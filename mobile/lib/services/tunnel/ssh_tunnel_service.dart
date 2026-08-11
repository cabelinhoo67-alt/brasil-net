import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../models/models.dart';
import 'captive_portal.dart';
import 'connect_strategy.dart';
import 'payload_parser.dart';
import 'raw_ssh_socket.dart';
import 'socks5_server.dart';
import 'tunnel_service.dart';
import 'vpn_bridge.dart';
import 'ws_ssh_socket.dart';

/// Motor de tunel SSH real, com resiliencia de rede tipo "zero-drop".
///
/// Fluxo de uma conexao:
///
///   1. TCP ate o servidor (ou proxy, quando o payload exige)
///   2. injecao do payload — CONNECT com os placeholders substituidos
///   3. deteccao de portal cativo na primeira resposta (302 de recarga etc.)
///   4. TLS com SNI de bug host, quando a estrategia exigir
///   5. handshake e autenticacao SSH com o usuario/senha do cliente
///   6. servidor SOCKS5 local, cada conexao virando um canal direct-tcpip
///   7. VpnService nativa: TUN -> tun2socks -> SOCKS5 local -> SSH -> internet
///
/// Duas camadas de resiliencia:
///
///   - **Fallback de portal cativo**: se a operadora interceptar a primeira
///     tentativa (chip sem saldo devolvendo 302 em vez do banner SSH), o motor
///     cai silenciosamente para a proxima estrategia da cadeia — payload
///     CONNECT, depois TLS com SNI — sem expor erro ao usuario.
///
///   - **Auto-reconnect**: ouve os eventos de rede do lado nativo
///     (NetworkCallback -> VpnService -> EventChannel). Ao perder rede, so
///     loga — o nativo ja congelou o trafego. Ao recuperar, refaz a sessao SSH
///     com backoff exponencial e reata o tun2socks (`rebind`) sem derrubar a
///     interface TUN, tornando o handover Wi-Fi <-> 4G imperceptivel.
class SshTunnelService implements TunnelService {
  SshTunnelService({VpnBridge? vpn, this.routeDeviceTraffic = true})
      : _vpn = vpn ?? VpnBridge();

  /// Quando falso, sobe apenas o SOCKS5 local (modo diagnostico).
  final bool routeDeviceTraffic;

  final VpnBridge _vpn;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _logController = StreamController<String>.broadcast();

  SSHClient? _client;
  Socks5Server? _socks;
  Timer? _keepAlive;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  /// Controle do watchdog de sessao meio-aberta: um socket SSH que parou de
  /// responder a ping nao fecha sozinho (o transporte nao detecta o bloqueio
  /// silencioso da operadora), entao a UI continuaria "conectado" para sempre.
  /// Este contador e o equivalente Dart do ServerAliveCountMax do OpenSSH.
  int _keepAliveFailures = 0;
  bool _keepAliveFiring = false;

  StreamSubscription<String>? _vpnEvents;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _reconnecting = false;

  /// Guardados para a reconexao poder refazer a sessao sem depender da UI.
  ///
  /// `_lastBypass` nao entra no rebind de proposito: a lista de apps excluidos
  /// ja foi aplicada na interface TUN quando ela foi criada, e o rebind()
  /// reaproveita essa mesma TUN (so troca a porta do tun2socks). Recriar a
  /// exclusao seria redundante.
  Payload? _lastPayload;
  String? _lastUsername;
  String? _lastPassword;
  String? _lastOperatorCode;

  static const _maxBackoff = Duration(seconds: 30);
  static const _maxReconnectAttempts = 8;

  /// Intervalo entre pings de keep-alive (equivalente a ServerAliveInterval).
  static const _keepAliveInterval = Duration(seconds: 30);

  /// Falhas consecutivas de ping que toleramos antes de declarar a sessao
  /// morta (equivalente a ServerAliveCountMax=3 do OpenSSH).
  static const _maxKeepAliveFailures = 3;

