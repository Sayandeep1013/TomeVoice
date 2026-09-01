import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// Punctuation pauses have to land after the right word, which means reading
/// the source text rather than guessing from timing alone. These tests pin the
/// cases that are easy to get wrong: ellipsis before full stop, punctuation
/// hidden behind a closing quote, and marks that should do nothing.
void main() {
  /// Builds audio plus timings whose character ranges match [text]'s words.
  ({AudioBuffer audio, List<WordTiming> timings}) forText(String text) {
    final words = <({int start, int end})>[];
    for (final m in RegExp(r'[A-Za-z0-9]+').allMatches(text)) {
      words.add((start: m.start, end: m.end));
    }
    final built = syntheticSpeech(words: words.length, wordMs: 150);
    return (
      audio: built.audio,
      timings: [
        for (var i = 0; i < words.length; i++)
          WordTiming(
            charStart: words[i].start,
            charEnd: words[i].end,
            frameStart: built.timings[i].frameStart,
            frameEnd: built.timings[i].frameEnd,
            source: WordTimingSource.engineReported,
          ),
      ],
    );
  }

  int insertedFrames(String text, PunctuationPauses pauses) {
    final f = forText(text);
    final out = PunctuationPauseStage(text: text, pauses: pauses)
        .process(f.audio, f.timings);
    return out.audio.frameCount - f.audio.frameCount;
  }

  group('punctuation pauses', () {
    test('inserts after a comma and nowhere else', () {
      const text = 'one two, three four';
      const pauses = PunctuationPauses(
        commaMs: 200,
        clauseMs: 0,
        colonMs: 0,
        dashMs: 0,
        ellipsisMs: 0,
      );
      final f = forText(text);
      final inserted = insertedFrames(text, pauses);

      expect(inserted, f.audio.msToFrames(200),
          reason: 'exactly one comma in the text');
    });

    test('each mark uses its own setting', () {
      const text = 'a, b; c: d';
      const pauses = PunctuationPauses(
        commaMs: 100,
        clauseMs: 200,
        colonMs: 300,
        dashMs: 0,
        ellipsisMs: 0,
      );
      final f = forText(text);
      expect(
        insertedFrames(text, pauses),
        f.audio.msToFrames(100) +
            f.audio.msToFrames(200) +
            f.audio.msToFrames(300),
      );
    });

    test('ellipsis is not read as a full stop', () {
      const text = 'well... maybe';
      const pauses = PunctuationPauses(
        commaMs: 0,
        clauseMs: 0,
        colonMs: 0,
        dashMs: 0,
        ellipsisMs: 400,
      );
      final f = forText(text);
      expect(insertedFrames(text, pauses), f.audio.msToFrames(400));
    });

    test('finds punctuation hidden behind a closing quote', () {
      // The comma sits after the quote mark, so a naive "next character"
      // check would miss it entirely.
      const text = '"stop," he said';
      const pauses = PunctuationPauses(
        commaMs: 250,
        clauseMs: 0,
        colonMs: 0,
        dashMs: 0,
        ellipsisMs: 0,
        quoteMs: 0,
      );
      final f = forText(text);
      expect(insertedFrames(text, pauses), f.audio.msToFrames(250));
    });

    test('a full stop is left to the sentence pause', () {
      const text = 'one two. three';
      const pauses = PunctuationPauses(
        commaMs: 200,
        clauseMs: 200,
        colonMs: 200,
        dashMs: 200,
        ellipsisMs: 200,
      );
      expect(insertedFrames(text, pauses), 0);
    });

    test('all-zero settings are a no-op', () {
      const text = 'a, b; c: d... e';
      const pauses = PunctuationPauses(
        commaMs: 0,
        clauseMs: 0,
        colonMs: 0,
        dashMs: 0,
        ellipsisMs: 0,
        quoteMs: 0,
      );
      final f = forText(text);
      final out = PunctuationPauseStage(text: text, pauses: pauses)
          .process(f.audio, f.timings);
      expect(out.audio.samples, same(f.audio.samples));
    });

    test('timings are remapped past the inserted silence', () {
      const text = 'alpha, beta gamma';
      const pauses = PunctuationPauses(
        commaMs: 300,
        clauseMs: 0,
        colonMs: 0,
        dashMs: 0,
        ellipsisMs: 0,
      );
      final f = forText(text);
      final out = PunctuationPauseStage(text: text, pauses: pauses)
          .process(f.audio, f.timings);

      final gapFrames = f.audio.msToFrames(300);
      // The first word is before the insertion and must not move.
      expect(out.remap(f.timings.first.frameStart), f.timings.first.frameStart);
      // Words after it shift by exactly the inserted amount.
      expect(
        out.remap(f.timings.last.frameStart),
        f.timings.last.frameStart + gapFrames,
      );
    });

    test('is additive with the word gap, not exclusive', () {
      const text = 'one two, three';
      const settings = PipelineSettings(
        wordGapMs: 100,
        sentencePauseMs: 0,
        trimEdges: false,
        snapSearchMs: 0,
        text: text,
        punctuation: PunctuationPauses(
          commaMs: 200,
          clauseMs: 0,
          colonMs: 0,
          dashMs: 0,
          ellipsisMs: 0,
        ),
        normaliseLoudness: false,
        compression: Compression.off,
      );

      final f = forText(text);
      final out =
          buildStandardPipeline(settings).run(resultOf(f.audio, f.timings));

      // Three words: two boundaries at 100 ms, plus one comma at 200 ms.
      final expected = f.audio.frameCount +
          2 * f.audio.msToFrames(100) +
          f.audio.msToFrames(200);
      expect(out.audio.frameCount, expected);
    });
  });

  group('gain', () {
    test('normalisation brings a quiet buffer up', () {
      final quiet = syntheticSpeech(words: 3, wordMs: 100, amplitude: 0.05);
      final out = const GainStage(compression: Compression.off)
          .process(quiet.audio, quiet.timings);

      expect(AudioAnalysis.peak(out.audio.samples), closeTo(0.89, 0.02));
    });

    test('never clips', () {
      final hot = syntheticSpeech(words: 3, wordMs: 100, amplitude: 0.99);
      final out = const GainStage(volume: 4.0, normalise: false)
          .process(hot.audio, hot.timings);

      for (final s in out.audio.samples) {
        expect(s.abs(), lessThanOrEqualTo(1.0));
      }
    });

    test('trim in dB scales as expected', () {
      final f = syntheticSpeech(words: 2, wordMs: 100, amplitude: 0.4);
      final before = AudioAnalysis.peak(f.audio.samples);
      final out = const GainStage(
        trimDb: -6.0,
        normalise: false,
        compression: Compression.off,
      ).process(f.audio, f.timings);

      // -6 dB is very close to half amplitude.
      expect(AudioAnalysis.peak(out.audio.samples), closeTo(before * 0.501, 0.01));
    });

    test('leaves frame positions alone', () {
      final f = syntheticSpeech(words: 4, wordMs: 100);
      final out = const GainStage().process(f.audio, f.timings);
      expect(out.audio.frameCount, f.audio.frameCount);
      for (final t in f.timings) {
        expect(out.remap(t.frameStart), t.frameStart);
      }
    });
  });

  group('presets', () {
    test('every preset is distinct and has a label', () {
      final ids = SpeechPreset.all.map((p) => p.id).toSet();
      expect(ids.length, SpeechPreset.all.length);
      for (final p in SpeechPreset.all) {
        expect(p.label, isNotEmpty);
        expect(p.description, isNotEmpty);
      }
    });

    test('the accessibility presets actually use the word gap', () {
      expect(SpeechPreset.dyslexia.settings.wordGapMs, greaterThan(100));
      expect(SpeechPreset.language.settings.wordGapMs, greaterThan(200));
      expect(SpeechPreset.natural.settings.wordGapMs, 0);
    });

    test('every preset survives the pipeline', () {
      final f = forText('Alpha, beta; gamma: delta. Epsilon zeta');
      for (final p in SpeechPreset.all) {
        final s = p.settings.copyWith(text: 'Alpha, beta; gamma: delta.');
        final out = buildStandardPipeline(s).run(resultOf(f.audio, f.timings));
        expect(out.audio.frameCount, greaterThan(0), reason: p.id);
        for (final t in out.wordTimings) {
          expect(t.frameStart, lessThanOrEqualTo(out.audio.frameCount),
              reason: p.id);
        }
      }
    });
  });
}
