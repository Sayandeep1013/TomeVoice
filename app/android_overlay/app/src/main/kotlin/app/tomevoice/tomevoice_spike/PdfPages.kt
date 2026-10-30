package app.tomevoice.tomevoice_spike

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * PDF pages as pictures, for the page view: the book exactly as it was laid
 * out, images and all, while the voice reads the extracted text.
 *
 * Uses the platform PdfRenderer, so no library and no extra APK size. One
 * document is kept open at a time; PdfRenderer is not thread-safe, so every
 * call is synchronized and the activity runs them on one worker thread.
 *
 * For Crop margins (page_crop.dart), a page is also drawn small to find
 * where its print lies ([prints]), and drawn cut to a part of it ([render]).
 */
object PdfPages {
    private var openPath: String? = null
    private var fd: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

    /** Where the print lies on the pages of [printsOf] looked at so far (null: blank). */
    private val prints = HashMap<Int, FloatArray?>()
    private var printsOf: String? = null

    /** About how many pixels a page is drawn in to find its print: A4 at 532 by 752. */
    private const val LOOK = 400_000.0

    /** The tallest a cut page is drawn, in pixels; a taller one is drawn narrower. */
    private const val TALLEST = 4096

    /** The edge of a page the paper is found on, of its shorter side. */
    private const val BAND = 0.04

    /** How deep in from an edge a shadow along it may reach, of the shorter side. */
    private const val SHADOW = 0.06

    /** More colourful than the paper by this much: a mark, not a shadow. */
    private const val TINT = 40

    @Synchronized
    private fun open(path: String): PdfRenderer {
        val current = renderer
        if (current != null && openPath == path) return current
        close()
        val f = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        val r = try {
            PdfRenderer(f)
        } catch (e: Exception) {
            f.close()
            throw e
        }
        fd = f
        renderer = r
        openPath = path
        return r
    }

    @Synchronized
    fun close() {
        try {
            renderer?.close()
        } catch (_: Exception) {
        }
        try {
            fd?.close()
        } catch (_: Exception) {
        }
        renderer = null
        fd = null
        openPath = null
        prints.clear()
        printsOf = null
    }

    /** Page count and every page's size in points, flattened [w0, h0, w1, h1...]. */
    @Synchronized
    fun info(path: String): Map<String, Any> {
        val r = open(path)
        val sizes = ArrayList<Int>(r.pageCount * 2)
        for (i in 0 until r.pageCount) {
            val page = r.openPage(i)
            try {
                sizes.add(page.width)
                sizes.add(page.height)
            } finally {
                page.close()
            }
        }
        return mapOf("pages" to r.pageCount, "sizes" to sizes)
    }

    /**
     * Render [index] at [width] pixels wide, the whole page or only [crop]
     * of it (left, top, right and bottom, in fractions of the page) drawn at
     * that width, so its print is as sharp as a whole page's (narrower only
     * if it would be taller than [TALLEST]); returns a cached JPEG's path.
     */
    @Synchronized
    fun render(path: String, index: Int, width: Int, cacheDir: File, crop: FloatArray? = null): String {
        val dir = File(cacheDir, "pages").apply { mkdirs() }
        val w = width.coerceIn(200, 2400)
        // The part within the page, as asked; one that is not a part (not
        // a number, or a sliver) is not cut.
        val part = crop?.takeIf { c -> c.size == 4 && c.none { it.isNaN() } }
            ?.let { c -> FloatArray(4) { k -> c[k].coerceIn(0f, 1f) } }
            ?.takeIf { it[2] - it[0] >= 0.05f && it[3] - it[1] >= 0.05f }
        val cut = part?.joinToString("_", prefix = "-c") { v -> (v * 10000).roundToInt().toString() } ?: ""
        val key = Integer.toHexString(path.hashCode()) + "-" + index + "-" + w + cut + ".jpg"
        val out = File(dir, key)
        if (out.exists() && out.length() > 0) return out.absolutePath

        val r = open(path)
        val page = r.openPage(index)
        try {
            val pw = page.width.coerceAtLeast(1)
            var bw = w
            val h: Int
            var transform: Matrix? = null
            if (part == null) {
                h = (page.height.toLong() * w / pw).toInt().coerceAtLeast(1)
            } else {
                // The part's corner at the bitmap's, its width across it. A
                // tall part is drawn narrower, so it is never more than
                // TALLEST high; it shows in its own shape all the same.
                val cw = (part[2] - part[0]) * pw
                val ch = (part[3] - part[1]) * page.height.coerceAtLeast(1)
                bw = min(w, (TALLEST * cw / ch).toInt()).coerceAtLeast(1)
                val scale = bw / cw
                h = (ch * scale).roundToInt().coerceIn(1, TALLEST)
                transform = Matrix().apply {
                    setTranslate(-part[0] * pw, -part[1] * page.height)
                    postScale(scale, scale)
                }
            }
            val bitmap = Bitmap.createBitmap(bw, h, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, transform, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val tmp = File(dir, "$key.tmp")
                tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                tmp.renameTo(out)
            } finally {
                bitmap.recycle()
            }
        } finally {
            page.close()
        }
        return out.absolutePath
    }

