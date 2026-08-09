import '../../models/models.dart';

/// Como o transporte ate o servidor deve ser montado.
enum TransportMode {
  /// TCP direto na porta SSH. Mais rapido, mas e o primeiro a ser barrado
  /// pelo portal cativo quando o chip esta sem saldo.
  direct,

  /// HTTP/1.1 CONNECT com payload customizado. Passa por proxy transparente
  /// de operadora que libera o metodo CONNECT.
  payload,

  /// TLS com SNI de bug host. A operadora ve um handshake para um dominio
  /// liberado (zero-rating) e nao intercepta.
  tlsSni,
}

/// Uma tentativa concreta de conexao.
class ConnectStrategy {
  const ConnectStrategy({
    required this.mode,
    required this.host,
    required this.port,
    this.payloadTemplate,
    this.sni,
    required this.label,
  });

  final TransportMode mode;
  final String host;
  final int port;
  final String? payloadTemplate;
  final String? sni;

  /// Texto curto para o log da tela — o usuario ve em que tentativa esta.
  final String label;
}

/// Monta a ordem de tentativas para um payload.
///
/// A ideia central: o modo escolhido no painel e a PRIMEIRA tentativa, nao a
/// unica. Se a operadora interceptar (302 de recarga), caimos para o proximo
/// modo silenciosamente, sem o usuario ver erro.
///
/// A ordem sobe em capacidade de evasao:
///   direto -> payload CONNECT -> TLS com SNI
class StrategyChain {
  const StrategyChain._();

  /// Bug hosts por operadora: dominios que costumam ficar fora da cobranca.
  ///
  /// Sao um ponto de partida — hosts de zero-rating mudam com frequencia, e o
  /// valor cadastrado no painel (payload.sni) sempre tem prioridade.
  static const _fallbackSni = <String, String>{
    'CLARO': 'www.claro.com.br',
    'VIVO': 'www.vivo.com.br',
    'TIM': 'www.tim.com.br',
    'OI': 'www.oi.com.br',
    'ALGAR': 'www.algartelecom.com.br',
    'VERO': 'www.vero.net.br',
  };

  /// Payload CONNECT padrao, usado quando o cadastro nao trouxe um proprio.
  static const _defaultPayload =
      'CONNECT [host_port] [protocol][crlf]Host: [host][crlf]'
      'Connection: Keep-Alive[crlf][crlf]';

  static List<ConnectStrategy> build({
    required Payload payload,
    required ServerInfo server,
    String? operatorCode,
  }) {
    final chain = <ConnectStrategy>[];

    final cadastrado = payload.content.trim();
    final template = cadastrado.isNotEmpty ? cadastrado : _defaultPayload;

    final sni = (payload.sni?.trim().isNotEmpty ?? false)
        ? payload.sni!.trim()
        : _fallbackSni[operatorCode?.toUpperCase() ?? ''] ?? server.host;

    final proxyHost = payload.proxyHost?.trim();
    final connectHost = (proxyHost != null && proxyHost.isNotEmpty) ? proxyHost : server.host;
    final proxyPort = payload.proxyPort ?? server.proxyPort;

    // 1) O modo do cadastro vem primeiro — respeita a escolha do operador.
    switch (payload.mode) {
      case 'SSH_SSL':
        chain.add(ConnectStrategy(
          mode: TransportMode.tlsSni,
          host: server.host,
          port: server.sslPort,
          sni: sni,
          payloadTemplate: cadastrado.isNotEmpty ? cadastrado : null,
          label: 'TLS/SNI $sni',
        ));
        break;
      case 'SSH_PAYLOAD':
        chain.add(ConnectStrategy(
          mode: TransportMode.payload,
          host: connectHost,
          port: proxyPort,
          payloadTemplate: template,
          label: 'payload via $connectHost:$proxyPort',
        ));
        break;
      default: // SSH_DIRECT e os demais
        chain.add(ConnectStrategy(
          mode: TransportMode.direct,
          host: server.host,
          port: server.sshPort,
          label: 'SSH direto',
        ));
    }

    // 2) Payload CONNECT — contorna o portal onde o direto morre.
    if (!chain.any((s) => s.mode == TransportMode.payload)) {
      chain.add(ConnectStrategy(
        mode: TransportMode.payload,
        host: connectHost,
        port: proxyPort,
        payloadTemplate: template,
        label: 'fallback: payload CONNECT',
      ));
    }

    // 3) TLS com SNI — ultima linha, a que mais disfarca o trafego.
    if (!chain.any((s) => s.mode == TransportMode.tlsSni)) {
      chain.add(ConnectStrategy(
        mode: TransportMode.tlsSni,
        host: server.host,
        port: server.sslPort,
        sni: sni,
        label: 'fallback: TLS/SNI $sni',
      ));
    }

    return chain;
  }
}
