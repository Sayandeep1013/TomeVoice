package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Checks the library's web novels for new chapters with TomeVoice closed,
 * on the reader's schedule (Settings > Check for new chapters), on the
 * network they allow and with the battery not low.
 *
 * The check is Dart (the sources run in QuickJS), so this starts a Flutter
 * engine of its own on background_check.dart's entry point, registers
 * SourcesBridge on it (MainActivity's channel does not exist there), and
 * waits for the Dart side to say it is done. Then it posts what was found,
 * as the Dart side worded it (novels on a secret shelf unnamed).
 *
 * While the app's own engine is up (TomeVoice open, left in the background
 * with Back, which keeps it, or reading a book with no screen), no engine is
 * started: two engines must never write the library at once. That engine is
 * asked to check instead ([askApp]), and what it found is posted the same way.
 */
class NovelCheckWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    private val done = CountDownLatch(1)
    private val outcome = AtomicReference<Map<*, *>?>(null)

    override fun doWork(): Result {
        val app = applicationContext
        if (SourcesBridge.appIsOpen()) {
            askApp()?.let { notify(app, it) }
            return Result.success()
        }
        val handle = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_HANDLE, 0L)
        if (handle == 0L || !running.compareAndSet(false, true)) return Result.success()
        val main = Handler(Looper.getMainLooper())
        val engine = AtomicReference<FlutterEngine?>(null)
        try {
            main.post {
                try {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(app)
                    loader.ensureInitializationComplete(app, null)
                    val callback = FlutterCallbackInformation.lookupCallbackInformation(handle)
                    if (callback == null) {
                        done.countDown()
                    } else {
                        val flutter = FlutterEngine(app)
                        engine.set(flutter)
                        SourcesBridge.attach(app, flutter.dartExecutor.binaryMessenger, null) { result ->
                            outcome.set(result)
                            done.countDown()
                        }
                        flutter.dartExecutor.executeDartCallback(
                            DartExecutor.DartCallback(app.assets, loader.findAppBundlePath(), callback)
                        )
                    }
                } catch (t: Throwable) {
                    done.countDown()
                }
            }
            // WorkManager gives a run ten minutes; the engine goes before.
            done.await(9, TimeUnit.MINUTES)
        } finally {
            main.post { engine.getAndSet(null)?.destroy() }
            running.set(false)
        }
        outcome.get()?.let { notify(app, it) }
        return Result.success()
    }

    /**
     * The app's own engine, asked to check (SourcesBridge.askAppToCheck),
     * and waited for: what it found, or null when it could not say (it has
     * no check to answer with yet, or went before it answered, as when the
     * app closes; or this run may wait no longer).
     */
    private fun askApp(): Map<*, *>? {
        val answered = CountDownLatch(1)
        val found = AtomicReference<Map<*, *>?>(null)
        val asked = AtomicReference<FlutterEngine?>(null)
        Handler(Looper.getMainLooper()).post {
            val engine = SourcesBridge.askAppToCheck { result ->
                found.set(result)
                answered.countDown()
            }
            if (engine == null) answered.countDown() else asked.set(engine)
        }
        // WorkManager gives a run ten minutes, as for an engine of its own.
        val deadline = SystemClock.elapsedRealtime() + TimeUnit.MINUTES.toMillis(9)
        while (!answered.await(2, TimeUnit.SECONDS)) {
            if (isStopped || SystemClock.elapsedRealtime() > deadline) return null
            val engine = asked.get()
            if (engine != null && FlutterEngineCache.getInstance().get(ReadingCore.ENGINE_ID) !== engine) return null
        }
        return found.get()
    }

    /** No longer allowed to run (out of time, or off Wi-Fi): end the engine. */
    override fun onStopped() {
        done.countDown()
    }

    companion object {
        private const val WORK = "novel-check"
        private const val PREFS = "novel_checks"
        private const val KEY_HANDLE = "handle"
        private const val CHANNEL_ID = "new_chapters"
        private const val NOTIFICATION_ID = 7301

        /** Set while a check runs here, so the app leaves its own to it. */
        val running = AtomicBoolean(false)

        /**
         * Run the Dart function behind [handle] every [minutes] (stopped at
         * 0), on Wi-Fi only when [unmetered], never with the battery low. The
         * same interval again keeps its place in the schedule.
         */
        fun schedule(context: Context, handle: Long, minutes: Long, unmetered: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (minutes <= 0L || handle == 0L) {
                wm.cancelUniqueWork(WORK)
                return
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(KEY_HANDLE, handle).apply()
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(if (unmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .build()
            val request = PeriodicWorkRequest.Builder(NovelCheckWorker::class.java, minutes, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        /** Whether TomeVoice may post notifications. */
        fun allowed(context: Context): Boolean {
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            return nm.areNotificationsEnabled()
        }

        private fun notify(context: Context, outcome: Map<*, *>) {
            val found = (outcome["found"] as? Number)?.toInt() ?: 0
            if (found <= 0 || !allowed(context)) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "New chapters", NotificationManager.IMPORTANCE_DEFAULT)
                channel.description = "Chapters the sites added to the web novels in your library."
                nm.createNotificationChannel(channel)
            }
            val style = Notification.InboxStyle()
            (outcome["lines"] as? List<*>)?.take(6)?.forEach { style.addLine(it.toString()) }
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tomevoice)
                .setContentTitle(outcome["title"] as? String ?: "New chapters")
                .setContentText(outcome["text"] as? String ?: "")
                .setStyle(style)
                .setNumber(found)
                .setAutoCancel(true)
                .setContentIntent(Widgets.openApp(context, NOTIFICATION_ID, null, false, "updates"))
                .build()
            nm.notify(NOTIFICATION_ID, notification)
        }
    }
}
