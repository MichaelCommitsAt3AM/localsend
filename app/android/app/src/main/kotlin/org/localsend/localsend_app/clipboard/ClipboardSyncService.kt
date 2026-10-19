package org.localsend.localsend_app.clipboard

import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.*
import org.localsend.localsend_app.MainActivity
import rikka.shizuku.Shizuku
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.*
import android.net.Uri

data class ClipboardNotificationDevices(val names: List<String>, val connected: Int)

/** Ordinary app-UID owner; only the separate shell helper reads privileged clips. */
class ClipboardSyncService : Service() {
    companion object {
        var instance: ClipboardSyncService? = null; private set
        private const val STARTING = "Starting Android clipboard listener"
        private const val RECONNECTING = "Android copies paused: clipboard helper reconnecting"
        private const val SHIZUKU_STOPPED = "Android copies paused: start Shizuku to restore sharing"
    }
    private val main = Handler(Looper.getMainLooper())
    private val owner = Binder()
    private var helper: IClipboardProbe? = null
    private lateinit var args: Shizuku.UserServiceArgs
    private var bound = false
    private var active = false
    private var generation = 0
    private var captured: String? = null
    private var capturedImage: ByteArray? = null
    private var syncImages = false
    private var screenshotWatcher: ScreenshotWatcher? = null
    private var screenshotIssue: String? = null
    private var lastClipboardMutationMs = 0L
    private val imageWorker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1))
    private val imageDescriptors = ConcurrentHashMap.newKeySet<ParcelFileDescriptor>()
    private val pendingImageWrites = mutableSetOf<(Long?, String?) -> Unit>()
    private val stopCallbacks = mutableListOf<() -> Unit>()
    private var captureIssue: String? = STARTING
    private val bindingTimeout: Runnable = Runnable {
        if (!active || !bound || helper != null) return@Runnable
        // A bind request is not a connected helper. Release a stalled request
        // before retrying, otherwise bound=true prevents recovery forever.
        try { Shizuku.unbindUserService(args, connection, false) } catch (_: Exception) {}
        bound = false
        setCaptureIssue(RECONNECTING)
        bindHelper()
    }
    private val remoteToken = java.util.UUID.randomUUID().toString()
    private val expireCapture = Runnable { captured = null; capturedImage = null }
    var sequence = 0L; private set

    private val dead = Shizuku.OnBinderDeadListener { main.post {
        if (!active) return@post
        // Binder callbacks are queued on the main thread; a new binder may
        // already have arrived by the time an old death callback is processed.
        if (Shizuku.pingBinder() && helper?.asBinder()?.isBinderAlive == true) {
            refreshCaptureStatus(); return@post
        }
        main.removeCallbacks(bindingTimeout)
        helper = null; bound = false; generation++; captured = null; capturedImage = null
        ClipboardChannels.emit("changed")
        setCaptureIssue(SHIZUKU_STOPPED)
        if (Shizuku.pingBinder()) bindHelper()
    } }
    private val received = Shizuku.OnBinderReceivedListener { main.post { refreshCaptureStatus() } }
    private val connection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (!active || !bound) return
            main.removeCallbacks(bindingTimeout)
            val current = ++generation
            helper = IClipboardProbe.Stub.asInterface(binder)
            try {
                val metadata = helper!!.start(Process.myUid() / 100000, owner, object : IProbeCallback.Stub() {
                    override fun onImage(descriptor: ParcelFileDescriptor, metadata: Bundle) { main.post {
                        if (!active || !syncImages || generation != current) { descriptor.close(); return@post }
                        sequence++; val capturedSequence = sequence
                        lastClipboardMutationMs = System.currentTimeMillis()
                        captured = null; capturedImage = null
                        ClipboardChannels.emit("changed")
                        imageDescriptors.add(descriptor)
                        try { imageWorker.execute {
                            val image = try { ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { ClipboardImages.normalize(it) } }
                                catch (_: Exception) { null }
                                finally { imageDescriptors.remove(descriptor) }
                            main.post {
                                if (!active || generation != current || sequence != capturedSequence) return@post
                                capturedImage = image
                                if (image != null) {
                                    main.removeCallbacks(expireCapture); main.postDelayed(expireCapture, 300000)
                                    setCaptureIssue(null)
                                    ClipboardChannels.emit("changed")
                                } else ClipboardChannels.emit("status", "Image unavailable or exceeds clipboard limits")
                            }
                        } } catch (_: RejectedExecutionException) { imageDescriptors.remove(descriptor); descriptor.close() }
                    } }
                    override fun onSnapshot(metadata: Bundle) { main.post {
                        if (!active || generation != current) return@post
                        if (metadata.getString("remoteToken") == remoteToken) return@post
                        sequence++
                        lastClipboardMutationMs = System.currentTimeMillis()
                        capturedImage = null
                        captured = metadata.getString("text")?.takeIf {
                            it.length <= 65536 && it.toByteArray(Charsets.UTF_8).size <= 65536
                        }
                        main.removeCallbacks(expireCapture)
                        if (captured != null) main.postDelayed(expireCapture, 300000)
                        ClipboardChannels.emit("changed")
                        if (metadata.getString("status") == "permission-denied") {
                            setCaptureIssue("Android copies paused: clipboard access denied")
                        } else if (metadata.getString("status") == "text-readable") {
                            setCaptureIssue(null)
                        } else if (metadata.getString("status") == "image-unavailable") {
                            ClipboardChannels.emit("status", "Copied image could not be read; try copying from another app")
                        }
                    } }
                }, syncImages)
                if (!metadata.getBoolean("listenerRegistered") || metadata.getInt("helperUid") != 2000) {
                    ClipboardChannels.emit("fatal", "Shizuku clipboard adapter unavailable: ${metadata.getString("status")}")
                    stopSelf()
                } else setCaptureIssue(null)
            } catch (_: Exception) {
                ClipboardChannels.emit("fatal", "Shizuku clipboard helper could not start"); stopSelf()
            }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            if (!active) return
            if (Shizuku.pingBinder() && helper?.asBinder()?.isBinderAlive == true) {
                refreshCaptureStatus(); return
            }
            main.removeCallbacks(bindingTimeout)
            helper = null; bound = false; generation++; captured = null; capturedImage = null
            ClipboardChannels.emit("changed")
            setCaptureIssue(RECONNECTING)
            if (active) main.postDelayed({ bindHelper() }, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate(); instance = this
        args = Shizuku.UserServiceArgs(ComponentName(this, ClipboardUserService::class.java))
            .tag("localsend-clipboard").daemon(false).processNameSuffix("clipboard").version(4)
        File(cacheDir, "clipboard_images").listFiles()?.forEach { it.delete() }
        Shizuku.addBinderDeadListener(dead)
        Shizuku.addBinderReceivedListenerSticky(received)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") { stopSelf(); return START_NOT_STICKY }
        syncImages = intent?.getBooleanExtra("syncImages", false) ?: false
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("clipboard-sync", "Clipboard synchronization", NotificationManager.IMPORTANCE_LOW))
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) startForeground(4501, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(4501, notification)
        active = true; refreshCaptureStatus()
        refreshScreenshotAccess()
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val devices = ClipboardChannels.notificationDevices
        val counts = "${devices.connected} connected ${if (devices.connected == 1) "device" else "devices"}"
        val summary = captureIssue ?: screenshotIssue ?: counts
        val details = android.text.SpannableStringBuilder()
        details.append(listOfNotNull(captureIssue, screenshotIssue, counts).joinToString("\n"))
        if (devices.connected > 0) {
            for (name in devices.names) {
                details.append("\n")
                val dotStart = details.length
                details.append("\u25CF ").append(name)
                details.setSpan(
                    android.text.style.ForegroundColorSpan(android.graphics.Color.rgb(76, 175, 80)),
                    dotStart, dotStart + 1, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ClipboardSyncService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "clipboard-sync")
            .setSmallIcon(android.R.drawable.ic_menu_share).setContentTitle("LocalSend clipboard sync")
            .setContentText(summary).setStyle(Notification.BigTextStyle().bigText(details))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
    }

    fun updateNotification() {
        if (active) getSystemService(NotificationManager::class.java).notify(4501, buildNotification())
    }

    private fun setCaptureIssue(issue: String?) {
        captureIssue = issue
        updateNotification()
        ClipboardChannels.emit(if (issue == null) "captureReady" else "captureUnavailable", issue)
    }

    /** Replay current health when the Activity/event stream reconnects. */
    fun refreshCaptureStatus() {
        if (!active) return
        if (Shizuku.pingBinder() && bound && helper?.asBinder()?.isBinderAlive == true) {
            // Only clear connection warnings. A real clipboard access denial
            // still needs a successful capture before it can be cleared.
            if (captureIssue in listOf(STARTING, RECONNECTING, SHIZUKU_STOPPED)) captureIssue = null
        } else {
            if (helper != null) {
                helper = null; bound = false; generation++
                captured = null; capturedImage = null
                ClipboardChannels.emit("changed")
            }
            bindHelper()
        }
        updateNotification()
        ClipboardChannels.emit(if (captureIssue == null) "captureReady" else "captureUnavailable", captureIssue)
        ClipboardChannels.emit(if (screenshotIssue == null) "screenshotReady" else "screenshotUnavailable", screenshotIssue)
    }

    private fun bindHelper() {
        if (!active || bound) return
        if (!Shizuku.pingBinder()) {
            setCaptureIssue(SHIZUKU_STOPPED)
            return
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            ClipboardChannels.emit("fatal", "Shizuku permission is required"); stopSelf(); return
        }
        try {
            // Retain a retry warning after a stalled bind instead of presenting
            // every retry as a healthy initial startup.
            if (captureIssue != RECONNECTING) setCaptureIssue(STARTING)
            bound = true
            Shizuku.bindUserService(args, connection)
            main.postDelayed(bindingTimeout, 5000)
        }
        catch (_: Exception) { bound = false; ClipboardChannels.emit("fatal", "Shizuku helper binding failed"); stopSelf() }
    }

    fun snapshot(): Map<String, Any?> = mapOf("text" to captured, "image" to capturedImage, "sequence" to sequence)
    fun refreshScreenshotAccess() {
        if (!active || !syncImages) return
        if (!ScreenshotWatcher.fullAccess(this)) {
            screenshotWatcher?.stop(); screenshotWatcher = null
            screenshotIssue = "Screenshot sharing paused: allow full photo access"
            updateNotification(); ClipboardChannels.emit("screenshotUnavailable", screenshotIssue)
            return
        }
        if (screenshotWatcher != null) return
        screenshotWatcher = ScreenshotWatcher(this, { uri, taken -> captureScreenshot(uri, taken) }, { issue ->
            screenshotIssue = issue
            if (issue != null) { screenshotWatcher?.stop(); screenshotWatcher = null }
            updateNotification()
            ClipboardChannels.emit(if (issue == null) "screenshotReady" else "screenshotUnavailable", issue)
        }).also { it.start() }
    }

    private fun captureScreenshot(uri: Uri, takenMs: Long) {
        if (!active || !syncImages || !ScreenshotWatcher.fullAccess(this) || takenMs < lastClipboardMutationMs) return
        lastClipboardMutationMs = minOf(takenMs, System.currentTimeMillis())
        sequence++; val expected = sequence; val current = generation
        captured = null; capturedImage = null
        ClipboardChannels.emit("changed")
        fun decode(retry: Int) {
            if (!active || !syncImages || sequence != expected || generation != current) return
            try { imageWorker.execute {
                var descriptor: ParcelFileDescriptor? = null
                val image = try {
                    descriptor = contentResolver.openFileDescriptor(uri, "r") ?: error("Screenshot unavailable")
                    imageDescriptors.add(descriptor)
                    ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { ClipboardImages.normalize(it) }
                } catch (_: Exception) { null }
                finally { descriptor?.let { imageDescriptors.remove(it); try { it.close() } catch (_: Exception) {} } }
                main.post {
                    if (!active || !syncImages || sequence != expected || generation != current) return@post
                    capturedImage = image
                    if (image != null) {
                        main.removeCallbacks(expireCapture); main.postDelayed(expireCapture, 300000)
                        ClipboardChannels.emit("changed")
                    } else ClipboardChannels.emit("status", "Screenshot unavailable or exceeds image limits")
                }
            } } catch (_: RejectedExecutionException) {
                if (retry < 8) main.postDelayed({ decode(retry + 1) }, 250)
                else ClipboardChannels.emit("status", "Screenshot capture busy; take a new screenshot")
            }
        }
        decode(0)
    }
    fun stopAndWait(completion: () -> Unit) { stopCallbacks.add(completion); stopSelf() }
    fun writeImage(bytes: ByteArray, expected: Long?, arrivalTitle: String, arrivalBody: String, completion: (Long?, String?) -> Unit) {
        require(active && syncImages && bytes.size in 1..ClipboardImages.MAX_BYTES)
        val current = generation
        var completed = false
        lateinit var finish: (Long?, String?) -> Unit
        finish = { sequence, error ->
            if (!completed) { completed = true; pendingImageWrites.remove(finish); completion(sequence, error) }
        }
        pendingImageWrites.add(finish)
        try { imageWorker.execute {
            var file: File? = null
            try {
                val normalized = ClipboardImages.normalize(bytes.inputStream())
                val directory = File(cacheDir, "clipboard_images").apply { mkdirs() }
                file = File(directory, "${java.util.UUID.randomUUID()}.png").apply { writeBytes(normalized) }
                val ready = file
                main.post {
                    if (!active || !syncImages || generation != current) { ready.delete(); finish(null, "STOPPED"); return@post }
                    if (expected != null && sequence != expected) { ready.delete(); finish(null, "STALE_WRITE"); return@post }
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.clipboard-images", ready)
                        val clip = ClipData.newUri(contentResolver, "LocalSend image", uri)
                        clip.description.extras = PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                            putString("org.localsend.clipboard.REMOTE_ORIGIN", remoteToken)
                        }
                        getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                        sequence++ // Invalidate any earlier local image decode still in flight.
                        lastClipboardMutationMs = System.currentTimeMillis()
                        captured = null; capturedImage = null
                        // Only the current immutable image is retained; no clipboard history.
                        directory.listFiles()?.filter { it != ready }?.forEach { it.delete() }
                        main.postDelayed({ ready.delete() }, 300000)
                        notifyImageArrival(arrivalTitle, arrivalBody)
                        finish(sequence, null)
                    } catch (_: Exception) { ready.delete(); finish(null, "IMAGE_WRITE_FAILED") }
                }
            } catch (_: Exception) { file?.delete(); main.post { finish(null, "INVALID_IMAGE") } }
        } } catch (_: RejectedExecutionException) { finish(null, "CLIPBOARD_BUSY") }
    }
    private fun notifyImageArrival(title: String, body: String) {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            // A new ID is needed because Android keeps the old channel's sound and vibration settings after an update.
            val channelId = "clipboard-images-silent"
            manager.createNotificationChannel(NotificationChannel(channelId, "Clipboard image arrivals", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
            })
            manager.deleteNotificationChannel("clipboard-images")
            val open = PendingIntent.getActivity(this, 4505, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val notification = Notification.Builder(this, channelId)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle(title.filter { !it.isISOControl() }.take(128))
                .setContentText(body.filter { !it.isISOControl() }.take(256))
                .setContentIntent(open).setAutoCancel(true).setTimeoutAfter(30000)
                .setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_STATUS)
                .build()
            manager.notify(4505, notification) // One replaceable arrival item, separate from service notification.
        } catch (_: Exception) { /* Delivery succeeded even if notifications are disabled. */ }
    }
    fun write(text: String, expected: Long?) {
        require(active && text.isNotEmpty() && text.length <= 65536 && text.toByteArray(Charsets.UTF_8).size <= 65536)
        if (expected != null && expected != sequence) throw StaleClipboardWrite()
        val clip = ClipData.newPlainText("LocalSend clipboard", text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean("android.content.extra.IS_SENSITIVE", true)
            putString("org.localsend.clipboard.REMOTE_ORIGIN", remoteToken)
        }
        getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        getSystemService(NotificationManager::class.java).cancel(4505)
        sequence++ // Own writes also invalidate asynchronous local image captures.
        lastClipboardMutationMs = System.currentTimeMillis()
        // The OS callback is sensitive-suppressed by the helper; never retransmit it.
        captured = null
        capturedImage = null
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        active = false; generation++; main.removeCallbacksAndMessages(null); captured = null; capturedImage = null
        getSystemService(NotificationManager::class.java).cancel(4505)
        screenshotWatcher?.stop(); screenshotWatcher = null
        imageDescriptors.forEach { try { it.close() } catch (_: Exception) {} }; imageDescriptors.clear()
        imageWorker.shutdownNow()
        pendingImageWrites.toList().forEach { it(null, "STOPPED") }
        File(cacheDir, "clipboard_images").listFiles()?.forEach { it.delete() }
        try { helper?.stop() } catch (_: Exception) { /* Binder may already be dead. */ }
        if (bound && Shizuku.pingBinder()) {
            try { Shizuku.unbindUserService(args, connection, true) } catch (_: Exception) { /* Continue local cleanup. */ }
        }
        Shizuku.removeBinderDeadListener(dead); Shizuku.removeBinderReceivedListener(received)
        helper = null; bound = false; instance = null; stopForeground(STOP_FOREGROUND_REMOVE)
        ClipboardChannels.retainingEngine = false
        ClipboardChannels.emit("stopped")
        stopCallbacks.toList().forEach { it() }; stopCallbacks.clear()
        super.onDestroy()
    }
}
