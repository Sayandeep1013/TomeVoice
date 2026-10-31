package app.tomevoice.tomevoice_spike

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A site's "checking your browser" page (Cloudflare), shown in a real
 * WebView so it can run, and so the reader can tick the box when it asks.
 * Once the site lets the browser in, its cookies (cf_clearance) are handed
 * back for the app's own requests, which then pass too, as in Mihon and
 * LNReader. The requests must use the same User-Agent: [userAgent].
 *
 * The web view keeps one cookie store for the whole app, while each source
 * keeps cookies of its own (cookies.dart). So it is used for one source at
 * a time, one page after another ([enqueue]): the store is cleared and that
 * source's own cookies for the site set ([prepare]), the page runs, what
 * the site keeps is handed back for that source alone ([harvest]), and the
 * store is cleared again ([wipe]). No source's sign-in or clearance is ever
 * there for another's page.
 */
object BrowserCheck {
    /** The WebView's own User-Agent without the "wv" mark, for every request. */
    fun userAgent(activity: Activity): String =
        WebSettings.getDefaultUserAgent(activity)
            .replace("; wv)", ")")
            .replace(Regex("Version/\\d+(\\.\\d+)* "), "")

    /**
     * Only web pages are loaded: a source plugin names the address, and a
     * file:, content: or javascript: one must never reach the web view.
     */
    fun isWebPage(url: String): Boolean {
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        return (scheme == "https" || scheme == "http") && !uri.host.isNullOrEmpty()
    }

    /** Nothing on the phone is open to the pages: no files, no content providers. */
    private fun lockDown(settings: WebSettings) {
        settings.allowFileAccess = false
        settings.allowContentAccess = false
    }

    // ------------------------------------------------ one source at a time

    /**
     * A source's own cookies for a site, as Dart hands them (Net.browserSeed):
     * each a Set-Cookie line and the address it is set at; and the site's
     * [domain], under which a cookie set for the whole site is told from one
     * for its host alone.
     */
    class Seed(val cookies: List<Pair<String, String>>, val domain: String?) {
        /** The value it gives cookie [name], if any. */
        fun valueOf(name: String): String? {
            for ((_, line) in cookies) {
                val value = BrowserCheck.valueIn(line.substringBefore(';'), name)
                if (value != null) return value
            }
            return null
        }

        companion object {
            /** From a call's "cookies" and "domain". */
            fun of(cookies: Any?, domain: Any?): Seed {
                val list = ArrayList<Pair<String, String>>()
                for (o in (cookies as? List<*>).orEmpty()) {
                    val m = o as? Map<*, *> ?: continue
                    val url = m["url"] as? String ?: continue
                    val line = m["cookie"] as? String ?: continue
                    list.add(url to line)
                }
                return Seed(list, (domain as? String)?.takeIf { it.isNotEmpty() })
            }
        }
    }

    /** Cookie [name]'s value in [jar] ("a=1; b=2"), if it is there. */
    private fun valueIn(jar: String?, name: String): String? {
        for (part in jar.orEmpty().split(';')) {
            val at = part.indexOf('=')
            if (at > 0 && part.substring(0, at).trim() == name) return part.substring(at + 1).trim()
        }
        return null
    }

    private val main = Handler(Looper.getMainLooper())
    private val waiting = ArrayDeque<() -> Unit>()
    private var busy = false

    /**
     * Run [job] once the web view is free: one page at a time, whatever it
     * is for (a check, a sign-in, a page nobody sees). [job] is handed the
     * call that frees the web view, which it makes once it is done with the
     * page. Should it throw instead, [fail] answers for it, and the web view
     * is cleared and freed all the same: the next one always goes on.
     * Returns its place in the line (see [fetch], which may give it up).
     */
    private fun enqueue(fail: () -> Unit, job: (free: () -> Unit) -> Unit): () -> Unit {
        val turn: () -> Unit = {
            var freed = false
            val free: () -> Unit = {
                if (!freed) {
                    freed = true
                    busy = false
                    main.post { next() }
                }
            }
            try {
                job(free)
            } catch (e: Exception) {
                fail()
                wipe()
                free()
            }
        }
        waiting.addLast(turn)
        if (!busy) next()
        return turn
    }

    private fun next() {
        if (busy) return
        val job = waiting.removeFirstOrNull() ?: return
        busy = true
        job()
    }

    /** [done], answered once whatever calls it after. */
    private fun once(done: (Map<String, Any?>?) -> Unit): (Map<String, Any?>?) -> Unit {
        var answered = false
        return { got ->
            if (!answered) {
                answered = true
                done(got)
            }
        }
    }

