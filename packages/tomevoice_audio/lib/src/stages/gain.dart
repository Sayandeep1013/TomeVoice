import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis.dart';
import '../pipeline.dart';
import '../types.dart';

enum Compression { off, light, strong }

/// Volume, per-voice trim, loudness levelling, compression and a limiter.
///
/// Loudness levelling is not a luxury here. Open TTS voices differ by more than
/// 10 dB in output level, so switching voice mid-book without it is genuinely
/// unpleasant — and on a device the user has already set a comfortable system
/// volume for, it is the app's job to be consistent, not theirs
/// (docs/05 section 5.5).
///
/// The level is the voice's measured loudness, not its loudest sample: one
/// sharp consonant used to set the gain of a whole sentence. The compressor
/// follows the level of the voice over a few milliseconds and moves its gain
/// smoothly; the one before bent each sample by its own size, which is a
/// distortion (7% on a pure tone, 13.5% at Strong). A limiter that sees each
/// peak coming catches what is left, so nothing is ever clipped.
///
/// Changes no frame positions, so its remap is the identity.
class GainStage implements PipelineStage {
  const GainStage({
    this.volume = 1.0,
    this.trimDb = 0.0,
    this.normalise = true,
    this.targetLevelDb = defaultLevelDb,
    this.ceiling = 0.89, // about -1 dBFS
    this.compression = Compression.light,
    this.gainDb,
  });

  /// The level voices are brought to: the mean power of their voiced
  /// moments, in dB below full scale. A meter would call it about -18 LUFS
  /// (no K-weighting: for speech the two are within a decibel), which leaves
  /// a voice's peaks room under the ceiling.
  static const defaultLevelDb = -18.0;

  /// The most a quiet voice is lifted, or a loud one lowered, in dB: past
  /// this, a nearly silent buffer would be lifted into hiss.
  static const maxLevelDb = 20.0;

  /// Master volume, 0..1, on top of the system volume.
  final double volume;

  /// Per-voice correction in dB, so a quiet voice can be brought up to sit
  /// alongside a loud one.
  final double trimDb;

  final bool normalise;

  /// See [defaultLevelDb].
  final double targetLevelDb;

  /// Nothing leaves louder than this: the limiter's ceiling.
  final double ceiling;

  final Compression compression;

  /// The levelling gain in dB when the caller has worked it out (smoothed
  /// from sentence to sentence); null measures this buffer alone.
  final double? gainDb;

  @override
  String get name => 'gain';

  /// The voiced level of [samples] in dB below full scale, or null for
  /// silence. Measured in 20 ms blocks with silence and the quiet edges of
  /// words gated out, as loudness meters do, so a sentence with long pauses
  /// is not taken for a quiet one.
  static double? speechLevelDb(Float32List samples, int sampleRate) {
    final block = math.max(1, sampleRate ~/ 50);
    final powers = <double>[];
    for (var a = 0; a < samples.length; a += block) {
      final b = math.min(samples.length, a + block);
      var sum = 0.0;
      for (var i = a; i < b; i++) {
        sum += samples[i] * samples[i];
      }
      final p = sum / (b - a);
      if (p > 1e-6) powers.add(p); // above -60 dBFS
    }
    if (powers.isEmpty) return null;
    final mean = powers.reduce((a, b) => a + b) / powers.length;
    var sum = 0.0;
    var n = 0;
    for (final p in powers) {
      if (p >= mean * 0.01) {
        // within 20 dB of the mean
        sum += p;
        n++;
      }
    }
    return 10 * math.log(sum / n) / math.ln10;
  }

  /// The gain in dB that brings [samples] to [targetDb] (0 for silence).
  static double levelGainDb(Float32List samples, int sampleRate, {double targetDb = defaultLevelDb}) {
    final level = speechLevelDb(samples, sampleRate);
    if (level == null) return 0;
    return (targetDb - level).clamp(-maxLevelDb, maxLevelDb).toDouble();
  }

  /// [previousDb] moved toward [targetDb]: a sentence's own measure varies
  /// with what it says, so each one goes half way, and the level drifts
  /// rather than jumping. The first of a run ([previousDb] null) goes all the way.
  static double smoothedGainDb(double? previousDb, double targetDb) =>
      previousDb == null ? targetDb : previousDb + (targetDb - previousDb) * 0.5;

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    final src = input.samples;
    if (src.isEmpty) return StageResult.unchanged(input);

