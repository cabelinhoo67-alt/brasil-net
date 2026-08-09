import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Janela flutuante de status (overlay), controlada pelo Kotlin nativo.
///
/// `SYSTEM_ALERT_WINDOW` nao passa por dialogo de runtime — o usuario precisa
/// visitar uma tela propria do sistema. Por isso o fluxo e: pedir ->
/// `requestPermission` abre essa tela -> ao voltar ao app, [hasPermission]
/// confere se foi concedida.
class OverlayService {
  static const _channel = MethodChannel('br.com.tunnelsystem/overlay');

  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // fora do Android
    }
  }

  static Future<bool> show() async {
    try {
      await _channel.invokeMethod<void>('show');
      return true;
    } on PlatformException catch (e) {
      debugPrint('[overlay] show falhou: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hide');
    } catch (_) {
      // esconder algo que ja caiu nao e erro
    }
  }

  /// Atualiza o card em tempo real. Chamado a cada medicao de ping — barato
  /// o bastante para nao pesar mesmo em ciclo curto.
  static Future<void> update({required int pingMs, required String status}) async {
    try {
      await _channel.invokeMethod<void>('update', {
        'pingMs': pingMs,
        'status': status,
      });
    } catch (_) {
      // overlay pode ter sido fechado pelo usuario; ignora
    }
  }

  static Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } catch (_) {
      return false;
    }
  }
}