    /**
     * Where the print lies on each of [indices], in fractions of the page
     * (left, top, right, bottom), or null on a blank page. Each page is
     * drawn small once to find it (see [findPrint]); what is found is kept
     * beside the rendered pages, so a book's pages are looked at once. A
     * page that cannot be drawn is all print, so it is never cut.
     */
    @Synchronized
    fun prints(path: String, indices: List<Int>, cacheDir: File): List<List<Double>?> {
        val r = open(path)
        val dir = File(cacheDir, "pages").apply { mkdirs() }
        val file = File(dir, Integer.toHexString(path.hashCode()) + "-print1.txt")
        if (printsOf != path) {
            prints.clear()
            printsOf = path
            readPrints(file)
        }
        val found = StringBuilder()
        val out = ArrayList<List<Double>?>(indices.size)
        try {
            for (index in indices) {
                if (!prints.containsKey(index)) {
                    val box = try {
                        look(r, index).also { b ->
                            found.append(index).append(' ').append(b?.joinToString(" ") ?: "-").append('\n')
                        }
                    } catch (_: Exception) {
                        floatArrayOf(0f, 0f, 1f, 1f)
                    }
                    prints[index] = box
                }
                out.add(prints[index]?.map { it.toDouble() })
            }
        } finally {
            // What was found is kept, even when a page after it could not be.
            if (found.isNotEmpty()) {
                try {
                    file.appendText(found.toString())
                } catch (_: Exception) {
                    // Looked at again next time.
                }
            }
        }
        return out
    }

    /**
     * What [prints] found before: "index left top right bottom" a line,
     * "index -" for a blank page. Read, it is kept from the week's [sweep]
     * as the book is.
     */
    private fun readPrints(file: File) {
        if (!file.exists()) return
        try {
            file.setLastModified(System.currentTimeMillis())
            file.forEachLine { line ->
                val parts = line.trim().split(' ')
                val index = parts[0].toIntOrNull() ?: return@forEachLine
                if (parts.size == 2 && parts[1] == "-") {
                    prints[index] = null
                } else if (parts.size == 5) {
                    val box = FloatArray(4)
                    for (k in 0 until 4) box[k] = parts[k + 1].toFloatOrNull() ?: return@forEachLine
                    prints[index] = box
                }
            }
        } catch (_: Exception) {
            // Found again as the pages are looked at.
        }
    }

