package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import de.sciss.jump3r.mp3.BitStream
import de.sciss.jump3r.mp3.GainAnalysis
import de.sciss.jump3r.mp3.ID3Tag
import de.sciss.jump3r.mp3.Lame
import de.sciss.jump3r.mp3.LameGlobalFlags
import de.sciss.jump3r.mp3.MPEGMode
import de.sciss.jump3r.mp3.Presets
import de.sciss.jump3r.mp3.Quantize
import de.sciss.jump3r.mp3.QuantizePVT
import de.sciss.jump3r.mp3.Reservoir
import de.sciss.jump3r.mp3.Takehiro
import de.sciss.jump3r.mp3.VBRTag
import de.sciss.jump3r.mp3.Version
import de.sciss.jump3r.mpg.Common
import de.sciss.jump3r.mpg.Interface
import de.sciss.jump3r.mpg.MPGLib
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Saving a book as audio, the platform's half (export_audio.dart is the
 * other): PCM16 from Dart, a sentence at a time, encoded to AAC-LC in an MP4
 * ([AacWriter]) or to MP3 ([Mp3Writer]) in the app's own storage; then the
 * file, with its chapter marks and tags written in by Dart, copied to
 * Audiobooks (MediaStore) or to where the reader chose (Android's save
 * dialog).
 *
 * The engine's, not an activity's: ReadingCore makes one with the engine,
 * on its messenger and the application, and closes it with the engine. A
 * save goes on when TomeVoice is swiped away from Recents (the engine stays
 * while one is [busy], see ReadingCore.saving), its notification's Cancel
 * still reaches Dart, and the next activity takes it up ([attach]). Only
 * the save dialog and the notification permission need an activity.
 *
 * Each write is answered only once the encoder has taken it, and Dart keeps
 * no more than two unanswered: the PCM of a whole book never waits in
 * memory. Encoding runs on its own thread; answers go back on the main one.
 *
 * Nothing half made is left anywhere: a save that stops deletes its file
 * and the document it was to fill, and one the app did not live to finish
 * is swept away the next time it starts (sweep).
 */
class AudioExport(private val app: Context, messenger: BinaryMessenger) {

