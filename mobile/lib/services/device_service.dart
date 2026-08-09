import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App instalado no aparelho, exibido na tela de bypass.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.name,
    required this.isSystem,
    this.icon,
  });

  final String packageName;
  final String name;
  final bool isSystem;
  final Uint8List? icon;

  factory InstalledApp.fromMap(Map<dynamic, dynamic> map) {
    final iconB64 = map['icon'] as String?;
    return InstalledApp(
      packageName: (map['package'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      isSystem: (map['system'] ?? false) as bool,
      icon: iconB64 == null ? null : base64Decode(iconB64),
    );
  }
}

/// Ponte com o [DeviceChannel] nativo: apps instalados e instalacao de APK.
class DeviceService {
  static const _channel = MethodChannel('br.com.tunnelsystem/device');

  /// Lista os apps com tela de abertura. `withIcons` pesa — so peca quando a
  /// tela realmente vai desenhar os icones.
  static Future<List<InstalledApp>> listInstalledApps({bool withIcons = true}) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'listInstalledApps',
        {'withIcons': withIcons},
      );
      return (result ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map(InstalledApp.fromMap)
          .toList(growable: false);
    } on PlatformException catch (e) {
      debugPrint('[device] listInstalledApps falhou: ${e.message}');
      return const [];
    } on MissingPluginException {
      return const []; // fora do Android
    }
  }

  static Future<bool> isInstalled(String packageName) async {
    try {
      return await _channel.invokeMethod<bool>('packageInstalled', {'package': packageName}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Diretorio onde o OTA salva o APK (external cache/updates).
  static Future<String> updateDir() async {
    final dir = await _channel.invokeMethod<String>('updateDir');
    return dir ?? '';
  }

  /// Abre o instalador do Android sobre o APK baixado.
  static Future<void> installApk(String path) async {
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }
}
