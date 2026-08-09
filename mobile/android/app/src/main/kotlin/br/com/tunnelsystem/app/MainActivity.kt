package br.com.tunnelsystem.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import br.com.tunnelsystem.app.tunnel.DeviceChannel
import br.com.tunnelsystem.app.tunnel.OverlayChannel
import br.com.tunnelsystem.app.tunnel.VpnChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Ponte nativa do app: leitura do SIM Card e controle da VpnService.
 *
 * SIM: o Flutter chama "getSimInfo" e recebe os dados da operadora ativa.
 * O MCC/MNC (networkOperator) e o dado confiavel — o carrierName vem sujo em
 * MVNOs ("Claro BR", "TIM BRASIL", "VIVO S.A."). Requer READ_PHONE_STATE.
 *
 * VPN: delegada ao [VpnChannel], que fala com a TunnelVpnService.
 */
class MainActivity : FlutterActivity() {

    private val simChannel = "br.com.tunnelsystem/sim"
    private var vpnChannel: VpnChannel? = null
    private var overlayChannel: OverlayChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, simChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSimInfo" -> result.success(readSimInfo())
                "getSimList" -> result.success(readAllSims())
                else -> result.notImplemented()
            }
        }

        vpnChannel = VpnChannel(this, messenger)
        DeviceChannel(this, messenger)
        overlayChannel = OverlayChannel(this, messenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VpnChannel.REQUEST_CODE_PREPARE) {
            vpnChannel?.onPermissionResult(resultCode)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        vpnChannel?.dispose()
        vpnChannel = null
        overlayChannel?.dispose()
        overlayChannel = null
        super.onDestroy()
    }

    // ------------------------------- SIM CARD --------------------------------

    /** Dados do chip usado para dados moveis (o que importa para o tunel). */
    private fun readSimInfo(): Map<String, Any?> {
        val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager

        // simOperator = MCC+MNC do chip; networkOperator = da rede registrada.
        // Em roaming os dois divergem, entao mandamos os dois ao backend.
        val simOperator = safe { tm.simOperator } ?: ""
        val networkOperator = safe { tm.networkOperator } ?: ""

        val simState = when (safe { tm.simState }) {
            TelephonyManager.SIM_STATE_READY -> "READY"
            TelephonyManager.SIM_STATE_ABSENT -> "ABSENT"
            TelephonyManager.SIM_STATE_PIN_REQUIRED -> "PIN_REQUIRED"
            TelephonyManager.SIM_STATE_PUK_REQUIRED -> "PUK_REQUIRED"
            TelephonyManager.SIM_STATE_NETWORK_LOCKED -> "NETWORK_LOCKED"
            else -> "UNKNOWN"
        }

        return mapOf(
            "operatorName" to (safe { tm.simOperatorName }?.takeIf { it.isNotBlank() }
                ?: safe { tm.networkOperatorName } ?: ""),
            "networkName" to (safe { tm.networkOperatorName } ?: ""),
            "mccMnc" to simOperator.ifBlank { networkOperator },
            "networkMccMnc" to networkOperator,
            "countryIso" to (safe { tm.simCountryIso } ?: ""),
            "simState" to simState,
            "hasSim" to (simState == "READY"),
            "isRoaming" to (safe { tm.isNetworkRoaming } ?: false)
        )
    }

    /**
     * Dual SIM: lista todos os chips ativos.
     * Usado na tela de configuracao quando o usuario quer forcar um chip.
     */
    private fun readAllSims(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return listOf(readSimInfo())
        }

        val sm = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
            ?: return listOf(readSimInfo())

        val list = safe { sm.activeSubscriptionInfoList } ?: return listOf(readSimInfo())

        return list.map { info ->
            mapOf(
                "slotIndex" to info.simSlotIndex,
                "subscriptionId" to info.subscriptionId,
                "operatorName" to (info.carrierName?.toString() ?: ""),
                "mccMnc" to buildMccMnc(info),
                "countryIso" to (info.countryIso ?: ""),
                "displayName" to (info.displayName?.toString() ?: "")
            )
        }
    }

    private fun buildMccMnc(info: android.telephony.SubscriptionInfo): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "${info.mccString ?: ""}${info.mncString ?: ""}"
        } else {
            @Suppress("DEPRECATION")
            "${info.mcc}${String.format("%02d", info.mnc)}"
        }
    }

    /**
     * A leitura do SIM lanca SecurityException quando a permissao foi negada
     * e IllegalStateException em alguns aparelhos sem modem ativo.
     * Aqui devolvemos null e deixamos o Dart tratar como "operadora nao detectada".
     */
    private fun <T> safe(block: () -> T): T? = try {
        block()
    } catch (e: SecurityException) {
        null
    } catch (e: Exception) {
        null
    }
}
