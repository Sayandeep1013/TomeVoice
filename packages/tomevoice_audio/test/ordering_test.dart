import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// Stage order is load-bearing, and the failure is silent.
///
/// If word-gap injection runs *before* time stretching, the inserted silence is
/// stretched along with the speech: a 120 ms gap becomes 60 ms at 2x speed, and
/// the user's setting quietly stops meaning what it says.
///
/// These tests encode the bug as well as the fix, so a future refactor that
/// reorders the stages fails loudly instead of degrading the feature.
void main() {
  group('stage ordering (S2)', () {
    const gapMs = 120;
    const speed = 2.0;

    test('stretch then gap keeps the gap at its requested duration', () {
      final fixture = syntheticSpeech(words: 5, wordMs: 300);

      final correct = Pipeline([
        const TimeStretchStubStage(speed),
        WordGapStage(const PipelineSettings(
          wordGapMs: gapMs,
          speedScale: speed,
          snapSearchMs: 0,
          crossfadeMs: 2,
        )),
      ]);

      final out = correct.run(resultOf(fixture.audio, fixture.timings));
      final silences =
          AudioAnalysis.interiorSilences(out.audio, minDurationMs: 20);

      expect(silences, hasLength(4));
      for (final run in silences) {
        expect(run.durationMs, closeTo(gapMs, 5.0));
      }
    });

    test('gap then stretch halves the gap — the bug this order prevents', () {
      final fixture = syntheticSpeech(words: 5, wordMs: 300);

      final wrong = Pipeline([
        WordGapStage(const PipelineSettings(
          wordGapMs: gapMs,
          snapSearchMs: 0,
          crossfadeMs: 2,
        )),
        const TimeStretchStubStage(speed),
      ]);

      final out = wrong.run(resultOf(fixture.audio, fixture.timings));
      final silences =
          AudioAnalysis.interiorSilences(out.audio, minDurationMs: 20);

      expect(silences, hasLength(4));
      for (final run in silences) {
        expect(
          run.durationMs,
          closeTo(gapMs / speed, 5.0),
          reason: 'demonstrates why gap must follow stretch',
        );
      }
    });

    test('the shipped pipeline uses the correct order', () {
      final pipeline = buildStandardPipeline(const PipelineSettings());
      final names = pipeline.stages.map((s) => s.name).toList();

      expect(names.first, 'edges',
          reason: 'edge trim must run before anything inserts silence');
      expect(names.indexOf('stretch_stub'), lessThan(names.indexOf('word_gap')),
          reason: 'time stretch must precede word gap');
      expect(names.indexOf('word_gap'),
          lessThan(names.indexOf('sentence_pause')));
    });

    test('inserted silence survives edge trimming (device-run regression)', () {
      // Reproduces what the first device run actually produced.
      //
      // Google TTS delivers onRangeStart as (frame, charStart, charEnd), not
      // the documented (charStart, charEnd, frame). Misreading it put every
      // word at frames 3, 9, 15, 19 - all bunched at the very start - so every
      // gap was inserted before any audio. Edge trim then removed the lot,
      // because at that point it is indistinguishable from engine lead-in.
      //
      // The parameter order is fixed in the app. This pins the pipeline against
      // the same shape of failure from any other source of bad timings: with
      // edge trim running first, inserted silence can never be mistaken for
      // padding.
      final speech = syntheticSpeech(words: 4, wordMs: 200, enveloped: true);
      final leadFrames = speech.audio.msToFrames(100);
      final padded = AudioBuffer(
        Float32List.fromList([
          ...List<double>.filled(leadFrames, 0.0),
          ...speech.audio.samples,
        ]),
        speech.audio.sampleRate,
      );

      // Timings bunched near frame zero, exactly as the misread values were.
      final bunched = [
        for (var i = 0; i < speech.timings.length; i++)
          speech.timings[i].copyWithFrames(i * 6, i * 6 + 3),
      ];

      const settings = PipelineSettings(
        wordGapMs: 150,
        sentencePauseMs: 0,
        snapSearchMs: 0,
        crossfadeMs: 2,
      );
      final shipped =
          buildStandardPipeline(settings).run(resultOf(padded, bunched));

      final trimLast = Pipeline([
        const TimeStretchStubStage(1.0),
        const WordGapStage(settings),
        const EdgeTrimStage(),
      ]).run(resultOf(padded, bunched));

      // Trimming last removes every gap, because by then they sit in front of
      // the first audible sample and are indistinguishable from engine padding.
      // Trimming first cannot make that mistake.
      //
      // Note it does not rescue all three gaps either: trimming shifts the
      // bunched timings to zero, and the gap stage then correctly declines to
      // insert where words have collapsed onto one frame. Preserving *more* is
      // the honest claim; preserving everything would not be true.
      expect(
        shipped.audio.frameCount,
        greaterThan(trimLast.audio.frameCount),
        reason: 'trimming first must lose less than trimming last',
      );
    });

    test('with sound timings, trim position does not change the audio length',
        () {
      // The honest counterpart to the test above: when timings are correct,
      // gaps land between words and edge-trim order makes no difference. The
      // reorder is defensive hardening, not a fix for everyday operation, and
      // saying otherwise in a test name would be a lie.
      final speech = syntheticSpeech(words: 4, wordMs: 200, enveloped: true);
      final leadFrames = speech.audio.msToFrames(100);
      final padded = AudioBuffer(
        Float32List.fromList([
          ...List<double>.filled(leadFrames, 0.0),
          ...speech.audio.samples,
        ]),
        speech.audio.sampleRate,
      );
      final shifted = [
        for (final t in speech.timings)
          t.copyWithFrames(t.frameStart + leadFrames, t.frameEnd + leadFrames),
      ];

      const settings = PipelineSettings(
        wordGapMs: 150,
        sentencePauseMs: 0,
        snapSearchMs: 0,
        crossfadeMs: 2,
      );

      final shipped =
          buildStandardPipeline(settings).run(resultOf(padded, shifted));
      final trimLast = Pipeline([
        const TimeStretchStubStage(1.0),
        const WordGapStage(settings),
        const EdgeTrimStage(),
      ]).run(resultOf(padded, shifted));

      expect(trimLast.audio.frameCount, shipped.audio.frameCount);
    });

    test('gap survives a range of speeds unchanged', () {
      for (final speedScale in [0.75, 1.5, 2.0, 3.0]) {
        final fixture = syntheticSpeech(words: 4, wordMs: 400);

        final out = Pipeline([
          TimeStretchStubStage(speedScale),
          WordGapStage(PipelineSettings(
            wordGapMs: gapMs,
            speedScale: speedScale,
            snapSearchMs: 0,
            crossfadeMs: 2,
          )),
        ]).run(resultOf(fixture.audio, fixture.timings));

        final silences =
            AudioAnalysis.interiorSilences(out.audio, minDurationMs: 20);

        expect(silences, hasLength(3), reason: 'at ${speedScale}x');
        for (final run in silences) {
          expect(run.durationMs, closeTo(gapMs, 5.0),
              reason: 'gap drifted at ${speedScale}x speed');
        }
      }
    });
  });
}
