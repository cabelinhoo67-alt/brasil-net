package br.com.tunnelsystem.app.tunnel

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Liga o Dart a VpnService.
 *
 * `prepare` abre o dialogo de autorizacao do sistema (uma vez por instalacao)
 * e so responde ao Flutter depois que o usuario decide — por isso guardamos o
 * `MethodChannel.Result` ate o retorno da Activity.
 */
class VpnChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val REQUEST_CODE_PREPARE = 9701

        private const val METHOD_CHANNEL = "br.com.tunnelsystem/vpn"
        private const val EVENT_CHANNEL = "br.com.tunnelsystem/vpn_events"
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var events: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        // O servico roda em outro contexto; repassamos o estado para o Flutter
        // sempre na thread da UI, que e de onde o EventSink pode ser usado.
        TunnelVpnService.listener = { state ->
            activity.runOnUiThread { events?.success(state) }
        }
    }

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "start" -> start(call, result)
            "stop" -> stop(result)
            // Consulta os dois lados: o servico e o proprio motor nativo.
            "isRunning" -> result.success(TunnelVpnService.isRunning && Tun2Socks.isRunning())
            "stats" -> {
                val s = Tun2Socks.stats()
                result.success(
                    mapOf(
                        "rx" to (s.getOrNull(0) ?: 0L),
                        "tx" to (s.getOrNull(1) ?: 0L),
                    )
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)

        if (intent == null) {
            // Ja autorizada anteriormente.
            result.success(true)
            return
        }

        if (pendingPermission != null) {
            result.error("BUSY", "Ja existe um pedido de permissao em andamento", null)
            return
        }

        pendingPermission = result
        activity.startActivityForResult(intent, REQUEST_CODE_PREPARE)
    }

    /** Chamado pela MainActivity ao voltar do dialogo do sistema. */
    fun onPermissionResult(resultCode: Int) {
        pendingPermission?.success(resultCode == Activity.RESULT_OK)
        pendingPermission = null
    }

    private fun start(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val socksPort = call.argument<Int>("socksPort") ?: 0
        val sessionName = call.argument<String>("sessionName") ?: "Tunnel"

        if (socksPort <= 0) {
            result.error("BAD_ARGS", "socksPort invalido", null)
            return
        }

        if (VpnService.prepare(activity) != null) {
            result.error("NO_PERMISSION", "A VPN nao foi autorizada", null)
            return
        }

        if (!Tun2Socks.available) {
            result.error(
                "NO_TUN2SOCKS",
                "Motor tun2socks ausente no APK. Veja docs/TUNNEL.md.",
                Tun2Socks.loadError,
            )
            return
        }

        val intent = Intent(activity, TunnelVpnService::class.java).apply {
            action = TunnelVpnService.ACTION_START
            putExtra(TunnelVpnService.EXTRA_SOCKS_PORT, socksPort)
            putExtra(TunnelVpnService.EXTRA_SESSION_NAME, sessionName)
        }

        startService(activity, intent)
        result.success(null)
    }

    private fun stop(result: MethodChannel.Result) {
        val intent = Intent(activity, TunnelVpnService::class.java).apply {
            action = TunnelVpnService.ACTION_STOP
        }
        startService(activity, intent)
        result.success(null)
    }

    private fun startService(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    fun dispose() {
        TunnelVpnService.listener = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
