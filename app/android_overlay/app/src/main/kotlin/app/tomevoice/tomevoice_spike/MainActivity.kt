package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Platform side of TomeVoice that needs the activity: file import, pickers,
 * the window, prompts, intents.
 *
 * Reading aloud (the voice, the player, the phone's audio, the card) is the
 * engine's, not the activity's: ReadingCore, for the life of the process. The
 * activity shows that one engine (provideFlutterEngine) and lets go of it
 * without ending the reading.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "tomevoice/tts"
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val pages = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    /** This activity came to an engine already running Dart (see onCreate). */
    private var rejoined = false

    /** Whether the engine goes with this activity, decided as it lets go. */
    private var engineGoes = false

    private var pickResult: MethodChannel.Result? = null
    private var imageResult: MethodChannel.Result? = null
    private var pendingOpen: Map<String, String>? = null

    /** A link or words shared to TomeVoice: id, text and subject (see takeSharedText). */
    private var pendingShare: Map<String, String>? = null

    /** A widget was tapped: the book to open (and play), or the page to show. */
    private var pendingWidget: Map<String, Any>? = null

    // A backup or restore waiting on Android's file dialog.
    private var backupResult: MethodChannel.Result? = null
    private var backupManifest = ""
    private var backupChapters = true
    private var restoreResult: MethodChannel.Result? = null
    private var restoreStaging: File? = null

    // A folder being picked, to write into from then on (automatic backups,
    // quotes as Markdown).
    private var folderResult: MethodChannel.Result? = null

    companion object {
        private const val REQ_PICK = 71
        private const val REQ_NOTIFY = 72
        private const val REQ_IMAGE = 73
        private const val REQ_BACKUP = 74
        private const val REQ_RESTORE = 75
        private const val REQ_CONFIRM = 76
        private const val REQ_FOLDER = 77
    }

    /**
     * [text] to an app that looks words up or translates them: Android's own
     * Translate when asked to translate (Android 10 and later), else every app
     * that offers to act on chosen text (dictionaries, Translate, Wikipedia).
     * False when the phone has none.
     */
    private fun processText(text: String, translate: Boolean): Boolean {
        if (text.isBlank()) return false
        if (translate && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val t = Intent(Intent.ACTION_TRANSLATE).putExtra(Intent.EXTRA_TEXT, text)
            if (t.resolveActivity(packageManager) != null) {
                try {
                    startActivity(t)
                    return true
                } catch (e: Exception) {
                    // Then the apps that act on chosen text.
                }
            }
        }
        val pick = Intent(Intent.ACTION_PROCESS_TEXT)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            .putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        @Suppress("DEPRECATION")
        if (packageManager.queryIntentActivities(pick, 0).isEmpty()) return false
        return try {
            startActivity(Intent.createChooser(pick, if (translate) "Translate with" else "Look up with"))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** The answer to "is it you?" on phones too old for BiometricPrompt's PIN. */
    private var confirmResult: MethodChannel.Result? = null

    /** Saving a book as audio: its own channel, "tomevoice/export". */
    private var exporter: AudioExport? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // An engine already running: the app is there, or a book was being
        // read with no activity, and this activity only shows it.
        rejoined = flutterEngine.dartExecutor.isExecutingDart
        exporter = AudioExport(this, flutterEngine.dartExecutor.binaryMessenger)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            // Asking to show the notification is the activity's part of it.
            if (call.method == "session" && call.argument<Boolean>("active") == true) askToNotify()
            // Reading's calls are the engine's, answered with or without an
            // activity; the rest are this activity's.
            if (ReadingCore.handle(call, result)) return@setMethodCallHandler
            when (call.method) {
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
                "pendingShare" -> {
                    result.success(pendingShare)
                    pendingShare = null
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
                // A scanned PDF read with OCR, in a foreground service (Ocr.kt).
                "ocrStart" -> {
                    try {
                        result.success(OcrService.start(this, call.arguments as Map<*, *>))
                    } catch (e: Exception) {
                        result.error("OCR", e.message ?: "The scan could not be read", null)
                    }
                }
                "ocrStop" -> {
                    OcrService.stop()
                    result.success(null)
                }
                "ocrStatus" -> result.success(OcrService.status())
                "outputDir" -> result.success(outputDir().absolutePath)
                "launchArgs" -> result.success(launchArgs())
                // Text in an East Asian legacy encoding (GBK, Big5, Shift_JIS,
                // EUC-KR...), decoded by Android's own charsets for an import.
                "decodeCharset" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    val name = call.argument<String>("charset").orEmpty()
                    io.execute {
                        try {
                            // The Windows supersets: what files called these really are.
                            val charset = java.nio.charset.Charset.forName(
                                when (name.uppercase()) {
                                    "SHIFT_JIS", "SJIS" -> "windows-31j"
                                    "EUC-KR" -> "x-windows-949"
                                    else -> name
                                }
                            )
                            val text = String(bytes, charset)
                            main.post { result.success(text) }
                        } catch (e: Exception) {
                            main.post { result.error("CHARSET", e.message, null) }
                        }
                    }
                }
                // A word or a sentence held in the reader, to the phone's own
                // dictionary and translate apps: TomeVoice itself goes nowhere.
                "lookUp" -> result.success(processText(call.argument<String>("text").orEmpty(), translate = false))
                "translate" -> result.success(processText(call.argument<String>("text").orEmpty(), translate = true))
                "openUrl" -> {
                    val scheme = Uri.parse(call.argument<String>("url").orEmpty()).scheme?.lowercase()
                    if (scheme != "https" && scheme != "http") {
                        result.success(false)
                        return@setMethodCallHandler
                    }
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
                            LibraryBackup.size(outputDir(), chapters, File(filesDir, "sources"))
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
                "shareImage", "shareFile" -> {
                    // A picture in cache/share (or another file made to be
                    // passed on, as its type), with words to go with it.
                    try {
                        val file = File(call.argument<String>("path").orEmpty())
                        val shared = File(ShareProvider.dir(cacheDir), file.name)
                        if (file.canonicalPath != shared.canonicalPath) file.copyTo(shared, overwrite = true)
                        val uri = ShareProvider.uriFor("$packageName.share", shared)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = call.argument<String>("mime") ?: "image/png"
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
                "playUrl" -> {
                    stopSample()
                    val url = call.argument<String>("url").orEmpty()
                    try {
                        sampler = android.media.MediaPlayer().apply {
                            setAudioAttributes(
                                android.media.AudioAttributes.Builder()
                                    .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build()
                            )
                            setDataSource(url)
                            setOnPreparedListener { it.start() }
                            setOnCompletionListener {
                                stopSample()
                                event(mapOf("type" to "urlSampleDone", "url" to url))
                            }
                            setOnErrorListener { _, _, _ ->
                                stopSample()
                                event(mapOf("type" to "urlSampleFailed", "url" to url))
                                true
                            }
                            prepareAsync()
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        stopSample()
                        result.error("SAMPLE", e.message, null)
                    }
                }
                "stopUrl" -> {
                    stopSample()
                    result.success(null)
                }
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
                            if (!isOwnUpdate(file)) {
                                file.delete()
                                result.success("notOurs")
                                return@setMethodCallHandler
                            }
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
                        "playerStamp" -> PlayerStampWidget::class.java
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
                "volumeKeysTurnPages" -> {
                    volumeKeysTurnPages = call.argument<Boolean>("on") == true
                    result.success(null)
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
                "deviceSecure" -> result.success(keyguard().isDeviceSecure)
                "confirmUser" -> confirmUser(call.argument<String>("title") ?: "TomeVoice", call.argument<String>("subtitle"), result)
                "hideRecents" -> {
                    hideRecents(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "openSecuritySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
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
                // The phone, for a problem report the reader reads and sends
                // themselves (About > Report a problem).
                "deviceInfo" -> result.success(
                    mapOf(
                        "android" to Build.VERSION.RELEASE,
                        "sdk" to Build.VERSION.SDK_INT,
                        "maker" to Build.MANUFACTURER,
                        "model" to Build.MODEL,
                    )
                )
                "pickFolder" -> {
                    if (folderResult != null) {
                        result.error("BUSY", "A folder is already being chosen", null)
                    } else {
                        folderResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_FOLDER)
                    }
                }
                "folderOk" -> {
                    val tree = call.argument<String>("tree").orEmpty()
                    result.success(contentResolver.persistedUriPermissions.any {
                        it.uri.toString() == tree && it.isWritePermission
                    })
                }
                "writeToFolder", "listFolder", "deleteFromFolder", "backupToFolder" -> folderCall(call, result)
                else -> result.notImplemented()
            }
        }

        // Web novels: their own channel (SourcesBridge.kt), also registered
        // on the background check's engine, where this activity is not.
        SourcesBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger, this)
        // A scan being read says how far it has got (ocr_jobs.dart).
        OcrService.onEvent = { e -> event(e) }
        cleanSynthDir()
        handleViewIntent(intent)
        // A widget's book for an app already running is told, as onNewIntent
        // tells it: the shelf asked once, when it first opened.
        if (takeWidgetIntent(intent) && rejoined) event(mapOf("type" to "widgetLaunch"))
        // The app in a new window: edge to edge again, and built if Dart was
        // only reading (backgroundMain).
        if (rejoined) event(mapOf("type" to "shown"))
    }

    // ---------------------------------------------------------------- engine

    /**
     * The one engine (ReadingCore), not one of this activity's own: the voice
     * is Dart's, and must not end with the activity.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = ReadingCore.engineFor(this)

    /**
     * Kept while a book is being read: a swipe from Recents, or Android
     * closing the activity, leaves the voice reading. With nothing read, an
     * activity that is finishing takes it along, so the next opening starts
     * afresh, as it always did (decided in cleanUpFlutterEngine, which comes
     * first). Never while a newer activity takes the engine over.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = engineGoes

    /** The engine's state is live: an activity's saved state must not overwrite it. */
    override fun shouldRestoreAndSaveState(): Boolean = false

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        engineGoes = isFinishing && !isChangingConfigurations && ReadingCore.shows(this) &&
            !ReadAloudService.isRunning() && !ReadAloudService.isStarting()
        // Reading carries on; this activity's own calls (pickers, the window,
        // prompts) go with it.
        ReadingCore.detach(this)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Back at the root, where Flutter has nothing to go back to, also
        // puts TomeVoice behind when Android handles it itself (predictive
        // back, Android 16): it finished an app another app had opened (a
        // file manager's Open with), and the book being read stopped with
        // it. Flutter registers its own callback whenever it has somewhere to
        // go back to; being registered later, that one is asked first.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT
            ) { moveTaskToBack(true) }
        }
        // An engine already running (a book read on after the last activity
        // closed): Flutter said whether it has a page to go back to when that
        // changed, to the activity before, and says it again only when it next
        // changes. Until then Back goes to Flutter, which closes a page, or at
        // the root calls popSystemNavigator: TomeVoice goes behind, as ever.
        if (rejoined) setFrameworkHandlesBack(true)
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

    // Back out of the library puts TomeVoice behind, as Home does, instead of
    // finishing it. Finishing ran onDestroy, which ended the reading service
    // and the player, so on Android 15 and older leaving with Back stopped the
    // book being read. Android 16 (predictive back, targetSdk 36) already
    // moved the app behind, which is why it never showed there.
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
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

    /**
     * Whether the APK at [file] is an update of this app: the same package,
     * signed with the same key when Android can tell. Android itself refuses
     * a same-package update signed by someone else; this stops an APK for a
     * different package (installed as a second app, under TomeVoice's name)
     * from ever being offered.
     */
    private fun isOwnUpdate(file: File): Boolean {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
        else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        val apk = packageManager.getPackageArchiveInfo(file.path, flags) ?: return false
        if (apk.packageName != packageName) return false
        val mine = packageManager.getPackageInfo(packageName, flags)
        val theirs = signers(apk)
        return theirs.isEmpty() || theirs == signers(mine)
    }

    private fun signers(p: android.content.pm.PackageInfo): Set<String> =
        if (Build.VERSION.SDK_INT >= 28) {
            p.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet() ?: emptySet()
        } else {
            @Suppress("DEPRECATION")
            p.signatures?.map { it.toCharsString() }?.toSet() ?: emptySet()
        }

    /** A voice's sample, streamed (Settings → Natural voices). */
    private var sampler: android.media.MediaPlayer? = null

    private fun stopSample() {
        val s = sampler ?: return
        sampler = null
        try {
            s.stop()
        } catch (_: Exception) {
        }
        s.release()
    }

    /** Set by the reader while its pages want the volume keys. */
    @Volatile
    private var volumeKeysTurnPages = false

    /**
     * The volume keys turn the reader's pages while it asks for them (pages
     * shown, nothing read aloud): down for on, up for back, held to keep
     * turning. Both the press and the release are kept from the system, so
     * the volume does not change and its panel does not show.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val delta = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> 1
            KeyEvent.KEYCODE_VOLUME_UP -> -1
            else -> 0
        }
        if (delta == 0 || !volumeKeysTurnPages) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN) event(mapOf("type" to "pageKey", "delta" to delta))
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
                    LibraryBackup.write(outputDir(), it, manifest, chapters, File(filesDir, "sources")) { done, all ->
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

    /**
     * Files in a folder the reader picked (pickFolder): one written, listed
     * or deleted, on a thread of its own (a backup takes a while). A folder
     * taken away, or gone, answers FOLDER.
     */
    private fun folderCall(call: MethodCall, result: MethodChannel.Result) {
        val tree = Uri.parse(call.argument<String>("tree").orEmpty())
        Thread {
            try {
                val out: Any? = when (call.method) {
                    "writeToFolder" -> {
                        val doc = createInFolder(
                            tree,
                            call.argument<String>("mime") ?: "text/plain",
                            call.argument<String>("name") ?: "TomeVoice.txt"
                        )
                        val stream = contentResolver.openOutputStream(doc, "wt")
                            ?: throw IllegalStateException("Android would not open the new file")
                        stream.use { it.write(call.argument<String>("text").orEmpty().toByteArray(Charsets.UTF_8)) }
                        queryDisplayName(doc)
                    }
                    "listFolder" -> listFolder(tree)
                    "deleteFromFolder" -> {
                        val id = call.argument<String>("id").orEmpty()
                        DocumentsContract.deleteDocument(contentResolver, DocumentsContract.buildDocumentUriUsingTree(tree, id))
                        null
                    }
                    "backupToFolder" -> {
                        val doc = createInFolder(tree, "application/zip", call.argument<String>("name") ?: "TomeVoice-backup.zip")
                        try {
                            var total = 0L
                            val stream = contentResolver.openOutputStream(doc, "wt")
                                ?: throw IllegalStateException("Android would not open the new file")
                            val files = stream.use {
                                LibraryBackup.write(
                                    outputDir(),
                                    it,
                                    call.argument<String>("manifest").orEmpty(),
                                    call.argument<Boolean>("includeChapters") == true,
                                    File(filesDir, "sources")
                                ) { _, all -> total = all }
                            }
                            mapOf("files" to files, "bytes" to total, "name" to queryDisplayName(doc))
                        } catch (e: Throwable) {
                            // Leave no half-written backup behind to be trusted later.
                            try {
                                DocumentsContract.deleteDocument(contentResolver, doc)
                            } catch (_: Throwable) {
                            }
                            throw e
                        }
                    }
                    else -> null
                }
                main.post { result.success(out) }
            } catch (e: SecurityException) {
                main.post { result.error("FOLDER", "TomeVoice may no longer write to that folder. Choose it again.", null) }
            } catch (e: java.io.FileNotFoundException) {
                main.post { result.error("FOLDER", "That folder is gone. Choose another.", null) }
            } catch (e: Throwable) {
                main.post { result.error("FOLDER_IO", e.message ?: "Could not write to that folder", null) }
            }
        }.start()
    }

    /** A new file [name] in the picked folder [tree]. */
    private fun createInFolder(tree: Uri, mime: String, name: String): Uri {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return DocumentsContract.createDocument(contentResolver, parent, mime, name)
            ?: throw IllegalStateException("Android would not make a file in that folder")
    }

    private fun listFolder(tree: Uri): List<Map<String, Any?>> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = mutableListOf<Map<String, Any?>>()
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        contentResolver.query(children, columns, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to c.getString(0),
                        "name" to c.getString(1),
                        "size" to (if (c.isNull(2)) 0L else c.getLong(2)),
                        "modified" to (if (c.isNull(3)) 0L else c.getLong(3))
                    )
                )
            }
        }
        return out
    }

    private fun folderName(tree: Uri): String? = try {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) {
        null
    }

    private fun cleanSynthDir() {
        io.execute {
            // (cache/tts, the voice's, is emptied when its engine is made, in
            // ReadingCore: a book may be reading from it now.)
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

    // -------------------------------------------------------------- session

    private var askedNotify = false

    /**
     * The notification permission, asked as reading starts (ReadingCore puts
     * the card up). Once per launch: the session is updated on every
     * sentence, and a refusal must not bring the prompt back each time.
     */
    private fun askToNotify() {
        if (Build.VERSION.SDK_INT >= 33 && !askedNotify &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            askedNotify = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
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

    private fun keyguard() = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    /**
     * The phone's own lock: a fingerprint or face, or its PIN, pattern or
     * password. True once the owner has shown it is them; false when they
     * cancel, or the phone has no lock to ask for.
     */
    private fun confirmUser(title: String, subtitle: String?, result: MethodChannel.Result) {
        val keyguard = keyguard()
        if (!keyguard.isDeviceSecure) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val builder = BiometricPrompt.Builder(this).setTitle(title)
            if (subtitle != null) builder.setSubtitle(subtitle)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setDeviceCredentialAllowed(true)
            }
            val answered = AtomicBoolean(false)
            fun answer(ok: Boolean) {
                if (answered.compareAndSet(false, true)) result.success(ok)
            }
            builder.build().authenticate(
                CancellationSignal(),
                mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult?) = answer(true)

                    // Cancelled, or too many tries. (A finger not recognised
                    // is onAuthenticationFailed: the prompt stays up.)
                    override fun onAuthenticationError(code: Int, message: CharSequence?) = answer(false)
                },
            )
            return
        }
        @Suppress("DEPRECATION")
        val intent = keyguard.createConfirmDeviceCredentialIntent(title, subtitle)
        if (intent == null) {
            result.success(false)
            return
        }
        confirmResult?.success(false)
        confirmResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_CONFIRM)
    }

    /** Recents shows a blank card for TomeVoice (older phones: no screenshots either). */
    private fun hideRecents(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 33) {
            setRecentsScreenshotEnabled(!on)
        } else if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    @Deprecated("startActivityForResult is what FlutterActivity still exposes")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (exporter?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode == REQ_CONFIRM) {
            confirmResult?.success(resultCode == Activity.RESULT_OK)
            confirmResult = null
            return
        }
        if (requestCode == REQ_BACKUP) {
            finishBackup(resultCode, data?.data)
            return
        }
        if (requestCode == REQ_RESTORE) {
            finishRestore(resultCode, data?.data)
            return
        }
        if (requestCode == REQ_FOLDER) {
            val reply = folderResult ?: return
            folderResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                reply.success(null)
                return
            }
            try {
                // Kept across restarts, until the reader takes it back.
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                reply.success(mapOf("uri" to uri.toString(), "name" to (folderName(uri) ?: "Folder")))
            } catch (e: Exception) {
                reply.error("FOLDER", e.message ?: "Android would not let TomeVoice keep that folder", null)
            }
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
        if (uri == null) {
            // No file: a link or words (Chrome's Share, chosen text).
            if (intent.action == Intent.ACTION_SEND) takeSharedText(intent)
            return
        }
        if (uri.scheme != "content" || uri.authority?.startsWith(packageName) == true) return
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

    /**
     * Words shared to TomeVoice, EXTRA_TEXT with no file: Dart reads a link
     * as an article, anything else as a book. Kept as pendingShare as well,
     * as a file is kept as pendingOpen, for a share that started the app
     * before Dart was listening; the id lets Dart take one of the two.
     */
    private fun takeSharedText(intent: Intent) {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (text.isNullOrBlank()) return
        // Not read again when the activity is recreated.
        intent.action = Intent.ACTION_MAIN
        val share = mapOf(
            "id" to java.util.UUID.randomUUID().toString(),
            "text" to text,
            "subject" to (intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString() ?: ""),
        )
        pendingShare = share
        event(mapOf("type" to "sharedText") + share)
    }

    private fun copyIn(uri: Uri): Map<String, String> {
        val name = (queryDisplayName(uri) ?: "document")
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
        // Each file in a folder of its own, its name kept (the format and title
        // come from it): two picked at once with one name wrote over each other.
        val destDir = File(File(outputDir(), "incoming"), java.util.UUID.randomUUID().toString())
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

    override fun onDestroy() {
        exporter?.close()
        exporter = null
        stopSample()
        // A scan being read goes on without the app; its book is made when
        // the app is next opened (ocr_jobs.dart).
        OcrService.onEvent = null
        // The reading, the voice and the player are the engine's and carry
        // on (ReadingCore): leaving the app, by a swipe from Recents too,
        // does not stop a book being read.
        io.shutdown()
        pages.execute { PdfPages.close() }
        pages.shutdown()
        super.onDestroy()
    }
}
