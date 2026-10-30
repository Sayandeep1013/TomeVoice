package app.tomevoice.tomevoice_spike

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * The whole library as one zip, and back.
 *
 * Streamed both ways: a library can be gigabytes of books and downloaded
 * chapters, so nothing is held in memory and progress is reported as it goes.
 * The Dart side decides what to do with a restored copy (replace or add); this
 * only writes the zip and unpacks one into a staging folder.
 */
object LibraryBackup {

    const val MANIFEST = "manifest.json"

    /** Far beyond any real library; a zip that unpacks to more is refused. */
    private const val MAX_BYTES = 16L shl 30
    private const val MAX_FILES = 500_000

    /** What is never backed up: imports in flight, caches, site cookies. */
    private fun skip(rel: String, includeChapters: Boolean): Boolean {
        val top = rel.substringBefore('/')
        if (top.startsWith(".")) return true // .restore, .before-restore
        if (top == "incoming") return true
        if (rel.endsWith(".tmp")) return true
        if (rel == "sources/cookies.json") return true
        // The update check's state names the APK to install: never carried.
        if (rel == "app_update.json") return true
        // The error log is this phone's own (ErrorLog.kt). It is kept in the
        // app's private storage, which is the library's folder too only on a
        // phone with no storage outside the app.
        if (rel == ErrorLog.FILE) return true
        // A cached copy of a source list; fetched again when needed.
        if (rel.startsWith("sources/index-")) return true
        // Natural voices are a download away (64 to 110 MB each). Carried,
        // every voice made every backup that much bigger (docs/11: never).
        if (top == "voices") return true
        // So is the OCR language data (Ocr.kt), and a scan still being read
        // is this phone's: its text is backed up with its book once made.
        if (top == "ocr") return true
        if (!includeChapters && rel.startsWith("books/") && rel.split('/').getOrNull(2) == "ch") return true
        return false
    }

    private fun files(root: File, includeChapters: Boolean, sources: File?): List<Pair<File, String>> {
        val out = mutableListOf<Pair<File, String>>()
        val base = root.absolutePath.trimEnd('/') + "/"
        root.walkTopDown().forEach { f ->
            if (!f.isFile) return@forEach
            val rel = f.absolutePath.removePrefix(base)
            if (!skip(rel, includeChapters)) out.add(f to rel)
        }
        // Web novels' sources moved to internal storage (SourceStore.open), out
        // of the library's folder: their lists, what is installed and each
        // source's own settings still travel, as sources/ (a restore adopts
        // them and installs the sources again from their lists). Never the
        // plugins' code, the site cookies or a cached list.
        val taken = out.map { it.second }.toSet()
        sources?.listFiles()?.forEach { f ->
            val name = f.name
            val carried = name == "repos.json" || name == "installed.json" ||
                (name.startsWith("storage-") && name.endsWith(".json"))
            val rel = "sources/$name"
            if (f.isFile && carried && rel !in taken) out.add(f to rel)
        }
        return out
    }

    /** Bytes a backup of [root] (and [sources]) would hold before compression. */
    fun size(root: File, includeChapters: Boolean, sources: File? = null): Long =
        files(root, includeChapters, sources).sumOf { it.first.length() }

    /**
     * Zip [root] into [out], [manifest] first, with what of [sources] (the
     * web novels' sources, in internal storage) is carried. [progress] gets
     * bytes done and the total. Returns the number of files written.
     */
    fun write(
        root: File,
        out: OutputStream,
        manifest: String,
        includeChapters: Boolean,
        sources: File? = null,
        progress: (Long, Long) -> Unit,
    ): Int {
        val list = files(root, includeChapters, sources)
        val total = list.sumOf { it.first.length() }
        var done = 0L
        var lastReport = 0L
        ZipOutputStream(out.buffered(1 shl 16)).use { zip ->
            zip.putNextEntry(ZipEntry(MANIFEST))
            zip.write(manifest.toByteArray(Charsets.UTF_8))
            zip.closeEntry()
            val buf = ByteArray(1 shl 16)
            for ((file, rel) in list) {
                zip.putNextEntry(ZipEntry(rel).apply { time = file.lastModified() })
                file.inputStream().use { input ->
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        zip.write(buf, 0, n)
                        done += n
                        if (done - lastReport > (1 shl 20)) {
                            lastReport = done
                            progress(done, total)
                        }
                    }
                }
                zip.closeEntry()
            }
        }
        progress(total, total)
        return list.size
    }

    /**
     * Unpack a backup from [input] into [staging] (emptied first). Returns the
     * manifest's text, or throws if the zip is not a TomeVoice backup.
     */
    fun read(input: InputStream, staging: File, progress: (Long) -> Unit): String {
        staging.deleteRecursively()
        staging.mkdirs()
        val base = staging.canonicalPath + File.separator
        var manifest: String? = null
        var done = 0L
        var lastReport = 0L
        var files = 0
        ZipInputStream(input.buffered(1 shl 16)).use { zip ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory) continue
                // A crafted zip must not fill the phone.
                if (++files > MAX_FILES) throw IllegalStateException("That backup has too many files")
                if (entry.name == MANIFEST) {
                    manifest = zip.readBytes().toString(Charsets.UTF_8)
                    continue
                }
                // Older backups carried the natural voices: left out, so a
                // restore keeps the phone's own (and no megabytes are spent).
                // No backup carries OCR data, and one that did is not trusted.
                // Nor another phone's error log.
                val top = entry.name.substringBefore('/')
                if (top == "voices" || top == "ocr" || entry.name == ErrorLog.FILE) continue
                val dest = File(staging, entry.name)
                // A name like "../../x" must not write outside the staging folder.
                if (!dest.canonicalPath.startsWith(base)) {
                    throw IllegalStateException("That backup has a file outside its folder")
                }
                dest.parentFile?.mkdirs()
                FileOutputStream(dest).use { o ->
                    while (true) {
                        val n = zip.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        if (done > MAX_BYTES) throw IllegalStateException("That backup is too large to restore")
                        if (done - lastReport > (1 shl 20)) {
                            lastReport = done
                            progress(done)
                        }
                    }
                }
                if (entry.time > 0) dest.setLastModified(entry.time)
            }
        }
        return manifest ?: run {
            staging.deleteRecursively()
            throw IllegalStateException("That file is not a TomeVoice backup")
        }
    }
}
