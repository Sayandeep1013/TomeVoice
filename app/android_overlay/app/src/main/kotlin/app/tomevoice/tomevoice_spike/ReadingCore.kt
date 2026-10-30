package app.tomevoice.tomevoice_spike

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.webkit.WebSettings
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reading aloud for the life of the process, not of the activity: the
 * Flutter engine, the voice (one warm TextToSpeech), the player, the phone's
 * audio, and the channel ("tomevoice/tts") between them and Dart.
 *
 * The engine lives in FlutterEngineCache under [ENGINE_ID] and is made by
 * whichever needs it first:
 *
 * - MainActivity (provideFlutterEngine), which runs main() on it: the app.
 * - ReadAloudService, for Play on the system's resume card, a headset's Play
 *   or Android Auto with no activity, which runs backgroundMain() on it
 *   (lib/main.dart): the library is opened and the book read, and nothing is
 *   drawn until an activity attaches and the app is built on the same engine.
 *
 * Reading's calls (the voice, the player, the phone's audio, the card) are
 * answered here, with or without an activity ([handle]). MainActivity puts
 * its own handler on the channel while it is attached, asks this one first
 * and answers the rest itself (pickers, the window, prompts); with no
 * activity, [alone] answers what needs no screen and quietly turns down
 * what does.
 *
 * The engine outlives the activity while a book is being read, or about to
 * be: a swipe from Recents, or Android closing the activity, leaves the voice
 * reading. With nothing read and no activity it goes ([idle]), so the next
 * opening starts afresh, as it always did.
 *
 * TTS: one engine instance, created with the Flutter engine and kept warm.
 * Listing voices and synthesising both use it. Earlier builds created a
 * throwaway engine for the engine list, another for the voice list and a
 * third for synthesis, each paying a service bind and model load; that was
 * the "voices lag". Synthesis still uses synthesizeToFile, never speak(): the
 * architecture requires PCM we can process (docs/10 ADR-003). onRangeStart is
 * captured verbatim; the Dart side detects its parameter layout.
 */
object ReadingCore {

    const val ENGINE_ID = "tomevoice"
    private const val CHANNEL = "tomevoice/tts"

    /** The engine goes this long after the last reading ended with no activity: Dart's last writes land first. */
    private const val RETIRE_AFTER_MS = 3000L

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    /** The application; set when anything first asks for the engine. */
    private lateinit var app: Context

    private var channel: MethodChannel? = null

    /**
     * The activity showing the app: set as it takes the engine (before the
     * one it replaces, if any, lets go), cleared as it lets go.
     */
    private var activity: MainActivity? = null

    /** A book asked for from outside the app, until Dart takes it ("takeMediaPlay"). */
    private var asked: Map<String, Any>? = null

    val player = PcmPlayer()

    /**
     * The engine, made and cached if there is none yet. Dart is not run
     * here: the activity runs main() on a new one, [runInBackground]
     * backgroundMain().
     */
    fun engine(ctx: Context): FlutterEngine {
        app = ctx.applicationContext
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(app)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        bind(engine)
        return engine
    }

    /** The engine for [a], which is to show the app from now on. */
    fun engineFor(a: MainActivity): FlutterEngine {
        val engine = engine(a)
        main.removeCallbacks(retire)
        activity = a
        return engine
    }

    /** Whether [a] is the activity showing the app now (not one a newer one replaced). */
    fun shows(a: MainActivity): Boolean = activity === a

    /** [a] lets go of the engine: its own calls go with it, reading's stay. */
    fun detach(a: MainActivity) {
        if (activity !== a) return
        activity = null
        channel?.setMethodCallHandler { call, result -> alone(call, result) }
    }

