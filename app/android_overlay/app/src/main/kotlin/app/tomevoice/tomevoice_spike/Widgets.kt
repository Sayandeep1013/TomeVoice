package app.tomevoice.tomevoice_spike

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.TextPaint
import android.text.TextUtils
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The home-screen widgets, in Nothing's manner with TomeVoice's: black (or
 * white) faces, dots for progress and dot-matrix numbers, the book's cover
 * and its title in Bodoni, and the book's colour on the lit dots and the
 * play button.
 *
 * Each face is drawn here as one picture; Android widgets cannot load
 * custom fonts or draw dots themselves. They read the library, the cover
 * colours and the stats straight from the app's files, so they are right
 * even when the app is not running.
 */
object Widgets {

    const val EXTRA_BOOK = "app.tomevoice.widget.BOOK"
    const val EXTRA_PLAY = "app.tomevoice.widget.PLAY"
    const val EXTRA_PAGE = "app.tomevoice.widget.PAGE"
    private const val PREFS = "widgets"

    /** Redraw every TomeVoice widget (the library or playback changed). */
    fun refreshAll(ctx: Context) {
        val mgr = AppWidgetManager.getInstance(ctx)
        for (cls in listOf(PlayerWidget::class.java, PlayerWidgetWide::class.java, StreakWidget::class.java, StreakWidgetWide::class.java)) {
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, cls))
            if (ids.isEmpty()) continue
            val provider = cls.getDeclaredConstructor().newInstance() as BaseWidget
            for (id in ids) provider.draw(ctx, mgr, id)
        }
    }

    /** The book a widget follows: one chosen for it, or null for the one read last. */
    fun bookFor(ctx: Context, widgetId: Int): String? =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("book_$widgetId", null)

    fun setBook(ctx: Context, widgetId: Int, bookId: String?) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            if (bookId == null) remove("book_$widgetId") else putString("book_$widgetId", bookId)
        }.apply()
    }

    // ------------------------------------------------------------------ data

    fun root(ctx: Context): File = ctx.getExternalFilesDir(null) ?: ctx.filesDir

    class Book(
        val id: String,
        val title: String,
        val where: String,
        val progress: Double,
        val cover: String?,
        val tint: Int,
        val chapters: Int,
        /** The app's own accent for the book (see widgetAccents in book_tint.dart), if saved. */
        val accents: IntArray?,
        val words: Int,
    )

    private fun readJson(f: File): JSONObject? = try {
        if (f.isFile) JSONObject(f.readText()) else null
    } catch (e: Exception) {
        null
    }

    fun books(ctx: Context): List<Book> {
        val lib = readJson(File(root(ctx), "library.json")) ?: return emptyList()
        val tintFile = readJson(File(root(ctx), "tints.json"))
        val tints = tintFile?.optJSONObject("books")
        val accents = tintFile?.optJSONObject("accents")
        val arr = lib.optJSONArray("books") ?: return emptyList()
        val out = mutableListOf<Pair<String, Book>>()
        for (i in 0 until arr.length()) {
            val b = arr.optJSONObject(i) ?: continue
            val id = b.optString("id")
            val cover = when (b.optString("coverMode", "auto")) {
                "plain" -> null
                "custom" -> b.optString("customCover").ifEmpty { b.optString("cover") }
                else -> b.optString("cover")
            }?.ifEmpty { null }
            val when_ = b.optString("openedAt").ifEmpty { b.optString("addedAt") }
            out.add(
                when_ to Book(
                    id = id,
                    title = b.optString("title", "TomeVoice"),
                    where = b.optString("where"),
                    progress = b.optDouble("progress", 0.0),
                    cover = cover,
                    tint = (tints?.optLong(id, 0L) ?: 0L).toInt(),
                    chapters = b.optInt("chapterCount", 0),
                    accents = accents?.optJSONArray(id)?.let { a -> IntArray(a.length()) { a.optLong(it).toInt() } }?.takeIf { it.size == 4 },
                    words = b.optInt("wordCount", 0),
                )
            )
        }
        return out.sortedByDescending { it.first }.map { it.second }
    }

    fun book(ctx: Context, widgetId: Int): Book? {
        val all = books(ctx)
        val chosen = bookFor(ctx, widgetId)
        return all.firstOrNull { it.id == chosen } ?: all.firstOrNull()
    }

    class Habit(val streak: Int, val todayMin: Int, val goalMin: Int, val days: List<Int>, val best: Int)

    /** The streak and recent days, as the app counts them (a day starts at 4 am). */
    fun habit(ctx: Context, dayCount: Int): Habit {
        val json = readJson(File(root(ctx), "stats.json"))
        val days = json?.optJSONObject("days")
        val goal = json?.optInt("goalMinutes", 5) ?: 5
        fun minutes(key: String): Int {
            val d = days?.optJSONObject(key) ?: return 0
            return ((d.optLong("listen") + d.optLong("read")) / 60000).toInt()
        }
        val cal = Calendar.getInstance().apply { add(Calendar.HOUR_OF_DAY, -4) }
        fun key(c: Calendar) = String.format(
            java.util.Locale.US, "%04d-%02d-%02d",
            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH),
        )
        val today = minutes(key(cal))
        val list = MutableList(dayCount) { 0 }
        val walk = cal.clone() as Calendar
        for (i in dayCount - 1 downTo 0) {
            list[i] = minutes(key(walk))
            walk.add(Calendar.DAY_OF_MONTH, -1)
        }
        var streak = 0
        val s = cal.clone() as Calendar
        if (today < goal) s.add(Calendar.DAY_OF_MONTH, -1)
        while (minutes(key(s)) >= goal) {
            streak++
            s.add(Calendar.DAY_OF_MONTH, -1)
        }
        // The longest run ever, from every day kept.
        var best = 0
        var run = 0
        var prev: java.time.LocalDate? = null
        val keys = days?.keys()?.asSequence()?.toList()?.sorted() ?: emptyList()
        for (k in keys) {
            if (minutes(k) < goal) continue
            val d = try { java.time.LocalDate.parse(k) } catch (e: Exception) { continue }
            run = if (prev != null && prev.plusDays(1) == d) run + 1 else 1
            best = max(best, run)
            prev = d
        }
        return Habit(streak, today, goal, list, max(best, streak))
    }

    /** Time left in [book] at the reading speed, as the app shows it ("1h 33m left"), or null if unknown. */
    fun timeLeft(ctx: Context, book: Book): String? {
        if (book.words <= 0) return null
        val speed = readJson(File(root(ctx), "prefs.json"))?.optJSONObject("settings")?.optDouble("speedScale", 1.0) ?: 1.0
        // The same 165 words a minute the app reckons with.
        val min = (book.words * (1 - book.progress) / (165 * max(0.25, speed))).roundToInt()
        return when {
            min < 1 -> null
            min < 60 -> "${min}m left"
            else -> "${min / 60}h ${min % 60}m left"
        }
    }

    // ---------------------------------------------------------------- style

    class Look(private val ctx: Context, tint: Int, accents: IntArray? = null) {
        val dark = (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val ground = if (dark) Color.BLACK else Color.WHITE
        val ink = if (dark) Color.rgb(242, 238, 232) else Color.rgb(20, 20, 20)
        val dim = if (dark) Color.rgb(142, 138, 132) else Color.rgb(110, 110, 110)
        val off = if (dark) Color.rgb(43, 43, 43) else Color.rgb(226, 226, 226)
        val accent = accents?.get(if (dark) 0 else 2) ?: readable(if (tint == 0) Color.rgb(224, 123, 57) else tint, dark)
        val onAccent = accents?.get(if (dark) 1 else 3) ?: if (luminance(accent) > 0.45) Color.BLACK else Color.WHITE
        val bodoni = font(ctx, "BodoniModa-Variable.ttf", 500)
        val figtree = font(ctx, "Figtree-Variable.ttf", 600)

        /** Doto, the dot-matrix face of the design, at [weight]. */
        fun doto(weight: Int): Typeface = Widgets.doto(ctx, weight)
    }

    /** Doto at [weight] (a variable font: the weight is a variation, not a style). */
    fun doto(ctx: Context, weight: Int): Typeface = fonts.getOrPut("doto/$weight") {
        try {
            Typeface.Builder(ctx.assets, "flutter_assets/assets/fonts/Doto-Variable.ttf")
                .setFontVariationSettings("'wght' $weight")
                .build()
        } catch (e: Exception) {
            Typeface.MONOSPACE
        }
    }

    private val fonts = HashMap<String, Typeface>()

    private fun font(ctx: Context, file: String, weight: Int): Typeface = fonts.getOrPut("$file/$weight") {
        val base = try {
            Typeface.createFromAsset(ctx.assets, "flutter_assets/assets/fonts/$file")
        } catch (e: Exception) {
            Typeface.DEFAULT
        }
        if (Build.VERSION.SDK_INT >= 28) Typeface.create(base, weight, false) else base
    }

    private fun luminance(c: Int): Double =
        (0.2126 * Color.red(c) + 0.7152 * Color.green(c) + 0.0722 * Color.blue(c)) / 255.0

    /** A cover colour that shows on the face: lifted on black, deepened on white. */
    private fun readable(c: Int, dark: Boolean): Int {
        val l = luminance(c)
        return when {
            dark && l < 0.45 -> mix(c, Color.WHITE, (0.45 - l) / 0.55 * 0.8)
            !dark && l > 0.6 -> mix(c, Color.BLACK, (l - 0.6) * 1.2)
            else -> c
        }
    }

    private fun mix(a: Int, b: Int, t: Double): Int {
        val k = t.coerceIn(0.0, 1.0)
        fun ch(x: Int, y: Int) = (x + (y - x) * k).roundToInt()
        return Color.rgb(ch(Color.red(a), Color.red(b)), ch(Color.green(a), Color.green(b)), ch(Color.blue(a), Color.blue(b)))
    }

    // ------------------------------------------------------------- drawing

    fun text(c: Canvas, s: String, x: Float, y: Float, size: Float, face: Typeface, color: Int, maxWidth: Float, caps: Boolean = false) {
        val p = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            typeface = face
            this.color = color
            if (caps) letterSpacing = 0.08f
        }
        val shown = TextUtils.ellipsize(if (caps) s.uppercase() else s, p, maxWidth, TextUtils.TruncateAt.END).toString()
        c.drawText(shown, x, y, p)
    }

    fun face(w: Int, h: Int, look: Look, radius: Float): Pair<Bitmap, Canvas> {
        val bmp = Bitmap.createBitmap(max(w, 1), max(h, 1), Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.ground })
        return bmp to c
    }

    /**
     * A postage stamp of [w] x [h]: perforated all round with holes of radius
     * [hole] (the wallpaper shows through them), one at each corner, and a
     * hairline frame inside the teeth.
     */
    fun stampFace(w: Int, h: Int, look: Look, hole: Float): Pair<Bitmap, Canvas> {
        val bmp = Bitmap.createBitmap(max(w, 1), max(h, 1), Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val fw = w.toFloat()
        val fh = h.toFloat()
        val body = Path().apply { addRect(0f, 0f, fw, fh, Path.Direction.CW) }
        val holes = Path()
        // Holes a little under two across apart, so the teeth are a hole wide.
        fun along(length: Float, at: (Float) -> Unit) {
            val n = max(2, (length / (hole * 3.6f)).roundToInt())
            for (i in 0..n) at(length * i / n)
        }
        along(fw) { x ->
            holes.addCircle(x, 0f, hole, Path.Direction.CW)
            holes.addCircle(x, fh, hole, Path.Direction.CW)
        }
        along(fh) { y ->
            holes.addCircle(0f, y, hole, Path.Direction.CW)
            holes.addCircle(fw, y, hole, Path.Direction.CW)
        }
        body.op(holes, Path.Op.DIFFERENCE)
        c.drawPath(body, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.ground })
        val inset = hole * 2.1f
        c.drawRoundRect(
            RectF(inset, inset, fw - inset, fh - inset), hole * 0.6f, hole * 0.6f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = max(1f, hole * 0.22f)
                color = look.off
            },
        )
        return bmp to c
    }

    fun cover(path: String?, size: Int): Bitmap? = try {
        if (path == null) null else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    } catch (e: Exception) {
        null
    }

    /** [bmp] cropped to fill [dst], clipped by [clip] (a circle or rounded rectangle). */
    fun drawCover(c: Canvas, bmp: Bitmap?, dst: RectF, clip: Path, fallback: Int) {
        c.save()
        c.clipPath(clip)
        if (bmp == null) {
            c.drawRect(dst, Paint().apply { color = fallback })
        } else {
            val scale = max(dst.width() / bmp.width, dst.height() / bmp.height)
            val m = Matrix().apply {
                setScale(scale, scale)
                postTranslate(dst.centerX() - bmp.width * scale / 2, dst.centerY() - bmp.height * scale / 2)
            }
            c.drawRect(dst, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
                shader = BitmapShader(bmp, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply { setLocalMatrix(m) }
            })
        }
        c.restore()
    }

    /** A round play (or pause) button. */
    fun playButton(c: Canvas, cx: Float, cy: Float, r: Float, look: Look, playing: Boolean) {
        c.drawCircle(cx, cy, r, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.accent })
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.onAccent }
        if (playing) {
            val bw = r * 0.22f
            val bh = r * 0.8f
            c.drawRoundRect(RectF(cx - bw * 1.6f, cy - bh / 2, cx - bw * 0.6f, cy + bh / 2), bw / 3, bw / 3, p)
            c.drawRoundRect(RectF(cx + bw * 0.6f, cy - bh / 2, cx + bw * 1.6f, cy + bh / 2), bw / 3, bw / 3, p)
        } else {
            val t = r * 0.42f
            val path = Path().apply {
                moveTo(cx - t * 0.7f, cy - t)
                lineTo(cx + t, cy)
                lineTo(cx - t * 0.7f, cy + t)
                close()
            }
            c.drawPath(path, p)
        }
    }

    /** A ring of [count] dots, the first [lit] in the accent. */
    fun ring(c: Canvas, cx: Float, cy: Float, radius: Float, dot: Float, count: Int, lit: Int, look: Look) {
        val on = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.accent }
        val off = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.off }
        for (i in 0 until count) {
            val a = -Math.PI / 2 + i * 2 * Math.PI / count
            c.drawCircle(cx + (radius * cos(a)).toFloat(), cy + (radius * sin(a)).toFloat(), dot / 2, if (i < lit) on else off)
        }
    }

    fun isPlaying(): Boolean = ReadAloudService.isPlaying()

    fun openApp(ctx: Context, code: Int, book: String?, play: Boolean, page: String?): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            action = "app.tomevoice.widget.OPEN.$code"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (book != null) putExtra(EXTRA_BOOK, book)
            if (play) putExtra(EXTRA_PLAY, true)
            if (page != null) putExtra(EXTRA_PAGE, page)
        }
        return PendingIntent.getActivity(ctx, code, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** [action] sent to the reading service. */
    fun service(ctx: Context, code: Int, action: String): PendingIntent = PendingIntent.getService(
        ctx,
        code,
        Intent(ctx, ReadAloudService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun toggle(ctx: Context, code: Int): PendingIntent = PendingIntent.getService(
        ctx,
        code,
        Intent(ctx, ReadAloudService::class.java).setAction(
            if (isPlaying()) ReadAloudService.ACTION_PAUSE else ReadAloudService.ACTION_PLAY
        ),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

/** Shared by the four widgets: size, the picture, and what a tap does. */
abstract class BaseWidget : AppWidgetProvider() {

    abstract val layout: Int

    /**
     * Draw the face at [w] x [h] dp, [u] pixels to the dp. Each kind of widget
     * has a layout for each size class (a strip, a square, wide, large), all
     * measured in dp so the spacing is the same on every phone.
     */
    abstract fun render(ctx: Context, id: Int, w: Float, h: Float, u: Float): Bitmap

    /** Where the play button was drawn, in pixels of the last face, if any. */
    var playRect: RectF? = null

    /** Where chapter back and on were drawn, likewise. */
    var prevRect: RectF? = null
    var nextRect: RectF? = null

    /** Wire the taps on [views]. */
    abstract fun taps(ctx: Context, id: Int, views: RemoteViews)

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) draw(ctx, mgr, id)
    }

    override fun onAppWidgetOptionsChanged(ctx: Context, mgr: AppWidgetManager, id: Int, options: Bundle) {
        draw(ctx, mgr, id)
    }

    override fun onDeleted(ctx: Context, ids: IntArray) {
        for (id in ids) Widgets.setBook(ctx, id, null)
    }

    fun draw(ctx: Context, mgr: AppWidgetManager, id: Int) {
        val opts = mgr.getAppWidgetOptions(id)
        val density = ctx.resources.displayMetrics.density
        // Portrait size; a sensible default before the launcher says.
        val wDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 } ?: defaultWidthDp()
        val hDp = opts.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT).takeIf { it > 0 } ?: defaultHeightDp()
        // Two and a half pixels a dp is sharp enough and keeps the picture small.
        val u = min(density, 2.5f)
        val views = RemoteViews(ctx.packageName, layout)
        playRect = null
        prevRect = null
        nextRect = null
        try {
            views.setImageViewBitmap(R.id.widget_face, render(ctx, id, wDp.toFloat(), hDp.toFloat(), u))
            // The tap targets over the drawn buttons. Android 12 and later
            // can move them; before that play keeps the layout's place (close)
            // and chapter back and on are left out.
            place(views, R.id.widget_play, playRect, u, keep = true)
            place(views, R.id.widget_prev, prevRect, u, keep = false)
            place(views, R.id.widget_next, nextRect, u, keep = false)
        } catch (e: Exception) {
            // A face that cannot be drawn stays as it was.
        }
        taps(ctx, id, views)
        mgr.updateAppWidget(id, views)
    }

    private fun place(views: RemoteViews, view: Int, r: RectF?, u: Float, keep: Boolean) {
        if (r == null || Build.VERSION.SDK_INT < 31) {
            if (!keep || r == null) views.setViewVisibility(view, android.view.View.GONE)
            return
        }
        val dip = android.util.TypedValue.COMPLEX_UNIT_DIP
        views.setViewVisibility(view, android.view.View.VISIBLE)
        views.setViewLayoutWidth(view, r.width() / u, dip)
        views.setViewLayoutHeight(view, r.height() / u, dip)
        views.setViewLayoutMargin(view, RemoteViews.MARGIN_LEFT, r.left / u, dip)
        views.setViewLayoutMargin(view, RemoteViews.MARGIN_TOP, r.top / u, dip)
    }

    open fun defaultWidthDp() = 160
    open fun defaultHeightDp() = 160

    /** Cut like a postage stamp instead of a rounded card. */
    open val stamp = false

    // ---- drawing in dp ----------------------------------------------------

    /** A face of [w] x [h] dp, and a canvas that draws in dp. */
    fun canvas(w: Float, h: Float, u: Float, look: Widgets.Look): Pair<Bitmap, Canvas> {
        val (bmp, c) = if (stamp) {
            Widgets.stampFace((w * u).toInt(), (h * u).toInt(), look, (min(w, h) * 0.024f).coerceIn(2.6f, 4.2f) * u)
        } else {
            Widgets.face((w * u).toInt(), (h * u).toInt(), look, 24 * u)
        }
        c.scale(u, u)
        return bmp to c
    }

    fun ink(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }

    fun text(c: Canvas, s: String, x: Float, y: Float, size: Float, face: Typeface, color: Int, maxWidth: Float, caps: Boolean = false) =
        Widgets.text(c, s, x, y, size, face, color, max(0f, maxWidth), caps)

    /**
     * [s] in Doto, the design's dot type: upper case, spaced a little, its
     * baseline at [y]. Returns the width drawn.
     */
    fun dotText(c: Canvas, s: String, x: Float, y: Float, size: Float, color: Int, maxWidth: Float, look: Widgets.Look, weight: Int = 600): Float {
        val p = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            typeface = look.doto(weight)
            this.color = color
            letterSpacing = if (weight >= 800) 0.02f else 0.08f
        }
        val shown = TextUtils.ellipsize(s.uppercase(), p, max(0f, maxWidth), TextUtils.TruncateAt.END).toString()
        c.drawText(shown, x, y, p)
        return p.measureText(shown)
    }

    /** The TomeVoice mark: five bars, [h] dp tall at most, its right edge at [right]. */
    fun mark(c: Canvas, right: Float, top: Float, h: Float, color: Int) {
        val unit = h / 11f
        val bars = floatArrayOf(5f, 9f, 7f, 11f, 6f)
        val p = ink(color)
        for (i in bars.indices) {
            val x = right - (bars.size - i) * unit * 4f + unit * 2f
            val bh = bars[i] * unit
            c.drawRoundRect(RectF(x, top + (h - bh) / 2, x + unit * 2f, top + (h + bh) / 2), unit, unit, p)
        }
    }

    /** A row of dots ([dot] wide, [gap] apart) across [width], the first [frac] of them lit. */
    fun dotRow(c: Canvas, x: Float, y: Float, width: Float, dot: Float, gap: Float, frac: Double, look: Widgets.Look) {
        val step = dot + gap
        val n = max(4, ((width + gap) / step).toInt())
        val lit = (frac * n).roundToInt()
        val on = ink(look.accent)
        val off = ink(look.off)
        for (i in 0 until n) c.drawCircle(x + i * step + dot / 2, y, dot / 2, if (i < lit) on else off)
    }

    /** Chapter back or on, [half] dp to either side of its centre, remembering where for its tap target. */
    fun skip(c: Canvas, cx: Float, cy: Float, half: Float, forward: Boolean, u: Float, look: Widgets.Look) {
        val p = ink(look.ink)
        val bar = half * 0.24f
        val dir = if (forward) 1f else -1f
        val back = cx - dir * half
        val tip = cx + dir * (half - bar * 1.6f)
        c.drawPath(Path().apply {
            moveTo(back, cy - half * 0.86f)
            lineTo(tip, cy)
            lineTo(back, cy + half * 0.86f)
            close()
        }, p)
        val bx = if (forward) cx + half - bar else cx - half
        c.drawRoundRect(RectF(bx, cy - half * 0.86f, bx + bar, cy + half * 0.86f), bar / 2, bar / 2, p)
        // A finger-sized target around the small icon.
        val t = max(half * 2.4f, 22f)
        val r = RectF((cx - t) * u, (cy - t) * u, (cx + t) * u, (cy + t) * u)
        if (forward) nextRect = r else prevRect = r
    }

    fun coverCircle(c: Canvas, book: Widgets.Book, cx: Float, cy: Float, d: Float, u: Float, look: Widgets.Look) {
        val rect = RectF(cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2)
        Widgets.drawCover(c, Widgets.cover(book.cover, (d * u).toInt()), rect, Path().apply { addOval(rect, Path.Direction.CW) }, look.off)
    }

    fun coverRect(c: Canvas, book: Widgets.Book, rect: RectF, radius: Float, u: Float, look: Widgets.Look) {
        Widgets.drawCover(c, Widgets.cover(book.cover, (rect.width() * u).toInt()), rect,
            Path().apply { addRoundRect(rect, radius, radius, Path.Direction.CW) }, look.off)
    }

    /** Play, in dp, remembering where (in pixels) for the tap target. */
    fun play(c: Canvas, cx: Float, cy: Float, r: Float, u: Float, look: Widgets.Look) {
        Widgets.playButton(c, cx, cy, r, look, Widgets.isPlaying())
        playRect = RectF((cx - r) * u, (cy - r) * u, (cx + r) * u, (cy + r) * u)
    }
}

