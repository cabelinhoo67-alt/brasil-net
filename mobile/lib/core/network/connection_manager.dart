import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/network_config.dart';
import 'payload_parser.dart';
import 'tunnel_socket.dart';

/// Estados reativos da conexao (Riverpod/Bloc).
enum TunnelState {
  /// Nenhuma tentativa em andamento.
  disconnected,

  /// Resolvendo o SNI via DNS-over-HTTPS (anti envenenamento).
  resolvingDns,

  /// Estabelecendo handshake TCP/TLS/WebSocket.
  handshaking,

  /// Autenticando no servidor (apos o upgrade HTTP 101/200).
  authenticating,

  /// Conexao estabelecida e funcional.
  connected,

  /// Perdemos a conexao e estamos tentando recuperar.
  reconnecting,

  /// Esgotou o numero de tentativas de fallover.
  failed,
}

extension TunnelStateX on TunnelState {
  String get label => switch (this) {
        TunnelState.disconnected => 'Desconectado',
        TunnelState.resolvingDns => 'Resolvendo DNS...',
        TunnelState.handshaking => 'Handshake...',
        TunnelState.authenticating => 'Autenticando...',
        TunnelState.connected => 'Conectado',
        TunnelState.reconnecting => 'Reconectando...',
        TunnelState.failed => 'Falha na conexao',
      };
}

/// Evento de progresso emitido durante a tentativa de conexao.
@immutable
class ConnectingState {
  const ConnectingState({
    required this.attempt,
    required this.totalAttempts,
    required this.targetHost,
    this.targetPort,
    this.sni,
    this.proxy,
  });

  final int attempt;
  final int totalAttempts;
  final String targetHost;
  final int? targetPort;
  final String? sni;
  final ProxyNode? proxy;

  @override
  String toString() =>
      'ConnectingState(attempt $attempt/$totalAttempts, $targetHost'
      '${targetPort != null ? ':$targetPort' : ''}'
      '${sni != null ? ' sni=$sni' : ''}'
      '${proxy != null ? ' proxy=${proxy!.hostPort}' : ''})';
}

/// Falha de conexao tipada com o nó que falhou (para o circuit breaker).
@immutable
class NodeFailure implements Exception {
  const NodeFailure(this.nodeKey, this.reason, {this.cause});

  /// Chave do nó que falhou (`host:porta`).
  final String nodeKey;

  final String reason;
  final Object? cause;

  @override
  String toString() => 'NodeFailure($nodeKey: $reason)';
}

/// Resultado de uma conexao estabelecida com sucesso.
@immutable
class TunnelConnection {
  const TunnelConnection({
    required this.socket,
    required this.node,
    required this.sni,
    required this.scheme,
    this.sessionId,
  });

  /// Socket pronto (pos payload + upgrade TLS/HTTP).
  final TunnelSocket socket;

  /// Nó proxy usado (ou nó do servidor direto).
  final ProxyNode node;

  /// SNI/host usado no handshake.
  final String sni;

  /// Esquema do transporte (`tcp`, `tls`, `http`).
  final String scheme;

  /// Identificador unico da sessao (para `[seuid]`).
  final String? sessionId;
}

/// Resultado de um RTT probe (para ordenacao de nós por latencia).
@immutable
class RttProbe {
  const RttProbe(this.node, this.rtt, {this.portable = false});

  final ProxyNode node;

  /// Latencia medida em milissegundos (infinito = inalcancavel).
  final Duration rtt;

  /// `true` quando o probe respondeu.
  final bool portable;

  @override
  String toString() => 'RttProbe(${node.hostPort}: ${rtt.inMilliseconds}ms)';
}

/// Circuit breaker por nó: marca falhas temporarias e impede reuso imediato.
class CircuitBreaker {
  CircuitBreaker({
    Duration openTimeout = const Duration(seconds: 30),
    this.maxFailuresBeforeOpen = 2,
  }) : _openTimeout = openTimeout;

  final Duration _openTimeout;
  final int maxFailuresBeforeOpen;

  final Map<String, _BreakerState> _states = {};

  bool _closed = false;

  /// `true` quando o breaker está completamente aberto (todos os nós).
  bool get isOpen => _closed;

