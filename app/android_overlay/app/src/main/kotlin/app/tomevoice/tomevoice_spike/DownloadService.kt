package app.tomevoice.tomevoice_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Web-novel chapters downloading (download_queue.dart): a notification of
 * how far it is, and a foreground service (data sync) so the app is kept
 * alive while it downloads in the background. The queue itself is Dart;
 * this only shows it. Started from the app (in the foreground), updated
 * through the notification, stopped when the queue is done or paused.
 */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = build(this, last)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        foreground = true
        // Done before it got here: stopped only now, as a service started
        // to be in the foreground must get there first.
        if (stopWhenUp) {
            stopWhenUp = false
            started = false
            foreground = false
            stopSelf()
        }
        // Gone with the app: the queue picks up again when it is opened.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        foreground = false
        started = false
        super.onDestroy()
    }

    /** Android 15: a data-sync service's daily time is up. The queue waits for the app. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    data class Progress(val title: String, val text: String, val done: Int, val total: Int)

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 7303

        @Volatile
        private var last = Progress("Downloading chapters", "", 0, 0)

        @Volatile
        private var started = false

        /** The service has called startForeground. */
        @Volatile
        private var foreground = false

        /** Stopped before it was up: stop once it is. */
        @Volatile
        private var stopWhenUp = false

        /** Show [p]; the service is started the first time (the app is in front then). */
        fun update(context: Context, p: Progress) {
            last = p
            stopWhenUp = false
            if (!started) {
                try {
                    context.startForegroundService(Intent(context, DownloadService::class.java))
                    started = true
                } catch (e: Exception) {
                    // Not allowed from the background (Android 12+): the
                    // notification still shows, without keeping the app alive.
                }
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, build(context, p))
        }

        fun stop(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (started && !foreground) {
                // Still on its way up (see onStartCommand).
                stopWhenUp = true
                return
            }
            if (started) {
                started = false
                foreground = false
                try {
                    context.stopService(Intent(context, DownloadService::class.java))
                } catch (e: Exception) {
                    // Already gone.
                }
            }
            nm.cancel(NOTIFICATION_ID)
        }

        private fun build(context: Context, p: Progress): Notification {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW)
                channel.description = "Web novel chapters being downloaded."
                channel.setShowBadge(false)
                nm.createNotificationChannel(channel)
            }
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(p.title)
                .setContentText(p.text)
                .setProgress(p.total, p.done, p.total <= 0)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setContentIntent(Widgets.openApp(context, NOTIFICATION_ID, null, false, null))
                .build()
        }
    }
}
