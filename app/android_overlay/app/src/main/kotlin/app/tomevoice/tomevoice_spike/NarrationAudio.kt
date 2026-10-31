package app.tomevoice.tomevoice_spike

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
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
 */
object NarrationAudio {

    /** Decoded from this long before the stretch: MP3's first frames after a seek need the ones before them. */
    private const val PRE_ROLL_US = 200_000L

    /** And on past its end, so its last frame comes whole. */
    private const val POST_ROLL_US = 100_000L

    /** A stretch still not decoded after this is given up. */
    private const val TIMEOUT_NS = 30_000_000_000L

    private val work = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

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
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            FileInputStream(path).use { input ->
                val size = if (length >= 0) length else input.channel.size() - offset
                // MediaExtractor keeps its own hold on the file: this one
                // may close as soon as it returns.
                extractor.setDataSource(input.fd, offset, size)
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
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1L
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floats = false
            val mime = format.getString(MediaFormat.KEY_MIME) ?: throw IllegalStateException("The narration's file has no type")
            val c = MediaCodec.createDecoderByType(mime)
            codec = c
            c.configure(format, null, null, 0)
            c.start()
            extractor.seekTo(maxOf(0L, beginUs - PRE_ROLL_US), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

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
                        if (n < 0 || (endUs >= 0 && time > endUs + POST_ROLL_US)) {
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
                        if (firstUs < 0) firstUs = info.presentationTimeUs
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
