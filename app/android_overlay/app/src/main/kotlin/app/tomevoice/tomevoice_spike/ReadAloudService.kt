package app.tomevoice.tomevoice_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process alive while a book is being read, so speech continues with
 * the screen off and from the lock screen.
 *
 * Without a foreground service Android freezes a backgrounded app within
 * seconds, and the next sentence is never synthesised. The service does no
 * audio work itself; the activity's player and the Dart scheduler keep doing
 * that. It owns the notification and a MediaSession so the lock screen,
 * notification shade and headset buttons can pause and resume.
 *
 * On Android 13+ the shade's media card is drawn from the session alone: the
 * cover is its background (and its colours come from the cover), the chapter
 * is its seek bar, and the custom action is the speed button.
 */
class ReadAloudService : Service() {

    companion object {
        const val ACTION_PLAY = "app.tomevoice.action.PLAY"
        const val ACTION_PAUSE = "app.tomevoice.action.PAUSE"
        const val ACTION_STOP = "app.tomevoice.action.STOP"
        const val ACTION_NEXT = "app.tomevoice.action.NEXT"
        const val ACTION_PREV = "app.tomevoice.action.PREV"
        private const val CUSTOM_SPEED = "speed"
        private const val CUSTOM_SAVE = "save"
        private const val CHANNEL_ID = "reading"
        private const val NOTIFICATION_ID = 7

        /** Covers are scaled to this on their long side; the card crops them. */
        private const val ART_MAX = 480

        /**
         * The wake lock lets go after this unless renewed: every sentence
         * read renews it, so only an app that died holding it is let off.
         */
        private const val AWAKE_MS = 10 * 60 * 1000L

        /** After a Play from the lock screen or a headset, until Dart answers. */
        private const val WAKE_FOR_PLAY_MS = 30 * 1000L

        /**
         * Set by the activity; receives "play", "pause", "stop", "next",
         * "prev", "speed", and "seek" with a position in milliseconds.
         */
        @Volatile
        var onAction: ((String, Long) -> Unit)? = null

        @Volatile
        private var instance: ReadAloudService? = null

        private var now = NowReading()

        /** Whether reading is under way (playing or paused), for the widgets. */
        fun isRunning(): Boolean = instance != null

        fun isPlaying(): Boolean = instance != null && now.playing

        fun update(ctx: Context, next: NowReading) {
            val previous = now
            now = next
            // The widgets show play or pause: redraw them when that changes.
            if (previous.playing != next.playing || previous.title != next.title || instance == null) {
                Widgets.refreshAll(ctx)
            }
            val running = instance
            if (running != null) {
                running.keepAwake(next.playing)
                // A new sentence only moves the seek bar; leave the
                // notification itself alone.
                if (next.copy(positionMs = previous.positionMs) == previous) {
                    running.publishState()
                } else {
                    running.refresh()
                }
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
            now = now.copy(playing = false)
            ctx.stopService(Intent(ctx, ReadAloudService::class.java))
            instance = null
            Widgets.refreshAll(ctx)
        }

        /** The button for [speed]: the number itself for the presets. */
        private fun speedIcon(speed: Double): Int {
            fun near(v: Double) = Math.abs(speed - v) < 0.001
            return when {
                near(0.75) -> R.drawable.ic_speed_0_75
                near(1.0) -> R.drawable.ic_speed_1_0
                near(1.25) -> R.drawable.ic_speed_1_25
                near(1.5) -> R.drawable.ic_speed_1_5
                near(2.0) -> R.drawable.ic_speed_2_0
                else -> R.drawable.ic_speed
            }
        }

        /** "1.25x", "2x" (with a multiplication sign). */
        private fun speedLabel(speed: Double): String {
            val text = String.format(java.util.Locale.US, "%.2f", speed).trimEnd('0').trimEnd('.')
            return text + "\u00d7"
        }
    }

    /**
     * What the card shows. [positionMs] and [durationMs] place the sentence
     * in its chapter, estimated from words at the current speed; a zero
     * duration hides the seek bar.
     */
    data class NowReading(
        val title: String = "TomeVoice",
        val subtitle: String = "",
        val playing: Boolean = false,
        val cover: String? = null,
        val positionMs: Long = 0,
        val durationMs: Long = 0,
        val speed: Double = 1.0,
    )

    private var session: MediaSession? = null
    private var artPath: String? = null
    private var art: Bitmap? = null
    private var wake: PowerManager.WakeLock? = null

    /**
     * Keeps the CPU awake while a book is read aloud or about to be (playing
     * includes making the next sentence). Without it, with the screen off,
     * the phone could doze while a sentence was being made, when the queue
     * ran dry, or before the first sentence after a Play from the lock screen
     * or a headset. Let go when paused or stopped, so a paused book costs
     * nothing; [ms] is a safety for an app that died holding it.
     */
    fun keepAwake(on: Boolean, ms: Long = AWAKE_MS) {
        try {
            if (on) {
                val w = wake ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TomeVoice:reading")
                    .also {
                        it.setReferenceCounted(false)
                        wake = it
                    }
                // Asked again, the timeout starts again.
                w.acquire(ms)
            } else {
                wake?.let { if (it.isHeld) it.release() }
            }
        } catch (_: Exception) {
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val s = MediaSession(this, "TomeVoice")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                // Awake until the app has the first sentence under way.
                if (!now.playing) keepAwake(true, WAKE_FOR_PLAY_MS)
                onAction?.invoke("play", 0)
            }

            override fun onPause() {
                onAction?.invoke("pause", 0)
            }

            override fun onStop() {
                onAction?.invoke("stop", 0)
            }

            override fun onSkipToNext() {
                onAction?.invoke("next", 0)
            }

            override fun onSkipToPrevious() {
                onAction?.invoke("prev", 0)
            }

            override fun onSeekTo(pos: Long) {
                onAction?.invoke("seek", pos)
            }

            override fun onCustomAction(action: String, extras: android.os.Bundle?) {
                if (action == CUSTOM_SPEED) onAction?.invoke("speed", 0)
                if (action == CUSTOM_SAVE) onAction?.invoke("save", 0)
            }
        })
        s.isActive = true
        session = s
        // Widgets' play buttons now go straight to this service.
        Widgets.refreshAll(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> {
                if (!now.playing) keepAwake(true, WAKE_FOR_PLAY_MS)
                onAction?.invoke("play", 0)
            }
            ACTION_PAUSE -> onAction?.invoke("pause", 0)
            ACTION_NEXT -> onAction?.invoke("next", 0)
            ACTION_PREV -> onAction?.invoke("prev", 0)
            ACTION_STOP -> onAction?.invoke("stop", 0)
        }
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        if (now.playing) keepAwake(true)
        if (onAction == null) {
            // Nothing is reading (the app was closed since): stop again, and
            // redraw the widgets so their buttons open the app instead.
            stopSelf()
            val app = applicationContext
            android.os.Handler(mainLooper).postDelayed({ Widgets.refreshAll(app) }, 400)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        keepAwake(false)
        session?.isActive = false
        session?.release()
        session = null
        art = null
        artPath = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        super.onDestroy()
    }

