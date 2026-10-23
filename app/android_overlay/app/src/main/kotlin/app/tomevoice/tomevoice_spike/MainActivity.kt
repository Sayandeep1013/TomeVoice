package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Platform side of TomeVoice: the TTS engine, the PCM player, file import and
 * the foreground service hooks.
 *
 * TTS: one engine instance, created at launch and kept warm. Listing voices
 * and synthesising both use it. Earlier builds created a throwaway engine for
 * the engine list, another for the voice list and a third for synthesis, each
 * paying a service bind and model load; that was the "voices lag".
 *
 * Synthesis still uses synthesizeToFile, never speak(): the architecture
 * requires PCM we can process (docs/10 ADR-003). onRangeStart is captured
 * verbatim; the Dart side detects its parameter layout.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "tomevoice/tts"
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val pages = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    private var tts: TextToSpeech? = null
    private var ttsEngineId: String? = null
    private var ttsReady = false
    private val ttsWaiters = mutableListOf<(TextToSpeech?) -> Unit>()

    private val player = PcmPlayer()
    private var pickResult: MethodChannel.Result? = null
    private var imageResult: MethodChannel.Result? = null
    private var pendingOpen: Map<String, String>? = null

    /** A widget was tapped: the book to open (and play), or the page to show. */
    private var pendingWidget: Map<String, Any>? = null

    // A backup or restore waiting on Android's file dialog.
    private var backupResult: MethodChannel.Result? = null
    private var backupManifest = ""
    private var backupChapters = true
    private var restoreResult: MethodChannel.Result? = null
    private var restoreStaging: File? = null

    private var focusRequest: AudioFocusRequest? = null
    private var noisyRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                event(mapOf("type" to "noisy"))
            }
        }
    }

    companion object {
        private const val REQ_PICK = 71
        private const val REQ_NOTIFY = 72
        private const val REQ_IMAGE = 73
        private const val REQ_BACKUP = 74
        private const val REQ_RESTORE = 75
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
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
                "openTtsSettings" -> {
                    try {
                        startActivity(
                            Intent("com.android.settings.TTS_SETTINGS")
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "playerEnqueue" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    val rate = call.argument<Int>("sampleRate") ?: 24000
                    if (pcm == null) {
                        result.error("NO_PCM", "No audio", null)
                    } else {
                        if (!player.isActive) requestFocus()
                        result.success(player.enqueue(pcm, rate))
                    }
                }
                "playerPosition" -> result.success(player.position())
                "playerPause" -> {
                    player.pause()
                    result.success(null)
                }
                "playerResume" -> {
                    requestFocus()
                    player.resume()
                    result.success(null)
                }
                "playerStop" -> {
                    player.stop()
                    result.success(null)
                }
                "session" -> session(call.arguments as Map<*, *>, result)
                "pickDocuments" -> pickDocuments(result)
                "pickImage" -> {
                    if (imageResult != null) {
                        result.error("PICK_IN_PROGRESS", "A picker is already open", null)
                    } else {
                        imageResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "image/*"
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_IMAGE)
                    }
                }
                "pendingOpen" -> {
                    result.success(pendingOpen)
                    pendingOpen = null
                }
                "extractPdf" -> extractPdf(call.argument<String>("path"), result)
                "pdfInfo" -> {
                    val path = call.argument<String>("path").orEmpty()
                    pages.execute {
                        try {
                            val info = PdfPages.info(path)
                            main.post { result.success(info) }
                        } catch (e: Throwable) {
                            main.post { result.error("PDF_PAGES", e.message ?: "Cannot show pages", null) }
                        }
                    }
                }
                "pdfRender" -> {
                    val path = call.argument<String>("path").orEmpty()
                    val index = call.argument<Int>("page") ?: 0
                    val width = call.argument<Int>("width") ?: 1080
                    pages.execute {
                        try {
                            val file = PdfPages.render(path, index, width, cacheDir)
                            main.post { result.success(file) }
                        } catch (e: Throwable) {
                            main.post { result.error("PDF_PAGES", e.message ?: "Cannot draw page", null) }
                        }
                    }
                }
                "outputDir" -> result.success(outputDir().absolutePath)
                "launchArgs" -> result.success(launchArgs())
                "openUrl" -> {
                    try {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url").orEmpty()))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "readNovelDokushaBackup" -> {
                    val path = call.argument<String>("path").orEmpty()
                    // Its own thread: a backup can be large, and the shared
                    // executors serve speech and PDF pages.
                    Thread {
                        try {
                            val out = NovelDokushaImport.read(path, cacheDir)
                            main.post { result.success(out) }
                        } catch (e: Throwable) {
                            main.post { result.error("ND_IMPORT", e.message ?: "Cannot read that backup", null) }
                        }
                    }.start()
                }
                "backupSize" -> {
                    val chapters = call.argument<Boolean>("includeChapters") != false
                    Thread {
                        val bytes = try {
                            LibraryBackup.size(outputDir(), chapters)
                        } catch (e: Throwable) {
                            -1L
                        }
                        main.post { result.success(bytes) }
                    }.start()
                }
                "backupLibrary" -> {
                    if (backupResult != null || restoreResult != null) {
                        result.error("BUSY", "A backup or restore is already running", null)
                    } else {
                        backupResult = result
                        backupManifest = call.argument<String>("manifest").orEmpty()
                        backupChapters = call.argument<Boolean>("includeChapters") != false
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/zip"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("fileName") ?: "TomeVoice-backup.zip")
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_BACKUP)
                    }
                }
                "pickBackup" -> {
                    if (backupResult != null || restoreResult != null) {
                        result.error("BUSY", "A backup or restore is already running", null)
                    } else {
                        restoreResult = result
                        restoreStaging = File(call.argument<String>("staging").orEmpty())
                        // Any type: file managers label zips inconsistently.
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_RESTORE)
                    }
                }
                "shareImage" -> {
                    // A picture in cache/share, with words to go with it.
                    try {
                        val file = File(call.argument<String>("path").orEmpty())
                        val shared = File(ShareProvider.dir(cacheDir), file.name)
                        if (file.canonicalPath != shared.canonicalPath) file.copyTo(shared, overwrite = true)
                        val uri = ShareProvider.uriFor("$packageName.share", shared)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "image/png"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            call.argument<String>("text")?.let { putExtra(Intent.EXTRA_TEXT, it) }
                            clipData = android.content.ClipData.newRawUri("", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE", e.message ?: "Could not share", null)
                    }
                }
                "shareDir" -> result.success(ShareProvider.dir(cacheDir).absolutePath)
                "is64Bit" -> result.success(android.os.Process.is64Bit())
                "installApk" -> {
                    // A downloaded update (in cache/share) to Android's
                    // installer, which asks the reader to confirm. The first
                    // time, Android must be told TomeVoice may install apps.
                    if (!packageManager.canRequestPackageInstalls()) {
                        startActivity(
                            Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                .setData(android.net.Uri.parse("package:$packageName"))
                        )
                        result.success("permission")
                    } else {
                        try {
                            val file = File(call.argument<String>("path").orEmpty())
                            val uri = ShareProvider.uriFor("$packageName.share", file)
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            })
                            result.success("started")
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                }
                "widgetLaunch" -> {
                    result.success(pendingWidget)
                    pendingWidget = null
                }
                "pinWidget" -> {
                    // Ask the launcher to put a widget on the home screen
                    // (Android shows its own "Add to home screen" sheet).
                    val mgr = getSystemService(android.appwidget.AppWidgetManager::class.java)
                    val cls = when (call.argument<String>("kind")) {
                        "playerWide" -> PlayerWidgetWide::class.java
                        "streak" -> StreakWidget::class.java
                        "streakWide" -> StreakWidgetWide::class.java
                        else -> PlayerWidget::class.java
                    }
                    val ok = Build.VERSION.SDK_INT >= 26 && mgr != null && mgr.isRequestPinAppWidgetSupported &&
                        mgr.requestPinAppWidget(android.content.ComponentName(this, cls), null, null)
                    result.success(ok)
                }
                "refreshWidgets" -> {
                    Widgets.refreshAll(this)
                    result.success(null)
                }
                "restartApp" -> {
                    // After a restore every store must read the new files; a
                    // fresh process is the one sure way. The process must end
                    // at once: given time, the new activity starts in this
                    // process and dies with it (found on the phone).
                    result.success(null)
                    startActivity(
                        Intent.makeRestartActivityTask(
                            android.content.ComponentName(this, MainActivity::class.java)
                        )
                    )
                    Runtime.getRuntime().exit(0)
                }
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "webUserAgent" -> {
                    try {
                        result.success(BrowserCheck.userAgent(this))
                    } catch (e: Exception) {
                        // No WebView installed: the built-in agent stays.
                        result.success(null)
                    }
                }
                "browserCheck" -> {
                    val url = call.argument<String>("url")
                    val agent = call.argument<String>("userAgent")
                    if (url == null || agent == null) {
                        result.success(null)
                    } else {
                        try {
                            BrowserCheck.open(this, url, agent) { jar -> result.success(jar) }
                        } catch (e: Exception) {
                            result.error("BROWSER_CHECK", e.message ?: "No web view on this phone", null)
                        }
                    }
                }
                "browserFetch" -> {
                    val url = call.argument<String>("url")
                    val agent = call.argument<String>("userAgent")
                    if (url == null || agent == null) {
                        result.success(null)
                    } else {
                        try {
                            BrowserCheck.fetch(this, url, agent) { html -> result.success(html) }
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                }
                "appVersion" -> {
                    try {
                        @Suppress("DEPRECATION")
                        result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        ReadAloudService.onAction = { action, value ->
            main.post { event(mapOf("type" to "action", "action" to action, "value" to value)) }
        }

        // Warm the engine now so the first Play does not pay for the bind.
        withTts(null) { }
        cleanSynthDir()
        handleViewIntent(intent)
        takeWidgetIntent(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Draw into the camera cutout too. Without this, landscape leaves a
        // dark strip down the cutout side and under the gesture bar, where
        // the window background shows instead of the app's gradient.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        // One key press (keyboard, D-pad, remote) puts Android in keyboard
        // navigation and it outlines the focused view. Flutter is a single
        // full-screen view, so that outline was a green line round the whole
        // screen, clipped by the rounded corners. Flutter draws its own focus.
        disableFocusHighlight(window.decorView)
    }

    private fun disableFocusHighlight(view: View) {
        if (Build.VERSION.SDK_INT >= 26) view.defaultFocusHighlightEnabled = false
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) disableFocusHighlight(view.getChildAt(i))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleViewIntent(intent)
        if (takeWidgetIntent(intent)) event(mapOf("type" to "widgetLaunch"))
    }

    /** Keep what a widget asked for, for the app to act on. */
    private fun takeWidgetIntent(intent: Intent?): Boolean {
        val i = intent ?: return false
        val book = i.getStringExtra(Widgets.EXTRA_BOOK)
        val page = i.getStringExtra(Widgets.EXTRA_PAGE)
        if (book == null && page == null) return false
        pendingWidget = buildMap {
            if (book != null) put("book", book)
            if (page != null) put("page", page)
            if (i.getBooleanExtra(Widgets.EXTRA_PLAY, false)) put("play", true)
        }
        i.removeExtra(Widgets.EXTRA_BOOK)
        i.removeExtra(Widgets.EXTRA_PAGE)
        return true
    }

    private fun event(payload: Map<String, Any?>) {
        main.post { channel?.invokeMethod("platformEvent", payload) }
    }

    private fun outputDir(): File = getExternalFilesDir(null) ?: filesDir

    /** The file dialog closed: write the zip there, on its own thread. */
    private fun finishBackup(resultCode: Int, uri: Uri?) {
        val reply = backupResult ?: return
        backupResult = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return
        }
        val manifest = backupManifest
        val chapters = backupChapters
        Thread {
            try {
                val out = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Android would not open that file for writing")
                var total = 0L
                val files = out.use {
                    LibraryBackup.write(outputDir(), it, manifest, chapters) { done, all ->
                        total = all
                        event(mapOf("type" to "backupProgress", "done" to done, "total" to all))
                    }
                }
                main.post { reply.success(mapOf("files" to files, "bytes" to total)) }
            } catch (e: Throwable) {
                // Leave no half-written backup behind to be trusted later.
                try {
                    android.provider.DocumentsContract.deleteDocument(contentResolver, uri)
                } catch (_: Throwable) {
                }
                main.post { reply.error("BACKUP", e.message ?: "The backup could not be written", null) }
            }
        }.start()
    }

    /** A backup was picked: unpack it into the staging folder. */
    private fun finishRestore(resultCode: Int, uri: Uri?) {
        val reply = restoreResult ?: return
        restoreResult = null
        val staging = restoreStaging
        if (resultCode != Activity.RESULT_OK || uri == null || staging == null) {
            reply.success(null)
            return
        }
        Thread {
            try {
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Android would not open that file")
                val manifest = input.use {
                    LibraryBackup.read(it, staging) { done ->
                        event(mapOf("type" to "restoreProgress", "done" to done))
                    }
                }
                main.post { reply.success(manifest) }
            } catch (e: Throwable) {
                staging.deleteRecursively()
                main.post { reply.error("RESTORE", e.message ?: "That backup could not be read", null) }
            }
        }.start()
    }

    private fun synthDir(): File = File(cacheDir, "tts").apply { mkdirs() }

    private fun cleanSynthDir() {
        io.execute {
            synthDir().listFiles()?.forEach { it.delete() }
            // Builds before this one left a WAV per sentence in the library
            // folder. They are dead weight; nothing reads them.
            outputDir().listFiles()?.forEach {
                if (it.isFile && it.name.endsWith(".wav")) it.delete()
            }
            PdfPages.sweep(cacheDir)
        }
    }

    /** Intent extras, so a measurement run can be driven from adb. */
    private fun launchArgs(): Map<String, String> {
        val extras = intent?.extras ?: return emptyMap()
        return extras.keySet().associateWith { key ->
            @Suppress("DEPRECATION")
            extras.get(key)?.toString() ?: ""
        }
    }

    // ------------------------------------------------------------------ TTS

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
        val created = TextToSpeech(applicationContext, { status ->
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

    private fun synthesise(args: Map<*, *>, result: MethodChannel.Result) {
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
        main.postDelayed({
            reply { result.error("TTS_TIMEOUT", "No callback within 30s", null) }
        }, 30_000)

        withTts(engineId) { engine ->
            if (engine == null) {
                reply { result.error("TTS_INIT", "The voice engine did not start", null) }
                return@withTts
            }
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
                        reply {
                            result.error("TTS_ERROR", "Synthesis failed (code $errorCode)", null)
                        }
                    }
                })
                val code = engine.synthesizeToFile(text, Bundle(), outFile, utteranceId)
                if (code != TextToSpeech.SUCCESS) {
                    reply { result.error("TTS_QUEUE", "synthesizeToFile returned $code", null) }
                }
            } catch (e: Exception) {
                reply { result.error("TTS_EXCEPTION", e.message, null) }
            }
        }
    }

    // ---------------------------------------------------------- audio focus

    private fun requestFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (focusRequest == null) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setWillPauseWhenDucked(true)
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
        am.requestAudioFocus(focusRequest!!)
        if (!noisyRegistered) {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            val flags = if (Build.VERSION.SDK_INT >= 33) Context.RECEIVER_NOT_EXPORTED else 0
            registerReceiver(noisyReceiver, filter, flags)
            noisyRegistered = true
        }
    }

    private fun abandonFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        focusRequest?.let { am.abandonAudioFocusRequest(it) }
        if (noisyRegistered) {
            try {
                unregisterReceiver(noisyReceiver)
            } catch (_: Exception) {
            }
            noisyRegistered = false
        }
    }

    // -------------------------------------------------------------- session

    private var askedNotify = false

    /** Start, update or end the "reading aloud" foreground service. */
    private fun session(args: Map<*, *>, result: MethodChannel.Result) {
        val active = args["active"] == true
        if (!active) {
            ReadAloudService.end(this)
            abandonFocus()
            result.success(null)
            return
        }
        // Asked once per launch: the session is updated on every sentence, and
        // a refusal must not bring the prompt back each time.
        if (Build.VERSION.SDK_INT >= 33 && !askedNotify &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            askedNotify = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }
        try {
            ReadAloudService.update(
                this,
                ReadAloudService.NowReading(
                    title = (args["title"] as? String) ?: "TomeVoice",
                    subtitle = (args["subtitle"] as? String) ?: "",
                    playing = args["playing"] == true,
                    cover = args["cover"] as? String,
                    positionMs = (args["positionMs"] as? Number)?.toLong() ?: 0,
                    durationMs = (args["durationMs"] as? Number)?.toLong() ?: 0,
                    speed = (args["speed"] as? Number)?.toDouble() ?: 1.0,
                )
            )
            result.success(null)
        } catch (e: Exception) {
            // Reading still works in the foreground; it just will not survive
            // the screen turning off.
            result.error("SESSION", e.message, null)
        }
    }

    // --------------------------------------------------------------- import

    private fun pickDocuments(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("PICK_IN_PROGRESS", "A picker is already open", null)
            return
        }
        pickResult = result
        // "*/*" with no EXTRA_MIME_TYPES. DocumentsUI hides .epub/.pdf when we
        // whitelist types, because many managers label them zip, empty, or octet.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_PICK)
    }

    @Deprecated("startActivityForResult is what FlutterActivity still exposes")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_BACKUP) {
            finishBackup(resultCode, data?.data)
            return
        }
        if (requestCode == REQ_RESTORE) {
            finishRestore(resultCode, data?.data)
            return
        }
        if (requestCode == REQ_IMAGE) {
            val reply = imageResult
            imageResult = null
            val uri = data?.data
            if (reply == null) return
            if (resultCode != Activity.RESULT_OK || uri == null) {
                reply.success(null)
                return
            }
            io.execute {
                try {
                    val file = copyIn(uri)
                    main.post { reply.success(file) }
                } catch (e: Exception) {
                    main.post { reply.error("PICK", e.message, null) }
                }
            }
            return
        }
        if (requestCode != REQ_PICK) return
        val reply = pickResult
        pickResult = null
        if (reply == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            reply.success(null)
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        if (uris.isEmpty()) {
            reply.success(null)
            return
        }
        // Copying a 25 MB PDF on the UI thread froze the app; do it on io.
        io.execute {
            val copied = mutableListOf<Map<String, String>>()
            var error: String? = null
            for (uri in uris) {
                try {
                    copied.add(copyIn(uri))
                } catch (e: Exception) {
                    error = e.message
                }
            }
            main.post {
                if (copied.isEmpty() && error != null) {
                    reply.error("PICK", error, null)
                } else {
                    reply.success(copied)
                }
            }
        }
    }

    /** "Open with TomeVoice" and "Share to TomeVoice". */
    private fun handleViewIntent(intent: Intent?) {
        if (intent == null) return
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            else -> null
        }
        if (uri == null) return
        // Do not re-import the same file when the activity is recreated.
        intent.action = Intent.ACTION_MAIN
        io.execute {
            try {
                val file = copyIn(uri)
                main.post {
                    pendingOpen = file
                    event(mapOf("type" to "openFile") + file)
                }
            } catch (e: Exception) {
                event(mapOf("type" to "openFailed", "message" to (e.message ?: "")))
            }
        }
    }

    private fun copyIn(uri: Uri): Map<String, String> {
        val name = (queryDisplayName(uri) ?: "document")
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val destDir = File(outputDir(), "incoming")
        destDir.mkdirs()
        val dest = File(destDir, name)
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Could not open $uri" }
            dest.outputStream().use { output -> input.copyTo(output) }
        }
        return mapOf(
            "path" to dest.absolutePath,
            "name" to name,
            "mime" to (contentResolver.getType(uri) ?: "")
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) return cursor.getString(0)
                }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun extractPdf(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("NO_FILE", "No PDF path", null)
            return
        }
        io.execute {
            try {
                var lastReport = 0L
                val out = PdfText.extract(this, path) { done, total ->
                    val now = System.currentTimeMillis()
                    if (now - lastReport > 250 || done == total) {
                        lastReport = now
                        event(mapOf("type" to "importProgress", "done" to done, "total" to total))
                    }
                }
                main.post { result.success(out) }
            } catch (e: Throwable) {
                main.post { result.error("PDF", e.message ?: "Could not read this PDF", null) }
            }
        }
    }

    // --------------------------------------------------------------- report

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

    override fun onDestroy() {
        ReadAloudService.onAction = null
        ReadAloudService.end(this)
        abandonFocus()
        player.stop()
        tts?.shutdown()
        tts = null
        io.shutdown()
        pages.execute { PdfPages.close() }
        pages.shutdown()
        super.onDestroy()
    }
}
