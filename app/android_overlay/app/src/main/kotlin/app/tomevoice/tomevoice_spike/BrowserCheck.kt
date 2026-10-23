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

    @SuppressLint("SetJavaScriptEnabled")
    fun open(activity: Activity, url: String, userAgent: String, done: (String?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        val cookies = CookieManager.getInstance().apply { setAcceptCookie(true) }
        val web = WebView(activity)
        cookies.setAcceptThirdPartyCookies(web, true)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgent
        }
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
            done(if (passed || jar?.contains("cf_clearance=") == true) jar else null)
            web.stopLoading()
            web.destroy()
            if (dialog.isShowing) dialog.dismiss()
        }

        // Passed when the clearance cookie is set and the page is the site,
        // not the check. Asked twice a second; given up after three minutes.
        val started = System.currentTimeMillis()
        val poll = object : Runnable {
            override fun run() {
                if (finished) return
                val jar = cookies.getCookie(url) ?: ""
                val title = web.title ?: ""
                val checking = title.contains("Just a moment", true) ||
                    title.contains("Attention Required", true) || title.isEmpty()
                if (jar.contains("cf_clearance=") && !checking) {
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
}
