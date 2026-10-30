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
