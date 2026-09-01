import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis.dart';
import '../pipeline.dart';
import '../types.dart';

enum Compression { off, light, strong }

/// Volume, per-voice trim, loudness levelling and a limiter.
///
/// Loudness levelling is not a luxury here. Open TTS voices differ by more than
/// 10 dB in output level, so switching voice mid-book without it is genuinely
/// unpleasant — and on a device the user has already set a comfortable system
/// volume for, it is the app's job to be consistent, not theirs
/// (docs/05 section 5.5).
///
/// Changes no frame positions, so its remap is the identity.
class GainStage implements PipelineStage {
  const GainStage({
    this.volume = 1.0,
    this.trimDb = 0.0,
    this.normalise = true,
    this.targetPeak = 0.89, // about -1 dBFS
    this.compression = Compression.light,
  });

  /// Master volume, 0..1, on top of the system volume.
  final double volume;

  /// Per-voice correction in dB, so a quiet voice can be brought up to sit
  /// alongside a loud one.
  final double trimDb;

  final bool normalise;

  /// Peak the normaliser aims for. Peak rather than LUFS: a true loudness
  /// measure needs K-weighting and gating, which is Phase 3 work. Peak
  /// normalising already removes the worst of the voice-to-voice jumps.
  final double targetPeak;

  final Compression compression;

  @override
  String get name => 'gain';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    final trimLinear = math.pow(10, trimDb / 20).toDouble();
    var gain = volume * trimLinear;

    if (normalise) {
      final peak = AudioAnalysis.peak(input.samples);
      if (peak > 1e-6) {
        gain *= targetPeak / peak;
      }
    }

    final ratio = switch (compression) {
      Compression.off => 1.0,
      Compression.light => 0.6,
      Compression.strong => 0.35,
    };
    const threshold = 0.35;

    // Unity gain and no compression means nothing to do; skip rather than
    // rewriting the buffer for no reason.
    if ((gain - 1.0).abs() < 1e-6 && compression == Compression.off) {
      return StageResult.unchanged(input);
    }

    final src = input.samples;
    final out = Float32List(src.length);

    for (var i = 0; i < src.length; i++) {
      var v = src[i] * gain;

      // Soft knee above the threshold, then a hard limit. Compression helps a
      // lot in a car or on a train, which is a primary listening context.
      final a = v.abs();
      if (ratio < 1.0 && a > threshold) {
        final over = a - threshold;
        final compressed = threshold + over * ratio;
        v = v.isNegative ? -compressed : compressed;
      }

      out[i] = v.clamp(-1.0, 1.0);
    }

    return StageResult(input.withSamples(out), identityRemap);
  }
}
