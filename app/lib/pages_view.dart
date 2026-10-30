import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'page_curl.dart';
import 'paged_view.dart' show InstantPagePhysics, PageTurn;
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// Turns [PdfPagesView]'s pages from outside.
class PdfPagesController {
  _PdfPagesViewState? _state;

  /// A page on (1) or back (-1), as by the reader's hand (a key).
  void turn(int delta) => _state?._turn(delta);
}

/// Black print on white paper as [ink] on [paper], and every colour between
/// turned over with its hue kept: inverted, then its hue turned half way
/// round, so a picture keeps its colours instead of becoming a negative.
ColorFilter invertedPage({required Color paper, required Color ink}) =>
    ColorFilter.matrix(invertedPageMatrix(paper: paper, ink: ink));

/// The colour matrix of [invertedPage]: rows red, green, blue and alpha,
/// each four weights and an offset out of 255.
List<double> invertedPageMatrix({required Color paper, required Color ink}) {
  // Hue turned 180 degrees, keeping lightness (the CSS hue-rotate matrix).
  const hue = [
    [-0.574, 1.430, 0.144],
    [0.426, 0.430, 0.144],
    [0.426, 1.430, -0.856],
  ];
  final to = [ink.r, ink.g, ink.b];
  final span = [ink.r - paper.r, ink.g - paper.g, ink.b - paper.b];
  return [
    for (var c = 0; c < 3; c++) ...[
      for (final h in hue[c]) -span[c] * h,
      0,
      to[c] * 255,
    ],
    0, 0, 0, 1, 0,
  ];
}

/// A PDF as its real pages: the layout, pictures and typography of the
/// original, while the voice keeps reading the extracted text. The page being
/// read is outlined in amber and followed as the voice moves on.
///
/// Each page zooms: pinch it, or tap twice to look closer and twice to come
/// back. A page zoomed in moves under the finger, and the book does not turn
/// (nor the pages scroll) by hand until it is back to its whole size; a key
/// still turns it.
class PdfPagesView extends StatefulWidget {
  const PdfPagesView({
    super.key,
    required this.path,
    required this.layout,
    required this.cursor,
    required this.detached,
    required this.onTapPage,
    this.controller,
    this.turn,
    this.spread = false,
    this.tapToTurn = true,
    this.dark,
    this.onTurned,
  });

  final String path;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;

  /// True while the user has scrolled away from the voice.
  final ValueNotifier<bool> detached;
  final ValueChanged<int> onTapPage;
  final PdfPagesController? controller;

  /// Turned like a book's pages, one at a time (two in a [spread]), instead
  /// of scrolled; null scrolls.
  final PageTurn? turn;
  final bool spread;

  /// A tap at a side turns the page, as on the text's pages.
  final bool tapToTurn;

  /// A dark page tone: the page drawn in its paper and its print in its ink
  /// (see [invertedPage]), so a white page is no lamp at night. Null keeps
  /// the page as it was printed.
  final ({Color paper, Color ink})? dark;

  /// A page came to rest; [byHand] when the reader turned to it.
  final void Function(int page, {required bool byHand})? onTurned;

  @override
  State<PdfPagesView> createState() => _PdfPagesViewState();
}

class _PdfPagesViewState extends State<PdfPagesView> {
  late final Future<({int pages, List<double> aspects})> _info =
      _svc.pdfInfo(widget.path);
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _renders = <String, Future<String>>{};
  int _pageCount = 0;
  int _current = 0;
  bool _programmatic = false;

  /// Pages zoomed in just now. While any is, a finger moves the page and
  /// does not turn or scroll the book.
  final _zoomed = <int>{};

