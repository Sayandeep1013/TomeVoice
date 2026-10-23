package app.tomevoice.tomevoice_spike

import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipFile

/**
 * Reads a NovelDokusha backup: a zip with its Room database at
 * "database.sqlite3" (tables Book, Chapter, ChapterBody). Writes the web
 * novels in its library, their chapters and any downloaded chapter text to a
 * JSON file for the Dart side to import, and returns that file's path.
 *
 * Local books (EPUBs it imported) are left out: TomeVoice opens those files
 * directly.
 */
object NovelDokushaImport {
    fun read(zipPath: String, cache: File): String {
        val db = File(cache, "noveldokusha_import.sqlite3")
        ZipFile(zipPath).use { zip ->
            val entry = zip.getEntry("database.sqlite3")
                ?: throw IllegalArgumentException("This is not a NovelDokusha backup: there is no database inside.")
            zip.getInputStream(entry).use { input -> db.outputStream().use { input.copyTo(it) } }
        }
        val out = File(cache, "noveldokusha_import.json")
        try {
            SQLiteDatabase.openDatabase(db.path, null, SQLiteDatabase.OPEN_READONLY).use { d ->
                val books = JSONArray()
                d.rawQuery(
                    "SELECT title, url, completed, lastReadChapter, coverImageUrl, description " +
                        "FROM Book WHERE inLibrary = 1",
                    null,
                ).use { c ->
                    while (c.moveToNext()) {
                        val url = c.getString(1) ?: continue
                        if (!url.startsWith("http")) continue
                        val book = JSONObject()
                            .put("title", c.getString(0) ?: "")
                            .put("url", url)
                            .put("completed", c.getInt(2) != 0)
                            .put("lastReadChapter", if (c.isNull(3)) JSONObject.NULL else c.getString(3))
                            .put("cover", c.getString(4) ?: "")
                            .put("description", c.getString(5) ?: "")
                        val chapters = JSONArray()
                        d.rawQuery(
                            "SELECT c.title, c.url, c.read, b.body FROM Chapter c " +
                                "LEFT JOIN ChapterBody b ON b.url = c.url " +
                                "WHERE c.bookUrl = ? ORDER BY c.position",
                            arrayOf(url),
                        ).use { ch ->
                            while (ch.moveToNext()) {
                                chapters.put(
                                    JSONObject()
                                        .put("title", ch.getString(0) ?: "")
                                        .put("url", ch.getString(1) ?: "")
                                        .put("read", ch.getInt(2) != 0)
                                        .put("body", if (ch.isNull(3)) JSONObject.NULL else ch.getString(3)),
                                )
                            }
                        }
                        books.put(book.put("chapters", chapters))
                    }
                }
                out.writeText(JSONObject().put("books", books).toString())
            }
        } finally {
            db.delete()
        }
        return out.path
    }
}
