package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.webkit.CookieManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.nio.charset.Charset
import java.util.concurrent.Executors

/**
 * Web novels' own channel to the platform ("tomevoice/sources"), kept out of
 * MainActivity. It is registered on the app's engine (MainActivity, with
 * [activity]) and on the engine the background check starts
 * (NovelCheckWorker), which has no activity: calls that need one answer null
 * there, and [onDone] hears that check finish.
 */
object SourcesBridge {
    const val CHANNEL = "tomevoice/sources"
    private const val REQ_NOTIFY = 7302

    /** The app's activity while it lives (see [appIsOpen]). */
    private var app: WeakReference<Activity>? = null

    /** Whether the app's own engine is up: the background check then stays out of its way. */
    fun appIsOpen(): Boolean {
        val a = app?.get() ?: return false
        return !a.isFinishing && !a.isDestroyed
    }

    fun attach(
        context: Context,
        messenger: BinaryMessenger,
        activity: Activity?,
        onDone: ((Map<*, *>) -> Unit)? = null,
    ): MethodChannel {
        val appContext = context.applicationContext
        if (activity != null) app = WeakReference(activity)
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Sources (plugin code, their storage, site cookies) live in
                // internal storage, which no other app can read or change.
                "sourcesRoot" -> result.success(appContext.filesDir.absolutePath)
                // The library, where MainActivity keeps it.
                "libraryRoot" -> result.success((appContext.getExternalFilesDir(null) ?: appContext.filesDir).absolutePath)
                "scheduleChecks" -> {
                    val handle = (call.argument<Any>("handle") as? Number)?.toLong() ?: 0L
                    val minutes = (call.argument<Any>("minutes") as? Number)?.toLong() ?: 0L
                    val unmetered = call.argument<Boolean>("unmetered") != false
                    try {
                        NovelCheckWorker.schedule(appContext, handle, minutes, unmetered)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SCHEDULE", e.message, null)
                    }
                }
                "backgroundDone" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    result.success(null)
                    onDone?.invoke(args)
                }
                "backgroundBusy" -> result.success(NovelCheckWorker.running.get())
                // A page in a charset Dart does not read (GBK, Big5,
                // Shift_JIS, windows-1251...): Java knows them all. Off the
                // main thread; null for a name it does not know.
                "decode" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("charset")
                    if (bytes == null || name == null) {
                        result.success(null)
                    } else {
                        decoder.execute {
                            val text = try {
                                if (Charset.isSupported(name)) String(bytes, Charset.forName(name)) else null
                            } catch (e: Exception) {
                                null
                            }
                            mainThread.post { result.success(text) }
                        }
                    }
                }
                // A page through the web view, for sites that turn the app's
                // own requests away (a POST is sent as a form). Only with the
                // app's activity: the background check has none.
                "browserFetch" -> {
                    val a = activity
                    val url = call.argument<String>("url")
                    val agent = call.argument<String>("userAgent")
                    if (a == null || url == null || agent == null) {
                        result.success(null)
                    } else {
                        try {
                            BrowserCheck.fetch(
                                a,
                                url,
                                agent,
                                call.argument<String>("method") ?: "GET",
                                call.argument<String>("body"),
                            ) { html -> result.success(html) }
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                }
                "clearWebCookies" -> {
                    // The web view's cookies (browser checks, logins): all of
                    // them, or one site's ([url]) as far as it can be told.
                    try {
                        val cookies = CookieManager.getInstance()
                        val url = call.argument<String>("url")
                        if (url == null) {
                            cookies.removeAllCookies(null)
                        } else {
                            val host = Uri.parse(url).host.orEmpty()
                            val names = cookies.getCookie(url)?.split(";")
                                ?.mapNotNull { it.substringBefore('=').trim().takeIf { n -> n.isNotEmpty() } }
                                .orEmpty()
                            val domains = listOf(host, host.removePrefix("www."), "." + host.removePrefix("www."))
                            for (name in names) {
                                for (domain in domains) {
                                    cookies.setCookie(
                                        url,
                                        "$name=; Max-Age=0; Path=/; Domain=$domain; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                                    )
                                }
                                cookies.setCookie(url, "$name=; Max-Age=0; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
                            }
                        }
                        cookies.flush()
                        result.success(true)
                    } catch (e: Exception) {
                        // No web view on this phone: nothing kept there.
                        result.success(false)
                    }
                }
                "downloadProgress" -> {
                    if (call.argument<Boolean>("active") == true) {
                        DownloadService.update(
                            appContext,
                            DownloadService.Progress(
                                title = call.argument<String>("title") ?: "Downloading chapters",
                                text = call.argument<String>("text") ?: "",
                                done = (call.argument<Any>("done") as? Number)?.toInt() ?: 0,
                                total = (call.argument<Any>("total") as? Number)?.toInt() ?: 0,
                            ),
                        )
                    } else {
                        DownloadService.stop(appContext)
                    }
                    result.success(null)
                }
                "notificationsAllowed" -> result.success(NovelCheckWorker.allowed(appContext))
                "askNotifications" -> {
                    val a = activity
                    if (a == null) {
                        result.success(false)
                    } else if (Build.VERSION.SDK_INT >= 33 &&
                        a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                        android.content.pm.PackageManager.PERMISSION_GRANTED &&
                        (!asked || a.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))
                    ) {
                        asked = true
                        a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
                        result.success(true)
                    } else {
                        // Refused before, or turned off: only Android's own
                        // settings can turn them on now.
                        try {
                            a.startActivity(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, a.packageName)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    /** The permission prompt was shown once this run. */
    private var asked = false

    private val decoder = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())
}
