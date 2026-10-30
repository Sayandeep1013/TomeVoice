package app.tomevoice.tomevoice_spike

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * PDF to text, on the device.
 *
 * PDFBox does the glyph work (fonts, ToUnicode maps, reading order within a
 * page). The Dart side (packages/tomevoice_document, formats/pdf.dart) does
 * the listening clean-up: running headers, page numbers, hyphenation,
 * paragraphs that cross a page break, footnotes and columns.
 *
 * Output contract: pages separated by form feed (0x0C), paragraphs within a
 * page started by U+2029, lines separated by "\n". "layout" is one IntArray
 * per page, five numbers for each line in the order the lines are written:
 * x, baseline y from the top, width (points), font size (tenths of a point)
 * and the length of the line's text, by which the Dart side checks that the
 * two agree.
 */
object PdfText {
    @Volatile
    private var initialised = false

    fun extract(ctx: Context, path: String, progress: (Int, Int) -> Unit): Map<String, Any?> {
        if (!initialised) {
            PDFBoxResourceLoader.init(ctx.applicationContext)
            initialised = true
        }
        val doc = try {
            PDDocument.load(File(path))
        } catch (e: Exception) {
            val name = e.javaClass.simpleName
            if (name.contains("Password")) {
                throw IllegalStateException("This PDF is password-protected.")
            }
            throw IllegalStateException("Could not open this PDF: ${e.message}")
        }
        doc.use { d ->
            val total = d.numberOfPages
            val stripper = LineStripper { page -> progress(page, total) }
            stripper.paragraphStart = 0x2029.toChar().toString()
            stripper.lineSeparator = "\n"
            stripper.pageStart = ""
            stripper.pageEnd = 0x0C.toChar().toString()
            val text = stripper.getText(d)

            val info = d.documentInformation
            return mapOf(
                "text" to text,
                "pages" to total,
                "title" to info?.title,
                "author" to info?.author,
                "outline" to outline(d),
                "layout" to stripper.layout
            )
        }
    }

    /**
     * What [extract] gives for the PDF at [path], written to [out] as JSON:
     * the map formats/pdf.dart reads, as the corpus's recorded extractions
     * keep it (packages/tomevoice_document/test/corpus/SOURCES.md), so that
     * a book that reads wrong on a phone can be looked at, and tested, off
     * it. Written whole or not at all. A development tool (MainActivity's
     * dumpPdf launch argument); nothing in the app uses it.
     */
    fun dump(ctx: Context, path: String, out: File) {
        val pdf = extract(ctx, path) { _, _ -> }
        val json = JSONObject()
        json.put("_note", "Extracted on a phone by PdfText.extract (PDFBox), for looking at off it.")
        for ((key, value) in pdf) json.put(key, jsonOf(value))
        val part = File(out.parentFile, out.name + ".part")
        part.writeText(json.toString(), Charsets.UTF_8)
        if (!part.renameTo(out)) {
            out.delete()
            if (!part.renameTo(out)) throw IllegalStateException("Could not write ${out.name}")
        }
    }

    /** [value] as org.json holds it: maps, lists and int arrays all the way down. */
    private fun jsonOf(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is IntArray -> JSONArray().also { a -> for (v in value) a.put(v) }
        is Map<*, *> -> JSONObject().also { o -> for ((k, v) in value) o.put(k.toString(), jsonOf(v)) }
        is List<*> -> JSONArray().also { a -> for (v in value) a.put(jsonOf(v)) }
        else -> value
    }

