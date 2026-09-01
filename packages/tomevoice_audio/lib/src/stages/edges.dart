import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// Trims leading silence and applies short fades at both ends.
///
/// TTS engines commonly emit a few tens of milliseconds of near-silence before
/// speech begins. Left in, it inflates time-to-first-audio and makes sentence
/// pauses inconsistent, because the "pause" a listener hears is our configured
/// value plus whatever padding the engine happened to add.
///
/// Trailing silence is left alone: [SentencePauseStage] puts it there
/// deliberately, and this stage runs after it.
class EdgeTrimStage implements PipelineStage {
  const EdgeTrimStage({
    this.enabled = true,
    this.thresholdDb = -60.0,
    this.fadeMs = 3,
    this.keepLeadMs = 5,
  });

  final bool enabled;

  /// Anything quieter than this, relative to full scale, counts as silence.
  final double thresholdDb;

  final int fadeMs;

  /// Silence deliberately kept before the first speech frame, so the attack of
  /// the first phoneme is not clipped.
  final int keepLeadMs;

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

    final keepLead = input.msToFrames(keepLeadMs);
    final trimFrom = math.max(0, firstSound - keepLead);

    if (trimFrom == 0) {
      _fade(input.samples, input.msToFrames(fadeMs));
      return StageResult.unchanged(input);
    }

    final out = Float32List(src.length - trimFrom)
      ..setRange(0, src.length - trimFrom, src, trimFrom);

    _fade(out, input.msToFrames(fadeMs));

    int remap(int frame) => math.max(0, frame - trimFrom);

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