    companion object {
        /**
         * Their own numbers: 77 was MainActivity's folder picker's too, and
         * this took that picker's answer (the folder for automatic backups
         * and quotes was never set).
         */
        const val REQ_PICK = 7311
        private const val REQ_NOTIFY = 7312

        /** Below this much free space the save stops, before the phone is full. */
        private const val MIN_FREE = 30L * 1024 * 1024

        /** Free space is looked at again after this much audio is taken. */
        private const val CHECK_EVERY = 4L * 1024 * 1024
    }

    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "tomevoice/export")
    private val work: ExecutorService = Executors.newSingleThreadExecutor()

    /** The activity showing the app, while there is one (see [attach]). */
    private var activity: Activity? = null

    /**
     * A save is under way: from Dart's "start" (or "begin") until "done" or
     * "abort". The engine stays for it with no activity (ReadingCore.saving).
     */
    @Volatile
    var busy = false
        private set

    @Volatile
    private var writer: AudioWriter? = null

    /** The file being made, or made and not yet copied where it goes. */
    @Volatile
    private var temp: File? = null
    private var sinceCheck = 0L
    private var pickReply: MethodChannel.Result? = null

    /** The activity the open save dialog was started from. */
    private var pickFrom: Activity? = null
    private var askedNotify = false

    private val cancelHook: () -> Unit = { main.post { event("cancel") } }
    private val timeoutHook: () -> Unit = { main.post { event("timeout") } }

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        AudioExportService.onCancel = cancelHook
        AudioExportService.onTimeout = timeoutHook
        work.execute { sweep() }
    }

    /** [a] shows the app now: the save dialog and the permission prompt are its. */
    fun attach(a: Activity) {
        activity = a
    }

    /**
     * [a] is going. A save goes on without it. A save dialog it had open is
     * answered through the activity that comes next (Android gives it the
     * result), or, if that answer never comes, when another is opened.
     */
    fun detach(a: Activity) {
        if (activity === a) activity = null
    }

    private fun dir(): File = File(app.noBackupFilesDir, "export").apply { mkdirs() }

    /** The saves to Audiobooks or a chosen document under way: see [sweep]. */
    private fun pendingFile(): File = File(app.noBackupFilesDir, "export-pending")

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "space" -> work.execute {
                val free = try {
                    StatFs(dir().path).availableBytes
                } catch (e: Exception) {
                    -1L
                }
                main.post { result.success(free) }
            }
            "audiobooksFolder" -> result.success(Build.VERSION.SDK_INT >= 29)
            "start", "progress" -> {
                if (call.method == "start") {
                    busy = true
                    askForNotifications()
                }
                try {
                    AudioExportService.show(
                        app,
                        call.argument<String>("title") ?: "Saving as audio",
                        call.argument<String>("text").orEmpty(),
                        call.argument<Int>("percent") ?: -1,
                    )
                    result.success(null)
                } catch (e: Exception) {
                    // Android would not start it (from the background): the
                    // save goes on while TomeVoice is open.
                    result.error("SERVICE", e.message ?: "The save could not run in the background", null)
                }
            }
            "begin" -> {
                val rate = call.argument<Int>("sampleRate") ?: 24000
                val bitRate = call.argument<Int>("bitRate") ?: 64000
                val mp3 = call.argument<String>("format") == "mp3"
                val room = call.argument<Int>("room") ?: 0
                busy = true
                work.execute {
                    try {
                        writer?.release()
                        temp?.delete()
                        val file = File(dir(), "save-${System.currentTimeMillis()}.${if (mp3) "mp3" else "m4a"}")
                        temp = file
                        writer = if (mp3) Mp3Writer(file, rate, bitRate, room) else AacWriter(file, rate, bitRate)
                        sinceCheck = 0
                        main.post { result.success(file.absolutePath) }
                    } catch (e: Throwable) {
                        // Throwable: an encoder's Error (out of memory, a class
                        // missing) fails the save, not the app with it.
                        writer = null
                        val what = if (mp3) "MP3" else "AAC"
                        main.post { result.error("ENCODER", e.message ?: "This phone could not make $what audio", null) }
                    }
                }
            }
            "write" -> {
                val pcm = call.argument<ByteArray>("pcm")
                work.execute {
                    val w = writer
                    try {
                        if (w == null || pcm == null) throw IllegalStateException("Nothing is being saved")
                        sinceCheck += pcm.size
                        if (sinceCheck >= CHECK_EVERY) {
                            sinceCheck = 0
                            if (StatFs(dir().path).availableBytes < MIN_FREE) {
                                main.post { result.error("SPACE", "The phone is out of space", null) }
                                return@execute
                            }
                        }
                        w.write(pcm)
                        main.post { result.success(null) }
                    } catch (e: Throwable) {
                        main.post { result.error("ENCODER", e.message ?: "The audio could not be encoded", null) }
                    }
                }
            }
            "finish" -> work.execute {
                val w = writer
                val file = temp
                writer = null
                if (w == null || file == null) {
                    main.post { result.error("ENCODER", "Nothing is being saved", null) }
                    return@execute
                }
                try {
                    val ms = w.finish()
                    main.post {
                        result.success(mapOf("path" to file.absolutePath, "bytes" to file.length(), "durationMs" to ms))
                    }
                } catch (e: Throwable) {
                    w.release()
                    main.post { result.error("ENCODER", e.message ?: "The audio could not be finished", null) }
                }
            }
            "abort" -> {
                val title = call.argument<String>("title") ?: "Not saved"
                val notice = call.argument<String>("notice")
                work.execute {
                    writer?.release()
                    writer = null
                    temp?.delete()
                    temp = null
                    main.post {
                        AudioExportService.end(app)
                        if (notice != null) AudioExportService.notice(app, title, notice, null, null)
                        ended()
                        result.success(null)
                    }
                }
            }
            "pick" -> pick(call.argument<String>("name") ?: "Audiobook.m4b", result)
            "discard" -> {
                val uri = call.argument<String>("uri")
                work.execute {
                    if (uri != null) deleteDocument(Uri.parse(uri))
                    forget()
                    main.post { result.success(null) }
                }
            }
            "publish" -> {
                val path = call.argument<String>("path").orEmpty()
                val name = call.argument<String>("name") ?: File(path).name
                val folder = call.argument<String>("folder") ?: "TomeVoice"
                val target = call.argument<String>("uri")
                work.execute {
                    try {
                        val out = publish(File(path), name, folder, target)
                        temp = null
                        main.post { result.success(out) }
                    } catch (e: Exception) {
                        val full = e is java.io.IOException && (e.message ?: "").contains("ENOSPC")
                        main.post {
                            result.error(if (full) "SPACE" else "PUBLISH", e.message ?: "The file could not be saved there", null)
                        }
                    }
                }
            }
            "done" -> {
                AudioExportService.end(app)
                val uri = call.argument<String>("uri")
                AudioExportService.notice(
                    app,
                    call.argument<String>("title") ?: "Saved as audio",
                    call.argument<String>("text").orEmpty(),
                    uri?.let { Uri.parse(it) },
                    call.argument<String>("mime"),
                )
                ended()
                result.success(null)
            }
            "share" -> {
                try {
                    val uri = Uri.parse(call.argument<String>("uri").orEmpty())
                    val chooser = Intent.createChooser(
                        AudioExportService.sendIntent(uri, call.argument<String>("mime")),
                        null,
                    ).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    val a = activity
                    if (a != null) {
                        a.startActivity(chooser)
                    } else {
                        app.startActivity(chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SHARE", e.message ?: "Could not share", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun event(type: String) {
        channel.invokeMethod("exportEvent", mapOf("type" to type))
    }

    /**
     * The save is over. With no activity the engine need not stay for it:
     * it goes in a moment unless something else holds it (ReadingCore.idle).
     */
    private fun ended() {
        busy = false
        if (activity == null) ReadingCore.idle()
    }

    /** Asked once: without it the progress shows only in the app. */
    private fun askForNotifications() {
        val a = activity ?: return
        if (Build.VERSION.SDK_INT < 33 || askedNotify) return
        if (a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        askedNotify = true
        a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
    }

    // ------------------------------------------------------------ where to

    /** The type Android gives [name]'s extension, so the name keeps it. */
    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val known = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        return if (known != null && known.startsWith("audio/")) known else "audio/mp4"
    }

    private fun pick(name: String, result: MethodChannel.Result) {
        val a = activity
        if (a == null) {
            result.error("PICK", "Open TomeVoice to choose where it goes", null)
            return
        }
        val open = pickReply
        if (open != null) {
            if (pickFrom === a) {
                result.error("BUSY", "A save dialog is already open", null)
                return
            }
            // Opened from an activity gone since, whose answer never came.
            open.success(null)
        }
        pickReply = result
        pickFrom = a
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeOf(name)
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            @Suppress("DEPRECATION")
            a.startActivityForResult(intent, REQ_PICK)
        } catch (e: Exception) {
            pickReply = null
            pickFrom = null
            result.error("PICK", e.message ?: "This phone has no save dialog", null)
        }
    }

    /** The save dialog closed: the document made for the file, or nothing. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK) return false
        val reply = pickReply ?: return true
        pickReply = null
        pickFrom = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return true
        }
        try {
            // Kept past a restart, so an empty document left by a save the
            // app did not finish can still be deleted.
            app.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: Exception) {
        }
        work.execute { remember(uri, -1) }
        reply.success(uri.toString())
        return true
    }

    /**
     * [file] copied to the document [target], or else into Audiobooks/[folder]
     * through MediaStore (not visible to other apps until it is whole), then
     * deleted. The address of the copy and where it is, to show.
     */
    private fun publish(file: File, name: String, folder: String, target: String?): Map<String, Any?> {
        if (!file.isFile) throw IllegalStateException("The audio is missing")
        val resolver = app.contentResolver
        if (target != null) {
            val uri = Uri.parse(target)
            remember(uri, file.length())
            val out = resolver.openOutputStream(uri, "wt")
                ?: throw IllegalStateException("Android would not open that file for writing")
            out.use { o -> file.inputStream().use { it.copyTo(o, 1 shl 16) } }
            forget()
            file.delete()
            return mapOf("uri" to uri.toString(), "where" to (displayName(uri) ?: name))
        }
        if (Build.VERSION.SDK_INT < 29) throw IllegalStateException("Choose where to save it")
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_AUDIOBOOKS + "/" + folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Android would not make the file in Audiobooks")
        remember(uri, file.length())
        try {
            val out = resolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("Android would not open the file in Audiobooks")
            out.use { o -> file.inputStream().use { it.copyTo(o, 1 shl 16) } }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            forget()
            throw e
        }
        forget()
        file.delete()
        // Android may have named it apart from one already there ("Emma (1).m4b").
        val shown = displayName(uri) ?: name
        return mapOf("uri" to uri.toString(), "where" to Environment.DIRECTORY_AUDIOBOOKS + "/" + folder + "/" + shown)
    }

    private fun displayName(uri: Uri): String? = try {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun sizeOf(uri: Uri): Long = try {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L
        } ?: -1L
    } catch (e: Exception) {
        -1L
    }

    private fun deleteDocument(uri: Uri) {
        try {
            if (uri.authority == MediaStore.AUTHORITY) {
                app.contentResolver.delete(uri, null, null)
            } else {
                DocumentsContract.deleteDocument(app.contentResolver, uri)
            }
        } catch (_: Exception) {
        }
    }

    /** A document being filled, and the size it will have (-1: not yet). */
    private fun remember(uri: Uri, bytes: Long) {
        try {
            pendingFile().writeText("$uri\t$bytes")
        } catch (_: Exception) {
        }
    }

    private fun forget() {
        pendingFile().delete()
    }

    /**
     * The app ended in the middle of a save: its file, and the document it
     * was copied into unless the copy was finished (its size says so), go.
     */
    private fun sweep() {
        dir().listFiles()?.forEach { if (it !== temp) it.delete() }
        val record = pendingFile()
        if (!record.isFile) return
        try {
            val parts = record.readText().trim().split('\t')
            val uri = Uri.parse(parts[0])
            val expected = parts.getOrNull(1)?.toLongOrNull() ?: -1L
            if (expected < 0 || sizeOf(uri) != expected) deleteDocument(uri)
        } catch (_: Exception) {
        }
        record.delete()
    }

    /** The engine is going: so is its Dart side, and any save with it. */
    fun close() {
        if (AudioExportService.onCancel === cancelHook) AudioExportService.onCancel = null
        if (AudioExportService.onTimeout === timeoutHook) AudioExportService.onTimeout = null
        channel.setMethodCallHandler(null)
        val w = writer
        val file = temp
        writer = null
        temp = null
        pickReply = null
        pickFrom = null
        activity = null
        if (busy || w != null || file != null) AudioExportService.end(app)
        busy = false
        work.execute {
            w?.release()
            file?.delete()
        }
        work.shutdown()
    }
}

/** An encoder writing a save's file, used from one thread. */
interface AudioWriter {
    /** [pcm] (16-bit little-endian samples, mono) into the encoder, and what it has made into the file. */
    fun write(pcm: ByteArray)

    /** The end: everything encoded and the file closed. Its length in ms. */
    fun finish(): Long

    /** Everything let go; the file is left as it is (the caller deletes it). */
    fun release()
}

/**
 * PCM16 mono in, AAC-LC in an MP4 out: MediaCodec encodes, MediaMuxer
 * writes the file. Used from one thread.
 */
class AacWriter(file: File, private val sampleRate: Int, bitRate: Int) : AudioWriter {

    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val muxer: MediaMuxer
    private val info = MediaCodec.BufferInfo()
    private var track = -1
    private var started = false
    private var framesIn = 0L
    private var lastPts = 0L

    init {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 32 * 1024)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        } catch (e: Exception) {
            codec.release()
            throw e
        }
        muxer = try {
            MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (e: Exception) {
            codec.stop()
            codec.release()
            throw e
        }
    }

    private fun ptsOf(frames: Long): Long = frames * 1_000_000L / sampleRate

    override fun write(pcm: ByteArray) {
        val size = pcm.size and 1.inv()
        var off = 0
        while (off < size) {
            val index = codec.dequeueInputBuffer(10_000)
            if (index < 0) {
                drain(false)
                continue
            }
            val buf = codec.getInputBuffer(index) ?: throw IllegalStateException("The encoder gave no buffer")
            buf.clear()
            val n = minOf(buf.remaining(), size - off) and 1.inv()
            if (n <= 0) throw IllegalStateException("The encoder's buffer is too small")
            buf.put(pcm, off, n)
            codec.queueInputBuffer(index, 0, n, ptsOf(framesIn), 0)
            framesIn += n / 2
            off += n
            drain(false)
        }
    }

    /** Everything encoded and the file closed (moov written). Its length in ms. */
    override fun finish(): Long {
        val deadline = System.nanoTime() + 10_000_000_000L
        while (true) {
            val index = codec.dequeueInputBuffer(10_000)
            if (index >= 0) {
                codec.queueInputBuffer(index, 0, 0, ptsOf(framesIn), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                break
            }
            drain(false)
            if (System.nanoTime() > deadline) throw IllegalStateException("The encoder did not finish")
        }
        drain(true)
        if (!started) throw IllegalStateException("The encoder made no audio")
        muxer.stop()
        release()
        return framesIn * 1000L / sampleRate
    }

    /** What the encoder has ready, into the file; at [end], until it says it is done. */
    private fun drain(end: Boolean) {
        val deadline = System.nanoTime() + 10_000_000_000L
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (end) 10_000L else 0L)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!end) return
                if (System.nanoTime() > deadline) throw IllegalStateException("The encoder stopped answering")
            } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (started) throw IllegalStateException("The encoder changed its format")
                track = muxer.addTrack(codec.outputFormat)
                muxer.start()
                started = true
            } else if (index >= 0) {
                val out = codec.getOutputBuffer(index)
                val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                if (out != null && info.size > 0 && !config && started) {
                    out.position(info.offset)
                    out.limit(info.offset + info.size)
                    // The muxer refuses time going backwards.
                    if (info.presentationTimeUs < lastPts) info.presentationTimeUs = lastPts
                    muxer.writeSampleData(track, out, info)
                    lastPts = info.presentationTimeUs
                }
                codec.releaseOutputBuffer(index, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
            }
            // INFO_OUTPUT_BUFFERS_CHANGED (older phones) needs nothing with getOutputBuffer.
        }
    }

    override fun release() {
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        try {
            codec.release()
        } catch (_: Exception) {
        }
        try {
            muxer.release()
        } catch (_: Exception) {
        }
    }
}