    /** Page [index] drawn small, and where its print lies on it in fractions of the page. */
    private fun look(r: PdfRenderer, index: Int): FloatArray? {
        val page = r.openPage(index)
        try {
            val pw = page.width.coerceAtLeast(1)
            val ph = page.height.coerceAtLeast(1)
            val s = sqrt(LOOK / (pw.toDouble() * ph))
            val w = (pw * s).roundToInt().coerceIn(8, 2000)
            val h = (ph * s).roundToInt().coerceIn(8, 2000)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val pixels = IntArray(w * h)
                bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
                val box = findPrint(pixels, w, h) ?: return null
                return floatArrayOf(
                    box[0].toFloat() / w,
                    box[1].toFloat() / h,
                    box[2].toFloat() / w,
                    box[3].toFloat() / h
                )
            } finally {
                bitmap.recycle()
            }
        } finally {
            page.close()
        }
    }

    /**
     * Where the print lies on a page drawn [w] by [h] ([px]: its ARGB
     * pixels, a row at a time): left, top, right and bottom in pixels (right
     * and bottom just past it), or null on a blank page.
     *
     * The paper is the colour most of the page's edge has, and ink is what
     * differs from it by more than the paper's own grain. A speck (a mark no
     * bigger than a cell either way) is not print. Nor is a shadow: a thin
     * band in the paper's own colours, only darker, lying along an edge for a
     * quarter of it or more (a scanner's shadow, the dark past a scanned
     * page's edge); a line of print that only grazes an edge is still print.
     * A page whose edge is mostly not paper (a picture to its edges) is print
     * all over.
     *
     * Pure, and the same step for step as findPrint in page_crop.dart, whose
     * tests cover it: change both.
     */
    fun findPrint(px: IntArray, w: Int, h: Int): IntArray? {
        val whole = intArrayOf(0, 0, w, h)
        if (w < 8 || h < 8 || px.size < w * h) return whole

        // The paper: each channel's middle value around the page's edge.
        val band = max(1, (min(w, h) * BAND).roundToInt())
        val reds = IntArray(256)
        val greens = IntArray(256)
        val blues = IntArray(256)
        var edge = 0
        alongEdge(px, w, h, band) { c ->
            reds[(c shr 16) and 0xFF]++
            greens[(c shr 8) and 0xFF]++
            blues[c and 0xFF]++
            edge++
        }
        val pr = middle(reds, edge)
        val pg = middle(greens, edge)
        val pb = middle(blues, edge)
        fun off(c: Int): Int = max(
            abs(((c shr 16) and 0xFF) - pr),
            max(abs(((c shr 8) and 0xFF) - pg), abs((c and 0xFF) - pb))
        )

        // Its grain: how far the edge strays from it, at the middle. Ink is
        // what strays further than a little more than that.
        val strays = IntArray(256)
        alongEdge(px, w, h, band) { c -> strays[off(c)]++ }
        val ink = (24 + 2 * middle(strays, edge)).coerceIn(24, 48)
        var paper = 0
        for (v in 0 until ink) paper += strays[v]
        if (paper * 2 < edge) return whole

        // Ink counted in cells two pixels square, as the page is drawn to be
        // looked at; a mark is the cells it inks, with two pixels of ink at
        // least (one is grain). A small page number spans two cells or more.
        val cell = max(1, (min(w, h) / 250.0).roundToInt())
        val gw = (w + cell - 1) / cell
        val gh = (h + cell - 1) / cell
        val inks = IntArray(gw * gh)
        val tinted = BooleanArray(gw * gh)
        val paperTint = max(pr, max(pg, pb)) - min(pr, min(pg, pb))
        for (y in 0 until h) {
            val row = y * w
            val cells = (y / cell) * gw
            for (x in 0 until w) {
                val c = px[row + x]
                if (off(c) < ink) continue
                val i = cells + x / cell
                inks[i]++
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                if (max(r, max(g, b)) - min(r, min(g, b)) - paperTint > TINT) tinted[i] = true
            }
        }
        val least = if (cell > 1) 2 else 1

        // Each mark in turn (cells touching, corners too), and the box around
        // those that are print.
        val seen = BooleanArray(gw * gh)
        val stack = IntArray(gw * gh)
        val deep = max(1, ceil(min(gw, gh) * SHADOW).toInt())
        var left = gw
        var top = gh
        var right = -1
        var bottom = -1
        for (start in 0 until gw * gh) {
            if (inks[start] < least || seen[start]) continue
            seen[start] = true
            stack[0] = start
            var sp = 1
            var x0 = gw
            var y0 = gh
            var x1 = -1
            var y1 = -1
            var far = 0
            var onEdge = 0
            var coloured = false
            while (sp > 0) {
                val i = stack[--sp]
                val x = i % gw
                val y = i / gw
                if (x < x0) x0 = x
                if (x > x1) x1 = x
                if (y < y0) y0 = y
                if (y > y1) y1 = y
                val depth = min(min(x, y), min(gw - 1 - x, gh - 1 - y))
                if (depth == 0) onEdge++
                if (depth > far) far = depth
                if (tinted[i]) coloured = true
                for (ny in max(0, y - 1)..min(gh - 1, y + 1)) {
                    for (nx in max(0, x - 1)..min(gw - 1, x + 1)) {
                        val n = ny * gw + nx
                        if (inks[n] >= least && !seen[n]) {
                            seen[n] = true
                            stack[sp++] = n
                        }
                    }
                }
            }
            val spanX = x1 - x0 + 1
            val spanY = y1 - y0 + 1
            if (spanX == 1 && spanY == 1) continue
            val long = spanX * 4 >= gw || spanY * 4 >= gh
            val hugs = onEdge * 2 >= max(spanX, spanY)
            if (long && hugs && far <= deep && !coloured) continue
            if (x0 < left) left = x0
            if (y0 < top) top = y0
            if (x1 > right) right = x1
            if (y1 > bottom) bottom = y1
        }
        if (right < 0) return null
        return intArrayOf(left * cell, top * cell, min(w, (right + 1) * cell), min(h, (bottom + 1) * cell))
    }

    /** Each pixel of the page's edge, [band] deep, to [pixel]. */
    private inline fun alongEdge(px: IntArray, w: Int, h: Int, band: Int, pixel: (Int) -> Unit) {
        for (y in 0 until h) {
            val row = y * w
            if (y < band || y >= h - band) {
                for (x in 0 until w) pixel(px[row + x])
            } else {
                for (x in 0 until band) {
                    pixel(px[row + x])
                    pixel(px[row + w - 1 - x])
                }
            }
        }
    }

    /** The middle value of [n] counted in [counts] (by value). */
    private fun middle(counts: IntArray, n: Int): Int {
        var seen = 0
        for (v in counts.indices) {
            seen += counts[v]
            if (seen * 2 >= n) return v
        }
        return counts.size - 1
    }

    /**
     * Drop rendered pages nobody has looked at for a week, and pages left
     * half written. A .tmp a minute old was never finished; a newer one is a
     * page being written now (the sweep runs as the app starts, maybe into a
     * book's pages), and its page would be lost.
     */
    fun sweep(cacheDir: File) {
        val now = System.currentTimeMillis()
        val cutoff = now - 7L * 24 * 60 * 60 * 1000
        File(cacheDir, "pages").listFiles()?.forEach {
            val left = it.name.endsWith(".tmp") && it.lastModified() < now - 60_000
            if (it.lastModified() < cutoff || left) it.delete()
        }
    }
}
