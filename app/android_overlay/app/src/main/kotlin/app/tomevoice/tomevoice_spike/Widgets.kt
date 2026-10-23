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

    class Habit(val streak: Int, val todayMin: Int, val goalMin: Int, val days: List<Int>)

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
        return Habit(streak, today, goal, list)
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
     * Draw the face at [w] x [h] pixels ([u] pixels a dp). Faces are laid
     * out in proportion to their size, so a 2 x 2 and a 3 x 3 look alike.
     */
    abstract fun render(ctx: Context, id: Int, w: Int, h: Int, u: Float): Bitmap

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
        val scale = min(density, 2.5f)
        val views = RemoteViews(ctx.packageName, layout)
        playRect = null
        try {
            views.setImageViewBitmap(R.id.widget_face, render(ctx, id, (wDp * scale).toInt(), (hDp * scale).toInt(), scale))
            // The tap target over the drawn button (Android 12 and later can
            // move it; before that the layout's place is close).
            val r = playRect
            if (r != null && Build.VERSION.SDK_INT >= 31) {
                val dip = android.util.TypedValue.COMPLEX_UNIT_DIP
                views.setViewLayoutWidth(R.id.widget_play, r.width() / scale, dip)
                views.setViewLayoutHeight(R.id.widget_play, r.height() / scale, dip)
                views.setViewLayoutMargin(R.id.widget_play, RemoteViews.MARGIN_LEFT, r.left / scale, dip)
                views.setViewLayoutMargin(R.id.widget_play, RemoteViews.MARGIN_TOP, r.top / scale, dip)
            }
        } catch (e: Exception) {
            // A face that cannot be drawn stays as it was.
        }
        taps(ctx, id, views)
        mgr.updateAppWidget(id, views)
    }

    open fun defaultWidthDp() = 160
    open fun defaultHeightDp() = 160
}

/** Now reading, small: the cover in a ring of dots, the title, play. */
open class PlayerWidget : BaseWidget() {
    override val layout = R.layout.widget_small

