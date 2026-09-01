import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// Timing remap is what keeps word highlighting aligned with the audio the
/// listener actually hears. Every stage changes the frame count; composing the
/// remaps wrongly is the classic source of "highlighting drifts after I change
/// the speed".
///
/// The impulse trick: mark each word boundary with a single-sample impulse in
/// an otherwise silent buffer, run the pipeline, then check that every reported
/// frame position still lands on an impulse. This tests the arithmetic without
/// needing a real engine or real speech.
void main() {
  group('timing remap (S4)', () {
    test('reported positions still land on their impulses after gap injection',
        () {
      final fixture = impulseMarked(words: 6, wordMs: 100);

      final out = Pipeline([
        WordGapStage(exactSettings.copyWith(wordGapMs: 150)),
      ]).run(resultOf(fixture.audio, fixture.timings));

      final impulses =
          AudioAnalysis.findImpulses(out.audio.samples).toSet();

      for (final t in out.wordTimings) {
        expect(
          _nearAny(impulses, t.frameStart, 2),
          isTrue,
          reason: 'word at ${t.frameStart} is not on an impulse; '
              'impulses at ${impulses.toList()..sort()}',
        );
      }
    });

    test('holds through the full standard pipeline', () {
      final fixture = impulseMarked(words: 5, wordMs: 120);

      final settings = exactSettings.copyWith(wordGapMs: 100);
      final out = buildStandardPipeline(settings)
          .run(resultOf(fixture.audio, fixture.timings));

      final impulses = AudioAnalysis.findImpulses(out.audio.samples).toSet();

      for (final t in out.wordTimings) {
        expect(_nearAny(impulses, t.frameStart, 2), isTrue,
            reason: 'drifted to ${t.frameStart}');
      }
    });

    test('remap through three stages equals composing them individually', () {
      final fixture = impulseMarked(words: 4, wordMs: 100);
      const settings = PipelineSettings(
        wordGapMs: 80,
        snapSearchMs: 0,
        crossfadeMs: 0,
        sentencePauseMs: 200,
        trimEdges: false,
      );

      final stages = <PipelineStage>[
        const TimeStretchStubStage(1.0),
        const WordGapStage(settings),
        SentencePauseStage(settings.sentencePauseMs),
      ];

      // Manual composition.
      var audio = fixture.audio;
      final remaps = <FrameRemap>[];
      for (final stage in stages) {
        final r = stage.process(audio, fixture.timings);
        audio = r.audio;
        remaps.add(r.remap);
      }
      int composed(int f) => remaps.fold(f, (acc, r) => r(acc));

      // Pipeline composition.
      final out =
          Pipeline(stages).run(resultOf(fixture.audio, fixture.timings));

      for (var i = 0; i < fixture.timings.length; i++) {
        expect(out.wordTimings[i].frameStart,
            composed(fixture.timings[i].frameStart));
      }
    });

    test('remapFromInsertions shifts only frames at or after each split', () {
      final remap = remapFromInsertions([
        (at: 100, shift: 50),
        (at: 200, shift: 100),
      ]);

      expect(remap(0), 0);
      expect(remap(99), 99);
      // A frame exactly at a split belongs after the inserted silence.
      expect(remap(100), 150);
      expect(remap(150), 200);
      expect(remap(199), 249);
      expect(remap(200), 300);
      expect(remap(500), 600);
    });

    test('remapFromInsertions is order-independent', () {
      final unsorted = remapFromInsertions([
        (at: 200, shift: 100),
        (at: 100, shift: 50),
      ]);
      expect(unsorted(150), 200);
      expect(unsorted(250), 350);
    });

    test('an empty insertion list is the identity', () {
      final remap = remapFromInsertions([]);
      for (final f in [0, 1, 999, 100000]) {
        expect(remap(f), f);
      }
    });

    test('word ordering and monotonicity survive the pipeline', () {
      final fixture = impulseMarked(words: 8, wordMs: 90);
      final out = buildStandardPipeline(exactSettings.copyWith(wordGapMs: 60))
          .run(resultOf(fixture.audio, fixture.timings));

      for (var i = 1; i < out.wordTimings.length; i++) {
        expect(out.wordTimings[i].frameStart,
            greaterThanOrEqualTo(out.wordTimings[i - 1].frameStart),
            reason: 'word starts must stay in order');
      }
      for (final t in out.wordTimings) {
        expect(t.frameStart, lessThanOrEqualTo(out.audio.frameCount));
        expect(t.frameEnd, lessThanOrEqualTo(out.audio.frameCount));
      }
    });
  });
}

bool _nearAny(Set<int> positions, int value, int tolerance) {
  for (var d = -tolerance; d <= tolerance; d++) {
    if (positions.contains(value + d)) return true;
  }
  return false;
}