  @override
  Stream<ConnectionStatus> get status => _statusController.stream;

  @override
  Stream<String> get logs => _logController.stream;

  @override
  ConnectionStatus get currentStatus => _status;

  @override
  int? get socksPort => _socks?.isRunning == true ? _socks?.port : null;

  void _emit(ConnectionStatus value) {
    _status = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  void _log(String message) {
    if (!_logController.isClosed) _logController.add(message);
    // ignore: avoid_print
    print('[tunnel] $message');
  }

  @override
  Future<void> connect(
    Payload payload, {
    required String username,
    required String password,
    List<String> bypassPackages = const [],
    String? operatorCode,
  }) async {
    _cancelReconnect();
    await _teardownSession(stopVpn: true);
    _emit(ConnectionStatus.connecting);

    _lastPayload = payload;
    _lastUsername = username;
    _lastPassword = password;
    _lastOperatorCode = operatorCode;

    try {
      final server = payload.server;
      if (server == null) {
        throw const TunnelException('Esta configuracao nao tem servidor vinculado.');
      }

      final result = await _connectWithFallback(payload, server, username, password);

      if (routeDeviceTraffic) {
        await _vpn.start(
          socksPort: result.socksPort,
          // O trafego para o proprio servidor nao pode entrar no tunel,
          // senao a conexao SSH se morde (loop de roteamento).
          bypassHost: server.host,
          bypassPackages: bypassPackages,
          sessionName: payload.name,
        );
        final extra = bypassPackages.isEmpty ? '' : ' (${bypassPackages.length} app(s) fora)';
        _log('VPN ativa — trafego do aparelho roteado pelo tunel$extra');
        _watchNetwork();
      } else {
        _log('modo diagnostico: SOCKS5 em 127.0.0.1:${result.socksPort}');
      }

      _emit(ConnectionStatus.connected);
    } on TunnelException catch (error) {
      _log('falha: ${error.message}');
      await _teardownSession(stopVpn: true);
      _emit(ConnectionStatus.error);
      rethrow;
    } catch (error) {
      _log('falha inesperada: $error');
      await _teardownSession(stopVpn: true);
      _emit(ConnectionStatus.error);
      throw TunnelException('Nao foi possivel conectar.', detail: error);
    }
  }

  // ------------------------ cadeia de fallback ------------------------------

  /// Tenta cada [ConnectStrategy] da cadeia ate uma funcionar.
  ///
  /// Arquitetura de rotacao (failover agressivo): a cadeia inteira e percorrida
  /// em loop continuo ate o deadline global de rotacao. Uma estrategia falha
  /// por dois motivos bem diferentes:
  ///   - portal cativo detectado -> tenta a proxima em silencio (e o cenario
  ///     do chip sem saldo, que e exatamente o que a cadeia existe para tratar)
  ///   - erro de rede/timeout -> tambem tenta a proxima, mas loga como erro
  ///
  /// O laço so e interrompido quando uma tentativa obtem sucesso — o handshake
  /// 101 Switching Protocols (WebSocket/upgrade) ou a autenticacao SSH
  /// completa. So propaga excecao se TODAS as estrategias falharem dentro do
  /// teto de [rotationDeadline].
  Future<_ConnectResult> _connectWithFallback(
    Payload payload,
    ServerInfo server,
    String username,
    String password,
  ) async {
    final chain = StrategyChain.build(
      payload: payload,
      server: server,
      operatorCode: _lastOperatorCode,
    );

    TunnelException? lastError;

    // Teto agregador por tentativa: cobre qualquer etapa interna (transporte,
    // injecao de payload, TLS, auth SSH) que nao tenha timeout proprio ou cujo
    // timeout individual nao dispare por bloqueio de I/O nao-assincrono real
    // (ex.: write() em loop apertado). Sem isto, uma unica etapa travada
    // trava a cadeia inteira, mesmo com os outros timeouts no lugar.
    const strategyDeadline = Duration(seconds: 20);

    // Deadline global de rotacao: o loop continua girando pelas estrategias
    // ate obter o handshake de sucesso ou estourar este teto (90s = ~4-5
    // passagens completas pela cadeia). Um teto curto demais faria o usuario
    // ver erro quando a rede esta apenas "esquentando"; um teto longo demais
    // prenderia o app em "conectando" quando o bloqueio e definitivo.
    const rotationDeadline = Duration(seconds: 90);
    final startedAt = DateTime.now();

    while (true) {
      // A cada passagem completa, verifica o teto global e o estado de auth.
      if (DateTime.now().difference(startedAt) >= rotationDeadline) {
        _log('teto de ${rotationDeadline.inSeconds}s de rotacao atingido');
        break;
      }

      for (var i = 0; i < chain.length; i++) {
        final strategy = chain[i];
        _log('tentativa ${i + 1}/${chain.length}: ${strategy.label}');

        try {
          return await _attempt(strategy, username, password).timeout(
            strategyDeadline,
            onTimeout: () {
              _log('tentativa "${strategy.label}" travou alem de ${strategyDeadline.inSeconds}s');
              // A Future original do _attempt continua rodando em segundo
              // plano (Dart nao cancela); derruba o que ela possa ter deixado
              // pendurado (client/socks) antes de seguir para a proxima.
              _forceCloseSession();
              throw TunnelException(
                'Sem resposta do servidor em ${strategyDeadline.inSeconds}s '
                '(rede pode estar bloqueando a conexao).',
              );
            },
          );
        } on _PortalDetected catch (error) {
          _log('portal cativo detectado (${error.status}) — trocando de estrategia');
          lastError = const TunnelException(
            'A operadora interceptou a conexao (possivel falta de credito).',
          );
          continue;
        } on TunnelException catch (error) {
          _log('estrategia "${strategy.label}" falhou: ${error.message}');
          lastError = error;
          // Senha incorreta e o mesmo problema em qualquer transporte — nao
          // adianta insistir nas proximas estrategias da cadeia.
          if (error.authFailed) break;
          continue;
        }
      }

      // Auth falhou: nao adianta outra rodada, credenciais estao erradas.
      if (lastError?.authFailed == true) break;

      // Pequena pausa entre rodadas completas: deixa a rede estabilizar e o
      // DNS dos SNIs que falharam "esfriar" antes de tentar de novo.
      _log('nenhuma rota funcionou nesta rodada — tentando novamente');
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    throw lastError ??
        const TunnelException('Nenhuma estrategia de conexao funcionou.');
  }

  /// Fecha client/socks que uma tentativa estourada em timeout possa ter
  /// deixado presos, sem derrubar a VPN nativa (isso e decisao de quem chama).
  void _forceCloseSession() {
    _keepAlive?.cancel();
    _keepAlive = null;
    _keepAliveFailures = 0;
    _keepAliveFiring = false;
    try {
      _socks?.stop();
    } catch (_) {}
    _socks = null;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
  }

  /// Uma tentativa completa: transporte -> deteccao de portal -> SSH -> SOCKS.
  Future<_ConnectResult> _attempt(
    ConnectStrategy strategy,
    String username,
    String password,
  ) async {
    final socket = await _openTransport(strategy);

    _log('iniciando SSH como "$username"');
    final client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
    );

    try {
      await client.authenticated.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw const TunnelException(
          'O servidor nao respondeu a autenticacao a tempo.',
        ),
      );
    } on SSHAuthError catch (error) {
      // O SSH respondeu e recusou as credenciais — nao e bloqueio de rede,
      // e trocar de transporte na cadeia nao vai mudar isso. Sinaliza
      // authFailed para o chamador parar de tentar as proximas estrategias.
      try {
        client.close();
      } catch (_) {}
      throw TunnelException(
        'Usuario ou senha incorretos.',
        detail: error,
        authFailed: true,
      );
    } catch (error) {
      try {
        client.close();
      } catch (_) {}
      rethrow;
    }

    _client = client;
    _log('SSH autenticado');

    // Queda do lado do servidor dispara o auto-reconnect, nao desliga na hora.
    unawaited(client.done.then((_) {
      if (_status == ConnectionStatus.connected) {
        _log('sessao SSH encerrada pelo servidor');
        _scheduleReconnect();
      }
    }));

    final socks = Socks5Server(
      openChannel: (host, port) async {
        final forward = await client.forwardLocal(host, port);
        return TunnelChannel(
          stream: forward.stream,
          sink: forward.sink,
          close: () async {
            try {
              await forward.sink.close();
            } catch (_) {
              /* canal ja fechado do outro lado */
            }
          },
        );
      },
      onLog: _log,
    );
    final socksPort = await socks.start();
    _socks = socks;

    // Watchdog de sessao meio-aberta (equivalente a ServerAliveInterval +
    // ServerAliveCountMax do OpenSSH): o ping mantem a sessao viva na rede, e
    // se a sessao parar de responder, fechamos o client para o `client.done`
    // disparar o auto-reconnect — em vez de deixar a UI presa em "conectado"
    // com um socket morto. O timeout do ping cobre o caso de a operadora
    // engolir os pacotes sem avisar (meio-aberto).
    _keepAliveFailures = 0;
    _keepAlive = Timer.periodic(_keepAliveInterval, (_) async {
      if (_keepAliveFiring) return;
      if (client.isClosed) {
        // O transporte ja morreu; o handler do `client.done` cuida do
        // reconnect. Aqui so garantimos que o contador nao sobe a toa.
        _keepAliveFailures = 0;
        return;
      }

      _keepAliveFiring = true;
      try {
        await client
            .ping()
            .timeout(const Duration(seconds: 12), onTimeout: () {
              throw const TunnelException('ping estourou o timeout');
            });
        // Ping respondeu: sessao viva, zera o contador de falhas.
        _keepAliveFailures = 0;
      } catch (error) {
        _keepAliveFailures++;
        _log('keepalive falhou ($_keepAliveFailures/$_maxKeepAliveFailures): $error');
        if (_keepAliveFailures >= _maxKeepAliveFailures) {
          _log('sessao SSH inativa — derrubando para reconectar');
          _keepAliveFailures = 0;
          // Derruba o client morto; o handler do `client.done` (instalado
          // no _attempt) ve o transporte fechar e agenda a reconexao.
          try {
            client.close();
          } catch (_) {
            /* ja fechado */
          }
        }
      } finally {
        _keepAliveFiring = false;
      }
    });

    return _ConnectResult(socksPort: socksPort);
  }

