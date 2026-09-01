import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

void main() {
  group('sentence pause', () {
    test('appends the requested silence', () {
      final fixture = syntheticSpeech(words: 3, wordMs: 200);
      const pauseMs = 350;

      final out = const SentencePauseStage(pauseMs)
          .process(fixture.audio, fixture.timings);

      expect(
        out.audio.frameCount,
        fixture.audio.frameCount + fixture.audio.msToFrames(pauseMs),
      );
    });

    test('appending never moves existing frames', () {
      final fixture = syntheticSpeech(words: 3, wordMs: 200);
      final out =
          const SentencePauseStage(500).process(fixture.audio, fixture.timings);

      for (final t in fixture.timings) {
        expect(out.remap(t.frameStart), t.frameStart);
        expect(out.remap(t.frameEnd), t.frameEnd);
      }
    });

    test('preserves the original samples exactly', () {
      final fixture = syntheticSpeech(words: 2, wordMs: 100);
      final out =
          const SentencePauseStage(200).process(fixture.audio, fixture.timings);

      for (var i = 0; i < fixture.audio.frameCount; i++) {
        expect(out.audio.samples[i], fixture.audio.samples[i]);
      }
      for (var i = fixture.audio.frameCount;
          i < out.audio.frameCount;
          i++) {
        expect(out.audio.samples[i], 0.0);
      }
    });

    test('zero pause is a no-op', () {
      final fixture = syntheticSpeech();
      final out =
          const SentencePauseStage(0).process(fixture.audio, fixture.timings);
      expect(out.audio.samples, same(fixture.audio.samples));
    });
  });

  group('edge trim', () {
    test('removes engine lead-in silence but keeps a short run-up', () {
      final speech = syntheticSpeech(words: 2, wordMs: 150, enveloped: true);
      final padFrames = speech.audio.msToFrames(120);

      final padded = AudioBuffer(
        Float32List.fromList([
          ...List<double>.filled(padFrames, 0.0),
          ...speech.audio.samples,
        ]),
        speech.audio.sampleRate,
      );

      final out = const EdgeTrimStage().process(padded, const []);

      expect(out.audio.frameCount, lessThan(padded.frameCount));
      // The keepLead window (5 ms) must survive, so the first phoneme's attack
      // is not clipped.
      final removed = padded.frameCount - out.audio.frameCount;
      expect(removed, lessThan(padFrames));
      expect(padded.framesToMs(padFrames - removed), closeTo(5, 2));
    });

    test('leaves an entirely silent buffer alone', () {
      final silent = AudioBuffer(Float32List(1000), kRate);
      final out = const EdgeTrimStage().process(silent, const []);
      expect(out.audio.frameCount, 1000);
    });

    test('can be disabled', () {
      final speech = syntheticSpeech(words: 2, wordMs: 100);
      final padded = AudioBuffer(
        Float32List.fromList([
          ...List<double>.filled(2000, 0.0),
          ...speech.audio.samples,
        ]),
        kRate,
      );
      final out =
          const EdgeTrimStage(enabled: false).process(padded, const []);
      expect(out.audio.frameCount, padded.frameCount);
    });
  });
}
