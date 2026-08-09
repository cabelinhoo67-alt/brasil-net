package br.com.tunnelsystem.app.tunnel

import android.util.Log
import java.io.File

/**
 * Ponte com o tun2socks — o unico pedaco nativo que este projeto NAO escreve.
 *
 * Motivo: converter pacotes IP crus da interface TUN em conexoes SOCKS5 exige
 * uma pilha TCP/IP completa em espaco de usuario. Escrever uma do zero seria
 * reimplementar um projeto inteiro; o certo e usar um pronto e testado.
 *
 * Usamos o hev-socks5-tunnel (licenca MIT), que expoe exatamente tres metodos
 * nativos. Veja `docs/TUNNEL.md` para o passo a passo de como adicionar a
 * biblioteca ao projeto Android.
 *
 * Se a .so nao estiver presente, [available] fica falso e o servico falha com
 * uma mensagem clara — nunca fingindo que conectou.
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

    // Assinaturas nativas do hev-socks5-tunnel (jni/hev-jni.c).
    private external fun TProxyStartService(configPath: String, fd: Int)
    private external fun TProxyStopService()
    private external fun TProxyGetStats(): LongArray

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
        TProxyStartService(config.absolutePath, fd)
    }

    fun stop() {
        if (!available) return
        try {
            TProxyStopService()
        } catch (e: Throwable) {
            Log.w(TAG, "erro ao parar tun2socks: ${e.message}")
        }
    }

    /** [bytesRecebidos, bytesEnviados] — usado para exibir trafego na tela. */
    fun stats(): LongArray = if (available) {
        try {
            TProxyGetStats()
        } catch (e: Throwable) {
            longArrayOf(0, 0)
        }
    } else {
        longArrayOf(0, 0)
    }

    private fun buildConfig(socksPort: Int, mtu: Int): String = """
        tunnel:
          mtu: $mtu
        socks5:
          address: 127.0.0.1
          port: $socksPort
          udp: 'udp'
        misc:
          task-stack-size: 20480
          log-level: warn
    """.trimIndent()
}
