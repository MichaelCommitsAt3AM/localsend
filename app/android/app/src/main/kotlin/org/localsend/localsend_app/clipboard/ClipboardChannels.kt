package org.localsend.localsend_app.clipboard

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.lang.ref.WeakReference
import com.journeyapps.barcodescanner.ScanOptions
import com.journeyapps.barcodescanner.ScanIntentResult

/** UI glue only. The service owns capture and cached-engine lifetime. */
object ClipboardChannels {
    var notificationDevices = ClipboardNotificationDevices(emptyList(), 0); private set
    var retainingEngine = false
    private const val NOTIFICATION_REQUEST = 4501
    private const val SCAN_REQUEST = 4503
    private const val PHOTO_REQUEST = 4504
    private var photoResult: MethodChannel.Result? = null
    private var scanResult: MethodChannel.Result? = null
    private var activity = WeakReference<Activity>(null)
    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var permissionListener: Shizuku.OnRequestPermissionResultListener? = null

    fun attach(engine: FlutterEngine, host: Activity) {
        activity = WeakReference(host)
        val application = host.applicationContext
        EventChannel(engine.dartExecutor.binaryMessenger, "org.localsend.localsend_app/clipboard_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    ClipboardSyncService.instance?.refreshCaptureStatus()
                }
                override fun onCancel(arguments: Any?) { sink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.localsend.localsend_app/clipboard")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "scanPairingQr" -> {
                            val host = activity.get()
                            if (host == null || scanResult != null) {
                                result.error("SCAN_UNAVAILABLE", "QR scanner is unavailable", null)
                            } else {
                                val options = ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                    .setCaptureActivity(PairingCaptureActivity::class.java)
                                    .setPrompt(call.argument<String>("prompt") ?: "Scan a LocalSend pairing QR code")
                                    .setBeepEnabled(false).setBarcodeImageEnabled(false).setOrientationLocked(true)
                                scanResult = result
                                host.startActivityForResult(options.createScanIntent(host), SCAN_REQUEST)
                            }
                        }
                        "loadSecret" -> result.success(ClipboardSecrets.load(application))
                        "saveSecret" -> {
                            ClipboardSecrets.save(application, call.argument<String>("value") ?: error("Missing identity data"))
                            result.success(null)
                        }
                        "status" -> result.success(status())
                        "updateNotification" -> {
                            val names = call.argument<List<String>>("names") ?: emptyList()
                            require(names.size <= 8)
                            val safeNames = names.mapIndexed { index, name ->
                                name.filter { !it.isISOControl() }.take(64).trim().ifEmpty { "Device ${index + 1}" }
                            }
                            val connected = (call.argument<Number>("connected")?.toInt() ?: 0).coerceIn(0, safeNames.size)
                            notificationDevices = ClipboardNotificationDevices(safeNames, connected)
                            ClipboardSyncService.instance?.updateNotification()
                            result.success(null)
                        }
                        "authorize" -> authorize(result)
                        "authorizeImages" -> {
                            val host = activity.get()
                            if (host == null || photoResult != null || permissionResult != null) result.error("BUSY", "Open the app to authorize photo access", null)
                            else if (ScreenshotWatcher.fullAccess(host)) {
                                ClipboardSyncService.instance?.refreshScreenshotAccess()
                                result.success(true)
                            } else {
                                photoResult = result
                                val permissions = if (Build.VERSION.SDK_INT >= 34)
                                    arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                                    else arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
                                host.requestPermissions(permissions, PHOTO_REQUEST)
                            }
                        }
                        "start" -> {
                            val context = activity.get()
                            if (context == null || !allowed()) {
                                result.error("PERMISSION_REQUIRED", "Authorize Shizuku and notifications first", null)
                            } else {
                                retainingEngine = true
                                context.startForegroundService(Intent(context, ClipboardSyncService::class.java)
                                    .putExtra("syncImages", call.argument<Boolean>("syncImages") == true))
                                result.success(null)
                            }
                        }
                        "stop" -> {
                            val service = ClipboardSyncService.instance
                            if (service != null) service.stopAndWait { result.success(null) }
                            else {
                                application.stopService(Intent(application, ClipboardSyncService::class.java))
                                result.success(null)
                            }
                        }
                        "read" -> result.success(ClipboardSyncService.instance?.snapshot()
                            ?: mapOf("text" to null, "sequence" to 0L))
                        "write" -> {
                            val service = ClipboardSyncService.instance
                            val text = call.argument<String>("text")
                            if (service == null || text == null) {
                                result.error("STOPPED", "Clipboard service is stopped", null)
                            } else {
                                val sequence = call.argument<Number>("sequence")?.toLong()
                                service.write(text, sequence)
                                result.success(service.sequence)
                            }
                        }
                        "writeImage" -> {
                            val service = ClipboardSyncService.instance
                            val image = call.argument<ByteArray>("image")
                            if (service == null || image == null) result.error("STOPPED", "Clipboard image service unavailable", null)
                            else service.writeImage(image, call.argument<Number>("sequence")?.toLong(),
                                call.argument<String>("notificationTitle") ?: "LocalSend image received",
                                call.argument<String>("notificationBody") ?: "Image received. Ready to paste.") { sequence, error ->
                                if (error != null) result.error(error, "Clipboard image write could not finish", null)
                                else result.success(sequence)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: StaleClipboardWrite) {
                    result.error("STALE_WRITE", "Local clipboard changed before remote write", null)
                } catch (_: Exception) {
                    if (call.method == "scanPairingQr") scanResult = null
                    if (call.method == "start") retainingEngine = false
                    // Platform exceptions must not include clipboard values or key material.
                    result.error("CLIPBOARD_FAILED", "Clipboard operation failed; check service and permissions", null)
                }
            }
    }

