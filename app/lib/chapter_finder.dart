import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'fast_scroller.dart';
import 'theme.dart';
import 'ui.dart';

/// Pick a chapter from [titles]: the one being read ([current]) marked, a
/// web novel's downloads ([onPhone]) shown, and Find a chapter by its
/// number or words from its title. The chapter picked (its place in
/// [titles]), or null.
///
/// A book's own Contents in the reader is this sheet too, set as it always
/// was: [hint] its own, [parts] read as dividers, the narrower
/// [numberWidth] of short numbers, and a drag that leaves the keyboard up
/// ([dismissOnDrag] off).
Future<int?> showChapterFinder(
  BuildContext context, {
  required List<String> titles,
  int current = -1,
  Set<int>? onPhone,
  int Function(int chapter)? numberOf,
  String heading = 'Contents',
  bool autofocus = false,
  String hint = 'Chapter number or title',
  bool parts = false,
  double numberWidth = 48,
  bool dismissOnDrag = true,
}) =>
    showModalBottomSheet<int>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(
        context,
        ChapterFinder(
          titles: titles,
          current: current,
          onPhone: onPhone,
          numberOf: numberOf,
          heading: heading,
          autofocus: autofocus,
          hint: hint,
          parts: parts,
          numberWidth: numberWidth,
          dismissOnDrag: dismissOnDrag,
        ),
      ),
    );

/// The sheet [showChapterFinder] shows; pops the chapter picked.
class ChapterFinder extends StatefulWidget {
  const ChapterFinder({
    super.key,
    required this.titles,
    this.current = -1,
    this.onPhone,
    this.numberOf,
    this.heading = 'Contents',
    this.autofocus = false,
    this.hint = 'Chapter number or title',
    this.parts = false,
    this.numberWidth = 48,
    this.dismissOnDrag = true,
  });

  final List<String> titles;
  final int current;
  final Set<int>? onPhone;

  /// The number shown for a chapter; its place in [titles] from 1 by default.
  final int Function(int chapter)? numberOf;
  final String heading;

  /// The keyboard up at once, for a sheet opened to find a chapter.
  final bool autofocus;

  /// What the search field says before anything is typed.
  final String hint;

  /// A part's title ("Part II: Reborn") reads as a divider (see [ChapterRow]).
  final bool parts;

  /// The column the numbers sit in: room for a web novel's 3222.
  final double numberWidth;

  /// A drag down the list puts the keyboard away.
  final bool dismissOnDrag;

  @override
  State<ChapterFinder> createState() => _ChapterFinderState();
}

class _ChapterFinderState extends State<ChapterFinder> {
  static const _rowHeight = 58.0;
  String _query = '';
  late final _controller = ScrollController(
    initialScrollOffset: ((widget.current - 2) * _rowHeight).clamp(0, double.infinity).toDouble(),
  );

  /// The matches of a search, from their top.
  final _found = ScrollController();

  int _number(int i) => widget.numberOf?.call(i) ?? i + 1;

  @override
  void dispose() {
    _controller.dispose();
    _found.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.titles;
    final q = _query.trim().toLowerCase();
    final rows = [
      for (var i = 0; i < all.length; i++)
        if (q.isEmpty || '${_number(i)}' == q || all[i].toLowerCase().contains(q)) i,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              widget.heading,
              trailing: Text('${all.length} ${all.length == 1 ? 'CHAPTER' : 'CHAPTERS'}', style: Skin.meta(context)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
              child: SearchField(
                hint: widget.hint,
                autofocus: widget.autofocus,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text('No chapters match.', style: Skin.label(context, size: 15)),
                    )
                  : FastScroller(
                      controller: q.isEmpty ? _controller : _found,
                      bottom: Gap.xl,
                      labelAt: (f) => 'Chapter ${_number(rows[(f * (rows.length - 1)).round()])}',
                      child: ListView.builder(
                        controller: q.isEmpty ? _controller : _found,
                        keyboardDismissBehavior: widget.dismissOnDrag ? ScrollViewKeyboardDismissBehavior.onDrag : null,
                        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xl),
                        itemExtent: _rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (context, n) {
                          final i = rows[n];
                          return ChapterRow(
                            number: _number(i),
                            title: all[i],
                            current: i == widget.current,
                            onTap: () => Navigator.pop(context, i),
                            numberWidth: widget.numberWidth,
                            parts: widget.parts,
                            onPhone: widget.onPhone?.contains(i) ?? false,
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One chapter in a list of them: its number, its title, and the one being
/// read marked in the accent with the voice's sign. With [parts], a part's
/// title ("Part II: Reborn") reads as a divider above the chapters it
/// holds; [onPhone] marks a web novel's chapter that is downloaded.
class ChapterRow extends StatelessWidget {
  const ChapterRow({
    super.key,
    required this.number,
    required this.title,
    required this.current,
    required this.onTap,
    this.numberWidth = 48,
    this.parts = false,
    this.onPhone = false,
  });

  final int number;
  final String title;
  final bool current;
  final VoidCallback onTap;
  final double numberWidth;
  final bool parts;
  final bool onPhone;

  static final _part = RegExp(r'^(part|book|volume|act)\b', caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    // The row being read is washed in the accent; its number, title and
    // sign are in the accent as type, which reads on the wash.
    final ink = Skin.accentInkOf(context);
    final part = parts && _part.hasMatch(title);
    return Material(
      color: current ? Skin.accentOf(context).withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          child: Row(
            children: [
              SizedBox(
                width: numberWidth,
                child: Text('$number', style: Skin.meta(context, size: 11.5, color: current ? ink : null)),
              ),
              Expanded(
                child: part
                    ? Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.meta(context, size: 12, color: current ? ink : Skin.inkSoftOn(context)),
                      )
                    : Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 17, color: current ? ink : null),
                      ),
              ),
              if (current)
                Icon(Icons.graphic_eq_rounded, size: 18, color: ink)
              else if (onPhone)
                Tooltip(
                  message: 'On the phone',
                  child: Icon(Icons.offline_pin_rounded, size: 18, color: Skin.inkFaintOn(context)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A book's chapters: number, title, the one being read marked. Parts
/// ("Part II: Reborn") read as dividers above the chapters they hold.
class ChapterList extends StatelessWidget {
  const ChapterList({
    super.key,
    required this.layout,
    required this.chapters,
    required this.current,
    required this.onPick,
    this.numberOf,
    this.controller,
    this.rowHeight = 56,
    this.shrinkWrap = false,
  });

  final ReadingLayout layout;

  /// The number shown for a chapter; its place in [layout] by default.
  final int Function(int chapter)? numberOf;
  final List<int> chapters;
  final int current;
  final ValueChanged<int> onPick;
  final ScrollController? controller;
  final double rowHeight;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) => ListView.builder(
        controller: controller,
        shrinkWrap: shrinkWrap,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xl),
        itemExtent: rowHeight,
        itemCount: chapters.length,
        itemBuilder: (context, i) => chapterRow(context, chapters[i]),
      );

  Widget chapterRow(BuildContext context, int c) => ChapterRow(
        number: numberOf?.call(c) ?? c + 1,
        title: layout.chapterTitle(c),
        current: c == current,
        onTap: () => onPick(c),
        numberWidth: 40,
        parts: true,
      );
}
