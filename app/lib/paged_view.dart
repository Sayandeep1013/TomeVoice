import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'page_curl.dart';
import 'scheduler.dart';
import 'theme.dart';

/// How the book is drawn on a page. Built by the reader from the same prefs
/// as the scrolling page, so the two look alike.
@immutable
class PageLook {
  const PageLook({
    required this.text,
    required this.heading,
    required this.chapterHeading,
    required this.title,
    required this.label,
    required this.status,
    required this.accent,
    required this.sentenceWash,
    required this.wordWash,
    required this.textScaler,
    required this.justify,
    required this.indent,
    required this.margin,
  });

  final TextStyle text;
  final TextStyle heading;
  final TextStyle chapterHeading;
  final TextStyle title;

  /// "CHAPTER 3" above a chapter's first line.
  final TextStyle label;

  /// The chapter's name above the page and the count below it.
  final TextStyle status;
  final Color accent;
  final Color sentenceWash;
  final Color wordWash;
  final TextScaler textScaler;
  final bool justify;
  final bool indent;
  final double margin;

  /// Everything the laid-out pages depend on: what changes where lines
  /// break, and the colours painted with them.
  Object get key => Object.hash(text, heading, chapterHeading, title, label, textScaler, justify, indent, margin);
}

/// Whether paragraph [item] of [l] opens with an indent when paragraphs are
/// indented: not the first of a chapter, nor one after a heading or a
/// picture, as in a printed book.
bool indentedAt(ReadingLayout l, int item) {
  final it = l.items[item];
  final b = it.block;
  if (b == null || b.isImage || b.role == BlockRole.heading) return false;
  if (item == 0 || item == l.chapterFirstItem[it.chapter]) return false;
  final before = l.items[item - 1];
  if (before.chapter != it.chapter) return false;
  final pb = before.block;
  return pb != null && !pb.isImage && pb.role != BlockRole.heading;
}

/// How a page turns: curling over like paper, sliding, or at once.
enum PageTurn {
  curl('Curl'),
  slide('Slide'),
  none('Instant');

  const PageTurn(this.label);
  final String label;

  static PageTurn byName(String? name) => values.where((t) => t.name == name).firstOrNull ?? curl;
}

/// The first line's indent, as a share of the text size.
const indentEm = 1.6;

/// The gap after a paragraph: a line's breath when spaced, a hair when
/// indented (the indent marks the new paragraph).
double paragraphGap(PageLook look) => look.indent ? 2 : 16;

enum _Kind { label, title, text, picture }

/// One piece of a page: a window onto an item's laid-out text from [top]
/// for [height], or a whole picture, title or chapter label.
class _Piece {
  const _Piece(this.kind, this.item, this.top, this.height, {this.gapAfter = 0});
  final _Kind kind;
  final int item;
  final double top;
  final double height;
  final double gapAfter;
}

class _Page {
  _Page(this.chapter, this.pieces, this.firstUnit, this.lastUnit, this.startItem, this.startOffset);
  final int chapter;
  final List<_Piece> pieces;

  /// The sentence the page opens with (one carried over from the page
  /// before counts as this page's when it starts here).
  final int firstUnit;

  /// The sentence its last line ends in (carried on to the next page, it
  /// counts for both).
  final int lastUnit;

  /// Where its first line begins: an item, and the offset in its block's
  /// text (0 unless the page opens partway through a paragraph).
  final int startItem;
  final int startOffset;
}

/// An item laid out once at the column's width: the painter and the tops
/// of its lines.
class _Laid {
  _Laid(this.painter, this.lineTops, this.shift);
  final TextPainter painter;

  /// Top of each line, then the bottom of the last.
  final List<double> lineTops;

  /// Characters before the block's own text (1 for an indent's placeholder).
  final int shift;
}

/// Moves the paged book from outside: to a sentence, or a page on or back.
class PagedController {
  _PagedBookState? _state;

  /// Show the page with sentence [unit]. With [at] (the offset of the word
  /// being read in the sentence), the page that word is on: the voice is
  /// followed word by word, and the page turns as it reads onto the next.
  void showUnit(int unit, {bool animate = true, int? at}) => _state?._showUnit(unit, animate: animate, at: at);

  /// A page on (1) or back (-1), as by the reader's hand.
  void turn(int delta) => _state?._turn(delta);

