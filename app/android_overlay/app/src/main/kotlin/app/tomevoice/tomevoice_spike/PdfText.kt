package app.tomevoice.tomevoice_spike

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File

/**
 * PDF to text, on the device.
 *
 * PDFBox does the glyph work (fonts, ToUnicode maps, reading order within a
 * page). The Dart side (packages/tomevoice_document, formats/pdf.dart) does
 * the listening clean-up: running headers, page numbers, hyphenation and
 * paragraphs that cross a page break.
 *
 * Output contract: pages separated by form feed (0x0C), paragraphs within a
 * page started by U+2029, lines separated by "\n".
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
            val stripper = object : PDFTextStripper() {
                override fun startPage(page: PDPage?) {
                    super.startPage(page)
                    progress(currentPageNo, total)
                }
            }
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
                "outline" to outline(d)
            )
        }
    }

    /** Top-level bookmarks, or the second level when there is a single root. */
    private fun outline(doc: PDDocument): List<Map<String, Any>> {
        val root = try {
            doc.documentCatalog?.documentOutline
        } catch (e: Exception) {
            null
        } ?: return emptyList()

        fun level(first: PDOutlineItem?): List<Map<String, Any>> {
            val out = mutableListOf<Map<String, Any>>()
            var item = first
            var guard = 0
            while (item != null && guard < 5000) {
                guard++
                try {
                    val page = item.findDestinationPage(doc)
                    val title = item.title
                    if (page != null && !title.isNullOrBlank()) {
                        val index = doc.pages.indexOf(page)
                        if (index >= 0) out.add(mapOf("title" to title.trim(), "page" to index))
                    }
                } catch (_: Exception) {
                }
                item = item.nextSibling
            }
            return out
        }

        val top = level(root.firstChild)
        if (top.size >= 2) return top
        val nested = root.firstChild?.firstChild
        return if (nested != null) level(nested) else top
    }
}
