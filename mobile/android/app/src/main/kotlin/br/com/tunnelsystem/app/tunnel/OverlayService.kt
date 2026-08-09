package br.com.tunnelsystem.app.tunnel

import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import br.com.tunnelsystem.app.MainActivity
import br.com.tunnelsystem.app.R
import kotlin.math.abs

/**
 * Janela flutuante de status — um card arrastavel sempre visivel por cima de
 * outros apps, mostrando ping em tempo real e o estado da conexao.
 *
 * Nao e um Foreground Service: `TYPE_APPLICATION_OVERLAY` ja mantem a view viva
 * sem exigir notificacao propria, e o [TunnelVpnService] e quem ja segura o
 * processo com sua propria notificacao persistente.
 */
class OverlayService : Service() {

    companion object {
        private const val TAG = "OverlayService"

        const val ACTION_UPDATE = "br.com.tunnelsystem.overlay.UPDATE"
        const val EXTRA_PING_MS = "pingMs"
        const val EXTRA_STATUS = "status" // "connected" | "connecting" | "reconnecting"

        /** Toque que se move menos que isto e tratado como clique, nao arraste. */
        private const val DRAG_SLOP_PX = 12

        @Volatile
        var isShowing = false
            private set
    }

    private var windowManager: WindowManager? = null
    private var rootView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var pingText: TextView? = null
    private var statusText: TextView? = null
    private var statusDot: View? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                val ping = intent.getIntExtra(EXTRA_PING_MS, -1)
                val status = intent.getStringExtra(EXTRA_STATUS) ?: "connecting"
                applyUpdate(ping, status)
                return START_NOT_STICKY
            }
            else -> {
                if (!isShowing) showOverlay()
                return START_NOT_STICKY
            }
        }
    }

    private fun showOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "sem permissao SYSTEM_ALERT_WINDOW; overlay nao sobe")
            stopSelf()
            return
        }

        try {
            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            windowManager = wm

            val view = LayoutInflater.from(this).inflate(R.layout.overlay_widget, null)
            rootView = view

            pingText = view.findViewById(R.id.overlay_ping)
            statusText = view.findViewById(R.id.overlay_status_text)
            statusDot = view.findViewById(R.id.overlay_status_dot)

            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = 24
                y = 140
            }
            layoutParams = params

            attachDragHandler(view, params, wm)
            wm.addView(view, params)
            isShowing = true
            Log.i(TAG, "overlay exibido")
        } catch (e: Exception) {
            Log.e(TAG, "falha ao exibir o overlay: ${e.message}")
            stopSelf()
        }
    }

    /**
     * Arraste manual via `onTouchEvent`, sem depender de biblioteca externa.
     * A distincao entre "arrastar" e "tocar para abrir o app" e pelo
     * deslocamento total: abaixo do slop, conta como clique.
     */
    private fun attachDragHandler(view: View, params: WindowManager.LayoutParams, wm: WindowManager) {
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var dragged = false

        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = event.rawX
                    touchY = event.rawY
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (!dragged && (abs(dx) > DRAG_SLOP_PX || abs(dy) > DRAG_SLOP_PX)) {
                        dragged = true
                    }
                    if (dragged) {
                        params.x = startX + dx
                        params.y = startY + dy
                        try {
                            wm.updateViewLayout(view, params)
                        } catch (e: Exception) {
                            Log.w(TAG, "updateViewLayout falhou: ${e.message}")
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) openApp()
                    true
                }
                else -> false
            }
        }
    }

    private fun openApp() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "nao consegui abrir o app: ${e.message}")
        }
    }

    private fun applyUpdate(pingMs: Int, status: String) {
        pingText?.text = if (pingMs >= 0) "$pingMs ms" else "-- ms"

        val (label, color) = when (status) {
            "connected" -> "Conectado" to 0xFF39FF14.toInt() // verde neon
            "reconnecting" -> "Reconectando..." to 0xFFFFD700.toInt() // ouro
            else -> "Conectando..." to 0xFFFFD700.toInt()
        }
        statusText?.text = label

        (statusDot?.background as? GradientDrawable)?.setColor(color)
            ?: run { statusDot?.setBackgroundColor(color) }
    }

    override fun onDestroy() {
        try {
            rootView?.let { windowManager?.removeView(it) }
        } catch (e: Exception) {
            Log.w(TAG, "erro ao remover a view: ${e.message}")
        }
        rootView = null
        windowManager = null
        isShowing = false
        super.onDestroy()
    }
}
