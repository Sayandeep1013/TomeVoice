import 'dart:typed_data';

/// Mono PCM, normalised to -1.0..1.0.
///
/// Every stage in the pipeline consumes and produces one of these. Keeping the
/// representation float rather than int16 means intermediate stages never
/// requantise; conversion happens once, at the WAV boundary.
class AudioBuffer {
  AudioBuffer(this.samples, this.sampleRate)
      : assert(sampleRate > 0, 'sampleRate must be positive');

  final Float32List samples;
  final int sampleRate;

  int get frameCount => samples.length;

  Duration get duration =>
      Duration(microseconds: (frameCount * 1000000) ~/ sampleRate);

  /// Frames in [ms] milliseconds at this buffer's rate.
  int msToFrames(num ms) => (ms * sampleRate / 1000).round();

  /// Milliseconds spanned by [frames] at this buffer's rate.
  double framesToMs(int frames) => frames * 1000.0 / sampleRate;

  AudioBuffer withSamples(Float32List next) => AudioBuffer(next, sampleRate);

  /// Silence of [frames] length at this buffer's rate.
  static Float32List silence(int frames) => Float32List(frames);
}

/// How a [WordTiming] was obtained. This is the honesty field: the UI degrades
/// highlighting granularity when timings are merely [estimated], rather than
/// confidently highlighting the wrong word.
enum WordTimingSource {
  /// The engine told us directly (Android `onRangeStart`, Windows markers).
  engineReported,

  /// Read out of a neural model's duration predictor.
  modelDurations,

  /// Recovered by running a forced aligner over the synthesised audio.
  aligned,

  /// Guessed by distributing sentence duration across words. Good enough to
  /// place gaps; visibly wrong for highlighting.
  estimated,
}

/// One word, located in both the request text and the audio.
class WordTiming {
  const WordTiming({
    required this.charStart,
    required this.charEnd,
    required this.frameStart,
    required this.frameEnd,
    required this.source,
  });

  /// Range in the request text.
  final int charStart;
  final int charEnd;

  /// Range in the audio buffer.
  final int frameStart;
  final int frameEnd;

  final WordTimingSource source;

  int get frameLength => frameEnd - frameStart;

  WordTiming copyWithFrames(int start, int end) => WordTiming(
        charStart: charStart,
        charEnd: charEnd,
        frameStart: start,
        frameEnd: end,
        source: source,
      );

  @override
  String toString() =>
      'WordTiming(chars $charStart-$charEnd, frames $frameStart-$frameEnd, '
      '${source.name})';
}

/// What an engine adapter returns. Contract B.
class SynthesisResult {
  const SynthesisResult({
    required this.audio,
    required this.wordTimings,
    required this.engineId,
    this.appliedNatively = const {},
  });

  final AudioBuffer audio;
  final List<WordTiming> wordTimings;
  final String engineId;

  /// Which parameters the engine honoured itself. Anything absent here has to
  /// be applied in DSP instead.
  final Set<Capability> appliedNatively;

  SynthesisResult copyWith({
    AudioBuffer? audio,
    List<WordTiming>? wordTimings,
  }) =>
      SynthesisResult(
        audio: audio ?? this.audio,
        wordTimings: wordTimings ?? this.wordTimings,
        engineId: engineId,
        appliedNatively: appliedNatively,
      );
}

enum Capability { rate, pitch, volume, ssml }

/// Settings the pipeline reads. Only the fields the spike needs.
class PipelineSettings {
  const PipelineSettings({
    this.wordGapMs = 0,
    this.speedScale = 1.0,
    this.sentencePauseMs = 350,
    this.crossfadeMs = 4,
    this.snapSearchMs = 5,
    this.trimEdges = true,
  });

  /// Silence inserted at every word boundary. The headline feature.
  final int wordGapMs;

  /// Residual speed change the engine did not apply itself.
  final double speedScale;

  /// Silence appended after the sentence.
  final int sentencePauseMs;

  /// Fade applied either side of a splice, to prevent clicks.
  final int crossfadeMs;

  /// How far a splice point may move to find a quiet spot.
  final int snapSearchMs;

  final bool trimEdges;

  PipelineSettings copyWith({
    int? wordGapMs,
    double? speedScale,
    int? sentencePauseMs,
  }) =>
      PipelineSettings(
        wordGapMs: wordGapMs ?? this.wordGapMs,
        speedScale: speedScale ?? this.speedScale,
        sentencePauseMs: sentencePauseMs ?? this.sentencePauseMs,
        crossfadeMs: crossfadeMs,
        snapSearchMs: snapSearchMs,
        trimEdges: trimEdges,
      );
}