/**
 * PCM16 mono in, MP3 out: LAME 3.98.4 as jump3r ports it to Java (LGPL 2.1
 * or later; no native code), at a constant [bitRate] and the voice's own
 * rate, nothing resampled. Used from one thread.
 *
 * The file starts with [room] bytes left for the ID3v2.3 tag Dart writes once
 * the chapters' times are known (mp3_chapters.dart): until then an empty
 * tag, all padding, that players skip. The first frame after it is LAME's
 * Info frame, filled in at the end with the frame count, the length and the
 * encoder's delay and padding, for the players that read it.
 *
 * jump3r's own wrapper (LameEncoder) takes javax.sound's AudioFormat, which
 * Android has not, so the encoder's parts are put together here as that
 * wrapper puts them together; and its putVbrTag looks for an ID3 tag the
 * wrong way round, so the Info frame is written here (getLameTagFrame).
 */
class Mp3Writer(file: File, private val sampleRate: Int, bitRate: Int, room: Int) : AudioWriter {

    private val lame = Lame()
    private val vbr = VBRTag()

    init {
        val ga = GainAnalysis()
        val bs = BitStream()
        val presets = Presets()
        val qupvt = QuantizePVT()
        val qu = Quantize()
        val version = Version()
        val id3 = ID3Tag()
        val rv = Reservoir()
        val tak = Takehiro()
        val mpg = MPGLib()
        val intf = Interface()
        val common = Common()
        lame.setModules(ga, bs, presets, qupvt, qu, vbr, version, id3, mpg)
        bs.setModules(ga, mpg, version, vbr)
        id3.setModules(bs, version)
        presets.setModules(lame)
        qu.setModules(bs, rv, qupvt, tak)
        qupvt.setModules(tak, rv, lame.enc.psy)
        rv.setModules(bs)
        tak.setModules(qupvt)
        vbr.setModules(lame, bs, version)
        mpg.setModules(intf, common)
        intf.setModules(vbr, common)
    }

