import 'dart:typed_data';

import 'stages/gain.dart';
import 'stages/punctuation.dart';

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

/// Everything the pipeline reads.
///
/// Deliberately a plain value object: the UI builds one, the pipeline consumes
/// it, and a preset is just a constant instance. Nothing here reaches back into
/// widgets or platform channels.
class PipelineSettings {
  const PipelineSettings({
    this.wordGapMs = 0,
    this.speedScale = 1.0,
    this.sentencePauseMs = 350,
    this.paragraphPauseMs = 700,
    this.crossfadeMs = 4,
    this.snapSearchMs = 5,
    this.trimEdges = true,
    this.punctuation = const PunctuationPauses(),
    this.volume = 1.0,
    this.trimDb = 0.0,
    this.normaliseLoudness = true,
    this.compression = Compression.light,
    this.pitchSemitones = 0.0,
    this.text = '',
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

  /// Silence between paragraphs. Applied by the scheduler between buffers in
  /// the real product; recorded here so a preset can carry it.
  final int paragraphPauseMs;

  /// Per-punctuation-mark pauses inside a sentence.
  final PunctuationPauses punctuation;

  final double volume;
  final double trimDb;
  final bool normaliseLoudness;
  final Compression compression;

  /// Applied by the engine where it can, since no neural model exposes pitch
  /// and our own shifter is Phase 3 work. Carried here so the UI and the
  /// exported report agree on what was asked for.
  final double pitchSemitones;

  /// The text being spoken. Punctuation pauses need it to know what follows
  /// each word.
  final String text;

  PipelineSettings copyWith({
    int? wordGapMs,
    double? speedScale,
    int? sentencePauseMs,
    int? paragraphPauseMs,
    PunctuationPauses? punctuation,
    double? volume,
    double? trimDb,
    bool? normaliseLoudness,
    Compression? compression,
    double? pitchSemitones,
    String? text,
    bool? trimEdges,
  }) =>
      PipelineSettings(
        wordGapMs: wordGapMs ?? this.wordGapMs,
        speedScale: speedScale ?? this.speedScale,
        sentencePauseMs: sentencePauseMs ?? this.sentencePauseMs,
        paragraphPauseMs: paragraphPauseMs ?? this.paragraphPauseMs,
        crossfadeMs: crossfadeMs,
        snapSearchMs: snapSearchMs,
        trimEdges: trimEdges ?? this.trimEdges,
        punctuation: punctuation ?? this.punctuation,
        volume: volume ?? this.volume,
        trimDb: trimDb ?? this.trimDb,
        normaliseLoudness: normaliseLoudness ?? this.normaliseLoudness,
        compression: compression ?? this.compression,
        pitchSemitones: pitchSemitones ?? this.pitchSemitones,
        text: text ?? this.text,
      );
}