    /**
     * The web view's cookies cleared, then [seed]'s set, so the page sees
     * the site as that source alone has it; [start] runs once they are. If
     * it throws, [fail].
     */
    private fun prepare(seed: Seed, fail: () -> Unit, start: () -> Unit) {
        val cookies = CookieManager.getInstance()
        cookies.setAcceptCookie(true)
        var went = false
        val go = Runnable {
            if (!went) {
                went = true
                try {
                    for ((url, line) in seed.cookies) {
                        if (isWebPage(url)) cookies.setCookie(url, line)
                    }
                    start()
                } catch (e: Exception) {
                    fail()
                }
            }
        }
        cookies.removeAllCookies { go.run() }
        // Should the store never say it is done, the page goes on anyway.
        main.postDelayed(go, 5000)
    }

    /**
     * What the site keeps in the web view now, for the source's own cookies
     * (Net.keepFromBrowser): those it sends [url] ("a=1; b=2"), and those
     * it would send anywhere on the site, its whole domain's.
     */
    private fun harvest(url: String, seed: Seed): Map<String, Any?> {
        val cookies = CookieManager.getInstance()
        val wide = seed.domain?.let { cookies.getCookie("https://tomevoice-probe.$it/") }
        return mapOf("cookies" to (cookies.getCookie(url) ?: ""), "wide" to (wide ?: ""))
    }

    /** The web view's cookies cleared: nothing of one source is left for the next, nor kept on the disk. */
    private fun wipe() {
        try {
            val cookies = CookieManager.getInstance()
            cookies.removeAllCookies(null)
            cookies.flush()
        } catch (e: Exception) {
            // No web view on this phone: nothing kept there.
        }
    }

    /** A page and its dialog put away. */
    private fun putAway(web: WebView?, dialog: Dialog?) {
        try {
            web?.stopLoading()
            web?.destroy()
        } catch (e: Exception) {
            // Gone already.
        }
        try {
            dialog?.let { if (it.isShowing) it.dismiss() }
        } catch (e: Exception) {
            // Its window went with the activity.
        }
    }

