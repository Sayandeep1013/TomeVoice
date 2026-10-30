package app.tomevoice.tomevoice_spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaDescription
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.service.media.MediaBrowserService
import android.view.KeyEvent
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * Keeps the process alive while a book is being read, so speech continues with
 * the screen off and from the lock screen.
 *
 * Without a foreground service Android freezes a backgrounded app within
 * seconds, and the next sentence is never synthesised. The service does no
 * audio work itself; the player and the Dart scheduler keep doing that
 * (ReadingCore). It owns the notification and a MediaSession so the lock
 * screen, notification shade and headset buttons can pause and resume.
 *
 * On Android 13+ the shade's media card is drawn from the session alone: the
 * cover is its background (and its colours come from the cover), the chapter
 * is its seek bar, and the custom action is the speed button.
 *
 * It is also a MediaBrowserService, so the books can be played from outside
 * the app: the system's resume card after the app was closed (Android 11+,
 * [ROOT_RECENT]), Android Auto ([ROOT]), and a headset's Play, which reaches
 * the session's media button receiver (this service) once the app is gone.
 * With no reading on the card, Play goes foreground here at once (Android
 * allows that start for the seconds after a media button or the system's
 * media controls), then asks Dart for the book, starting the engine at
 * backgroundMain if the app is not running (ReadingCore.play). Books on a
 * secret shelf are never listed or played from outside ([Shelf]).
 *
 * Reading (Dart's session, [update] to [end]) and being up are apart: System
 * UI and Android Auto bind to the browser with nothing being read, and the
 * service then has no notification and is not foreground. A book left
 * paused keeps its card but not the foreground ([settle]); Play puts it back.
 */
class ReadAloudService : MediaBrowserService() {

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

        /** The resume card's picture, and Android Auto's list's. */
        private const val ART_RECENT = 320
        private const val ART_LIST = 192

        /**
         * The wake lock lets go after this unless renewed: every sentence
         * read renews it, so only an app that died holding it is let off.
         */
        private const val AWAKE_MS = 10 * 60 * 1000L

        /** After a Play from the lock screen or a headset, until Dart answers. */
        private const val WAKE_FOR_PLAY_MS = 30 * 1000L

        /**
         * A reading ended stays on the card this long: a reading handed to
         * another player (a book's page to the background, one book to the
         * next) puts it up again within it, and once gone, Android might not
         * let the card start again with the app in the background.
         */
        private const val LINGER_MS = 2000L

        /**
         * Paused while reading may still play on by itself (see settle):
         * how soon the foreground is looked at again.
         */
        private const val SETTLE_AGAIN_MS = 15 * 1000L

        /** A Play from outside the app gives Dart this long to start reading. */
        private const val START_TIMEOUT_MS = 30 * 1000L

        /** The browser's roots: Android Auto's, the resume card's, and one with nothing for apps not known. */
        private const val ROOT = "root"
        private const val ROOT_RECENT = "recent"
        private const val ROOT_EMPTY = "empty"

        /** How many books Android Auto lists: the one being read, then the ones read before it. */
        private const val BROWSE_MAX = 12

        // Android Auto's look for the list (androidx.media's MediaConstants,
        // by value: the framework browser has no names for them).
        private const val CONTENT_STYLE_SUPPORTED = "android.media.browse.CONTENT_STYLE_SUPPORTED"
        private const val CONTENT_STYLE_PLAYABLE = "android.media.browse.CONTENT_STYLE_PLAYABLE_HINT"
        private const val CONTENT_STYLE_BROWSABLE = "android.media.browse.CONTENT_STYLE_BROWSABLE_HINT"
        private const val CONTENT_STYLE_LIST = 1
        private const val GROUP_TITLE = "android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT"
        private const val COMPLETION_STATUS = "android.media.extra.PLAYBACK_STATUS"
        private const val COMPLETION_PERCENTAGE = "androidx.media.MediaItem.Extras.COMPLETION_PERCENTAGE"

        /**
         * Apps that may browse the books besides the system's own: Android
         * Auto, Wear OS and the Assistant. Any other is given an empty root:
         * it may still press play, but sees no titles.
         */
        private val CLIENTS = setOf(
            "com.google.android.projection.gearhead",
            "com.google.android.wearable.app",
            "com.google.android.googlequicksearchbox",
            "com.google.android.carassistant",
        )

        /** The buttons that mean Play to a service the app's session is gone from. */
        private val PLAY_KEYS = setOf(
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
        )

        /**
         * Set by ReadingCore while there is an engine; receives "play",
         * "pause", "stop", "next", "prev", "speed", "save", and "seek" with a
         * position in milliseconds.
         */
        @Volatile
        var onAction: ((String, Long) -> Unit)? = null

        @Volatile
        private var instance: ReadAloudService? = null

        private var now = NowReading()

        /** A reading is up (Dart's session, playing or paused). */
        @Volatile
        private var reading = false

        /** A Play from outside the app went foreground; Dart has not taken it up yet. */
        @Volatile
        private var starting = false

        private val main = Handler(Looper.getMainLooper())

        /** Whether reading is under way (playing or paused), for the widgets. */
        fun isRunning(): Boolean = reading

        fun isPlaying(): Boolean = reading && now.playing

        /** Whether a Play from outside the app is being started. */
        fun isStarting(): Boolean = starting

        fun update(ctx: Context, next: NowReading) {
            val previous = now
            val was = reading
            now = next
            reading = true
            starting = false
            main.removeCallbacks(afterEnd)
            // The widgets show play or pause: redraw them when that changes.
            if (previous.playing != next.playing || previous.title != next.title || !was) {
                Widgets.refreshAll(ctx)
            }
            val running = instance
            if (running != null && (running.foreground || running.started)) {
                running.giveUpLater(false)
                running.keepAwake(next.playing)
                // Playing again after a pause: back in the foreground, with
                // the card as it is now.
                val promoted = next.playing && !running.foreground && running.goForeground()
                if (!promoted) {
                    // A new sentence only moves the seek bar; leave the
                    // notification itself alone.
                    if (was && next.copy(positionMs = previous.positionMs) == previous) {
                        running.publishState()
                    } else {
                        running.refresh()
                    }
                }
                running.settle()
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
            reading = false
            instance?.let {
                it.keepAwake(false)
                it.publishState()
            }
            Widgets.refreshAll(ctx)
            main.removeCallbacks(afterEnd)
            main.postDelayed(afterEnd, LINGER_MS)
        }

        /** Dart could not read the book asked for from outside the app. */
        fun mediaFailed() {
            if (!starting) return
            starting = false
            if (reading) return
            val running = instance
            if (running != null) running.standDown("TomeVoice could not open that book") else ReadingCore.idle()
        }

        private val afterEnd = Runnable {
            if (reading || starting) return@Runnable
            val running = instance
            if (running != null) running.standDown() else ReadingCore.idle()
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
     * duration hides the seek bar. [bookId]: the book, when the reading in
     * the background says (a Play from outside for it carries on with it).
     */
    data class NowReading(
        val title: String = "TomeVoice",
        val subtitle: String = "",
        val playing: Boolean = false,
        val cover: String? = null,
        val positionMs: Long = 0,
        val durationMs: Long = 0,
        val speed: Double = 1.0,
        val bookId: String? = null,
    )

    private var session: MediaSession? = null
    private var artPath: String? = null
    private var art: Bitmap? = null
    private var wake: PowerManager.WakeLock? = null

    /** The notification is up (startForeground, not undone since). */
    private var foreground = false

    /** Started (not only bound), so it stops itself when the reading is over. */
    private var started = false

    /** Covers for the browser, read off the main thread. */
    private val work = Executors.newSingleThreadExecutor()

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

    override fun onCreate() {
        super.onCreate()
        instance = this
        val s = MediaSession(this, "TomeVoice")
        s.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = play(null)

            // A book picked in Android Auto.
            override fun onPlayFromMediaId(mediaId: String?, extras: Bundle?) = play(mediaId)

            // "Play <title> on TomeVoice".
            override fun onPlayFromSearch(query: String?, extras: Bundle?) =
                play(Shelf.search(this@ReadAloudService, query)?.id)

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
        // A headset's Play once the app is gone comes here, and after a
        // reboot too: Android keeps the last media app's receiver. Mutable,
        // so the button pressed (filled in by Android) reaches this service.
        @Suppress("DEPRECATION")
        s.setMediaButtonReceiver(
            PendingIntent.getForegroundService(
                this,
                9,
                Intent(Intent.ACTION_MEDIA_BUTTON).setClass(this, ReadAloudService::class.java),
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0) or PendingIntent.FLAG_UPDATE_CURRENT
            )
        )
        s.isActive = true
        session = s
        setSessionToken(s.sessionToken)
        publishState()
        if (!reading) showContinue()
        // Widgets' play buttons now go straight to this service.
        Widgets.refreshAll(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        started = true
        val action = intent?.action
        // A start that promised the notification (startForegroundService:
        // the reading's own, and a headset's Play once the app is gone) puts
        // it up first; a widget's or the notification's button needs it only
        // while a book is being read.
        if (action == null || action == Intent.ACTION_MEDIA_BUTTON || reading) goForeground()
        when (action) {
            ACTION_PLAY -> play(null)
            ACTION_PAUSE -> onAction?.invoke("pause", 0)
            ACTION_NEXT -> onAction?.invoke("next", 0)
            ACTION_PREV -> onAction?.invoke("prev", 0)
            ACTION_STOP -> onAction?.invoke("stop", 0)
            Intent.ACTION_MEDIA_BUTTON -> intent?.let { button(it) }
        }
        if (reading && now.playing) keepAwake(true)
        // Started for a reading that is paused (a book handed on paused):
        // up, as Android requires of a start like this, and out again.
        if (action == null) settle()
        if (!reading && !starting) {
            // Nothing is being read (the app was closed since, or a button
            // with nothing to act on): stop again, and redraw the widgets so
            // their buttons open the app instead.
            standDown()
            val app = applicationContext
            main.postDelayed({ Widgets.refreshAll(app) }, 400)
        }
        return START_NOT_STICKY
    }

    /**
     * TomeVoice swiped from Recents. A book being read reads on: the engine,
     * the voice and the player outlive the activity. A paused one is put
     * away, as a music player's is, and its card becomes the resume card.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (reading && !now.playing) {
            onAction?.invoke("stop", 0)
        } else if (!reading && !starting) {
            standDown()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        instance = null
        giveUpLater(false)
        main.removeCallbacks(settleLater)
        keepAwake(false)
        // Stopped by Android while a book waits, paused: its card stays, and
        // its Play starts the service again. Otherwise it goes.
        if (!reading) cancelCard()
        session?.isActive = false
        session?.release()
        session = null
        art = null
        artPath = null
        foreground = false
        started = false
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        work.shutdown()
        super.onDestroy()
    }

    /**
     * Play, from the card, a headset, the resume card or Android Auto. The
     * reading on the card carries on. Another book, or a Play with nothing
     * on the card (the app was closed), is Dart's to start: that book, or
     * the one read last, from its place.
     */
    private fun play(bookId: String?) {
        if (reading) {
            if (bookId == null || bookId == now.bookId) {
                // Awake until the app has the first sentence under way.
                if (!now.playing) keepAwake(true, WAKE_FOR_PLAY_MS)
                onAction?.invoke("play", 0)
            } else {
                // The card stays up, foreground, while Dart changes book.
                Shelf.book(this, bookId)?.let { ReadingCore.play(this, it.id, reading = true) }
            }
            return
        }
        val book = bookId?.let { Shelf.book(this, it) } ?: Shelf.continueBook(this)
        if (book == null) {
            publishState("Add a book to TomeVoice first")
            return
        }
        starting = true
        now = NowReading(title = book.title, subtitle = book.author, playing = true, cover = book.cover, bookId = book.id)
        // Foreground now, within the seconds Android allows for a start from
        // a media button or the system's media controls.
        if (!started) {
            try {
                startForegroundService(Intent(this, ReadAloudService::class.java))
                started = true
            } catch (e: Exception) {
                starting = false
                publishState("TomeVoice could not start reading")
                return
            }
        }
        goForeground()
        keepAwake(true, WAKE_FOR_PLAY_MS)
        giveUpLater(true)
        ReadingCore.play(this, book.id, reading = false)
    }

    /** A media button sent here, the app's session gone: Play reads on. */
    private fun button(intent: Intent) {
        @Suppress("DEPRECATION")
        val key = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
        if (key != null && reading) {
            session?.controller?.dispatchMediaButtonEvent(key)
            return
        }
        // No key at all (an intent that could not be filled in) is a Play.
        if (key == null || (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0 && key.keyCode in PLAY_KEYS)) {
            play(null)
        }
    }

    private val giveUp = Runnable {
        if (!starting || reading) return@Runnable
        starting = false
        standDown("TomeVoice could not start reading")
    }

    private fun giveUpLater(on: Boolean) {
        main.removeCallbacks(giveUp)
        if (on) main.postDelayed(giveUp, START_TIMEOUT_MS)
    }

    /** The notification up, as a foreground service. False if Android refused it. */
    private fun goForeground(): Boolean = try {
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        foreground = true
        true
    } catch (e: Exception) {
        // Android 12+ refused a start from the background
        // (ForegroundServiceStartNotAllowedException).
        false
    }

    /**
     * Paused: out of the foreground, the card kept (now one that can be
     * swiped away), so a book left paused no longer holds the app up for
     * good and Android may take its memory back. Play puts it back in the
     * foreground ([update]). Not while reading may play on by itself (the
     * phone's audio taken a moment, or Play waiting for a call to end, see
     * ReadingCore.audioMayReturn): Android 12+ would not let the app go
     * foreground again then, from the background. That is looked at again
     * every little while until it no longer may.
     */
    private fun settle() {
        main.removeCallbacks(settleLater)
        if (!foreground || !reading || now.playing || starting) return
        if (ReadingCore.audioMayReturn()) {
            main.postDelayed(settleLater, SETTLE_AGAIN_MS)
            return
        }
        foreground = false
        stopForeground(STOP_FOREGROUND_DETACH)
    }

    private val settleLater = Runnable { settle() }

    /** The card, left up by [settle] apart from the service, goes. */
    private fun cancelCard() {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }

    /**
     * The reading is over: the notification goes, and the service unless
     * something is bound to it (the system's media controls, Android Auto).
     * With no activity either, the engine goes after it.
     */
    fun standDown(error: String? = null) {
        giveUpLater(false)
        main.removeCallbacks(settleLater)
        keepAwake(false)
        if (foreground) {
            foreground = false
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        }
        // Left up on a pause, it is the app's own notification now.
        cancelCard()
        publishState(error)
        if (started) {
            started = false
            stopSelf()
        }
        ReadingCore.idle()
    }

    fun refresh() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build())
    }

    /** Play state, place in the chapter and the speed button. [error]: said instead. */
    fun publishState(error: String? = null) {
        val n = now
        val seekable = reading && n.durationMs > 0
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_PLAY_FROM_MEDIA_ID or PlaybackState.ACTION_PLAY_FROM_SEARCH
        if (seekable) actions = actions or PlaybackState.ACTION_SEEK_TO
        val position = if (seekable) {
            n.positionMs.coerceIn(0, n.durationMs)
        } else {
            PlaybackState.PLAYBACK_POSITION_UNKNOWN
        }
        val state = when {
            error != null -> PlaybackState.STATE_ERROR
            starting -> PlaybackState.STATE_BUFFERING
            !reading -> PlaybackState.STATE_STOPPED
            n.playing -> PlaybackState.STATE_PLAYING
            else -> PlaybackState.STATE_PAUSED
        }
        val builder = PlaybackState.Builder()
            .setActions(actions)
            .setState(
                state,
                position,
                // The position is already in time at this speed, so the bar
                // runs at real time between sentences.
                if (state == PlaybackState.STATE_PLAYING) 1f else 0f
            )
        if (error != null) builder.setErrorMessage(error)
        if (reading) {
            builder
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
        }
        session?.setPlaybackState(builder.build())
    }

    /** The cover at card size, decoded once per book. */
    private fun artFor(path: String?): Bitmap? {
        if (path == artPath) return art
        artPath = path
        art = path?.let { Shelf.cover(it, ART_MAX) }
        return art
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

    // ------------------------------------------------------------- browser

    /**
     * Who may see the books. The system's resume card asks with EXTRA_RECENT
     * (System UI, a system app) and gets the book to carry on with; Android
     * Auto and the other known clients, and the system's own apps, get the
     * list; any other app an empty root.
     */
    override fun onGetRoot(clientPackageName: String, clientUid: Int, rootHints: Bundle?): MediaBrowserService.BrowserRoot? {
        val known = trusted(clientPackageName, clientUid)
        if (rootHints?.getBoolean(MediaBrowserService.BrowserRoot.EXTRA_RECENT) == true) {
            if (!known) return null
            return MediaBrowserService.BrowserRoot(
                ROOT_RECENT,
                Bundle().apply { putBoolean(MediaBrowserService.BrowserRoot.EXTRA_RECENT, true) }
            )
        }
        if (!known) return MediaBrowserService.BrowserRoot(ROOT_EMPTY, null)
        return MediaBrowserService.BrowserRoot(
            ROOT,
            Bundle().apply {
                putBoolean(CONTENT_STYLE_SUPPORTED, true)
                putInt(CONTENT_STYLE_PLAYABLE, CONTENT_STYLE_LIST)
                putInt(CONTENT_STYLE_BROWSABLE, CONTENT_STYLE_LIST)
            }
        )
    }

    /**
     * The books, playable, with their titles, authors and covers: under
     * [ROOT_RECENT] only the one Play carries on with (the resume card
     * takes the first), under [ROOT] that one under "Continue" and the ones
     * read before it under "Recent".
     */
    override fun onLoadChildren(parentId: String, result: MediaBrowserService.Result<List<MediaBrowser.MediaItem>>) {
        result.detach()
        val ctx = applicationContext
        work.execute {
            val items: List<MediaBrowser.MediaItem> = try {
                when (parentId) {
                    ROOT_RECENT -> listOfNotNull(Shelf.continueBook(ctx)).map { item(it, ART_RECENT, null) }
                    ROOT -> {
                        val first = Shelf.continueBook(ctx)
                        val rest = Shelf.books(ctx).filter { it.id != first?.id }
                        listOfNotNull(first?.let { item(it, ART_LIST, "Continue") }) +
                            rest.take(BROWSE_MAX - 1).map { item(it, ART_LIST, "Recent") }
                    }
                    else -> emptyList()
                }
            } catch (e: Exception) {
                emptyList()
            }
            main.post { result.sendResult(items) }
        }
    }

    private fun item(b: Shelf.Book, artMax: Int, group: String?): MediaBrowser.MediaItem {
        val extras = Bundle()
        if (group != null) extras.putString(GROUP_TITLE, group)
        // How far along, drawn by Android Auto: not started, under way, read.
        extras.putInt(
            COMPLETION_STATUS,
            when {
                b.progress <= 0.0 -> 0
                b.progress >= 0.995 -> 2
                else -> 1
            }
        )
        extras.putDouble(COMPLETION_PERCENTAGE, b.progress.coerceIn(0.0, 1.0))
        val d = MediaDescription.Builder()
            .setMediaId(b.id)
            .setTitle(b.title)
            .setSubtitle(b.author)
            .setDescription(b.where)
            .setExtras(extras)
        b.cover?.let { Shelf.cover(it, artMax) }?.let { d.setIconBitmap(it) }
        return MediaBrowser.MediaItem(d.build(), MediaBrowser.MediaItem.FLAG_PLAYABLE)
    }

    private fun trusted(pkg: String, uid: Int): Boolean {
        if (uid == Process.myUid() || uid == Process.SYSTEM_UID || pkg in CLIENTS) return true
        return try {
            // A client that binds is visible to this app (Android 11 package
            // visibility), and the browser has checked that pkg is its uid's.
            @Suppress("DEPRECATION")
            val info = packageManager.getApplicationInfo(pkg, 0)
            info.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
        } catch (e: Exception) {
            false
        }
    }

    /**
     * With nothing being read, the book Play would read is on the session,
     * for what shows it with no card (Android Auto).
     */
    private fun showContinue() {
        val ctx = applicationContext
        work.execute {
            val book = Shelf.continueBook(ctx)
            val cover = book?.cover?.let { Shelf.cover(it, ART_MAX) }
            main.post {
                if (reading || starting || book == null) return@post
                val meta = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_MEDIA_ID, book.id)
                    .putString(MediaMetadata.METADATA_KEY_TITLE, book.title)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, book.author)
                if (cover != null) meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, cover)
                session?.setMetadata(meta.build())
            }
        }
    }
}

