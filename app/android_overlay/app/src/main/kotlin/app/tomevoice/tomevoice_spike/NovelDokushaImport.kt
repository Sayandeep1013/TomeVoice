package app.tomevoice.tomevoice_spike

import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.zip.ZipFile

/**
 * Reads a NovelDokusha backup: a zip with its Room database at
 * "database.sqlite3" (tables Book, Chapter, ChapterBody). Writes the web
 * novels in its library, their chapters and any downloaded chapter text to a
 * file of JSON lines for the Dart side to import, and returns that file's
 * path: a header ({"v":2,"books":n}), then for each book its details and
 * chapter list ({"book":...}) followed by each downloaded chapter's text on
 * a line of its own ({"body":{"i":place,"text":...}}). Nothing holds the
 * whole library in memory, here or in Dart: one book's list, one chapter's
 * text at a time.
 *
 * Its local books (EPUBs imported into it, "local://") come too: their text
 * is in the backup, and the files they came from may be gone.
 */
object NovelDokushaImport {
    /** Far beyond any real library: a database that unpacks to more is refused. */
    private const val MAX_DATABASE = 2L shl 30

    /** Room left on the phone after unpacking. */
    private const val SPARE = 256L shl 20

    fun read(zipPath: String, cache: File): String {
        val db = File(cache, "noveldokusha_import.sqlite3")
        // A crafted zip must not fill the phone.
        val limit = minOf(MAX_DATABASE, cache.usableSpace - SPARE)
        ZipFile(zipPath).use { zip ->
            val entry = zip.getEntry("database.sqlite3")
                ?: throw IllegalArgumentException("This is not a NovelDokusha backup: there is no database inside.")
            if (limit <= 0) throw IllegalStateException("There is not enough room on the phone to read that backup.")
            zip.getInputStream(entry).use { input ->
                db.outputStream().use { output ->
                    val buf = ByteArray(1 shl 16)
                    var total = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > limit) throw IllegalStateException("That backup is too large to read on this phone.")
                        output.write(buf, 0, n)
                    }
                }
            }
        }
        val out = File(cache, "noveldokusha_import.jsonl")
        try {
            SQLiteDatabase.openDatabase(db.path, null, SQLiteDatabase.OPEN_READONLY).use { d ->
                out.bufferedWriter().use { w ->
                    fun line(o: JSONObject) {
                        w.write(o.toString())
                        w.newLine()
                    }
                    line(JSONObject().put("v", 2).put("books", DatabaseUtils.queryNumEntries(d, "Book", "inLibrary = 1")))
                    d.rawQuery(
                        "SELECT title, url, completed, lastReadChapter, coverImageUrl, description " +
                            "FROM Book WHERE inLibrary = 1",
                        null,
                    ).use { c ->
                        while (c.moveToNext()) {
                            val url = c.getString(1) ?: continue
                            if (!url.startsWith("http") && !url.startsWith("local://")) continue
                            val chapters = JSONArray()
                            val places = HashMap<String, Int>()
                            d.rawQuery(
                                "SELECT title, url, read FROM Chapter WHERE bookUrl = ? ORDER BY position",
                                arrayOf(url),
                            ).use { ch ->
                                while (ch.moveToNext()) {
                                    val chapterUrl = ch.getString(1) ?: ""
                                    if (!places.containsKey(chapterUrl)) places[chapterUrl] = chapters.length()
                                    chapters.put(
                                        JSONObject()
                                            .put("title", ch.getString(0) ?: "")
                                            .put("url", chapterUrl)
                                            .put("read", ch.getInt(2) != 0),
                                    )
                                }
                            }
                            line(
                                JSONObject().put(
                                    "book",
                                    JSONObject()
                                        .put("title", c.getString(0) ?: "")
                                        .put("url", url)
                                        .put("completed", c.getInt(2) != 0)
                                        .put("lastReadChapter", if (c.isNull(3)) JSONObject.NULL else c.getString(3))
                                        .put("cover", c.getString(4) ?: "")
                                        .put("description", c.getString(5) ?: "")
                                        .put("chapters", chapters),
                                ),
                            )
                            d.rawQuery(
                                "SELECT c.url, b.body FROM Chapter c JOIN ChapterBody b ON b.url = c.url " +
                                    "WHERE c.bookUrl = ? ORDER BY c.position",
                                arrayOf(url),
                            ).use { b ->
                                while (b.moveToNext()) {
                                    if (b.isNull(1)) continue
                                    val place = places[b.getString(0) ?: continue] ?: continue
                                    line(JSONObject().put("body", JSONObject().put("i", place).put("text", b.getString(1))))
                                }
                            }
                        }
                    }
                }
            }
        } finally {
            db.delete()
        }
        return out.path
    }
}