    private val flags: LameGlobalFlags = lame.lame_init() ?: throw IllegalStateException("The MP3 encoder would not start")

    /** Where the audio starts: after the room for the tag. */
    private val start: Long = if (room >= 10) room.toLong() else 0L

    private val out: RandomAccessFile
    private var samples = IntArray(0)
    private var mp3 = ByteArray(0)
    private var framesIn = 0L

    init {
        flags.num_channels = 1
        flags.in_samplerate = sampleRate
        flags.out_samplerate = sampleRate
        flags.mode = MPEGMode.MONO
        flags.brate = bitRate / 1000
        // LAME's -q 5: its usual speed and quality (2 is slower, 7 rougher).
        flags.quality = 5
        // The Info frame, which LAME writes for a constant bit rate too.
        flags.bWriteVbrTag = true
        // No ID3 tag from LAME, v1 or v2: the tag is Dart's. (Left on, it
        // would be written from a tag spec never set up: id3tag_init.)
        flags.write_id3tag_automatic = false
        flags.findReplayGain = false
        val ok = lame.lame_init_params(flags)
        if (ok < 0) {
            throw IllegalArgumentException("MP3 cannot be made at $sampleRate Hz and ${bitRate / 1000} kbps ($ok)")
        }
        out = RandomAccessFile(file, "rw")
        try {
            out.setLength(0)
            if (start > 0) out.write(emptyTag(start.toInt()))
        } catch (e: Exception) {
            try {
                out.close()
            } catch (_: Exception) {
            }
            throw e
        }
    }

