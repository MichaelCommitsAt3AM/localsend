package org.localsend.localsend_app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** OS package validation supplements the verified GitHub asset digest. */
object AppUpdateChannel {
    private const val CHANNEL = "org.localsend.localsend_app/updater"
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    fun detach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(null)
    }
    fun attach(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "validateApk") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path")
            if (path == null || !busy.compareAndSet(false, true)) { result.error("BUSY", "APK validation is unavailable", null); return@setMethodCallHandler }
            executor.execute {
                try {
                    val file = File(path).canonicalFile
                    val roots = listOf(app.filesDir.canonicalPath, app.cacheDir.canonicalPath)
                    require(roots.any { file.path.startsWith("$it/") } && file.isFile && file.name.endsWith(".apk")) { "Update must be in private app storage" }
                    @Suppress("DEPRECATION")
                    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                    @Suppress("DEPRECATION")
                    val candidate = app.packageManager.getPackageArchiveInfo(file.path, flags) ?: error("Invalid APK")
                    @Suppress("DEPRECATION")
                    val current = app.packageManager.getPackageInfo(app.packageName, flags)
                    require(candidate.packageName == app.packageName) { "This APK belongs to a different app/build. Debug and release builds require matching packages." }
                    @Suppress("DEPRECATION")
                    val newCode = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode else candidate.versionCode.toLong()
                    @Suppress("DEPRECATION")
                    val oldCode = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()
                    require(newCode > oldCode) { "The APK version code must be newer than the installed build" }
                    @Suppress("DEPRECATION")
                    val candidateSigners = if (Build.VERSION.SDK_INT >= 28) candidate.signingInfo?.apkContentsSigners else candidate.signatures
                    @Suppress("DEPRECATION")
                    val currentSigners = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
                    require(!candidateSigners.isNullOrEmpty() && !currentSigners.isNullOrEmpty() && candidateSigners.toSet() == currentSigners.toSet()) { "APK signing certificate does not match. Keep the same release signing key." }
                    Handler(Looper.getMainLooper()).post { result.success(null) }
                } catch (error: Exception) {
                    Handler(Looper.getMainLooper()).post { result.error("INVALID_UPDATE", error.message ?: "APK validation failed", null) }
                } finally { busy.set(false) }
            }
        }
    }
}