/**
 * Now reading: the book being read (or one chosen), with play.
 *
 * Drawn to the design in docs/road-to-1.0.html: its 2 x 2 is a 176-unit
 * square and its 4 x 2 a 360 x 176 card. Each layout takes those units and
 * scales them as one piece ([s] dp a unit), so a launcher's 136 dp square
 * looks like the design, only smaller, instead of squeezing a few parts.
 */
open class PlayerWidget : BaseWidget() {
    override val layout = R.layout.widget_small

    override val stamp = true

    override fun render(ctx: Context, id: Int, w: Float, h: Float, u: Float): Bitmap {
        val book = Widgets.book(ctx, id)
        val look = Widgets.Look(ctx, book?.tint ?: 0, book?.accents)
        val (bmp, c) = canvas(w, h, u, look)
        if (book == null) {
            text(c, "Add a book to TomeVoice", 16f, h / 2 + 4, 13f, look.figtree, look.ink, w - 32)
            return bmp
        }
        val pct = "${(book.progress * 100).roundToInt()}%"
        val left = Widgets.timeLeft(ctx, book)
        when {
            h < 110 -> strip(c, book, pct, left, w, h, u, look)
            w < 230 -> square(c, book, pct, left, w, h, u, look)
            h < 190 -> wide(c, book, pct, left, w, h, u, look)
            else -> large(c, book, pct, left, w, h, u, look)
        }
        return bmp
    }