  /// Registra uma falha no nó. Retorna `true` quando o breaker abriu.
  bool reportFailure(String nodeKey) {
    final state = _states.putIfAbsent(nodeKey, () => _BreakerState());
    state.failures++;
    state.lastFailureAt = DateTime.now();

    if (state.failures >= maxFailuresBeforeOpen) {
      state.openUntil = DateTime.now().add(_openTimeout);
      state.failures = 0; // reset para o próximo ciclo de contagem
      if (_states.isNotEmpty) {
        // Se todos os nós conhecidos abriram, o breaker global abre.
        _closed = _states.values.every(
          (s) => s.openUntil != null && s.openUntil!.isAfter(DateTime.now()),
        );
      }
      return true;
    }
    return false;
  }

  /// `true` quando o nó pode ser tentado (não está no período de abertura).
  bool canTry(String nodeKey) {
    final state = _states[nodeKey];
    if (state == null) return true;
    final openUntil = state.openUntil;
    if (openUntil == null) return true;
    if (openUntil.isAfter(DateTime.now())) return false;
    state.openUntil = null;
    state.failures = 0;
    return true;
  }

  /// Remove um nó do breaker (não é mais rastreado).
  void forget(String nodeKey) => _states.remove(nodeKey);

  /// Reseta o breaker inteiro.
  void reset() {
    _states.clear();
    _closed = false;
  }
}

class _BreakerState {
  int failures = 0;
  DateTime? lastFailureAt;
  DateTime? openUntil;
}

/// Resolvedor DNS-over-HTTPS (DoH) para converter SNIs em IPs limpos quando
/// o DNS da operadora está envenenado (DNS poisoning).
///
/// Usa `https://dns.google/resolve` (formato JSON) com fallback para
/// `https://cloudflare-dns.com/dns-query?type=A`.
class DohResolver {
  DohResolver({
    this.dohEndpoints = const [
      'https://dns.google/resolve',
      'https://cloudflare-dns.com/dns-query?type=A',
    ],
    this.timeout = const Duration(seconds: 4),
    this.httpClient,
  });

  final List<String> dohEndpoints;
  final Duration timeout;
  final HttpClient? httpClient;

  /// Resolve [hostname] para enderecos IP via DoH.
  ///
  /// Retorna uma lista de [InternetAddress] na ordem retornada pelo servidor.
  /// Lanca [SocketException] se nenhum endpoint respondeu.
  Future<List<InternetAddress>> resolve(String hostname) async {
    if (hostname.isEmpty) return const [];

    // Se já é IP literal, não precisa de DNS.
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) return [literal];

    for (final endpoint in dohEndpoints) {
      try {
        final addresses = await _resolveSingle(endpoint, hostname);
        if (addresses.isNotEmpty) return addresses;
      } catch (_) {
        // Tenta o próximo endpoint.
      }
    }

    // Fallback: DNS do sistema (pode estar envenenado, mas é o último recurso).
    try {
      return await InternetAddress.lookup(hostname);
    } on SocketException {
      throw SocketException('DoH falhou para $hostname (todos os endpoints).');
    }
  }

  Future<List<InternetAddress>> _resolveSingle(
    String endpoint,
    String hostname,
  ) async {
    final client = httpClient ?? HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('$endpoint?name=$hostname&type=A'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(timeout);

      if (response.statusCode != 200) {
        throw SocketException('DoH HTTP ${response.statusCode}');
      }

      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final answers = json['Answer'] as List? ?? const [];

      final addresses = <InternetAddress>[];
      for (final answer in answers) {
        if (answer is! Map) continue;
        final map = Map<String, dynamic>.from(answer);
        final type = map['type'];
        final data = map['data'];
        if (type is int && type == 1 && data is String) {
          final ip = InternetAddress.tryParse(data);
          if (ip != null) addresses.add(ip);
        }
      }
      return addresses;
    } finally {
      if (httpClient == null) {
        client.close(force: true);
      }
    }
  }
}

