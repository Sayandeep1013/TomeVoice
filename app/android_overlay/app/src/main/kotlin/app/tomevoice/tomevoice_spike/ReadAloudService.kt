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
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while a book is being read, so speech continues with
 * the screen off and from the lock screen.
 *
 * Without a foreground service Android freezes a backgrounded app within
 * seconds, and the next sentence is never synthesised. The service does no
 * audio work itself; the activity's player and the Dart scheduler keep doing
 * that. It owns the notification and a MediaSession so the lock screen,
 * notification shade and headset buttons can pause and resume.
 */
class ReadAloudService : Service() {

    companion object {
        const val ACTION_PLAY = "app.tomevoice.action.PLAY"
        const val ACTION_PAUSE = "app.tomevoice.action.PAUSE"
        const val ACTION_STOP = "app.tomevoice.action.STOP"
        const val ACTION_NEXT = "app.tomevoice.action.NEXT"
        const val ACTION_PREV = "app.tomevoice.action.PREV"
        private const val CHANNEL_ID = "reading"
        private const val NOTIFICATION_ID = 7

        /** Set by the activity; receives "play", "pause", "stop", "next", "prev". */
        @Volatile
        var onAction: ((String) -> Unit)? = null

        @Volatile
        private var instance: ReadAloudService? = null

        private var title = "TomeVoice"
        private var subtitle = ""
        private var playing = false

        fun update(ctx: Context, newTitle: String, newSubtitle: String, isPlaying: Boolean) {
            title = newTitle
            subtitle = newSubtitle
            playing = isPlaying
            val running = instance
            if (running != null) {
                running.refresh()
                return
            }
            val intent = Intent(ctx, ReadAloudService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun end(ctx: Context) {
            playing = false
            ctx.stopService(Intent(ctx, ReadAloudService::class.java))
        }
    }

    private var session: MediaSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val s = MediaSession(this, "TomeVoice")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                onAction?.invoke("play")
            }

            override fun onPause() {
                onAction?.invoke("pause")
            }

            override fun onStop() {
                onAction?.invoke("stop")
            }

            override fun onSkipToNext() {
                onAction?.invoke("next")
            }

            override fun onSkipToPrevious() {
                onAction?.invoke("prev")
            }
        })
        s.isActive = true
        session = s
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> onAction?.invoke("play")
            ACTION_PAUSE -> onAction?.invoke("pause")
            ACTION_NEXT -> onAction?.invoke("next")
            ACTION_PREV -> onAction?.invoke("prev")
            ACTION_STOP -> onAction?.invoke("stop")
        }
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        session?.isActive = false
        session?.release()
        session = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        super.onDestroy()
    }

    fun refresh() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build())
    }

    private fun build(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Reading aloud",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shows what is being read, with pause and resume."
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }

        session?.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle)
                .build()
        )
        session?.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    1f
                )
                .build()
        )

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        fun action(icon: Int, label: String, act: String, code: Int): Notification.Action {
            val pi = PendingIntent.getService(
                this,
                code,
                Intent(this, ReadAloudService::class.java).setAction(act),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            return Notification.Action.Builder(
                Icon.createWithResource(this, icon),
                label,
                pi
            ).build()
        }

        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(
                if (playing) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
            )
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(open)
            .setOngoing(playing)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(action(android.R.drawable.ic_media_previous, "Previous", ACTION_PREV, 1))
            .addAction(
                if (playing) {
                    action(android.R.drawable.ic_media_pause, "Pause", ACTION_PAUSE, 2)
                } else {
                    action(android.R.drawable.ic_media_play, "Play", ACTION_PLAY, 3)
                }
            )
            .addAction(action(android.R.drawable.ic_media_next, "Next", ACTION_NEXT, 4))
            .addAction(
                action(android.R.drawable.ic_menu_close_clear_cancel, "Stop", ACTION_STOP, 5)
            )
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }
        builder.setStyle(style)
        return builder.build()
    }
}
