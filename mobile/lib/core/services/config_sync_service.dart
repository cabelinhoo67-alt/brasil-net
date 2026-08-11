import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../app_config.dart';
import '../models/network_config.dart';

/// Resultado de uma sincronizacao remota de configuracao.
@immutable
class ConfigSyncResult {
  const ConfigSyncResult._({
    required this.applied,
    required this.remoteVersion,
    required this.localVersion,
  });

  /// Resultado sintetico usado quando um sync ja esta em andamento
  /// (guard contra chamadas concorrentes ao [ConfigSyncService.sync]).
  static const ConfigSyncResult inFlight = ConfigSyncResult._(
    applied: false,
    remoteVersion: 0,
    localVersion: 0,
  );

  /// `true` quando uma configuracao nova foi aplicada (hot reload).
  final bool applied;

  /// Versao encontrada no servidor (0 quando indisponivel).
  final int remoteVersion;

  /// Versao ativa localmente antes do sync.
  final int localVersion;

  bool get hasUpdate => remoteVersion > localVersion;

  /// Sync aplicou uma config nova.
  bool get isUpdated => applied && hasUpdate;

  /// O app ja estava na versao mais recente.
  bool get isUpToDate => !applied && hasUpdate == false && remoteVersion > 0;

  /// O servidor nao foi alcancado (mas o cache/fallback continua valido).
  bool get isUnavailable => remoteVersion == 0;

  /// Mensagem legivel para SnackBar/Toast.
  String get message {
    if (isUnavailable) {
      return 'Nao foi possivel contactar o servidor de atualizacao.';
    }
    if (isUpdated) {
      return 'Payloads e servidores atualizados para a versao $remoteVersion!';
    }
    if (isUpToDate) {
      return 'Voce ja esta utilizando a versao mais recente ($remoteVersion).';
    }
    // Servidor respondeu, mas com versao igual ou inferior a ativa.
    return 'Configuracao local em dia (v$localVersion).';
  }
}

/// Camada de dados do Remote Control Plane.
///
/// Responsavel por:
///  1. Buscar o JSON de configuracao na URL remota (CDN/Worker/GitHub Raw).
///  2. Comparar a versao remota com a ativa localmente.
///  3. Persistir a nova configuracao no cache criptografado
///     ([NetworkConfigCache] via `flutter_secure_storage`).
///  4. Servir o fallback offline empacotado em assets para o primeiro boot.
///
/// Design: imutavel e stateless por construcao; todo o estado transiente vive
/// no [ConfigController] (ChangeNotifier). O unico estado persistido e o cache
/// criptografado, mantido pelo [NetworkConfigCache] existente.
class ConfigSyncService {
  ConfigSyncService({
    http.Client? client,
    NetworkConfigCache? cache,
    String? remoteUrl,
    String? assetPath,
  })  : _client = client ?? http.Client(),
        _cache = cache ?? NetworkConfigCache(),
        _remoteUrl = remoteUrl ?? AppConfig.configUrl,
        _assetPath = assetPath ?? AppConfig.assetConfigPath;

  final http.Client _client;
  final NetworkConfigCache _cache;
  final String _remoteUrl;
  final String _assetPath;

  /// Timeout por requisicao (rede movel ruim).
  static const _requestTimeout = Duration(seconds: 10);

  /// Carrega a configuracao ativa: cache local criptografado primeiro, e
  /// fallback para o asset empacotado no APK (primeiro boot / sem rede).
  ///
  /// Nunca lanca: qualquer falha de leitura resulta em `null` (fail-open) —
  /// o tunel usa a estrategia de resgate por conta propria nesse caso.
  Future<NetworkConfigModel?> loadActive() async {
    final cached = await _cache.read();
    if (cached != null) return cached.config;

    // Sem cache ainda (primeiro boot): usa o fallback embutido.
    final asset = await _loadAssetConfig();
    if (asset != null) {
      // Persiste o fallback para os proximos boots sem rede.
      await _cache.save(asset);
    }
    return asset;
  }

  /// Busca e aplica a configuracao remota mais recente.
  ///
  /// Compara a versao do JSON remoto com a ativa localmente (cache ou asset).
  /// So persiste e retorna `applied: true` quando a versao remota e
  /// ESTRITAMENTE superior — jamais regride para versoes antigas.
  ///
  /// [onApplied] e chamado com a config nova (hot reload) ANTES do retorno,
  /// permitindo injetar no [TunnelConnectionManager] sem reiniciar o app.
  Future<ConfigSyncResult> sync({
    void Function(NetworkConfigModel config)? onApplied,
  }) async {
    final local = await loadActive();
    final localVersion = local?.version ?? 0;

    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(_remoteUrl))
          .timeout(_requestTimeout);
    } catch (e) {
      debugPrint('[config_sync] fetch remoto falhou: $e');
      return ConfigSyncResult._(
        applied: false,
        remoteVersion: 0,
        localVersion: localVersion,
      );
    }

    if (response.statusCode != 200) {
      debugPrint('[config_sync] HTTP ${response.statusCode} em $_remoteUrl');
      return ConfigSyncResult._(
        applied: false,
        remoteVersion: 0,
        localVersion: localVersion,
      );
    }

    final NetworkConfigModel remote;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('JSON de config nao e um objeto');
      }
      remote = NetworkConfigModel.fromJson(decoded);
    } catch (e) {
      debugPrint('[config_sync] JSON invalido: $e');
      return ConfigSyncResult._(
        applied: false,
        remoteVersion: 0,
        localVersion: localVersion,
      );
    }

    // Regra do Remote Control Plane: so atualiza para versao SUPERIOR.
    if (remote.version <= localVersion) {
      return ConfigSyncResult._(
        applied: false,
        remoteVersion: remote.version,
        localVersion: localVersion,
      );
    }

    // Nova configuracao valida: persiste no cache criptografado.
    try {
      await _cache.save(remote);
    } catch (e) {
      debugPrint('[config_sync] falha ao persistir cache: $e');
      // Continua aplicando em memoria mesmo se a persistencia falhar.
    }

    onApplied?.call(remote);

    return ConfigSyncResult._(
      applied: true,
      remoteVersion: remote.version,
      localVersion: localVersion,
    );
  }

  /// Le o JSON fallback embutido nos assets. Retorna `null` se ausente/corrompido.
  Future<NetworkConfigModel?> _loadAssetConfig() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return NetworkConfigModel.fromJson(decoded);
    } catch (e) {
      debugPrint('[config_sync] asset fallback indisponivel: $e');
      return null;
    }
  }

  /// Libera o cliente HTTP (chamado pelo controller ao descartar).
  void dispose() {
    _client.close();
  }
}
