package org.localsend.localsend_app.clipboard

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Event-driven MediaStore watcher. Baselines every start; never scans image bytes in history. */
class ScreenshotWatcher(
    private val context: Context,
    private val onScreenshot: (Uri, Long) -> Unit,
    private val onStatus: (String?) -> Unit,
) {
    private val resolver = context.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val worker = ScheduledThreadPoolExecutor(1).apply {
        removeOnCancelPolicy = true
        setExecuteExistingDelayedTasksAfterShutdownPolicy(false)
    }
    private val started = System.currentTimeMillis()
    private val baselines = mutableMapOf<String, Long>()
    private val seen = LinkedHashSet<String>()
    @Volatile private var stopped = false
    @Volatile private var cancellation: CancellationSignal? = null
    private var scheduled: ScheduledFuture<*>? = null
    private val observer = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean, uri: Uri?) { schedule() }
    }

    fun start() {
        if (!fullAccess(context)) { main.post { onStatus("Screenshot sharing paused: allow full photo access") }; stop(); return }
        worker.execute {
            try {
                val volumes = MediaStore.getExternalVolumeNames(context).take(8)
                for (volume in volumes) {
                    if (stopped) return@execute
                    val uri = MediaStore.Images.Media.getContentUri(volume)
                    // Record all existing IDs before registering: no old screenshots on enable/reconnect.
                    var baseline = 0L
                    query(uri, arrayOf(MediaStore.Images.Media._ID), null, null, 1)?.use {
                        if (it.moveToFirst()) baseline = it.getLong(0)
                    }
                    baselines[volume] = baseline
                    synchronized(this) { if (!stopped) resolver.registerContentObserver(uri, true, observer) }
                }
                // Providers also notify the synthetic external collection.
                synchronized(this) { if (!stopped) resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer) }
                main.post { if (!stopped) onStatus(null) }
                schedule()
            } catch (_: Exception) { report("Screenshot sharing unavailable; check photo access") }
        }
    }

    @Synchronized private fun schedule() {
        if (stopped) return
        scheduled?.cancel(false)
        scheduled = worker.schedule({ scan() }, 350, TimeUnit.MILLISECONDS)
    }

    private fun scan() {
        if (stopped) return
        if (!fullAccess(context)) { report("Screenshot sharing paused: allow full photo access"); return }
        try {
            var newest: Pair<Uri, Long>? = null
            val columns = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.RELATIVE_PATH,
                MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE,
                MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.SIZE, MediaStore.Images.Media.IS_PENDING)
            for ((volume, baseline) in baselines) {
                if (stopped) return
                val collection = MediaStore.Images.Media.getContentUri(volume)
                query(collection, columns, "${MediaStore.Images.Media._ID} > ?", arrayOf(baseline.toString()), 32)?.use { cursor ->
                    var examined = 0
                    while (examined++ < 32 && cursor.moveToNext() && !stopped) {
                        val id = cursor.getLong(0)
                        val key = "$volume:$id"
                        if (key in seen) continue
                        val added = cursor.getLong(4); val taken = cursor.getLong(5)
                        if (!ScreenshotPolicy.eligible(cursor.getString(1), cursor.getString(2), cursor.getString(3),
                                added, taken, started, System.currentTimeMillis(), cursor.getLong(6), cursor.getInt(7) != 0)) continue
                        seen.add(key)
                        while (seen.size > 256) seen.remove(seen.first())
                        val captureTime = if (taken > 0) taken else added * 1000 + 999
                        if (newest == null || captureTime > newest!!.second) newest = ContentUris.withAppendedId(collection, id) to captureTime
                    }
                }
            }
            newest?.let { candidate -> main.post { if (!stopped) onScreenshot(candidate.first, candidate.second) } }
        } catch (_: Exception) { report("Screenshot sharing unavailable; check photo access") }
    }

    private fun query(uri: Uri, columns: Array<String>, selection: String?, args: Array<String>?, limit: Int): android.database.Cursor? {
        val signal = CancellationSignal(); cancellation = signal
        try {
            if (stopped) { signal.cancel(); return null }
            return resolver.query(uri, columns, Bundle().apply {
                putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media._ID))
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                if (selection != null) putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                if (args != null) putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            }, signal)
        } finally { cancellation = null }
    }
    private fun report(message: String) { main.post { if (!stopped) onStatus(message) } }
    @Synchronized fun stop() {
        stopped = true
        cancellation?.cancel()
        scheduled?.cancel(false)
        resolver.unregisterContentObserver(observer)
        worker.shutdownNow()
    }
    companion object {
        fun fullAccess(context: Context): Boolean = context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
    }
}
