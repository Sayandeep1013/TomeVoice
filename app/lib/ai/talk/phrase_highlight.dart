import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'phrase.dart';

/// The sentence a name was held in, with the words being looked up lit as
/// with a marker: what "Who or what is it?" will ask about, seen in its
/// place ("Six Finger", not "Finger"). As words are added or dropped the
/// mark stretches to them with a little spring. A tap on a word
/// ([onTapWord]) takes the mark out to that word.
///
/// A long sentence is shown in part: the words round the mark, with "…".
class PhraseInSentence extends StatefulWidget {
  const PhraseInSentence({super.key, required this.span, this.onTapWord, this.style, this.lit = true});

  final PhraseSpan span;

  /// The index (in [PhraseSpan.words]) of a word tapped.
  final ValueChanged<int>? onTapWord;
  final TextStyle? style;

  /// False: the words typed no longer match the sentence's, so nothing is
  /// lit.
  final bool lit;

  @override
  State<PhraseInSentence> createState() => _PhraseInSentenceState();
}

/// The most of a sentence shown, in characters, round the mark.
const _window = 200;

/// The characters of [span]'s sentence shown, and where they start in it.
({String text, int offset}) _shownOf(PhraseSpan span) {
  final s = span.sentence;
  if (s.length <= _window || span.words.isEmpty || span.to < span.from) return (text: s, offset: 0);
  final a = span.words[span.from].start;
  final b = span.words[span.to].end;
  var start = math.max(0, (a + b) ~/ 2 - _window ~/ 2);
  var end = math.min(s.length, start + _window);
  start = math.max(0, end - _window);
  // Whole words at the cut.
  while (start > 0 && s[start - 1].trim().isNotEmpty) {
    start--;
  }
  while (end < s.length && s[end].trim().isNotEmpty) {
    end++;
  }
  final lead = start > 0 ? '… ' : '';
  return (text: '$lead${s.substring(start, end)}${end < s.length ? ' …' : ''}', offset: start - lead.length);
}

/// Where [span]'s words are in its sentence (null when it has none there).
({int a, int b})? _rangeOf(PhraseSpan span) =>
    span.words.isEmpty || span.to < span.from ? null : (a: span.words[span.from].start, b: span.words[span.to].end);

class _PhraseInSentenceState extends State<PhraseInSentence> with SingleTickerProviderStateMixin {
  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 420), value: 1);

  /// Where the mark was before the last change (in the sentence).
  ({int a, int b})? _was;

  @override
  void didUpdateWidget(PhraseInSentence old) {
    super.didUpdateWidget(old);
    if (old.span.from != widget.span.from || old.span.to != widget.span.to || old.lit != widget.lit) {
      _was = old.lit ? _rangeOf(old.span) : null;
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _move.value = 1;
      } else {
        _move.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ??
        TextStyle(
          fontFamily: 'Newsreader',
          fontStyle: FontStyle.italic,
          fontSize: 16,
          height: 1.45,
          color: Skin.inkSoftOn(context),
        );
    final shown = _shownOf(widget.span);
    final range = widget.lit ? _rangeOf(widget.span) : null;
    int? local(int? x) => x == null ? null : x - shown.offset;
    final a = local(range?.a), b = local(range?.b);
    final lit = a != null && b != null && a >= 0 && b <= shown.text.length && a < b;
    final text = TextSpan(
      style: base,
      children: lit
          ? [
              TextSpan(text: shown.text.substring(0, a)),
              TextSpan(
                text: shown.text.substring(a, b),
                style: TextStyle(color: Skin.inkOn(context), fontWeight: FontWeight.w600, fontStyle: FontStyle.normal),
              ),
              TextSpan(text: shown.text.substring(b)),
            ]
          : [TextSpan(text: shown.text)],
    );
    final accent = Skin.accentOf(context);
    final dir = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final was = _was;
    final wa = local(was?.a), wb = local(was?.b);
    final from = wa != null && wb != null && wa >= 0 && wb <= shown.text.length && wa < wb ? (a: wa, b: wb) : null;
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: widget.onTapWord == null || widget.span.words.isEmpty
            ? null
            : (d) {
                final p = TextPainter(text: text, textDirection: dir, textScaler: scaler)..layout(maxWidth: box.maxWidth);
                final at = p.getPositionForOffset(d.localPosition).offset + shown.offset;
                p.dispose();
                final i = widget.span.words.indexWhere((w) => at >= w.start && at <= w.end);
                if (i >= 0) widget.onTapWord!(i);
              },
        child: CustomPaint(
          painter: lit
              ? _MarkPainter(
                  text: text,
                  dir: dir,
                  scaler: scaler,
                  to: (a: a, b: b),
                  from: from,
                  t: _move,
                  fill: accent.withValues(alpha: 0.26),
                  edge: accent.withValues(alpha: 0.75),
                )
              : null,
          child: Text.rich(text, textScaler: scaler),
        ),
      ),
    );
  }
}

/// The mark: rounded boxes behind the words, with a marker's stroke under
/// them, moving from where it was ([from]) to where it is ([to]) as [t]
/// runs, overshooting a little and settling.
class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.text,
    required this.dir,
    required this.scaler,
    required this.to,
    required this.from,
    required this.t,
    required this.fill,
    required this.edge,
  }) : super(repaint: t);

  final TextSpan text;
  final TextDirection dir;
  final TextScaler scaler;
  final ({int a, int b}) to;
  final ({int a, int b})? from;
  final Animation<double> t;
  final Color fill;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final p = TextPainter(text: text, textDirection: dir, textScaler: scaler)..layout(maxWidth: size.width);
    List<Rect> boxes(({int a, int b}) r) => [
          for (final x in p.getBoxesForSelection(TextSelection(baseOffset: r.a, extentOffset: r.b))) x.toRect().inflate(3),
        ];
    final target = boxes(to);
    final start = from == null ? const <Rect>[] : boxes(from!);
    p.dispose();
    final k = Curves.easeOutBack.transform(t.value);
    final paint = Paint()..color = fill;
    final line = Paint()
      ..color = edge
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < target.length; i++) {
      final end = target[i];
      // A box with none to match grows out of the last one, or out of its
      // own middle.
      final begin = i < start.length
          ? start[i]
          : start.isEmpty
              ? Rect.fromCenter(center: end.center, width: 0, height: end.height)
              : start.last;
      final r = Rect.lerp(begin, end, k)!;
      if (r.width <= 1) continue;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), paint);
      canvas.drawLine(Offset(r.left + 4, r.bottom - 1), Offset(r.right - 4, r.bottom - 1), line);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.to != to || old.from != from || old.fill != fill || old.edge != edge || old.text != text;
}
