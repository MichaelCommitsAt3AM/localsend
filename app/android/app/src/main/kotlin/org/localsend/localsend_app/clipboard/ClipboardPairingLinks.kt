package org.localsend.localsend_app.clipboard

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** One RAM-only pending link. Never persist or log invitation credentials. */
object ClipboardPairingLinks {
    private const val CHANNEL = "org.localsend.localsend_app/clipboard_pairing_links"
    private var channel: MethodChannel? = null
    private var pending: String? = null
    private var received = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val expire = Runnable { pending = null }

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takePairingLink") {
                    val link = if (SystemClock.elapsedRealtime() - received <= 180000) pending else null
                    pending = null; handler.removeCallbacks(expire)
                    result.success(link)
                } else result.notImplemented()
            }
        }
        if (pending != null) channel?.invokeMethod("pairingLinkReady", null)
    }

    fun accept(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_VIEW) return false
        val uri = intent.data ?: return false
        val raw = uri.toString()
        val web = uri.scheme == "https" && uri.encodedAuthority == "localsend.currenta.tech" && uri.path == "/pair"
        val app = uri.scheme == "localsend-clipboard" && uri.encodedAuthority == "pair" && uri.path.isNullOrEmpty()
        if ((!web && !app) || raw.length > 8192 || uri.encodedQuery != null ||
            !Regex("^[A-Za-z0-9_-]+$").matches(uri.fragment ?: "")) return false
        pending = raw; received = SystemClock.elapsedRealtime()
        handler.removeCallbacks(expire); handler.postDelayed(expire, 180000)
        channel?.invokeMethod("pairingLinkReady", null)
        return true
    }
}
