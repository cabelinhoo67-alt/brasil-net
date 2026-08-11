import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Modelo imutavel da configuracao remota de rede (Remote Control Plane).
///
/// Deserializado de um JSON como o produzido pelo painel:
///
/// ```json
/// {
///   "version": 20260811,
///   "carriers": [
///     {
///       "name": "TIM",
///       "carrier_code": "72402",
///       "sni_hosts": ["meutim.tim.com.br", "m.ofertas.tim.com.br"],
///       "payload_template": "GET /seuid HTTP/1.1[crlf]Host: [host][crlf][crlf]",
///       "proxy_nodes": ["179.191.165.65:8080", "108.139.113.110:443"]
///     }
///   ]
/// }
/// ```
///
/// Todas as listas sao imutaveis ([List.unmodifiable]) e a desserializacao e
/// defensiva: uma operadora malformada e descartada individualmente em vez de
/// derrubar a configuracao inteira (fail-open).
@immutable
class NetworkConfigModel {
  NetworkConfigModel({
    required this.version,
    required List<CarrierConfig> carriers,
    this.meta,
  }) : carriers = List.unmodifiable(carriers);

  /// Numero da versao da configuracao (ex.: 20260811).
  final int version;

  /// Operadoras conhecidas, em ordem de prioridade.
  final List<CarrierConfig> carriers;

  /// Metadados opcionais livre (chaves extras do JSON, preservadas).
  final Map<String, dynamic>? meta;

  static final empty = NetworkConfigModel(version: 0, carriers: const []);

  /// Desserializacao defensiva: cada operadora e validada isoladamente e
  /// operadoras invalidas sao ignoradas sem abortar o parse do documento.
  factory NetworkConfigModel.fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    final version = rawVersion is num ? rawVersion.toInt() : 0;

    final carriers = <CarrierConfig>[];
    final rawCarriers = json['carriers'];
    if (rawCarriers is List) {
      for (final item in rawCarriers) {
        if (item is! Map) continue;
        try {
          final carrier = CarrierConfig.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (carrier.name.trim().isNotEmpty) carriers.add(carrier);
        } catch (_) {
          // Operadora malformada: pula, preserva as demais.
        }
      }
    }

    final meta = <String, dynamic>{
      for (final e in json.entries)
        if (e.key != 'version' && e.key != 'carriers') e.key: e.value,
    };

    return NetworkConfigModel(
      version: version,
      carriers: carriers,
      meta: meta.isEmpty ? null : Map.unmodifiable(meta),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'carriers': carriers.map((c) => c.toJson()).toList(),
        if (meta != null) ...meta!,
      };

  /// Operadora correspondente ao [carrierCode] (MCC/MNC ou nome). Retorna
  /// `null` se nao houver correspondencia.
  CarrierConfig? pickCarrier(String? carrierCode) {
    if (carrierCode == null || carrierCode.isEmpty) return null;
    final normalized = carrierCode.trim().toUpperCase();
    for (final carrier in carriers) {
      if (carrier.carrierCode == normalized ||
          carrier.name.toUpperCase() == normalized) {
        return carrier;
      }
    }
    return null;
  }

  /// Primeira operadora disponivel (fallback universal).
  CarrierConfig? get firstCarrier => carriers.isEmpty ? null : carriers.first;

  @override
  String toString() =>
      'NetworkConfigModel(version: $version, carriers: ${carriers.length})';
}

/// Operadora com suas rotas de conexao: SNIs de alta autoridade, template de
/// payload e nos proxy. Imutavel.
@immutable
class CarrierConfig {
  CarrierConfig({
    required this.name,
    this.carrierCode = '',
    List<String> sniHosts = const [],
    this.payloadTemplate = '',
    List<ProxyNode> proxyNodes = const [],
  })  : sniHosts = List.unmodifiable(sniHosts),
        proxyNodes = List.unmodifiable(proxyNodes);

  final String name;

  /// MCC/MNC da operadora (ex.: "72402" para TIM).
  final String carrierCode;

  /// Hosts/SNIs de alta autoridade, em ordem de prioridade.
  final List<String> sniHosts;

  /// Template de payload com marcadores (ex.: `GET /seuid HTTP/1.1[crlf]...`).
  final String payloadTemplate;

  /// Nos de proxy (host:porta) publicos/conhecidos.
  final List<ProxyNode> proxyNodes;