    override fun write(pcm: ByteArray) {
        val n = pcm.size / 2
        if (n == 0) return
        if (samples.size < n) samples = IntArray(n)
        // LAME's whole-number input is 32-bit: each 16-bit sample in its top half.
        for (i in 0 until n) {
            val lo = pcm[2 * i].toInt() and 0xFF
            val hi = pcm[2 * i + 1].toInt()
            samples[i] = ((hi shl 8) or lo) shl 16
        }
        // LAME's own worst case: 1.25 bytes a sample and 7200 more.
        val need = n + n / 4 + 7200
        if (mp3.size < need) mp3 = ByteArray(need)
        // Mono: the right channel is not read.
        val made = lame.lame_encode_buffer_int(flags, samples, samples, n, mp3, 0, mp3.size)
        if (made < 0) throw IllegalStateException("The MP3 encoder failed ($made)")
        out.write(mp3, 0, made)
        framesIn += n
    }

    override fun finish(): Long {
        val tail = ByteArray(maxOf(mp3.size, 16 * 1024))
        val made = lame.lame_encode_flush(flags, tail, 0, tail.size)
        if (made < 0) throw IllegalStateException("The MP3 encoder could not finish ($made)")
        out.write(tail, 0, made)
        // The Info frame LAME put first, filled in now the length is known.
        val info = ByteArray(VBRTag.MAXFRAMESIZE)
        val size = vbr.getLameTagFrame(flags, info)
        if (size in 1..info.size) {
            out.seek(start)
            out.write(info, 0, size)
        }
        out.close()
        lame.lame_close(flags)
        return framesIn * 1000L / sampleRate
    }