    private fun label(pct: String, left: String?) = if (left == null) pct else "$pct · $left"

    /** 2 x 2: the cover in a ring of 36 dots, play beside it, the title and a dot-type line beneath. */
    private fun square(c: Canvas, book: Widgets.Book, pct: String, left: String?, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val s = min(w, h) / 176f
        val pad = 15.2f * s
        val ring = 97.6f * s
        val cx = pad + ring / 2
        val cy = pad + ring / 2
        Widgets.ring(c, cx, cy, ring * 0.46f, ring * 0.052f, 36, (book.progress * 36).roundToInt(), look)
        coverCircle(c, book, cx, cy, ring - 18.6f * s, u, look)
        mark(c, w - 16f * s, pad, 11f * s, look.dim)
        val r = 23.2f * s
        play(c, w - pad - r, pad + 56.8f * s + r, r, u, look)
        val labelSize = 11.8f * s
        val labelBase = h - 13.6f * s - labelSize * 0.2f
        // In from the edge a little, clear of the stamp's frame.
        val tx = pad + 6f * s
        dotText(c, label(pct, left), tx, labelBase, labelSize, look.dim, w - tx - pad, look)
        val titleBase = labelBase - labelSize * 0.8f - 4.8f * s - 16f * s * 0.3f
        text(c, book.title, tx, titleBase, 16f * s, look.bodoni, look.ink, w - tx - pad)
    }

