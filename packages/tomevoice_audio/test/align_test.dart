import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

/// Speech whose truth is known, for a voice that reports no word timings (a
/// natural voice): each word a tone burst as long as the script says, which
/// is not how long its letters say, butted against the next inside a phrase,
/// with the pauses a voice makes at punctuation, and the engine's silence
/// before and after.
({AudioBuffer audio, String text, List<({int start, int end})> truth}) spoken(
  List<(String, int, int)> script, {
  int leadMs = 150,
  int tailMs = 300,
  int rate = kRate,
}) {
  int f(num ms) => (ms * rate / 1000).round();
  final total = f(leadMs) + script.fold<int>(0, (s, w) => s + f(w.$2) + f(w.$3)) + f(tailMs);
  final samples = Float32List(total);
  final truth = <({int start, int end})>[];
  final env = f(5);
  var at = f(leadMs);
  for (var k = 0; k < script.length; k++) {
    final (_, ms, pause) = script[k];
    final len = f(ms);
    final hz = 160.0 + 37 * (k % 7);
    for (var i = 0; i < len; i++) {
      var v = 0.6 * math.sin(2 * math.pi * hz * i / rate);
      if (i < env) v *= 0.5 * (1 - math.cos(math.pi * i / env));
      if (i >= len - env) v *= 0.5 * (1 - math.cos(math.pi * (len - 1 - i) / env));
      samples[at + i] = v;
    }
    truth.add((start: at, end: at + len));
    at += len + f(pause);
  }
  return (
    audio: AudioBuffer(samples, rate),
    text: [for (final w in script) w.$1].join(' '),
    truth: truth,
  );
}

/// What the app did before: the whole buffer, lead-in and tail included,
/// shared by character count over the text's words.
List<WordTiming> naive(String text, int frames) {
  final words = RegExp(r'\S+').allMatches(text).toList();
  final chars = words.fold<int>(0, (s, m) => s + m.end - m.start);
  var cursor = 0;
  return [
    for (final w in words)
      () {
        final t = WordTiming(
          charStart: w.start,
          charEnd: w.end,
          frameStart: cursor,
          frameEnd: (cursor + frames * (w.end - w.start) / chars).round().clamp(0, frames),
          source: WordTimingSource.estimated,
        );
        cursor = t.frameEnd;
        return t;
      }(),
  ];
}

/// Mean and worst distance, in ms, of each word's start from the truth.
({double mean, double worst}) error(List<WordTiming> timings, List<({int start, int end})> truth, int rate) {
  expect(timings, hasLength(truth.length));
  var sum = 0.0;
  var worst = 0.0;
  for (var i = 0; i < truth.length; i++) {
    final e = (timings[i].frameStart - truth[i].start).abs() * 1000 / rate;
    sum += e;
    worst = math.max(worst, e);
  }
  return (mean: sum / truth.length, worst: worst);
}

/// Where a stage spliced silence in, in its input's frames: wherever its
/// remap starts shifting frames by more.
List<int> splicesOf(StageResult r, int frames) {
  final out = <int>[];
  var shift = 0;
  for (var f = 0; f < frames; f++) {
    final s = r.remap(f) - f;
    if (s > shift) out.add(f);
    shift = s;
  }
  return out;
}

/// The sentence the tests read, timed as a voice might: "The" and "of" long,
/// "unbelievably" short, so letters are a poor guide, and a pause at each
/// comma and the full stop.
const script = [
  ('The', 320, 0),
  ('old', 150, 0),
  ('man,', 520, 230),
  ('who', 180, 0),
  ('had', 340, 0),
  ('walked', 260, 0),
  ('unbelievably', 420, 0),
  ('far,', 480, 260),
  ('sat', 210, 0),
  ('down', 300, 0),
  ('at', 380, 0),
  ('last.', 380, 420),
  ('He', 160, 0),
  ('slept', 420, 0),
];

