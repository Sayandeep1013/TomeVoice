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

      expect(names.indexOf('stretch_stub'), lessThan(names.indexOf('word_gap')),
          reason: 'time stretch must precede word gap');
      expect(names.indexOf('word_gap'),
          lessThan(names.indexOf('sentence_pause')));
      expect(names.last, 'edges');
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
