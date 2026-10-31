package app.tomevoice.tomevoice_spike

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * A book's own recorded narration (an EPUB's media overlays), the
 * platform's half (narration.dart is the other): a stretch of one of its
 * audio files decoded by MediaExtractor and MediaCodec, read straight from
 * the book's EPUB where the file is stored in it whole (a range of the
 * EPUB's bytes), so nothing is unpacked.
 *
 * Only the decoding is done here, from a little before the stretch to a
 * little after it. Dart is given all of that as it came: 16-bit samples,
 * the file's channels interleaved, at its own rate, with the time of the
 * first. Dart cuts it to the stretch, mixes it down and brings it to the
 * voices' rate, where that can be tested.
 *
 * An MP3 is read from one of its own frames, found from their headers
 * ([Mp3Frames]), not by MediaExtractor's seek: in one whose bit rate
 * varies, that only estimates where a time is, and gives the time asked
 * for as the time it landed at, so clips were cut away from their words.
 * Anything else (AAC in an MP4, whose seek is exact) is read as before.
 */
object NarrationAudio {

    /** Decoded from this long before the stretch: MP3's first frames after a seek need the ones before them. */
    private const val PRE_ROLL_US = 200_000L

    /** And on past its end, so its last frame comes whole. */
    private const val POST_ROLL_US = 100_000L

    /** A stretch still not decoded after this is given up. */
    private const val TIMEOUT_NS = 30_000_000_000L

    /** At most this much after an MP3's last frame is taken for its tags (ID3v1, APE), not frames that stopped reading. */
    private const val TAIL_MAX = 64 * 1024L

    /** An MP3 frame's version, layer and rate: the same in every frame of a file. */
    private val SAME = 0xFFFE0C00L.toInt()

