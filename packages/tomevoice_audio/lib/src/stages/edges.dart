import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// Trims leading and trailing silence and applies short fades at both ends.
///
/// TTS engines commonly emit a few tens of milliseconds of near-silence before
/// speech begins, and more after it ends. Left in, the first inflates
/// time-to-first-audio, and both make sentence pauses inconsistent: the
/// "pause" a listener hears was the configured value plus whatever padding
/// the engine happened to add. The pause after a sentence is appended later
/// ([SentencePauseStage], or the scheduler between buffers), after this
/// stage, so trimming here never takes it away.
class EdgeTrimStage implements PipelineStage {
  const EdgeTrimStage({
    this.enabled = true,
    this.thresholdDb = -60.0,
    this.fadeMs = 3,
    this.keepLeadMs = 5,
    this.keepTailMs = 40,
  });

  final bool enabled;

  /// Anything quieter than this, relative to full scale, counts as silence.
  final double thresholdDb;

  final int fadeMs;

  /// Silence deliberately kept before the first speech frame, so the attack of
  /// the first phoneme is not clipped.
  final int keepLeadMs;

  /// Kept after the last sound above the threshold, so a soft ending (an
  /// "s" dying away) is not cut off.
  final int keepTailMs;

  @override
  String get name => 'edges';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    if (!enabled || input.frameCount == 0) {
      return StageResult.unchanged(input);
    }

    final src = input.samples;
    final threshold = math.pow(10, thresholdDb / 20).toDouble();

    var firstSound = 0;
    while (firstSound < src.length && src[firstSound].abs() < threshold) {
      firstSound++;
    }
    if (firstSound >= src.length) {
      // Entirely silent. Leave it alone rather than returning an empty buffer.
      return StageResult.unchanged(input);
    }

    var lastSound = src.length - 1;
    while (lastSound > firstSound && src[lastSound].abs() < threshold) {
      lastSound--;
    }

    final keepLead = input.msToFrames(keepLeadMs);
    final trimFrom = math.max(0, firstSound - keepLead);
    final trimTo = math.min(src.length, lastSound + 1 + input.msToFrames(keepTailMs));

    if (trimFrom == 0 && trimTo == src.length) {
      _fade(input.samples, input.msToFrames(fadeMs));
      return StageResult.unchanged(input);
    }

    final length = trimTo - trimFrom;
    final out = Float32List(length)..setRange(0, length, src, trimFrom);

    _fade(out, input.msToFrames(fadeMs));

    // A word reported to run on into the trimmed tail ends where the
    // buffer now ends.
    int remap(int frame) => (frame - trimFrom).clamp(0, length);

    return StageResult(input.withSamples(out), remap);
  }

  void _fade(Float32List buffer, int frames) {
    if (frames <= 0 || buffer.isEmpty) return;
    final span = math.min(frames, buffer.length ~/ 2);
    for (var i = 0; i < span; i++) {
      final g = (i + 1) / span;
      buffer[i] *= g;
      buffer[buffer.length - 1 - i] *= g;
    }
  }
}
