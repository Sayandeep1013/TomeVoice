package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.Icon
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.Process
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.File
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Scanned pages read as text on the phone, for a PDF whose pages are
 * pictures (the Dart side: ocr.dart, ocr_jobs.dart).
 *
 * Each page is drawn by Android's PdfRenderer at about 300 dpi, made grey and
 * read by Tesseract (Tesseract4Android, Apache-2.0) in the languages asked
 * for, from the data the app downloaded into files/ocr/tessdata. One page at
 * a time, with one engine, on one thread at background priority: the page
 * drawn is let go before it is read, and a book read aloud meanwhile keeps
 * its voice.
 *
 * A foreground service (dataSync: a file read in on the phone), with the page
 * it is on and Stop in its notification, so a 300-page scan goes on with the
 * screen off. Each page's text is written to the job's pages/<n>.txt as soon
 * as it is read, so a stop of any kind (Stop, the app or the phone killed)
 * goes on from the first page without one. Scans asked for while one is read
 * wait their turn.
 *
 * Stop takes effect between pages, never in the middle of one: Tesseract's
 * own stop() races the progress callback it shares with the recognition (a
 * crash in native code), and a page takes seconds.
 */
class OcrService : Service() {

    /** A scan to read: see [start]. */
    private class Job(
        val dir: String,
        val pdf: String,
        val pages: IntArray,
        val languages: String,
        val dataPath: String,
        val title: String,
    )

    /** How a scan's reading ended: the event Dart is sent. */
    private class Outcome(val type: String, val message: String? = null, val data: Boolean = false)

    /** A page drawn and made grey, one byte a pixel, at [dpi] dots an inch. */
    private class Grey(val pixels: ByteArray, val width: Int, val height: Int, val dpi: Int)

    companion object {
        private const val ACTION_STOP = "app.tomevoice.action.OCR_STOP"
        private const val CHANNEL_ID = "ocr"
        private const val NOTIFICATION_ID = 8
        private const val DONE_NOTIFICATION_ID = 9
        private const val REQ_NOTIFY = 77

        /** About 300 dpi: what Tesseract reads printed text best at. */
        private const val DPI = 300f

        /**
         * No page is drawn larger than this (36 MB as it is drawn, 9 MB grey):
         * an A4 page at 300 dpi fits; a scan whose pages claim to be a metre
         * tall is drawn smaller rather than run a 3 GB phone out of memory.
         */
        private const val MAX_PIXELS = 9_000_000.0

        /** The CPU is kept awake while pages are read; renewed every page. */
        private const val AWAKE_MS = 10 * 60 * 1000L

        /** Set by the activity: hands progress and each scan's end to Dart. */
        @Volatile
        var onEvent: ((Map<String, Any?>) -> Unit)? = null

        private val lock = Any()

        // Guarded by lock.
        private val queue = ArrayList<Job>()
        private var current: Job? = null
        private var working = false

        @Volatile
        private var done = 0

        @Volatile
        private var total = 0

        @Volatile
        private var stopping = false

        @Volatile
        private var instance: OcrService? = null

        /** The notification permission is asked for once a launch at most. */
        private var askedNotify = false

        /**
         * Read the scan [args] names: "job" (its folder), "pdf", "pages" (to
         * read, 0-based), "languages" ("ben+eng"), "data" (the folder holding
         * tessdata/) and "title". Answers "started", "queued" (behind the scan
         * being read) or "already" (it is being read, or waiting).
         */
        fun start(activity: Activity, args: Map<*, *>): String {
            val job = Job(
                dir = args["job"] as? String ?: throw IllegalArgumentException("No job folder"),
                pdf = args["pdf"] as? String ?: throw IllegalArgumentException("No PDF"),
                pages = (args["pages"] as? List<*>).orEmpty().mapNotNull { (it as? Number)?.toInt() }.toIntArray(),
                languages = args["languages"] as? String ?: "eng",
                dataPath = args["data"] as? String ?: throw IllegalArgumentException("No language data"),
                title = args["title"] as? String ?: "a scan",
            )
            val answer = synchronized(lock) {
                if (current?.dir == job.dir || queue.any { it.dir == job.dir }) {
                    "already"
                } else {
                    queue.add(job)
                    if (working) {
                        "queued"
                    } else {
                        working = true
                        stopping = false
                        "started"
                    }
                }
            }
            if (answer == "started") {
                askToNotify(activity)
                try {
                    activity.startForegroundService(Intent(activity, OcrService::class.java))
                } catch (e: Exception) {
                    synchronized(lock) {
                        queue.remove(job)
                        working = false
                    }
                    throw e
                }
            }
            return answer
        }

        /** Stop after the page being read; the scans waiting are let go too. */
        fun stop() {
            if (!synchronized(lock) { working }) return
            stopping = true
            instance?.refresh()
        }

        /** The scan being read and how far it is, or null when none is. */
        fun status(): Map<String, Any?>? = synchronized(lock) {
            if (!working) {
                null
            } else {
                mapOf(
                    "job" to current?.dir,
                    "done" to done,
                    "total" to total,
                    "stopping" to stopping,
                    "queued" to queue.map { it.dir },
                )
            }
        }

        /** Without it, Android 13 and later hide the notification with the progress. */
        private fun askToNotify(activity: Activity) {
            if (Build.VERSION.SDK_INT < 33 || askedNotify) return
            if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            askedNotify = true
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
        }

        private fun send(event: Map<String, Any?>) {
            onEvent?.invoke(event)
        }
    }

