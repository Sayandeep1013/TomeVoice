import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// A tone of [hz] for [ms], at [rate].
Float32List tone(double hz, int ms, {int rate = kRate, double amplitude = 0.5}) {
  final n = rate * ms ~/ 1000;
  return Float32List.fromList([for (var i = 0; i < n; i++) amplitude * math.sin(2 * math.pi * hz * i / rate)]);
}

/// The pitch of [x] at [rate], from how often it crosses zero going up.
double pitchOf(Float32List x, int rate) {
  var ups = 0;
  for (var i = 1; i < x.length; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) ups++;
  }
  return ups * rate / x.length;
}

double rmsOf(Float32List x, [int from = 0, int? to]) => AudioAnalysis.rms(x, from, (to ?? x.length) - from);

void main() {
  group('time stretch that keeps the pitch (a narration at another speed)', () {
    for (final speed in [0.75, 1.5, 2.0, 3.0]) {
      test('${speed}x: the length goes with the speed and the pitch stays', () {
        final input = tone(220, 3000);
        final out = TimeStretchStage.stretch(input, kRate, speed);
        expect(out.length, (input.length / speed).round());
        expect(pitchOf(out, kRate), closeTo(220, 220 * 0.03));
        // No dip or swell in the level along the way.
        final level = rmsOf(input);
        for (var at = 0; at + kRate ~/ 10 <= out.length - kRate ~/ 20; at += kRate ~/ 10) {
          expect(rmsOf(out, at, at + kRate ~/ 10), closeTo(level, level * 0.12), reason: 'at frame $at');
        }
      });
    }

    test('the stub it stands beside moves the pitch with the speed', () {
      final input = tone(220, 2000);
      final out = const TimeStretchStubStage(2).process(AudioBuffer(input, kRate), const []).audio.samples;
      expect(pitchOf(out, kRate), closeTo(440, 15));
    });

    test('at 1x nothing changes', () {
      final input = AudioBuffer(tone(220, 500), kRate);
      final r = const TimeStretchStage(1.0).process(input, const []);
      expect(identical(r.audio, input), isTrue);
      expect(r.remap(1234), 1234);
    });

    test('word timings move with the speed', () {
      final fixture = syntheticSpeech(words: 4, wordMs: 400, naturalGapMs: 100);
      final out = Pipeline([const TimeStretchStage(2)]).run(resultOf(fixture.audio, fixture.timings));
      expect(out.audio.frameCount, (fixture.audio.frameCount / 2).round());
      for (var k = 0; k < fixture.timings.length; k++) {
        expect(out.wordTimings[k].frameStart, (fixture.timings[k].frameStart / 2).round());
        expect(out.wordTimings[k].frameEnd, (fixture.timings[k].frameEnd / 2).round());
      }
    });

    test('a pause in the recording stays a pause, shorter by the speed', () {
      final rate = kRate;
      final input = Float32List.fromList([...tone(200, 800), ...Float32List(rate * 400 ~/ 1000), ...tone(200, 800)]);
      final out = TimeStretchStage.stretch(input, rate, 2);
      final quiet = AudioAnalysis.interiorSilences(AudioBuffer(out, rate), minDurationMs: 50);
      expect(quiet, hasLength(1));
      expect(quiet.single.durationMs, closeTo(200, 25));
    });

    test('audio that stops in the middle of a sound is not given a click', () {
      // A clip of a narration can end mid-breath; slowed down, windows run
      // over its end.
      final input = tone(180, 1003);
      final jump = AudioAnalysis.maxDiscontinuity(input);
      for (final speed in [0.6, 0.75, 1.3, 2.5]) {
        final out = TimeStretchStage.stretch(input, kRate, speed);
        expect(AudioAnalysis.maxDiscontinuity(out), lessThan(jump * 1.5), reason: '${speed}x');
      }
    });

    test('very short audio is kept, cut to its length', () {
      final input = tone(220, 20);
      expect(TimeStretchStage.stretch(input, kRate, 2).length, (input.length / 2).round());
    });
  });

  group('band-limited resampling (a 44.1 kHz recording at the voices\' 24 kHz)', () {
    test('a voice-band tone keeps its pitch and its level', () {
      final input = tone(440, 1000, rate: 44100);
      final out = resampleBandLimited(input, 44100, 24000);
      expect(out.length, 24000);
      expect(pitchOf(out, 24000), closeTo(440, 3));
      expect(rmsOf(out, 200, out.length - 200), closeTo(rmsOf(input), 0.01));
    });

    test('sound above the new rate\'s half is taken out, not folded back in', () {
      // 16 kHz cannot be held at 24 kHz; straight lines fold it to 8 kHz.
      final input = tone(16000, 500, rate: 44100);
      final out = resampleBandLimited(input, 44100, 24000);
      expect(rmsOf(out, 200, out.length - 200), lessThan(0.01));
    });

    test('a lower rate brought up keeps its tone', () {
      final input = tone(300, 1000, rate: 16000);
      final out = resampleBandLimited(input, 16000, 24000);
      expect(out.length, 24000);
      expect(pitchOf(out, 24000), closeTo(300, 3));
      expect(rmsOf(out, 200, out.length - 200), closeTo(rmsOf(input), 0.01));
    });

    test('the same rate is the same audio', () {
      final input = tone(300, 100);
      expect(identical(resampleBandLimited(input, kRate, kRate), input), isTrue);
    });
  });

  group('the quietest moment near a place', () {
    test('a pause near the guess is found, not the guess itself', () {
      final x = Float32List.fromList([...tone(200, 1000), ...Float32List(kRate * 200 ~/ 1000), ...tone(200, 1000)]);
      final at = AudioAnalysis.quietestNear(x, kRate, near: kRate * 900 ~/ 1000, from: 0, to: x.length);
      expect(at, inInclusiveRange(kRate * 1020 ~/ 1000, kRate * 1180 ~/ 1000));
    });

    test('of two pauses, the one nearer the guess unless the other is far quieter', () {
      final quiet = Float32List(kRate * 200 ~/ 1000);
      final x = Float32List.fromList([...tone(200, 500), ...quiet, ...tone(200, 1500), ...quiet, ...tone(200, 500)]);
      final first = kRate * 600 ~/ 1000;
      final second = kRate * 2300 ~/ 1000;
      expect((AudioAnalysis.quietestNear(x, kRate, near: first + 2400, from: 0, to: x.length) - first).abs(),
          lessThan(kRate ~/ 10));
      expect((AudioAnalysis.quietestNear(x, kRate, near: second - 2400, from: 0, to: x.length) - second).abs(),
          lessThan(kRate ~/ 10));
    });

    test('kept between its bounds', () {
      final x = tone(200, 1000);
      final at = AudioAnalysis.quietestNear(x, kRate, near: 100, from: 2000, to: 4000);
      expect(at, inInclusiveRange(2000, 4000));
    });
  });
}