    fun refresh() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build())
    }

    /** Play state, place in the chapter and the speed button. */
    fun publishState() {
        val n = now
        val seekable = n.durationMs > 0
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        if (seekable) actions = actions or PlaybackState.ACTION_SEEK_TO
        val position = if (seekable) {
            n.positionMs.coerceIn(0, n.durationMs)
        } else {
            PlaybackState.PLAYBACK_POSITION_UNKNOWN
        }
        session?.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (n.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    position,
                    // The position is already in time at this speed, so the bar
                    // runs at real time between sentences.
                    if (n.playing) 1f else 0f
                )
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(
                        CUSTOM_SPEED,
                        "Speed " + speedLabel(n.speed),
                        speedIcon(n.speed)
                    ).build()
                )
                // Keep the sentence being read (Saved, in the app).
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(CUSTOM_SAVE, "Save this line", R.drawable.ic_save_line).build()
                )
                .build()
        )
    }

    /** The cover at card size, decoded once per book. */
    private fun artFor(path: String?): Bitmap? {
        if (path == artPath) return art
        artPath = path
        art = path?.let { decodeArt(it) }
        return art
    }

    private fun decodeArt(path: String): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= ART_MAX) sample *= 2
        // RGB_565 is half the bytes of ARGB: the session sends the picture
        // between processes, and that has a size limit.
        val decoded = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.RGB_565
            }
        )
        val long = if (decoded == null) 0 else maxOf(decoded.width, decoded.height)
        if (decoded == null || long <= ART_MAX) {
            decoded
        } else {
            val k = ART_MAX.toFloat() / long
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * k).toInt().coerceAtLeast(1),
                (decoded.height * k).toInt().coerceAtLeast(1),
                true
            )
        }
    } catch (e: Exception) {
        null
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

        val n = now
        val cover = artFor(n.cover)
        val meta = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, n.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, n.subtitle)
        if (n.durationMs > 0) meta.putLong(MediaMetadata.METADATA_KEY_DURATION, n.durationMs)
        if (cover != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, cover)
        session?.setMetadata(meta.build())
        publishState()
        val playing = n.playing

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
            // The app's mark, as Spotify shows its own. The card puts this top
            // left, where a play or pause sign read as a second button.
            .setSmallIcon(R.drawable.ic_stat_tomevoice)
            .setContentTitle(n.title)
            .setContentText(n.subtitle)
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
        if (cover != null) builder.setLargeIcon(cover)
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2)
        session?.let { style.setMediaSession(it.sessionToken) }
        builder.setStyle(style)
        return builder.build()
    }
}
