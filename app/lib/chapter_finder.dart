import 'package:flutter/material.dart';

import 'book_tint.dart';
import 'fast_scroller.dart';
import 'theme.dart';
import 'ui.dart';

/// Pick a chapter from [titles]: the one being read ([current]) marked, a
/// web novel's downloads ([onPhone]) shown, and Find a chapter by its
/// number or words from its title. The chapter picked (its place in
/// [titles]), or null.
Future<int?> showChapterFinder(
  BuildContext context, {
  required List<String> titles,
  int current = -1,
  Set<int>? onPhone,
  int Function(int chapter)? numberOf,
  String heading = 'Contents',
  bool autofocus = false,
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
  });

  final List<String> titles;
  final int current;
  final Set<int>? onPhone;

  /// The number shown for a chapter; its place in [titles] from 1 by default.
  final int Function(int chapter)? numberOf;
  final String heading;

  /// The keyboard up at once, for a sheet opened to find a chapter.
  final bool autofocus;

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
    final accent = Skin.accentOf(context);
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
                hint: 'Chapter number or title',
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
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xl),
                        itemExtent: _rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (context, n) => _row(context, rows[n], accent),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, Color accent) {
    final isCurrent = i == widget.current;
    return Material(
      color: isCurrent ? accent.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => Navigator.pop(context, i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text('${_number(i)}', style: Skin.meta(context, size: 11.5, color: isCurrent ? accent : null)),
              ),
              Expanded(
                child: Text(
                  widget.titles[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.title(context, size: 17, color: isCurrent ? accent : null),
                ),
              ),
              if (isCurrent)
                Icon(Icons.graphic_eq_rounded, size: 18, color: accent)
              else if (widget.onPhone?.contains(i) ?? false)
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
