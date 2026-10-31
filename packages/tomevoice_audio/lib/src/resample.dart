import 'dart:math' as math;
import 'dart:typed_data';

/// [x] at [from] Hz as [to] Hz, band-limited: each output sample is the
/// input under a windowed sinc cut off just below half the lower rate.
///
/// Straight-line interpolation (dialogue.dart's resample) is fine between
/// two voices' close rates, but a recording at 44.1 or 48 kHz brought down
/// to the voices' 24 kHz with it folds everything above 12 kHz back down
/// into the voice as a hiss. Here those sounds are filtered out first.
Float32List resampleBandLimited(Float32List x, int from, int to) {
  if (from == to || x.isEmpty) return x;
  final ratio = to / from;
  final n = (x.length * ratio).round();
  final out = Float32List(n);
  if (n == 0) return out;
  final kernel = _Kernel.of(math.min(1.0, ratio));
  final half = kernel.half;
  final step = 1 / ratio;
  for (var i = 0; i < n; i++) {
    final centre = i * step;
    final first = math.max(0, (centre - half).ceil());
    final last = math.min(x.length - 1, (centre + half).floor());
    var sum = 0.0;
    var weights = 0.0;
    for (var j = first; j <= last; j++) {
      final w = kernel.at((j - centre).abs());
      sum += x[j] * w;
      weights += w;
    }
    // Divided by the weights it had: no ripple in the level, and the edges,
    // where part of the kernel falls outside the input, are not faded.
    out[i] = weights.abs() < 1e-9 ? 0 : sum / weights;
  }
  return out;
}

/// A sinc cut off at [cutoff] of the input's own half rate, under a
/// Blackman window, tabulated finely enough to read between its points.
class _Kernel {
  _Kernel._(this.half, this._table);

  /// How far it reaches each side, in input samples.
  final double half;
  final Float64List _table;

  static const _zeros = 12;
  static const _perSample = 256;
  static final _made = <double, _Kernel>{};

  static _Kernel of(double share) => _made.putIfAbsent(share, () {
        // Cycles per input sample, a little under the lower rate's half.
        final fc = 0.5 * share * 0.94;
        final half = _zeros / (2 * fc);
        final size = (half * _perSample).ceil() + 2;
        final table = Float64List(size);
        for (var k = 0; k < size; k++) {
          final t = k / _perSample;
          if (t > half) break;
          final x = 2 * fc * t;
          final sinc = x == 0 ? 1.0 : math.sin(math.pi * x) / (math.pi * x);
          final u = t / half;
          final window = 0.42 + 0.5 * math.cos(math.pi * u) + 0.08 * math.cos(2 * math.pi * u);
          table[k] = 2 * fc * sinc * window;
        }
        return _Kernel._(half, table);
      });

  /// The kernel [t] input samples from its centre.
  double at(double t) {
    final p = t * _perSample;
    final k = p.floor();
    if (k + 1 >= _table.length) return 0;
    final f = p - k;
    return _table[k] * (1 - f) + _table[k + 1] * f;
  }
}
