import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../models/models.dart';
import 'payload_parser.dart';
import 'raw_ssh_socket.dart';
import 'socks5_server.dart';
import 'tunnel_service.dart';
import 'vpn_bridge.dart';

/// Motor de tunel SSH real.
///
/// Fluxo completo de uma conexao:
///
///   1. TCP ate o servidor (ou ate o proxy, quando o payload exige)
///   2. injecao do payload — CONNECT com os placeholders substituidos
///   3. TLS com SNI customizado, quando o modo for SSH_SSL
///   4. handshake e autenticacao SSH com o usuario/senha do cliente
///   5. servidor SOCKS5 local, cada conexao virando um canal direct-tcpip
///   6. VpnService nativa: TUN -> tun2socks -> SOCKS5 local -> SSH -> internet
///
/// O passo 6 e o que faz o celular inteiro passar pelo tunel. Sem ele, os
/// passos 1-5 ainda funcionam e entregam um proxy SOCKS5 em 127.0.0.1 — util
/// para testar a conexao antes de mexer com VPN.
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

  @override
  Stream<ConnectionStatus> get status => _statusController.stream;

  @override
  Stream<String> get logs => _logController.stream;

  @override
  ConnectionStatus get currentStatus => _status;

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
  }) async {
    await _teardown();
    _emit(ConnectionStatus.connecting);

    try {
      final server = payload.server;
      if (server == null) {
        throw const TunnelException('Esta configuracao nao tem servidor vinculado.');
      }

      final socket = await _openTransport(payload, server);

      _log('iniciando SSH como "$username"');
      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
      );

      await client.authenticated.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw const TunnelException(
          'O servidor nao respondeu a autenticacao a tempo.',
        ),
      );
      _client = client;
      _log('SSH autenticado');

      // Queda do lado do servidor derruba a UI junto.
      unawaited(client.done.then((_) {
        if (_status != ConnectionStatus.disconnected) {
          _log('sessao SSH encerrada pelo servidor');
          disconnect();
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

      if (routeDeviceTraffic) {
        await _vpn.start(
          socksPort: socksPort,
          // O trafego para o proprio servidor nao pode entrar no tunel,
          // senao a conexao SSH se morde (loop de roteamento).
          bypassHost: server.host,
          bypassPackages: bypassPackages,
          sessionName: payload.name,
        );
        final extra = bypassPackages.isEmpty ? '' : ' (${bypassPackages.length} app(s) fora)';
        _log('VPN ativa — trafego do aparelho roteado pelo tunel$extra');
      } else {
        _log('modo diagnostico: SOCKS5 em 127.0.0.1:$socksPort');
      }

      _keepAlive = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          client.ping();
        } catch (error) {
          _log('keepalive falhou: $error');
        }
      });

      _emit(ConnectionStatus.connected);
    } on TunnelException catch (error) {
      _log('falha: ${error.message}');
      await _teardown();
      _emit(ConnectionStatus.error);
      rethrow;
    } catch (error) {
      _log('falha inesperada: $error');
      await _teardown();
      _emit(ConnectionStatus.error);
      throw TunnelException('Nao foi possivel conectar.', detail: error);
    }
  }

  /// Monta o transporte (TCP + payload + TLS) conforme o modo do payload.
  Future<SSHSocket> _openTransport(Payload payload, ServerInfo server) async {
    final usesPayload = payload.content.trim().isNotEmpty;
    final usesTls = payload.mode == 'SSH_SSL';

    // Com payload, conectamos primeiro no proxy; sem payload, direto no destino.
    final connectHost = usesPayload ? (payload.proxyHost ?? server.host) : server.host;
    final connectPort = usesPayload
        ? (payload.proxyPort ?? server.proxyPort)
        : (usesTls ? server.sslPort : server.sshPort);

    _log('TCP $connectHost:$connectPort');

    final RawSocket raw;
    try {
      raw = await RawSocket.connect(
        connectHost,
        connectPort,
        timeout: const Duration(seconds: 15),
      );
    } on SocketException catch (error) {
      throw TunnelException(
        'Nao consegui alcancar $connectHost:$connectPort.',
        detail: error.osError?.message ?? error.message,
      );
    }

    raw.setOption(SocketOption.tcpNoDelay, true);

    var subscription = raw.listen(null);
    final reader = _RawReader(raw, subscription);

    if (usesPayload) {
      await _injectPayload(
        raw: raw,
        reader: reader,
        payload: payload,
        targetHost: server.host,
        targetPort: usesTls ? server.sslPort : server.sshPort,
      );
    }

    if (!usesTls) {
      // O leftover carrega os bytes que chegaram junto com a resposta do
      // proxy — tipicamente o proprio banner "SSH-2.0-..." do servidor.
      return RawSSHSocket(
        raw,
        subscription: reader.detach(),
        leftover: reader.takeBuffered(),
      );
    }

    final sni = (payload.sni?.trim().isNotEmpty ?? false) ? payload.sni!.trim() : server.host;
    _log('TLS com SNI "$sni"');

    // O TLS assume o socket do zero. Se o proxy mandou bytes extras junto com
    // a resposta, o ClientHello sairia depois de lixo e o handshake quebraria.
    final stray = reader.takeBuffered();
    if (stray.isNotEmpty) {
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
        const Duration(seconds: 15),
        onTimeout: () => throw const TunnelException('Tempo esgotado no handshake TLS.'),
      );

      return RawSSHSocket(secure);
    } on TlsException catch (error) {
      throw TunnelException('Falha no TLS.', detail: error.osError?.message ?? error.message);
    }
  }

  /// Envia o payload e espera o proxy responder com sucesso.
  Future<void> _injectPayload({
    required RawSocket raw,
    required _RawReader reader,
    required Payload payload,
    required String targetHost,
    required int targetPort,
  }) async {
    final chunks = PayloadParser.chunks(
      payload: payload.content,
      host: targetHost,
      port: targetPort,
    );

    _log('injetando payload (${chunks.length} pacote(s))');

    for (final chunk in chunks) {
      var offset = 0;
      while (offset < chunk.data.length) {
        offset += raw.write(chunk.data, offset, chunk.data.length - offset);
        if (offset < chunk.data.length) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      if (chunk.delayAfter > Duration.zero) {
        await Future<void>.delayed(chunk.delayAfter);
      }
    }

    // Alguns proxies respondem varias linhas de status antes do corpo;
    // aceitamos o primeiro 200/101 que aparecer.
    final response = await reader
        .readUntilHeaderEnd()
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw const TunnelException(
            'O proxy nao respondeu a injecao do payload.',
          ),
        );

    final text = String.fromCharCodes(response);
    final firstLine = text.split('\n').first.trim();
    _log('proxy respondeu: $firstLine');

    final ok = RegExp(r'\s(200|101)\s').hasMatch(' $firstLine ') ||
        firstLine.contains(' 200 ') ||
        firstLine.contains(' 101 ');

    if (!ok) {
      throw TunnelException(
        'O proxy recusou o payload.',
        detail: firstLine.isEmpty ? 'resposta vazia' : firstLine,
      );
    }
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
    _emit(ConnectionStatus.disconnected);
  }

  Future<void> _teardown() async {
    _keepAlive?.cancel();
    _keepAlive = null;

    if (routeDeviceTraffic) {
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
    await _teardown();
    await _statusController.close();
    await _logController.close();
  }
}

/// Leitor sobre [RawSocket] usado apenas na fase de handshake.
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
