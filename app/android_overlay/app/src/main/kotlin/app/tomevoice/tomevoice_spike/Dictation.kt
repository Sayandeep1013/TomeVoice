package app.tomevoice.tomevoice_spike

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Speaking into the journal: the phone's own speech recogniser (Android's
 * SpeechRecognizer; Google's voice typing on most phones), on the channel
 * "tomevoice/dictate". Nothing is recorded or kept here: the words come back
 * as text, partly as they are said ("partial"), then whole ("final"). The
 * recogniser stops by itself after a pause; Dart starts it again until the
 * reader taps stop, so a long thought is not cut short.
 */
class Dictation(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "tomevoice/dictate")
    private var recogniser: SpeechRecognizer? = null
    private var waiting: MethodChannel.Result? = null
    private var waitingLanguage: String? = null
    private var lastLevel = 0L

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(SpeechRecognizer.isRecognitionAvailable(activity))
                "start" -> start(call.argument<String>("language"), result)
                "stop" -> {
                    recogniser?.stopListening()
                    result.success(null)
                }
                "cancel" -> {
                    close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(language: String?, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            waiting?.success("denied")
            waiting = result
            waitingLanguage = language
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
            return
        }
        result.success(if (listen(language)) "listening" else "unavailable")
    }

    /** The answer to asking for the microphone. True when it was this asking. */
    fun onPermission(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != REQ_MIC) return false
        val r = waiting ?: return true
        waiting = null
        if (grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED) {
            r.success(if (listen(waitingLanguage)) "listening" else "unavailable")
        } else {
            r.success("denied")
        }
        return true
    }

    private fun listen(language: String?): Boolean {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) return false
        val rec = recogniser ?: SpeechRecognizer.createSpeechRecognizer(activity).also {
            it.setRecognitionListener(listener)
            recogniser = it
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            if (!language.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            // A thinking pause is not the end (some recognisers ignore it).
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 3000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 3000L)
            // Punctuation and capitals, where the recogniser can.
            if (Build.VERSION.SDK_INT >= 33) {
                putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            }
        }
        return try {
            rec.startListening(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun send(method: String, args: Map<String, Any?>) {
        activity.runOnUiThread { channel.invokeMethod(method, args) }
    }

    private fun words(b: Bundle?): String =
        b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = send("ready", emptyMap())
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {
            // About ten a second is plenty for the mic's ring.
            val now = System.currentTimeMillis()
            if (now - lastLevel < 100) return
            lastLevel = now
            send("level", mapOf("db" to rmsdB.toDouble()))
        }
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onError(error: Int) = send("error", mapOf("code" to error))
        override fun onResults(results: Bundle?) = send("final", mapOf("text" to words(results)))
        override fun onPartialResults(partialResults: Bundle?) = send("partial", mapOf("text" to words(partialResults)))
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    fun close() {
        recogniser?.destroy()
        recogniser = null
    }

    companion object {
        const val REQ_MIC = 74
    }
}
