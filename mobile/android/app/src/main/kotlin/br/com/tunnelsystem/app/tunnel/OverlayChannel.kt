package br.com.tunnelsystem.app.tunnel

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Controle da janela flutuante de status pelo lado Dart.
 *
 * `SYSTEM_ALERT_WINDOW` nao e concedida por dialogo de runtime — o usuario
 * precisa passar por uma tela propria do sistema (`ACTION_MANAGE_OVERLAY_PERMISSION`).
 * Por isso `requestPermission` abre essa tela e o app confere o resultado
 * quando volta ao primeiro plano (`hasPermission`), em vez de esperar callback.
 */
class OverlayChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "br.com.tunnelsystem/overlay"
    }

    private val channel = MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(Settings.canDrawOverlays(activity))

            "requestPermission" -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${activity.packageName}"),
                )
                activity.startActivity(intent)
                result.success(null)
            }

            "show" -> {
                if (!Settings.canDrawOverlays(activity)) {
                    result.error("NO_PERMISSION", "Overlay nao autorizado", null)
                    return
                }
                activity.startService(Intent(activity, OverlayService::class.java))
                result.success(null)
            }

            "hide" -> {
                activity.stopService(Intent(activity, OverlayService::class.java))
                result.success(null)
            }

            "update" -> {
                val ping = call.argument<Int>("pingMs") ?: -1
                val status = call.argument<String>("status") ?: "connecting"

                if (!OverlayService.isShowing) {
                    // Overlay ainda nao subiu (ou foi fechado) — ignora silenciosamente.
                    result.success(null)
                    return
                }

                val intent = Intent(activity, OverlayService::class.java).apply {
                    action = OverlayService.ACTION_UPDATE
                    putExtra(OverlayService.EXTRA_PING_MS, ping)
                    putExtra(OverlayService.EXTRA_STATUS, status)
                }
                activity.startService(intent)
                result.success(null)
            }

            "isShowing" -> result.success(OverlayService.isShowing)

            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
