import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// Appends the sentence pause.
///
/// Trailing silence only — it never shifts existing frames, so its remap is the
/// identity. In the full product, inter-sentence and inter-paragraph silence is
/// inserted by the *scheduler* between buffers rather than baked into them, so
/// that changing the setting takes effect without re-synthesis (docs/05 §5.4).
/// The spike bakes it in because it has no scheduler yet.
class SentencePauseStage implements PipelineStage {
  const SentencePauseStage(this.pauseMs);

  final int pauseMs;

  @override
  String get name => 'sentence_pause';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    final pauseFrames = input.msToFrames(pauseMs);
    if (pauseFrames <= 0) return StageResult.unchanged(input);

    final out = Float32List(input.frameCount + pauseFrames)
      ..setRange(0, input.frameCount, input.samples);

    // Appending cannot move anything that already exists.
    return StageResult(input.withSamples(out), identityRemap);
  }
}
