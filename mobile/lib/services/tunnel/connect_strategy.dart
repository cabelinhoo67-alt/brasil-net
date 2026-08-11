import '../../models/models.dart';

/// Como o transporte ate o servidor deve ser montado.
enum TransportMode {
  /// TCP direto na porta SSH. Mais rapido, mas e o primeiro a ser barrado
  /// pelo portal cativo quando o chip esta sem saldo.
  direct,

  /// HTTP/1.1 CONNECT com payload customizado. Passa por proxy transparente
  /// de operadora que libera o metodo CONNECT (com ou sem upgrade).
  payload,

  /// TLS com SNI de bug host. A operadora ve um handshake para um dominio
  /// liberado (zero-rating) e nao intercepta.
  tlsSni,

  /// SSH tunelado dentro de um WebSocket (wss://) contra o dominio real,
  /// com certificado valido. E o fallback mais dificil de qualquer operadora
  /// bloquear sem quebrar HTTPS comum — o trafego parece uma conexao HTTPS
  /// normal ao dominio ate o upgrade de protocolo (101 Switching Protocols).
  webSocket,
}

/// Uma tentativa concreta de conexao.
class ConnectStrategy {
  const ConnectStrategy({
    required this.mode,
    required this.host,
    required this.port,
    this.payloadTemplate,
    this.sni,
    this.wsUrl,
    this.wsHeaders = const {},
    required this.label,
  });

  final TransportMode mode;
  final String host;
  final int port;
  final String? payloadTemplate;
  final String? sni;

  /// Endpoint wss:// usado quando `mode == webSocket`.
  final String? wsUrl;

  /// Headers HTTP extras no handshake do WebSocket (camuflagem de navegador).
  /// O runtime ja envia `Connection: Upgrade`/`Upgrade: websocket` sozinho.
  final Map<String, dynamic> wsHeaders;

  /// Texto curto para o log da tela — o usuario ve em que tentativa esta.
  final String label;
}

/// Perfil de rotas de uma operadora: SNIs de alta autoridade, payloads
/// otimizados e endpoints WebSocket. Tudo listado em ordem de prioridade.
class OperatorProfile {
  const OperatorProfile({
    required this.code,
    required this.snis,
    this.payloads = const [],
    this.wsUrls = const [],
  });

  final String code;
  final List<String> snis;
  final List<String> payloads;
  final List<String> wsUrls;
}

/// Monta a ordem de tentativas para um payload.
///
/// A ideia central: o modo escolhido no painel e a PRIMEIRA tentativa, nao a
/// unica. Depois vem uma rotacao agressiva por TODAS as rotas conhecidas da
/// operadora — variantes de payload CONNECT, depois TLS com cada SNI de alta
/// autoridade, e por fim o WebSocket seguro. A cadeia inteira e percorrida em
/// loop pelo SshTunnelService ate obter o handshake de sucesso.
class StrategyChain {
  const StrategyChain._();

  /// SNI de fallback universal quando a operadora nao e reconhecida.
  static const _genericSnis = <String>[
    'www.google.com',
    'www.googleapis.com',
    'www.gstatic.com',
    'android.clients.google.com',
    'www.whatsapp.com',
    'www.instagram.com',
    'www.cloudflare.com',
    'www.netflix.com',
  ];