  /// Changed to bring every page back to its whole size.
  final _unzoom = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    widget.cursor.addListener(_onCursor);
    widget.detached.addListener(_onDetached);
  }

  @override
  void didUpdateWidget(PdfPagesView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller?._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    widget.cursor.removeListener(_onCursor);
    widget.detached.removeListener(_onDetached);
    _turner.dispose();
    _unzoom.dispose();
    super.dispose();
  }

  int _pageOf(int unit) {
    final l = widget.layout;
    if (l.units.isEmpty || _pageCount == 0) return 0;
    final u = unit.clamp(0, l.units.length - 1);
    if (l.hasPages) return l.unitPage[u].clamp(0, _pageCount - 1);
    // Parsed before page numbers were kept: place by position in the book.
    return (u * _pageCount ~/ l.units.length).clamp(0, _pageCount - 1);
  }

  void _onCursor() {
    final page = _pageOf(widget.cursor.value);
    if (page == _current) return;
    setState(() => _current = page);
    if (!widget.detached.value) _reveal(page);
  }

  final _curl = CurlController();
  late final _turner = PageController(initialPage: _current ~/ _per);

  /// The pages were turned by a finger since they last settled.
  bool _hand = false;
  int get _per => widget.spread ? 2 : 1;

  void _onDetached() {
    if (!widget.detached.value) _reveal(_current, force: true);
  }

  /// A page zoomed in, or back to its whole size: the book turns by hand
  /// again only once none is zoomed.
  void _onZoom(int page, bool zoomed) {
    final was = _zoomed.isNotEmpty;
    if (zoomed) {
      _zoomed.add(page);
    } else {
      _zoomed.remove(page);
    }
    if (mounted && _zoomed.isNotEmpty != was) setState(() {});
  }

  void _reveal(int page, {bool force = false}) {
    // Following the voice to another page: every page back to its size.
    if (_zoomed.isNotEmpty) _unzoom.value++;
    if (widget.turn != null) {
      final item = page ~/ _per;
      if (widget.turn == PageTurn.curl) {
        _curl.turnTo(item);
      } else if (_turner.hasClients) {
        final near = (_turner.page?.round() ?? item) - item;
        if (near.abs() == 1 && widget.turn == PageTurn.slide && !Motion.reduced(context)) {
          unawaited(_turner.animateToPage(item, duration: Motion.standard, curve: Motion.out));
        } else {
          _turner.jumpToPage(item);
        }
      }
      return;
    }
    if (!_scroll.isAttached) return;
    if (!force) {
      for (final p in _positions.itemPositions.value) {
        if (p.index == page && p.itemLeadingEdge >= -0.05 && p.itemTrailingEdge <= 1.05) return;
      }
    }
    _programmatic = true;
    // Far away or motion turned down: straight there, without the list's
    // cross-fade of two copies of the pages.
    if (!_positions.itemPositions.value.any((p) => p.index == page) || Motion.reduced(context)) {
      _scroll.jumpTo(index: page, alignment: 0.02);
      _programmatic = false;
      return;
    }
    unawaited(_scroll
        .scrollTo(
          index: page,
          alignment: 0.02,
          duration: Motion.follow,
          curve: Curves.easeInOutCubic,
        )
        .whenComplete(() => _programmatic = false));
  }

  /// A page on or back by a key, a tap at a side or TalkBack, as the text's
  /// pages turn: curled over, slid, or at once.
  void _turn(int delta) {
    if (widget.turn == null || _pageCount == 0) return;
    if (widget.turn == PageTurn.curl) {
      _curl.step(delta);
      return;
    }
    if (!_turner.hasClients) return;
    final items = (_pageCount + _per - 1) ~/ _per;
    final now = _turner.page?.round() ?? 0;
    final i = (now + delta).clamp(0, items - 1);
    if (i == now) return;
    _hand = true;
    final d = Motion.of(context, Motion.standard);
    if (widget.turn == PageTurn.slide && d > Duration.zero) {
      unawaited(_turner.animateToPage(i, duration: d, curve: Motion.out));
    } else {
      _turner.jumpToPage(i);
    }
  }

  /// The page drawn dark on a dark page tone.
  Widget _ink(Widget page) {
    final dark = widget.dark;
    if (dark == null) return page;
    return ColorFiltered(colorFilter: invertedPage(paper: dark.paper, ink: dark.ink), child: page);
  }

  /// The paper behind a page: white, or the dark tone's.
  Color get _paper => widget.dark?.paper ?? Colors.white;

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _info,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  'This PDF\'s pages cannot be shown here. The text view still works.',
                  textAlign: TextAlign.center,
                  style: Skin.label(context, size: 13),
                ),
              ),
            );
          }
          final info = snap.data;
          if (info == null) {
            return Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Skin.accentOf(context)),
              ),
            );
          }
          _pageCount = info.pages;
          _current = _pageOf(widget.cursor.value);
          if (widget.turn != null) return FadeIn(child: _book(context, info.pages, info.aspects));
          // The pages fade in over the spinner's place, rather than cut in.
          return FadeIn(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null && !_programmatic) {
                  widget.detached.value = true;
                }
                return false;
              },
              child: ScrollablePositionedList.builder(
                itemCount: info.pages,
                itemScrollController: _scroll,
                itemPositionsListener: _positions,
                initialScrollIndex: _current,
                // A page zoomed in takes the finger: it moves under it.
                physics: _zoomed.isEmpty ? null : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 120),
                itemBuilder: (context, i) => _page(context, i, info.aspects[i]),
              ),
            ),
          );
        },
      );

  /// The pages as a book: each leaf the page's own shape, so the paper
  /// that turns is the page itself.
  Widget _book(BuildContext context, int pages, List<double> aspects) => LayoutBuilder(
        builder: (context, box) {
          final per = _per;
          final aspect = aspects.isEmpty ? 0.75 : aspects.first;
          final room = Size(box.maxWidth - 24, box.maxHeight - 24);
          var w = room.width;
          var h = w / (aspect * per);
          if (h > room.height) {
            h = room.height;
            w = h * aspect * per;
          }
          final items = (pages + per - 1) ~/ per;
          final start = _current ~/ per;
          final zoomed = _zoomed.isNotEmpty;
          void settled(int i, {required bool byHand}) => widget.onTurned?.call(i * per, byHand: byHand);
          Widget leaf(BuildContext context, int i, int side) {
            final page = i * per + side;
            if (page >= pages) return const SizedBox.shrink();
            return GestureDetector(
              onLongPress: () {
                unawaited(HapticFeedback.selectionClick());
                widget.onTapPage(page);
              },
              child: _ZoomPage(
                key: ValueKey(page),
                page: page,
                unzoom: _unzoom,
                onZoom: _onZoom,
                // Two taps zoom where one does nothing else: between the
                // sides that turn the page, or anywhere once zoomed in.
                quiet: (at, size) {
                  if (_zoomed.isNotEmpty || !widget.tapToTurn) return true;
                  final x = (side + at.dx / size.width) / per;
                  return x >= 0.28 && x <= 0.72;
                },
                child: _ink(_image(context, page, w / per)),
              ),
            );
          }

          final Widget book = widget.turn == PageTurn.curl
              ? PageCurl(
                  controller: _curl,
                  itemCount: items,
                  initialIndex: start,
                  leaf: leaf,
                  paper: BoxDecoration(color: _paper),
                  spread: widget.spread,
                  crease: Colors.black,
                  tapToTurn: widget.tapToTurn,
                  held: zoomed,
                  onSettled: settled,
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollStartNotification && n.dragDetails != null) _hand = true;
                    if (n is ScrollEndNotification && _turner.hasClients) {
                      settled(_turner.page?.round() ?? 0, byHand: _hand);
                      _hand = false;
                    }
                    return false;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // TalkBack turns pages by the book's actions (see
                    // _turnable): its double tap arrives here with no place.
                    excludeFromSemantics: true,
                    onTapUp: (d) {
                      if (zoomed || !widget.tapToTurn) return;
                      final x = d.localPosition.dx / w;
                      if (x < 0.28) {
                        _turn(-1);
                      } else if (x > 0.72) {
                        _turn(1);
                      }
                    },
                    child: PageView.builder(
                      controller: _turner,
                      itemCount: items,
                      // Zoomed in, a drag moves the page instead of turning it.
                      physics: zoomed
                          ? const NeverScrollableScrollPhysics()
                          : widget.turn == PageTurn.slide
                              ? null
                              : const InstantPagePhysics(),
                      itemBuilder: (context, i) => Row(
                        children: [
                          for (var side = 0; side < per; side++)
                            Expanded(child: ColoredBox(color: _paper, child: leaf(context, i, side))),
                        ],
                      ),
                    ),
                  ),
                );
          return Center(
            child: _turnable(
              Container(
                width: w,
                height: h,
                decoration: BoxDecoration(boxShadow: Skin.lift(context)),
                child: book,
              ),
            ),
          );
        },
      );

  /// The page turns as TalkBack actions (with the two-finger swipe), as on
  /// the text's pages: the taps at the sides are not reachable to it.
  Widget _turnable(Widget child) => Semantics(
        container: true,
        explicitChildNodes: true,
        onScrollLeft: () => _turn(1),
        onScrollRight: () => _turn(-1),
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Next page'): () => _turn(1),
          const CustomSemanticsAction(label: 'Previous page'): () => _turn(-1),
        },
        child: child,
      );

  /// Page [index] rendered for a width of [width], fading in over its number.
  Widget _image(BuildContext context, int index, double width) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = ((width * dpr) / 120).ceil() * 120;
    final file = _renders.putIfAbsent('$index@$px', () => _svc.pdfRender(widget.path, index, px));
    return FutureBuilder<String>(
      future: file,
      builder: (context, snap) {
        final path = snap.data;
        final number = Center(
          child: Text('${index + 1}', style: Skin.meta(context, color: Skin.inkFaint, size: 11)),
        );
        if (path == null) return number;
        return Image.file(
          File(path),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          frameBuilder: fadeInOver(number),
        );
      },
    );
  }

  Widget _page(BuildContext context, int index, double aspect) {
    final current = index == _current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          // Round so a small layout change does not render every page again.
          final px = ((c.maxWidth * dpr) / 120).ceil() * 120;
          final key = '$index@$px';
          final file = _renders.putIfAbsent(key, () => _svc.pdfRender(widget.path, index, px));
          // Press and hold reads from the page, as on the text: a tap (to
          // stop a fling) must not move the voice. A screen reader's double
          // tap still does.
          return GestureDetector(
            onLongPress: () {
              unawaited(HapticFeedback.selectionClick());
              widget.onTapPage(index);
            },
            child: Semantics(
              button: true,
              label: 'Page ${index + 1}. Double tap to read from here',
              onTap: () => widget.onTapPage(index),
              child: AnimatedContainer(
                duration: Motion.of(context, Motion.standard),
                decoration: BoxDecoration(
                  color: _paper,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: current ? Skin.accentOf(context) : Colors.transparent,
                    width: 3,
                  ),
                  boxShadow: Skin.lift(context),
                ),
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: _ZoomPage(
                    key: ValueKey(index),
                    page: index,
                    unzoom: _unzoom,
                    onZoom: _onZoom,
                    // A tap on the scrolling pages does nothing else.
                    quiet: (_, __) => true,
                    child: _ink(FutureBuilder<String>(
                      future: file,
                      builder: (context, snap) {
                        final path = snap.data;
                        final number = Center(
                          child: Text('${index + 1}', style: Skin.meta(context, color: Skin.inkFaint, size: 11)),
                        );
                        if (path == null) return number;
                        // The page fades in over its number as it decodes,
                        // instead of popping over it.
                        return Image.file(
                          File(path),
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          frameBuilder: fadeInOver(number),
                        );
                      },
                    )),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One page, zoomed by a pinch or by two taps, and moved under a finger
/// while zoomed in. The pinch is claimed as soon as a second finger is down
/// (see [_Pinch]), so the book's turn or the list's scroll, which follow one
/// finger, never take a pinch for themselves.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({
    super.key,
    required this.page,
    required this.unzoom,
    required this.onZoom,
    required this.quiet,
    required this.child,
  });

  final int page;

  /// Brings the page back to its whole size each time it changes.
  final Listenable unzoom;

  /// The page was zoomed in ([zoomed]), or came back to its whole size.
  final void Function(int page, bool zoomed) onZoom;

  /// Whether a tap at [at] on the page (of [size]) does nothing else, so two
  /// of them zoom: a tap at a side turns the page instead.
  final bool Function(Offset at, Size size) quiet;
  final Widget child;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> with SingleTickerProviderStateMixin {
  /// As close as a page comes, and how close two taps bring it.
  static const _most = 5.0;
  static const _closer = 2.5;

  final _zoom = TransformationController();
  late final _glide = AnimationController(vsync: this, duration: Motion.standard)..addListener(_onGlide);
  Matrix4Tween? _tween;
  bool _zoomed = false;

  /// A pinch begun: the page's zoom then, and the point of the page under
  /// the fingers, which stays under them.
  double _pinchScale = 1;
  Offset _pinchAt = Offset.zero;

  /// The finger on the page, and whether it is still a tap: not moved, not
  /// joined by another.
  int? _finger;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  bool _tap = false;

  /// The tap before, while a second can still make it two, and whether the
  /// finger on the page came down in time to be that second.
  Offset? _tapAt;
  Timer? _tapWindow;
  bool _second = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
    widget.unzoom.addListener(_whole);
  }

  @override
  void didUpdateWidget(_ZoomPage old) {
    super.didUpdateWidget(old);
    if (old.unzoom != widget.unzoom) {
      old.unzoom.removeListener(_whole);
      widget.unzoom.addListener(_whole);
    }
  }

  @override
  void dispose() {
    widget.unzoom.removeListener(_whole);
    _tapWindow?.cancel();
    _glide.dispose();
    _zoom.dispose();
    if (_zoomed) {
      // Gone while zoomed in (turned or scrolled away): the book turns by
      // hand again. After this frame: the tree is being taken down now.
      final page = widget.page, onZoom = widget.onZoom;
      WidgetsBinding.instance.addPostFrameCallback((_) => onZoom(page, false));
    }
    super.dispose();
  }

  void _onZoom() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoom(widget.page, zoomed);
  }

  /// Zoom [s] with the page's corner at [at], held so the page still fills
  /// its place: nothing beside it shows while zoomed in.
  Matrix4 _fit(double s, Offset at) {
    final size = context.size ?? Size.zero;
    final x = at.dx.clamp(size.width * (1 - s), 0.0);
    final y = at.dy.clamp(size.height * (1 - s), 0.0);
    return Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, x, y, 0, 1);
  }

  void _glideTo(Matrix4 to) {
    _glide.stop();
    if (Motion.reduced(context)) {
      _zoom.value = to;
      return;
    }
    _tween = Matrix4Tween(begin: _zoom.value.clone(), end: to);
    unawaited(_glide.forward(from: 0));
  }

  void _onGlide() {
    final tween = _tween;
    if (tween != null) _zoom.value = tween.transform(Motion.out.transform(_glide.value));
  }

  /// Back to the whole page (the book moved on).
  void _whole() {
    if (_zoom.value.getMaxScaleOnAxis() > 1.01) _glideTo(Matrix4.identity());
  }

  /// Two taps: closer, there; or back out to the whole page.
  void _toggle(Offset at) {
    if (_zoom.value.getMaxScaleOnAxis() > 1.01) {
      _glideTo(Matrix4.identity());
    } else {
      _glideTo(_fit(_closer, at - at * _closer));
    }
  }

  void _pinchStart(Offset focal) {
    _glide.stop();
    final m = _zoom.value;
    _pinchScale = m.getMaxScaleOnAxis();
    _pinchAt = Offset((focal.dx - m.storage[12]) / _pinchScale, (focal.dy - m.storage[13]) / _pinchScale);
  }

  void _pinchUpdate(double scale, Offset focal) {
    final s = (_pinchScale * scale).clamp(1.0, _most);
    _zoom.value = _fit(s, focal - _pinchAt * s);
  }

  void _pinchEnd() {
    // Let go near its whole size: exactly whole, so it turns again.
    if (_zoom.value.getMaxScaleOnAxis() < 1.01) _zoom.value = Matrix4.identity();
  }

  // Two taps, from the raw pointer: a recogniser for them would hold every
  // single tap back until it knew, and a tap at a side turns the page.

  void _down(PointerDownEvent e) {
    if (_finger != null) {
      _tap = false;
      return;
    }
    _finger = e.pointer;
    _downAt = e.localPosition;
    _downTime = e.timeStamp;
    _tap = true;
    _second = _tapAt != null;
    _tapWindow?.cancel();
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer == _finger && (e.localPosition - _downAt).distance > kTouchSlop) _tap = false;
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _finger) return;
    _finger = null;
    final size = context.size;
    // Held long, it was a press and hold (read from here), not a tap.
    final tap = _tap && size != null && e.timeStamp - _downTime < kLongPressTimeout && widget.quiet(e.localPosition, size);
    final before = _tapAt;
    _tapAt = null;
    if (!tap) return;
    if (_second && before != null && (e.localPosition - before).distance <= kDoubleTapSlop) {
      _toggle(e.localPosition);
      return;
    }
    _tapAt = e.localPosition;
    _tapWindow = Timer(kDoubleTapTimeout, () => _tapAt = null);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (e) {
          if (e.pointer != _finger) return;
          _finger = null;
          _tapAt = null;
        },
        child: RawGestureDetector(
          excludeFromSemantics: true,
          gestures: {
            _Pinch: GestureRecognizerFactoryWithHandlers<_Pinch>(
              () => _Pinch(debugOwner: this),
              (pinch) => pinch
                ..onStart = _pinchStart
                ..onUpdate = _pinchUpdate
                ..onEnd = _pinchEnd,
            ),
          },
          child: InteractiveViewer(
            transformationController: _zoom,
            minScale: 1,
            maxScale: _most,
            onInteractionStart: (_) => _glide.stop(),
            child: widget.child,
          ),
        ),
      );
}