  /// The sentences on the page shown (both pages, in a spread): the first,
  /// and the one after the last. A sentence carried over a page's end is
  /// the next page's. Null before the first page is laid out.
  (int, int)? get range => _state?._range();
}

/// The book in pages, a chapter at a time: each chapter is cut into pages
/// of whole lines when it is reached (a 3,000-chapter web novel costs no
/// more than a short story), and the place is a sentence, never a page
/// number, so a new size or font or a turn of the phone keeps it.
class PagedBook extends StatefulWidget {
  const PagedBook({
    super.key,
    required this.layout,
    required this.look,
    required this.controller,
    required this.startUnit,
    required this.marked,
    required this.word,
    required this.chapterName,
    required this.onPage,
    required this.onTapMiddle,
    required this.onHold,
    required this.pictureOf,
    this.chapterLabel,
    this.turn = PageTurn.curl,
    this.spread = false,
    this.paper = const BoxDecoration(),
    this.crease,
    this.tapToTurn = true,
    this.endButton,
    this.topInset = 0,
    this.bottomInset = 0,
    this.marks,
  });

  final ReadingLayout layout;
  final PageLook look;
  final PagedController controller;
  final int startUnit;

  /// The sentence washed on the page (-1 for none), and the word under the
  /// voice.
  final ValueListenable<int> marked;
  final ValueListenable<WordMark> word;

  final String Function(int chapter) chapterName;

  /// "CHAPTER 3", or null when the title carries its number.
  final String? Function(int chapter)? chapterLabel;

  /// A page came to rest: its first sentence, and whether the reader
  /// turned to it (rather than the voice or a jump).
  final void Function(int unit, {required bool byHand}) onPage;
  final VoidCallback onTapMiddle;

  /// Press and hold on text: the item and the offset in its block's text.
  final void Function(int item, int offset) onHold;

  /// A picture block drawn in [size].
  final Widget Function(Block block, Size size) pictureOf;

  final PageTurn turn;

  /// Two pages side by side, as an open book (a wide screen).
  final bool spread;

  /// The page's paper: a turning page must hide the one under it.
  final BoxDecoration paper;

  /// The shade of the binding between two open pages.
  final Color? crease;
  final bool tapToTurn;

  /// The page after the last chapter here (a web novel's next chapter).
  final Widget? endButton;

  /// Room kept clear at the top and foot, under the reader's bars.
  final double topInset;
  final double bottomInset;

  /// Sentences with a bookmark: a page holding one shows a ribbon.
  final ValueListenable<Set<int>>? marks;

  @override
  State<PagedBook> createState() => _PagedBookState();
}

class _PagedBookState extends State<PagedBook> {
  ReadingLayout get _l => widget.layout;

  /// Pages of each chapter cut so far, for the current size and look.
  final _cut = <int, List<_Page>>{};
  final _laid = <int, _Laid>{};
  Object? _cutFor;

  late int _chapter = _l.chapterOfUnit(widget.startUnit);
  PageController? _pages;
  final _curl = CurlController();

  /// A new row (another chapter, or a new size): the page view or the
  /// curl is made afresh at its index, in the same frame.
  Object _row = Object();
  int _index = 0;
  bool _turningByHand = false;
  Size _size = Size.zero;

  /// Set when a page is to be shown once the size is known.
  int? _pendingUnit;

  /// The sentence the page shown is kept at: the one being read, or the
  /// first of the page turned to. A new size, look or spread cuts new
  /// pages, and the page that has it is shown.
  int? _anchor;