    override fun render(ctx: Context, id: Int, w: Int, h: Int, u: Float): Bitmap {
        val book = Widgets.book(ctx, id)
        val look = Widgets.Look(ctx, book?.tint ?: 0)
        val s = min(w, h).toFloat()
        val (bmp, c) = Widgets.face(w, h, look, 0.16f * s)
        val pad = 0.09f * s
        Widgets.mark(c, w - pad, pad, 0.0055f * s, look.dim)
        if (book == null) {
            Widgets.text(c, "Add a book to TomeVoice", pad, h / 2f, 0.08f * s, look.figtree, look.ink, w - 2 * pad)
            return bmp
        }
        val ringD = 0.58f * s
        val cx = pad + ringD / 2
        val cy = pad + ringD / 2
        val dot = 0.026f * s
        Widgets.ring(c, cx, cy, ringD / 2 - dot, dot, 36, (book.progress * 36).roundToInt(), look)
        val coverD = ringD - 0.13f * s
        val rect = RectF(cx - coverD / 2, cy - coverD / 2, cx + coverD / 2, cy + coverD / 2)
        Widgets.drawCover(c, Widgets.cover(book.cover, coverD.toInt()), rect, Path().apply { addOval(rect, Path.Direction.CW) }, look.off)
        // Play: beside the ring, level with its middle.
        val r = 0.125f * s
        val px = w - pad - r
        Widgets.playButton(c, px, cy, r, look, Widgets.isPlaying())
        playRect = RectF(px - r, cy - r, px + r, cy + r)
        Widgets.text(c, book.title, pad, h - pad - 0.135f * s, 0.095f * s, look.bodoni, look.ink, w - 2 * pad)
        val pct = "${(book.progress * 100).roundToInt()}%"
        val d = 0.009f * s
        Widgets.dots(c, pct, pad, h - pad - 7 * d * 1.5f, d, look.dim)
        val after = pad + Widgets.dotWidth(pct, d) + 0.04f * s
        Widgets.text(c, book.where, after, h - pad, 0.055f * s, look.figtree, look.dim, w - pad - after, caps = true)
        return bmp
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

/** Now reading, wide: cover, title, chapter, dot progress, play. */
class PlayerWidgetWide : PlayerWidget() {
    override val layout = R.layout.widget_wide

    override fun defaultWidthDp() = 320

    override fun render(ctx: Context, id: Int, w: Int, h: Int, u: Float): Bitmap {
        val book = Widgets.book(ctx, id)
        val look = Widgets.Look(ctx, book?.tint ?: 0)
        val s = h.toFloat()
        val (bmp, c) = Widgets.face(w, h, look, 0.16f * s)
        val pad = 0.09f * s
        if (book == null) {
            Widgets.text(c, "Add a book to TomeVoice", pad, h / 2f, 0.08f * s, look.figtree, look.ink, w - 2 * pad)
            return bmp
        }
        val coverH = h - 2 * pad
        val coverW = min(coverH * 0.68f, w * 0.34f)
        val rect = RectF(pad, pad, pad + coverW, pad + coverH)
        Widgets.drawCover(c, Widgets.cover(book.cover, coverW.toInt()), rect,
            Path().apply { addRoundRect(rect, 0.09f * s, 0.09f * s, Path.Direction.CW) }, look.off)
        val x = rect.right + 0.09f * s
        val width = w - x - pad
        Widgets.mark(c, w - pad, pad, 0.0055f * s, look.dim)
        Widgets.text(c, book.title, x, pad + 0.11f * s, 0.11f * s, look.bodoni, look.ink, width - 0.12f * s)
        Widgets.text(c, book.where, x, pad + 0.22f * s, 0.07f * s, look.figtree, look.dim, width)
        // Progress as a row of dots.
        val count = 24
        val dot = min(0.04f * s, width / (count * 1.5f))
        val on = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.accent }
        val off = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.off }
        val lit = (book.progress * count).roundToInt()
        for (i in 0 until count) c.drawCircle(x + i * dot * 1.5f + dot / 2, pad + 0.33f * s, dot / 2, if (i < lit) on else off)
        val pct = "${(book.progress * 100).roundToInt()}%"
        Widgets.dots(c, pct, x, pad + 0.42f * s, 0.012f * s, look.dim)
        val r = 0.15f * s
        val px = w - pad - r
        val py = h - pad - r
        Widgets.playButton(c, px, py, r, look, Widgets.isPlaying())
        playRect = RectF(px - r, py - r, px + r, py + r)
        return bmp
    }
}

/** The streak, small: the number in dots, the week, today's ring. */
open class StreakWidget : BaseWidget() {
    override val layout = R.layout.widget_plain