    override fun release() {
        try {
            out.close()
        } catch (_: Exception) {
        }
        try {
            lame.lame_close(flags)
        } catch (_: Exception) {
        }
    }

    /** An ID3v2.3 tag of [size] bytes holding nothing yet: its header, then padding. */
    private fun emptyTag(size: Int): ByteArray {
        val tag = ByteArray(size)
        tag[0] = 0x49
        tag[1] = 0x44
        tag[2] = 0x33
        tag[3] = 3
        val n = size - 10
        tag[6] = ((n shr 21) and 0x7F).toByte()
        tag[7] = ((n shr 14) and 0x7F).toByte()
        tag[8] = ((n shr 7) and 0x7F).toByte()
        tag[9] = (n and 0x7F).toByte()
        return tag
    }
}

/**
 * Keeps TomeVoice alive while a book is saved as audio, so it goes on with
 * the screen off and with no activity (swiped away from Recents): a dataSync
 * foreground service (the reading one is mediaPlayback and belongs to
 * reading aloud). It does no work itself; Dart makes the speech and the
 * encoder thread writes it. Its notification shows how far the save is,
 * with Cancel, and opens the app onto the save's progress. Android 15 and
 * later give a service of this kind six hours a day: then it is stopped,
 * and the save waits for the app to be opened (onTimeout).
 */
class AudioExportService : Service() {