void main() {
  group('pause-anchored timings', () {
    test('a word after each pause starts where the voice starts again', () {
      final s = spoken(script);
      final t = PauseAligner.align(s.audio, s.text);
      expect([for (final w in t) s.text.substring(w.charStart, w.charEnd)],
          ['The', 'old', 'man', 'who', 'had', 'walked', 'unbelievably', 'far', 'sat', 'down', 'at', 'last', 'He', 'slept'],
          reason: 'words without their punctuation, as an engine reports them');
      for (final i in [0, 3, 8, 12]) {
        expect((t[i].frameStart - s.truth[i].start).abs(), lessThan(s.audio.msToFrames(12)),
            reason: '"${s.text.substring(t[i].charStart, t[i].charEnd)}" begins a stretch');
      }
      // The word before each pause holds through it, as Google reports one.
      for (final i in [2, 7, 11]) {
        expect(t[i].frameEnd, greaterThan(s.truth[i].end));
        expect(t[i].frameEnd, lessThan(s.truth[i + 1].start));
      }
      expect(t.every((w) => w.source == WordTimingSource.anchored), isTrue);
    });

    test('is far closer than sharing the whole sentence out by letters', () {
      final s = spoken(script);
      final before = error(naive(s.text, s.audio.frameCount), s.truth, kRate);
      final after = error(PauseAligner.align(s.audio, s.text), s.truth, kRate);
      // The plain share is hundreds of milliseconds out, as on the phone.
      expect(before.mean, greaterThan(150));
      expect(after.mean, lessThan(before.mean / 2), reason: 'mean ${after.mean} vs ${before.mean}');
      expect(after.worst, lessThan(before.worst));
      expect(after.worst, lessThan(320), reason: 'a wrong guess is put right at the next pause');
    });

    test('a long stretch with no pause found is not trusted with a word highlight', () {
      final long = [for (var i = 0; i < 22; i++) ('word$i', 280, 0)];
      final s = spoken(long);
      final t = PauseAligner.align(s.audio, s.text);
      expect(t, hasLength(22));
      expect(t.every((w) => w.source == WordTimingSource.estimated), isTrue);
      expect(t.every((w) => !w.source.showsWord), isTrue);
    });

    test('a short sentence with no pause is shared over the voice, not its silence', () {
      final s = spoken(const [('Come', 300, 0), ('here', 280, 0), ('now', 330, 0)], leadMs: 400, tailMs: 500);
      final t = PauseAligner.align(s.audio, s.text);
      expect(t.every((w) => w.source == WordTimingSource.anchored), isTrue);
      expect((t.first.frameStart - s.truth.first.start).abs(), lessThan(s.audio.msToFrames(6)),
          reason: 'the engine\'s lead-in is not a word');
      expect(error(t, s.truth, kRate).worst, lessThan(80));
    });

    test('a quiet stretch where the text has no mark is passed over, not matched', () {
      // A long closure inside "stopped" and a comma later: the comma's
      // pause is the one matched.
      final s = spoken(const [
        ('It', 200, 0),
        ('stop', 220, 90),
        ('ped', 200, 0),
        ('there,', 400, 240),
        ('then', 300, 0),
        ('went', 300, 0),
      ]);
      final t = PauseAligner.align(s.audio, s.text.replaceFirst('stop ped', 'stopped'));
      expect(t, hasLength(5));
      expect((t[3].frameStart - s.truth[4].start).abs(), lessThan(s.audio.msToFrames(12)), reason: '"then" after the pause');
    });

    test('pieces joined where they were made are split there', () {
      final a = spoken(const [('First', 400, 0), ('part', 300, 0)], leadMs: 60, tailMs: 120);
      final b = spoken(const [('second', 350, 0), ('one', 500, 0)], leadMs: 60, tailMs: 200);
      final joined = AudioBuffer(Float32List.fromList([...a.audio.samples, ...b.audio.samples]), kRate);
      const text = 'First part second one';
      final t = PauseAligner.align(joined, text, known: [(char: text.indexOf('second'), frame: a.audio.frameCount)]);
      expect(t, hasLength(4));
      expect((t[2].frameStart - (a.audio.frameCount + b.truth.first.start)).abs(), lessThan(joined.msToFrames(8)));
    });

    test('no words, or no sound, still gives an answer', () {
      expect(PauseAligner.align(AudioBuffer(Float32List(100), kRate), '...'), isEmpty);
      final t = PauseAligner.align(AudioBuffer(Float32List(2400), kRate), 'Silent words');
      expect(t, hasLength(2));
      expect(t.every((w) => w.source == WordTimingSource.estimated), isTrue);
    });

    test('marks the text asks a pause at', () {
      expect(PauseAligner.strengthBetween(', '), 1);
      expect(PauseAligner.strengthBetween('; '), 2);
      expect(PauseAligner.strengthBetween(' - '), 2);
      expect(PauseAligner.strengthBetween('." '), 3);
      expect(PauseAligner.strengthBetween(' '), 0);
      expect(PauseAligner.strengthBetween('-'), 0, reason: 'a hyphen inside a word is no pause');
    });
  });

  group('splicing at worked-out boundaries', () {
    PunctuationPauses commaOnly(int ms) => PunctuationPauses(commaMs: ms, clauseMs: 0, colonMs: 0, dashMs: 0, ellipsisMs: 0);

    test('a comma pause goes into the voice\'s own pause, so it only grows', () {
      final s = spoken(script);
      final t = PauseAligner.align(s.audio, s.text);
      final r = PunctuationPauseStage(text: s.text, pauses: commaOnly(200)).process(s.audio, t);
      expect(r.audio.frameCount, s.audio.frameCount + 2 * s.audio.msToFrames(200), reason: 'two commas');
      final before = AudioAnalysis.interiorSilences(s.audio, minDurationMs: 20);
      final after = AudioAnalysis.interiorSilences(r.audio, minDurationMs: 20);
      expect(after, hasLength(before.length), reason: 'no new silence inside a word');
      expect(after[0].durationMs, closeTo(before[0].durationMs + 200, 6));
      expect(after[1].durationMs, closeTo(before[1].durationMs + 200, 6));
    });

    test('a pause the voice did not make is not cut into a guessed boundary', () {
      // The same words with no pause at the comma: worked out, it gets none.
      final s = spoken([for (final w in script) (w.$1, w.$2, 0)]);
      final t = PauseAligner.align(s.audio, s.text);
      final r = PunctuationPauseStage(text: s.text, pauses: commaOnly(200)).process(s.audio, t);
      expect(r.audio.frameCount, s.audio.frameCount);
    });

    test('word gaps from a plain share never land inside a word', () {
      final s = spoken(script);
      final t = naive(s.text, s.audio.frameCount);
      final r = const WordGapStage(PipelineSettings(wordGapMs: 120)).process(s.audio, t);
      final slack = s.audio.msToFrames(8);
      bool between(int f) {
        for (var i = 0; i < s.truth.length; i++) {
          if (f > s.truth[i].start + slack && f < s.truth[i].end - slack) return false;
        }
        return true;
      }

      final cuts = splicesOf(r, s.audio.frameCount);
      for (final c in cuts) {
        expect(between(c), isTrue, reason: 'cut at ${c * 1000 ~/ kRate} ms is inside a word');
      }
    });

    test('word gaps from anchored timings find the boundaries between words', () {
      final s = spoken(script);
      final t = PauseAligner.align(s.audio, s.text);
      final r = const WordGapStage(PipelineSettings(wordGapMs: 120)).process(s.audio, t);
      final cuts = splicesOf(r, s.audio.frameCount);
      expect(cuts.length, greaterThanOrEqualTo(8), reason: 'most of the 13 boundaries get their gap');
      final slack = s.audio.msToFrames(8);
      for (final c in cuts) {
        final inside = s.truth.any((w) => c > w.start + slack && c < w.end - slack);
        expect(inside, isFalse, reason: 'cut at ${c * 1000 ~/ kRate} ms');
      }
    });

    test('engine timings keep their exact splice points', () {
      // A reported boundary with no pause is the next word's onset.
      final f = syntheticSpeech(words: 4, wordMs: 200);
      final r = const WordGapStage(PipelineSettings(wordGapMs: 100, snapSearchMs: 0)).process(f.audio, f.timings);
      expect(splicesOf(r, f.audio.frameCount), [for (final t in f.timings.skip(1)) t.frameStart]);
    });
  });
}
