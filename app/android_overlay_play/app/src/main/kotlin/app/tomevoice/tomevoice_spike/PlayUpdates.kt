package app.tomevoice.tomevoice_spike

import android.app.Activity
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Google Play's in-app updates, for the Play build only (copied over the
 * GitHub build's stand-in by tools/prepare_android.py when TV_STORE=play).
 *
 * The app asks Play whether a newer version is out ("check"); the reader
 * taps Update, Play downloads it in the background ("start", a flexible
 * update: reading goes on meanwhile), and once it is down the app offers a
 * restart ("complete"), which installs it. Play answers only for a copy
 * installed from Play.
 */
class PlayUpdates(private val activity: Activity, engine: FlutterEngine) {
    private val manager = AppUpdateManagerFactory.create(activity)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)

    private val listener = InstallStateUpdatedListener { state ->
        when (state.installStatus()) {
            InstallStatus.DOWNLOADING -> {
                val total = state.totalBytesToDownload()
                channel.invokeMethod("progress", if (total > 0) state.bytesDownloaded().toDouble() / total else null)
            }
            InstallStatus.DOWNLOADED -> channel.invokeMethod("downloaded", null)
            InstallStatus.FAILED, InstallStatus.CANCELED -> channel.invokeMethod("failed", null)
            else -> {}
        }
    }

    init {
        manager.registerListener(listener)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> manager.appUpdateInfo
                    .addOnSuccessListener { info ->
                        result.success(
                            mapOf(
                                "available" to (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                                    info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)),
                                "versionCode" to info.availableVersionCode(),
                                "staleDays" to info.clientVersionStalenessDays(),
                                "downloaded" to (info.installStatus() == InstallStatus.DOWNLOADED),
                                "bytes" to info.totalBytesToDownload(),
                            )
                        )
                    }
                    // Not installed from Play, no Play Store, no network.
                    .addOnFailureListener { result.success(null) }
                "start" -> manager.appUpdateInfo
                    .addOnSuccessListener { info ->
                        if (info.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE) {
                            result.success(false)
                        } else {
                            result.success(
                                try {
                                    manager.startUpdateFlowForResult(
                                        info, activity, AppUpdateOptions.defaultOptions(AppUpdateType.FLEXIBLE), REQUEST,
                                    )
                                } catch (e: Exception) {
                                    false
                                }
                            )
                        }
                    }
                    .addOnFailureListener { result.success(false) }
                "complete" -> {
                    manager.completeUpdate()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        manager.unregisterListener(listener)
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "tomevoice/play_update"
        const val REQUEST = 0x7E0A
    }
}
