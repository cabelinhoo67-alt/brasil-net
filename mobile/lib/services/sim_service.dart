import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/models.dart';

/// Leitura do SIM Card via MethodChannel (ver MainActivity.kt).
///
/// Sem READ_PHONE_STATE o Android devolve string vazia em vez de erro,
/// por isso pedimos a permissao antes e tratamos o vazio como "nao detectado".
class SimService {
  static const _channel = MethodChannel('br.com.tunnelsystem/sim');

  /// Pede READ_PHONE_STATE. Retorna false se o usuario negou de vez.
  static Future<bool> ensurePermission() async {
    final status = await Permission.phone.status;
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) return false;

    final result = await Permission.phone.request();
    return result.isGranted;
  }

  static Future<bool> isPermanentlyDenied() async {
    return Permission.phone.status.isPermanentlyDenied;
  }

  static Future<void> openSettings() => openAppSettings();

  /// Le a operadora do chip ativo. Nunca lanca: devolve [SimInfo.empty].
  static Future<SimInfo> read() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getSimInfo');
      if (result == null) return SimInfo.empty;
      return SimInfo.fromMap(result);
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[SimService] falha ao ler o SIM: ${e.message}');
      return SimInfo.empty;
    } on MissingPluginException {
      // Roda em iOS/desktop, onde a ponte nativa nao existe.
      return SimInfo.empty;
    }
  }

  /// Dual SIM: usado na tela de selecao manual de chip.
  static Future<List<SimInfo>> readAll() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getSimList');
      if (result == null) return const [];
      return result
          .whereType<Map<dynamic, dynamic>>()
          .map(SimInfo.fromMap)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