    /** 4 x 2: the cover, the title and chapter, a row of dots, the time left and the controls. */
    private fun wide(c: Canvas, book: Widgets.Book, pct: String, left: String?, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val s = min(h / 176f, w / 360f)
        val pad = 15.2f * s
        val ch = h - 2 * pad
        val cw = min(100.8f * s * ch / (145.6f * s), w * 0.34f)
        coverRect(c, book, RectF(pad, pad, pad + cw, pad + ch), 14.4f * s, u, look)
        val x = pad + cw + 15.2f * s
        val width = w - x - pad
        text(c, book.title, x, pad + 15f * s, 17.3f * s, look.bodoni, look.ink, width)
        text(c, book.where, x, pad + 33f * s, 11.2f * s, look.figtree, look.dim, width)
        val dot = 6f * s
        dotRow(c, x, pad + 51f * s, width, dot, 3f * s, book.progress, look)
        dotText(c, "$pct read", x, pad + 75f * s, 11.8f * s, look.dim, width, look)
        val r = 23.2f * s
        val pcx = w - pad - 16.8f * s - 12f * s - r
        val pcy = h - pad - r
        play(c, pcx, pcy, r, u, look)
        skip(c, pcx - r - 12f * s - 8.4f * s, pcy, 8.4f * s, false, u, look)
        skip(c, pcx + r + 12f * s + 8.4f * s, pcy, 8.4f * s, true, u, look)
        if (left != null) dotText(c, left, x, pcy + 11.8f * s * 0.35f, 11.8f * s, look.dim, pcx - r - 40f * s - x, look)
    }

