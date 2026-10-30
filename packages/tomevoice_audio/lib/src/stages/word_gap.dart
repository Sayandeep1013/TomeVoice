import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis.dart';
import '../pipeline.dart';
import '../types.dart';

/// Inserts silence at word boundaries.
///
/// This is the feature no TTS engine offers — not Android's `TextToSpeech`,
/// not Windows `SpeechSynthesizer`, not Piper, not Kokoro — and the reason the
/// whole architecture synthesises to PCM rather than calling `speak()`.
/// See docs/09 C-12.
///
/// Three details carry the quality:
///
/// 1. **Snap to a quiet point.** A hard splice at an arbitrary sample produces
///    an audible click. Searching a small window for the lowest-energy frame
///    lands the cut in the natural inter-word silence, where a discontinuity is
///    inaudible. This also absorbs inaccurate timings.
/// 2. **Short symmetric fades.** Belt and braces over the snap. Kept short —
///    long fades sound like ducking rather than separation.
/// 3. **Clamped search.** The window is bounded by the neighbouring words so a
///    badly-placed boundary cannot cut into the middle of speech.
///
/// A boundary that was only worked out ([WordTimingSource.anchored] or
/// [WordTimingSource.estimated]) can be a word or more out, so a quiet
/// *sample* near it is no comfort: a zero crossing inside a vowel is one.
/// There the search is wider and looks for a quiet *stretch*, a dip well
/// below the voice around it, and a boundary with none is left without a
/// gap rather than cut through a word.
class WordGapStage implements PipelineStage {
  const WordGapStage(this.settings);

  final PipelineSettings settings;

  @override
  String get name => 'word_gap';

  @override
  StageResult process(AudioBuffer input, List<WordTiming> timings) {
    final gapFrames = input.msToFrames(settings.wordGapMs);

    // Nothing to do. Return early rather than pointlessly fading — a zero gap
    // must be bit-identical to the input.
    if (gapFrames <= 0 || timings.length < 2) {
      return StageResult.unchanged(input);
    }

    final src = input.samples;
    final snapFrames = input.msToFrames(settings.snapSearchMs);
    final fadeFrames = input.msToFrames(settings.crossfadeMs);

    final splits = _splitPoints(input, timings, snapFrames);
    if (splits.isEmpty) return StageResult.unchanged(input);

    final out = Float32List(src.length + splits.length * gapFrames);
    final insertions = <({int at, int shift})>[];

    var readCursor = 0;
    var writeCursor = 0;
    var cumulativeShift = 0;

    for (var i = 0; i < splits.length; i++) {
      final split = splits[i];
      final runLength = split - readCursor;

      out.setRange(writeCursor, writeCursor + runLength, src, readCursor);

      // Fades are applied *after* the copy, never before: the destination is
      // zero-filled until setRange runs, so fading first would scale silence
      // and then be overwritten.
      if (i > 0) {
        _fadeIn(out, writeCursor, math.min(fadeFrames, runLength));
      }
      _fadeOut(out, writeCursor + runLength, math.min(fadeFrames, runLength));

      writeCursor += runLength;
      // The silence itself: Float32List is zero-initialised, so advancing the
      // write cursor past it is all that is required.
      writeCursor += gapFrames;
      readCursor = split;

      cumulativeShift += gapFrames;
      insertions.add((at: split, shift: cumulativeShift));
    }

    // Everything after the final split, faded in from the last gap.
    final tail = src.length - readCursor;
    out.setRange(writeCursor, writeCursor + tail, src, readCursor);
    _fadeIn(out, writeCursor, math.min(fadeFrames, tail));

    return StageResult(input.withSamples(out), remapFromInsertions(insertions));
  }

  /// Where to cut, one point per word boundary, strictly increasing.
  List<int> _splitPoints(
    AudioBuffer input,
    List<WordTiming> timings,
    int snapFrames,
  ) {
    final src = input.samples;
    final splits = <int>[];
    final step = math.max(1, input.msToFrames(1));
    final span = math.max(2, input.msToFrames(5));
    final floor = AudioAnalysis.peak(src) * math.pow(10, -40 / 20).toDouble();

    for (var i = 0; i < timings.length - 1; i++) {
      final current = timings[i];
      final next = timings[i + 1];

      final candidate = current.frameEnd;
      final worked = !current.source.reliable || !next.source.reliable;

      // Bound the search by the neighbouring words so a bad timing cannot move
      // the cut deep into speech, and by the buffer so it stays in range. A
      // worked-out boundary is searched more widely, but never past the
      // middle of either word.
      final reach = worked
          ? math.min(
              input.msToFrames(80),
              (0.45 * math.min(current.frameLength, next.frameLength)).round(),
            )
          : snapFrames;
      var lo = math.max(current.frameStart + 1, candidate - reach);
      var hi = math.min(next.frameEnd - 1, candidate + reach);

      lo = lo.clamp(1, src.length - 1);
      hi = hi.clamp(1, src.length - 1);

      // Keep splits strictly increasing: two words whose timings collapse onto
      // the same frame must not produce two cuts at one point.
      if (splits.isNotEmpty) {
        lo = math.max(lo, splits.last + 1);
        if (hi < lo) continue;
      }
      if (hi < lo) continue;

      if (!worked) {
        splits.add(_snapToQuietest(src, candidate.clamp(lo, hi), lo, hi));
        continue;
      }
      final dip = _quietStretch(src, lo, hi, step, span, floor);
      if (dip != null) splits.add(dip);
    }

    return splits;
  }

  /// The quietest [span]-long stretch in [lo, hi] if it is a real dip (10 dB
  /// below the loudest stretch there, or near silence), at its quietest
  /// sample; null when the voice does not dip there.
  int? _quietStretch(Float32List src, int lo, int hi, int step, int span, double floor) {
    var bestAt = -1;
    var best = double.infinity;
    var loudest = 0.0;
    for (var a = lo; a <= hi; a += step) {
      final from = (a - span ~/ 2).clamp(0, src.length - 1);
      final level = AudioAnalysis.rms(src, from, math.min(span, src.length - from));
      if (level < best) {
        best = level;
        bestAt = a;
      }
      if (level > loudest) loudest = level;
    }
    if (bestAt < 0 || (best > floor && best > 0.32 * loudest)) return null;
    final a = math.max(lo, bestAt - span ~/ 2);
    final b = math.min(hi, bestAt + span ~/ 2);
    return _snapToQuietest(src, bestAt, a, b);
  }

  /// Lowest-magnitude sample in [lo, hi], preferring [candidate] on a tie so a
  /// well-placed boundary is not moved for no reason.
  int _snapToQuietest(Float32List src, int candidate, int lo, int hi) {
    var best = candidate;
    var bestValue = src[candidate].abs();

    for (var i = lo; i <= hi; i++) {
      final value = src[i].abs();
      if (value < bestValue) {
        bestValue = value;
        best = i;
      }
    }
    return best;
  }

  void _fadeOut(Float32List buffer, int endExclusive, int frames) {
    if (frames <= 0) return;
    final start = math.max(0, endExclusive - frames);
    final span = endExclusive - start;
    if (span <= 0) return;
    for (var i = 0; i < span; i++) {
      buffer[start + i] *= 1.0 - (i + 1) / span;
    }
  }

  void _fadeIn(Float32List buffer, int start, int frames) {
    if (frames <= 0) return;
    final end = math.min(buffer.length, start + frames);
    final span = end - start;
    if (span <= 0) return;
    for (var i = 0; i < span; i++) {
      buffer[start + i] *= (i + 1) / span;
    }
  }
}
