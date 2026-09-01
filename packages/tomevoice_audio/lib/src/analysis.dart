import 'dart:math' as math;
import 'dart:typed_data';

import 'types.dart';

/// A contiguous stretch of near-silence.
class SilenceRun {
  const SilenceRun(this.startFrame, this.frameCount, this.sampleRate);

  final int startFrame;
  final int frameCount;
  final int sampleRate;

  int get endFrame => startFrame + frameCount;
  double get durationMs => frameCount * 1000.0 / sampleRate;

  @override
  String toString() =>
      'SilenceRun(${startFrame}f +${frameCount}f = '
      '${durationMs.toStringAsFixed(1)}ms)';
}

/// Measurement tools for verifying the pipeline did what it claimed.
///
/// Deliberately independent of the pipeline itself: the spike's offline checker
/// uses these to confirm gap durations from the audio alone, so a bug in the
/// gap stage cannot hide behind the same bug in the verifier.
class AudioAnalysis {
  const AudioAnalysis._();

  /// Finds runs quieter than [thresholdDb] relative to the buffer's peak,
  /// lasting at least [minDurationMs].
  ///
  /// The threshold is relative rather than absolute because TTS engines differ
  /// by more than 10 dB in output level (docs/09 C-18); a fixed threshold would
  /// find every gap in a loud voice and none in a quiet one.
  static List<SilenceRun> findSilences(
    AudioBuffer buffer, {
    double thresholdDb = -50.0,
    double minDurationMs = 20.0,
    double windowMs = 5.0,
  }) {
    if (buffer.frameCount == 0) return const [];

    final peakValue = peak(buffer.samples);
    if (peakValue <= 0) {
      return [SilenceRun(0, buffer.frameCount, buffer.sampleRate)];
    }

    final threshold = peakValue * math.pow(10, thresholdDb / 20).toDouble();
    final window = math.max(1, buffer.msToFrames(windowMs));
    final minFrames = buffer.msToFrames(minDurationMs);

    final runs = <SilenceRun>[];
    var runStart = -1;

    for (var i = 0; i < buffer.frameCount; i += window) {
      final end = math.min(i + window, buffer.frameCount);
      final quiet = rms(buffer.samples, i, end - i) < threshold;

      if (quiet && runStart < 0) {
        runStart = i;
      } else if (!quiet && runStart >= 0) {
        if (i - runStart >= minFrames) {
          runs.add(SilenceRun(runStart, i - runStart, buffer.sampleRate));
        }
        runStart = -1;
      }
    }

    if (runStart >= 0 && buffer.frameCount - runStart >= minFrames) {
      runs.add(
        SilenceRun(runStart, buffer.frameCount - runStart, buffer.sampleRate),
      );
    }
    return runs;
  }

  /// Silence runs excluding any at the very start or end, which are engine
  /// padding and the sentence pause rather than word gaps.
  static List<SilenceRun> interiorSilences(
    AudioBuffer buffer, {
    double thresholdDb = -50.0,
    double minDurationMs = 20.0,
  }) {
    final all = findSilences(
      buffer,
      thresholdDb: thresholdDb,
      minDurationMs: minDurationMs,
    );
    return all
        .where((r) => r.startFrame > 0 && r.endFrame < buffer.frameCount)
        .toList();
  }

  /// Largest absolute sample-to-sample jump.
  ///
  /// Splicing silence into audio without snapping to a quiet point or fading
  /// leaves a step discontinuity here, which is what a click *is*. Comparing
  /// this before and after the pipeline detects introduced clicks numerically,
  /// long before a human would notice one.
  static double maxDiscontinuity(Float32List samples) {
    var worst = 0.0;
    for (var i = 1; i < samples.length; i++) {
      final d = (samples[i] - samples[i - 1]).abs();
      if (d > worst) worst = d;
    }
    return worst;
  }

  static double rms(Float32List samples, int start, int length) {
    if (length <= 0) return 0;
    final end = math.min(start + length, samples.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += samples[i] * samples[i];
    }
    final n = end - start;
    return n <= 0 ? 0 : math.sqrt(sum / n);
  }

  static double peak(Float32List samples) {
    var worst = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > worst) worst = a;
    }
    return worst;
  }

  /// Frames where a single-sample impulse sits, used by the remap tests.
  static List<int> findImpulses(Float32List samples, {double threshold = 0.5}) {
    final out = <int>[];
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].abs() >= threshold) out.add(i);
    }
    return out;
  }
}
