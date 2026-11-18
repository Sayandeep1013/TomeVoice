package app.tomevoice.tomevoice_spike

import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The ways the app ended that ErrorLog.kt's handler never hears: a crash in
 * native code (Flutter's engine aborting, as on 11 November 2026, when a
 * web-novel worker's answer came after the worker had gone), and Android
 * ending it for not responding. Android keeps a record of how each run
 * ended (API 30+); the app asks for those since it last asked, once, as it
 * opens its error log (error_log.dart's openErrorLog), and adds them there.
 *
 * As ErrorLog.kt: nothing from a book. The abort message's first line,
 * scrubbed, and where in the code the crashing thread was.
 */
object PastExits {

    /** When the last run asked: exits before it were seen (or are older than the log). */
    const val SEEN = "errors.exits"

    /** Frames of a native stack kept. */
    private const val FRAMES = 12

    @Synchronized
    fun since(context: Context): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        return try {
            read(context.applicationContext ?: context)
        } catch (e: Throwable) {
            emptyList()
        }
    }

    @TargetApi(30)
    private fun read(app: Context): List<Map<String, Any>> {
        val am = app.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val exits = am.getHistoricalProcessExitReasons(app.packageName, 0, 16)
        val marker = File(app.filesDir, SEEN)
        val seen = try {
            marker.readText().trim().toLong()
        } catch (e: Exception) {
            null
        }
        val newest = exits.maxOfOrNull { it.timestamp } ?: System.currentTimeMillis()
        if (seen == null || newest > seen) {
            try {
                marker.writeText(newest.toString())
            } catch (_: Exception) {
            }
        }
        // The first time, no run before this one asked: what is there is
        // from before the log knew to ask, of a version it cannot name.
        if (seen == null) return emptyList()
        val version = versionOf(app)
        return exits
            .filter { it.timestamp > seen }
            .sortedBy { it.timestamp }
            .mapNotNull { entry(it, version) }
    }

    @TargetApi(30)
    private fun entry(info: ApplicationExitInfo, version: String): Map<String, Any>? {
        val (message, stack) = when (info.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> {
                val t = try {
                    info.traceInputStream?.use { Tombstone.read(it) }
                } catch (e: Throwable) {
                    null
                }
                val said = t?.abort?.takeIf { it.isNotBlank() }
                    ?: "signal ${info.status}"
                ("Native crash: " + ErrorLog.scrub(said)) to (t?.frames?.take(FRAMES)?.joinToString("\n") ?: "")
            }
            ApplicationExitInfo.REASON_ANR -> {
                val said = info.description?.takeIf { it.isNotBlank() } ?: "no reason given"
                val stack = try {
                    info.traceInputStream?.use { anrMain(it) } ?: ""
                } catch (e: Throwable) {
                    ""
                }
                ("Not responding (ANR): " + ErrorLog.scrub(said)) to stack
            }
            else -> return null
        }
        return mapOf(
            "time" to iso(info.timestamp),
            "version" to version,
            "from" to "android",
            "message" to message,
            "stack" to stack,
        )
    }

    /** The main thread's frames in an ANR's text trace. */
    private fun anrMain(input: InputStream): String {
        val lines = input.bufferedReader().readLines()
        val start = lines.indexOfFirst { it.startsWith("\"main\"") }
        if (start < 0) return ""
        return lines.drop(start + 1)
            .takeWhile { it.isNotBlank() }
            .map { it.trim() }
            .filter { it.startsWith("at ") || it.startsWith("native: ") }
            .take(FRAMES)
            .joinToString("\n") { line ->
                // Native frames name a file by its path: its name alone.
                line.replace(Regex("""/\S*/([^/\s]+)"""), "$1")
            }
    }

    private fun iso(millis: Long): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date(millis))
    }

    @Suppress("DEPRECATION")
    private fun versionOf(app: Context): String =
        try {
            app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: ""
        } catch (e: Exception) {
            ""
        }
}

/**
 * The little of Android's tombstone (tombstone.proto) the log keeps: the
 * abort message, and the crashing thread's frames by name. Read by hand: a
 * protobuf library for two fields is not worth its weight.
 */
internal class Tombstone private constructor(val abort: String?, val frames: List<String>) {
    companion object {
        // Tombstone: tid = 6, abort_message = 14, threads = 16 (map<uint32, Thread>).
        // Thread: id = 1, current_backtrace = 4. BacktraceFrame: function_name = 4, file_name = 6.

        fun read(input: InputStream): Tombstone {
            val bytes = input.readBytes()
            var tid = -1L
            var abort: String? = null
            val threads = HashMap<Long, ByteArray>()
            fields(bytes) { field, value, data ->
                when (field) {
                    6 -> tid = value
                    14 -> abort = data?.toString(Charsets.UTF_8)
                    16 -> if (data != null) {
                        var key = -1L
                        var thread: ByteArray? = null
                        fields(data) { f, v, d ->
                            if (f == 1) key = v
                            if (f == 2) thread = d
                        }
                        thread?.let { threads[key] = it }
                    }
                }
            }
            val thread = threads[tid] ?: threads.values.firstOrNull()
            val frames = ArrayList<String>()
            if (thread != null) {
                fields(thread) { f, _, d ->
                    if (f == 4 && d != null) {
                        var name = ""
                        var file = ""
                        fields(d) { ff, _, dd ->
                            if (ff == 4 && dd != null) name = dd.toString(Charsets.UTF_8)
                            if (ff == 6 && dd != null) file = dd.toString(Charsets.UTF_8).substringAfterLast('/')
                        }
                        frames.add(if (name.isEmpty()) "at ($file)" else "at $name ($file)")
                    }
                }
            }
            return Tombstone(abort, frames)
        }

        /**
         * Each field of the message in [b]: its number, its value (a varint;
         * 0 otherwise) and its bytes (length-delimited; null otherwise).
         */
        private fun fields(b: ByteArray, each: (Int, Long, ByteArray?) -> Unit) {
            var i = 0
            fun varint(): Long {
                var shift = 0
                var out = 0L
                while (i < b.size) {
                    val c = b[i++].toInt() and 0xff
                    out = out or ((c and 0x7f).toLong() shl shift)
                    if (c and 0x80 == 0) return out
                    shift += 7
                    if (shift > 63) break
                }
                return out
            }
            while (i < b.size) {
                val key = varint()
                val field = (key ushr 3).toInt()
                when ((key and 7).toInt()) {
                    0 -> each(field, varint(), null)
                    1 -> i += 8
                    2 -> {
                        val n = varint().toInt()
                        if (n < 0 || i + n > b.size) return
                        each(field, 0, b.copyOfRange(i, i + n))
                        i += n
                    }
                    5 -> i += 4
                    else -> return
                }
            }
        }
    }
}
