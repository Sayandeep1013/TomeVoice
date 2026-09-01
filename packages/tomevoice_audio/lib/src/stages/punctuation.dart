import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline.dart';
import '../types.dart';

/// How long to hold at each kind of punctuation.
///
/// Separate knobs rather than one "pause" slider, because they do different
/// jobs: a comma is a breath inside a thought, a clause boundary separates
/// thoughts, and a colon introduces one. Collapsing them into a single value is
/// what makes most readers sound either rushed or ponderous.
class PunctuationPauses {
  const PunctuationPauses({
    this.commaMs = 150,
    this.clauseMs = 100,
    this.colonMs = 200,
    this.dashMs = 180,
    this.ellipsisMs = 300,
    this.quoteMs = 0,
  });

  /// `,`
  final int commaMs;

  /// `;` and bracket boundaries
  final int clauseMs;

  /// `:`
  final int colonMs;

  /// Em and en dashes used as asides
  final int dashMs;

  /// `...`
  final int ellipsisMs;

  /// Entering or leaving quoted speech
  final int quoteMs;

  bool get isEmpty =>
      commaMs <= 0 &&
      clauseMs <= 0 &&
      colonMs <= 0 &&
      dashMs <= 0 &&
      ellipsisMs <= 0 &&
      quoteMs <= 0;

  PunctuationPauses copyWith({
    int? commaMs,
    int? clauseMs,
    int? colonMs,
    int? dashMs,
    int? ellipsisMs,
    int? quoteMs,
  }) =>
      PunctuationPauses(
        commaMs: commaMs ?? this.commaMs,
        clauseMs: clauseMs ?? this.clauseMs,
        colonMs: colonMs ?? this.colonMs,
        dashMs: dashMs ?? this.dashMs,
        ellipsisMs: ellipsisMs ?? this.ellipsisMs,
        quoteMs: quoteMs ?? this.quoteMs,
      );
}

/// Inserts extra silence *inside* a sentence, at punctuation.
///
/// Engines already pause at punctuation, some of them well. This adds to what
/// is there rather than replacing it — the same additive model as
/// [WordGapStage], and for the same reason: we cannot remove silence the engine
/// baked in without cutting speech, so every control here can only lengthen.
///
/// Placement comes from the word timings plus the source text: the pause goes
/// after the word whose character range ends at (or immediately before) the
/// punctuation mark.
class PunctuationPauseStage implements PipelineStage {
  const PunctuationPauseStage({
    required this.text,
    required this.pauses,
    this.crossfadeMs = 4,
  });

  final String text;
  final PunctuationPauses pauses;
  final int crossfadeMs;

  @override
  String get name => 'punctuation';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    if (pauses.isEmpty || timings.isEmpty || text.isEmpty) {
      return StageResult.unchanged(input);
    }

    // (frame position, silence to insert) for each punctuated word.
    final marks = <({int at, int frames})>[];

    for (final t in timings) {
      final ms = _pauseAfter(t.charEnd);
      if (ms <= 0) continue;

      final frames = input.msToFrames(ms);
      if (frames <= 0) continue;

      final at = t.frameEnd.clamp(0, input.frameCount);
      marks.add((at: at, frames: frames));
    }

    if (marks.isEmpty) return StageResult.unchanged(input);

    marks.sort((a, b) => a.at.compareTo(b.at));

    final total = marks.fold<int>(0, (sum, m) => sum + m.frames);
    final src = input.samples;
    final out = Float32List(src.length + total);
    final fade = input.msToFrames(crossfadeMs);

    final insertions = <({int at, int shift})>[];
    var read = 0;
    var write = 0;
    var shift = 0;

    for (final m in marks) {
      final run = m.at - read;
      if (run < 0) continue;

      out.setRange(write, write + run, src, read);
      _fadeOut(out, write + run, math.min(fade, run));

      write += run + m.frames;
      read = m.at;
      shift += m.frames;
      insertions.add((at: m.at, shift: shift));
    }

    final tail = src.length - read;
    out.setRange(write, write + tail, src, read);
    _fadeIn(out, write, math.min(fade, tail));

    return StageResult(input.withSamples(out), remapFromInsertions(insertions));
  }

  /// Looks at the characters immediately after a word to decide what, if
  /// anything, follows it.
  ///
  /// Order matters: `...` must be tested before `.`, and a closing quote may
  /// sit between the word and its punctuation (`"stop," he said`).
  int _pauseAfter(int charEnd) {
    var i = charEnd;
    var sawQuote = false;

    // Skip a closing quote or bracket, remembering that we saw one.
    while (i < text.length && _isCloser(text[i])) {
      sawQuote = true;
      i++;
    }
    if (i >= text.length) return sawQuote ? pauses.quoteMs : 0;

    final rest = text.substring(i);
    if (rest.startsWith('...') || rest.startsWith('…')) {
      return pauses.ellipsisMs;
    }

    final c = text[i];
    final base = switch (c) {
      ',' => pauses.commaMs,
      ';' => pauses.clauseMs,
      ':' => pauses.colonMs,
      '—' || '–' || '-' => pauses.dashMs,
      _ => 0,
    };

    if (base > 0) return base;
    return sawQuote ? pauses.quoteMs : 0;
  }

  bool _isCloser(String c) =>
      c == '"' || c == '\'' || c == '”' || c == '’' ||
      c == ')' || c == ']' || c == '}';

  void _fadeOut(Float32List b, int endExclusive, int frames) {
    if (frames <= 0) return;
    final start = math.max(0, endExclusive - frames);
    final span = endExclusive - start;
    if (span <= 0) return;
    for (var i = 0; i < span; i++) {
      b[start + i] *= 1.0 - (i + 1) / span;
    }
  }

  void _fadeIn(Float32List b, int start, int frames) {
    if (frames <= 0) return;
    final end = math.min(b.length, start + frames);
    final span = end - start;
    if (span <= 0) return;
    for (var i = 0; i < span; i++) {
      b[start + i] *= (i + 1) / span;
    }
  }
}
