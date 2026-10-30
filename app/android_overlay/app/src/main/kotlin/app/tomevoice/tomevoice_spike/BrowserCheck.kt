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

    @SuppressLint("SetJavaScriptEnabled")
    fun open(activity: Activity, url: String, userAgent: String, done: (String?) -> Unit) {
        if (!isWebPage(url)) {
            done(null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        val cookies = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val web = WebView(activity)
        cookies.setAcceptThirdPartyCookies(web, true)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgent
        }
        lockDown(web.settings)
        val host = Uri.parse(url).host ?: url
        val note = TextView(activity).apply {
            text = "Checking $host. Tick the box if the page asks; this closes by itself when the site lets you in."
            setTextColor(Color.WHITE)
            textSize = 14f
            setPadding(40, 32, 24, 32)
        }
        val close = Button(activity).apply { text = "Close" }
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
            addView(note, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(close)
        }
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
            addView(bar)
            addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        dialog.setContentView(root)

        var finished = false
        fun finish(passed: Boolean) {
            if (finished) return
            finished = true
            main.removeCallbacksAndMessages(null)
            cookies.flush()
            val jar = cookies.getCookie(url)
            done(if (passed || jar?.contains("cf_clearance=") == true) (jar ?: "") else null)
            web.stopLoading()
            web.destroy()
            if (dialog.isShowing) dialog.dismiss()
        }

        // Passed when the page is the site, not the check, for a second in a
        // row (the check reloads itself when done). Asked twice a second;
        // given up after three minutes.
        val started = System.currentTimeMillis()
        var calm = 0
        val poll = object : Runnable {
            override fun run() {
                if (finished) return
                if (System.currentTimeMillis() - started > 180_000) {
                    finish(false)
                    return
                }
                if (web.progress < 100) {
                    calm = 0
                    main.postDelayed(this, 500)
                    return
                }
                val again = this
                isCheckPage(web) { check ->
                    calm = if (check) 0 else calm + 1
                    if (calm >= 2) finish(true) else if (!finished) main.postDelayed(again, 500)
                }
            }
        }
        web.webViewClient = object : WebViewClient() {}
        close.setOnClickListener { finish(false) }
        dialog.setOnCancelListener { finish(false) }
        dialog.show()
        web.loadUrl(url)
        main.postDelayed(poll, 1000)
    }

    /**
     * The site at [url] in a web view, for the reader to sign in to it (a
     * source whose site wants an account), with Done once they have. Its
     * cookies for [url] are handed back ("a=1; b=2") for that source's own
     * jar, or null when it was closed without Done. The same agent as the
     * app's own requests, so the site sees one browser. Only web pages
     * load: a sign-in's link into another app (intent:, market:) goes
     * nowhere, and Back goes back a page before it closes.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun login(activity: Activity, url: String, userAgent: String, done: (String?) -> Unit) {
        if (!isWebPage(url)) {
            done(null)
            return
        }
        val cookies = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val web = WebView(activity)
        cookies.setAcceptThirdPartyCookies(web, true)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgent
        }
        lockDown(web.settings)
        val host = Uri.parse(url).host ?: url
        val note = TextView(activity).apply {
            text = "Sign in to $host, then tap Done. What the site keeps of it goes to this source only."
            setTextColor(Color.WHITE)
            textSize = 14f
            setPadding(40, 32, 24, 32)
        }
        val cancel = Button(activity).apply { text = "Cancel" }
        val ok = Button(activity).apply { text = "Done" }
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
            addView(note, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(cancel)
            addView(ok)
        }
        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setBackgroundColor(Color.rgb(0x1E, 0x2A, 0x24))
            addView(bar)
            addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        dialog.setContentView(root)

        var finished = false
        fun finish(signedIn: Boolean) {
            if (finished) return
            finished = true
            cookies.flush()
            val jar = if (signedIn) (cookies.getCookie(url) ?: "") else null
            done(jar)
            web.stopLoading()
            web.destroy()
            if (dialog.isShowing) dialog.dismiss()
        }

        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
                !isWebPage(request?.url?.toString() ?: "")
        }
        ok.setOnClickListener { finish(true) }
        cancel.setOnClickListener { finish(false) }
        dialog.setOnCancelListener { finish(false) }
        // Back goes back a page, then closes: by its key, and (predictive
        // back, where the key is not sent) by the dialog's own callback.
        dialog.setOnKeyListener { _, keyCode, event ->
            if (keyCode != KeyEvent.KEYCODE_BACK || !web.canGoBack()) {
                false
            } else {
                if (event.action == KeyEvent.ACTION_UP) web.goBack()
                true
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            dialog.onBackInvokedDispatcher.registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_OVERLAY
            ) { if (web.canGoBack()) web.goBack() else finish(false) }
        }
        dialog.show()
        web.loadUrl(url)
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

    private val queue = ArrayDeque<() -> Unit>()
    private var fetching = false

    /**
     * Load [url] in a web view nobody sees and hand back its HTML once it is
     * the site and not a check: for sites whose Cloudflare refuses the app's
     * own requests whatever cookies they carry. A POST ([method]) sends
     * [body] as a form, the one kind a web view can post. One page at a
     * time; null if the page is still a check after 25 seconds (the visible
     * check is then the way through).
     */
    fun fetch(
        activity: Activity,
        url: String,
        userAgent: String,
        method: String = "GET",
        body: String? = null,
        done: (String?) -> Unit,
    ) {
        if (!isWebPage(url) || (method != "GET" && method != "POST")) {
            done(null)
            return
        }
        queue.addLast { load(activity, url, userAgent, method, body) { html -> done(html); next() } }
        if (!fetching) next()
    }

    private fun next() {
        val job = queue.removeFirstOrNull()
        fetching = job != null
        job?.invoke()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(activity: Activity, url: String, userAgent: String, method: String, body: String?, done: (String?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        val web = WebView(activity)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            blockNetworkImage = true
            userAgentString = userAgent
        }
        lockDown(web.settings)
        // Attached, but one pixel and see-through: a detached web view may
        // never run the check's scripts.
        val parent = activity.window.decorView as ViewGroup
        web.alpha = 0f
        parent.addView(web, ViewGroup.LayoutParams(1, 1))
        var finished = false
        fun finish(html: String?) {
            if (finished) return
            finished = true
            main.removeCallbacksAndMessages(null)
            web.stopLoading()
            parent.removeView(web)
            web.destroy()
            done(html)
        }
        val started = System.currentTimeMillis()
        val poll = object : Runnable {
            override fun run() {
                if (finished) return
                if (System.currentTimeMillis() - started > 25_000) {
                    finish(null)
                    return
                }
                if (web.progress < 100) {
                    main.postDelayed(this, 400)
                    return
                }
                val again = this
                isCheckPage(web) { check ->
                    if (finished) return@isCheckPage
                    if (check) {
                        main.postDelayed(again, 400)
                    } else {
                        web.evaluateJavascript("document.documentElement.outerHTML") { raw ->
                            finish(if (raw == null || raw == "null") null else org.json.JSONArray("[$raw]").getString(0))
                        }
                    }
                }
            }
        }
        web.webViewClient = object : WebViewClient() {}
        if (method == "POST") {
            web.postUrl(url, (body ?: "").toByteArray(Charsets.UTF_8))
        } else {
            web.loadUrl(url)
        }
        main.postDelayed(poll, 800)
    }
}
