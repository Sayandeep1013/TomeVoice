import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// Naive linear-resampling time stretch. **Deliberately a stub.**
///
/// This changes pitch along with duration, which is wrong for a speed control
/// and will be replaced in Phase 3 by a proper pitch-preserving WSOLA stretcher
/// (a GPL library is available to us — see docs/09 C-14).
///
/// It exists now for one reason: to prove that stage *ordering* and remap
/// composition are correct. A 120 ms word gap must survive a 2x speed change
/// as 120 ms, not 60 ms, and that property is independent of how good the
/// stretcher is. `ordering_test.dart` depends on this stage behaving like a
/// real one arithmetically, not on it sounding good.
class TimeStretchStubStage implements PipelineStage {
  const TimeStretchStubStage(this.speedScale);

  /// Greater than 1.0 shortens the audio (faster speech).
  final double speedScale;

  @override
  String get name => 'stretch_stub';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    if (speedScale == 1.0 || input.frameCount == 0) {
      return StageResult.unchanged(input);
    }

    final outLength = (input.frameCount / speedScale).round();
    if (outLength <= 0) return StageResult.unchanged(input);

    final src = input.samples;
    final out = Float32List(outLength);

    for (var i = 0; i < outLength; i++) {
      final srcPos = i * speedScale;
      final i0 = srcPos.floor();
      final i1 = i0 + 1;
      final frac = srcPos - i0;

      if (i1 < src.length) {
        out[i] = src[i0] * (1 - frac) + src[i1] * frac;
      } else if (i0 < src.length) {
        out[i] = src[i0];
      }
    }

    int remap(int frame) => (frame / speedScale).round().clamp(0, outLength);

    return StageResult(input.withSamples(out), remap);
  }
}
