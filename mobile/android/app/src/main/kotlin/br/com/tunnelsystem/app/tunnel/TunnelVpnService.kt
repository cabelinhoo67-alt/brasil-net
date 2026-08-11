package br.com.tunnelsystem.app.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import br.com.tunnelsystem.app.MainActivity
import br.com.tunnelsystem.app.R
import java.net.InetAddress
import java.net.Socket

/**
 * VpnService que roteia o trafego do aparelho para o tunel.
 *
 * Caminho dos pacotes:
 *
 *   apps do celular -> interface TUN -> tun2socks -> SOCKS5 em 127.0.0.1
 *      -> canal SSH (Dart) -> servidor VPS -> internet
 *
 * Detalhe que evita o erro classico: `addDisallowedApplication(packageName)`
 * tira o proprio app do tunel. Sem isso, a conexao SSH que sustenta a VPN
 * seria roteada para dentro da propria VPN e o trafego se morderia.
 */
class TunnelVpnService : VpnService() {

    companion object {
        private const val TAG = "TunnelVpnService"

        const val ACTION_START = "br.com.tunnelsystem.vpn.START"
        const val ACTION_STOP = "br.com.tunnelsystem.vpn.STOP"
        const val ACTION_REBIND = "br.com.tunnelsystem.vpn.REBIND"

        const val EXTRA_SOCKS_PORT = "socksPort"
        const val EXTRA_SESSION_NAME = "sessionName"
        const val EXTRA_BYPASS_PACKAGES = "bypassPackages"

        private const val CHANNEL_ID = "tunnel_vpn"
        private const val NOTIFICATION_ID = 4242

        private const val MTU = 8500
        private const val TUN_ADDRESS = "10.111.222.2"
        private const val TUN_PREFIX = 32

        /** Verde neon do design system, usado no acento da notificacao. */
        private const val NEON_GREEN = 0xFF39FF14.toInt()

        // DNS publico: o DNS da operadora costuma nao responder dentro do tunel.
        private val DNS_SERVERS = listOf("1.1.1.1", "8.8.8.8")

        @Volatile
        var isRunning: Boolean = false
            private set

        /** Notifica o Flutter sobre mudancas de estado (setado pelo VpnChannel). */
        @Volatile
        var listener: ((String) -> Unit)? = null

        /** Ultima porta SOCKS usada — necessaria para o restart do START_STICKY. */
        @Volatile
        private var lastSocksPort: Int = 0
    }

    private var tunInterface: ParcelFileDescriptor? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var watcher: NetworkWatcher? = null
    private var sessionLabel: String = "Tunnel"

