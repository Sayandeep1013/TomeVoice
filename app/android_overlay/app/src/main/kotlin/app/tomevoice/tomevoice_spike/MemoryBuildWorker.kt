package app.tomevoice.tomevoice_spike

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Builds the books' memories (the AI companion's chapter notes) with
 * TomeVoice closed: every hour or so, on the network the reader allows,
 * the battery not low (and charging, when they asked), for most of the ten
 * minutes WorkManager gives a run.
 *
 * As NovelCheckWorker does, it starts a Flutter engine of its own on
 * memory_background.dart's entry point, and waits for the Dart side to say
 * it is done. Never while the app's own engine is up (the app builds the
 * memories itself then), nor while a check for new chapters runs here: two
 * engines must never write the library at once.
 */
class MemoryBuildWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    private val done = CountDownLatch(1)

    override fun doWork(): Result {
        val app = applicationContext
        if (SourcesBridge.appIsOpen() || NovelCheckWorker.running.get()) return Result.success()
        val handle = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_HANDLE, 0L)
        if (handle == 0L || !running.compareAndSet(false, true)) return Result.success()
        // See NovelCheckWorker: its own flag set, the other's read again.
        if (NovelCheckWorker.running.get()) {
            running.set(false)
            return Result.success()
        }
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
                        SourcesBridge.attach(app, flutter.dartExecutor.binaryMessenger, null) { _ ->
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
            // The Dart side stops itself at eight minutes; the engine goes
            // before WorkManager's ten in any case.
            done.await(9, TimeUnit.MINUTES)
        } finally {
            main.post { engine.getAndSet(null)?.destroy() }
            running.set(false)
        }
        return Result.success()
    }

    /** No longer allowed to run (out of time, off Wi-Fi, unplugged). */
    override fun onStopped() {
        done.countDown()
    }

    companion object {
        private const val WORK = "memory-build"
        private const val PREFS = "memory_builds"
        private const val KEY_HANDLE = "handle"

        /** Set while memories are built here. */
        val running = AtomicBoolean(false)

        /**
         * Run the Dart function behind [handle] every [minutes] (stopped at
         * 0), on Wi-Fi only when [unmetered], only while charging when
         * [charging], never with the battery low.
         */
        fun schedule(context: Context, handle: Long, minutes: Long, unmetered: Boolean, charging: Boolean) {
            val wm = WorkManager.getInstance(context)
            if (minutes <= 0L || handle == 0L) {
                wm.cancelUniqueWork(WORK)
                return
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(KEY_HANDLE, handle).apply()
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(if (unmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .setRequiresCharging(charging)
                .build()
            val request = PeriodicWorkRequest.Builder(MemoryBuildWorker::class.java, minutes, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }
}