/**
 * The books played from outside the app (the resume card, a headset's Play,
 * Android Auto), read from library.json here, as the widgets read it: the
 * app may not be running. Books on a secret shelf are never among them, open
 * or not: only the app knows whether the shelf is open.
 */
object Shelf {

    class Book(
        val id: String,
        val title: String,
        val author: String,
        /** Where the reader is: "Chapter 12: The Fool". */
        val where: String,
        val progress: Double,
        val cover: String?,
        /** When it was last opened ("" if never), and added. */
        val openedAt: String,
        val addedAt: String,
    )

    /** The books, the one touched last first (opened, or added if never opened), as the shelf lists them. */
    fun books(ctx: Context): List<Book> {
        val lib = try {
            JSONObject(File(Widgets.root(ctx), "library.json").readText())
        } catch (e: Exception) {
            return emptyList()
        }
        // As LibraryStore reads it: no categories are the two it starts with,
        // a book's unknown category is the default, an unknown default is the
        // first. A book is secret if the shelf it shows on is.
        val ids = mutableListOf<String>()
        val secret = mutableSetOf<String>()
        val cats = lib.optJSONArray("categories")
        for (i in 0 until (cats?.length() ?: 0)) {
            val c = cats?.optJSONObject(i) ?: continue
            val id = c.optString("id")
            ids.add(id)
            if (c.optBoolean("secret", false)) secret.add(id)
        }
        if (ids.isEmpty()) ids.addAll(listOf("reading", "later"))
        val named = lib.optString("defaultCategory")
        val fallback = if (named in ids) named else ids.first()
        val arr = lib.optJSONArray("books") ?: return emptyList()
        val out = mutableListOf<Book>()
        for (i in 0 until arr.length()) {
            val b = arr.optJSONObject(i) ?: continue
            val id = b.optString("id")
            if (id.isEmpty()) continue
            val category = b.optString("category").takeIf { it in ids } ?: fallback
            if (category in secret) continue
            val cover = when (b.optString("coverMode", "auto")) {
                "plain" -> null
                "custom" -> b.optString("customCover").ifEmpty { b.optString("cover") }
                else -> b.optString("cover")
            }?.ifEmpty { null }
            val authors = b.optJSONArray("authors")
            out.add(
                Book(
                    id = id,
                    title = b.optString("title", "TomeVoice"),
                    author = (0 until (authors?.length() ?: 0)).mapNotNull { authors?.optString(it) }
                        .filter { it.isNotBlank() }.joinToString(", "),
                    where = b.optString("where"),
                    progress = b.optDouble("progress", 0.0),
                    cover = cover,
                    openedAt = b.optString("openedAt"),
                    addedAt = b.optString("addedAt"),
                )
            )
        }
        return out.sortedByDescending { it.openedAt.ifEmpty { it.addedAt } }
    }

    /** The book being read: the one opened last, else the one added last. */
    fun continueBook(ctx: Context): Book? {
        val all = books(ctx)
        return all.filter { it.openedAt.isNotEmpty() }.maxByOrNull { it.openedAt } ?: all.firstOrNull()
    }

    fun book(ctx: Context, id: String): Book? = books(ctx).firstOrNull { it.id == id }

    /** The book a spoken request names, by its title, else its author; null for none (or no words). */
    fun search(ctx: Context, query: String?): Book? {
        val q = query?.trim().orEmpty()
        if (q.isEmpty()) return null
        val all = books(ctx)
        return all.firstOrNull { it.title.contains(q, ignoreCase = true) }
            ?: all.firstOrNull { it.author.contains(q, ignoreCase = true) }
    }

    /**
     * The cover at [max] pixels on its long side, RGB_565: half the bytes of
     * ARGB, as the session and the browser send pictures between processes,
     * and that has a size limit.
     */
    fun cover(path: String, max: Int): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= max) sample *= 2
        val decoded = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.RGB_565
            }
        )
        val long = if (decoded == null) 0 else maxOf(decoded.width, decoded.height)
        if (decoded == null || long <= max) {
            decoded
        } else {
            val k = max.toFloat() / long
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
}
