import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// A [hz] tone at [amplitude] for [ms]. 240 Hz is exactly 100 samples a
/// cycle at 24 kHz, so a whole number of cycles has no leakage between the
/// bins the distortion is read from.
Float32List tone(double amplitude, {int ms = 1000, double hz = 240}) => Float32List.fromList([
      for (var i = 0; i < kRate * ms ~/ 1000; i++) amplitude * math.sin(2 * math.pi * hz * i / kRate),
    ]);

/// Total harmonic distortion of [x] around [hz]: harmonics 2 to 10 against
/// the fundamental, over [from, to) (whole cycles, once the gain has settled).
double thd(Float32List x, {double hz = 240, int from = 6000, int to = 18000}) {
  double magnitude(double f) {
    var re = 0.0;
    var im = 0.0;
    for (var i = from; i < to; i++) {
      final a = 2 * math.pi * f * i / kRate;
      re += x[i] * math.cos(a);
      im -= x[i] * math.sin(a);
    }
    return math.sqrt(re * re + im * im);
  }

  final fundamental = magnitude(hz);
  var harmonics = 0.0;
  for (var k = 2; k <= 10; k++) {
    final m = magnitude(hz * k);
    harmonics += m * m;
  }
  return math.sqrt(harmonics) / fundamental;
}

void main() {
  group('compression', () {
    for (final c in [Compression.light, Compression.strong]) {
      for (final normalise in [true, false]) {
        test('${c.name} compression keeps a full-scale tone clean (normalise $normalise)', () {
          final out = GainStage(compression: c, normalise: normalise)
              .process(AudioBuffer(tone(1.0), kRate), const [])
              .audio
              .samples;
          // Bending each sample by its own size gave 7% here (13.5% at Strong).
          expect(thd(out), lessThan(0.01), reason: 'THD ${(thd(out) * 100).toStringAsFixed(2)}%');
        });
      }
    }

    test('lowers what is loud and leaves what is quiet', () {
      final loud = GainStage(compression: Compression.strong, normalise: false)
          .process(AudioBuffer(tone(0.9), kRate), const [])
          .audio
          .samples;
      final soft = GainStage(compression: Compression.strong, normalise: false)
          .process(AudioBuffer(tone(0.05), kRate), const [])
          .audio
          .samples;
      final loudGain = AudioAnalysis.rms(loud, 6000, 12000) / (0.9 / math.sqrt2);
      final softGain = AudioAnalysis.rms(soft, 6000, 12000) / (0.05 / math.sqrt2);
      expect(loudGain, lessThan(0.6));
      expect(softGain, closeTo(1.19, 0.05), reason: 'only the makeup gain, 1.5 dB');
    });
  });

  group('limiter', () {
    test('nothing passes the ceiling, even pushed hard, and nothing is clipped', () {
      for (final hz in [100.0, 240.0, 1000.0]) {
        final out = const GainStage(volume: 4, normalise: false, compression: Compression.off)
            .process(AudioBuffer(tone(0.9, hz: hz), kRate), const [])
            .audio
            .samples;
        expect(AudioAnalysis.peak(out), lessThanOrEqualTo(0.89 + 1e-6), reason: '$hz Hz');
        expect(AudioAnalysis.peak(out), greaterThan(0.8), reason: 'held at the ceiling, not far under it');
      }
    });

    test('a steady tone pushed into it stays clean', () {
      final out = const GainStage(volume: 3, normalise: false, compression: Compression.off)
          .process(AudioBuffer(tone(0.9), kRate), const [])
          .audio
          .samples;
      expect(thd(out), lessThan(0.01), reason: 'THD ${(thd(out) * 100).toStringAsFixed(2)}%');
    });

    test('a single loud click is caught without touching the rest', () {
      final x = tone(0.3, ms: 400);
      x[4800] = 1.0;
      final out = const GainStage(normalise: false, compression: Compression.off)
          .process(AudioBuffer(x, kRate), const [])
          .audio
          .samples;
      expect(out[4800].abs(), lessThanOrEqualTo(0.89 + 1e-6));
      // Well before it and well after it, the tone is as it was.
      expect(out[2000], closeTo(x[2000], 1e-6));
      expect(out[9000], closeTo(x[9000], 1e-3));
    });
  });

  group('loudness levelling', () {
    test('a quiet voice and a loud one come out at the same level', () {
      for (final amplitude in [0.02, 0.2, 0.95]) {
        final out = const GainStage(compression: Compression.off)
            .process(AudioBuffer(tone(amplitude), kRate), const [])
            .audio
            .samples;
        expect(GainStage.speechLevelDb(out, kRate), closeTo(GainStage.defaultLevelDb, 0.3), reason: 'from $amplitude');
      }
    });

    test('measured on the voice: pauses do not make a sentence quieter', () {
      final speech = syntheticSpeech(words: 6, wordMs: 200);
      final paused = syntheticSpeech(words: 6, wordMs: 200, naturalGapMs: 300);
      expect(GainStage.speechLevelDb(paused.audio.samples, kRate),
          closeTo(GainStage.speechLevelDb(speech.audio.samples, kRate)!, 0.2));
    });

    test('silence is left alone, and nothing is lifted into hiss', () {
      expect(GainStage.levelGainDb(Float32List(2400), kRate), 0);
      // About -53 dB: 35 dB under the level, lifted only 20.
      expect(GainStage.levelGainDb(tone(0.003), kRate), GainStage.maxLevelDb);
    });

    test('from sentence to sentence the level moves half way, not all at once', () {
      expect(GainStage.smoothedGainDb(null, 6), 6);
      expect(GainStage.smoothedGainDb(6, 2), 4);
      // A gain worked out by the reader is the one used.
      final out = GainStage(compression: Compression.off, gainDb: -6)
          .process(AudioBuffer(tone(0.5), kRate), const [])
          .audio
          .samples;
      expect(AudioAnalysis.peak(out), closeTo(0.5 * 0.501, 0.01));
    });
  });

  group('edges', () {
    test("the engine's trailing silence is trimmed, keeping a short tail", () {
      final speech = syntheticSpeech(words: 2, wordMs: 150, enveloped: true);
      final tail = speech.audio.msToFrames(400);
      final padded = AudioBuffer(
        Float32List.fromList([...speech.audio.samples, ...List<double>.filled(tail, 0.0)]),
        kRate,
      );
      final out = const EdgeTrimStage().process(padded, speech.timings);
      final kept = out.audio.frameCount - speech.audio.frameCount;
      expect(padded.framesToMs(kept), closeTo(40, 6));
      // A word reported to run into the tail ends at the new end.
      expect(out.remap(padded.frameCount), out.audio.frameCount);
    });

    test('so the pause after a sentence is the one set, not that plus the tail', () {
      final speech = syntheticSpeech(words: 3, wordMs: 150, enveloped: true);
      final padded = AudioBuffer(
        Float32List.fromList([...speech.audio.samples, ...List<double>.filled(speech.audio.msToFrames(300), 0.0)]),
        kRate,
      );
      const settings = PipelineSettings(sentencePauseMs: 350, normaliseLoudness: false, compression: Compression.off);
      final out = buildStandardPipeline(settings).run(resultOf(padded, speech.timings));
      final pause = out.audio.frameCount - speech.audio.frameCount;
      expect(padded.framesToMs(pause), closeTo(390, 8));
    });
  });
}
