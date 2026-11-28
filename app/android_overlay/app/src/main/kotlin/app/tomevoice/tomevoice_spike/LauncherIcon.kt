package app.tomevoice.tomevoice_spike

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The launcher icon in the theme's colours (Settings > Appearance > Icon
 * follows the theme).
 *
 * Each icon is a launcher activity-alias of MainActivity (prepare_android.py
 * writes one per theme icon, all off but IconClassic), and the one shown is
 * the one enabled. Dart says which it wants ([want]); the change is made as
 * the reader leaves the app ([apply], from onUserLeaveHint and a finishing
 * onDestroy), never while they are in it: some launchers redraw, and
 * Android may close the task the old entry started, as the alias changes.
 * The new one is enabled before the old one goes off, so there is never a
 * moment without an entry; DONT_KILL_APP keeps the reading going.
 */
object LauncherIcon {
    private const val CLASSIC = "IconClassic"

    /** The alias wanted, by its simple name; null when nothing is to change. */
    @Volatile private var wanted: String? = null

    private fun base(): String = MainActivity::class.java.name.substringBeforeLast('.')

    /** [key] from lib/launcher_icon.dart (e.g. "paper_day"), or null for the classic icon. */
    fun want(key: String?) {
        wanted = if (key.isNullOrEmpty()) CLASSIC else "Icon_$key"
    }

    /** The alias showing now: its key, or null for the classic one. */
    fun current(context: Context): String? {
        val name = enabledAliases(context).firstOrNull() ?: return null
        val simple = name.substringAfterLast('.')
        return if (simple.startsWith("Icon_")) simple.removePrefix("Icon_") else null
    }

    fun apply(context: Context) {
        val w = wanted ?: return
        wanted = null
        try {
            val pm = context.packageManager
            val pkg = context.packageName
            val target = ComponentName(pkg, "${base()}.$w")
            // A theme with no icon of its own (an older build's key): leave it.
            try {
                pm.getActivityInfo(target, PackageManager.MATCH_DISABLED_COMPONENTS)
            } catch (_: PackageManager.NameNotFoundException) {
                return
            }
            val on = enabledAliases(context)
            if (on == listOf(target.className)) return
            pm.setComponentEnabledSetting(target, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
            for (name in on) {
                if (name == target.className) continue
                pm.setComponentEnabledSetting(
                    ComponentName(pkg, name),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        } catch (e: Exception) {
            // The icon stays as it was; nothing else depends on it.
            android.util.Log.w("TomeVoice", "launcher icon: ${e.message}")
        }
    }

    /** The launcher aliases on now, by class name. */
    private fun enabledAliases(context: Context): List<String> {
        val pm = context.packageManager
        val pkg = context.packageName
        @Suppress("DEPRECATION")
        val info = pm.getPackageInfo(pkg, PackageManager.GET_ACTIVITIES or PackageManager.MATCH_DISABLED_COMPONENTS)
        return info.activities.orEmpty()
            .filter { it.targetActivity != null && it.name.substringAfterLast('.').let { n -> n == CLASSIC || n.startsWith("Icon_") } }
            .filter {
                when (pm.getComponentEnabledSetting(ComponentName(pkg, it.name))) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                    PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> it.enabled
                    else -> false
                }
            }
            .map { it.name }
    }
}
