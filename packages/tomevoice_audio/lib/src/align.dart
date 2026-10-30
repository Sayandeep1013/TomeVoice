import 'dart:math' as math;
import 'dart:typed_data';

import 'analysis.dart';
import 'types.dart';

/// Word timings for speech that came with none (a natural voice, a line
/// joined from two voices), worked out from the audio and the text together.
///
/// Sharing a sentence out over its words by character count drifts: against
/// an engine's own timings it was 271 ms out on average and 610 ms at worst,
/// and the highlight, the word gap and the page turns all followed it. Part
/// of that was the engine's own silence before and after the speech, shared
/// out as if it were words; the rest builds up word by word.
///
/// But the audio does say one thing for certain: where the voice pauses. The
/// text says where it ought to (commas, full stops, dashes). This matches the
/// two in order, then shares out each stretch between two pauses over its
/// own words, so a guess that runs fast or slow is put right at the next
/// pause instead of carrying on to the end of the sentence.
///
/// A long stretch with no pause found keeps its words
/// [WordTimingSource.estimated], so the reader highlights the sentence there
/// rather than a confidently wrong word; the words of shorter stretches are
/// [WordTimingSource.anchored].
class PauseAligner {
  const PauseAligner._();

  /// Pauses shorter than this are not looked for: the closure of a stop
  /// consonant inside a word can be silent for as long as 60 ms.
  static const minPauseMs = 70.0;

  /// Quieter than this, relative to the loudest moment, is not voice.
  static const quietDb = -40.0;

  /// Words shared over a longer stretch than this, with no pause to put
  /// them right, can be far enough out that highlighting one would mislead.
  static const trustedSpanMs = 3500.0;

  /// Timings for each word of [text], in the frames of [audio].
  ///
  /// [known] are places already certain, a character of [text] and the frame
  /// its audio begins at: where pieces made apart were joined. They split the
  /// matching into independent parts.
  ///
  /// [spans] are the text's word units when the caller has them (the
  /// document package's, which know where Chinese and Japanese words fall).
  /// Punctuation at either end of one is left out of it, as an engine
  /// reports a word, so a comma's pause still finds its comma. Without them
  /// [wordsOf] splits the text.
  static List<WordTiming> align(
    AudioBuffer audio,
    String text, {
    List<({int char, int frame})> known = const [],
    List<({int start, int end})>? spans,
  }) {
    final words = spans == null ? wordsOf(text) : unitsOf(text, spans);
    if (words.isEmpty) return const [];
    final n = audio.frameCount;

    // Known joins, as (first word after it, where its audio begins).
    final cuts = <({int word, int frame})>[];
    for (final k in [...known]..sort((a, b) => a.char.compareTo(b.char))) {
      final w = words.indexWhere((x) => x.start >= k.char);
      if (w <= 0) continue;
      final f = k.frame.clamp(0, n);
      if (cuts.isNotEmpty && (w <= cuts.last.word || f <= cuts.last.frame)) continue;
      cuts.add((word: w, frame: f));
    }

    final peak = AudioAnalysis.peak(audio.samples);
    final quiet = peak * math.pow(10, quietDb / 20).toDouble();
    final pauses = peak <= 0
        ? const <SilenceRun>[]
        : AudioAnalysis.findSilences(audio, thresholdDb: quietDb, minDurationMs: minPauseMs, windowMs: 5);

    final out = <WordTiming>[];
    var first = 0;
    var from = 0;
    for (var r = 0; r <= cuts.length; r++) {
      final last = r < cuts.length ? cuts[r].word : words.length;
      final to = r < cuts.length ? cuts[r].frame : n;
      out.addAll(_region(audio, text, words.sublist(first, last), from, to, pauses, quiet));
      first = last;
      from = to;
    }
    return out;
  }

  /// The words of [text]: letters and digits, with an apostrophe or hyphen
  /// inside a word kept in it ("don't", "well-known"), punctuation left out,
  /// as an engine reports them. Chinese and Japanese, written without spaces
  /// between words, give one unit a character. [weight] is roughly how long
  /// each takes to say: its letters, more for digits (a year is four words),
  /// and a little for every word however short.
  static List<({int start, int end, double weight})> wordsOf(String text) => [
        for (final m in _word.allMatches(text))
          for (final w in _splitWide(text, m.start, m.end))
            (start: w.$1, end: w.$2, weight: _weight(text.substring(w.$1, w.$2))),
      ];

  /// Word units given by the caller, each without the punctuation at its
  /// ends ("two," is "two"; a Chinese character and its comma, the
  /// character); one with no letter or digit at all is not a word.
  static List<({int start, int end, double weight})> unitsOf(String text, List<({int start, int end})> spans) {
    final out = <({int start, int end, double weight})>[];
    for (final s in spans) {
      var a = s.start.clamp(0, text.length);
      var b = s.end.clamp(a, text.length);
      while (a < b && !_wordChar.hasMatch(text[a])) {
        a++;
      }
      while (b > a && !_wordChar.hasMatch(text[b - 1])) {
        b--;
      }
      if (b > a) out.add((start: a, end: b, weight: _weight(text.substring(a, b))));
    }
    return out;
  }

