package app.tomevoice.tomevoice_spike

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import java.util.concurrent.LinkedBlockingQueue

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
 * will start, and [position] reports what the listener is hearing, so the Dart
 * side can say exactly which sentence and word is audible right now. That is
 * what keeps the word highlight in sync with the voice instead of with a
 * wall-clock timer that drifts.
 */
class PcmPlayer {
    companion object {
        /**
         * About how long Bluetooth takes to play what it is given. A route
         * whose delay the platform reports (in the track's timestamps) is not
         * topped up; one that reports less is, to this.
         */
        const val BLUETOOTH_DELAY_MS = 150L

        fun isBluetooth(type: Int?): Boolean = when (type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST -> true
            else -> false
        }
    }

    private val lock = Any()
    private var track: AudioTrack? = null
    private var sampleRate = 0
    private var queue = LinkedBlockingQueue<ByteArray>()
    private var framesEnqueued = 0L
    private var paused = false

    @Volatile
    private var generation = 0

    /** The track refused a write (it died under us): said through [position]. */
    @Volatile
    private var failed = false

    /** The sleep timer's fade; kept for the next track. */
    private var volume = 1f

    /** The listener's own correction for each route (Highlight timing), in ms. */
    private var bluetoothOffsetMs = 0L
    private var otherOffsetMs = 0L

    private val stamp = AudioTimestamp()
    private var haveStamp = false
    private var stampAskedAt = 0L
    private var lastHeard = 0L
    private var bluetooth = false
    private var routeAskedAt = 0L

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

    /**
     * Frames the listener has heard in this stream: the hardware head less
     * what is still on its way out. The track's timestamp says what reached
     * the output (Bluetooth's delay included, where the platform knows it);
     * Bluetooth that reports less is topped up to [BLUETOOTH_DELAY_MS]; and
     * the listener's correction for the route comes off last. [raw] is the
     * head itself. -1 once a write has failed: the stream needs starting again.
     */
    fun position(raw: Boolean = false): Long = synchronized(lock) {
        val t = track ?: return 0L
        if (failed) return -1L
        val head = try {
            t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        } catch (e: Exception) {
            return 0L
        }
        if (raw) return head
        // Paused, the timestamp stands still while the clock runs on: what
        // was heard is what was heard.
        if (t.playState != AudioTrack.PLAYSTATE_PLAYING) return minOf(lastHeard, head)
        val now = System.nanoTime()
        // Asked twice a second: the platform says asking more often is waste.
        if (!haveStamp || now - stampAskedAt > 500_000_000L) {
            haveStamp = try {
                t.getTimestamp(stamp)
            } catch (e: Exception) {
                false
            }
            stampAskedAt = now
        }
        var presented = head
        if (haveStamp) {
            val since = maxOf(0L, now - stamp.nanoTime)
            presented = (stamp.framePosition + since * sampleRate / 1_000_000_000L).coerceIn(0L, head)
        }
        val bt = onBluetooth(t, now)
        val topUp = if (bt) maxOf(0L, BLUETOOTH_DELAY_MS * sampleRate / 1000 - (head - presented)) else 0L
        val offset = (if (bt) bluetoothOffsetMs else otherOffsetMs) * sampleRate / 1000
        val heard = (presented - topUp - offset).coerceIn(0L, head)
        // Never back while it plays (an offset changed, a stale stamp).
        lastHeard = maxOf(lastHeard, heard)
        lastHeard
    }

    /** Whether the voice is heard over Bluetooth now, or null with no stream. */
    fun onBluetoothNow(): Boolean? = synchronized(lock) {
        val t = track ?: return null
        onBluetooth(t, System.nanoTime())
    }

    private fun onBluetooth(t: AudioTrack, now: Long): Boolean {
        if (now - routeAskedAt > 1_000_000_000L || routeAskedAt == 0L) {
            routeAskedAt = now
            bluetooth = try {
                isBluetooth(t.routedDevice?.type)
            } catch (e: Exception) {
                false
            }
        }
        return bluetooth
    }

    fun setOffsets(bluetoothMs: Long, otherMs: Long) = synchronized(lock) {
        bluetoothOffsetMs = bluetoothMs
        otherOffsetMs = otherMs
    }

    fun setVolume(v: Float) = synchronized(lock) {
        volume = v.coerceIn(0f, 1f)
        try {
            track?.setVolume(volume)
        } catch (_: Exception) {
        }
    }

    fun enqueuedFrames(): Long = synchronized(lock) { framesEnqueued }

    fun pause() = synchronized(lock) {
        paused = true
        haveStamp = false
        try {
            track?.pause()
        } catch (_: Exception) {
        }
    }

    fun resume() = synchronized(lock) {
        paused = false
        haveStamp = false
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
        failed = false
        haveStamp = false
        lastHeard = 0L
        routeAskedAt = 0L
        try {
            t.setVolume(volume)
        } catch (_: Exception) {
        }
        val gen = ++generation
        val q = LinkedBlockingQueue<ByteArray>()
        queue = q
        if (!paused) t.play()

        val writer = Thread({
            try {
                while (generation == gen) {
                    // Asleep until the next sentence comes (it looked every
                    // 200 ms, playing or paused); a stop wakes it with an
                    // empty one (see releaseLocked).
                    val chunk = q.take()
                    var off = 0
                    while (off < chunk.size && generation == gen) {
                        val n = t.write(chunk, off, chunk.size - off)
                        if (n < 0) {
                            // The track refused it (dead: the audio server
                            // restarted, a route change failed). Once quiet,
                            // the app showed "playing" over silence; now the
                            // scheduler hears of it and starts the sentence again.
                            if (generation == gen) failed = true
                            return@Thread
                        }
                        if (n == 0) Thread.sleep(10)
                        off += n
                    }
                }
            } catch (_: Exception) {
                // Track released under us: this generation is over. Anything
                // else while it is still ours is a failure.
                if (generation == gen) failed = true
            }
        }, "tomevoice-pcm")
        writer.isDaemon = true
        writer.start()
    }

    private fun releaseLocked() {
        generation++
        queue.clear()
        // The writer of this stream, waiting for the next sentence, wakes to
        // find its stream gone.
        queue.offer(ByteArray(0))
        failed = false
        haveStamp = false
        lastHeard = 0L
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
