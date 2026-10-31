import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'highlights.dart';
import 'marks.dart';
import 'scheduler.dart';
import 'theme.dart';

// The book's words as the scrolling page sets them: a paragraph with the
// sentence being read washed in it, the word under a finger, and the way
// round a script is read.

/// One paragraph. Rebuilds only when the spoken sentence enters, leaves or
/// moves within it — not when anything else in the book changes.
class BlockText extends StatefulWidget {
  const BlockText({
    super.key,
    required this.item,
    required this.layout,
    required this.cursor,
    required this.word,
    required this.style,
    required this.wash,
    required this.wordWash,
    required this.onTapUnit,
    required this.onLongPressUnit,
    this.heading = false,
    this.justify = false,
    this.indent = 0,
    this.highlights,
    this.onTapAt,
    this.wordInk,
    this.headingInk,
  });

  final LayoutItem item;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final ValueListenable<WordMark> word;
  final TextStyle style;

  /// Behind the sentence being read, and behind its word: the page tone's.
  final Color wash;
  final Color wordWash;

  /// The word being read, on [wordWash]: an ink that reads there; null for
  /// the text's own.
  final Color? wordInk;

  /// What a [heading] being read turns to: the accent, in an ink that reads
  /// on its wash; null for the accent's ink.
  final Color? headingInk;
  final ValueChanged<int> onTapUnit;

  /// Press and hold: the sentence, and the word under the finger.
  final void Function(int unit, String word) onLongPressUnit;

  /// Saved quotes, washed in their colours under the voice's washes.
  final ValueListenable<Map<int, Mark>>? highlights;

  /// A tap on a paragraph holding a saved quote: the sentence tapped.
  final ValueChanged<int>? onTapAt;

  /// A heading being spoken turns amber rather than sitting in a box.
  final bool heading;
  final bool justify;

  /// The first line's indent, when paragraphs are indented (0 for none).
  final double indent;

  @override
  State<BlockText> createState() => _BlockTextState();
}

class _BlockTextState extends State<BlockText> {
  final _key = GlobalKey();
  late int _current = _mine(widget.cursor.value);

  /// The saved quotes over this paragraph's sentences.
  Map<int, Mark> _quotes = const {};

  int _mine(int u) => widget.item.containsUnit(u) ? u : -1;