    companion object {
        const val ACTION_CANCEL = "app.tomevoice.action.EXPORT_CANCEL"
        private const val CHANNEL_ID = "export"

        /** Their own: 8 and 9 were OCR's as well, and a scan read during a save took its notification. */
        private const val NOTIFICATION_ID = 7304
        private const val NOTICE_ID = 7305

        /** The wake lock lets go after this unless renewed by progress. */
        private const val AWAKE_MS = 10 * 60 * 1000L

        /** Set by AudioExport: the notification's Cancel. */
        @Volatile
        var onCancel: (() -> Unit)? = null

        /** Set by AudioExport: Android stopped the service (Android 15's limit). */
        @Volatile
        var onTimeout: (() -> Unit)? = null

        @Volatile
        private var instance: AudioExportService? = null
        private var title = "Saving as audio"
        private var text = ""
        private var percent = -1

        /** Start the service, or show [text] and [percent] (-1: not known) on its notification. */
        fun show(ctx: Context, title: String, text: String, percent: Int) {
            this.title = title
            this.text = text
            this.percent = percent
            val running = instance
            if (running != null) {
                running.refresh()
                return
            }
            val intent = Intent(ctx, AudioExportService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun end(ctx: Context) {
            instance = null
            ctx.stopService(Intent(ctx, AudioExportService::class.java))
        }

        private fun channel(ctx: Context) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(CHANNEL_ID, "Saving as audio", NotificationManager.IMPORTANCE_LOW)
                channel.description = "How far a book being saved as audio is, and when it is saved."
                channel.setShowBadge(false)
                nm.createNotificationChannel(channel)
            }
        }

        private fun builder(ctx: Context): Notification.Builder {
            channel(ctx)
            return if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(ctx, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(ctx)
            }
        }

        private fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(
            ctx,
            20,
            Intent(ctx, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        /** ACTION_SEND for the saved file at [uri], of type [mime], readable by the app it goes to. */
        fun sendIntent(uri: Uri, mime: String?): Intent = Intent(Intent.ACTION_SEND).apply {
            type = mime ?: "audio/*"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        /**
         * The end of a save, once its service has gone: saved (tap to play it,
         * Share), or not, and why. Stays until dismissed.
         */
        fun notice(ctx: Context, title: String, text: String, uri: Uri?, mime: String?) {
            val b = builder(ctx)
                .setSmallIcon(R.drawable.ic_stat_tomevoice)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setContentIntent(openApp(ctx))
            if (uri != null) {
                val play = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, mime ?: "audio/*")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                b.setContentIntent(
                    PendingIntent.getActivity(
                        ctx, 22, play, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                )
                val share = Intent.createChooser(sendIntent(uri, mime), null)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                b.addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(ctx, android.R.drawable.ic_menu_share),
                        "Share",
                        PendingIntent.getActivity(
                            ctx, 23, share, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                        )
                    ).build()
                )
            }
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTICE_ID, b.build())
            } catch (_: Exception) {
            }
        }
    }

    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            val cancel = onCancel
            if (cancel != null) cancel() else stopSelf()
            return START_NOT_STICKY
        }
        val n = build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        keepAwake()
        // Nothing is saving (the engine went since): stop again.
        if (onCancel == null) stopSelf()
        return START_NOT_STICKY
    }

    /** Android 15 and later: a dataSync service's six hours a day are used up. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        letGo()
        instance = null
        notice(
            this,
            "Saving paused",
            "Android lets it work six hours a day in the background. Open TomeVoice to go on.",
            null,
            null,
        )
        onTimeout?.invoke()
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        letGo()
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    fun refresh() {
        keepAwake()
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, build())
        } catch (_: Exception) {
        }
    }

    /**
     * The CPU kept awake while the save works, or the phone could sleep
     * between sentences with the screen off. Renewed with every update;
     * the timeout only lets an app that died holding it off.
     */
    private fun keepAwake() {
        try {
            val w = wake ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TomeVoice:saving")
                .also {
                    it.setReferenceCounted(false)
                    wake = it
                }
            w.acquire(AWAKE_MS)
        } catch (_: Exception) {
        }
    }

    private fun letGo() {
        try {
            wake?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
    }

    private fun build(): Notification {
        val cancel = PendingIntent.getService(
            this,
            21,
            Intent(this, AudioExportService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return builder(this)
            .setSmallIcon(R.drawable.ic_stat_tomevoice)
            .setContentTitle(title)
            .setContentText(text)
            // Tapped: the app, the save's progress over it (home_shell.dart).
            .setContentIntent(Widgets.openApp(this, NOTIFICATION_ID, null, false, "export"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(100, percent.coerceIn(0, 100), percent < 0)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Cancel",
                    cancel
                ).build()
            )
            .build()
    }
}