/// Two fingers on a page, claimed the moment the second is down: before a
/// one-finger drag (the book's turn, the list's scroll) has gone far enough
/// to take them, which it did as one finger of a pinch moved. One finger
/// alone is never this gesture; it is left to the rest.
class _Pinch extends OneSequenceGestureRecognizer {
  _Pinch({super.debugOwner});

  void Function(Offset focal)? onStart;
  void Function(double scale, Offset focal)? onUpdate;
  VoidCallback? onEnd;

  final _at = <int, Offset>{};
  bool _pinching = false;
  double _span = 0;

  Offset get _focal {
    var sum = Offset.zero;
    for (final p in _at.values) {
      sum += p;
    }
    return sum / _at.length.toDouble();
  }

  double get _spread {
    final f = _focal;
    var sum = 0.0;
    for (final p in _at.values) {
      sum += (p - f).distance;
    }
    return sum / _at.length;
  }

  /// A pinch (re)started from where the fingers are now.
  void _begin() {
    _pinching = true;
    _span = _spread;
    onStart?.call(_focal);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _at[event.pointer] = event.localPosition;
    if (_at.length < 2) return;
    // Another finger joined a pinch: carry on from where they all are.
    if (_pinching) _begin();
    resolve(GestureDisposition.accepted);
  }