/// Orquestrador de conexao com failover adaptativo, circuit breaker e
/// rotação de IPs/SNIs.
///
/// Arquitetura:
///  1. RTT probe concorrente em background ordena os pares (SNI, Proxy) por
///     menor latência.
///  2. Tenta conectar usando o par mais rápido.
///  3. Em falha de handshake TLS, timeout (padrão 5s) ou resposta HTTP != 101
///     Switching Protocols, o circuit breaker marca o nó como falho e alterna
///     instantaneamente para o próximo par.
///  4. A alternância emite [ConnectingState] reativo sem resetar a UI.
///  5. DoH integrado converte SNIs em IPs limpos quando o DNS da operadora
///     está envenenado.
class TunnelConnectionManager {
  /// Instancia compartilhada (padrao do projeto, como [TunnelFactory]).
  ///
  /// Permite que o Remote Control Plane injete a config via [applyConfig] de
  /// qualquer lugar do app — inclusive do [ConfigController] criado no boot.
  static final TunnelConnectionManager instance = TunnelConnectionManager();

  TunnelConnectionManager({
    DohResolver? doh,
    CircuitBreaker? breaker,
    this.connectTimeout = const Duration(seconds: 5),
    this.headerTimeout = const Duration(seconds: 8),
    this.maxRotationAttempts = 12,
    this.probeConcurrency = 4,
  })  : _doh = doh ?? DohResolver(),
        _breaker = breaker ?? CircuitBreaker();

  final DohResolver _doh;
  final CircuitBreaker _breaker;

  /// Ultima configuracao aplicada via [applyConfig] (hot reload).
  ///
  /// Mantida para que as proximas chamadas de [connect] usem a config mais
  /// recente recebida do Remote Control Plane sem reiniciar o app.
  NetworkConfigModel? _appliedConfig;

  /// Configuracao ativa (a mais recente aplicada, se houver).
  NetworkConfigModel? get appliedConfig => _appliedConfig;

  /// Timeout de conexão TCP (padrão 5s por especificação).
  final Duration connectTimeout;

  /// Timeout para ler o cabeçalho de resposta do proxy.
  final Duration headerTimeout;

  /// Limite total de tentativas de rotação.
  final int maxRotationAttempts;

  /// Quantos RTT probes rodam em paralelo.
  final int probeConcurrency;

  /// Aplica uma nova configuracao recebida do Remote Control Plane (hot
  /// reload) sem reiniciar o app.
  ///
  /// A config substitui a anterior e e usada pelas proximas chamadas de
  /// [connect]. Se o app estiver conectado no momento, a config entra em
  /// vigor na proxima conexao — a sessao atual nao e derrubada.
  ///
  /// Tambem "esquece" os estados do circuit breaker (novos SNIs/proxies podem
  /// ter entrado na lista) e emite um aviso no log.
  void applyConfig(NetworkConfigModel config) {
    _appliedConfig = config;
    _breaker.reset();
    debugPrint(
      '[$TunnelConnectionManager] config aplicada v${config.version} '
      '(${config.carriers.length} operadoras)',
    );
  }

  final _stateController = StreamController<TunnelState>.broadcast();
  final _progressController = StreamController<ConnectingState>.broadcast();

  /// Estado atual.
  TunnelState _state = TunnelState.disconnected;
  TunnelState get currentState => _state;

  /// Stream reativa do estado da conexão.
  Stream<TunnelState> get states => _stateController.stream;

  /// Stream reativa do progresso (tentativa atual, host alvo, etc.).
  Stream<ConnectingState> get progress => _progressController.stream;

  void _setState(TunnelState value) {
    if (_state == value) return;
    _state = value;
    if (!_stateController.isClosed) _stateController.add(value);
  }

  void _emitProgress(ConnectingState value) {
    if (!_progressController.isClosed) _progressController.add(value);
  }

