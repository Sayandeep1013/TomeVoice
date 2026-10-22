package app.tomevoice.tomevoice_spike

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * One streaming AudioTrack that the Dart scheduler feeds sentence by sentence.
 *
 * This replaced a MediaPlayer-per-sentence design that wrote a WAV, prepared a
 * new player and waited for its completion callback for every sentence. That
 * cost 600-750 ms of dead air between sentences on the test phone and made
 * pause impossible (stop was the only verb).
 *
 * Here sentences are written back to back into the same track, so playback is
 * gapless by construction. Every enqueue returns the frame at which that chunk
 * will start, and [position] reports the hardware playback head, so the Dart
 * side can say exactly which sentence and word is audible right now. That is
 * what keeps the word highlight in sync with the voice instead of with a
 * wall-clock timer that drifts.
 */
class PcmPlayer {
    private val lock = Any()
    private var track: AudioTrack? = null
    private var sampleRate = 0
    private var queue = LinkedBlockingQueue<ByteArray>()
    private var framesEnqueued = 0L
    private var paused = false

    @Volatile
    private var generation = 0

    val isActive: Boolean
        get() = synchronized(lock) { track != null }

    /** Queue PCM16 mono [pcm]; returns the stream frame it starts at. */
    fun enqueue(pcm: ByteArray, rate: Int): Long = synchronized(lock) {
        if (track == null || rate != sampleRate) startLocked(rate)
        val start = framesEnqueued
        framesEnqueued += (pcm.size / 2).toLong()
        queue.put(pcm)
        start
    }

    /** Frames actually played since the stream started. */
    fun position(): Long = synchronized(lock) {
        val t = track ?: return 0L
        try {
            t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (e: Exception) {
            0L
        }
    }

    fun enqueuedFrames(): Long = synchronized(lock) { framesEnqueued }

    fun pause() = synchronized(lock) {
        paused = true
        try {
            track?.pause()
        } catch (_: Exception) {
        }
    }

    fun resume() = synchronized(lock) {
        paused = false
        try {
            track?.play()
        } catch (_: Exception) {
        }
    }

    fun stop() = synchronized(lock) {
        releaseLocked()
        paused = false
    }

    private fun startLocked(rate: Int) {
        releaseLocked()
        sampleRate = rate
        val min = AudioTrack.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // About half a second. Position comes from the playback head, so a
        // larger buffer costs nothing in sync; it only protects against a
        // writer hiccup turning into an audible dropout.
        val bytes = maxOf(min * 4, rate)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track = t
        framesEnqueued = 0L
        val gen = ++generation
        val q = LinkedBlockingQueue<ByteArray>()
        queue = q
        if (!paused) t.play()

        val writer = Thread({
            try {
                while (generation == gen) {
                    val chunk = q.poll(200, TimeUnit.MILLISECONDS) ?: continue
                    var off = 0
                    while (off < chunk.size && generation == gen) {
                        val n = t.write(chunk, off, chunk.size - off)
                        if (n < 0) return@Thread
                        if (n == 0) Thread.sleep(10)
                        off += n
                    }
                }
            } catch (_: Exception) {
                // Track released under us: this generation is over.
            }
        }, "tomevoice-pcm")
        writer.isDaemon = true
        writer.start()
    }

    private fun releaseLocked() {
        generation++
        queue.clear()
        val t = track ?: return
        track = null
        framesEnqueued = 0L
        try {
            t.pause()
            t.flush()
            t.stop()
        } catch (_: Exception) {
        }
        try {
            t.release()
        } catch (_: Exception) {
        }
    }
}
