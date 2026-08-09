package br.com.tunnelsystem.app.tunnel

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Observa as trocas de rede do aparelho (Wi-Fi <-> dados moveis).
 *
 * Nao reconecta nada sozinho: apenas classifica o que aconteceu e avisa. Quem
 * decide reconectar e o lado Dart, porque e la que vive a sessao SSH — o
 * servico nativo nao tem como recria-la.
 *
 * O detalhe que evita falso positivo: durante um handover o Android entrega
 * `onAvailable` da rede nova ANTES do `onLost` da antiga. Reagir ao `onLost`
 * cru derrubaria o tunel bem no momento em que ele acabou de ganhar uma rota
 * valida. Por isso o `onLost` so vira evento depois de um debounce que confirma
 * que nao sobrou nenhuma rede utilizavel.
 */
class NetworkWatcher(
    private val context: Context,
    private val onEvent: (NetworkEvent) -> Unit,
) {

    enum class NetworkEvent {
        /** Perdeu todas as rotas: o socket vai quebrar, congele o trafego. */
        LOST,

        /** Rede nova disponivel apos perda: hora de reconectar. */
        AVAILABLE,

        /** Trocou de interface (ex.: Wi-Fi -> 4G) sem ficar offline. */
        CHANGED,
    }

    companion object {
        private const val TAG = "NetworkWatcher"

        /** Janela para o handover se completar antes de declarar queda. */
        private const val LOST_DEBOUNCE_MS = 2_500L
    }

    private val manager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())

    private var registered = false
    private var currentNetwork: Network? = null

    /** Marcado quando avisamos LOST; o proximo AVAILABLE vira reconexao. */
    private var offline = false

    private val pendingLost = Runnable {
        if (hasUsableNetwork()) {
            Log.d(TAG, "queda descartada: ainda ha rede utilizavel")
            return@Runnable
        }
        offline = true
        Log.w(TAG, "sem rede utilizavel -> LOST")
        onEvent(NetworkEvent.LOST)
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {

        override fun onAvailable(network: Network) {
            main.removeCallbacks(pendingLost)

            val previous = currentNetwork
            currentNetwork = network

            when {
                // Voltou depois de uma queda confirmada.
                offline -> {
                    offline = false
                    Log.i(TAG, "rede de volta -> AVAILABLE")
                    onEvent(NetworkEvent.AVAILABLE)
                }
                // Trocou de interface sem passar por offline (handover limpo).
                previous != null && previous != network -> {
                    Log.i(TAG, "interface trocada -> CHANGED")
                    onEvent(NetworkEvent.CHANGED)
                }
                else -> Log.d(TAG, "rede inicial registrada")
            }
        }

        override fun onLost(network: Network) {
            if (network != currentNetwork) {
                // Caiu uma rede secundaria; a nossa continua de pe.
                Log.d(TAG, "perda de rede secundaria, ignorada")
                return
            }
            // Debounce: o handover costuma entregar a rede nova logo em seguida.
            main.removeCallbacks(pendingLost)
            main.postDelayed(pendingLost, LOST_DEBOUNCE_MS)
        }
    }

    /** Ha alguma rede com internet validada no momento? */
    private fun hasUsableNetwork(): Boolean {
        return try {
            val active = manager.activeNetwork ?: return false
            val caps = manager.getNetworkCapabilities(active) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (e: Exception) {
            Log.w(TAG, "nao consegui inspecionar a rede: ${e.message}")
            false
        }
    }

    fun start() {
        if (registered) return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        try {
            manager.registerNetworkCallback(request, callback)
            currentNetwork = manager.activeNetwork
            registered = true
            Log.i(TAG, "monitorando trocas de rede")
        } catch (e: Exception) {
            // Nunca deixar o monitoramento derrubar o tunel.
            Log.e(TAG, "falha ao registrar o callback: ${e.message}")
        }
    }

    fun stop() {
        main.removeCallbacks(pendingLost)
        if (!registered) return
        try {
            manager.unregisterNetworkCallback(callback)
        } catch (e: Exception) {
            Log.w(TAG, "falha ao desregistrar: ${e.message}")
        }
        registered = false
        currentNetwork = null
        offline = false
    }
}
