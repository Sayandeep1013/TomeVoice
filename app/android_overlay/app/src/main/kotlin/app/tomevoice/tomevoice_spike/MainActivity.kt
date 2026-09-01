package app.tomevoice.tomevoice_spike

import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The only part of the spike that needs a device, and the part that answers
 * risk R1: does this engine actually supply word timings?
 *
 * Every onRangeStart callback is captured verbatim rather than interpreted. The
 * platform documentation is explicit that it is "Only called if the engine
 * supplies timing information", and engines differ, so this adapter's job is to
 * measure the engine rather than to trust it.
 *
 * Uses synthesizeToFile, never speak(): the architecture requires PCM we can
 * process, not fire-and-forget playback (docs/10 ADR-003).
 */
class MainActivity : FlutterActivity() {

    private val channelName = "tomevoice/tts"
    private val main = Handler(Looper.getMainLooper())

    private var tts: TextToSpeech? = null
    private var player: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listEngines" -> listEngines(result)
                    "listVoices" -> listVoices(call.argument<String>("engineId"), result)
                    "synthesise" -> synthesise(call.arguments as Map<*, *>, result)
                    "play" -> play(call.argument<String>("path"), result)
                    "outputDir" -> result.success(outputDir().absolutePath)
                    "launchArgs" -> result.success(launchArgs())
                    else -> result.notImplemented()
                }
            }
    }

    private fun outputDir(): File = getExternalFilesDir(null) ?: cacheDir

    /**
     * Intent extras, so a measurement run can be driven from adb rather than by
     * tapping through the UI.
     *
     *   adb shell am start -n app.tomevoice.tomevoice_spike/.MainActivity \
     *       --es batch true
     *
     * Driving Flutter through `input tap` would be fragile and would not
     * reproduce; an explicit batch mode makes the run repeatable and makes the
     * exported artefacts comparable across devices.
     */
    private fun launchArgs(): Map<String, String> {
        val extras = intent?.extras ?: return emptyMap()
        return extras.keySet().associateWith { key ->
            extras.get(key)?.toString() ?: ""
        }
    }

    /**
     * R1 is a per-engine question, so the UI must be able to switch engines.
     * Testing one engine and generalising would answer nothing.
     */
    private fun listEngines(result: MethodChannel.Result) {
        var probe: TextToSpeech? = null
        try {
            probe = TextToSpeech(applicationContext, null)
            result.success(
                probe.engines.map { mapOf("name" to it.name, "label" to it.label) }
            )
        } catch (e: Exception) {
            result.error("ENGINE_LIST", e.message, null)
        } finally {
            probe?.shutdown()
        }
    }

    /**
     * The voices an engine actually has, so a poor default can be replaced.
     *
     * Quality varies enormously: a device may carry a small embedded fallback
     * and a much better downloaded network-free voice under the same locale.
     * `Voice.getQuality()` distinguishes them, so the list is sorted best-first.
     */
    private fun listVoices(engineId: String?, result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        val holder = arrayOfNulls<TextToSpeech>(1)

        holder[0] = TextToSpeech(applicationContext, { status ->
            val engine = holder[0]
            if (status != TextToSpeech.SUCCESS || engine == null) {
                if (replied.compareAndSet(false, true)) {
                    main.post { result.error("TTS_INIT", "init failed: $status", null) }
                }
                return@TextToSpeech
            }
            val voices = try {
                (engine.voices ?: emptySet())
                    .sortedWith(
                        compareByDescending<android.speech.tts.Voice> { it.quality }
                            .thenBy { it.name }
                    )
                    .map {
                        mapOf(
                            "name" to it.name,
                            "locale" to it.locale.toString(),
                            "quality" to it.quality,
                            "networkRequired" to
                                it.isNetworkConnectionRequired,
                            "features" to it.features.joinToString(",")
                        )
                    }
            } catch (e: Exception) {
                emptyList()
            }
            if (replied.compareAndSet(false, true)) {
                main.post {
                    result.success(voices)
                    engine.shutdown()
                }
            }
        }, engineId)

        main.postDelayed({
            if (replied.compareAndSet(false, true)) {
                result.error("TTS_TIMEOUT", "voice list timed out", null)
            }
        }, 15_000)
    }

    private fun synthesise(args: Map<*, *>, result: MethodChannel.Result) {
        val text = (args["text"] as? String).orEmpty()
        val engineId = args["engineId"] as? String
        val rate = (args["rate"] as? Number)?.toFloat() ?: 1.0f
        val pitch = (args["pitch"] as? Number)?.toFloat() ?: 1.0f

        if (text.isBlank()) {
            result.error("EMPTY_TEXT", "Nothing to synthesise", null)
            return
        }

        tts?.shutdown()
        tts = null

        val replied = AtomicBoolean(false)
        fun reply(block: () -> Unit) {
            if (replied.compareAndSet(false, true)) main.post(block)
        }

        // Callbacks arrive off the main thread, so this is written from a
        // synthesis thread and read from the main one.
        val events = CopyOnWriteArrayList<Map<String, Int>>()
        val utteranceId = "spike-" + System.currentTimeMillis()
        val outFile = File(outputDir(), "$utteranceId.wav")

        // The engine reference has to be reachable from inside its own init
        // callback. A plain local would not be assigned yet, so it goes in a
        // holder that the lambda closes over.
        val holder = arrayOfNulls<TextToSpeech>(1)

        holder[0] = TextToSpeech(applicationContext, { status ->
            val engine = holder[0]
            if (status != TextToSpeech.SUCCESS || engine == null) {
                reply {
                    result.error("TTS_INIT", "Engine init failed: $status", null)
                }
                return@TextToSpeech
            }

            try {
                // Do NOT force Locale.US. On a device without en-US voice data
                // installed, forcing it selects a low-quality embedded fallback
                // - which is what made the first listening test sound robotic.
                // Prefer an explicitly chosen voice, else the engine's own
                // default, which is the one the user has actually installed.
                val wanted = args["voiceName"] as? String
                if (!wanted.isNullOrBlank()) {
                    engine.voices?.firstOrNull { it.name == wanted }?.let {
                        engine.voice = it
                    }
                }

                engine.setSpeechRate(rate)
                engine.setPitch(pitch)

                engine.setOnUtteranceProgressListener(
                    object : UtteranceProgressListener() {
                        override fun onStart(id: String?) = Unit

                        override fun onRangeStart(
                            id: String?,
                            start: Int,
                            end: Int,
                            frame: Int
                        ) {
                            events.add(
                                mapOf("start" to start, "end" to end, "frame" to frame)
                            )
                        }

                        override fun onDone(id: String?) {
                            reply {
                                result.success(buildReport(text, outFile, events, engine))
                            }
                        }

                        @Deprecated("Required by the base class")
                        override fun onError(id: String?) {
                            reply { result.error("TTS_ERROR", "Synthesis failed", null) }
                        }

                        override fun onError(id: String?, errorCode: Int) {
                            reply {
                                result.error(
                                    "TTS_ERROR",
                                    "Synthesis failed (code $errorCode)",
                                    null
                                )
                            }
                        }
                    }
                )

                // No SSML. With SSML the start/end indices refer to the SSML
                // string rather than the plain text, which would corrupt the
                // character mapping we depend on (docs/04 section 4.3).
                val code = engine.synthesizeToFile(text, Bundle(), outFile, utteranceId)
                if (code != TextToSpeech.SUCCESS) {
                    reply {
                        result.error("TTS_QUEUE", "synthesizeToFile returned $code", null)
                    }
                }
            } catch (e: Exception) {
                reply { result.error("TTS_EXCEPTION", e.message, null) }
            }
        }, engineId)

        tts = holder[0]

        // An engine that never calls back would otherwise hang the UI silently.
        main.postDelayed({
            reply { result.error("TTS_TIMEOUT", "No callback within 30s", null) }
        }, 30_000)
    }

    private fun play(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank() || !File(path).exists()) {
            result.error("NO_FILE", "No such file: $path", null)
            return
        }
        try {
            player?.release()
            player = MediaPlayer().apply {
                setDataSource(path)
                prepare()
                start()
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("PLAYBACK", e.message, null)
        }
    }

    private fun buildReport(
        text: String,
        file: File,
        events: List<Map<String, Int>>,
        engine: TextToSpeech
    ): Map<String, Any?> {
        val header = readWavHeader(file)
        val words = wordCount(text)

        // Granularity is inferred, not asserted: an engine reporting roughly one
        // event per word is doing word ranges; one or two events for a whole
        // sentence is utterance-level and useless for gap placement.
        val granularity = when {
            events.isEmpty() -> "none"
            words > 0 && events.size >= (words * 0.6) -> "word"
            else -> "utterance"
        }

        return mapOf(
            "wavPath" to file.absolutePath,
            "engineId" to (engine.defaultEngine ?: "unknown"),
            "voiceName" to (engine.voice?.name ?: "unknown"),
            "voiceQuality" to (engine.voice?.quality ?: -1),
            "rangeEvents" to events,
            "rangeStartFired" to events.isNotEmpty(),
            "granularity" to granularity,
            "wordCount" to words,
            "sampleRate" to header.first,
            "frameCount" to header.second,
            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "androidVersion" to Build.VERSION.SDK_INT
        )
    }

    private fun wordCount(text: String): Int =
        text.trim().split(Regex("\\s+")).count { it.isNotBlank() }

    /** Returns (sampleRate, frameCount) by walking RIFF chunks. */
    private fun readWavHeader(file: File): Pair<Int, Int> {
        if (!file.exists() || file.length() < 44) return Pair(0, 0)
        val bytes = file.readBytes()

        fun u32(o: Int) = (bytes[o].toInt() and 0xFF) or
            ((bytes[o + 1].toInt() and 0xFF) shl 8) or
            ((bytes[o + 2].toInt() and 0xFF) shl 16) or
            ((bytes[o + 3].toInt() and 0xFF) shl 24)

        fun u16(o: Int) = (bytes[o].toInt() and 0xFF) or
            ((bytes[o + 1].toInt() and 0xFF) shl 8)

        var sampleRate = 0
        var bitsPerSample = 16
        var channels = 1
        var dataBytes = 0
        var offset = 12

        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val size = u32(offset + 4)
            val body = offset + 8
            when (id) {
                "fmt " -> {
                    channels = u16(body + 2)
                    sampleRate = u32(body + 4)
                    bitsPerSample = u16(body + 14)
                }
                "data" -> dataBytes = minOf(size, bytes.size - body)
            }
            if (size <= 0) break
            offset = body + size + (size and 1)
        }

        val bytesPerFrame = maxOf(1, channels * bitsPerSample / 8)
        return Pair(sampleRate, dataBytes / bytesPerFrame)
    }

    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        player?.release()
        player = null
        super.onDestroy()
    }
}
