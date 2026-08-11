import 'package:flutter/foundation.dart';

import '../../../../core/models/network_config.dart';
import '../../../../core/services/config_sync_service.dart';

/// Ciclo de vida da sincronizacao remota de configuracao.
///
/// Reativo: a UI observa [ConfigController] via `ChangeNotifierProvider` e
/// reage aos estados abaixo (botoes, spinners e SnackBars).
enum ConfigPhase {
  /// Estado inicial: nenhuma sincronizacao foi tentada ainda.
  idle,

  /// Buscando atualizacoes no servidor remoto.
  checking,

  /// Sucesso: uma configuracao nova foi baixada e aplicada (hot reload).
  updated,

  /// Sucesso: o app ja esta na versao mais recente.
  upToDate,

  /// Falha de rede ou JSON invalido.
  error,
}

/// Controller (ChangeNotifier) do Remote Control Plane.
///
/// Esconde a logica do [ConfigSyncService] da UI e expoe:
///  - [phase]: estado reativo atual.
///  - [lastResult]: ultimo [ConfigSyncResult] (para mensagens de feedback).
///  - [activeConfig]: configuracao ativa em memoria (hot reload).
///  - [check]: dispara a sincronizacao (manual ou silenciosa no boot).
///
/// O [onApplied] passado no construtor permite injetar a config nova no
/// [TunnelConnectionManager] ativo sem reiniciar o app.
class ConfigController extends ChangeNotifier {
  ConfigController({
    ConfigSyncService? service,
    this.onApplied,
  }) : _service = service ?? ConfigSyncService();

  final ConfigSyncService _service;

  /// Callback de hot reload: chamado com a config nova quando uma versao
  /// superior e baixada. Normalmente injeta no `TunnelConnectionManager`.
  final void Function(NetworkConfigModel config)? onApplied;

  ConfigPhase _phase = ConfigPhase.idle;
  ConfigSyncResult? _lastResult;
  NetworkConfigModel? _activeConfig;
  bool _disposed = false;

  /// Estado reativo atual da sincronizacao.
  ConfigPhase get phase => _phase;

  /// Ultimo resultado (mensagem de feedback para SnackBar).
  ConfigSyncResult? get lastResult => _lastResult;

  /// Configuracao ativa em memoria (inicializada no primeiro check/boot).
  NetworkConfigModel? get activeConfig => _activeConfig;

  /// Versao ativa (para exibir na UI quando disponivel).
  int get activeVersion => _activeConfig?.version ?? 0;

  /// `true` enquanto uma sincronizacao esta em andamento.
  bool get isChecking => _phase == ConfigPhase.checking;

  void _set(ConfigPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  /// Sincroniza com o servidor remoto.
  ///
  /// [silent] = `true` no boot: falhas nao poluem a UI (fica em [ConfigPhase.idle]
  /// quando a rede falha silenciosamente). Chamadas manuais (botao) usam
  /// `silent: false` para expor o erro ao usuario.
  Future<ConfigSyncResult> check({bool silent = false}) async {
    // Evita sincronizacoes concorrentes.
    if (_phase == ConfigPhase.checking) {
      return _lastResult ?? ConfigSyncResult.inFlight;
    }

    _set(ConfigPhase.checking);

    final result = await _service.sync(
      onApplied: (config) {
        _activeConfig = config;
        // Hot reload: injeta no gerenciador de conexoes ativo.
        onApplied?.call(config);
      },
    );

    _lastResult = result;

    if (result.isUnavailable) {
      _set(silent ? ConfigPhase.idle : ConfigPhase.error);
    } else if (result.isUpdated) {
      _set(ConfigPhase.updated);
    } else if (result.isUpToDate) {
      _set(ConfigPhase.upToDate);
    } else {
      // Servidor respondeu com versao igual/inferior — trata como em dia.
      _set(ConfigPhase.upToDate);
    }

    return result;
  }

  /// Carrega a configuracao ativa do cache/asset (sem tocar na rede).
  /// Chamado no boot para inicializar [_activeConfig] antes do primeiro sync.
  Future<void> loadActive() async {
    final config = await _service.loadActive();
    if (config != null) _activeConfig = config;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _service.dispose();
    super.dispose();
  }
}