  /// Inicia a conexão para a [carrier], tentando os pares (SNI, proxy) em
  /// ordem de menor latência.
  ///
  /// [onUpgraded] é chamado quando o socket está pronto (após payload +
  /// upgrade). O callback deve autenticar (ex.: SSH) e retornar `true` em
  /// sucesso — o que sela a conexão. Retorna o [TunnelConnection] selado.
  Future<TunnelConnection> connect({
    required CarrierConfig carrier,
    String? sessionId,
    String? overrideSni,
    String? overrideProxy,
    bool Function(TunnelSocket socket, String sni)? onUpgraded,
    void Function(TunnelState state)? onState,
    void Function(ConnectingState progress)? onProgress,
  }) async {
    // Hot reload: se uma config remota mais recente foi aplicada, resolve a
    // carrier pela config ativa (por codigo/nome) antes de conectar. Se a
    // carrier informada nao existir na config nova, mantem a passada (a rede
    // legada continua valida ate a proxima atualizacao).
    final applied = _appliedConfig;
    if (applied != null && applied.version > 0) {
      final fresh = applied.pickCarrier(carrier.carrierCode) ??
          applied.pickCarrier(carrier.name);
      if (fresh != null) {
        carrier = fresh;
        debugPrint(
          '[$TunnelConnectionManager] usando config v${applied.version} '
          'para ${carrier.name}',
        );
      }
    }

    onState?.call(_state = TunnelState.resolvingDns);
    _setState(TunnelState.resolvingDns);

    final session = sessionId ?? _uuidV4();

    // Ordena SNIs e proxies por menor latência (probe concorrente em background).
    final rankedSnis = await _rankByLatency(carrier.sniHosts);
    final rankedProxies = overrideProxy != null
        ? [_parseProxy(overrideProxy)]
        : await _rankByLatencyProxies(carrier.proxyNodes);

    if (rankedSnis.isEmpty) {
      _fail('Nenhum SNI disponível para ${carrier.name}.');
      onState?.call(_state = TunnelState.failed);
      return Future.error(
        NodeFailure('${carrier.name}:sni', 'Sem SNIs para ${carrier.name}'),
      );
    }
    if (rankedProxies.isEmpty) {
      _fail('Nenhum proxy disponível para ${carrier.name}.');
      onState?.call(_state = TunnelState.failed);
      return Future.error(
        NodeFailure('${carrier.name}:proxy', 'Sem proxies para ${carrier.name}'),
      );
    }

    // Gera a ordem de tentativas: SNIs × proxies, com os mais rápidos primeiro.
    final orderedPairs = <({String sni, ProxyNode proxy})>[];
    for (final sni in rankedSnis) {
      for (final proxy in rankedProxies) {
        if (_breaker.canTry(proxy.key)) {
          orderedPairs.add((sni: sni, proxy: proxy));
        }
      }
    }

    final total = orderedPairs.length;
    if (total == 0) {
      _fail('Todos os nós estão em cooldown (circuit breaker).');
      onState?.call(_state = TunnelState.failed);
      return Future.error(
        const NodeFailure('all', 'Todos os nós em cooldown'),
      );
    }

    var attempt = 0;
    for (final pair in orderedPairs) {
      attempt++;
      if (attempt > maxRotationAttempts) break;

      final progress = ConnectingState(
        attempt: attempt,
        totalAttempts: total,
        targetHost: pair.proxy.host,
        targetPort: pair.proxy.port,
        sni: pair.sni,
        proxy: pair.proxy,
      );
      _emitProgress(progress);
      onProgress?.call(progress);
      onState?.call(_state = TunnelState.handshaking);
      _setState(TunnelState.handshaking);

      try {
        final connection = await _tryConnect(
          carrier: carrier,
          sni: pair.sni,
          proxy: pair.proxy,
          sessionId: session,
          onUpgraded: onUpgraded,
        );
        _setState(TunnelState.connected);
        onState?.call(TunnelState.connected);
        _breaker.reset();
        return connection;
      } on NodeFailure catch (failure) {
        // Circuit breaker: marca o nó que falhou.
        final opened = _breaker.reportFailure(failure.nodeKey);
        if (opened) {
          _emitProgress(ConnectingState(
            attempt: attempt,
            totalAttempts: total,
            targetHost: pair.proxy.host,
            targetPort: pair.proxy.port,
            sni: pair.sni,
            proxy: pair.proxy,
          ));
        }
        // Continua para o próximo par.
        continue;
      } on TimeoutException catch (error) {
        final opened = _breaker.reportFailure(pair.proxy.key);
        if (opened) {
          _emitProgress(ConnectingState(
            attempt: attempt,
            totalAttempts: total,
            targetHost: pair.proxy.host,
            targetPort: pair.proxy.port,
            sni: pair.sni,
            proxy: pair.proxy,
          ));
        }
        debugPrint('[$TunnelConnectionManager] timeout em '
            '${pair.proxy.hostPort}: $error');
        continue;
      }
    }

    _setState(TunnelState.failed);
    onState?.call(TunnelState.failed);
    return Future.error(
      const NodeFailure('all', 'Esgotadas as tentativas de rotação.'),
    );
  }