    /** Bit rates in kbps by index: MPEG-1 layers I, II and III, MPEG-2 (and 2.5) layer I, and their II and III. */
    private val V1L1 = intArrayOf(0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448)
    private val V1L2 = intArrayOf(0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384)
    private val V1L3 = intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320)
    private val V2L1 = intArrayOf(0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256)
    private val V2L23 = intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160)

    private val work = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The frames of the files read last (null: not an MP3 read as frames), by file; used on [work] alone. */
    private val indexes = LinkedHashMap<String, Mp3Frames?>()

    /** Dart's "narrationClip": the stretch [args] names, decoded on its own thread. */
    fun decode(args: Map<*, *>, result: MethodChannel.Result) {
        val path = args["path"] as? String
        if (path.isNullOrEmpty()) {
            result.error("NARRATION", "No audio file was named", null)
            return
        }
        val offset = (args["offset"] as? Number)?.toLong() ?: 0L
        val length = (args["length"] as? Number)?.toLong() ?: -1L
        val beginUs = (args["beginUs"] as? Number)?.toLong() ?: 0L
        val endUs = (args["endUs"] as? Number)?.toLong() ?: -1L
        work.execute {
            try {
                val out = stretch(path, offset, length, beginUs, endUs)
                main.post { result.success(out) }
            } catch (e: Throwable) {
                // Throwable: a decoder's Error (out of memory) fails this
                // stretch, and the voice reads it, not the app with it.
                main.post { result.error("NARRATION", e.message ?: "The narration could not be read", null) }
            }
        }
    }

    /**
     * The audio of the file of [length] bytes at [offset] in [path] (-1:
     * the rest of the file), from about [beginUs] to about [endUs] (-1: its
     * end).
     */
    private fun stretch(path: String, offset: Long, length: Long, beginUs: Long, endUs: Long): Map<String, Any> {
        val size = if (length >= 0) length else File(path).length() - offset
        val frames = framesOf(path, offset, size)
        if (frames == null) return read(path, offset, size, beginUs, endUs, null)
        return try {
            read(path, offset, size, beginUs, endUs, frames)
        } catch (e: Exception) {
            // Would not read from a frame of its own: by seeking, as before.
            read(path, offset, size, beginUs, endUs, null)
        }
    }

    /**
     * [stretch]: an MP3 with its [frames] from the frame at or before the
     * stretch's pre-roll, read as a file of its own that starts there (its
     * times then count from that frame, whose own time is known); anything
     * else from MediaExtractor's seek.
     */
    private fun read(path: String, offset: Long, size: Long, beginUs: Long, endUs: Long, frames: Mp3Frames?): Map<String, Any> {
        val kept = frames?.at(maxOf(0L, beginUs - PRE_ROLL_US)) ?: 0
        // Where the file is read from, and the time there.
        val skip = frames?.starts?.get(kept) ?: 0L
        val baseUs = frames?.timeUs(kept.toLong() * Mp3Frames.STEP) ?: 0L
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            FileInputStream(path).use { input ->
                // MediaExtractor keeps its own hold on the file: this one
                // may close as soon as it returns.
                extractor.setDataSource(input.fd, offset + skip, size - skip)
            }
            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    track = i
                    break
                }
            }
            if (track < 0) throw IllegalStateException("The narration's file has no sound in it")
            val format = extractor.getTrackFormat(track)
            extractor.selectTrack(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: throw IllegalStateException("The narration's file has no type")
            if (frames != null && !mime.startsWith(MediaFormat.MIMETYPE_AUDIO_MPEG)) throw IllegalStateException("Not read as an MP3")
            // An MP3's frames say how long it is; a file read from one of
            // them would say how long the rest is, and only roughly.
            val durationUs = when {
                frames != null -> frames.durationUs
                format.containsKey(MediaFormat.KEY_DURATION) -> format.getLong(MediaFormat.KEY_DURATION)
                else -> -1L
            }
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floats = false
            val c = MediaCodec.createDecoderByType(mime)
            codec = c
            c.configure(format, null, null, 0)
            c.start()
            if (frames == null) extractor.seekTo(maxOf(0L, beginUs - PRE_ROLL_US), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val out = Pcm16()
            var firstUs = -1L
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            val deadline = System.nanoTime() + TIMEOUT_NS
            while (true) {
                if (System.nanoTime() > deadline) throw IllegalStateException("The narration took too long to read")
                if (!inputDone) {
                    val slot = c.dequeueInputBuffer(10_000)
                    if (slot >= 0) {
                        val buf = c.getInputBuffer(slot) ?: throw IllegalStateException("The decoder gave no buffer")
                        val n = extractor.readSampleData(buf, 0)
                        val time = extractor.sampleTime
                        if (n < 0 || (endUs >= 0 && baseUs + time > endUs + POST_ROLL_US)) {
                            c.queueInputBuffer(slot, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            c.queueInputBuffer(slot, 0, n, time, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = c.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // What the decoder really gives (HE-AAC doubles its rate).
                    val f = c.outputFormat
                    if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floats = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (index >= 0) {
                    val buf = c.getOutputBuffer(index)
                    if (buf != null && info.size > 0) {
                        if (firstUs < 0) firstUs = baseUs + info.presentationTimeUs
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        if (floats) out.addFloats(buf) else out.addShorts(buf)
                    }
                    c.releaseOutputBuffer(index, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                }
            }
            return mapOf(
                "pcm" to out.bytes(),
                "channels" to channels,
                "sampleRate" to rate,
                "firstUs" to maxOf(0L, firstUs),
                "durationUs" to durationUs,
            )
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            extractor.release()
        }
    }

    /**
     * Where an MP3's frames are: every [STEP]th one's start, in bytes from
     * the start of the file, and how many there are, each [samples] long at
     * [rate]. A Xing, Info or VBRI frame first holds no sound and is not
     * counted, as MediaExtractor passes over it too.
     */
    private class Mp3Frames(val starts: LongArray, val count: Int, val samples: Int, val rate: Int) {
        /** The time frame [frame] starts at. */
        fun timeUs(frame: Long): Long = frame * samples * 1_000_000L / rate

        val durationUs: Long get() = timeUs(count.toLong())

        /** Which of [starts] is the frame at or before [us]. */
        fun at(us: Long): Int = (us * rate / (samples * 1_000_000L) / STEP).toInt().coerceIn(0, starts.size - 1)

        companion object {
            const val STEP = 8
        }
    }

    /** One frame's header: its length in bytes, and the samples it holds at its rate. */
    private class Mp3Frame(val bytes: Int, val samples: Int, val rate: Int)

    /** The frame whose header is [h], or null if [h] is not one this reads (free format among them). */
    private fun frameOf(h: Int): Mp3Frame? {
        if ((h ushr 21) != 0x7FF) return null
        // Version 3: MPEG-1, 2: MPEG-2, 0: MPEG-2.5. Layer 1: III, 2: II, 3: I.
        val version = (h ushr 19) and 3
        val layer = (h ushr 17) and 3
        val bitIndex = (h ushr 12) and 15
        val rateIndex = (h ushr 10) and 3
        val padding = (h ushr 9) and 1
        if (version == 1 || layer == 0 || bitIndex == 0 || bitIndex == 15 || rateIndex == 3) return null
        val rate = intArrayOf(44100, 48000, 32000)[rateIndex] shr (if (version == 3) 0 else if (version == 2) 1 else 2)
        val kbps = when {
            version == 3 && layer == 3 -> V1L1
            version == 3 && layer == 2 -> V1L2
            version == 3 -> V1L3
            layer == 3 -> V2L1
            else -> V2L23
        }
        val bits = kbps[bitIndex] * 1000
        return when {
            layer == 3 -> Mp3Frame((12 * bits / rate + padding) * 4, 384, rate)
            layer == 2 || version == 3 -> Mp3Frame(144 * bits / rate + padding, 1152, rate)
            else -> Mp3Frame(72 * bits / rate + padding, 576, rate)
        }
    }

    /** [path]'s frames (see [Mp3Frames]), from those read last or read now. */
    private fun framesOf(path: String, offset: Long, size: Long): Mp3Frames? {
        val key = "$path:$offset:$size:${File(path).lastModified()}"
        if (indexes.containsKey(key)) return indexes[key]
        val found = try {
            readFrames(path, offset, size)
        } catch (e: Exception) {
            null
        }
        // A few files: a chapter's, and the next.
        if (indexes.size >= 4) indexes.remove(indexes.keys.first())
        indexes[key] = found
        return found
    }

    /**
     * The frames of the MP3 of [size] bytes at [offset] in [path], from their
     * headers: past any ID3v2 tag, one after another to the end. Null for a
     * file that is not an MP3, or one that stops reading as frames before
     * its end (but for tags there): it is read as before.
     */
    private fun readFrames(path: String, offset: Long, size: Long): Mp3Frames? {
        RandomAccessFile(path, "r").use { file ->
            val buf = ByteArray(1 shl 16)
            var bufAt = 0L
            var bufLen = 0

            /** The byte at [p] in the MP3, or -1 past its end. */
            fun byteAt(p: Long): Int {
                if (p < 0 || p >= size) return -1
                if (p < bufAt || p >= bufAt + bufLen) {
                    file.seek(offset + p)
                    bufAt = p
                    bufLen = maxOf(0, file.read(buf, 0, minOf(buf.size.toLong(), size - p).toInt()))
                    if (bufLen == 0) return -1
                }
                return buf[(p - bufAt).toInt()].toInt() and 0xFF
            }

            /** The four bytes at [p] as one, big-endian, or null past the end. */
            fun headerAt(p: Long): Int? {
                var h = 0
                for (i in 0 until 4) {
                    val b = byteAt(p + i)
                    if (b < 0) return null
                    h = (h shl 8) or b
                }
                return h
            }

            fun saysAt(p: Long, word: String): Boolean = word.indices.all { byteAt(p + it) == word[it].code }

            var pos = 0L
            // ID3v2 tags first (a cover can be much of the file): their sizes
            // are seven bits a byte, and a footer adds ten.
            while (saysAt(pos, "ID3")) {
                var tag = 0L
                for (i in 6..9) {
                    val b = byteAt(pos + i)
                    if (b < 0) return null
                    tag = (tag shl 7) or (b and 0x7F).toLong()
                }
                pos += 10 + tag + (if ((byteAt(pos + 5) and 0x10) != 0) 10 else 0)
            }
            val first = headerAt(pos) ?: return null
            val head = frameOf(first) ?: return null
            // A Xing or Info frame has its word after the side information
            // (and the checksum, if there is one); a VBRI frame at 36.
            val mono = ((first ushr 6) and 3) == 3
            val side = if (((first ushr 19) and 3) == 3) (if (mono) 17 else 32) else (if (mono) 9 else 17)
            val info = pos + 4 + (if (((first ushr 16) and 1) == 0) 2 else 0) + side
            if (saysAt(info, "Xing") || saysAt(info, "Info") || saysAt(pos + 36, "VBRI")) pos += head.bytes
            var starts = LongArray(1024)
            var kept = 0
            var count = 0
            while (true) {
                val h = headerAt(pos) ?: break
                if ((h and SAME) != (first and SAME)) break
                val f = frameOf(h) ?: break
                if (count % Mp3Frames.STEP == 0) {
                    if (kept == starts.size) starts = starts.copyOf(kept * 2)
                    starts[kept++] = pos
                }
                count++
                pos += f.bytes
            }
            if (count < 2 || size - pos > TAIL_MAX) return null
            return Mp3Frames(starts.copyOf(kept), count, head.samples, head.rate)
        }
    }

    /** 16-bit samples as they are decoded, kept as little-endian bytes. */
    private class Pcm16 {
        private var data = ByteArray(1 shl 16)
        private var size = 0

        private fun room(n: Int) {
            if (size + n <= data.size) return
            var next = data.size * 2
            while (next < size + n) next *= 2
            data = data.copyOf(next)
        }

        /** A decoder's 16-bit output, in the phone's own order: little-endian. */
        fun addShorts(buf: ByteBuffer) {
            val n = buf.remaining() and 1.inv()
            room(n)
            buf.get(data, size, n)
            size += n
        }

        /** A decoder that gives floats: each as 16 bits. */
        fun addFloats(buf: ByteBuffer) {
            val values = buf.order(ByteOrder.nativeOrder()).asFloatBuffer()
            val n = values.remaining()
            room(n * 2)
            for (i in 0 until n) {
                val s = (values.get(i) * 32767f).coerceIn(-32768f, 32767f).toInt()
                data[size++] = s.toByte()
                data[size++] = (s shr 8).toByte()
            }
        }

        fun bytes(): ByteArray = data.copyOf(size)
    }
}
