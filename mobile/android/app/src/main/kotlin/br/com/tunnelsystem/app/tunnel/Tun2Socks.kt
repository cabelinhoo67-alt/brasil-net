package br.com.tunnelsystem.app.tunnel

import android.util.Log
import hev.htproxy.TProxyService
import java.io.File

/**
 * Ponte com o hev-socks5-tunnel (MIT) — a pilha TCP/IP em espaco de usuario
 * que converte os pacotes IP crus da interface TUN em conexoes SOCKS5.
 *
 * A `.so` e compilada a partir do fonte pelo NDK; veja `docs/TUNNEL.md`. Os
 * metodos nativos em si vivem em [TProxyService], cujo pacote e nome sao
 * ditados pela biblioteca e nao podem mudar.
 *
 * Se a `.so` nao estiver no APK, [available] fica falso e o servico falha com
 * mensagem clara — nunca fingindo que conectou.
 */
object Tun2Socks {

    private const val TAG = "Tun2Socks"

    var available: Boolean = false
        private set

    var loadError: String? = null
        private set

    init {
        try {
            System.loadLibrary("hev-socks5-tunnel")
            available = true
        } catch (e: UnsatisfiedLinkError) {
            available = false
            loadError = e.message
            Log.w(TAG, "libhev-socks5-tunnel.so ausente: ${e.message}")
        }
    }

    /**
     * @param fd descritor da interface TUN entregue pela VpnService
     * @param socksPort porta do SOCKS5 local levantado pelo Dart
     */
    fun start(cacheDir: File, fd: Int, socksPort: Int, mtu: Int) {
        check(available) {
            "Biblioteca tun2socks nao encontrada. Siga docs/TUNNEL.md para inclui-la no build."
        }

        val config = File(cacheDir, "tun2socks.yaml")
        config.writeText(buildConfig(socksPort, mtu))

        Log.i(TAG, "iniciando tun2socks fd=$fd socks=127.0.0.1:$socksPort")

        // Devolve false quando ja ha uma sessao rodando ou o config e invalido.
        val ok = TProxyService.TProxyStartService(config.absolutePath, fd)
        check(ok) { "tun2socks recusou iniciar; confira ${config.absolutePath}" }
    }

    fun stop() {
        if (!available) return
        try {
            TProxyService.TProxyStopService()
        } catch (e: Throwable) {
            Log.w(TAG, "erro ao parar tun2socks: ${e.message}")
        }
    }

    fun isRunning(): Boolean = if (available) {
        try {
            TProxyService.TProxyIsRunning()
        } catch (e: Throwable) {
            false
        }
    } else {
        false
    }

    /** [bytesRecebidos, bytesEnviados] — usado para exibir trafego na tela. */
    fun stats(): LongArray = if (available) {
        try {
            TProxyService.TProxyGetStats()
        } catch (e: Throwable) {
            longArrayOf(0, 0)
        }
    } else {
        longArrayOf(0, 0)
    }

    /**
     * O `tunnel.name` e omitido de proposito: com a interface entregue por fd,
     * a lib usa o descritor e nao tenta criar uma TUN propria. Os enderecos
     * casam com os da VpnService.Builder.
     */
    private fun buildConfig(socksPort: Int, mtu: Int): String = """
        tunnel:
          mtu: $mtu
          ipv4: 10.111.222.2
        socks5:
          address: 127.0.0.1
          port: $socksPort
          udp: 'udp'
        misc:
          task-stack-size: 20480
          log-level: warn
    """.trimIndent()
}