    /** 4 x 1: the cover in its ring, the title and the dot-type line, play. */
    private fun strip(c: Canvas, book: Widgets.Book, pct: String, left: String?, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val s = h / 72f
        val pad = 10f * s
        val ring = h - 2 * pad
        val cx = pad + ring / 2
        val cy = h / 2
        Widgets.ring(c, cx, cy, ring * 0.46f, ring * 0.06f, 28, (book.progress * 28).roundToInt(), look)
        coverCircle(c, book, cx, cy, ring - 14f * s, u, look)
        val r = 19f * s
        play(c, w - pad - 4f * s - r, cy, r, u, look)
        val x = pad + ring + 12f * s
        val width = w - x - 2 * r - pad - 16f * s
        text(c, book.title, x, cy - 2f * s, 15f * s, look.bodoni, look.ink, width)
        dotText(c, label(pct, left), x, cy + 14f * s, 10f * s, look.dim, width, look)
    }

    /** 4 x 3 and up: the ring and how far along at the top; the title, chapter and controls along the foot. */
    private fun large(c: Canvas, book: Widgets.Book, pct: String, left: String?, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val s = min(w / 300f, h / 230f)
        val pad = 18f * s
        val ring = 132f * s
        val cx = pad + ring / 2
        val cy = pad + ring / 2
        Widgets.ring(c, cx, cy, ring * 0.46f, ring * 0.05f, 44, (book.progress * 44).roundToInt(), look)
        coverCircle(c, book, cx, cy, ring - 22f * s, u, look)
        mark(c, w - pad, pad, 11f * s, look.dim)
        val x = pad + ring + 20f * s
        val top = cy - 22f * s
        dotText(c, pct, x, top + 20f * s, 30f * s, look.ink, w - x - pad, look, weight = 800)
        dotText(c, "of the book", x, top + 38f * s, 10.5f * s, look.dim, w - x - pad, look)
        if (left != null) dotText(c, left, x, top + 54f * s, 10.5f * s, look.dim, w - x - pad, look)
        val r = 24f * s
        val pcy = h - pad - r
        val nextX = w - pad - 9f * s
        val pcx = nextX - 9f * s - 16f * s - r
        val prevX = pcx - r - 16f * s - 9f * s
        play(c, pcx, pcy, r, u, look)
        skip(c, prevX, pcy, 9f * s, false, u, look)
        skip(c, nextX, pcy, 9f * s, true, u, look)
        val width = prevX - 9f * s - 16f * s - pad
        text(c, book.title, pad, pcy - 1f * s, 19f * s, look.bodoni, look.ink, width)
        text(c, book.where, pad, pcy + 16f * s, 11.5f * s, look.figtree, look.dim, width)
    }

