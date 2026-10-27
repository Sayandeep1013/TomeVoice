import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'page_curl.dart';
import 'paged_view.dart' show PageTurn;
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// A PDF as its real pages: the layout, pictures and typography of the
/// original, while the voice keeps reading the extracted text. The page being
/// read is outlined in amber and followed as the voice moves on.
class PdfPagesView extends StatefulWidget {
  const PdfPagesView({
    super.key,
    required this.path,
    required this.layout,
    required this.cursor,
    required this.detached,
    required this.onTapPage,
    this.turn,
    this.spread = false,
    this.onTurned,
  });

  final String path;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;

  /// True while the user has scrolled away from the voice.
  final ValueNotifier<bool> detached;
  final ValueChanged<int> onTapPage;

  /// Turned like a book's pages, one at a time (two in a [spread]), instead
  /// of scrolled; null scrolls.
  final PageTurn? turn;
  final bool spread;

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

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_onCursor);
    widget.detached.addListener(_onDetached);
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_onCursor);
    widget.detached.removeListener(_onDetached);
    _turner.dispose();
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

  void _reveal(int page, {bool force = false}) {
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
          void settled(int i, {required bool byHand}) => widget.onTurned?.call(i * per, byHand: byHand);
          Widget leaf(BuildContext context, int i, int side) {
            final page = i * per + side;
            if (page >= pages) return const SizedBox.shrink();
            return GestureDetector(
              onLongPress: () {
                unawaited(HapticFeedback.selectionClick());
                widget.onTapPage(page);
              },
              child: _image(context, page, w / per),
            );
          }

          final Widget book = widget.turn == PageTurn.curl
              ? PageCurl(
                  controller: _curl,
                  itemCount: items,
                  initialIndex: start,
                  leaf: leaf,
                  paper: const BoxDecoration(color: Colors.white),
                  spread: widget.spread,
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
                  child: PageView.builder(
                    controller: _turner,
                    itemCount: items,
                    physics: widget.turn == PageTurn.slide ? null : const ClampingScrollPhysics(),
                    itemBuilder: (context, i) => Row(
                      children: [
                        for (var side = 0; side < per; side++)
                          Expanded(child: ColoredBox(color: Colors.white, child: leaf(context, i, side))),
                      ],
                    ),
                  ),
                );
          return Center(
            child: Container(
              width: w,
              height: h,
              decoration: BoxDecoration(boxShadow: Skin.lift(context)),
              child: book,
            ),
          );
        },
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
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: current ? Skin.accentOf(context) : Colors.transparent,
                    width: 3,
                  ),
                  boxShadow: Skin.lift(context),
                ),
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: FutureBuilder<String>(
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