    var db = trimDb;
    if (normalise) {
      db += gainDb ?? levelGainDb(src, input.sampleRate, targetDb: targetLevelDb);
    }
    final gain = volume * math.pow(10, db / 20).toDouble();
    if (gain <= 0) return StageResult(input.withSamples(Float32List(src.length)), identityRemap);

    // Unity gain, no compression and nothing over the ceiling means nothing
    // to do; skip rather than rewriting the buffer for no reason.
    if ((gain - 1.0).abs() < 1e-6 && compression == Compression.off && AudioAnalysis.peak(src) <= ceiling) {
      return StageResult.unchanged(input);
    }

    final out = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      out[i] = src[i] * gain;
    }
    if (compression != Compression.off) _compress(out, input.sampleRate);
    _limit(out, input.sampleRate);
    return StageResult(input.withSamples(out), identityRemap);
  }

  /// Lowers the loud parts of the voice above a threshold near its level:
  /// gently (2:1, only the loudest syllables) at Light, firmly (4:1, most of
  /// the voice) at Strong. A soft knee, and a gain that follows the voice's
  /// power over about 20 ms and moves smoothly (5 ms down, 120 ms back up),
  /// so a held vowel is lowered evenly instead of having its waveform bent.
  /// Compression helps a lot in a car or on a train, which is a primary
  /// listening context.
  void _compress(Float32List x, int rate) {
    final light = compression == Compression.light;
    final threshold = targetLevelDb + (light ? 6.0 : 1.0);
    final slope = 1 - 1 / (light ? 2.0 : 4.0);
    const knee = 6.0;
    final makeup = light ? 0.5 : 1.5;
    final average = 1 - math.exp(-1 / (0.020 * rate));
    final down = 1 - math.exp(-1 / (0.005 * rate));
    final up = 1 - math.exp(-1 / (0.120 * rate));
    // Start settled at the target level: no swell on the first word.
    var power = math.pow(10, targetLevelDb / 10).toDouble();
    var reduce = 0.0;
    for (var i = 0; i < x.length; i++) {
      power += average * (x[i] * x[i] - power);
      final over = 10 * math.log(power + 1e-12) / math.ln10 - threshold;
      final double want;
      if (over <= -knee / 2) {
        want = 0;
      } else if (over >= knee / 2) {
        want = slope * over;
      } else {
        final k = over + knee / 2;
        want = slope * k * k / (2 * knee);
      }
      reduce += (want > reduce ? down : up) * (want - reduce);
      x[i] *= math.pow(10, (makeup - reduce) / 20).toDouble();
    }
  }

  /// Keeps every sample at or under [ceiling] without clipping: the gain
  /// starts down 5 ms before a peak and eases into it, then comes back over
  /// about 60 ms. (The gain at each sample is the mean of the least gain
  /// needed over the next 5 ms, taken over the last 5 ms, which is never
  /// more than that sample itself needs.)
  void _limit(Float32List x, int rate) {
    final n = x.length;
    var over = false;
    for (final v in x) {
      if (v.abs() > ceiling) {
        over = true;
        break;
      }
    }
    if (!over) return;

    final ahead = math.max(1, (0.005 * rate).round());
    final need = Float32List(n);
    for (var i = 0; i < n; i++) {
      final a = x[i].abs();
      need[i] = a > ceiling ? ceiling / a : 1.0;
    }
    // The least need over [i, i + ahead]: a sliding minimum, back to front.
    final least = Float32List(n);
    final queue = Int32List(n);
    var head = 0;
    var tail = 0;
    for (var i = n - 1; i >= 0; i--) {
      while (tail > head && need[queue[tail - 1]] >= need[i]) {
        tail--;
      }
      queue[tail++] = i;
      while (queue[head] > i + ahead) {
        head++;
      }
      least[i] = need[queue[head]];
    }
    final release = 1 - math.exp(-1 / (0.060 * rate));
    var sum = 0.0;
    var g = 1.0;
    for (var i = 0; i < n; i++) {
      sum += least[i];
      if (i >= ahead) sum -= least[i - ahead];
      final eased = sum / math.min(i + 1, ahead);
      g = math.min(eased, g + release * (1 - g));
      x[i] = (x[i] * g).clamp(-1.0, 1.0);
    }
  }
}