  /// [start, end) as words, with each Chinese or Japanese character on its own.
  static List<(int, int)> _splitWide(String text, int start, int end) {
    var wide = false;
    for (var i = start; i < end && !wide; i++) {
      wide = isHanOrKana(text.codeUnitAt(i));
    }
    if (!wide) return [(start, end)];
    final out = <(int, int)>[];
    var run = -1;
    for (var i = start; i < end; i++) {
      if (isHanOrKana(text.codeUnitAt(i))) {
        if (run >= 0) out.add((run, i));
        run = -1;
        out.add((i, i + 1));
      } else if (run < 0) {
        run = i;
      }
    }
    if (run >= 0) out.add((run, end));
    return out;
  }

  /// Chinese characters and Japanese kana: a word unit each.
  static bool isHanOrKana(int c) =>
      (c >= 0x3040 && c <= 0x30FF) || // hiragana, katakana
      (c >= 0x31F0 && c <= 0x31FF) || // katakana extensions
      (c >= 0x3400 && c <= 0x4DBF) || // CJK extension A
      (c >= 0x4E00 && c <= 0x9FFF) || // CJK unified ideographs
      (c >= 0xF900 && c <= 0xFAFF) || // compatibility ideographs
      (c >= 0xFF66 && c <= 0xFF9F); // half-width katakana

  static final _wordChar = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

  static final _word = RegExp(r"[\p{L}\p{N}\p{M}]+(?:['’\-][\p{L}\p{N}\p{M}]+)*", unicode: true);
  static final _digit = RegExp(r'\p{N}', unicode: true);
  static final _letter = RegExp(r'[\p{L}\p{M}]', unicode: true);

  static double _weight(String word) =>
      _letter.allMatches(word).length + 4.0 * _digit.allMatches(word).length + 1.5;

  /// How strongly the text between two words asks for a pause: 3 a full
  /// stop, 2 a clause mark or a dash, 1 a comma, 0 none (Chinese and
  /// Japanese marks too).
  static int strengthBetween(String between) {
    if (between.contains(RegExp('[.!?…。！？]'))) return 3;
    if (between.contains(RegExp('[;:—–()\\[\\]；：（）]')) || between.contains(RegExp(r'\s-\s'))) return 2;
    if (between.contains(RegExp('[,，、]'))) return 1;
    return 0;
  }

  static List<WordTiming> _region(
    AudioBuffer audio,
    String text,
    List<({int start, int end, double weight})> words,
    int from,
    int to,
    List<SilenceRun> allPauses,
    double quiet,
  ) {
    if (words.isEmpty) return const [];
    final window = math.max(1, audio.msToFrames(5));
    final voiced = to > from && quiet > 0 ? _voiced(audio.samples, from, to, quiet, window) : null;
    if (voiced == null) {
      // Nothing heard: shared over the whole stretch, and not trusted.
      return _spread(words, from, math.max(from, to), const [], WordTimingSource.estimated, to);
    }
    final (s0, s1) = voiced;
    final pauses = [
      for (final p in allPauses)
        if (p.startFrame > s0 && p.endFrame < s1) p,
    ];

    // Where the text asks for a pause, and where a plain share would put it.
    final total = words.fold<double>(0, (s, w) => s + w.weight);
    final marks = <({int word, int strength, double expected})>[];
    var cum = 0.0;
    for (var i = 0; i < words.length - 1; i++) {
      cum += words[i].weight;
      final strength = strengthBetween(text.substring(words[i].end, words[i + 1].start));
      if (strength > 0) marks.add((word: i, strength: strength, expected: s0 + (s1 - s0) * cum / total));
    }

    final tol = math.max(audio.msToFrames(250).toDouble(), 0.12 * (s1 - s0));
    final matched = _match(marks, pauses, tol, audio.sampleRate);

    final out = <WordTiming>[];
    var segFirst = 0;
    var segFrom = s0;
    for (var k = 0; k <= matched.length; k++) {
      final pause = k < matched.length ? matched[k].pause : null;
      final lastWord = k < matched.length ? matched[k].word : words.length - 1;
      final segTo = pause?.startFrame ?? s1;
      // The last word holds through its pause, as an engine reports it;
      // the region's last word to the region's end.
      final end = pause == null ? to : pause.startFrame + pause.frameCount ~/ 2;
      final inner = [
        for (final p in pauses)
          if (p.startFrame > segFrom && p.endFrame < segTo) p,
      ];
      final speech = (segTo - segFrom) - inner.fold<int>(0, (s, p) => s + p.frameCount);
      final source = audio.framesToMs(speech) <= trustedSpanMs ? WordTimingSource.anchored : WordTimingSource.estimated;
      out.addAll(_spread(words.sublist(segFirst, lastWord + 1), segFrom, segTo, inner, source, end));
      segFirst = lastWord + 1;
      if (pause != null) segFrom = pause.endFrame;
    }
    return out;
  }