    /** Trafego congelado durante uma troca de rede; nao e desconexao. */
    @Volatile
    private var paused = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        }

        // Reconexao: o Dart refez o SSH e quer apontar o tun2socks para a porta
        // nova, mantendo a mesma interface TUN.
        if (intent?.action == ACTION_REBIND) {
            rebind(intent.getIntExtra(EXTRA_SOCKS_PORT, 0))
            return START_STICKY
        }

        // O Android 8+ exige startForeground() em ate ~5s apos o servico ser
        // criado por startForegroundService(). Se qualquer checagem abaixo
        // lancar excecao (ex.: lib tun2socks ausente), o processo morreria com
        // "did not then call Service.startForeground()". Chamar aqui, antes de
        // qualquer codigo que possa falhar, elimina a corrida — a notificacao
        // ja fica de pe e o fluxo normal a atualiza via startForegroundCompat().
        startForegroundCompat(intent?.getStringExtra(EXTRA_SESSION_NAME) ?: "Tunnel")

        // intent == null significa que o Android matou o processo e recriou o
        // servico pelo START_STICKY. A sessao SSH vive no isolate Dart, que
        // morreu junto — subir a TUN agora criaria um buraco negro que engole
        // o trafego do aparelho. Em vez disso, checamos se o SOCKS sobreviveu.
        if (intent == null) return recoverFromStickyRestart()

        val socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, 0)
        val sessionName = intent.getStringExtra(EXTRA_SESSION_NAME) ?: "Tunnel"
        val bypass = intent.getStringArrayListExtra(EXTRA_BYPASS_PACKAGES) ?: arrayListOf()

        if (socksPort <= 0) {
            fail("Porta SOCKS invalida.")
            return START_NOT_STICKY
        }

        return try {
            startTunnel(socksPort, sessionName, bypass)
            // START_STICKY: o sistema recria o servico se matar o processo por
            // memoria. A recuperacao acima trata o caso do Dart nao voltar.
            START_STICKY
        } catch (e: Throwable) {
            fail(e.message ?: "Falha ao iniciar a VPN")
            START_NOT_STICKY
        }
    }

    /**
     * Recria o tunel apos o sistema ter matado o processo — mas so se o lado
     * Dart ainda estiver de pe (o Flutter pode ter sobrevivido em background).
     *
     * Sem essa checagem, a TUN subiria apontando para um SOCKS inexistente e o
     * usuario ficaria sem internet nenhuma, achando que esta "conectado". Falhar
     * limpo e melhor: o app reconecta sozinho quando voltar ao primeiro plano.
     */
    private fun recoverFromStickyRestart(): Int {
        val port = lastSocksPort
        Log.w(TAG, "servico recriado pelo sistema (socks=$port)")

        if (port <= 0 || !isSocksAlive(port)) {
            Log.w(TAG, "SOCKS local nao respondeu; encerrando em vez de subir tunel morto")
            listener?.invoke("needs_reconnect")
            stopTunnel()
            return START_NOT_STICKY
        }

        return try {
            startTunnel(port, "Tunnel", arrayListOf())
            Log.i(TAG, "tunel restaurado apos restart do sistema")
            START_STICKY
        } catch (e: Throwable) {
            fail(e.message ?: "Falha ao restaurar a VPN")
            START_NOT_STICKY
        }
    }

    /** O servidor SOCKS do Dart ainda aceita conexao? */
    private fun isSocksAlive(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 1500)
            true
        }
    } catch (e: Exception) {
        false
    }

    private fun startTunnel(socksPort: Int, sessionName: String, bypassPackages: List<String>) {
        if (!Tun2Socks.available) {
            throw IllegalStateException(
                "Motor tun2socks ausente no APK. Veja docs/TUNNEL.md (${Tun2Socks.loadError})."
            )
        }

        startForegroundCompat(sessionName)

        val builder = Builder()
            .setSession(sessionName)
            .setMtu(MTU)
            .addAddress(TUN_ADDRESS, TUN_PREFIX)
            // Rota padrao: tudo entra no tunel...
            .addRoute("0.0.0.0", 0)

        DNS_SERVERS.forEach { builder.addDnsServer(InetAddress.getByName(it)) }

        applyDisallowed(builder, bypassPackages)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val descriptor = builder.establish()
            ?: throw IllegalStateException("A permissao de VPN foi revogada.")

        tunInterface = descriptor

        Tun2Socks.start(
            cacheDir = cacheDir,
            fd = descriptor.fd,
            socksPort = socksPort,
            mtu = MTU,
        )

        lastSocksPort = socksPort
        isRunning = true
        paused = false

        acquireWakeLock()
        startWatchingNetwork()

        listener?.invoke("connected")
        Log.i(TAG, "VPN ativa (socks=$socksPort)")
    }

    // ------------------------- resiliencia de rede ---------------------------

    /**
     * Doze Mode suspende o CPU e mata sockets ociosos. O wake lock parcial
     * mantem o processo vivo com a tela apagada — que e justamente quando o
     * usuario deixa o tunel rodando.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "brasilnet:tunnel",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
            Log.d(TAG, "wake lock adquirido")
        } catch (e: Exception) {
            // Sem wake lock o tunel ainda funciona; so fica mais sujeito ao Doze.
            Log.w(TAG, "wake lock indisponivel: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "erro ao liberar wake lock: ${e.message}")
        }
        wakeLock = null
    }

    private fun startWatchingNetwork() {
        if (watcher != null) return
        watcher = NetworkWatcher(this) { event ->
            // Qualquer excecao aqui nao pode derrubar o servico.
            try {
                handleNetworkEvent(event)
            } catch (e: Throwable) {
                Log.e(TAG, "erro tratando evento de rede: ${e.message}")
            }
        }.also { it.start() }
    }

    /**
     * O nativo nao reconecta sozinho: ele congela o trafego e avisa o Dart,
     * que e quem detem a sessao SSH e sabe refaze-la com backoff.
     */
    private fun handleNetworkEvent(event: NetworkWatcher.NetworkEvent) {
        if (!isRunning) return

        when (event) {
            NetworkWatcher.NetworkEvent.LOST -> {
                if (paused) return
                paused = true
                // Parar o tun2socks evita que ele fique escrevendo num socket
                // morto — origem das SocketException/EOFException em cascata.
                Tun2Socks.stop()
                updateNotification("Sem rede — aguardando conexao")
                listener?.invoke("network_lost")
                Log.w(TAG, "rede perdida: trafego congelado")
            }

            NetworkWatcher.NetworkEvent.AVAILABLE,
            NetworkWatcher.NetworkEvent.CHANGED -> {
                updateNotification("Reconectando...")
                // O Dart refaz o SSH e chama start() de novo com a porta nova.
                listener?.invoke("network_available")
                Log.i(TAG, "rede disponivel: pedindo reconexao ao Dart")
            }
        }
    }

    /**
     * Reata o tun2socks a uma porta SOCKS nova, sem derrubar a interface TUN.
     * Manter o mesmo fd e o que torna o handover imperceptivel: os apps nao
     * veem a interface sumir.
     */
    fun rebind(socksPort: Int) {
        val descriptor = tunInterface
        if (descriptor == null || socksPort <= 0) {
            Log.w(TAG, "rebind ignorado (tun=${descriptor != null}, porta=$socksPort)")
            return
        }

        try {
            Tun2Socks.stop()
            Tun2Socks.start(
                cacheDir = cacheDir,
                fd = descriptor.fd,
                socksPort = socksPort,
                mtu = MTU,
            )
            lastSocksPort = socksPort
            paused = false
            updateNotification(null)
            listener?.invoke("connected")
            Log.i(TAG, "tun2socks reatado na porta $socksPort")
        } catch (e: Throwable) {
            Log.e(TAG, "rebind falhou: ${e.message}")
            listener?.invoke("needs_reconnect")
        }
    }

    /**
     * Split tunneling: tira do tunel o proprio app e os pacotes do bypass.
     *
     * `addDisallowedApplication` lanca PackageManager.NameNotFoundException
     * quando o pacote nao esta instalado — e o motorista raramente tem TODOS os
     * apps da lista. Sem o try-catch por item, um unico app ausente aborta o
     * `establish()` e o tunel inteiro nao sobe. Por isso cada pacote e aplicado
     * isoladamente: os que existem entram, os que faltam sao ignorados.
     */
    private fun applyDisallowed(builder: Builder, bypassPackages: List<String>) {
        // O proprio app SEMPRE fica de fora, senao a conexao SSH que sustenta a
        // VPN seria roteada para dentro dela mesma (loop).
        val targets = LinkedHashSet<String>().apply {
            add(packageName)
            addAll(bypassPackages)
        }

        var applied = 0
        for (pkg in targets) {
            if (pkg.isBlank()) continue
            try {
                builder.addDisallowedApplication(pkg)
                applied++
            } catch (e: PackageManager.NameNotFoundException) {
                // App nao instalado neste aparelho — normal, so ignora.
                Log.d(TAG, "bypass ignorado (nao instalado): $pkg")
            } catch (e: Exception) {
                Log.w(TAG, "bypass falhou para $pkg: ${e.message}")
            }
        }
        Log.i(TAG, "split tunneling: $applied de ${targets.size} pacote(s) fora do tunel")
    }

    private fun stopTunnel() {
        if (!isRunning && tunInterface == null) return

        // Cada etapa em seu try-catch: uma falha de I/O aqui nao pode impedir
        // a liberacao das outras (wake lock preso vaza bateria).
        try { watcher?.stop() } catch (e: Exception) { Log.w(TAG, "watcher: ${e.message}") }
        watcher = null

        try { Tun2Socks.stop() } catch (e: Throwable) { Log.w(TAG, "tun2socks: ${e.message}") }

        try {
            tunInterface?.close()
        } catch (e: Exception) {
            Log.w(TAG, "erro ao fechar TUN: ${e.message}")
        }
        tunInterface = null

        releaseWakeLock()

        isRunning = false
        paused = false
        lastSocksPort = 0

        listener?.invoke("disconnected")

        stopForegroundCompat()
        stopSelf()
        Log.i(TAG, "VPN encerrada")
    }

    private fun fail(message: String) {
        Log.e(TAG, message)
        listener?.invoke("error:$message")
        stopTunnel()
    }

    /** O sistema mata a VPN quando o usuario revoga a permissao ou troca de VPN. */
    override fun onRevoke() {
        Log.w(TAG, "permissao de VPN revogada pelo sistema")
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    // --------------------------- notificacao ---------------------------------

    // NotificationChannel e API 26; o minSdk do app e 21, entao o canal so e
    // criado quando existe de verdade. O NotificationCompat cuida do resto em
    // versoes antigas (ignora o canal e usa os campos legados do Builder).
    private fun startForegroundCompat(sessionName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Conexao VPN",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Mostra o status do tunel enquanto ele esta ativo"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        sessionLabel = sessionName
        val notification = buildNotification(null)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Notificacao persistente e irremovivel.
     *
     * `setOngoing` impede o swipe; `FLAG_NO_CLEAR` sobrevive ao "limpar tudo".
     * Sem ela o Android trata o processo como descartavel e o OOM killer o
     * derruba nas trocas de rede — exatamente quando o tunel mais precisa viver.
     *
     * @param status texto de estado; null volta ao "conectado".
     */
    private fun buildNotification(status: String?): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // `android.R.drawable.stat_sys_vpn_ic` parece o icone certo, mas e um
        // recurso interno da plataforma e nao existe no SDK publico.
        //
        // FLAG_NO_CLEAR e propriedade do Notification construido, nao do
        // Builder — por isso e aplicada depois do build(), nao encadeada nele.
        //
        // NotificationCompat.Builder funciona em qualquer API: em >= 26 usa o
        // canal; em versoes antigas cai para os campos legados (importancia,
        // prioridade), que e exatamente o que o app antigo (minSdk 26) fazia.
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(status ?: "Tunel conectado")
            .setContentText(sessionLabel)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setColor(NEON_GREEN)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

        notification.flags = notification.flags or Notification.FLAG_NO_CLEAR
        return notification
    }

    private fun updateNotification(status: String?) {
        try {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(status))
        } catch (e: Exception) {
            Log.w(TAG, "nao consegui atualizar a notificacao: ${e.message}")
        }
    }

    private fun stopForegroundCompat() {
        // STOP_FOREGROUND_REMOVE (API 24); em versoes antigas o stopForeground
        // sem argumentos remove a notificacao por padrao.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
