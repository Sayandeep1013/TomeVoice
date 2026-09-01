import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// The analysis helpers are the measuring instrument for every other test and
/// for the on-device verification. If they are wrong, everything they certify
/// is worthless — so they get tested against buffers whose answers are known by
/// construction.
void main() {
  group('silence detection', () {
    test('finds a silence of known length', () {
      const rate = kRate;
      final samples = Float32List(rate); // 1 second
      // Tone for 400 ms, silence for 200 ms, tone for 400 ms.
      void fill(int from, int to) {
        for (var i = from; i < to; i++) {
          samples[i] = 0.6 * ((i % 50) < 25 ? 1 : -1);
        }
      }

      final a = (0.4 * rate).round();
      final b = (0.6 * rate).round();
      fill(0, a);
      fill(b, rate);

      final runs = AudioAnalysis.findSilences(
        AudioBuffer(samples, rate),
        windowMs: 1,
      );

      expect(runs, hasLength(1));
      expect(runs.single.durationMs, closeTo(200, 5));
    });

    test('ignores silences shorter than the minimum', () {
      const rate = kRate;
      final samples = Float32List(rate);
      for (var i = 0; i < rate; i++) {
        samples[i] = 0.5;
      }
      // A 5 ms hole, below the 20 ms floor.
      for (var i = 1000; i < 1000 + (rate * 5 ~/ 1000); i++) {
        samples[i] = 0;
      }

      final runs = AudioAnalysis.findSilences(
        AudioBuffer(samples, rate),
        minDurationMs: 20,
        windowMs: 1,
      );
      expect(runs, isEmpty);
    });

    test('interiorSilences excludes leading and trailing silence', () {
      const rate = kRate;
      final samples = Float32List(rate);
      // Silent | tone | silent | tone | silent
      void fill(int from, int to) {
        for (var i = from; i < to; i++) {
          samples[i] = 0.6 * ((i % 50) < 25 ? 1 : -1);
        }
      }

      fill(2000, 8000);
      fill(12000, 18000);

      final buffer = AudioBuffer(samples, rate);
      final all = AudioAnalysis.findSilences(buffer, windowMs: 1);
      final interior = AudioAnalysis.interiorSilences(buffer);

      expect(all.length, greaterThan(interior.length));
      expect(interior, hasLength(1));
      expect(interior.single.durationMs, closeTo(4000 * 1000 / rate, 5));
    });

    test('an all-silent buffer is one run', () {
      final runs = AudioAnalysis.findSilences(
        AudioBuffer(Float32List(1000), kRate),
      );
      expect(runs, hasLength(1));
      expect(runs.single.frameCount, 1000);
    });

    test('threshold is relative to peak, so loud and quiet voices agree', () {
      final loud = syntheticSpeech(words: 3, wordMs: 150, naturalGapMs: 100);
      final quietSamples = Float32List(loud.audio.frameCount);
      for (var i = 0; i < quietSamples.length; i++) {
        quietSamples[i] = loud.audio.samples[i] * 0.02; // ~34 dB quieter
      }

      final loudRuns = AudioAnalysis.interiorSilences(loud.audio);
      final quietRuns = AudioAnalysis.interiorSilences(
        AudioBuffer(quietSamples, loud.audio.sampleRate),
      );

      expect(quietRuns.length, loudRuns.length);
    });
  });

  group('discontinuity', () {
    test('a smooth signal measures low', () {
      final fixture = syntheticSpeech(words: 3, wordMs: 150, enveloped: true);
      expect(AudioAnalysis.maxDiscontinuity(fixture.audio.samples),
          lessThan(0.1));
    });

    test('a hard splice measures high', () {
      final samples = Float32List.fromList([0.0, 0.1, 0.2, -0.9, 0.2, 0.1]);
      expect(AudioAnalysis.maxDiscontinuity(samples), closeTo(1.1, 1e-6));
    });
  });

  group('rms and peak', () {
    test('rms of a constant equals its magnitude', () {
      final s = Float32List.fromList(List<double>.filled(100, 0.5));
      expect(AudioAnalysis.rms(s, 0, 100), closeTo(0.5, 1e-6));
    });

    test('rms of silence is zero', () {
      expect(AudioAnalysis.rms(Float32List(100), 0, 100), 0.0);
    });

    test('rms clamps a window that runs past the end', () {
      final s = Float32List.fromList(List<double>.filled(10, 1.0));
      expect(AudioAnalysis.rms(s, 5, 1000), closeTo(1.0, 1e-6));
    });

    test('peak finds the largest magnitude regardless of sign', () {
      final s = Float32List.fromList([0.1, -0.9, 0.3]);
      expect(AudioAnalysis.peak(s), closeTo(0.9, 1e-6));
    });
  });

  group('impulse finding', () {
    test('locates every impulse', () {
      final fixture = impulseMarked(words: 5, wordMs: 100);
      expect(
        AudioAnalysis.findImpulses(fixture.audio.samples),
        fixture.impulses,
      );
    });
  });
}