    override fun taps(ctx: Context, id: Int, views: RemoteViews) {
        val book = Widgets.book(ctx, id)
        val running = ReadAloudService.isRunning()
        views.setOnClickPendingIntent(R.id.widget_face, Widgets.openApp(ctx, id * 8, book?.id, false, null))
        views.setOnClickPendingIntent(
            R.id.widget_play,
            if (running) Widgets.toggle(ctx, id * 8 + 1) else Widgets.openApp(ctx, id * 8 + 2, book?.id, true, null),
        )
        // Chapter back and on: to the reading service while it runs; until
        // then, like the face, they open the book.
        views.setOnClickPendingIntent(
            R.id.widget_prev,
            if (running) Widgets.service(ctx, id * 8 + 3, ReadAloudService.ACTION_PREV) else Widgets.openApp(ctx, id * 8 + 4, book?.id, false, null),
        )
        views.setOnClickPendingIntent(
            R.id.widget_next,
            if (running) Widgets.service(ctx, id * 8 + 5, ReadAloudService.ACTION_NEXT) else Widgets.openApp(ctx, id * 8 + 6, book?.id, false, null),
        )
    }
}

/** Now reading, offered wide: the same widget, a wider start. */
class PlayerWidgetWide : PlayerWidget() {
    override val layout = R.layout.widget_wide