  /// Abre o transporte (TCP + payload + TLS, ou WebSocket) para uma
  /// estrategia especifica, inspecionando a primeira resposta em busca de
  /// sinais de portal cativo quando aplicavel.
  Future<SSHSocket> _openTransport(ConnectStrategy strategy) async {
    if (strategy.mode == TransportMode.webSocket) {
      final url = strategy.wsUrl;
      if (url == null) {
        throw const TunnelException('Estrategia WebSocket sem URL configurada.');
      }
      _log('WebSocket $url');
      // wss:// ja e HTTPS por baixo — nao ha payload nem SNI custom aqui: o
      // certificado e o mesmo do dominio, entao nao ha o que "disfarcar". Os
      // headers extras (User-Agent/Origin) sao passados para o handshake HTTP
      // parecer HTTPS comum de navegador para a operadora.
      return WebSocketSSHSocket.connect(
        url,
        timeout: const Duration(seconds: 12),
        headers: strategy.wsHeaders,
      );
    }

    final usesPayload = strategy.mode == TransportMode.payload;
    final usesTls = strategy.mode == TransportMode.tlsSni;

    _log('TCP ${strategy.host}:${strategy.port}');

    final RawSocket raw;
    try {
      raw = await RawSocket.connect(
        strategy.host,
        strategy.port,
        timeout: const Duration(seconds: 12),
      );
    } on SocketException catch (error) {
      throw TunnelException(
        'Nao consegui alcancar ${strategy.host}:${strategy.port}.',
        detail: error.osError?.message ?? error.message,
      );
    }

    raw.setOption(SocketOption.tcpNoDelay, true);

    final subscription = raw.listen(null);
    final reader = _RawReader(raw, subscription);

    if (usesPayload) {
      await _injectPayload(raw: raw, reader: reader, strategy: strategy);
    } else if (!usesTls) {
      // SSH direto: a primeira coisa que chega deveria ser o banner SSH.
      // Se vier HTTP, e portal cativo interceptando na porta 22 mesmo.
      await _peekForPortal(reader);
    }

    if (!usesTls) {
      return RawSSHSocket(
        raw,
        subscription: reader.detach(),
        leftover: reader.takeBuffered(),
      );
    }

    final sni = strategy.sni ?? strategy.host;
    _log('TLS com SNI "$sni"');

    final stray = reader.takeBuffered();
    if (stray.isNotEmpty) {
      final verdict = CaptivePortal.inspect(stray);
      if (verdict == PortalVerdict.portal) {
        throw _PortalDetected(_extractStatus(stray));
      }
      throw TunnelException(
        'O proxy enviou dados inesperados antes do TLS.',
        detail: '${stray.length} byte(s) fora de ordem',
      );
    }

    try {
      final secure = await RawSecureSocket.secure(
        raw,
        subscription: reader.detach(),
        host: sni,
        // Servidores de tunel quase sempre usam certificado auto-assinado;
        // a confidencialidade aqui vem do SSH por dentro, nao do TLS.
        onBadCertificate: (_) => true,
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw const TunnelException('Tempo esgotado no handshake TLS.'),
      );

      return RawSSHSocket(secure);
    } on TlsException catch (error) {
      throw TunnelException('Falha no TLS.', detail: error.osError?.message ?? error.message);
    }
  }

