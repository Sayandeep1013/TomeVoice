package app.tomevoice.tomevoice_spike

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The GitHub build's stand-in for Google Play's in-app updates: it has no
 * Play library, and finds its updates on GitHub instead (app_update.dart).
 * The Play build replaces this file with the real one
 * (android_overlay_play, copied by tools/prepare_android.py).
 */
class PlayUpdates(activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> result.success(null)
                "start", "complete" -> result.success(false)
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "tomevoice/play_update"
        const val REQUEST = 0x7E0A
    }
}