    override fun render(ctx: Context, id: Int, w: Int, h: Int, u: Float): Bitmap {
        val habit = Widgets.habit(ctx, 7)
        val current = Widgets.books(ctx).firstOrNull()
        val look = Widgets.Look(ctx, current?.tint ?: 0)
        val s = min(w, h).toFloat()
        val (bmp, c) = Widgets.face(w, h, look, 0.16f * s)
        val pad = 0.09f * s
        Widgets.mark(c, w - pad, pad, 0.0055f * s, look.dim)
        val number = "${habit.streak}"
        val digit = min(0.035f * s, (w - 2 * pad - 0.16f * s) / (number.length * 9f))
        Widgets.dots(c, number, pad, pad, digit, look.ink)
        val below = pad + 7 * digit * 1.5f
        Widgets.text(c, if (habit.streak == 1) "day streak" else "days streak", pad, below + 0.1f * s, 0.06f * s, look.figtree, look.dim, w - 2 * pad, caps = true)
        Widgets.text(c, "${min(habit.todayMin, habit.goalMin)} of ${habit.goalMin} min today", pad, below + 0.19f * s, 0.06f * s, look.figtree, look.ink, w - 2 * pad, caps = true)
        // The week: a dot a day, today a ring closing toward the goal.
        val slot = (w - 2 * pad) / 7f
        val r = min(slot * 0.33f, 0.045f * s)
        val y = h - pad - 0.075f * s - r
        val letters = "MTWTFSS"
        val todayIndex = (Calendar.getInstance().apply { add(Calendar.HOUR_OF_DAY, -4) }.get(Calendar.DAY_OF_WEEK) + 5) % 7
        val on = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.ink }
        val off = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = look.off }
        val lp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 0.05f * s; typeface = look.figtree; color = look.dim; textAlign = Paint.Align.CENTER }
        for (i in 0 until 7) {
            val cx = pad + slot * i + slot / 2
            val m = habit.days[i]
            if (i == 6) {
                val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = r * 0.34f; strokeCap = Paint.Cap.ROUND }
                val box = RectF(cx - r * 0.83f, y - r * 0.83f, cx + r * 0.83f, y + r * 0.83f)
                c.drawArc(box, 0f, 360f, false, stroke.apply { color = look.off })
                val sweep = 360f * min(1f, m.toFloat() / habit.goalMin)
                if (sweep > 0) c.drawArc(box, -90f, sweep, false, stroke.apply { color = look.accent })
            } else {
                c.drawCircle(cx, y, r, if (m >= habit.goalMin) on else off)
            }
            c.drawText(letters[(todayIndex - (6 - i) + 7) % 7].toString(), cx, h - pad, lp)
        }
        return bmp
    }

    override fun taps(ctx: Context, id: Int, views: RemoteViews) {
        views.setOnClickPendingIntent(R.id.widget_face, Widgets.openApp(ctx, id * 4 + 3, null, false, "stats"))
    }
}

/** The streak, wide: the number, this week, and eighteen weeks of dots. */
class StreakWidgetWide : StreakWidget() {
    override fun defaultWidthDp() = 320

    override fun render(ctx: Context, id: Int, w: Int, h: Int, u: Float): Bitmap {
        val weeks = 18
        val habit = Widgets.habit(ctx, weeks * 7)
        val current = Widgets.books(ctx).firstOrNull()
        val look = Widgets.Look(ctx, current?.tint ?: 0)
        val s = h.toFloat()
        val (bmp, c) = Widgets.face(w, h, look, 0.16f * s)
        val pad = 0.09f * s
        val number = "${habit.streak}"
        val digit = min(0.035f * s, (w * 0.4f - pad) / (number.length * 9f))
        Widgets.dots(c, number, pad, pad, digit, look.ink)
        val below = pad + 7 * digit * 1.5f
        Widgets.text(c, if (habit.streak == 1) "day streak" else "days streak", pad, below + 0.1f * s, 0.06f * s, look.figtree, look.dim, w * 0.4f, caps = true)
        val week = habit.days.takeLast(7).sum()
        Widgets.text(c, if (week < 60) "${week}m this week" else "${week / 60}h ${week % 60}m this week", pad, h - pad, 0.06f * s, look.figtree, look.ink, w * 0.4f, caps = true)
        // Eighteen weeks: columns of seven, newest on the right.
        val step = min(w * 0.55f / weeks, (h - 2 * pad) / 7f)
        val left = w - pad - step * weeks
        val top = (h - step * 7) / 2
        val dotR = step * 0.32f
        for (i in habit.days.indices) {
            val m = habit.days[i]
            val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (m == 0) look.off else look.ink
                alpha = when {
                    m == 0 -> 255
                    m < habit.goalMin -> 90
                    m < habit.goalMin * 4 -> 180
                    else -> 255
                }
            }
            c.drawCircle(left + (i / 7) * step + step / 2, top + (i % 7) * step + step / 2, dotR, p)
        }
        return bmp
    }
}