    /**
     * The engine with Dart running, for a book read with no activity: at
     * backgroundMain, unless Dart already runs on it (the app is open, or
     * was opened and closed while a book read on).
     */
    fun runInBackground(ctx: Context): FlutterEngine {
        val engine = engine(ctx)
        if (!engine.dartExecutor.isExecutingDart) {
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    "backgroundMain",
                )
            )
        }
        return engine
    }

    /**
     * Read [bookId], asked for from outside the app (ReadAloudService):
     * kept for Dart to take, Dart started if it is not running, and woken
     * if it is. [reading]: whether a reading had the card when it was asked.
     */
    fun play(ctx: Context, bookId: String, reading: Boolean) {
        asked = mapOf("book" to bookId, "reading" to reading)
        runInBackground(ctx)
        event(mapOf("type" to "mediaPlay"))
    }

    /**
     * Nothing is being read: with no activity either, the engine goes in a
     * moment, and with it the voice and the player. The next Play from
     * outside the app starts it again.
     */
    fun idle() {
        main.removeCallbacks(retire)
        main.postDelayed(retire, RETIRE_AFTER_MS)
    }

    private val retire = Runnable {
        if (activity != null || ReadAloudService.isRunning() || ReadAloudService.isStarting()) return@Runnable
        // Its lifecycle listener (bind) lets everything else go.
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.destroy()
    }

    /** A platform event to Dart (SpeechService.events). */
    fun event(payload: Map<String, Any?>) {
        main.post { channel?.invokeMethod("platformEvent", payload) }
    }

    private fun bind(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result -> alone(call, result) }
        // The card's and a headset's buttons, to whichever player reads.
        ReadAloudService.onAction = { action, value ->
            event(mapOf("type" to "action", "action" to action, "value" to value))
        }
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit

            override fun onEngineWillDestroy() = unbind()
        })
        // Speech made for an engine before this one: nothing will read it.
        // (Not on each activity: the voice may be reading from these.)
        io.execute { synthDir().listFiles()?.forEach { it.delete() } }
        // Warm the voice now so the first Play does not pay for the bind.
        withTts(null) { }
    }

    private fun unbind() {
        main.removeCallbacks(retire)
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
        asked = null
        ReadAloudService.onAction = null
        player.stop()
        abandonFocus()
        tts?.shutdown()
        tts = null
        ttsReady = false
        ttsWaiters.clear()
    }

    /** Reading's calls: true when [call] was one of them (and is answered). */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "listEngines" -> listEngines(result)
            "listVoices" -> listVoices(call.argument<String>("engineId"), result)
            "synthesise" -> synthesise(call.arguments as Map<*, *>, result)
            "cancelSynthesis" -> {
                // Seeking should not wait for a sentence nobody will hear.
                try {
                    if (ttsReady) tts?.stop()
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "playerEnqueue" -> {
                val pcm = call.argument<ByteArray>("pcm")
                val rate = call.argument<Int>("sampleRate") ?: 24000
                if (pcm == null) {
                    result.error("NO_PCM", "No audio", null)
                } else {
                    if (!player.isActive) requestFocus()
                    try {
                        result.success(player.enqueue(pcm, rate))
                    } catch (e: Exception) {
                        result.error("PLAYER", e.message ?: "The audio could not be played", null)
                    }
                }
            }
            "playerPosition" -> result.success(player.position(call.argument<Boolean>("raw") == true))
            "playerPause" -> {
                player.pause()
                result.success(null)
            }
            "playerResume" -> {
                // Dart asked for focus first; during a call it waits for
                // the gain instead of reading over the call.
                if (requestFocus() == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) player.resume()
                result.success(null)
            }
            "playerStop" -> {
                player.stop()
                result.success(null)
            }
            "requestFocus" -> result.success(
                when (requestFocus()) {
                    AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> "granted"
                    AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> "delayed"
                    else -> "failed"
                }
            )
            "playerVolume" -> {
                player.setVolume((call.argument<Double>("volume") ?: 1.0).toFloat())
                result.success(null)
            }
            "playerLatency" -> {
                player.setOffsets(
                    (call.argument<Int>("bluetoothMs") ?: 0).toLong(),
                    (call.argument<Int>("otherMs") ?: 0).toLong(),
                )
                result.success(null)
            }
            "playerRoute" -> result.success(if (player.onBluetoothNow() ?: bluetoothOut()) "bluetooth" else "other")
            "session" -> session(call.arguments as Map<*, *>, result)
            // A book asked for from outside the app, once.
            "takeMediaPlay" -> {
                result.success(asked)
                asked = null
            }
            "mediaPlayFailed" -> {
                ReadAloudService.mediaFailed()
                result.success(null)
            }
            "activityAttached" -> result.success(activity != null)
            else -> return false
        }
        return true
    }

    /**
     * The channel with no activity attached: reading's calls, what needs no
     * screen, and a quiet answer for what does (there is no window to keep
     * on, nothing was opened with the app).
     */
    private fun alone(call: MethodCall, result: MethodChannel.Result) {
        if (handle(call, result)) return
        when (call.method) {
            "outputDir" -> result.success((app.getExternalFilesDir(null) ?: app.filesDir).absolutePath)
            "shareDir" -> result.success(ShareProvider.dir(app.cacheDir).absolutePath)
            "webUserAgent" -> result.success(
                try {
                    // As BrowserCheck.userAgent gives it, from the application.
                    WebSettings.getDefaultUserAgent(app)
                        .replace("; wv)", ")")
                        .replace(Regex("Version/\\d+(\\.\\d+)* "), "")
                } catch (e: Exception) {
                    null
                }
            )
            "refreshWidgets" -> {
                Widgets.refreshAll(app)
                result.success(null)
            }
            "appVersion" -> {
                try {
                    @Suppress("DEPRECATION")
                    result.success(app.packageManager.getPackageInfo(app.packageName, 0).versionName)
                } catch (e: Exception) {
                    result.success(null)
                }
            }
            "is64Bit" -> result.success(android.os.Process.is64Bit())
            "deviceSecure" -> result.success((app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceSecure)
            "launchArgs" -> result.success(emptyMap<String, String>())
            "keepScreenOn", "volumeKeysTurnPages", "hideRecents",
            "pendingOpen", "widgetLaunch", "browserFetch" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------- session

    /** Start, update or end the "reading aloud" service and its card. */
    private fun session(args: Map<*, *>, result: MethodChannel.Result) {
        val active = args["active"] == true
        if (!active) {
            ReadAloudService.end(app)
            abandonFocus()
            result.success(null)
            return
        }
        try {
            ReadAloudService.update(
                app,
                ReadAloudService.NowReading(
                    title = (args["title"] as? String) ?: "TomeVoice",
                    subtitle = (args["subtitle"] as? String) ?: "",
                    playing = args["playing"] == true,
                    cover = args["cover"] as? String,
                    positionMs = (args["positionMs"] as? Number)?.toLong() ?: 0,
                    durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0,
                    speed = (args["speed"] as? Number)?.toDouble() ?: 1.0,
                    bookId = args["book"] as? String,
                )
            )
            result.success(null)
        } catch (e: Exception) {
            // Reading still works in the foreground; it just will not survive
            // the screen turning off.
            result.error("SESSION", e.message, null)
        }
    }

    // ------------------------------------------------------------------ TTS

    private var tts: TextToSpeech? = null
    private var ttsEngineId: String? = null
    private var ttsReady = false
    private val ttsWaiters = mutableListOf<(TextToSpeech?) -> Unit>()

    private fun synthDir(): File = File(app.cacheDir, "tts").apply { mkdirs() }

    private fun engineMatches(requested: String?): Boolean {
        val current = tts ?: return false
        if (requested.isNullOrBlank()) return true
        if (requested == ttsEngineId) return true
        return ttsEngineId == null && requested == current.defaultEngine
    }

    /** Run [block] with a ready engine (or null if it failed to start). */
    private fun withTts(engineId: String?, block: (TextToSpeech?) -> Unit) {
        val current = tts
        if (current != null && engineMatches(engineId)) {
            if (ttsReady) block(current) else ttsWaiters.add(block)
            return
        }
        current?.shutdown()
        ttsReady = false
        ttsEngineId = if (engineId.isNullOrBlank()) null else engineId
        ttsWaiters.add(block)
        val holder = arrayOfNulls<TextToSpeech>(1)
        val created = TextToSpeech(app, { status ->
            main.post {
                val engine = holder[0]
                if (engine == null || tts !== engine) return@post
                ttsReady = status == TextToSpeech.SUCCESS
                if (!ttsReady) {
                    tts = null
                    engine.shutdown()
                }
                val waiting = ttsWaiters.toList()
                ttsWaiters.clear()
                waiting.forEach { it(if (ttsReady) engine else null) }
            }
        }, ttsEngineId)
        holder[0] = created
        tts = created
    }

    private fun listEngines(result: MethodChannel.Result) {
        withTts(null) { engine ->
            if (engine == null) {
                result.error("TTS_INIT", "No text-to-speech engine could start", null)
                return@withTts
            }
            result.success(engine.engines.map { mapOf("name" to it.name, "label" to it.label) })
        }
    }

    /** Voices of [engineId], best quality first. */
    private fun listVoices(engineId: String?, result: MethodChannel.Result) {
        withTts(engineId) { engine ->
            if (engine == null) {
                result.error("TTS_INIT", "The voice engine did not start", null)
                return@withTts
            }
            val voices = try {
                (engine.voices ?: emptySet())
                    .sortedWith(
                        compareByDescending<android.speech.tts.Voice> { it.quality }
                            .thenBy { it.name }
                    )
                    .map {
                        mapOf(
                            "name" to it.name,
                            "locale" to it.locale.toLanguageTag(),
                            "quality" to it.quality,
                            "networkRequired" to it.isNetworkConnectionRequired,
                            "installed" to !it.features.contains(
                                TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED
                            )
                        )
                    }
            } catch (e: Exception) {
                emptyList()
            }
            result.success(voices)
        }
    }

    /**
     * [engine] is dead: its service went away (an update of Speech Services
     * kills it) and the binding still looks alive, so every sentence after
     * failed or timed out. It is shut down and forgotten, and the next use
     * makes a new one: still one warm engine, not one per sentence.
     */
    private fun ttsDied(engine: TextToSpeech?) {
        if (engine == null || tts !== engine) return
        try {
            engine.shutdown()
        } catch (_: Exception) {
        }
        tts = null
        ttsReady = false
    }

    private fun synthesise(args: Map<*, *>, result: MethodChannel.Result, retried: Boolean = false) {
        val text = (args["text"] as? String).orEmpty()
        val engineId = args["engineId"] as? String
        val rate = (args["rate"] as? Number)?.toFloat() ?: 1.0f
        val pitch = (args["pitch"] as? Number)?.toFloat() ?: 1.0f
        val wanted = args["voiceName"] as? String

        if (text.isBlank()) {
            result.error("EMPTY_TEXT", "Nothing to synthesise", null)
            return
        }

        val replied = AtomicBoolean(false)
        fun reply(block: () -> Unit) {
            if (replied.compareAndSet(false, true)) main.post(block)
        }

        /** The engine died under this sentence: a new one, and the sentence again, once. */
        fun again(engine: TextToSpeech, fallback: () -> Unit) {
            if (!retried && replied.compareAndSet(false, true)) {
                main.post {
                    ttsDied(engine)
                    synthesise(args, result, retried = true)
                }
            } else {
                main.post { ttsDied(engine) }
                reply(fallback)
            }
        }

        var used: TextToSpeech? = null
        main.postDelayed({
            // No word from the engine in 30 s: it may be dead. The next
            // sentence gets a new one.
            if (!replied.get()) ttsDied(used)
            reply { result.error("TTS_TIMEOUT", "No callback within 30s", null) }
        }, 30_000)

        withTts(engineId) { engine ->
            if (engine == null) {
                reply { result.error("TTS_INIT", "The voice engine did not start", null) }
                return@withTts
            }
            used = engine
            val events = CopyOnWriteArrayList<Map<String, Int>>()
            val utteranceId = "tv-" + System.nanoTime()
            val outFile = File(synthDir(), "$utteranceId.wav")
            try {
                if (!wanted.isNullOrBlank() && engine.voice?.name != wanted) {
                    engine.voices?.firstOrNull { it.name == wanted }?.let { engine.voice = it }
                }
                engine.setSpeechRate(rate)
                engine.setPitch(pitch)
                // The engine has one listener. A late callback for an utterance
                // that was cancelled must not complete this one, so every
                // callback checks the id.
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) = Unit

                    override fun onRangeStart(id: String?, start: Int, end: Int, frame: Int) {
                        if (id != utteranceId) return
                        events.add(mapOf("start" to start, "end" to end, "frame" to frame))
                    }

                    override fun onDone(id: String?) {
                        if (id != utteranceId) return
                        reply { result.success(buildReport(text, outFile, events, engine)) }
                    }

                    override fun onStop(id: String?, interrupted: Boolean) {
                        if (id != utteranceId) return
                        outFile.delete()
                        reply { result.error("TTS_STOPPED", "Synthesis cancelled", null) }
                    }

                    @Deprecated("Required by the base class")
                    override fun onError(id: String?) {
                        if (id != utteranceId) return
                        reply { result.error("TTS_ERROR", "Synthesis failed", null) }
                    }

                    override fun onError(id: String?, errorCode: Int) {
                        if (id != utteranceId) return
                        val failed = {
                            result.error("TTS_ERROR", "Synthesis failed (code $errorCode)", null)
                        }
                        // The engine's service failed: a new engine, and again.
                        if (errorCode == TextToSpeech.ERROR_SERVICE) again(engine, failed) else reply(failed)
                    }
                })
                val code = engine.synthesizeToFile(text, Bundle(), outFile, utteranceId)
                if (code != TextToSpeech.SUCCESS) {
                    // Not even queued: the binding is gone.
                    again(engine) { result.error("TTS_QUEUE", "synthesizeToFile returned $code", null) }
                }
            } catch (e: Exception) {
                reply { result.error("TTS_EXCEPTION", e.message, null) }
            }
        }
    }

    private fun buildReport(
        text: String,
        file: File,
        events: List<Map<String, Int>>,
        engine: TextToSpeech
    ): Map<String, Any?> {
        val words = text.trim().split(Regex("\\s+")).count { it.isNotBlank() }
        val granularity = when {
            events.isEmpty() -> "none"
            words > 0 && events.size >= (words * 0.6) -> "word"
            else -> "utterance"
        }
        return mapOf(
            "wavPath" to file.absolutePath,
            "engineId" to (ttsEngineId ?: engine.defaultEngine ?: "unknown"),
            "voiceName" to (engine.voice?.name ?: "unknown"),
            "voiceQuality" to (engine.voice?.quality ?: -1),
            "rangeEvents" to events,
            "rangeStartFired" to events.isNotEmpty(),
            "granularity" to granularity,
            "wordCount" to words,
            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "androidVersion" to Build.VERSION.SDK_INT
        )
    }

    // ---------------------------------------------------------- audio focus

    private var focusRequest: AudioFocusRequest? = null
    private var noisyRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                event(mapOf("type" to "noisy"))
            }
        }
    }

    /**
     * Ask for the audio; the answer is AudioManager's: granted, delayed (a
     * call is on: AUDIOFOCUS_GAIN arrives as "focusGain" when it ends) or
     * failed. It used to be ignored, and Play during a call read over it.
     */
    private fun requestFocus(): Int {
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (focusRequest == null) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setWillPauseWhenDucked(true)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener { change ->
                    val type = when (change) {
                        AudioManager.AUDIOFOCUS_LOSS -> "focusLoss"
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "focusLossTransient"
                        AudioManager.AUDIOFOCUS_GAIN -> "focusGain"
                        else -> null
                    }
                    if (type != null) event(mapOf("type" to type))
                }
                .build()
            focusRequest = req
        }
        val answer = am.requestAudioFocus(focusRequest!!)
        if (!noisyRegistered) {
            // On the application, not an activity: it must hear the
            // headphones come out with no activity at all.
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            val flags = if (Build.VERSION.SDK_INT >= 33) Context.RECEIVER_NOT_EXPORTED else 0
            app.registerReceiver(noisyReceiver, filter, flags)
            noisyRegistered = true
        }
        return answer
    }

    /** Whether a Bluetooth output is connected, for when nothing is playing to ask. */
    private fun bluetoothOut(): Boolean = try {
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { PcmPlayer.isBluetooth(it.type) }
    } catch (e: Exception) {
        false
    }

    private fun abandonFocus() {
        if (!::app.isInitialized) return
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        focusRequest?.let { am.abandonAudioFocusRequest(it) }
        if (noisyRegistered) {
            try {
                app.unregisterReceiver(noisyReceiver)
            } catch (_: Exception) {
            }
            noisyRegistered = false
        }
    }
}
