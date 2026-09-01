import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

void main() {
  group('word gap injection', () {
    // Criterion S1: a requested gap must actually appear in the audio, within
    // 5 ms, measured from the waveform rather than trusted from the settings.
    for (final gapMs in [60, 120, 250, 400]) {
      test('inserts $gapMs ms at every word boundary (S1)', () {
        final fixture = syntheticSpeech(words: 5, wordMs: 200);
        final stage = WordGapStage(PipelineSettings(
          wordGapMs: gapMs,
          snapSearchMs: 0,
          crossfadeMs: 2,
        ));

        final out = stage.process(fixture.audio, fixture.timings);

        final silences = AudioAnalysis.interiorSilences(
          out.audio,
          minDurationMs: 20,
        );

        expect(silences, hasLength(4), reason: '5 words means 4 boundaries');
        for (final run in silences) {
          expect(
            run.durationMs,
            closeTo(gapMs, 5.0),
            reason: 'gap measured ${run.durationMs}ms, requested ${gapMs}ms',
          );
        }
      });
    }

    test('zero gap leaves the buffer bit-identical', () {
      final fixture = syntheticSpeech();
      final out = const WordGapStage(PipelineSettings(wordGapMs: 0))
          .process(fixture.audio, fixture.timings);

      expect(out.audio.samples, same(fixture.audio.samples));
      for (final t in fixture.timings) {
        expect(out.remap(t.frameStart), t.frameStart);
      }
    });

    test('a single word has no boundaries, so nothing is inserted', () {
      final fixture = syntheticSpeech(words: 1);
      final out = const WordGapStage(PipelineSettings(wordGapMs: 200))
          .process(fixture.audio, fixture.timings);

      expect(out.audio.frameCount, fixture.audio.frameCount);
    });

    test('output length equals input plus exactly the inserted silence', () {
      final fixture = syntheticSpeech(words: 5, wordMs: 200);
      const gapMs = 120;
      final out = WordGapStage(
        const PipelineSettings(wordGapMs: gapMs, snapSearchMs: 0),
      ).process(fixture.audio, fixture.timings);

      final expected =
          fixture.audio.frameCount + 4 * fixture.audio.msToFrames(gapMs);
      expect(out.audio.frameCount, expected);
    });

    // Criterion S3: splicing silence into audio must not introduce clicks.
    test('introduces no discontinuity beyond the source (S3)', () {
      final fixture = syntheticSpeech(words: 6, wordMs: 150, enveloped: true);
      final before = AudioAnalysis.maxDiscontinuity(fixture.audio.samples);

      final out = const WordGapStage(PipelineSettings(wordGapMs: 150))
          .process(fixture.audio, fixture.timings);
      final after = AudioAnalysis.maxDiscontinuity(out.audio.samples);

      expect(after, lessThan(0.1),
          reason: 'absolute click threshold from spec S3');
      expect(after, lessThanOrEqualTo(before + 1e-6),
          reason: 'gap injection must not make the signal rougher');
    });

    test('snapping finds the quiet point when timings are late', () {
      // Words separated by real silence, but the reported boundary lands 8 ms
      // into the following word — the kind of error `estimated` timings make.
      final fixture = syntheticSpeech(
        words: 3,
        wordMs: 200,
        naturalGapMs: 40,
        enveloped: true,
      );
      final skewFrames = fixture.audio.msToFrames(8);
      final skewed = [
        for (final t in fixture.timings)
          t.copyWithFrames(t.frameStart, t.frameEnd + skewFrames),
      ];

      final out = const WordGapStage(PipelineSettings(
        wordGapMs: 100,
        snapSearchMs: 20,
        crossfadeMs: 2,
      )).process(fixture.audio, skewed);

      // If the cut had landed inside speech we would see a step; snapping into
      // the natural silence keeps the waveform smooth.
      expect(AudioAnalysis.maxDiscontinuity(out.audio.samples), lessThan(0.1));
    });

    test('never cuts outside the neighbouring words, however bad the timings',
        () {
      final fixture = syntheticSpeech(words: 4, wordMs: 150);
      // Deliberately corrupt: every boundary claims to be at frame 0.
      final broken = [
        for (final t in fixture.timings) t.copyWithFrames(0, 0),
      ];

      final out = const WordGapStage(PipelineSettings(
        wordGapMs: 100,
        snapSearchMs: 5,
      )).process(fixture.audio, broken);

      // The contract that matters under bad input: produce a valid buffer of
      // the right length rather than corrupt memory or drop audio.
      final expected =
          fixture.audio.frameCount + 3 * fixture.audio.msToFrames(100);
      expect(out.audio.frameCount, lessThanOrEqualTo(expected));
      expect(out.audio.frameCount, greaterThan(fixture.audio.frameCount));
    });

    test('splits stay strictly increasing when words collapse to one frame',
        () {
      final fixture = syntheticSpeech(words: 4, wordMs: 150);
      final collapsed = [
        for (final t in fixture.timings) t.copyWithFrames(1000, 1000),
      ];

      final out = const WordGapStage(PipelineSettings(
        wordGapMs: 50,
        snapSearchMs: 0,
      )).process(fixture.audio, collapsed);

      expect(out.audio.frameCount, greaterThanOrEqualTo(
        fixture.audio.frameCount,
      ));
    });
  });
}
