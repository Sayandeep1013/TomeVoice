import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'speech_service.dart';
import 'theme.dart';

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
  });

  final String path;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;

  /// True while the user has scrolled away from the voice.
  final ValueNotifier<bool> detached;
  final ValueChanged<int> onTapPage;

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

  void _onDetached() {
    if (!widget.detached.value) _reveal(_current, force: true);
  }

  void _reveal(int page, {bool force = false}) {
    if (!_scroll.isAttached) return;
    if (!force) {
      for (final p in _positions.itemPositions.value) {
        if (p.index == page && p.itemLeadingEdge >= -0.05 && p.itemTrailingEdge <= 1.05) return;
      }
    }
    _programmatic = true;
    unawaited(_scroll
        .scrollTo(
          index: page,
          alignment: 0.02,
          duration: const Duration(milliseconds: 380),
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
            return const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Skin.amber),
              ),
            );
          }
          _pageCount = info.pages;
          _current = _pageOf(widget.cursor.value);
          return NotificationListener<ScrollNotification>(
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
          );
        },
      );

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
          return GestureDetector(
            onTap: () => widget.onTapPage(index),
            child: Semantics(
              button: true,
              label: 'Page ${index + 1}. Double tap to read from here',
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: current ? Skin.amber : Colors.transparent,
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
                      if (path == null) {
                        return Center(
                          child: Text('${index + 1}',
                              style: Skin.meta(context, color: Skin.inkFaint, size: 11)),
                        );
                      }
                      return Image.file(
                        File(path),
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
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
            SafeArea(
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
