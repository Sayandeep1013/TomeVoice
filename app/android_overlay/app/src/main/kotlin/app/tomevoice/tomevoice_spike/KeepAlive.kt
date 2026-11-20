package app.tomevoice.tomevoice_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Long jobs the app's own Dart does on its engine (keep_alive.dart):
 * chapters downloading, a book's memory being built, a natural voice
 * downloading. Its channel ("tomevoice/keepalive") is on the app's engine
 * only (ReadingCore); the background workers' engines have their own time
 * from WorkManager.
 *
 * While Dart has work going ([busy]) the engine stays when the activity
 * goes (MainActivity.cleanUpFlutterEngine, ReadingCore's retire), as it
 * does for a book read aloud, so a swipe from Recents does not end it; and
 * [KeepAliveService] keeps the process in the foreground with the CPU
 * awake. Dart asks for the service as a job starts, with the app in front:
 * Android 12 and later will not start one from the background.
 */
object KeepAlive {
    const val CHANNEL = "tomevoice/keepalive"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null

    /** What the notification says, and what it says if Android pauses the work. */
    data class Notice(val title: String, val text: String, val done: Int, val total: Int, val paused: String)

    @Volatile
    var notice = Notice("TomeVoice", "", 0, 0, "Work paused")
        private set

    /** Dart has work going: the engine stays for it, the service shows it. */
    @Volatile
    private var wanted = false

    fun busy(): Boolean = wanted

    /** Dart's side, on the app's engine (ReadingCore.engine). */
    fun attach(app: Context, messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    result.success(
                        show(
                            app,
                            Notice(
                                title = args["title"] as? String ?: "TomeVoice",
                                text = args["text"] as? String ?: "",
                                done = (args["done"] as? Number)?.toInt() ?: 0,
                                total = (args["total"] as? Number)?.toInt() ?: 0,
                                paused = args["paused"] as? String ?: "Work paused",
                            ),
                        )
                    )
                }
                "stop" -> {
                    stop(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The engine went (ReadingCore.unbind): its work went with it. */
    fun engineGone(app: Context) {
        channel = null
        if (wanted) {
            wanted = false
            KeepAliveService.end(app)
        }
    }

    /**
     * To Dart: "stop" (the notification's Stop), "timeout" (Android 15's
     * six hours a day of this work in the background are used up) or
     * "refused" (Android would not let the service into the foreground).
     */
    fun send(event: String) {
        main.post { channel?.invokeMethod(event, null) }
    }

    /** The notification's Stop: Dart stops its jobs, and ends them; with no Dart to ask, stopped here. */
    fun askToStop(ctx: Context) {
        if (channel != null && wanted) send("stop") else stop(ctx)
    }

    /** Start the service, or show [n] on its notification. False when Android would not start it now. */
    private fun show(ctx: Context, n: Notice): Boolean {
        wanted = true
        notice = n
        return KeepAliveService.show(ctx)
    }

    /** Nothing is left: the service goes, and the engine too if nothing else holds it. */
    private fun stop(ctx: Context) {
        wanted = false
        KeepAliveService.end(ctx)
        ReadingCore.idle()
    }
}

/**
 * The foreground service (data sync) that keeps TomeVoice running while
 * the jobs [KeepAlive] knows of go on: one quiet notification of what runs,
 * how far, and Stop; a partial wake lock, renewed every few minutes while
 * the engine doing the work lives, and let go after ten without renewal.
 * Not restarted by Android once gone (START_NOT_STICKY): the work is
 * Dart's, and picks up where it was when TomeVoice is opened.
 *
 * Android 15 and later give a data-sync service six hours a day in the
 * background ([onTimeout]): then it says so, the jobs are held, and they go
 * on when TomeVoice is next opened.
 */
class KeepAliveService : Service() {

    companion object {
        const val ACTION_STOP = "app.tomevoice.action.WORK_STOP"
        private const val CHANNEL_ID = "work"

        /** The downloads' own channel, before this one took its place. */
        private const val OLD_CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 7306
        private const val NOTICE_ID = 7307

        /** The wake lock lets go after this unless renewed. */
        private const val AWAKE_MS = 10 * 60 * 1000L

        /** How often it is renewed while the work's engine lives. */
        private const val RENEW_MS = 4 * 60 * 1000L

        @Volatile
        private var instance: KeepAliveService? = null

        /** Asked to start, not yet in onStartCommand. */
        @Volatile
        private var starting = false

        /** Ended while on its way up: it stops once up (a service started this way must get there first). */
        @Volatile
        private var stopWhenUp = false

        fun show(ctx: Context): Boolean {
            stopWhenUp = false
            cancelNotice(ctx)
            val running = instance
            if (running != null && running.up) {
                running.refresh()
                return true
            }
            if (starting) return true
            return try {
                starting = true
                ctx.startForegroundService(Intent(ctx, KeepAliveService::class.java))
                true
            } catch (e: Exception) {
                // Not allowed from the background (Android 12 and later), or
                // the day's time used up (Android 15): Dart asks again when
                // the app is next in front.
                starting = false
                false
            }
        }

        fun end(ctx: Context) {
            if (starting) {
                stopWhenUp = true
                return
            }
            instance?.finish()
        }

        private fun channel(ctx: Context) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "Downloads and memories", NotificationManager.IMPORTANCE_LOW)
                channel.description = "Chapters downloading, a memory being built or a voice downloading while TomeVoice is in the background."
                channel.setShowBadge(false)
                nm.createNotificationChannel(channel)
            }
            if (nm.getNotificationChannel(OLD_CHANNEL_ID) != null) {
                try {
                    nm.deleteNotificationChannel(OLD_CHANNEL_ID)
                } catch (_: Exception) {
                }
            }
        }

        /** Android paused the work: said until TomeVoice is opened, or the work goes on. */
        private fun notice(ctx: Context, title: String, text: String) {
            channel(ctx)
            val n = Notification.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tomevoice)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setContentIntent(Widgets.openApp(ctx, NOTICE_ID, null, false, null))
                .build()
            try {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTICE_ID, n)
            } catch (_: Exception) {
            }
        }

        private fun cancelNotice(ctx: Context) {
            try {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTICE_ID)
            } catch (_: Exception) {
            }
        }
    }

    /** In the foreground (startForeground done, not undone since). */
    @Volatile
    var up = false
        private set

    private val main = Handler(Looper.getMainLooper())
    private var wake: PowerManager.WakeLock? = null

    /** The wake lock renewed while the engine doing the work lives; with it gone, the work went too. */
    private val renew = object : Runnable {
        override fun run() {
            if (!up) return
            val alive = FlutterEngineCache.getInstance().get(ReadingCore.ENGINE_ID)?.dartExecutor?.isExecutingDart == true
            if (!alive) {
                KeepAlive.engineGone(this@KeepAliveService)
                finish()
                return
            }
            keepAwake()
            main.postDelayed(this, RENEW_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            KeepAlive.askToStop(this)
            return START_NOT_STICKY
        }
        starting = false
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, build())
            }
        } catch (e: Exception) {
            // Not allowed now (Android 15's six hours used up, or the app no
            // longer in front): Dart asks again when it is.
            up = false
            KeepAlive.send("refused")
            stopSelf()
            return START_NOT_STICKY
        }
        up = true
        keepAwake()
        main.removeCallbacks(renew)
        main.postDelayed(renew, RENEW_MS)
        // Ended before it got here, or nothing is wanted any more.
        if (stopWhenUp || !KeepAlive.busy()) {
            stopWhenUp = false
            finish()
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15 and later: a data-sync service's six hours a day in the
     * background are used up, and it must stop now. Dart holds its jobs
     * until TomeVoice is next opened, and the reader is told.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        notice(
            this,
            KeepAlive.notice.paused,
            "Android lets this work six hours a day in the background. Open TomeVoice to go on.",
        )
        KeepAlive.send("timeout")
        finish()
    }

    // Swiped from Recents: nothing to do here. The work goes on, as the
    // engine stays while it runs; a phone that ends the whole app then ends
    // it too, and it picks up where it was when TomeVoice is opened.

    override fun onDestroy() {
        if (instance === this) instance = null
        up = false
        main.removeCallbacks(renew)
        letGo()
        super.onDestroy()
    }

    /** Out of the foreground, its notification gone, and stopped. */
    fun finish() {
        main.removeCallbacks(renew)
        letGo()
        up = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        stopSelf()
    }

    fun refresh() {
        keepAwake()
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, build())
        } catch (_: Exception) {
        }
    }

    /**
     * The CPU kept awake while the work goes on: with the screen off the
     * phone would otherwise sleep between chapters, or while an AI's answer
     * comes. The timeout only lets go of one nothing renews.
     */
    private fun keepAwake() {
        try {
            val w = wake ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TomeVoice:work")
                .also {
                    it.setReferenceCounted(false)
                    wake = it
                }
            w.acquire(AWAKE_MS)
        } catch (_: Exception) {
        }
    }

    private fun letGo() {
        try {
            wake?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
    }

    private fun build(): Notification {
        channel(this)
        val n = KeepAlive.notice
        val stop = PendingIntent.getService(
            this,
            NOTIFICATION_ID,
            Intent(this, KeepAliveService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_tomevoice)
            .setContentTitle(n.title)
            .setContentText(n.text)
            .setProgress(n.total.coerceAtLeast(0), n.done.coerceIn(0, n.total.coerceAtLeast(0)), n.total <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(Widgets.openApp(this, NOTIFICATION_ID, null, false, null))
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Stop",
                    stop,
                ).build()
            )
            .build()
    }
}