    /**
     * [url]'s browser check in a web view, for the source [seed] is from:
     * what the site keeps once it lets the reader in ([harvest]), or null.
     * It closes by itself once the page is the site. [activity] is asked
     * for the activity showing the app when the check's turn comes.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun open(activity: () -> Activity?, url: String, userAgent: String, seed: Seed, done: (Map<String, Any?>?) -> Unit) {
        if (!isWebPage(url)) {
            done(null)
            return
        }
        val reply = once(done)
        enqueue({ reply(null) }) { free ->
            val main = Handler(Looper.getMainLooper())
            var web: WebView? = null
            var dialog: Dialog? = null
            var finished = false
            fun finish(passed: Boolean) {
                if (finished) return
                finished = true
                main.removeCallbacksAndMessages(null)
                var got: Map<String, Any?>? = null
                try {
                    val jar = harvest(url, seed)
                    // Let in: said by the page, or a clearance the site gave
                    // just now (not the one the source had already).
                    val clearance = valueIn(jar["cookies"] as? String, "cf_clearance")
                    if (passed || (clearance != null && clearance != seed.valueOf("cf_clearance"))) got = jar
                } catch (e: Exception) {
                    got = null
                }
                reply(got)
                putAway(web, dialog)
                wipe()
                free()
            }
            val a = activity()
            if (a == null) {
                finish(false)
                return@enqueue
            }
            prepare(seed, { finish(false) }) {
                val page = WebView(a)
                web = page
                CookieManager.getInstance().setAcceptThirdPartyCookies(page, true)
                page.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    userAgentString = userAgent
                }
                lockDown(page.settings)
                val host = Uri.parse(url).host ?: url
                val note = TextView(a).apply {
                    text = "Checking $host. Tick the box if the page asks; this closes by itself when the site lets you in."
                    setTextColor(Color.WHITE)
                    textSize = 14f
                    setPadding(40, 32, 24, 32)
                }
                val close = Button(a).apply { text = "Close" }
                val bar = LinearLayout(a).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
                    addView(note, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                    addView(close)
                }
                val root = LinearLayout(a).apply {
                    orientation = LinearLayout.VERTICAL
                    fitsSystemWindows = true
                    setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
                    addView(bar)
                    addView(page, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
                }
                val d = Dialog(a, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
                dialog = d
                d.setContentView(root)

                // Passed when the page is the site, not the check, for a second
                // in a row (the check reloads itself when done). Asked twice a
                // second.
                val started = System.currentTimeMillis()
                var calm = 0
                val poll = object : Runnable {
                    override fun run() {
                        if (finished) return
                        // Given up after three minutes, or once the activity
                        // under it is gone (nothing can close it then).
                        if (System.currentTimeMillis() - started > 180_000 || a.isFinishing || a.isDestroyed) {
                            finish(false)
                            return
                        }
                        if (page.progress < 100) {
                            calm = 0
                            main.postDelayed(this, 500)
                            return
                        }
                        val again = this
                        isCheckPage(page) { check ->
                            calm = if (check) 0 else calm + 1
                            if (calm >= 2) finish(true) else if (!finished) main.postDelayed(again, 500)
                        }
                    }
                }
                page.webViewClient = object : WebViewClient() {}
                close.setOnClickListener { finish(false) }
                d.setOnCancelListener { finish(false) }
                d.show()
                page.loadUrl(url)
                main.postDelayed(poll, 1000)
            }
        }
    }

    /**
     * The site at [url] in a web view, for the reader to sign in to it (a
     * source whose site wants an account), with Done once they have. What
     * the site keeps then ([harvest]) is handed back for that source's own
     * cookies, or null when it was closed without Done; either way nothing
     * of it stays in the web view. The same agent as the app's own
     * requests, so the site sees one browser. Only web pages load: a
     * sign-in's link into another app (intent:, market:) goes nowhere, and
     * Back goes back a page before it closes.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun login(activity: () -> Activity?, url: String, userAgent: String, seed: Seed, done: (Map<String, Any?>?) -> Unit) {
        if (!isWebPage(url)) {
            done(null)
            return
        }
        val reply = once(done)
        enqueue({ reply(null) }) { free ->
            val main = Handler(Looper.getMainLooper())
            var web: WebView? = null
            var dialog: Dialog? = null
            var finished = false
            fun finish(signedIn: Boolean) {
                if (finished) return
                finished = true
                main.removeCallbacksAndMessages(null)
                val got = if (signedIn) {
                    try {
                        harvest(url, seed)
                    } catch (e: Exception) {
                        null
                    }
                } else {
                    null
                }
                reply(got)
                putAway(web, dialog)
                // Done or Cancel: the web view keeps nothing of it.
                wipe()
                free()
            }
            val a = activity()
            if (a == null) {
                finish(false)
                return@enqueue
            }
            prepare(seed, { finish(false) }) {
                val page = WebView(a)
                web = page
                CookieManager.getInstance().setAcceptThirdPartyCookies(page, true)
                page.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    userAgentString = userAgent
                }
                lockDown(page.settings)
                val host = Uri.parse(url).host ?: url
                val note = TextView(a).apply {
                    text = "Sign in to $host, then tap Done. What the site keeps of it goes to this source only."
                    setTextColor(Color.WHITE)
                    textSize = 14f
                    setPadding(40, 32, 24, 32)
                }
                val cancel = Button(a).apply { text = "Cancel" }
                val ok = Button(a).apply { text = "Done" }
                val bar = LinearLayout(a).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
                    addView(note, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                    addView(cancel)
                    addView(ok)
                }
                val root = LinearLayout(a).apply {
                    orientation = LinearLayout.VERTICAL
                    fitsSystemWindows = true
                    setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
                    addView(bar)
                    addView(page, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
                }
                val d = Dialog(a, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
                dialog = d
                d.setContentView(root)

                page.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
                        !isWebPage(request?.url?.toString() ?: "")
                }
                ok.setOnClickListener { finish(true) }
                cancel.setOnClickListener { finish(false) }
                d.setOnCancelListener { finish(false) }
                // Back goes back a page, then closes: by its key, and (predictive
                // back, where the key is not sent) by the dialog's own callback.
                d.setOnKeyListener { _, keyCode, event ->
                    if (keyCode != KeyEvent.KEYCODE_BACK || !page.canGoBack()) {
                        false
                    } else {
                        if (event.action == KeyEvent.ACTION_UP) page.goBack()
                        true
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    d.onBackInvokedDispatcher.registerOnBackInvokedCallback(
                        android.window.OnBackInvokedDispatcher.PRIORITY_OVERLAY
                    ) { if (page.canGoBack()) page.goBack() else finish(false) }
                }
                // The activity under it gone (closed, or put away by Android):
                // nothing can tap Done or Cancel now.
                val watch = object : Runnable {
                    override fun run() {
                        if (finished) return
                        if (a.isFinishing || a.isDestroyed) finish(false) else main.postDelayed(this, 1000)
                    }
                }
                d.show()
                page.loadUrl(url)
                main.postDelayed(watch, 1000)
            }
        }
    }

    /** An English check page's title; the markup ([CHECK_JS]) tells in any language. */
    fun isCheck(title: String?): Boolean {
        val t = title ?: return true
        return t.isEmpty() || t.contains("Just a moment", true) ||
            t.contains("Attention Required", true) || t.contains("Checking your browser", true)
    }