  /// The first and last frame of sound in [from, to), to the window.
  static (int, int)? _voiced(Float32List s, int from, int to, double quiet, int window) {
    int? start;
    for (var i = from; i < to; i += window) {
      if (AudioAnalysis.rms(s, i, math.min(window, to - i)) >= quiet) {
        start = i;
        break;
      }
    }
    if (start == null) return null;
    var end = to;
    for (var i = to; i > start; i -= window) {
      final a = math.max(start, i - window);
      if (AudioAnalysis.rms(s, a, i - a) >= quiet) {
        end = i;
        break;
      }
    }
    return (start, math.max(start + 1, end));
  }

  /// Marks matched to pauses, in order, so the total cost is least: a match
  /// costs its distance from where the plain share expected it; a mark left
  /// without a pause costs more the stronger it is (a full stop nearly always
  /// has one); a pause left without a mark costs more the longer it is (a
  /// short one may be a consonant, a long one is a real pause).
  static List<({int word, SilenceRun pause})> _match(
    List<({int word, int strength, double expected})> marks,
    List<SilenceRun> pauses,
    double tol,
    int rate,
  ) {
    final m = marks.length;
    final p = pauses.length;
    if (m == 0 || p == 0) return const [];
    double miss(int i) => switch (marks[i].strength) { 1 => 0.6, 2 => 1.0, _ => 1.6 };
    double skip(int j) {
      final ms = pauses[j].frameCount * 1000 / rate;
      return ms < 120 ? 0.3 : (ms < 250 ? 0.8 : 1.4);
    }

    double centre(int j) => pauses[j].startFrame + pauses[j].frameCount / 2;
    final cost = List.generate(m + 1, (_) => List<double>.filled(p + 1, 0));
    // 0: the mark went without a pause, 1: the pause without a mark, 2: matched.
    final move = List.generate(m + 1, (_) => List<int>.filled(p + 1, 0));
    for (var i = 1; i <= m; i++) {
      cost[i][0] = cost[i - 1][0] + miss(i - 1);
    }
    for (var j = 1; j <= p; j++) {
      cost[0][j] = cost[0][j - 1] + skip(j - 1);
      move[0][j] = 1;
    }
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= p; j++) {
        var best = cost[i - 1][j] + miss(i - 1);
        var how = 0;
        final s = cost[i][j - 1] + skip(j - 1);
        if (s < best) {
          best = s;
          how = 1;
        }
        final d = (marks[i - 1].expected - centre(j - 1)).abs();
        if (d < 3 * tol) {
          final c = cost[i - 1][j - 1] + d / tol;
          if (c < best) {
            best = c;
            how = 2;
          }
        }
        cost[i][j] = best;
        move[i][j] = how;
      }
    }
    final out = <({int word, SilenceRun pause})>[];
    var i = m;
    var j = p;
    while (i > 0 && j > 0) {
      switch (move[i][j]) {
        case 2:
          out.add((word: marks[i - 1].word, pause: pauses[j - 1]));
          i--;
          j--;
        case 1:
          j--;
        default:
          i--;
      }
    }
    return out.reversed.toList();
  }

  /// [words] shared over [from, to) by weight, skipping the quiet [gaps]
  /// inside it (a word begins after a pause, not in it). The last word ends
  /// at [lastEnd].
  static List<WordTiming> _spread(
    List<({int start, int end, double weight})> words,
    int from,
    int to,
    List<SilenceRun> gaps,
    WordTimingSource source,
    int lastEnd,
  ) {
    final total = words.fold<double>(0, (s, w) => s + w.weight);
    final speech = math.max(0, (to - from) - gaps.fold<int>(0, (s, g) => s + g.frameCount));
    int at(double t) {
      var f = from + t;
      for (final g in gaps) {
        if (f >= g.startFrame) {
          f += g.frameCount;
        } else {
          break;
        }
      }
      return f.round().clamp(from, math.max(from, to));
    }

    final starts = <int>[];
    var cum = 0.0;
    for (final w in words) {
      starts.add(total <= 0 ? from : at(speech * cum / total));
      cum += w.weight;
    }
    return [
      for (var k = 0; k < words.length; k++)
        WordTiming(
          charStart: words[k].start,
          charEnd: words[k].end,
          frameStart: starts[k],
          frameEnd: k + 1 < words.length ? starts[k + 1] : math.max(starts[k], lastEnd),
          source: source,
        ),
    ];
  }
}