    fun detach(host: Activity) {
        if (activity.get() !== host) return
        activity = WeakReference(null)
        permissionListener?.let { Shizuku.removeRequestPermissionResultListener(it) }
        permissionListener = null
        permissionResult?.error("CANCELLED", "Permission request interrupted by closing the screen", null)
        permissionResult = null
        photoResult?.error("CANCELLED", "Photo authorization interrupted by closing the screen", null)
        photoResult = null
        scanResult?.success(null)
        scanResult = null
    }

    fun activityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != SCAN_REQUEST) return false
        val value = ScanIntentResult.parseActivityResult(resultCode, data)?.contents
        if (value != null && value.length > 4096) scanResult?.error("INVALID_QR", "Invalid pairing QR code", null)
        else scanResult?.success(value)
        scanResult = null
        return true
    }

    private fun allowed(): Boolean = Build.VERSION.SDK_INT in 33..36 && Shizuku.pingBinder() &&
        Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED &&
        activity.get()?.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun status(): Map<String, Any> = mapOf(
        "supported" to (Build.VERSION.SDK_INT in 33..36),
        "authorized" to allowed(),
        "running" to (ClipboardSyncService.instance != null),
        "sequence" to (ClipboardSyncService.instance?.sequence ?: 0L)
    )

    private fun authorize(result: MethodChannel.Result) {
        if (permissionResult != null || photoResult != null) { result.error("BUSY", "Permission request already open", null); return }
        val host = activity.get()
        if (host == null || Build.VERSION.SDK_INT !in 33..36 || !Shizuku.pingBinder()) {
            result.error("SHIZUKU_UNAVAILABLE", "Start ADB-mode Shizuku on Android 13–16 first", null); return
        }
        permissionResult = result
        if (host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
        } else requestShizuku()
    }

    fun permissionResult(request: Int, grants: IntArray) {
        if (request == PHOTO_REQUEST) {
            val granted = activity.get()?.let { ScreenshotWatcher.fullAccess(it) } == true
            if (granted) ClipboardSyncService.instance?.refreshScreenshotAccess()
            photoResult?.success(granted); photoResult = null
            return
        }
        if (request != NOTIFICATION_REQUEST) return
        if (grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED) requestShizuku()
        else finishPermission()
    }

    private fun requestShizuku() {
        if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) { finishPermission(); return }
        if (Shizuku.shouldShowRequestPermissionRationale()) {
            permissionResult?.error("RESTORE_SHIZUKU", "Restore LocalSend access in Shizuku Authorized applications", null)
            permissionResult = null; return
        }
        val listener = Shizuku.OnRequestPermissionResultListener { _, _ -> activity.get()?.runOnUiThread { finishPermission() } }
        permissionListener = listener
        Shizuku.addRequestPermissionResultListener(listener)
        Shizuku.requestPermission(4502)
    }

    private fun finishPermission() {
        permissionListener?.let { Shizuku.removeRequestPermissionResultListener(it) }
        permissionListener = null
        permissionResult?.success(status()); permissionResult = null
    }

    fun emit(kind: String, message: String? = null) {
        sink?.success(mapOf("kind" to kind, "message" to message))
    }
}

class StaleClipboardWrite : Exception()