  /// Tenta uma única conexão com o par (SNI, proxy).
  Future<TunnelConnection> _tryConnect({
    required CarrierConfig carrier,
    required String sni,
    required ProxyNode proxy,
    required String sessionId,
    bool Function(TunnelSocket socket, String sni)? onUpgraded,
  }) async {
    final session = sessionId;
    final template = carrier.payloadTemplate;

    // Conecta ao proxy (TCP).
    final socket = await TunnelSocket.connectTcp(
      proxy.host,
      proxy.port,
      timeout: connectTimeout,
    );

    try {
      // Injeta o payload com a fragmentação (se o template tiver splits).
      if (template.isNotEmpty) {
        final segments = const PayloadParserEngine().segments(
          payload: template,
          host: sni,
          port: proxy.port,
          sessionId: session,
        );
        await socket.writeFragmentedLoop(segments, deadline: headerTimeout);
      }

      // Lê a resposta do proxy (200/101) — pode vir HTTP (proxy) ou direto.
      final header = await socket.readHeader(timeout: headerTimeout);
      final text = String.fromCharCodes(header);
      final firstLine = text.split('\r\n').first;

      final accepted = firstLine.contains(' 200 ') ||
          firstLine.contains(' 101 ') ||
          firstLine.contains('HTTP/1.1 101');
      if (!accepted) {
        socket.close();
        throw NodeFailure(
          proxy.key,
          'Proxy recusou payload (${firstLine.trim()})',
        );
      }

      // Chama o callback de autenticação (SSH etc.).
      var upgraded = true;
      final handler = onUpgraded;
      if (handler != null) {
        upgraded = handler(socket, sni);
      }
      if (!upgraded) {
        socket.close();
        throw NodeFailure(proxy.key, 'Autenticação falhou no socket');
      }

      return TunnelConnection(
        socket: socket,
        node: proxy,
        sni: sni,
        scheme: 'tcp+payload',
        sessionId: session,
      );
    } catch (error) {
      await socket.close();
      rethrow;
    }
  }

  // ------------------------- RTT probe / ordenação --------------------------

  Future<List<String>> _rankByLatency(List<String> snis) async {
    if (snis.length <= 1) return snis;

    // Probe em paralelo: mede o tempo de resolução do hostname.
    final results = await Future.wait(
      snis.map((sni) async {
        final sw = Stopwatch()..start();
        try {
          final addresses = await _doh.resolve(sni);
          if (addresses.isEmpty) {
            return (sni: sni, rtt: const Duration(days: 1));
          }
          sw.stop();
          return (sni: sni, rtt: sw.elapsed);
        } catch (_) {
          sw.stop();
          return (sni: sni, rtt: const Duration(days: 1));
        }
      }),
    );

    results.sort((a, b) => a.rtt.compareTo(b.rtt));
    return results.map((r) => r.sni).toList();
  }

  Future<List<ProxyNode>> _rankByLatencyProxies(List<ProxyNode> proxies) async {
    if (proxies.length <= 1) return proxies;

    final results = await Future.wait(
      proxies.map((node) async {
        final sw = Stopwatch()..start();
        try {
          final socket = await TunnelSocket.connectTcp(
            node.host,
            node.port,
            timeout: const Duration(seconds: 3),
          );
          await socket.close();
          sw.stop();
          return (node: node, rtt: sw.elapsed);
        } catch (_) {
          sw.stop();
          return (node: node, rtt: const Duration(days: 1));
        }
      }),
    );

    results.sort((a, b) => a.rtt.compareTo(b.rtt));
    return results.map((r) => r.node).toList();
  }

  /// Converte um `host:porta` em [ProxyNode].
  ProxyNode _parseProxy(String value) {
    final node = ProxyNode.parse(value);
    if (node == null) {
      throw FormatException('Proxy inválido: $value');
    }
    return node;
  }

  void _fail(String message) {
    debugPrint('[$TunnelConnectionManager] $message');
  }

  static String _uuidV4() {
    final rng = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Cancela o gerenciador (fecha streams e reseta o breaker).
  Future<void> dispose() async {
    await _stateController.close();
    await _progressController.close();
    _breaker.reset();
  }
}