    override fun defaultWidthDp() = 320
}

/**
 * The streak: days in a row, the week, and (with room) weeks of days. Drawn
 * to the same design as the player, in the same units.
 */
open class StreakWidget : BaseWidget() {
    override val layout = R.layout.widget_plain

    override fun render(ctx: Context, id: Int, w: Float, h: Float, u: Float): Bitmap {
        val habit = Widgets.habit(ctx, 7 * 30)
        val current = Widgets.books(ctx).firstOrNull()
        val look = Widgets.Look(ctx, current?.tint ?: 0, current?.accents)
        val (bmp, c) = canvas(w, h, u, look)
        when {
            h < 110 -> strip(c, habit, w, h, look)
            w < 230 -> square(c, habit, w, h, look)
            h < 190 -> wide(c, habit, w, h, look)
            else -> large(c, habit, w, h, look)
        }
        return bmp
    }

    private fun label(habit: Widgets.Habit) = if (habit.streak == 1) "day streak" else "days streak"

    private fun today(habit: Widgets.Habit) = "${min(habit.todayMin, habit.goalMin)} of ${habit.goalMin} min today"

    private fun weekText(habit: Widgets.Habit): String {
        val m = habit.days.takeLast(7).sum()
        return if (m < 60) "${m}m" else "${m / 60}h ${m % 60}m"
    }

