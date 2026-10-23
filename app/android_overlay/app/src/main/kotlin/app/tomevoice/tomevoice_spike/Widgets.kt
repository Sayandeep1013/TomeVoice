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
    )

    private fun readJson(f: File): JSONObject? = try {
        if (f.isFile) JSONObject(f.readText()) else null
    } catch (e: Exception) {
        null
    }

    fun books(ctx: Context): List<Book> {
        val lib = readJson(File(root(ctx), "library.json")) ?: return emptyList()
        val tints = readJson(File(root(ctx), "tints.json"))?.optJSONObject("books")
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

    // ---------------------------------------------------------------- style

    class Look(ctx: Context, tint: Int) {
        val dark = (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val ground = if (dark) Color.BLACK else Color.WHITE
        val ink = if (dark) Color.rgb(242, 238, 232) else Color.rgb(20, 20, 20)
        val dim = if (dark) Color.rgb(142, 138, 132) else Color.rgb(110, 110, 110)
        val off = if (dark) Color.rgb(43, 43, 43) else Color.rgb(226, 226, 226)
        val accent = readable(if (tint == 0) Color.rgb(224, 123, 57) else tint, dark)
        val onAccent = if (luminance(accent) > 0.45) Color.BLACK else Color.WHITE
        val bodoni = font(ctx, "BodoniModa-Variable.ttf", 500)
        val figtree = font(ctx, "Figtree-Variable.ttf", 600)
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

    /** 5 x 7 dot glyphs, the same as the app's (stats.dart). */
    private val glyphs = mapOf(
        '0' to intArrayOf(14, 17, 19, 21, 25, 17, 14),
        '1' to intArrayOf(4, 12, 4, 4, 4, 4, 14),
        '2' to intArrayOf(14, 17, 1, 2, 4, 8, 31),
        '3' to intArrayOf(31, 2, 4, 2, 1, 17, 14),
        '4' to intArrayOf(2, 6, 10, 18, 31, 2, 2),
        '5' to intArrayOf(31, 16, 30, 1, 1, 17, 14),
        '6' to intArrayOf(6, 8, 16, 30, 17, 17, 14),
        '7' to intArrayOf(31, 1, 2, 4, 8, 8, 8),
        '8' to intArrayOf(14, 17, 17, 14, 17, 17, 14),
        '9' to intArrayOf(14, 17, 17, 15, 1, 2, 12),
        '%' to intArrayOf(24, 25, 2, 4, 8, 19, 3),
        ' ' to intArrayOf(0, 0, 0, 0, 0, 0, 0),
    )

    /** Width of [text] in dots of size [dot]. */
    fun dotWidth(text: String, dot: Float): Float = text.length * 6 * dot * 1.5f - dot * 1.5f

    fun dots(c: Canvas, text: String, x: Float, y: Float, dot: Float, color: Int) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        val step = dot * 1.5f
        text.forEachIndexed { g, ch ->
            val rows = glyphs[ch] ?: return@forEachIndexed
            for (r in 0 until 7) for (col in 0 until 5) {
                if (rows[r] and (16 shr col) != 0) {
                    c.drawCircle(x + (g * 6 + col) * step + dot / 2, y + r * step + dot / 2, dot / 2, p)
                }
            }
        }
    }

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

    /** The TomeVoice mark, small, top right. */
    fun mark(c: Canvas, right: Float, top: Float, unit: Float, color: Int) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        val heights = floatArrayOf(5f, 9f, 7f, 11f, 6f)
        for (i in heights.indices) {
            val x = right - (heights.size - i) * unit * 1.6f
            val hh = heights[i] * unit * 0.55f
            c.drawRoundRect(RectF(x, top + (6.5f * unit - hh / 2), x + unit * 0.7f, top + (6.5f * unit + hh / 2)), unit, unit, p)
        }
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
        try {
            views.setImageViewBitmap(R.id.widget_face, render(ctx, id, wDp.toFloat(), hDp.toFloat(), u))
            // The tap target over the drawn button (Android 12 and later can
            // move it; before that the layout's place is close).
            val r = playRect
            if (r != null && Build.VERSION.SDK_INT >= 31) {
                val dip = android.util.TypedValue.COMPLEX_UNIT_DIP
                views.setViewLayoutWidth(R.id.widget_play, r.width() / u, dip)
                views.setViewLayoutHeight(R.id.widget_play, r.height() / u, dip)
                views.setViewLayoutMargin(R.id.widget_play, RemoteViews.MARGIN_LEFT, r.left / u, dip)
                views.setViewLayoutMargin(R.id.widget_play, RemoteViews.MARGIN_TOP, r.top / u, dip)
            }
        } catch (e: Exception) {
            // A face that cannot be drawn stays as it was.
        }
        taps(ctx, id, views)
        mgr.updateAppWidget(id, views)
    }

    open fun defaultWidthDp() = 160
    open fun defaultHeightDp() = 160

    // ---- drawing in dp ----------------------------------------------------

    /** A face of [w] x [h] dp, and a canvas that draws in dp. */
    fun canvas(w: Float, h: Float, u: Float, look: Widgets.Look): Pair<Bitmap, Canvas> {
        val (bmp, c) = Widgets.face((w * u).toInt(), (h * u).toInt(), look, 24 * u)
        c.scale(u, u)
        return bmp to c
    }

    fun ink(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }

    fun text(c: Canvas, s: String, x: Float, y: Float, size: Float, face: Typeface, color: Int, maxWidth: Float, caps: Boolean = false) =
        Widgets.text(c, s, x, y, size, face, color, max(0f, maxWidth), caps)

    /** Up to two lines of [s], the second ending in "…" if it runs over; returns the height used. */
    fun twoLines(c: Canvas, s: String, x: Float, top: Float, size: Float, face: Typeface, color: Int, width: Float): Float {
        val p = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; typeface = face; this.color = color }
        val layout = android.text.StaticLayout.Builder.obtain(s, 0, s.length, p, max(1, width.toInt()))
            .setMaxLines(2)
            .setEllipsize(TextUtils.TruncateAt.END)
            .setLineSpacing(0f, 0.95f)
            .build()
        c.save()
        c.translate(x, top)
        layout.draw(c)
        c.restore()
        return layout.height.toFloat()
    }

    fun dotHeight(dot: Float) = 7 * dot * 1.5f - dot * 0.5f

    /** The TomeVoice mark, [h] dp tall, its right edge at [right]. */
    fun mark(c: Canvas, right: Float, top: Float, h: Float, color: Int) {
        val unit = h / 11f
        val bars = floatArrayOf(5f, 9f, 7f, 11f, 6f)
        val p = ink(color)
        for (i in bars.indices) {
            val x = right - (bars.size - i) * unit * 1.7f
            val bh = bars[i] * unit
            c.drawRoundRect(RectF(x, top + (h - bh) / 2, x + unit * 0.8f, top + (h + bh) / 2), unit, unit, p)
        }
    }

    /** A row of dots across [width], the first [frac] of them lit. */
    fun dotRow(c: Canvas, x: Float, y: Float, width: Float, dot: Float, frac: Double, look: Widgets.Look) {
        val step = dot * 1.9f
        val n = max(4, ((width + dot * 0.9f) / step).toInt())
        val lit = (frac * n).roundToInt()
        val on = ink(look.accent)
        val off = ink(look.off)
        for (i in 0 until n) c.drawCircle(x + i * step + dot / 2, y, dot / 2, if (i < lit) on else off)
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

/** Now reading: the book being read (or one chosen), with play. */
open class PlayerWidget : BaseWidget() {
    override val layout = R.layout.widget_small

    override fun render(ctx: Context, id: Int, w: Float, h: Float, u: Float): Bitmap {
        val book = Widgets.book(ctx, id)
        val look = Widgets.Look(ctx, book?.tint ?: 0)
        val (bmp, c) = canvas(w, h, u, look)
        if (book == null) {
            text(c, "Add a book to TomeVoice", 16f, h / 2 + 4, 13f, look.figtree, look.ink, w - 32)
            return bmp
        }
        val pct = "${(book.progress * 100).roundToInt()}%"
        when {
            h < 110 -> strip(c, book, pct, w, h, u, look)
            w < 230 -> square(c, book, pct, w, h, u, look)
            h < 230 -> wide(c, book, pct, w, h, u, look)
            else -> large(c, book, pct, w, h, u, look)
        }
        return bmp
    }

    /** A strip (4 x 1): the cover in its ring, the title and chapter, play. */
    private fun strip(c: Canvas, book: Widgets.Book, pct: String, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val pad = 12f
        val d = h - 2 * pad
        val cx = pad + d / 2
        val cy = h / 2
        val dot = max(2.2f, d * 0.05f)
        Widgets.ring(c, cx, cy, d / 2 - dot / 2, dot, 28, (book.progress * 28).roundToInt(), look)
        coverCircle(c, book, cx, cy, d - dot * 2 - 6, u, look)
        val r = min(17f, d / 2)
        play(c, w - pad - r, cy, r, u, look)
        val x = pad + d + 12
        val maxW = w - x - pad - 2 * r - 12
        text(c, book.title, x, cy - 3, 14f, look.bodoni, look.ink, maxW)
        text(c, if (book.where.isEmpty()) pct else "$pct · ${book.where}", x, cy + 13, 9f, look.figtree, look.dim, maxW, caps = true)
    }

    /** A square (2 x 2): the cover in a ring of dots, play beside it, the title below. */
    private fun square(c: Canvas, book: Widgets.Book, pct: String, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val pad = 16f
        val r = 17f
        val d = min(w - 2 * pad - 2 * r - 14, h - 2 * pad - 44)
        val cx = pad + d / 2
        val cy = pad + d / 2
        val dot = d * 0.042f
        Widgets.ring(c, cx, cy, d / 2 - dot / 2, dot, 32, (book.progress * 32).roundToInt(), look)
        coverCircle(c, book, cx, cy, d - dot * 2 - 8, u, look)
        play(c, w - pad - r, cy + d * 0.18f, r, u, look)
        mark(c, w - pad, pad + 2, 8f, look.dim)
        text(c, book.title, pad, h - pad - 17, 14.5f, look.bodoni, look.ink, w - 2 * pad)
        val pd = 1.05f
        Widgets.dots(c, pct, pad, h - pad - dotHeight(pd), pd, look.dim)
        val x = pad + Widgets.dotWidth(pct, pd) + 8
        text(c, book.where.substringBefore(':'), x, h - pad, 8.5f, look.figtree, look.dim, w - x - pad, caps = true)
    }

    /** Wide (4 x 2, 3 x 2): the cover, the title and chapter, dots for progress, play. */
    private fun wide(c: Canvas, book: Widgets.Book, pct: String, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val pad = 16f
        val ch = h - 2 * pad
        val cw = min(ch * 0.68f, w * 0.32f)
        coverRect(c, book, RectF(pad, pad, pad + cw, pad + ch), 12f, u, look)
        val x = pad + cw + 16
        val width = w - x - pad
        mark(c, w - pad, pad + 2, 8f, look.dim)
        text(c, book.title, x, pad + 16, 17f, look.bodoni, look.ink, width - 26)
        text(c, book.where, x, pad + 34, 10.5f, look.figtree, look.dim, width)
        dotRow(c, x, pad + 54, width - 4, 3.6f, book.progress, look)
        val pd = 1.15f
        Widgets.dots(c, pct, x, pad + 66, pd, look.dim)
        val label = if (book.chapters > 0) "of ${book.chapters} chapters" else "through"
        text(c, label, x + Widgets.dotWidth(pct, pd) + 7, pad + 66 + dotHeight(pd) - 0.5f, 9f, look.figtree, look.dim, width, caps = true)
        val r = 19f
        play(c, w - pad - r, h - pad - r, r, u, look)
    }

    /** Large (3 x 3 and up): the cover beside its title, progress across the foot, play. */
    private fun large(c: Canvas, book: Widgets.Book, pct: String, w: Float, h: Float, u: Float, look: Widgets.Look) {
        val pad = 18f
        val r = 22f
        val ch = min(h - 2 * pad - 2 * r - 30, (w - 2 * pad) * 0.62f / 0.68f)
        val cw = ch * 0.68f
        coverRect(c, book, RectF(pad, pad, pad + cw, pad + ch), 14f, u, look)
        val x = pad + cw + 16
        val width = w - x - pad
        mark(c, w - pad, pad + 2, 8f, look.dim)
        val used = twoLines(c, book.title, x, pad + 2, 20f, look.bodoni, look.ink, width - 18)
        val where = book.where
        val head = where.substringBefore(':').trim()
        val rest = if (where.contains(':')) where.substringAfter(':').trim() else ""
        text(c, head, x, pad + used + 18, 10.5f, look.figtree, look.dim, width, caps = true)
        if (rest.isNotEmpty()) text(c, rest, x, pad + used + 34, 11f, look.figtree, look.dim, width)
        dotRow(c, pad, h - pad - 2 * r - 14, w - 2 * pad, 4.2f, book.progress, look)
        val pd = 1.3f
        Widgets.dots(c, pct, pad, h - pad - r - dotHeight(pd) / 2, pd, look.ink)
        val label = if (book.chapters > 0) "of ${book.chapters} chapters" else "through"
        text(c, label, pad + Widgets.dotWidth(pct, pd) + 8, h - pad - r + 4, 9.5f, look.figtree, look.dim, w - 2 * pad - 2 * r - 60, caps = true)
        play(c, w - pad - r, h - pad - r, r, u, look)
    }

    override fun taps(ctx: Context, id: Int, views: RemoteViews) {
        val book = Widgets.book(ctx, id)
        views.setOnClickPendingIntent(R.id.widget_face, Widgets.openApp(ctx, id * 4, book?.id, false, null))
        views.setOnClickPendingIntent(
            R.id.widget_play,
            if (ReadAloudService.isRunning()) Widgets.toggle(ctx, id * 4 + 1)
            else Widgets.openApp(ctx, id * 4 + 2, book?.id, true, null),
        )
    }
}

/** Now reading, offered wide: the same widget, a wider start. */
class PlayerWidgetWide : PlayerWidget() {
    override val layout = R.layout.widget_wide

    override fun defaultWidthDp() = 320
}

/** The streak: days in a row, the week, and (with room) weeks of days. */
open class StreakWidget : BaseWidget() {
    override val layout = R.layout.widget_plain

    override fun render(ctx: Context, id: Int, w: Float, h: Float, u: Float): Bitmap {
        val habit = Widgets.habit(ctx, 7 * 30)
        val current = Widgets.books(ctx).firstOrNull()
        val look = Widgets.Look(ctx, current?.tint ?: 0)
        val (bmp, c) = canvas(w, h, u, look)
        when {
            h < 110 -> strip(c, habit, w, h, look)
            w < 230 -> square(c, habit, w, h, look)
            h < 230 -> wide(c, habit, w, h, look)
            else -> large(c, habit, w, h, look)
        }
        return bmp
    }

    private fun label(habit: Widgets.Habit) = if (habit.streak == 1) "day streak" else "days streak"

    private fun weekText(habit: Widgets.Habit): String {
        val m = habit.days.takeLast(7).sum()
        return if (m < 60) "${m}m this week" else "${m / 60}h ${m % 60}m this week"
    }

    /** The last seven days, today a ring closing toward the goal. */
    private fun week(c: Canvas, habit: Widgets.Habit, x: Float, y: Float, width: Float, r: Float, lettersY: Float, look: Widgets.Look) {
        val slot = width / 7f
        val days = habit.days.takeLast(7)
        val todayIndex = (Calendar.getInstance().apply { add(Calendar.HOUR_OF_DAY, -4) }.get(Calendar.DAY_OF_WEEK) + 5) % 7
        val on = ink(look.ink)
        val off = ink(look.off)
        val letters = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 7.5f; typeface = look.figtree; color = look.dim; textAlign = Paint.Align.CENTER
        }
        for (i in 0 until 7) {
            val cx = x + slot * i + slot / 2
            val m = days.getOrElse(i) { 0 }
            if (i == 6) {
                val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = r * 0.36f; strokeCap = Paint.Cap.ROUND }
                val box = RectF(cx - r * 0.82f, y - r * 0.82f, cx + r * 0.82f, y + r * 0.82f)
                c.drawArc(box, 0f, 360f, false, stroke.apply { color = look.off })
                val sweep = 360f * min(1f, m.toFloat() / habit.goalMin)
                if (sweep > 0) c.drawArc(box, -90f, sweep, false, stroke.apply { color = look.accent })
            } else {
                c.drawCircle(cx, y, r, if (m >= habit.goalMin) on else off)
            }
            c.drawText("MTWTFSS"[(todayIndex - (6 - i) + 7) % 7].toString(), cx, lettersY, letters)
        }
    }

    /** Days as dots in columns of seven, newest at the right; brighter for more. */
    private fun grid(c: Canvas, habit: Widgets.Habit, x: Float, y: Float, cols: Int, step: Float, look: Widgets.Look) {
        val days = habit.days.takeLast(cols * 7)
        val offset = cols * 7 - days.size
        for (i in days.indices) {
            val m = days[i]
            val p = ink(if (m == 0) look.off else look.ink).apply {
                alpha = when {
                    m == 0 -> 255
                    m < habit.goalMin -> 90
                    m < habit.goalMin * 4 -> 180
                    else -> 255
                }
            }
            val k = i + offset
            c.drawCircle(x + (k / 7) * step + step / 2, y + (k % 7) * step + step / 2, step * 0.3f, p)
        }
    }

    private fun strip(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val pad = 14f
        val dot = 2.4f
        val n = "${habit.streak}"
        Widgets.dots(c, n, pad, (h - dotHeight(dot)) / 2 - 6, dot, look.ink)
        text(c, label(habit), pad, h - pad + 1, 8.5f, look.figtree, look.dim, 100f, caps = true)
        val x0 = pad + max(Widgets.dotWidth(n, dot), 70f) + 16
        week(c, habit, x0, h / 2 - 5, w - x0 - pad, min(6f, (w - x0 - pad) / 7 * 0.3f), h / 2 + 15, look)
    }

    private fun square(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val pad = 16f
        val n = "${habit.streak}"
        val dot = min(3.1f, (w - 2 * pad - 24) / (n.length * 9f))
        Widgets.dots(c, n, pad, pad, dot, look.ink)
        mark(c, w - pad, pad + 2, 8f, look.dim)
        val y = pad + dotHeight(dot)
        text(c, label(habit), pad, y + 17, 9f, look.figtree, look.dim, w - 2 * pad, caps = true)
        text(c, "${min(habit.todayMin, habit.goalMin)} of ${habit.goalMin} min today", pad, y + 31, 9f, look.figtree, look.ink, w - 2 * pad, caps = true)
        val r = min((w - 2 * pad) / 7 * 0.3f, 6f)
        week(c, habit, pad, h - pad - 13 - r, w - 2 * pad, r, h - pad, look)
    }

    private fun wide(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val pad = 16f
        val n = "${habit.streak}"
        val dot = 3.1f
        Widgets.dots(c, n, pad, pad, dot, look.ink)
        val y = pad + dotHeight(dot)
        val left = max(Widgets.dotWidth(n, dot), 92f)
        text(c, label(habit), pad, y + 17, 9f, look.figtree, look.dim, left, caps = true)
        text(c, weekText(habit), pad, h - pad, 9f, look.figtree, look.ink, left + 10, caps = true)
        val gx = pad + left + 14
        val step = min((w - gx - pad) / 18f, (h - 2 * pad) / 7f)
        val cols = ((w - gx - pad) / step).toInt()
        grid(c, habit, w - pad - cols * step, (h - 7 * step) / 2, cols, step, look)
    }

    private fun large(c: Canvas, habit: Widgets.Habit, w: Float, h: Float, look: Widgets.Look) {
        val pad = 18f
        val n = "${habit.streak}"
        val dot = 3.6f
        Widgets.dots(c, n, pad, pad, dot, look.ink)
        mark(c, w - pad, pad + 2, 8f, look.dim)
        val y = pad + dotHeight(dot)
        text(c, label(habit), pad, y + 18, 9.5f, look.figtree, look.dim, w - 2 * pad, caps = true)
        text(c, "best ${habit.best} · ${weekText(habit)}", pad, y + 33, 9.5f, look.figtree, look.ink, w - 2 * pad, caps = true)
        val top = y + 52
        val bottom = h - pad - 34
        val step = min(16f, (bottom - top) / 7f)
        val cols = ((w - 2 * pad) / step).toInt()
        grid(c, habit, pad + ((w - 2 * pad) - cols * step) / 2, top + ((bottom - top) - 7 * step) / 2, cols, step, look)
        week(c, habit, pad, h - pad - 17, w - 2 * pad, 5f, h - pad, look)
    }

    override fun taps(ctx: Context, id: Int, views: RemoteViews) {
        views.setOnClickPendingIntent(R.id.widget_face, Widgets.openApp(ctx, id * 4 + 3, null, false, "stats"))
    }
}

/** The streak, offered wide: the same widget, a wider start. */
class StreakWidgetWide : StreakWidget() {
    override fun defaultWidthDp() = 320
}