    private var worker: Thread? = null
    private var wake: PowerManager.WakeLock? = null
    private var lastStart = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStart = startId
        val busy = synchronized(lock) { working }
        if (intent?.action == ACTION_STOP) {
            // From the notification's Stop.
            stopping = true
            if (busy) refresh() else finish()
            return START_NOT_STICKY
        }
        // In the foreground at once: Android ends an app that starts a
        // foreground service and does not.
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        if (!busy) {
            finish()
        } else if (worker?.isAlive != true) {
            worker = Thread({ work() }, "tomevoice-ocr").also { it.start() }
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15 gives a data-sync service six hours a day: stopped here as
     * Stop stops it, at once as Android asks. The scan goes on from its next
     * page when the app asks again.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopping = true
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        instance = null
        // Ended from outside: the page being read is the last.
        if (synchronized(lock) { working }) stopping = true
        keepAwake(false)
        super.onDestroy()
    }

    /** The scans, one after another, until none is left or Stop. */
    private fun work() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        while (true) {
            val job = synchronized(lock) {
                val next = if (stopping) null else queue.firstOrNull()
                if (next == null) {
                    queue.clear()
                    current = null
                    working = false
                } else {
                    queue.removeAt(0)
                    current = next
                }
                next
            } ?: break
            val outcome = try {
                read(job)
            } catch (e: OutOfMemoryError) {
                Outcome("ocrFailed", "The phone ran out of memory on page ${done + 1}. Close other apps and go on.")
            } catch (e: Throwable) {
                Outcome("ocrFailed", e.message ?: e.javaClass.simpleName)
            }
            if (outcome.type == "ocrDone") announce(job)
            send(
                mapOf(
                    "type" to outcome.type,
                    "job" to job.dir,
                    "done" to done,
                    "total" to total,
                    "message" to outcome.message,
                    "data" to outcome.data,
                )
            )
        }
        keepAwake(false)
        send(mapOf("type" to "ocrIdle"))
        Handler(Looper.getMainLooper()).post { finish() }
    }

    /** Out of the foreground and stopped, unless a scan came in meanwhile. */
    private fun finish() {
        if (instance !== this || synchronized(lock) { working }) return
        keepAwake(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(lastStart)
    }

    /** Read the pages of [job] that have no text file yet. */
    private fun read(job: Job): Outcome {
        val pagesDir = File(job.dir, "pages").apply { mkdirs() }
        val todo = job.pages.filter { !File(pagesDir, "$it.txt").exists() }
        total = job.pages.size
        done = total - todo.size
        progress(job)
        if (todo.isEmpty()) return Outcome("ocrDone")

        val fd = try {
            ParcelFileDescriptor.open(File(job.pdf), ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (e: Exception) {
            return Outcome("ocrFailed", "The PDF is no longer on the phone.")
        }
        val renderer = try {
            PdfRenderer(fd)
        } catch (e: Exception) {
            close(fd)
            return Outcome("ocrFailed", "Android could not open this PDF to draw its pages.")
        }
        try {
            val api = TessBaseAPI()
            try {
                val ready = try {
                    api.init(job.dataPath, job.languages)
                } catch (e: IllegalArgumentException) {
                    // No tessdata folder.
                    false
                }
                if (!ready) {
                    return Outcome(
                        "ocrFailed",
                        "The language data would not load. It is downloaded again when you go on.",
                        data = true
                    )
                }
                // The whole page, laid out as a book's is: columns, headings,
                // pictures passed over. The engine's own default is one block.
                api.setPageSegMode(TessBaseAPI.PageSegMode.PSM_AUTO)
                var grey: ByteArray? = null
                for (index in todo) {
                    if (stopping) return Outcome("ocrStopped")
                    keepAwake(true)
                    var text = ""
                    // A page Android cannot draw (damaged, or too big for
                    // the memory left even at half the size) is left without
                    // text, as one the engine cannot read: the rest of the
                    // book is still read, and Go on does not stop at it again.
                    val page = if (index >= 0 && index < renderer.pageCount) {
                        try {
                            try {
                                draw(renderer, index, MAX_PIXELS, grey)
                            } catch (e: OutOfMemoryError) {
                                // Once more, at half the width and height, the
                                // last page's grey let go first.
                                grey = null
                                draw(renderer, index, MAX_PIXELS / 4, null)
                            }
                        } catch (e: Throwable) {
                            null
                        }
                    } else {
                        null
                    }
                    if (page != null) {
                        grey = page.pixels
                        try {
                            // Raw pixels carry no resolution, and Tesseract
                            // then takes them for 70 dpi: a 300 dpi page's
                            // letters look four times their size to it. It is
                            // told what the page was drawn at.
                            api.setVariable("user_defined_dpi", page.dpi.toString())
                            api.setImage(page.pixels, page.width, page.height, 1, page.width)
                            text = api.getUTF8Text() ?: ""
                        } catch (e: Throwable) {
                            // A page the engine cannot read is left without
                            // text; the rest of the book is still read.
                            text = ""
                        } finally {
                            api.clear()
                        }
                    }
                    save(pagesDir, index, text)
                    done++
                    progress(job)
                }
                return Outcome("ocrDone")
            } finally {
                api.recycle()
            }
        } finally {
            try {
                renderer.close()
            } catch (_: Exception) {
            }
            close(fd)
        }
    }

    private fun close(fd: ParcelFileDescriptor) {
        try {
            fd.close()
        } catch (_: Exception) {
        }
    }

    /**
     * Page [index] drawn at about [DPI], no larger than [maxPixels], on white
     * and made grey. The drawn page is let go at once: only the grey one, a
     * quarter of its size, is kept while the page is read. [reuse] is the last
     * page's grey, taken again when the size is the same.
     */
    private fun draw(renderer: PdfRenderer, index: Int, maxPixels: Double, reuse: ByteArray?): Grey {
        val page = renderer.openPage(index)
        try {
            // Points, 72 to the inch.
            val pw = page.width.coerceAtLeast(1)
            val ph = page.height.coerceAtLeast(1)
            var scale = DPI / 72f
            val pixels = pw.toDouble() * ph * scale * scale
            if (pixels > maxPixels) scale *= sqrt(maxPixels / pixels).toFloat()
            val w = (pw * scale).roundToInt().coerceAtLeast(1)
            val h = (ph * scale).roundToInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = if (reuse != null && reuse.size == w * h) reuse else ByteArray(w * h)
                val row = IntArray(w)
                for (y in 0 until h) {
                    bitmap.getPixels(row, 0, w, 0, y, w, 1)
                    val at = y * w
                    for (x in 0 until w) {
                        val c = row[x]
                        val r = (c shr 16) and 0xFF
                        val g = (c shr 8) and 0xFF
                        val b = c and 0xFF
                        out[at + x] = ((r * 77 + g * 150 + b * 29) shr 8).toByte()
                    }
                }
                return Grey(out, w, h, (72f * scale).roundToInt())
            } finally {
                bitmap.recycle()
            }
        } finally {
            page.close()
        }
    }

    /** A page's text, written whole or not at all. */
    private fun save(dir: File, index: Int, text: String) {
        val tmp = File(dir, "$index.txt.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(File(dir, "$index.txt"))) {
            throw IllegalStateException("Page ${index + 1}'s text could not be saved")
        }
    }

    private fun progress(job: Job) {
        refresh()
        send(mapOf("type" to "ocrProgress", "job" to job.dir, "done" to done, "total" to total))
    }

    /**
     * Keeps the CPU awake while pages are read: with the screen off the phone
     * would otherwise sleep between them. [AWAKE_MS] is a safety for a thread
     * that died holding it; every page renews it.
     */
    private fun keepAwake(on: Boolean) {
        try {
            if (on) {
                val w = wake ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TomeVoice:ocr")
                    .also {
                        it.setReferenceCounted(false)
                        wake = it
                    }
                w.acquire(AWAKE_MS)
            } else {
                wake?.let { if (it.isHeld) it.release() }
            }
        } catch (_: Exception) {
        }
    }

    fun refresh() {
        if (instance !== this) return
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, build())
        } catch (_: Exception) {
        }
    }

    private fun builder(): Notification.Builder {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "Reading scans", NotificationManager.IMPORTANCE_LOW)
            channel.description = "How far TomeVoice is through reading a scanned book's pages."
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
        return if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
    }

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    /** The page being read, of how many, with Stop. */
    private fun build(): Notification {
        val job = synchronized(lock) { current }
        val n = total
        val text = when {
            stopping -> "Stopping after this page…"
            n > 0 -> "Page ${minOf(done + 1, n)} of $n"
            else -> "Starting…"
        }
        val builder = builder()
            .setSmallIcon(R.drawable.ic_stat_tomevoice)
            .setContentTitle(if (job == null) "Reading a scan" else "Reading “${job.title}”")
            .setContentText(text)
            .setContentIntent(openApp())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setProgress(n, done, n == 0)
        if (!stopping) {
            val stop = PendingIntent.getService(
                this,
                11,
                Intent(this, OcrService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Stop",
                    stop
                ).build()
            )
        }
        return builder.build()
    }

    /** Said when a scan is read to its end, the app open or not. */
    private fun announce(job: Job) {
        try {
            val n = builder()
                .setSmallIcon(R.drawable.ic_stat_tomevoice)
                .setContentTitle("Finished reading “${job.title}”")
                .setContentText("Open TomeVoice to listen to it.")
                .setContentIntent(openApp())
                .setAutoCancel(true)
                .build()
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(DONE_NOTIFICATION_ID, n)
        } catch (_: Exception) {
        }
    }
}