  @override
  void acceptGesture(int pointer) {
    if (!_pinching && _at.length >= 2) _begin();
  }

  @override
  void rejectGesture(int pointer) {
    _at.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (!_at.containsKey(event.pointer)) return;
      _at[event.pointer] = event.localPosition;
      if (_pinching && _at.length >= 2) onUpdate?.call(_span > 0 ? _spread / _span : 1, _focal);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _at.remove(event.pointer);
      if (_pinching) {
        if (_at.length >= 2) {
          _begin();
        } else {
          _pinching = false;
          onEnd?.call();
        }
      }
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (_pinching) onEnd?.call();
    _pinching = false;
    _at.clear();
    resolve(GestureDisposition.rejected);
  }

  @override
  String get debugDescription => 'pinch';
}

/// A picture from the book, full screen, pinch to zoom.
class PictureViewer extends StatelessWidget {
  const PictureViewer({super.key, required this.file, this.caption});

  final File file;
  final String? caption;

  static Future<void> open(BuildContext context, File file, {String? caption}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => PictureViewer(file: file, caption: caption),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 8,
                child: Center(child: Image.file(file, fit: BoxFit.contain)),
              ),
            ),
            // Positioned, so the stack takes the whole screen: as the only
            // unpositioned child this button sized the stack to itself and
            // squeezed the picture into its corner.
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: RoundButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Close',
                    color: Colors.white.withValues(alpha: 0.14),
                    iconColor: Colors.white,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
            if ((caption ?? '').isNotEmpty)
              Positioned(
                left: 20,
                right: 20,
                bottom: 28,
                child: SafeArea(
                  child: Text(
                    caption!,
                    textAlign: TextAlign.center,
                    style: Skin.label(context, color: Colors.white70, size: 12.5),
                  ),
                ),
              ),
          ],
        ),
      );
}
