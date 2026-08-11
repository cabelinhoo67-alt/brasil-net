/// Dados brutos lidos do chip pela ponte nativa (MainActivity.kt).
class SimInfo {
  const SimInfo({
    required this.operatorName,
    required this.mccMnc,
    required this.hasSim,
    this.networkName = '',
    this.countryIso = '',
    this.simState = 'UNKNOWN',
    this.isRoaming = false,
  });

  final String operatorName;
  final String networkName;
  final String mccMnc;
  final String countryIso;
  final String simState;
  final bool hasSim;
  final bool isRoaming;

  static const empty = SimInfo(operatorName: '', mccMnc: '', hasSim: false);

  factory SimInfo.fromMap(Map<dynamic, dynamic> map) => SimInfo(
        operatorName: (map['operatorName'] ?? '') as String,
        networkName: (map['networkName'] ?? '') as String,
        mccMnc: (map['mccMnc'] ?? '') as String,
        countryIso: (map['countryIso'] ?? '') as String,
        simState: (map['simState'] ?? 'UNKNOWN') as String,
        hasSim: (map['hasSim'] ?? false) as bool,
        isRoaming: (map['isRoaming'] ?? false) as bool,
      );
}

/// Operadora reconhecida pelo backend a partir do SimInfo.
class OperatorInfo {
  const OperatorInfo({
    required this.code,
    required this.name,
    required this.detected,
    this.logoUrl,
  });

  final String? code;
  final String name;
  final bool detected;
  final String? logoUrl;

  static const unknown = OperatorInfo(code: null, name: 'Nao detectada', detected: false);

  factory OperatorInfo.fromJson(Map<String, dynamic> json) => OperatorInfo(
        code: json['code'] as String?,
        name: (json['name'] ?? 'Desconhecida') as String,
        detected: (json['detected'] ?? false) as bool,
        logoUrl: json['logoUrl'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'code': code, 'name': name, 'detected': detected, 'logoUrl': logoUrl};
}

class ServerInfo {
  const ServerInfo({
    required this.id,
    required this.name,
    required this.host,
    required this.sshPort,
    required this.sslPort,
    required this.proxyPort,
  });

  final String id;
  final String name;
  final String host;
  final int sshPort;
  final int sslPort;
  final int proxyPort;

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        sshPort: (json['sshPort'] ?? 22) as int,
        sslPort: (json['sslPort'] ?? 443) as int,
        proxyPort: (json['proxyPort'] ?? 80) as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'sshPort': sshPort,
        'sslPort': sslPort,
        'proxyPort': proxyPort,
      };
}

/// Configuracao de conexao. O backend so envia payloads da operadora do chip.
class Payload {
  const Payload({
    required this.id,
    required this.name,
    required this.mode,
    required this.content,
    this.sni,
    this.proxyHost,
    this.proxyPort,
    this.dnsHost,
    this.publicKey,
    this.server,
    this.extra = const {},
  });

  final String id;
  final String name;
  final String mode;
  final String content;
  final String? sni;
  final String? proxyHost;
  final int? proxyPort;
  final String? dnsHost;
  final String? publicKey;
  final ServerInfo? server;
  final Map<String, dynamic> extra;

  factory Payload.fromJson(Map<String, dynamic> json) => Payload(
        id: json['id'] as String,
        name: json['name'] as String,
        mode: (json['mode'] ?? 'SSH_PAYLOAD') as String,
        content: (json['content'] ?? '') as String,
        sni: json['sni'] as String?,
        proxyHost: json['proxyHost'] as String?,
        proxyPort: json['proxyPort'] as int?,
        dnsHost: json['dnsHost'] as String?,
        publicKey: json['publicKey'] as String?,
        server: json['server'] == null
            ? null
            : ServerInfo.fromJson(json['server'] as Map<String, dynamic>),
        extra: (json['extra'] as Map<String, dynamic>?) ?? const {},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode,
        'content': content,
        'sni': sni,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'dnsHost': dnsHost,
        'publicKey': publicKey,
        'server': server?.toJson(),
        'extra': extra,
      };

  String get modeLabel => switch (mode) {
        'SSH_DIRECT' => 'SSH Direto',
        'SSH_PAYLOAD' => 'SSH + Payload',
        'SSH_SSL' => 'SSH + SSL/TLS',
        'V2RAY' => 'V2Ray',
        'SLOWDNS' => 'SlowDNS',
        'UDP' => 'UDP Custom',
        _ => mode,
      };
}

class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.connectionLimit,
    this.fullName,
    this.expiresAt,
    this.daysLeft,
    this.planName,
  });

  final String id;
  final String username;
  final String? fullName;
  final DateTime? expiresAt;
  final int? daysLeft;
  final int connectionLimit;
  final String? planName;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: (json['id'] ?? '') as String,
        username: json['username'] as String,
        fullName: json['fullName'] as String?,
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.tryParse(json['expiresAt'] as String),
        daysLeft: json['daysLeft'] as int?,
        connectionLimit: (json['connectionLimit'] ?? 1) as int,
        planName: (json['plan'] as Map<String, dynamic>?)?['name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'fullName': fullName,
        'expiresAt': expiresAt?.toIso8601String(),
        'daysLeft': daysLeft,
        'connectionLimit': connectionLimit,
        'plan': planName == null ? null : {'name': planName},
      };
}

enum ConnectionStatus { disconnected, connecting, connected, error }

extension ConnectionStatusX on ConnectionStatus {
  String get label => switch (this) {
        ConnectionStatus.disconnected => 'Desconectado',
        ConnectionStatus.connecting => 'Conectando...',
        ConnectionStatus.connected => 'Conectado',
        ConnectionStatus.error => 'Falha na conexao',
      };

  bool get isBusy => this == ConnectionStatus.connecting;
  bool get isOnline => this == ConnectionStatus.connected;
}
