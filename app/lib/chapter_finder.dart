import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'fast_scroller.dart';
import 'notebook.dart' show NotebookInk;
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

  /// The book's parts, where [ChapterFinder.parts] reads them: the first
  /// row of each, a part's own title ("Part II") or its first chapter's
  /// ("Part II · I: Of Spaceland", as a book's contents join them). Two or
  /// more get tabs down the side.
  late final List<int> _parts = !widget.parts
      ? const []
      : [
          for (var i = 0; i < widget.titles.length; i++)
            if (ChapterRow.partOf(widget.titles[i]) case final p?)
              if (i == 0 || ChapterRow.partOf(widget.titles[i - 1]) != p) i,
        ];

  /// The part (an index into [_parts]) row [i] is in, or null for a row in
  /// none (a preface before the first part).
  int? _partAt(int i) {
    if (ChapterRow.partOf(widget.titles[i]) == null) return null;
    int? at;
    for (var p = 0; p < _parts.length && _parts[p] <= i; p++) {
      at = p;
    }
    return at;
  }

  /// The tab of [part] (an index into [_parts]).
  Color _tabColour(BuildContext context, int part) => NotebookInk.of(context).tab(part);

  void _toPart(int part) {
    if (!_controller.hasClients) return;
    final to = (_parts[part] * _rowHeight).clamp(0.0, _controller.position.maxScrollExtent);
    if (Motion.reduced(context)) {
      _controller.jumpTo(to);
    } else {
      _controller.animateTo(to, duration: Motion.of(context, Motion.page), curve: Motion.emphasized);
    }
  }

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
                  : _withTabs(
                      context,
                      show: q.isEmpty && _parts.length >= 2,
                      child: FastScroller(
                        controller: q.isEmpty ? _controller : _found,
                        bottom: Gap.xl,
                        labelAt: (f) => 'Chapter ${_number(rows[(f * (rows.length - 1)).round()])}',
                        child: ListView.builder(
                          controller: q.isEmpty ? _controller : _found,
                          keyboardDismissBehavior:
                              widget.dismissOnDrag ? ScrollViewKeyboardDismissBehavior.onDrag : null,
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
                              tab: _parts.length >= 2
                                  ? switch (_partAt(i)) { final p? => _tabColour(context, p), _ => null }
                                  : null,
                            );
                          },
                        ),
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
extension on _ChapterFinderState {
  /// [child], with the parts' coloured tabs down its right edge when
  /// [show]: each opens its part, and the one in view stands out.
  Widget _withTabs(BuildContext context, {required bool show, required Widget child}) {
    if (!show) return child;
    final ink = NotebookInk.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: child),
        SizedBox(
          width: 34,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final top = _controller.hasClients ? _controller.offset / _ChapterFinderState._rowHeight + 0.5 : 0;
              var at = 0;
              for (var p = 0; p < _parts.length; p++) {
                if (_parts[p] <= top) at = p;
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                itemCount: _parts.length,
                itemBuilder: (context, p) {
                  final open = p == at;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Semantics(
                      button: true,
                      selected: open,
                      label: ChapterRow.partOf(widget.titles[_parts[p]]) ?? widget.titles[_parts[p]],
                      excludeSemantics: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toPart(p),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AnimatedContainer(
                            duration: Motion.of(context, Motion.quick),
                            curve: Motion.out,
                            width: open ? 32 : 24,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: open ? ink.tab(p) : ink.tab(p).withValues(alpha: 0.55),
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                            ),
                            child: Text('${p + 1}',
                                style: Skin.ui(size: 12.5, weight: FontWeight.w800, color: ink.tabInk)),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

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
    this.tab,
  });

  /// A part's tab colour (see ChapterFinder's tabs), marked on its divider.
  final Color? tab;

  /// Whether [title] reads as a part's ("Part II: Reborn").
  static bool isPart(String title) => _part.hasMatch(title) && !title.contains(_joiner);

  /// The part [title] is in ("Part I: This World" of "Part I: This World ·
  /// I: Of the Nature of Flatland", as a book's contents join a part and
  /// its chapter), or the part it is ("Part II"); null when it names none.
  static String? partOf(String title) {
    if (!_part.hasMatch(title)) return null;
    final i = title.indexOf(_joiner);
    return i < 0 ? title : title.substring(0, i);
  }

  static const _joiner = ' · ';

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
    // A part's own title reads as a divider. A chapter its part's name is
    // joined to is a chapter: with its part's tab colour beside it, its own
    // name is enough.
    final part = parts && isPart(title);
    final joined = title.indexOf(_joiner);
    final shown = parts && tab != null && joined > 0 && _part.hasMatch(title)
        ? title.substring(joined + _joiner.length)
        : title;
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
                    ? Row(
                        children: [
                          if (tab != null) ...[
                            Container(
                              width: 4,
                              height: 18,
                              decoration: BoxDecoration(color: tab, borderRadius: BorderRadius.circular(2)),
                            ),
                            const SizedBox(width: Gap.s),
                          ],
                          Expanded(
                            child: Text(
                              title.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Skin.meta(context, size: 12, color: current ? ink : Skin.inkSoftOn(context)),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (tab != null) ...[
                            Container(
                              width: 4,
                              height: 18,
                              decoration: BoxDecoration(color: tab, borderRadius: BorderRadius.circular(2)),
                            ),
                            const SizedBox(width: Gap.s),
                          ],
                          Expanded(
                            child: Text(
                              shown,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Skin.title(context, size: 17, color: current ? ink : null),
                            ),
                          ),
                        ],
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