  /// The size, look and spread the page shown was found for.
  Object? _cutAt;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    _pendingUnit = widget.startUnit;
  }

  @override
  void didUpdateWidget(PagedBook old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._state = null;
      widget.controller._state = this;
    }
    if (old.layout != widget.layout) _forget();
  }

  @override
  void dispose() {
    if (widget.controller._state == this) widget.controller._state = null;
    _pages?.dispose();
    _forgetLaid();
    super.dispose();
  }

  void _forgetLaid() {
    for (final l in _laid.values) {
      l.painter.dispose();
    }
    _laid.clear();
  }

  void _forget() {
    _forgetLaid();
    _cut.clear();
  }

  // ------------------------------------------------------------- geometry

  double get _leafWidth => widget.spread ? _size.width / 2 : _size.width;
  double get _sideFor => math.max(widget.look.margin, (_leafWidth - 720) / 2);
  double get _columnWidth => math.max(120, _leafWidth - 2 * _sideFor);

  static const _statusBand = 30.0;
  double get _top => widget.topInset + _statusBand;
  double get _foot => widget.bottomInset + _statusBand;
  double get _pageHeight => math.max(160, _size.height - _top - _foot);

  // ------------------------------------------------------------ cutting

  int _chapterEnd(int c) => c + 1 < _l.chapters.length ? _l.chapterFirstItem[c + 1] : _l.items.length;

  _Laid _lay(int i) => _laid[i] ??= () {
        final look = widget.look;
        final item = _l.items[i];
        final chapterStart = i == _l.chapterFirstItem[item.chapter];
        final TextStyle style;
        String text;
        var shift = 0;
        final spans = <InlineSpan>[];
        if (item.isTitle) {
          style = look.title;
          text = item.title ?? '';
        } else {
          final heading = item.block!.role == BlockRole.heading;
          style = heading ? (chapterStart ? look.chapterHeading : look.heading) : look.text;
          text = item.block!.text;
          if (look.indent && indentedAt(_l, i)) {
            shift = 1;
            spans.add(const WidgetSpan(child: SizedBox.shrink()));
          }
        }
        spans.add(TextSpan(text: text));
        final heading = !item.isTitle && item.block!.role == BlockRole.heading;
        final tp = TextPainter(
          text: TextSpan(style: style, children: spans),
          textDirection: TextDirection.ltr,
          textAlign: look.justify && !heading && !item.isTitle ? TextAlign.justify : TextAlign.start,
          textScaler: look.textScaler,
        );
        if (shift > 0) {
          final size = look.textScaler.scale(look.text.fontSize ?? 19) * indentEm;
          tp.setPlaceholderDimensions([
            PlaceholderDimensions(size: Size(size, 1), alignment: PlaceholderAlignment.bottom),
          ]);
        }
        tp.layout(maxWidth: _columnWidth);
        final tops = <double>[0];
        for (final m in tp.computeLineMetrics()) {
          tops.add(tops.last + m.height);
        }
        // The painter's own height is the truth for the last line.
        if (tops.length > 1) tops[tops.length - 1] = tp.height;
        return _Laid(tp, tops, shift);
      }();

  /// The unit whose text holds [offset] of item [i]'s block.
  int _unitAt(int i, int offset) {
    final item = _l.items[i];
    var unit = item.firstUnit;
    for (var u = item.firstUnit; u < item.firstUnit + item.unitCount; u++) {
      if (_l.unitOffset[u] <= offset) unit = u;
    }
    return unit;
  }

  Size _pictureSize(Block b) {
    final iw = (b.imageWidth ?? 1).toDouble(), ih = (b.imageHeight ?? 1).toDouble();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    var w = math.min(_columnWidth, iw / dpr * 2.2);
    var h = w * ih / iw;
    final most = _pageHeight - 28;
    if (h > most) {
      w = w * most / h;
      h = most;
    }
    return Size(w, h);
  }

  List<_Page> _pagesOf(int c) {
    final key = Object.hash(widget.look.key, _size, widget.spread);
    if (_cutFor != key) {
      _forget();
      _cutFor = key;
    }
    return _cut[c] ??= _cutChapter(c);
  }

  List<_Page> _cutChapter(int c) {
    final look = widget.look;
    final height = _pageHeight;
    final pages = <_Page>[];
    var pieces = <_Piece>[];
    var y = 0.0;
    var first = -1;
    var last = -1;
    var startOffset = 0;
    void close() {
      if (pieces.isEmpty) return;
      final firstItem = pieces.first.item;
      final opens = first >= 0 ? first : _l.items[firstItem].firstUnit;
      pages.add(_Page(c, pieces, opens, last >= opens ? last : opens, firstItem, startOffset));
      pieces = [];
      y = 0;
      first = -1;
      last = -1;
      startOffset = 0;
    }

    void place(_Piece p, {int unit = -1, int lastUnit = -1, int at = 0}) {
      if (pieces.isEmpty) startOffset = at;
      if (first < 0 && unit >= 0) first = unit;
      if (lastUnit >= 0) last = lastUnit;
      pieces.add(p);
      y += p.height + p.gapAfter;
    }

    final from = _l.chapterFirstItem[c], to = _chapterEnd(c);
    // A chapter opens with its label, as on the scrolling page.
    final label = _l.chapters.length > 1 ? widget.chapterLabel?.call(c) : null;
    final labelHeight = _labelHeight(label);
    if (labelHeight > 0) place(_Piece(_Kind.label, from, 0, labelHeight));
    for (var i = from; i < to; i++) {
      final item = _l.items[i];
      if (item.isImage) {
        final size = _pictureSize(item.block!);
        final h = size.height + 28;
        if (y + h > height && pieces.isNotEmpty) close();
        place(_Piece(_Kind.picture, i, 0, h), unit: item.firstUnit < _l.units.length ? item.firstUnit : -1);
        continue;
      }
      final laid = _lay(i);
      final heading = item.isTitle || item.block!.role == BlockRole.heading;
      final chapterStart = i == _l.chapterFirstItem[item.chapter];
      final above = heading && !chapterStart && !item.isTitle ? 12.0 : 0.0;
      final gap = heading ? 18.0 : paragraphGap(look);
      final tops = laid.lineTops;
      final lines = tops.length - 1;
      if (heading) {
        // A heading stays with what follows it: never last on a page.
        final h = above + tops.last;
        final next = i + 1 < to && !_l.items[i + 1].isImage ? _lay(i + 1).lineTops : null;
        final needs = h + gap + (next != null && next.length > 2 ? next[2] : 0);
        if (y + needs > height && pieces.isNotEmpty) close();
        // Its space above only between paragraphs, not at a page's top.
        final pad = y > 0 ? above : 0.0;
        place(_Piece(item.isTitle ? _Kind.title : _Kind.text, i, -pad, tops.last + pad, gapAfter: gap),
            unit: item.isTitle ? -1 : item.firstUnit,
            lastUnit: item.isTitle || item.unitCount == 0 ? -1 : item.firstUnit + item.unitCount - 1);
        continue;
      }
      var a = 0;
      while (a < lines) {
        var b = a;
        while (b < lines && y + (tops[b + 1] - tops[a]) <= height) {
          b++;
        }
        if (b == a) {
          if (pieces.isNotEmpty) {
            close();
            continue;
          }
          b = a + 1; // A line taller than the page: it goes alone.
        }
        final at = a == 0 ? 0 : math.max(0, laid.painter.getPositionForOffset(Offset(1, tops[a] + 1)).offset - laid.shift);
        final unit = a == 0 ? item.firstUnit : _unitAt(i, at);
        final whole = b == lines;
        // The sentence the last line here ends in.
        final ends = whole
            ? item.firstUnit + item.unitCount - 1
            : _unitAt(i, laid.painter.getPositionForOffset(Offset(_columnWidth - 1, tops[b] - 1)).offset - laid.shift);
        place(_Piece(_Kind.text, i, tops[a], tops[b] - tops[a], gapAfter: whole ? gap : 0),
            unit: unit, lastUnit: ends, at: at);
        a = b;
        if (!whole) close();
      }
    }
    close();
    if (pages.isEmpty) {
      pages.add(_Page(c, const [], _l.chapterFirstUnit[c], _l.chapterFirstUnit[c], _l.chapterFirstItem[c], 0));
    }
    return pages;
  }

  double _labelHeight(String? label) {
    if (label == null) return 0;
    final tp = TextPainter(
      text: TextSpan(text: label, style: widget.look.label),
      textDirection: TextDirection.ltr,
      textScaler: widget.look.textScaler,
    )..layout();
    final h = tp.height + 8 + 12;
    tp.dispose();
    return h;
  }

  /// The page of chapter [c] that sentence [unit] is on.
  int _pageOfUnit(List<_Page> pages, int unit) {
    var p = 0;
    for (var k = 0; k < pages.length; k++) {
      if (pages[k].firstUnit <= unit) p = k;
    }
    return p;
  }

  /// The page of chapter [c] that offset [offset] of item [item]'s text is
  /// on: the last page beginning at or before it.
  int _pageOfPlace(List<_Page> pages, int item, int offset) {
    var p = 0;
    for (var k = 0; k < pages.length; k++) {
      final s = pages[k];
      if (s.startItem < item || (s.startItem == item && s.startOffset <= offset)) p = k;
    }
    return p;
  }

  // ------------------------------------------------------------- turning

  /// Pages shown at once: two side by side in a spread.
  int get _per => widget.spread ? 2 : 1;
  int _itemsIn(int c) => (_pagesOf(c).length + _per - 1) ~/ _per;
  int _itemOf(int c, int unit) => _pageOfUnit(_pagesOf(c), unit) ~/ _per;

  /// Items laid out in a row: the last of the chapter before, this
  /// chapter's, and the first of the next (or the way on). Turning onto
  /// either edge moves to that chapter once the page comes to rest.
  bool get _hasBefore => _chapter > 0;
  bool get _hasNext => _chapter + 1 < _l.chapters.length;
  bool get _hasEnd => !_hasNext && widget.endButton != null;
  int get _before => _hasBefore ? 1 : 0;
  int get _count => _before + _itemsIn(_chapter) + (_hasNext || _hasEnd ? 1 : 0);

  void _ensureController(int index) {
    if (_pages == null) {
      _pages = PageController(initialPage: index);
      _index = index;
    }
  }

  /// Show chapter [c] at item [index] of its row. The row is made afresh
  /// (keyed by [_row]) on a new controller, so it opens there in the same
  /// frame: a jump on the old one showed the wrong page for a frame.
  void _moveTo(int c, int index) {
    final old = _pages;
    setState(() {
      _chapter = c;
      _index = index;
      _pages = PageController(initialPage: index);
      _row = Object();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _showUnit(int unit, {bool animate = true, int? at}) {
    if (_size == Size.zero || _pages == null) {
      _pendingUnit = unit;
      return;
    }
    _anchor = unit;
    final c = _l.chapterOfUnit(unit);
    // The voice reading on into the next chapter turns onto its first page,
    // already at the row's end, as a hand would.
    final onward = at != null && c == _chapter + 1 && _followed(c, unit, at) == 0;
    if (c != _chapter && !onward) {
      _moveTo(c, (c > 0 ? 1 : 0) + _itemOf(c, unit));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _settled(byHand: false);
      });
      return;
    }
    final i = onward ? _before + _itemsIn(_chapter) : _before + (at == null ? _itemOf(c, unit) : _followed(c, unit, at));
    if (i == _index) return;
    // A sentence begun on the page before and carried onto this one: the
    // voice starting it here (Play on this page) does not turn back.
    if (at != null && i < _index && _pageAt(_index)?.firstUnit == unit) return;
    final near = (i - _index).abs() == 1;
    _turningByHand = false;
    if (widget.turn == PageTurn.curl) {
      _curl.turnTo(i, animate: animate && near);
      return;
    }
    final d = Motion.of(context, Motion.standard);
    if (near && widget.turn == PageTurn.slide && d > Duration.zero) {
      unawaited(_pages!.animateToPage(i, duration: d, curve: Motion.out));
    } else {
      _pages!.jumpToPage(i);
    }
  }

  /// The item of chapter [c] holding the word at [at] in sentence [unit].
  int _followed(int c, int unit, int at) =>
      _pageOfPlace(_pagesOf(c), _l.unitItem[unit], _l.unitOffset[unit] + at) ~/ _per;

  void _turn(int delta) {
    if (widget.turn == PageTurn.curl) {
      _curl.step(delta);
      return;
    }
    final p = _pages;
    if (p == null) return;
    final i = (_index + delta).clamp(0, _count - 1);
    if (i == _index) return;
    _turningByHand = true;
    final d = Motion.of(context, Motion.standard);
    if (widget.turn == PageTurn.slide && d > Duration.zero) {
      unawaited(p.animateToPage(i, duration: d, curve: Motion.out));
    } else {
      p.jumpToPage(i);
    }
  }

  /// The page at rest: an edge item becomes its own chapter's, and the
  /// reader hears which sentence the page opens with.
  void _settled({required bool byHand}) {
    if (_hasBefore && _index == 0) {
      final c = _chapter - 1;
      _moveTo(c, (c > 0 ? 1 : 0) + _itemsIn(c) - 1);
    } else if (_hasNext && _index == _before + _itemsIn(_chapter)) {
      _moveTo(_chapter + 1, 1);
    }
    final page = _pageAt(_index);
    if (page != null) {
      // Kept while it is on the page shown, so new cuts find the same
      // sentence again instead of drifting back a page each time.
      final shown = _range();
      final a = _anchor;
      if (a == null || shown == null || a < shown.$1 || a >= shown.$2) _anchor = page.firstUnit;
      widget.onPage(page.firstUnit, byHand: byHand);
    }
    // Cut the chapters either side ahead of time, a frame apart, so
    // turning onto them never waits.
    final c = _chapter;
    Timer(const Duration(milliseconds: 60), () {
      if (!mounted || c != _chapter) return;
      if (_hasBefore) _pagesOf(c - 1);
      Timer(const Duration(milliseconds: 60), () {
        if (mounted && c == _chapter && _hasNext) _pagesOf(c + 1);
      });
    });
  }

  /// The chapter and item at [index] of the row; null for the way on.
  (int, int)? _itemAt(int index) {
    if (index < _before) return _hasBefore ? (_chapter - 1, _itemsIn(_chapter - 1) - 1) : null;
    final k = index - _before;
    if (k < _itemsIn(_chapter)) return (_chapter, k);
    if (_hasNext) return (_chapter + 1, 0);
    return null;
  }

  /// Page [side] (0 left or alone, 1 right) of item [index].
  _Page? _leafPage(int index, int side) {
    final at = _itemAt(index);
    if (at == null) return null;
    final pages = _pagesOf(at.$1);
    final k = at.$2 * _per + side;
    return k < pages.length ? pages[k] : null;
  }

  _Page? _pageAt(int index) => _leafPage(index, 0);

  /// The sentence after [p]'s own: the next page's first (a sentence carried
  /// over a page's end is the next page's, so a bookmark is on one page),
  /// or after the last for a chapter's last page or a sentence longer than
  /// a page.
  int _endOf(_Page p) {
    final pages = _pagesOf(p.chapter);
    final k = pages.indexOf(p);
    if (k >= 0 && k + 1 < pages.length && pages[k + 1].firstUnit > p.firstUnit) return pages[k + 1].firstUnit;
    return p.lastUnit + 1;
  }

  (int, int)? _range() {
    if (_size == Size.zero) return null;
    final a = _leafPage(_index, 0);
    if (a == null) return null;
    final b = widget.spread ? (_leafPage(_index, 1) ?? a) : a;
    return (a.firstUnit, _endOf(b));
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final cut = Object.hash(widget.look.key, size, widget.spread);
          if (cut != _cutAt) {
            _cutAt = cut;
            _size = size;
            // A new size, look or spread cuts new pages; the page keeps its
            // sentence. (Asked of the pages after the cut, the old page's
            // number came back, with other text on it.)
            final keep = _pendingUnit ?? _anchor;
            if (keep != null) {
              _anchor = keep;
              _chapter = _l.chapterOfUnit(keep);
              final i = _before + _itemOf(_chapter, keep);
              if (_pages == null) {
                _ensureController(i);
              } else if (i != _index) {
                final old = _pages;
                _index = i;
                _pages = PageController(initialPage: i);
                _row = Object();
                WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
              }
            }
            _pendingUnit = null;
          }
          _ensureController(0);
          if (widget.turn == PageTurn.curl) {
            return _turnable(PageCurl(
              key: ValueKey(_row),
              controller: _curl,
              itemCount: _count,
              initialIndex: _index,
              leaf: _leafView,
              paper: widget.paper,
              spread: widget.spread,
              crease: widget.crease,
              tapToTurn: widget.tapToTurn,
              onTapMiddle: widget.onTapMiddle,
              onSettled: (i, {required byHand}) {
                _index = i;
                _settled(byHand: byHand);
              },
            ));
          }
          return _turnable(NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.depth != 0) return false;
              if (n is ScrollStartNotification && n.dragDetails != null) _turningByHand = true;
              if (n is ScrollEndNotification) {
                final byHand = _turningByHand;
                _turningByHand = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _settled(byHand: byHand);
                });
              }
              return false;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // TalkBack turns pages by the actions in _turnable: its double
              // tap arrives here with no place on the page, read as "back".
              excludeFromSemantics: true,
              onTapUp: (d) {
                final x = d.localPosition.dx / size.width;
                if (widget.tapToTurn && x < 0.28) {
                  _turn(-1);
                } else if (widget.tapToTurn && x > 0.72) {
                  _turn(1);
                } else {
                  widget.onTapMiddle();
                }
              },
              child: PageView.builder(
                key: ValueKey(_row),
                controller: _pages,
                itemCount: _count,
                physics: widget.turn == PageTurn.slide ? const PageScrollPhysics() : const _InstantPagePhysics(),
                onPageChanged: (i) => _index = i,
                itemBuilder: (context, i) => widget.spread
                    ? Stack(
                        children: [
                          Row(
                            children: [
                              Expanded(child: _leafView(context, i, 0)),
                              Expanded(child: _leafView(context, i, 1)),
                            ],
                          ),
                          if (widget.crease != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Center(child: SizedBox(width: 68, child: CustomPaint(painter: Crease(widget.crease!)))),
                              ),
                            ),
                        ],
                      )
                    : _leafView(context, i, 0),
              ),
            ),
          ));
        },
      );

  /// The page turns, and the bars, as TalkBack actions (with the two-finger
  /// swipe): the pages are painted and turned by taps at their sides, which
  /// a screen reader could not reach.
  Widget _turnable(Widget child) => Semantics(
        container: true,
        explicitChildNodes: true,
        onScrollLeft: () => _turn(1),
        onScrollRight: () => _turn(-1),
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Next page'): () => _turn(1),
          const CustomSemanticsAction(label: 'Previous page'): () => _turn(-1),
          const CustomSemanticsAction(label: 'Show the controls'): widget.onTapMiddle,
        },
        child: child,
      );

  /// The words a slice of a paragraph shows, for TalkBack: the page is
  /// painted, and read out only the chapter's name and the page count.
  String _sliceText(_Piece p, _Laid laid) {
    final text = laid.painter.plainText;
    final s = laid.painter.getPositionForOffset(Offset(0, p.top + 1)).offset.clamp(0, text.length);
    final e = laid.painter.getPositionForOffset(Offset(_columnWidth, p.top + p.height - 1)).offset.clamp(s, text.length);
    // The indent is a placeholder in the painter's text.
    return text.substring(s, e).replaceAll(String.fromCharCode(0xFFFC), '').trim();
  }

  Widget _leafView(BuildContext context, int index, int side) {
    if (_itemAt(index) == null && _hasEnd) {
      return side == 0 ? Center(child: widget.endButton) : const SizedBox.shrink();
    }
    final page = _leafPage(index, side);
    if (page == null) return const SizedBox.shrink();
    final pages = _pagesOf(page.chapter);
    final number = pages.indexOf(page) + 1;
    final look = widget.look;
    final margin = _sideFor;
    final unitsLeft = _wordsLeft(page);
    final minutes = (unitsLeft / _readingWpm).ceil();
    final marks = widget.marks;
    final end = _endOf(page);
    final body = Padding(
        padding: EdgeInsets.fromLTRB(margin, widget.topInset, margin, widget.bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _statusBand,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.chapterName(page.chapter).toUpperCase(),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: look.status),
              ),
            ),
            SizedBox(
              height: _pageHeight,
              child: ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  // The last piece's gap is the page's foot, not a gap.
                  children: [
                    for (final p in page.pieces) _pieceView(context, p, last: identical(p, page.pieces.last)),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: _statusBand,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      minutes <= 0 ? 'END OF CHAPTER' : '$minutes MIN LEFT IN CHAPTER',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: look.status,
                    ),
                  ),
                  Text('$number / ${pages.length}', style: look.status),
                ],
              ),
            ),
          ],
        ),
    );
    if (marks == null) return body;
    // A bookmark on this page: a ribbon at its top corner.
    return Stack(
      children: [
        body,
        Positioned(
          top: widget.topInset,
          right: margin - 6,
          child: ValueListenableBuilder<Set<int>>(
            valueListenable: marks,
            builder: (context, set, _) => AnimatedSwitcher(
              duration: Motion.of(context, Motion.quick),
              child: set.any((u) => u >= page.firstUnit && u < end)
                  ? Icon(Icons.bookmark_rounded,
                      key: const ValueKey('ribbon'), size: 22, semanticLabel: 'Bookmarked', color: look.accent)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  /// Words a reader reads in a minute, silently (about 230 for most).

  static const _readingWpm = 230;

  int _wordsLeft(_Page page) {
    final end = page.chapter + 1 < _l.chapters.length ? _l.chapterFirstUnit[page.chapter + 1] : _l.units.length;
    final from = page.firstUnit.clamp(0, _l.units.length);
    return _l.wordsBefore[end] - _l.wordsBefore[from];
  }

  Widget _pieceView(BuildContext context, _Piece p, {required bool last}) {
    final look = widget.look;
    switch (p.kind) {
      case _Kind.label:
        final label = widget.chapterLabel?.call(_l.items[p.item].chapter) ?? '';
        return SizedBox(
          height: p.height,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Row(
              children: [
                Text(label, style: look.label),
                const SizedBox(width: Gap.m),
                Expanded(child: Container(height: 1, color: look.accent.withValues(alpha: 0.35))),
              ],
            ),
          ),
        );
      case _Kind.picture:
        final b = _l.items[p.item].block!;
        return SizedBox(
          height: p.height,
          width: _columnWidth,
          child: Center(child: widget.pictureOf(b, _pictureSize(b))),
        );
      case _Kind.title:
      case _Kind.text:
        final laid = _lay(p.item);
        return Padding(
          padding: EdgeInsets.only(bottom: last ? 0 : p.gapAfter),
          child: Semantics(
            label: _sliceText(p, laid),
            child: GestureDetector(
            onLongPressStart: p.kind == _Kind.title
                ? null
                : (d) {
                    final at = laid.painter.getPositionForOffset(d.localPosition + Offset(0, p.top)).offset;
                    widget.onHold(p.item, math.max(0, at - laid.shift));
                  },
            child: CustomPaint(
              size: Size(_columnWidth, p.height),
              painter: _SlicePainter(
                laid: laid,
                top: p.top,
                item: _l.items[p.item],
                layout: _l,
                marked: widget.marked,
                word: widget.word,
                sentenceWash: look.sentenceWash,
                wordWash: look.wordWash,
              ),
            ),
          ),
          ),
        );
    }
  }
}

/// A window onto one laid-out paragraph, with the sentence being read and
/// its word washed behind the text.
class _SlicePainter extends CustomPainter {
  _SlicePainter({
    required this.laid,
    required this.top,
    required this.item,
    required this.layout,
    required this.marked,
    required this.word,
    required this.sentenceWash,
    required this.wordWash,
  }) : super(repaint: Listenable.merge([marked, word]));

  final _Laid laid;
  final double top;
  final LayoutItem item;
  final ReadingLayout layout;
  final ValueListenable<int> marked;
  final ValueListenable<WordMark> word;
  final Color sentenceWash;
  final Color wordWash;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(0, -top);
    final u = marked.value;
    final text = item.block?.text ?? '';
    if (u >= 0 && item.containsUnit(u)) {
      final s = layout.unitOffset[u].clamp(0, text.length);
      final e = (s + layout.units[u].text.length).clamp(s, text.length);
      _wash(canvas, s, e, sentenceWash);
      final w = word.value;
      if (w.unit == u && w.start >= 0) {
        final ws = (s + w.start).clamp(s, e);
        final we = (s + w.end).clamp(ws, e);
        if (we > ws) _wash(canvas, ws, we, wordWash);
      }
    }
    laid.painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _wash(Canvas canvas, int from, int to, Color color) {
    final paint = Paint()..color = color;
    for (final b in laid.painter.getBoxesForSelection(
      TextSelection(baseOffset: from + laid.shift, extentOffset: to + laid.shift),
    )) {
      if (b.bottom < top || b.top > top + 10000) continue;
      canvas.drawRRect(RRect.fromRectAndRadius(b.toRect().inflate(1.5), const Radius.circular(3)), paint);
    }
  }

  @override
  bool shouldRepaint(_SlicePainter old) =>
      old.laid != laid ||
      old.top != top ||
      old.sentenceWash != sentenceWash ||
      old.wordWash != wordWash ||
      old.marked != marked ||
      old.word != word;
}

/// Page turns with no slide: a swipe or a tap moves a whole page at once.
class _InstantPagePhysics extends PageScrollPhysics {
  const _InstantPagePhysics({super.parent});

  @override
  _InstantPagePhysics applyTo(ScrollPhysics? ancestor) => _InstantPagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => const SpringDescription(mass: 0.1, stiffness: 4000, damping: 40);
}
