package br.com.tunnelsystem.app.tunnel

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Canal de utilidades do aparelho:
 *   - lista os apps instalados (para a tela de bypass)
 *   - dispara o instalador do Android sobre um APK baixado (OTA)
 *
 * Ambos precisam de codigo nativo: o PackageManager nao tem equivalente em Dart
 * puro, e a instalacao de APK exige um Intent com FileProvider.
 */
class DeviceChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "br.com.tunnelsystem/device"
    }

    private val channel = MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listInstalledApps" -> result.success(listInstalledApps(call.argument("withIcons") ?: false))
            "installApk" -> installApk(call.argument("path"), result)
            "packageInstalled" -> result.success(isInstalled(call.argument("package") ?: ""))
            "updateDir" -> result.success(updateDir().absolutePath)
            else -> result.notImplemented()
        }
    }

    /**
     * Apps que o usuario pode ver e escolher para bypass.
     *
     * Filtra os que tem tela de abertura (launcher): apps de servico e do
     * sistema puro so poluiriam a lista. Os icones sao opcionais e vao em
     * base64 PNG — carrega-los todos de uma vez pesa, entao a UI pede so quando
     * precisa.
     */
    private fun listInstalledApps(withIcons: Boolean): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launchables = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            0,
        )

        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any?>>()

        for (info in launchables) {
            val pkg = info.activityInfo.packageName
            if (pkg == context.packageName) continue // nao faz sentido bypassar a si mesmo
            if (!seen.add(pkg)) continue

            val appInfo = info.activityInfo.applicationInfo
            apps.add(
                mapOf(
                    "package" to pkg,
                    "name" to pm.getApplicationLabel(appInfo).toString(),
                    "system" to ((appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                    "icon" to if (withIcons) iconBase64(pm, appInfo) else null,
                ),
            )
        }

        apps.sortBy { (it["name"] as String).lowercase() }
        return apps
    }

    private fun iconBase64(pm: PackageManager, appInfo: ApplicationInfo): String? {
        return try {
            val drawable = pm.getApplicationIcon(appInfo)
            val size = 96
            val bitmap = android.graphics.Bitmap.createBitmap(
                size, size, android.graphics.Bitmap.Config.ARGB_8888,
            )
            val canvas = android.graphics.Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)

            val out = ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Pasta onde o OTA salva o APK. Fica no external cache — sem permissao de
     * armazenamento, limpavel pelo sistema — e casa com o `external-cache-path`
     * declarado no file_paths.xml do FileProvider.
     */
    private fun updateDir(): File {
        val dir = File(context.externalCacheDir ?: context.cacheDir, "updates")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun isInstalled(pkg: String): Boolean {
        if (pkg.isBlank()) return false
        return try {
            context.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Abre o instalador do sistema sobre o APK baixado pelo OTA.
     *
     * A partir do Android 7 nao se passa `file://` para outro app — o sistema
     * lanca FileUriExposedException. O FileProvider gera um `content://`
     * temporario e concede permissao de leitura ao instalador.
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "caminho do APK ausente", null)
            return
        }

        val file = File(path)
        if (!file.exists()) {
            result.error("NOT_FOUND", "APK nao encontrado em $path", null)
            return
        }

        try {
            val uri: Uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            context.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, null)
        }
    }
}