    /**
     * Every bookmark, three levels deep, in document order: its title, page
     * (-1 when it points nowhere) and depth ("level", 0 at the top). The Dart
     * side (pdfOutlineFromPlatform) makes the chapter list: Parts keep their
     * chapters, a lone top bookmark is unwrapped.
     */
    private fun outline(doc: PDDocument): List<Map<String, Any>> {
        val root = try {
            doc.documentCatalog?.documentOutline
        } catch (e: Exception) {
            null
        } ?: return emptyList()

        val out = mutableListOf<Map<String, Any>>()
        var guard = 0
        fun walk(first: PDOutlineItem?, level: Int) {
            var item = first
            while (item != null && guard < 5000) {
                guard++
                val title = try {
                    item.title
                } catch (_: Exception) {
                    null
                }
                if (!title.isNullOrBlank()) {
                    val index = try {
                        val page = item.findDestinationPage(doc)
                        if (page != null) doc.pages.indexOf(page) else -1
                    } catch (_: Exception) {
                        -1
                    }
                    out.add(mapOf("title" to title.trim(), "page" to index, "level" to level))
                }
                if (level < 2) {
                    val child = try {
                        item.firstChild
                    } catch (_: Exception) {
                        null
                    }
                    walk(child, level + 1)
                }
                item = item.nextSibling
            }
        }
        walk(root.firstChild, 0)
        return out
    }
}

/**
 * PDFBox's stripper, noting where each line it writes sits. A line ends at
 * whichever separator the stripper writes next (line, paragraph or page), so
 * the notes follow the text line for line.
 */
private class LineStripper(private val onPage: (Int) -> Unit) : PDFTextStripper() {
    /** Per page: x, y, width, size x10 and text length for each line. */
    val layout = ArrayList<IntArray>()

    private val pageLines = ArrayList<Int>()
    private val sizes = HashMap<Int, Int>()
    private var lineLength = 0
    private var glyphs = 0
    private var minX = 0f
    private var maxX = 0f
    private var maxY = 0f

    override fun startPage(page: PDPage?) {
        super.startPage(page)
        pageLines.clear()
        resetLine()
        onPage(currentPageNo)
    }

    override fun endPage(page: PDPage?) {
        endLine()
        layout.add(pageLines.toIntArray())
        super.endPage(page)
    }

    override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
        // A glyph that maps to a separator would add a line the notes do not
        // have (and a form feed a page).
        val raw = text ?: ""
        val clean = if (raw.any { isSeparator(it) }) {
            raw.map { if (isSeparator(it)) ' ' else it }.joinToString("")
        } else {
            raw
        }
        super.writeString(clean, textPositions)
        lineLength += clean.length
        textPositions?.forEach { p ->
            val x = p.getXDirAdj()
            val end = x + p.getWidthDirAdj()
            val y = p.getYDirAdj()
            if (glyphs == 0) {
                minX = x
                maxX = end
                maxY = y
            } else {
                minX = minOf(minX, x)
                maxX = maxOf(maxX, end)
                maxY = maxOf(maxY, y)
            }
            glyphs++
            // Math.round, unlike roundToInt, takes NaN (a broken matrix) as 0.
            val size = Math.round(p.getYScale() * 10)
            sizes[size] = (sizes[size] ?: 0) + 1
        }
    }

    override fun writeWordSeparator() {
        super.writeWordSeparator()
        lineLength += wordSeparator.length
    }

    override fun writeLineSeparator() {
        endLine()
        super.writeLineSeparator()
    }

    override fun writeParagraphStart() {
        endLine()
        super.writeParagraphStart()
    }

    override fun writeParagraphEnd() {
        endLine()
        super.writeParagraphEnd()
    }

    override fun writePageEnd() {
        endLine()
        super.writePageEnd()
    }

    private fun isSeparator(c: Char) =
        c.code == 0x0A || c.code == 0x0D || c.code == 0x0C || c.code == 0x2029

    private fun endLine() {
        if (lineLength > 0) {
            // The size most of its glyphs are set in: a superscript note mark
            // does not make a line of text small.
            var size = 0
            var most = 0
            for ((s, n) in sizes) {
                if (n > most) {
                    most = n
                    size = s
                }
            }
            if (glyphs > 0) {
                pageLines.add(Math.round(minX))
                pageLines.add(Math.round(maxY))
                pageLines.add(Math.round(maxX - minX))
            } else {
                pageLines.add(0)
                pageLines.add(0)
                pageLines.add(0)
            }
            pageLines.add(size)
            pageLines.add(lineLength)
        }
        resetLine()
    }

    private fun resetLine() {
        lineLength = 0
        glyphs = 0
        sizes.clear()
    }
}
