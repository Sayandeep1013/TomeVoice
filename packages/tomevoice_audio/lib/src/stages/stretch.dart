import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// Speech made faster or slower with its pitch kept: WSOLA (waveform
/// similarity overlap-add).
///
/// The audio is laid down again in overlapping 30 ms windows, each taken
/// from the input at the new pace and moved by up to 10 ms to where its
/// waveform best carries on the one before it, so the voice's own pitch
/// periods line up and nothing is resampled. [TimeStretchStubStage]
/// resamples, which moves the pitch with the speed; a voice the engine
/// speeds itself (a phone's, a natural one) needs neither. This is for
/// audio that comes as it was recorded: a book's own narration.
class TimeStretchStage implements PipelineStage {
  const TimeStretchStage(this.speed);

  /// Greater than 1.0 is faster: shorter audio.
  final double speed;

  @override
  String get name => 'stretch';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    if ((speed - 1.0).abs() < 1e-3 || speed <= 0 || input.frameCount == 0) {
      return StageResult.unchanged(input);
    }
    final out = stretch(input.samples, input.sampleRate, speed);
    final length = out.length;
    int remap(int frame) => (frame / speed).round().clamp(0, length);
    return StageResult(input.withSamples(out), remap);
  }

  /// [x] at [rate] played [speed] times as fast, its pitch kept.
  static Float32List stretch(Float32List x, int rate, double speed) {
    final length = (x.length / speed).round();
    final window = math.max(4, (rate * 0.030).round() & ~1);
    final hop = window ~/ 2;
    final reach = math.max(1, (rate * 0.010).round());
    if (x.length < window * 2 || length < window) return _plain(x, length);

    // Room past the end to read into, so no bounds are checked inside: the
    // end mirrored, so a window that runs over it carries on smoothly
    // instead of dropping to silence mid-way (a click, where a clip ends in
    // the middle of a sound).
    final src = Float32List(x.length + window + 2 * reach + hop)..setRange(0, x.length, x);
    for (var j = 0; x.length + j < src.length && j < x.length; j++) {
      src[x.length + j] = x[x.length - 1 - j];
    }
    final out = Float32List(length + window);
    final shape = Float64List(window);
    for (var n = 0; n < window; n++) {
      shape[n] = 0.5 - 0.5 * math.cos(2 * math.pi * n / window);
    }

    final last = x.length - 1;
    var prev = 0;
    for (var k = 0; k * hop < length; k++) {
      final at = k * hop;
      var pos = 0;
      if (k > 0) {
        final ideal = (k * hop * speed).round();
        final natural = prev + hop;
        final lo = math.max(0, ideal - reach);
        final hi = math.min(last, ideal + reach);
        pos = lo > hi ? math.min(ideal, last) : _bestMatch(src, natural, lo, hi, hop);
      }
      for (var n = 0; n < window; n++) {
        // The first window comes in whole: no fade from silence at the start.
        final w = k == 0 && n < hop ? 1.0 : shape[n];
        out[at + n] += src[pos + n] * w;
      }
      prev = pos;
    }
    return Float32List.sublistView(out, 0, length);
  }

  /// Where in [lo, hi] a window starts whose first [hop] samples look most
  /// like those at [natural] (the way the last window would have gone on):
  /// their correlation, for the candidate's own loudness, every second
  /// sample; looked for every second place, then beside the best.
  static int _bestMatch(Float32List src, int natural, int lo, int hi, int hop) {
    double score(int p) {
      var dot = 0.0;
      var energy = 1e-9;
      for (var n = 0; n < hop; n += 2) {
        final b = src[p + n];
        dot += src[natural + n] * b;
        energy += b * b;
      }
      return dot / math.sqrt(energy);
    }

    var best = lo;
    var top = double.negativeInfinity;
    for (var p = lo; p <= hi; p += 2) {
      final s = score(p);
      if (s > top) {
        top = s;
        best = p;
      }
    }
    for (final p in [best - 1, best + 1]) {
      if (p < lo || p > hi) continue;
      final s = score(p);
      if (s > top) {
        top = s;
        best = p;
      }
    }
    return best;
  }

  /// Too short for windows: taken as it is, cut or padded to [length].
  static Float32List _plain(Float32List x, int length) {
    final out = Float32List(length);
    out.setRange(0, math.min(length, x.length), x);
    return out;
  }
}
