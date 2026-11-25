package app.tomevoice.tomevoice_spike

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.Display
import kotlin.math.abs

/**
 * How often the screen refreshes while TomeVoice is in front. By default
 * Android chooses: on a 120 Hz phone, 120 while something moves and less at
 * rest. Steady asks for the phone's 60 Hz mode at the same resolution and
 * keeps it, so each frame has twice the time (16.7 ms), and an animation that
 * would miss some 120 Hz beats runs at an even 60 instead.
 *
 * A launch of the test app (app.tomevoice.test) can ask for it, to measure
 * it on a phone; TomeVoice itself never reads the extra:
 *
 *   adb shell am start -n app.tomevoice.test/app.tomevoice.tomevoice_spike.MainActivity --es tv_rate 60
 */
object DisplayRate {
    fun fromLaunch(activity: Activity, intent: Intent?) {
        if (!activity.packageName.endsWith(".test")) return
        if (intent?.getStringExtra("tv_rate") == "60") steady(activity, true)
    }

    /** The 60 Hz mode when [on], else Android's own choice again. */
    fun steady(activity: Activity, on: Boolean) {
        val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }
        val now = display?.mode
        val mode = if (!on || display == null || now == null) {
            null
        } else {
            display.supportedModes
                .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
                .minByOrNull { abs(it.refreshRate - 60f) }
        }
        val window = activity.window
        val attrs = window.attributes
        attrs.preferredDisplayModeId = mode?.modeId ?: 0
        window.attributes = attrs
        Log.i("TomeVoice", "display rate: " + (mode?.let { "steady ${it.refreshRate} Hz (mode ${it.modeId})" } ?: "Android's choice"))
    }
}
