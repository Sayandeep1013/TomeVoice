package app.tomevoice.tomevoice_spike

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * PDF pages as pictures, for the page view: the book exactly as it was laid
 * out, images and all, while the voice reads the extracted text.
 *
 * Uses the platform PdfRenderer, so no library and no extra APK size. One
 * document is kept open at a time; PdfRenderer is not thread-safe, so every
 * call is synchronized and the activity runs them on one worker thread.
 */
object PdfPages {
    private var openPath: String? = null
    private var fd: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

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

    /** Render [index] at [width] pixels wide; returns a cached JPEG's path. */
    @Synchronized
    fun render(path: String, index: Int, width: Int, cacheDir: File): String {
        val dir = File(cacheDir, "pages").apply { mkdirs() }
        val w = width.coerceIn(200, 2400)
        val key = Integer.toHexString(path.hashCode()) + "-" + index + "-" + w + ".jpg"
        val out = File(dir, key)
        if (out.exists() && out.length() > 0) return out.absolutePath

        val r = open(path)
        val page = r.openPage(index)
        try {
            val h = (page.height.toLong() * w / page.width.coerceAtLeast(1)).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
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

    /** Drop rendered pages nobody has looked at for a week. */
    fun sweep(cacheDir: File) {
        val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
        File(cacheDir, "pages").listFiles()?.forEach {
            if (it.lastModified() < cutoff || it.name.endsWith(".tmp")) it.delete()
        }
    }
}