    /** The last seven days as dots ([r] each), today a ring closing toward the goal, letters beneath. */
    private fun week(c: Canvas, habit: Widgets.Habit, x: Float, y: Float, width: Float, r: Float, letter: Float, look: Widgets.Look) {
        val days = habit.days.takeLast(7)
        val todayIndex = (Calendar.getInstance().apply { add(Calendar.HOUR_OF_DAY, -4) }.get(Calendar.DAY_OF_WEEK) + 5) % 7
        val step = (width - 2 * r) / 6f
        val on = ink(look.ink)
        val off = ink(look.off)
        val letters = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = letter; typeface = look.doto(700); color = look.dim; textAlign = Paint.Align.CENTER
        }
        for (i in 0 until 7) {
            val cx = x + r + step * i
            val m = days.getOrElse(i) { 0 }
            if (i == 6) {
                val sw = r * 0.36f
                val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = sw; strokeCap = Paint.Cap.ROUND }
                val box = RectF(cx - r + sw / 2, y - r + sw / 2, cx + r - sw / 2, y + r - sw / 2)
                c.drawArc(box, 0f, 360f, false, stroke.apply { color = look.off })
                val sweep = 360f * min(1f, m.toFloat() / habit.goalMin)
                if (sweep > 0) c.drawArc(box, -90f, sweep, false, stroke.apply { color = look.ink })
            } else {
                c.drawCircle(cx, y, r, if (m >= habit.goalMin) on else off)
            }
            c.drawText("MTWTFSS"[(todayIndex - (6 - i) + 7) % 7].toString(), cx, y + r + letter * 0.55f + letter * 0.62f, letters)
        }
    }

    /** Days as dots in columns of seven, newest at the right; brighter for more. */
    private fun grid(c: Canvas, habit: Widgets.Habit, right: Float, y: Float, cols: Int, step: Float, dot: Float, look: Widgets.Look) {
        val days = habit.days.takeLast(cols * 7)
        val offset = cols * 7 - days.size
        val x = right - cols * step + (step - dot)
        for (i in days.indices) {
            val m = days[i]
            val p = ink(if (m == 0) look.off else look.ink).apply {
                alpha = when {
                    m == 0 -> 255
                    m < habit.goalMin -> 100
                    m < habit.goalMin * 4 -> 175
                    else -> 255
                }
            }
            val k = i + offset
            c.drawCircle(x + (k / 7) * step + dot / 2, y + (k % 7) * step + dot / 2, dot / 2, p)
        }
    }

    /** 2 x 2: the streak in dot type, today, and the week. */
    private fun square(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val s = min(w, h) / 176f
        val pad = 15.2f * s
        mark(c, w - 16f * s, pad, 11f * s, look.dim)
        val num = 49.6f * s
        dotText(c, "${habit.streak}", pad, pad + num * 0.74f, num, look.ink, w - 2 * pad - 30f * s, look, weight = 800)
        val l = 11.8f * s
        dotText(c, label(habit), pad, pad + num * 0.9f + 7.2f * s + l * 0.8f, l, look.dim, w - 2 * pad, look)
        dotText(c, today(habit), pad, pad + num * 0.9f + 7.2f * s + l * 1.8f + 5.6f * s, l, look.ink, w - 2 * pad, look)
        val letter = 8.8f * s
        val r = 6.7f * s
        week(c, habit, pad, h - 14.4f * s - letter - 4.8f * s - r, w - 2 * pad, r, letter, look)
    }

    /** 4 x 2: the streak and the week's time at the left, the last weeks as dots at the right. */
    private fun wide(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val s = min(h / 176f, w / 360f)
        val pad = 15.2f * s
        val num = 49.6f * s
        val l = 11.8f * s
        val colW = 134.4f * s
        dotText(c, "${habit.streak}", pad, pad + num * 0.74f, num, look.ink, colW, look, weight = 800)
        dotText(c, label(habit), pad, pad + num * 0.9f + 7.2f * s + l * 0.8f, l, look.dim, colW, look)
        dotText(c, weekText(habit), pad, h - pad - l - 4.8f * s, l, look.ink, colW, look)
        dotText(c, "this week", pad, h - pad - l * 0.2f, l, look.dim, colW, look)
        val dot = 6f * s
        val step = 9.5f * s
        val gx = pad + colW + 15.2f * s
        val cols = min(18, ((w - gx - pad + (step - dot)) / step).toInt())
        grid(c, habit, w - pad, (h - 7 * step + (step - dot)) / 2, cols, step, dot, look)
    }

    /** 4 x 1: the streak, then the week. */
    private fun strip(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val s = h / 72f
        val pad = 12f * s
        val num = 34f * s
        val n = "${habit.streak}"
        val nw = dotText(c, n, pad, h / 2 + num * 0.3f, num, look.ink, 90f * s, look, weight = 800)
        val l = 9.5f * s
        val lx = pad + nw + 8f * s
        dotText(c, if (habit.streak == 1) "day" else "days", lx, h / 2 - 2f * s, l, look.dim, 60f * s, look)
        dotText(c, "streak", lx, h / 2 + l, l, look.dim, 60f * s, look)
        val x0 = lx + 62f * s
        val r = min(6f * s, (w - x0 - pad) / 7f * 0.32f)
        week(c, habit, x0, h / 2 - 6f * s, w - x0 - pad, r, 8f * s, look)
    }

    /** 4 x 3 and up: the square's top, the last weeks as dots, the week beneath. */
    private fun large(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val s = min(w / 300f, h / 260f)
        val pad = 18f * s
        mark(c, w - pad, pad, 11f * s, look.dim)
        val num = 56f * s
        dotText(c, "${habit.streak}", pad, pad + num * 0.74f, num, look.ink, w / 2, look, weight = 800)
        val l = 12f * s
        val y = pad + num * 0.9f + 8f * s
        dotText(c, label(habit), pad, y + l * 0.8f, l, look.dim, w - 2 * pad, look)
        dotText(c, "best ${habit.best} · ${weekText(habit)} this week", pad, y + l * 2f + 4f * s, l, look.ink, w - 2 * pad, look)
        val letter = 9f * s
        val r = 7f * s
        val weekY = h - pad - letter - 5f * s - r
        week(c, habit, pad, weekY, w - 2 * pad, r, letter, look)
        val top = y + l * 2.6f + 16f * s
        val bottom = weekY - r - 16f * s
        val step = min(12f * s, (bottom - top) / 7f)
        val dot = step * 0.64f
        val cols = ((w - 2 * pad + (step - dot)) / step).toInt()
        grid(c, habit, w - pad, top + ((bottom - top) - 7 * step) / 2, cols, step, dot, look)
    }

    override fun taps(ctx: Context, id: Int, views: RemoteViews) {
        views.setOnClickPendingIntent(R.id.widget_face, Widgets.openApp(ctx, id * 8 + 7, null, false, "stats"))
    }
}

/** The streak, offered wide: the same widget, a wider start. */
class StreakWidgetWide : StreakWidget() {
    override fun defaultWidthDp() = 320
}
