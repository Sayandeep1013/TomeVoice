package app.tomevoice.tomevoice_spike

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
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
                calm = if (!isCheck(web.title) && web.progress == 100) calm + 1 else 0
                if (calm >= 2) {
                    finish(true)
                } else if (System.currentTimeMillis() - started > 180_000) {
                    finish(false)
                } else {
                    main.postDelayed(this, 500)
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

    fun isCheck(title: String?): Boolean {
        val t = title ?: return true
        return t.isEmpty() || t.contains("Just a moment", true) ||
            t.contains("Attention Required", true) || t.contains("Checking your browser", true)
    }

    private val queue = ArrayDeque<() -> Unit>()
    private var fetching = false

    /**
     * Load [url] in a web view nobody sees and hand back its HTML once it is
     * the site and not a check: for sites whose Cloudflare refuses the app's
     * own requests whatever cookies they carry. One page at a time; null if
     * the page is still a check after 25 seconds (the visible check is then
     * the way through).
     */
    fun fetch(activity: Activity, url: String, userAgent: String, done: (String?) -> Unit) {
        if (!isWebPage(url)) {
            done(null)
            return
        }
        queue.addLast { load(activity, url, userAgent) { html -> done(html); next() } }
        if (!fetching) next()
    }

    private fun next() {
        val job = queue.removeFirstOrNull()
        fetching = job != null
        job?.invoke()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(activity: Activity, url: String, userAgent: String, done: (String?) -> Unit) {
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
                if (web.progress == 100 && !isCheck(web.title)) {
                    web.evaluateJavascript("document.documentElement.outerHTML") { raw ->
                        finish(if (raw == null || raw == "null") null else org.json.JSONArray("[$raw]").getString(0))
                    }
                } else if (System.currentTimeMillis() - started > 25_000) {
                    finish(null)
                } else {
                    main.postDelayed(this, 400)
                }
            }
        }
        web.webViewClient = object : WebViewClient() {}
        web.loadUrl(url)
        main.postDelayed(poll, 800)
    }
}