  /// Perfis por operadora. SNIs prioritarios primeiro: o dominio oficial da
  /// operadora (zero-rating) e depois dominios globais de alta autoridade que
  /// dificilmente entram em blocklist (Google, Meta/WhatsApp, Cloudflare,
  /// streaming). Se um for bloqueado, o proximo da lista e tentado.
  static const _profiles = <String, OperatorProfile>{
    'CLARO': OperatorProfile(
      code: 'CLARO',
      snis: <String>[
        'www.claro.com.br',
        'claro.com.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'android.clients.google.com',
        'www.whatsapp.com',
        'www.instagram.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
    'VIVO': OperatorProfile(
      code: 'VIVO',
      snis: <String>[
        'www.vivo.com.br',
        'vivo.com.br',
        'www.telefonica.com.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'www.whatsapp.com',
        'www.instagram.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
    'TIM': OperatorProfile(
      code: 'TIM',
      snis: <String>[
        'www.tim.com.br',
        'tim.com.br',
        'app.tim.com.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'www.whatsapp.com',
        'www.instagram.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
    'OI': OperatorProfile(
      code: 'OI',
      snis: <String>[
        'www.oi.com.br',
        'oi.com.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'www.whatsapp.com',
        'www.instagram.com',
        'www.cloudflare.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
    'ALGAR': OperatorProfile(
      code: 'ALGAR',
      snis: <String>[
        'www.algartelecom.com.br',
        'algartelecom.com.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'www.whatsapp.com',
        'www.instagram.com',
        'www.cloudflare.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
    'VERO': OperatorProfile(
      code: 'VERO',
      snis: <String>[
        'www.vero.net.br',
        'vero.net.br',
        'www.google.com',
        'www.googleapis.com',
        'www.gstatic.com',
        'www.whatsapp.com',
        'www.instagram.com',
        'www.cloudflare.com',
      ],
      payloads: _optimizedPayloads,
      wsUrls: _wsEndpoints,
    ),
  };

  /// Payload CONNECT padrao, usado quando o cadastro nao trouxe um proprio.
  static const _defaultPayload =
      'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf]'
      'Connection: Keep-Alive[crlf]Proxy-Connection: Keep-Alive[crlf][crlf]';

  /// Variante com upgrade explícito: sinaliza ao proxy que o tunel quer
  /// promover a conexao para WebSocket. Usada em operadoras que so liberam
  /// trafego com `Connection: Upgrade`.
  static const _upgradePayload =
      'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf]'
      'Connection: Upgrade[crlf]Upgrade: websocket[crlf]'
      'Proxy-Connection: Keep-Alive[crlf][crlf]';

  /// Variante com Keep-Alive explícito e parametrizado (estabilidade).
  static const _keepAlivePayload =
      'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf]'
      'Connection: Keep-Alive[crlf]'
      'Keep-Alive: timeout=60, max=500[crlf]'
      'Proxy-Connection: Keep-Alive[crlf][crlf]';

  /// Variante GET + upgrade (metodo liberado por operadoras que barram o
  /// CONNECT, ex.: TIM antiga). O proxy a promove com 101 Switching Protocols.
  /// Usa [host_port] (e nao [raw]) porque o PayloadParser renderiza [raw] com
  /// o metodo fixo "CONNECT" — o que geraria "GET CONNECT ..." invalido.
  static const _getUpgradePayload =
      'GET [host_port] HTTP/1.1[crlf]Host: [host][crlf]'
      'Connection: Upgrade[crlf]Upgrade: websocket[crlf]'
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]'
      'Sec-WebSocket-Version: 13[crlf][crlf]';

  /// Todas as variantes otimizadas, na ordem de tentativa.
  static const _optimizedPayloads = <String>[
    _defaultPayload,
    _upgradePayload,
    _keepAlivePayload,
    _getUpgradePayload,
  ];

  /// Bridge WebSocket->SSH mantido no servidor, atras do mesmo dominio e
  /// certificado do painel — nao depende de payload cadastrado nem de bug
  /// host, entao serve de fallback universal para qualquer operadora.
  static const _wsEndpoints = <String>[
    'wss://brasilnetpro.click/tun',
  ];

  /// Headers de camuflagem de navegador para o handshake WebSocket.
  static const _wsHeaders = <String, dynamic>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36',
    'Origin': 'https://brasilnetpro.click',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  /// Limite de SNIs TLS por operadora, para a cadeia nao explodir em dezenas
  /// de tentativas. O loop de rotacao cobre as demais em outra rodada.
  static const _maxSnis = 8;

  static List<ConnectStrategy> build({
    required Payload payload,
    required ServerInfo server,
    String? operatorCode,
  }) {
    final chain = <ConnectStrategy>[];

    final cadastrado = payload.content.trim();
    final template = cadastrado.isNotEmpty ? cadastrado : _defaultPayload;

    final opCode = operatorCode?.toUpperCase() ?? '';
    final profile = _profiles[opCode];

    // SNIs em ordem de prioridade: o cadastrado no painel, depois o perfil da
    // operadora, por fim o host do servidor como ultimo recurso.
    final snis = <String>{
      if (payload.sni?.trim().isNotEmpty ?? false) payload.sni!.trim(),
      if (profile != null) ...profile.snis,
      if (profile == null) ..._genericSnis,
      server.host,
    }.take(_maxSnis).toList();

    // Payloads: o cadastrado primeiro, depois as variantes otimizadas do
    // perfil, e o padrao por ultimo.
    final payloads = <String>{
      if (cadastrado.isNotEmpty) cadastrado,
      if (profile != null) ...profile.payloads,
      _defaultPayload,
    }.toList();

    final wsUrls = <String>{
      if (profile != null) ...profile.wsUrls,
      ..._wsEndpoints,
    }.toList();

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
          sni: snis.first,
          payloadTemplate: cadastrado.isNotEmpty ? cadastrado : null,
          label: 'TLS/SNI ${snis.first}',
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

    // 2) Rotacao de payloads CONNECT — todas as variantes otimizadas.
    for (final p in payloads) {
      chain.add(ConnectStrategy(
        mode: TransportMode.payload,
        host: connectHost,
        port: proxyPort,
        payloadTemplate: p,
        label: 'payload CONNECT',
      ));
    }

    // 3) Rotacao TLS/SNI — um SNI por tentativa, em ordem de prioridade.
    //    Se o modo escolhido ja foi SSH_SSL, o primeiro SNI ja foi tentado.
    final tlsSnis = payload.mode == 'SSH_SSL' ? snis.skip(1) : snis;
    for (final s in tlsSnis) {
      chain.add(ConnectStrategy(
        mode: TransportMode.tlsSni,
        host: server.host,
        port: server.sslPort,
        sni: s,
        label: 'TLS/SNI $s',
      ));
    }

    // 4) WebSocket contra o dominio real — a ultima linha, a mais dificil de
    //    bloquear sem quebrar HTTPS comum. Nao depende do payload cadastrado.
    for (final url in wsUrls) {
      chain.add(ConnectStrategy(
        mode: TransportMode.webSocket,
        host: 'brasilnetpro.click',
        port: 443,
        wsUrl: url,
        wsHeaders: _wsHeaders,
        label: 'WebSocket seguro ($url)',
      ));
    }

    return chain;
  }
}