  factory CarrierConfig.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '') as String;
    final carrierCode = (json['carrier_code'] ?? json['carrierCode'] ?? '')
        as String;

    final snis = _stringList(json['sni_hosts'] ?? json['sniHosts']);

    final payloadTemplate =
        (json['payload_template'] ?? json['payloadTemplate'] ?? '') as String;

    final proxyNodes = <ProxyNode>[];
    final rawNodes = json['proxy_nodes'] ?? json['proxyNodes'];
    if (rawNodes is List) {
      for (final node in rawNodes) {
        try {
          if (node is String) {
            final proxy = ProxyNode.parse(node);
            if (proxy != null) proxyNodes.add(proxy);
          } else if (node is Map) {
            proxyNodes.add(
              ProxyNode.fromJson(Map<String, dynamic>.from(node)),
            );
          }
        } catch (_) {
          // No invalido: ignora.
        }
      }
    }

    return CarrierConfig(
      name: name,
      carrierCode: carrierCode,
      sniHosts: snis,
      payloadTemplate: payloadTemplate,
      proxyNodes: proxyNodes,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'carrier_code': carrierCode,
        'sni_hosts': sniHosts,
        'payload_template': payloadTemplate,
        'proxy_nodes': proxyNodes.map((n) => n.toJson()).toList(),
      };

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    final result = <String>[];
    for (final item in value) {
      final text = item?.toString().trim() ?? '';
      if (text.isNotEmpty && !result.contains(text)) result.add(text);
    }
    return List.unmodifiable(result);
  }

  @override
  String toString() => 'CarrierConfig($name, code: $carrierCode, '
      'snis: ${sniHosts.length}, proxies: ${proxyNodes.length})';
}

/// No de proxy TCP (host + porta). Imutavel.
@immutable
class ProxyNode {
  const ProxyNode(this.host, this.port);

  final String host;
  final int port;

  /// Chave unica usada pelo circuit breaker (por no, nao por tentativa).
  String get key => '$host:$port';

  String get hostPort => '$host:$port';

  /// Parse de "179.191.165.65:8080" (ou "host:porta"). Retorna `null` se
  /// invalido (porta fora de 1..65535, host vazio).
  static ProxyNode? parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final sep = trimmed.lastIndexOf(':');
    if (sep <= 0 || sep == trimmed.length - 1) return null;
    final host = trimmed.substring(0, sep).trim();
    final port = int.tryParse(trimmed.substring(sep + 1).trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return ProxyNode(host, port);
  }

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    final host = (json['host'] ?? json['hostname'] ?? '') as String;
    final port = (json['port'] is num) ? (json['port'] as num).toInt() : 0;
    if (host.trim().isEmpty || port < 1 || port > 65535) {
      throw const FormatException('ProxyNode invalido');
    }
    return ProxyNode(host.trim(), port);
  }

  Map<String, dynamic> toJson() => {'host': host, 'port': port};

  @override
  bool operator ==(Object other) => other is ProxyNode && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => hostPort;
}

/// Cache local criptografado da [NetworkConfigModel].
///
/// Usa `flutter_secure_storage` (Keystore/Keychain — AES-GCM no Android),
/// atendendo ao requisito de cache criptografado sem adicionar Hive/Isar ao
/// projeto. O TTL/cache e controlado por quem consome via [CachedNetworkConfig].
class NetworkConfigCache {
  NetworkConfigCache({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _configKey = 'network_config_v1';
  static const _savedAtKey = 'network_config_saved_at_v1';

  /// Persiste a configuracao criptografada.
  Future<void> save(NetworkConfigModel config) async {
    await _storage.write(key: _configKey, value: jsonEncode(config.toJson()));
    await _storage.write(
      key: _savedAtKey,
      value: DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Le a configuracao em cache. Retorna `null` se ausente ou corrompida.
  Future<CachedNetworkConfig?> read() async {
    try {
      final raw = await _storage.read(key: _configKey);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final config = NetworkConfigModel.fromJson(decoded);

      DateTime? savedAt;
      final rawSavedAt = await _storage.read(key: _savedAtKey);
      if (rawSavedAt != null) {
        savedAt = DateTime.tryParse(rawSavedAt)?.toLocal();
      }

      return CachedNetworkConfig(config: config, savedAt: savedAt);
    } catch (_) {
      return null;
    }
  }

  /// Remove a configuracao em cache (ex.: ao deslogar).
  Future<void> clear() async {
    await _storage.delete(key: _configKey);
    await _storage.delete(key: _savedAtKey);
  }
}

/// Configuracao em cache com a data em que foi salva (para decidir TTL).
@immutable
class CachedNetworkConfig {
  const CachedNetworkConfig({required this.config, this.savedAt});

  final NetworkConfigModel config;
  final DateTime? savedAt;

  /// Idade do cache (nulo quando `savedAt` ausente).
  Duration? get age {
    final saved = savedAt;
    return saved == null ? null : DateTime.now().difference(saved);
  }
}