    /**
     * True when the page is a Cloudflare challenge, by what every one of them
     * carries whatever its language: the challenge platform's script and
     * options, or the old check's form. Its title was English-only.
     */
    private const val CHECK_JS = """(function () {
  try {
    if (window._cf_chl_opt) return true;
    return !!document.querySelector('script[src*="/cdn-cgi/challenge-platform/"], #challenge-form, ' +
      '#challenge-running, #challenge-stage, #cf-challenge-running, .cf-browser-verification, ' +
      '#cf-please-wait, #turnstile-wrapper, iframe[src*="challenges.cloudflare.com"]');
  } catch (e) {
    return true;
  }
})()"""

    /** Whether [web]'s page is a check: its markup, or (English) its title. */
    private fun isCheckPage(web: WebView, answer: (Boolean) -> Unit) {
        web.evaluateJavascript(CHECK_JS) { raw -> answer(raw != "false" || isCheck(web.title)) }
    }

    /**
     * Load [url] in a web view nobody sees and hand back its HTML once it is
     * the site and not a check: for sites whose Cloudflare refuses the app's
     * own requests whatever cookies they carry. A POST ([method]) sends
     * [body] as a form, the one kind a web view can post. One page at a
     * time, as every use of the web view is; null if the page is still a
     * check after 25 seconds (the visible check is then the way through), or
     * if it waited 40 seconds for its turn (a sign-in or a check the reader
     * has open). Otherwise {html, url (where it ended), and what the site
     * keeps, see [harvest]}.
     */
    fun fetch(
        activity: () -> Activity?,
        url: String,
        userAgent: String,
        method: String,
        body: String?,
        seed: Seed,
        done: (Map<String, Any?>?) -> Unit,
    ) {
        if (!isWebPage(url) || (method != "GET" && method != "POST")) {
            done(null)
            return
        }
        val reply = once(done)
        val turn = enqueue({ reply(null) }) { free ->
            val a = activity()
            if (a == null) {
                reply(null)
                free()
            } else {
                load(a, url, userAgent, method, body, seed, reply, free)
            }
        }
        // Kept waiting (behind a sign-in the reader has open): the source
        // goes on without the web view rather than run out of time.
        main.postDelayed({ if (waiting.remove(turn)) reply(null) }, 40_000)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(
        activity: Activity,
        url: String,
        userAgent: String,
        method: String,
        body: String?,
        seed: Seed,
        done: (Map<String, Any?>?) -> Unit,
        free: () -> Unit,
    ) {
        val main = Handler(Looper.getMainLooper())
        var web: WebView? = null
        var parent: ViewGroup? = null
        var finished = false
        fun finish(html: String?) {
            if (finished) return
            finished = true
            main.removeCallbacksAndMessages(null)
            var got: Map<String, Any?>? = null
            if (html != null) {
                try {
                    got = harvest(url, seed) + mapOf("html" to html, "url" to (web?.url ?: url))
                } catch (e: Exception) {
                    got = null
                }
            }
            try {
                web?.stopLoading()
                web?.let { parent?.removeView(it) }
                web?.destroy()
            } catch (e: Exception) {
                // Gone with its activity.
            }
            wipe()
            done(got)
            free()
        }
        prepare(seed, { finish(null) }) {
            val page = WebView(activity)
            web = page
            CookieManager.getInstance().setAcceptThirdPartyCookies(page, true)
            page.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                blockNetworkImage = true
                userAgentString = userAgent
            }
            lockDown(page.settings)
            // Attached, but one pixel and see-through: a detached web view may
            // never run the check's scripts.
            val decor = activity.window.decorView as ViewGroup
            parent = decor
            page.alpha = 0f
            decor.addView(page, ViewGroup.LayoutParams(1, 1))
            val started = System.currentTimeMillis()
            val poll = object : Runnable {
                override fun run() {
                    if (finished) return
                    if (System.currentTimeMillis() - started > 25_000) {
                        finish(null)
                        return
                    }
                    if (page.progress < 100) {
                        main.postDelayed(this, 400)
                        return
                    }
                    val again = this
                    isCheckPage(page) { check ->
                        if (finished) return@isCheckPage
                        if (check) {
                            main.postDelayed(again, 400)
                        } else {
                            page.evaluateJavascript("document.documentElement.outerHTML") { raw ->
                                val html = try {
                                    if (raw == null || raw == "null") null else org.json.JSONArray("[$raw]").getString(0)
                                } catch (e: Exception) {
                                    null
                                }
                                finish(html)
                            }
                        }
                    }
                }
            }
            page.webViewClient = object : WebViewClient() {}
            if (method == "POST") {
                page.postUrl(url, (body ?: "").toByteArray(Charsets.UTF_8))
            } else {
                page.loadUrl(url)
            }
            main.postDelayed(poll, 800)
        }
    }
}
