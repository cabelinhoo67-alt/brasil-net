package br.com.tunnelsystem.app.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import br.com.tunnelsystem.app.MainActivity
import br.com.tunnelsystem.app.R
import java.net.InetAddress

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

        const val EXTRA_SOCKS_PORT = "socksPort"
        const val EXTRA_SESSION_NAME = "sessionName"

        private const val CHANNEL_ID = "tunnel_vpn"
        private const val NOTIFICATION_ID = 4242

        private const val MTU = 8500
        private const val TUN_ADDRESS = "10.111.222.2"
        private const val TUN_PREFIX = 32

        // DNS publico: o DNS da operadora costuma nao responder dentro do tunel.
        private val DNS_SERVERS = listOf("1.1.1.1", "8.8.8.8")

        @Volatile
        var isRunning: Boolean = false
            private set

        /** Notifica o Flutter sobre mudancas de estado (setado pelo VpnChannel). */
        @Volatile
        var listener: ((String) -> Unit)? = null
    }

    private var tunInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
        }

        val socksPort = intent?.getIntExtra(EXTRA_SOCKS_PORT, 0) ?: 0
        val sessionName = intent?.getStringExtra(EXTRA_SESSION_NAME) ?: "Tunnel"

        if (socksPort <= 0) {
            fail("Porta SOCKS invalida.")
            return START_NOT_STICKY
        }

        return try {
            startTunnel(socksPort, sessionName)
            // START_STICKY faria o Android recriar o servico sem a sessao SSH
            // do lado Dart — o tunel voltaria quebrado. Melhor nao ressuscitar.
            START_NOT_STICKY
        } catch (e: Throwable) {
            fail(e.message ?: "Falha ao iniciar a VPN")
            START_NOT_STICKY
        }
    }

    private fun startTunnel(socksPort: Int, sessionName: String) {
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

        // ...menos o proprio app, que precisa falar direto com a VPS.
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
            Log.w(TAG, "nao consegui excluir o proprio app do tunel: ${e.message}")
        }

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

        isRunning = true
        listener?.invoke("connected")
        Log.i(TAG, "VPN ativa (socks=$socksPort)")
    }

    private fun stopTunnel() {
        if (!isRunning && tunInterface == null) return

        Tun2Socks.stop()

        try {
            tunInterface?.close()
        } catch (e: Exception) {
            Log.w(TAG, "erro ao fechar TUN: ${e.message}")
        }
        tunInterface = null
        isRunning = false

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

    // minSdk do app e 26, entao NotificationChannel e o Builder com canal
    // estao sempre disponiveis — sem guarda de versao aqui.
    private fun startForegroundCompat(sessionName: String) {
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

        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        // Icone da propria aplicacao. `android.R.drawable.stat_sys_vpn_ic`
        // parece o icone certo, mas e um recurso interno da plataforma e nao
        // existe no SDK publico — usa-lo nao compila.
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Tunel conectado")
            .setContentText(sessionName)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()

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

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
    }
}
