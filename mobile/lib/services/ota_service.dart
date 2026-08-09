import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_config.dart';
import 'device_service.dart';

/// Informacao de atualizacao vinda do backend (GET /api/app/version).
class UpdateInfo {
  const UpdateInfo({
    required this.available,
    required this.mandatory,
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.changelog,
    required this.sizeBytes,
  });

  final bool available;
  final bool mandatory;
  final String version;
  final int build;
  final String apkUrl;
  final String changelog;
  final int sizeBytes;

  /// Changelog em linhas, para virar bullets no modal.
  List<String> get changelogLines =>
      changelog.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final latest = (json['latest'] as Map<String, dynamic>?) ?? const {};
    return UpdateInfo(
      available: (json['updateAvailable'] ?? false) as bool,
      mandatory: (json['mandatory'] ?? false) as bool,
      version: (latest['version'] ?? '') as String,
      build: (latest['build'] ?? 0) as int,
      apkUrl: (latest['apkUrl'] ?? '') as String,
      changelog: (latest['changelog'] ?? '') as String,
      sizeBytes: (latest['sizeBytes'] ?? 0) as int,
    );
  }
}

enum OtaPhase { idle, checking, available, downloading, installing, done, error }

/// Motor OTA: checa versao, baixa o APK com progresso e dispara a instalacao.
///
/// Mantido separado do AppState para poder rodar independente do login — a
/// checagem acontece no ciclo de vida do app, nao so quando ha sessao.
class OtaService extends ChangeNotifier {
  OtaService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  OtaPhase _phase = OtaPhase.idle;
  UpdateInfo? _update;
  double _progress = 0;
  String? _error;
  int _currentBuild = 0;
  CancelToken? _cancel;

  OtaPhase get phase => _phase;
  UpdateInfo? get update => _update;
  double get progress => _progress;
  String? get error => _error;

  bool get hasUpdate => _update?.available ?? false;

  void _set(OtaPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  Future<int> _readCurrentBuild() async {
    if (_currentBuild > 0) return _currentBuild;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      _currentBuild = 0;
    }
    return _currentBuild;
  }

  /// Consulta o backend. Silenciosa: falha de rede nunca deve atrapalhar o app.
  Future<void> check({bool silent = true}) async {
    // Nao reabre o fluxo se ja estamos baixando/instalando.
    if (_phase == OtaPhase.downloading || _phase == OtaPhase.installing) return;

    _set(OtaPhase.checking);
    try {
      final build = await _readCurrentBuild();
      final base = AppConfig.apiUrl.replaceAll(RegExp(r'/$'), '');

      final response = await _dio.get(
        '$base/api/app/version',
        queryParameters: {'build': build},
        options: Options(receiveTimeout: const Duration(seconds: 15)),
      );

      final info = UpdateInfo.fromJson(Map<String, dynamic>.from(response.data as Map));
      _update = info;
      _set(info.available ? OtaPhase.available : OtaPhase.idle);
    } catch (e) {
      debugPrint('[ota] check falhou: $e');
      _update = null;
      if (!silent) {
        _error = 'Nao consegui verificar atualizacoes.';
        _set(OtaPhase.error);
      } else {
        _set(OtaPhase.idle);
      }
    }
  }

  /// Baixa o APK para o cache e, ao completar, abre o instalador.
  Future<void> downloadAndInstall() async {
    final info = _update;
    if (info == null || info.apkUrl.isEmpty) return;

    _progress = 0;
    _error = null;
    _set(OtaPhase.downloading);

    try {
      final dir = await DeviceService.updateDir();
      final file = '$dir/tunnel-app-${info.build}.apk';

      // Remove um download parcial de tentativa anterior.
      final existing = File(file);
      if (await existing.exists()) await existing.delete();

      _cancel = CancelToken();
      await _dio.download(
        info.apkUrl,
        file,
        cancelToken: _cancel,
        options: Options(receiveTimeout: const Duration(minutes: 5)),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _progress = received / total;
            notifyListeners();
          }
        },
      );

      _progress = 1;
      _set(OtaPhase.installing);

      // O sistema assume a instalacao; o modal se fecha na UI.
      await DeviceService.installApk(file);
      _set(OtaPhase.done);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _set(OtaPhase.available); // usuario cancelou; volta a oferecer
        return;
      }
      debugPrint('[ota] download falhou: $e');
      _error = 'Falha ao baixar a atualizacao. Verifique sua conexao.';
      _set(OtaPhase.error);
    } catch (e) {
      debugPrint('[ota] instalacao falhou: $e');
      _error = 'Baixou, mas nao consegui abrir o instalador.';
      _set(OtaPhase.error);
    }
  }

  void cancelDownload() {
    _cancel?.cancel('cancelado pelo usuario');
  }

  /// Fecha o modal sem instalar (so quando a atualizacao nao e obrigatoria).
  void dismiss() {
    if (_update?.mandatory ?? false) return;
    _set(OtaPhase.idle);
  }
}
