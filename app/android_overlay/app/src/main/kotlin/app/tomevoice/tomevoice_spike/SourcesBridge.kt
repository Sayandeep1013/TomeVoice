package app.tomevoice.tomevoice_spike

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Web novels' own channel to the platform ("tomevoice/sources"), kept out of
 * MainActivity. It is registered on the app's engine (MainActivity, with
 * [activity]) and on the engine the background check starts, which has no
 * activity: calls that need one answer null there.
 */
object SourcesBridge {
    const val CHANNEL = "tomevoice/sources"

    fun attach(context: Context, messenger: BinaryMessenger, activity: Activity?): MethodChannel {
        val app = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Sources (plugin code, their storage, site cookies) live in
                // internal storage, which no other app can read or change.
                "sourcesRoot" -> result.success(app.filesDir.absolutePath)
                // The library, where MainActivity keeps it.
                "libraryRoot" -> result.success((app.getExternalFilesDir(null) ?: app.filesDir).absolutePath)
                else -> result.notImplemented()
            }
        }
        return channel
    }
}