  /// Espia os primeiros bytes de uma conexao "direta" sem consumi-los, so para
  /// decidir se e um portal cativo antes de tentar autenticar SSH em cima.
  Future<void> _peekForPortal(_RawReader reader) async {
    final peeked = await reader.peek(const Duration(milliseconds: 800));
    if (peeked == null || peeked.isEmpty) return; // nada ainda, segue normal

    final verdict = CaptivePortal.inspect(peeked);
    if (verdict == PortalVerdict.portal) {
      final target = CaptivePortal.redirectTarget(peeked);
      if (target != null) _log('portal aponta para: $target');
      throw _PortalDetected(_extractStatus(peeked));
    }
  }

  int _extractStatus(Uint8List data) {
    final head = String.fromCharCodes(data.take(64).toList());
    final match = RegExp(r'HTTP/\d\.\d\s+(\d{3})').firstMatch(head);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// Envia o payload e espera o proxy responder — ou detecta portal no meio.
  Future<void> _injectPayload({
    required RawSocket raw,
    required _RawReader reader,
    required ConnectStrategy strategy,
  }) async {
    final template = strategy.payloadTemplate ?? '';
    final chunks = PayloadParser.chunks(
      payload: template,
      host: strategy.host,
      port: strategy.port,
    );

    _log('injetando payload (${chunks.length} pacote(s))');

    // Deadline agregado para TODO o envio, nao so para a leitura da resposta.
    // raw.write() e nao-bloqueante: se a operadora fizer zero-window ou
    // black-hole no meio do envio, ele passa a devolver 0 bytes escritos
    // indefinidamente e o loop giraria para sempre — este e o bug que
    // travava o app em "carregando infinito" na Claro.
    final deadline = DateTime.now().add(const Duration(seconds: 10));

    for (final chunk in chunks) {
      var offset = 0;
      var stalledWrites = 0;

      while (offset < chunk.data.length) {
        if (DateTime.now().isAfter(deadline)) {
          throw const TunnelException(
            'A operadora parou de aceitar dados durante o envio do payload.',
          );
        }

        final written = raw.write(chunk.data, offset, chunk.data.length - offset);
        if (written == 0) {
          // Buffer de saida cheio / janela TCP travada. Tolera algumas
          // tentativas com backoff curto; se persistir ate o deadline acima,
          // o proximo giro do loop estoura a excecao.
          stalledWrites++;
          if (stalledWrites > 400) {
            throw const TunnelException(
              'A operadora parou de aceitar dados durante o envio do payload.',
            );
          }
        } else {
          stalledWrites = 0;
        }

        offset += written;
        if (offset < chunk.data.length) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      if (chunk.delayAfter > Duration.zero) {
        await Future<void>.delayed(chunk.delayAfter);
      }
    }

    final response = await reader
        .readUntilHeaderEnd()
        .timeout(
          const Duration(seconds: 12),
          onTimeout: () => throw const TunnelException(
            'O proxy nao respondeu a injecao do payload.',
          ),
        );

    final text = String.fromCharCodes(response);
    final firstLine = text.split('\n').first.trim();
    _log('proxy respondeu: $firstLine');

    final verdict = CaptivePortal.inspect(response);
    if (verdict == PortalVerdict.portal) {
      throw _PortalDetected(_extractStatus(response));
    }

    // Handshake de sucesso: 200 (CONNECT aceito, tunel TCP puro) ou 101
    // (Switching Protocols — a conexao foi promovida, ex.: para WebSocket).
    // O 101 e o sinal do upgrade de protocolo; apos ele, o tunel pode mandar
    // o banner SSH direto no mesmo socket.
    final ok = firstLine.contains(' 200 ') || firstLine.contains(' 101 ');
    if (!ok) {
      throw TunnelException(
        'O proxy recusou o payload.',
        detail: firstLine.isEmpty ? 'resposta vazia' : firstLine,
      );
    }

    if (firstLine.contains(' 101 ')) {
      _log('handshake 101 Switching Protocols confirmado');
    }
  }

  // --------------------------- auto-reconnect -------------------------------

  /// Passa a ouvir os eventos de rede do lado nativo. So chamado depois que a
  /// VPN esta de pe — antes disso nao ha nada para reconectar.
  void _watchNetwork() {
    _vpnEvents?.cancel();
    _vpnEvents = _vpn.state.listen((event) {
      switch (event) {
        case 'network_lost':
          // O nativo ja parou o tun2socks; aqui e so estado + log. Nao ha
          // socket para "congelar" do lado Dart alem do que ja e feito.
          _log('rede perdida — aguardando reconexao automatica');
          break;

        case 'network_available':
        case 'needs_reconnect':
          _log('rede disponivel — reconectando');
          _scheduleReconnect();
          break;

        case 'disconnected':
          // A TUN caiu sem ordem nossa (ex.: revogacao de permissao pelo
          // sistema, ou erro fatal no nativo). Se ainda temos credenciais e
          // o usuario nao desligou, tenta refazer a sessao do zero.
          if (_lastPayload != null) {
            _log('VPN encerrada pelo sistema — tentando reconectar');
            _scheduleReconnect();
          }
          break;

        default:
          if (event.startsWith('error:')) {
            final detail = event.substring(6);
            _log('erro da VPN nativa: $detail');
            // Falha fatal ao subir a TUN (ex.: tun2socks ausente): o tunel
            // SSH pode ate estar de pe, mas sem a interface o trafego nao
            // passa. Derrete a sessao e emite erro — em vez de deixar o app
            // preso em "conectado" sem internet, que e o sintoma que o
            // usuario descreve como "tunel fechado".
            if (_lastPayload != null) {
              _log('VPN nativa falhou — encerrando sessao');
              unawaited(_teardownSession(stopVpn: true).then((_) {
                _emit(ConnectionStatus.error);
              }));
            }
          }
          break;
      }
    });
  }

  /// Agenda uma tentativa de reconexao com backoff exponencial: 2s, 4s, 8s,
  /// 16s, ate o teto de 30s. Nao empilha tentativas concorrentes.
  void _scheduleReconnect() {
    if (_reconnecting) return;
    if (_lastPayload == null || _lastUsername == null || _lastPassword == null) return;

    _reconnectTimer?.cancel();

    final delay = _backoffDelay(_reconnectAttempt);
    _reconnectAttempt++;
    _log('nova tentativa em ${delay.inSeconds}s (tentativa $_reconnectAttempt)');

    _reconnectTimer = Timer(delay, _attemptReconnect);
  }

  Duration _backoffDelay(int attempt) {
    final seconds = min(pow(2, attempt + 1).toInt(), _maxBackoff.inSeconds);
    return Duration(seconds: seconds);
  }

  Future<void> _attemptReconnect() async {
    if (_reconnecting) return;
    _reconnecting = true;

    try {
      if (_reconnectAttempt > _maxReconnectAttempts) {
        _log(
          'desisti apos $_maxReconnectAttempts tentativas de reconexao — '
          'feche o tunel e tente de novo, ou verifique se o servidor '
          '${_lastPayload?.server?.host ?? ''} esta acessivel.',
        );
        await _teardownSession(stopVpn: true);
        _emit(ConnectionStatus.error);
        return;
      }

      final payload = _lastPayload!;
      final server = payload.server;
      if (server == null) return;

      // Reflete "reconectando" na UI e no overlay durante a tentativa.
      _emit(ConnectionStatus.connecting);

      // Fecha so a sessao SSH/SOCKS antiga; a TUN nativa continua de pe —
      // e o rebind() que a reaproveita, sem os apps notarem a troca.
      await _teardownSession(stopVpn: false);

      final result = await _connectWithFallback(
        payload,
        server,
        _lastUsername!,
        _lastPassword!,
      );

      if (routeDeviceTraffic) {
        await _vpn.rebind(result.socksPort);
      }

      _reconnectAttempt = 0;
      _emit(ConnectionStatus.connected);
      _log('reconectado com sucesso');
    } on TunnelException catch (error) {
      _log('reconexao falhou: ${error.message}');
      if (error.detail != null) {
        _log('detalhe: ${error.detail}');
      }
      if (error.authFailed) {
        // O servidor recusou as credenciais durante a reconexao: continuar
        // tentando so queima bateria e dados. Desiste ja com erro claro.
        _log('credenciais recusadas pelo servidor — parando de tentar');
        _reconnecting = false;
        await _teardownSession(stopVpn: true);
        _emit(ConnectionStatus.error);
        return;
      }
      _reconnecting = false;
      _scheduleReconnect();
      return;
    } catch (error) {
      _log('reconexao falhou: $error');
      _reconnecting = false;
      _scheduleReconnect();
      return;
    }
    _reconnecting = false;
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _reconnecting = false;
  }

  @override
  Future<void> disconnect() async {
    _cancelReconnect();
    await _vpnEvents?.cancel();
    _vpnEvents = null;
    _lastPayload = null;
    _lastUsername = null;
    _lastPassword = null;
    await _teardownSession(stopVpn: true);
    _emit(ConnectionStatus.disconnected);
  }

  /// Fecha SSH e SOCKS. `stopVpn` controla se a interface TUN nativa tambem
  /// cai — falso durante reconexao, para o handover ficar imperceptivel.
  Future<void> _teardownSession({required bool stopVpn}) async {
    _keepAlive?.cancel();
    _keepAlive = null;

    if (stopVpn && routeDeviceTraffic) {
      await _vpnEvents?.cancel();
      _vpnEvents = null;
      try {
        await _vpn.stop();
      } catch (error) {
        _log('erro ao parar a VPN: $error');
      }
    }

    await _socks?.stop();
    _socks = null;

    try {
      _client?.close();
    } catch (_) {
      /* ja fechado */
    }
    _client = null;
  }

  @override
  Future<void> dispose() async {
    _cancelReconnect();
    await _vpnEvents?.cancel();
    await _teardownSession(stopVpn: true);
    await _statusController.close();
    await _logController.close();
  }
}

class _ConnectResult {
  const _ConnectResult({required this.socksPort});
  final int socksPort;
}

/// Sinaliza que a resposta recebida e de um portal cativo, nao do servidor.
/// Fica interno ao arquivo: quem consome e so a cadeia de fallback.
class _PortalDetected implements Exception {
  const _PortalDetected(this.status);
  final int status;
}

/// Leitor sobre [RawSocket] usado na fase de handshake.
///
/// Guarda a assinatura para devolve-la depois — e ela que o
/// `RawSecureSocket.secure` precisa receber para assumir o socket.
class _RawReader {
  _RawReader(this._raw, this._subscription) {
    _subscription.onData(_onEvent);
  }

  final RawSocket _raw;
  final StreamSubscription<RawSocketEvent> _subscription;
  final _buffer = <int>[];
  Completer<Uint8List>? _waiter;
  bool _closed = false;

  void _onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final data = _raw.read();
      if (data != null) _buffer.addAll(data);
      _check();
    } else if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
      _closed = true;
      _check();
    }
  }

  void _check() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;

    final text = String.fromCharCodes(_buffer);
    final end = text.indexOf('\r\n\r\n');
    final endLf = text.indexOf('\n\n');

    if (end >= 0 || endLf >= 0) {
      final cut = end >= 0 ? end + 4 : endLf + 2;
      final head = Uint8List.fromList(_buffer.sublist(0, cut));
      _buffer.removeRange(0, cut);
      _waiter = null;
      waiter.complete(head);
      return;
    }

    if (_closed) {
      _waiter = null;
      waiter.completeError(
        const TunnelException('O proxy fechou a conexao durante o handshake.'),
      );
    }
  }

  Future<Uint8List> readUntilHeaderEnd() {
    final completer = Completer<Uint8List>();
    _waiter = completer;
    _check();
    return completer.future;
  }

  /// Olha o que ja chegou sem exigir um terminador — usado na deteccao de
  /// portal do modo SSH direto, onde nao ha um fim de cabecalho para esperar.
  /// Devolve null se nada chegou dentro do prazo (segue como conexao normal).
  Future<Uint8List?> peek(Duration timeout) async {
    if (_buffer.isNotEmpty) {
      return Uint8List.fromList(_buffer);
    }

    final completer = Completer<Uint8List?>();
    void checkPeek() {
      if (completer.isCompleted) return;
      if (_buffer.isNotEmpty) {
        completer.complete(Uint8List.fromList(_buffer));
      } else if (_closed) {
        completer.complete(null);
      }
    }

    final previousWaiter = _waiter;
    // Reaproveita o mesmo canal de notificacao do _check() via um poll leve;
    // simples e suficiente para uma janela de flush de algumas centenas de ms.
    final ticker = Timer.periodic(const Duration(milliseconds: 40), (_) => checkPeek());

    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      ticker.cancel();
      _waiter = previousWaiter;
    }
  }

  /// Entrega a assinatura para quem for assumir o socket daqui em diante.
  StreamSubscription<RawSocketEvent> detach() {
    _subscription.onData(null);
    return _subscription;
  }

  /// Bytes ja lidos do socket que ainda nao foram consumidos.
  Uint8List takeBuffered() {
    final data = Uint8List.fromList(_buffer);
    _buffer.clear();
    return data;
  }
}