  Map<int, Mark> _quotesHere() {
    final all = widget.highlights?.value;
    if (all == null || all.isEmpty) return const {};
    final item = widget.item;
    return {
      for (var u = item.firstUnit; u < item.firstUnit + item.unitCount; u++)
        if (all[u] case final m?) u: m,
    };
  }

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_onCursor);
    widget.highlights?.addListener(_onHighlights);
    _quotes = _quotesHere();
  }

  @override
  void didUpdateWidget(BlockText old) {
    super.didUpdateWidget(old);
    if (old.cursor != widget.cursor) {
      old.cursor.removeListener(_onCursor);
      widget.cursor.addListener(_onCursor);
    }
    if (old.highlights != widget.highlights) {
      old.highlights?.removeListener(_onHighlights);
      widget.highlights?.addListener(_onHighlights);
    }
    _current = _mine(widget.cursor.value);
    _quotes = _quotesHere();
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_onCursor);
    widget.highlights?.removeListener(_onHighlights);
    super.dispose();
  }

  void _onCursor() {
    final next = _mine(widget.cursor.value);
    if (next != _current) setState(() => _current = next);
  }

  /// Only a paragraph whose own quotes changed is built again.
  void _onHighlights() {
    final next = _quotesHere();
    if (!sameQuotes(next, _quotes)) setState(() => _quotes = next);
  }

  /// The sentence under [global], and the offset in the paragraph's text.
  (int, int)? _hit(Offset global) {
    final render = _paragraphOf(_key.currentContext?.findRenderObject());
    if (render == null) return null;
    final at = render.getPositionForOffset(render.globalToLocal(global)).offset;
    // The indent is one placeholder before the text.
    final offset = widget.indent > 0 ? math.max(0, at - 1) : at;
    final l = widget.layout;
    var unit = widget.item.firstUnit;
    for (var u = widget.item.firstUnit; u < widget.item.firstUnit + widget.item.unitCount; u++) {
      if (l.unitOffset[u] <= offset) unit = u;
    }
    return (unit, offset);
  }

  void _onLongPress(LongPressStartDetails d) {
    final hit = _hit(d.globalPosition);
    if (hit != null) widget.onLongPressUnit(hit.$1, wordAt(widget.item.block!.text, hit.$2));
  }

  /// Text may wrap its paragraph in semantics or selection render objects.
  static RenderParagraph? _paragraphOf(RenderObject? r) {
    if (r == null) return null;
    if (r is RenderParagraph) return r;
    RenderParagraph? found;
    r.visitChildren((child) => found ??= _paragraphOf(child));
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final body = _current < 0
        ? _span(context, WordMark.none)
        : ValueListenableBuilder<WordMark>(
            valueListenable: widget.word,
            builder: (context, w, _) => _span(context, w.unit == _current ? w : WordMark.none),
          );
    // A tap does nothing: taps while scrolling kept sending the voice
    // somewhere else. Press and hold, then Read from here. A screen reader's
    // double tap still reads from the paragraph. Only a paragraph holding a
    // saved quote takes a tap (for the quote's note and actions); elsewhere
    // the page has it, for the bars.
    final tap = widget.onTapAt;
    return Semantics(
      button: true,
      hint: 'Double tap to read from here',
      onTap: () => widget.onTapUnit(widget.item.firstUnit),
      child: GestureDetector(
        onLongPressStart: _onLongPress,
        onTapUp: tap == null || _quotes.isEmpty
            ? null
            : (d) {
                final hit = _hit(d.globalPosition);
                if (hit != null) tap(hit.$1);
              },
        child: body,
      ),
    );
  }

  Widget _span(BuildContext context, WordMark word) {
    final text = widget.item.block!.text;
    final align = widget.justify ? TextAlign.justify : TextAlign.start;
    final lead = <InlineSpan>[
      if (widget.indent > 0) WidgetSpan(child: SizedBox(width: widget.indent)),
    ];
    if (_current < 0 && _quotes.isEmpty) {
      return Text.rich(TextSpan(children: [...lead, TextSpan(text: text)]),
          key: _key, style: widget.style, textAlign: align);
    }
    // Saved quotes in their colours, and the voice's sentence and word over
    // them.
    final accent = widget.wash.withValues(alpha: 1);
    final dark = darkPage(widget.style.color);
    final spoken = widget.heading ? widget.headingInk ?? Skin.accentInkOf(context) : null;
    final runs = washRuns(
      layout: widget.layout,
      item: widget.item,
      quotes: _quotes,
      quoteWash: (m) => highlightWash(m.colour, accent: accent, dark: dark),
      spoken: _current,
      sentenceWash: widget.heading ? widget.wash.withValues(alpha: 0.08) : widget.wash,
      wordWash: widget.wordWash,
      wordStart: word.start,
      wordEnd: word.end,
    );
    final spans = <InlineSpan>[
      ...lead,
      for (final r in runs)
        TextSpan(
          text: text.substring(r.start, r.end),
          style: r.wash == null && !(r.spoken && spoken != null)
              ? null
              : TextStyle(
                  backgroundColor: r.wash,
                  color: r.word ? widget.wordInk ?? spoken : (r.spoken ? spoken : null),
                ),
        ),
    ];
    return Text.rich(TextSpan(children: spans), key: _key, style: widget.style, textAlign: align);
  }
}

/// Right to left for the scripts read that way: Arabic (and Persian, Urdu,
/// Pashto, Sindhi, Uyghur, Sorani), Hebrew and Yiddish, Thaana and Syriac.
TextDirection directionOfLanguage(String language) =>
    const {'ar', 'fa', 'ur', 'ps', 'sd', 'ug', 'ckb', 'he', 'iw', 'yi', 'dv', 'syr'}.contains(language)
        ? TextDirection.rtl
        : TextDirection.ltr;

/// The word around [offset] in [text] (letters, digits, apostrophes,
/// hyphens), or the one just beside it; empty far from any word.
String wordAt(String text, int offset) {
  // Marks too (\p{M}): Bengali and Hindi vowel signs and the virama are
  // marks, and without them বাংলা came back as ব.
  final letter = RegExp(r"[\p{L}\p{M}\p{N}'’-]", unicode: true);
  bool isLetter(int i) => i >= 0 && i < text.length && letter.hasMatch(text[i]);
  var i = offset.clamp(0, text.length);
  // A finger on a space or a comma means the word beside it.
  if (!isLetter(i)) {
    i = [i - 1, i + 1, i - 2, i + 2].firstWhere(isLetter, orElse: () => -1);
    if (i < 0) return '';
  }
  var s = i;
  var e = i;
  while (isLetter(s - 1)) {
    s--;
  }
  while (isLetter(e)) {
    e++;
  }
  return text.substring(s, e).replaceAll(RegExp(r"^['’-]+|['’-]+$"), '');
}
