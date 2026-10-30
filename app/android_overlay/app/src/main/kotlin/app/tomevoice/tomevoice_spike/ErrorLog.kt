package app.tomevoice.tomevoice_spike

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Android's side of the app's error log (error_log.dart). A crash on this
 * side, on any thread, is added to the same file in the app's private
 * storage before Android's own handler ends the app, so "Report a problem"
 * in About can show it next time. Nothing is ever sent: the reader sees the
 * report and sends it, or not, themselves.
 *
 * As on the Dart side, nothing from a book is written: the error's kind and
 * first line only, with anything quoted, every link and every file path
 * taken out, and where in the code it happened. The Dart side takes the
 * books' titles out as well when it reads the file (they are not known
 * here). Never in a backup (LibraryBackup.skip).
 */
object ErrorLog {

    /** The file, in filesDir: one entry a line, newest last. */
    const val FILE = "errors.jsonl"

    /** The most kept, as on the Dart side: one more pushes out the oldest. */
    private const val KEEP = 50

    /** Frames of a stack kept: where it happened, not the whole way there. */
    private const val FRAMES = 12

    /** The longest a message is kept. */
    private const val LONGEST = 240

    @Volatile
    private var installed = false

    // As error_log.dart has them, but stricter with quotes: everything in
    // them goes.
    private val link = Regex("""\b[A-Za-z][A-Za-z0-9+.\-]*://\S+""")
    private val quoted = Regex("""“[^”\n]*”|"[^"\n]*"|(?<!\w)'[^'\n]*'(?!\w)|‘[^’\n]*’|«[^»\n]*»|„[^“”\n]*[“”]""")
    private val path = Regex("""(?<![\w:/.~\-])/[^/\s]*/[^\n]*?(?=: |\s\(|, |['"“”‘’)]|$)""")
    private val space = Regex("""\s+""")

    /**
     * Log what nothing else caught, then hand it on as before: to Android's
     * own handler, which ends the app. Once, as the process starts
     * (ShareProvider.onCreate, which Android runs before an activity, a
     * widget, a service or a background check).
     */
    fun install(context: Context) {
        if (installed) return
        installed = true
        val app = context.applicationContext ?: context
        val file = File(app.filesDir, FILE)
        val version = versionOf(app)
        val before = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                write(file, version, error)
            } catch (_: Throwable) {
                // The log must never stand between a crash and Android.
            }
            before?.uncaughtException(thread, error)
        }
    }

    @Suppress("DEPRECATION")
    private fun versionOf(app: Context): String =
        try {
            app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: ""
        } catch (e: Exception) {
            ""
        }

    /** [error] as one line at the end of [file], the oldest dropped past [KEEP]. */
    private fun write(file: File, version: String, error: Throwable) {
        val entry = JSONObject()
            .put("time", now())
            .put("version", version)
            .put("from", "android")
            .put("message", scrub(describe(error)))
            .put("stack", stack(error))
            .toString()
        // A file grown past any sane size (it never should) starts afresh.
        val kept = if (file.isFile && file.length() < (1L shl 20)) {
            file.readLines().filter { it.isNotBlank() }.takeLast(KEEP - 1)
        } else {
            emptyList()
        }
        val tmp = File(file.path + ".tmp")
        tmp.writeText((kept + entry).joinToString("\n", postfix = "\n"))
        if (!tmp.renameTo(file)) tmp.delete()
    }

    /** Now, as UTC, as the Dart side writes it. */
    private fun now(): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date())
    }

    /** "java.lang.IllegalStateException: its first line". */
    private fun describe(error: Throwable): String {
        val first = error.message?.lineSequence()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() }
        return if (first == null) error.javaClass.name else "${error.javaClass.name}: $first"
    }

    /** Where it happened, and where what set it off at the root did. */
    private fun stack(error: Throwable): String {
        val lines = error.stackTrace.take(FRAMES).map { "at $it" }.toMutableList()
        val cause = generateSequence(error.cause) { it.cause }.take(8).lastOrNull()
        if (cause != null && cause !== error) {
            lines.add("Caused by: " + scrub(describe(cause)))
            lines.addAll(cause.stackTrace.take(4).map { "at $it" })
        }
        return lines.joinToString("\n")
    }

    /** [text]'s first line, with links, anything quoted and file paths taken out. */
    fun scrub(text: String): String {
        var line = text.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: ""
        line = link.replace(line, "<link>")
        line = quoted.replace(line, "\"…\"")
        line = path.replace(line, "<file>")
        line = space.replace(line, " ").trim()
        return if (line.length <= LONGEST) line else line.substring(0, LONGEST - 1) + "…"
    }
}
