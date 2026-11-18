import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'highlights.dart';
import 'journal.dart';
import 'journal_page.dart' show JournalEntryCard;
import 'library_store.dart';
import 'marks.dart';
import 'page_tone.dart';
import 'theme.dart';

/// A field notebook, a page a book: its cover taped at the top, what was
/// written about it in handwriting on squared paper (the journal; quotes
/// under their highlighter's colour too, when given), and coloured,
/// numbered tabs down the edge to turn to a book. The idea of a
/// spiral-bound field notebook, drawn here from scratch.
class NotebookPages extends StatefulWidget {
  const NotebookPages({
    super.key,
    required this.pages,
    required this.books,
    required this.present,
    required this.onOpen,
    required this.onAction,
    this.journal = const {},
    this.onJournal,
    this.onJournalHold,
  });

  /// A page a book, in order: its id and what was saved from it, newest
  /// first (none, for a book with only its journal).
  final List<(String, List<Mark>)> pages;

  /// Each book's journal, newest first (journal.dart).
  final Map<String, List<JournalEntry>> journal;

  /// An entry tapped (to change it) or held (to remove it).
  final void Function(JournalEntry)? onJournal;
  final void Function(JournalEntry)? onJournalHold;

  /// Book [id]'s title, as what was saved from it has it.
  String titleOf(String id, List<Mark> marks) =>
      marks.firstOrNull?.bookTitle ?? journal[id]?.firstOrNull?.bookTitle ?? books[id]?.title ?? '';

  /// The books in the library by id; a book not there is gone (or hidden).
  final Map<String, LibraryEntry> books;

  /// Whether a book is still in the library at all.
  final bool Function(String bookId) present;

  final void Function(Mark) onOpen;

  /// Press and hold a quote: what to do with it (a note, share, remove).
  final void Function(Mark) onAction;

  @override
  State<NotebookPages> createState() => _NotebookPagesState();
}

/// The notebook's colours: its paper, its pens and its tabs, by day and by
/// night (a cream page glares in the dark).
@immutable
class NotebookInk {
  const NotebookInk._(this.tone, this.pen, this.tabs, this.tabInk, this.tape, this.photo, this.rings);

  final PageTone tone;

  /// The pen your notes are written in.
  final Color pen;
  final List<Color> tabs;
  final Color tabInk;
  final Color tape;

  /// The white border round a taped cover.
  final Color photo;
  final Color rings;

  static const day = NotebookInk._(
    PageTone.notebook,
    Color(0xFF24478A),
    [Color(0xFFC0503F), Color(0xFFD69A2D), Color(0xFF3F8A7A), Color(0xFF4A6FB0), Color(0xFF8A5AA6), Color(0xFF6E8F3A)],
    Colors.white,
    Color(0x9EEFE2A8),
    Color(0xFFFDFCF8),
    Color(0xFF3A3A40),
  );

  static const night = NotebookInk._(
    PageTone(
      'notebook-night',
      'Notebook',
      paper: [Color(0xFF26241F), Color(0xFF1E1C18)],
      ink: Color(0xFFDCD4C3),
      inkSoft: Color(0xFFA79E8E),
      accent: Color(0xFFE08A78),
      dark: true,
      grid: Color(0x24B9C7DC),
    ),
    Color(0xFFA9C0EC),
    [Color(0xFFB5604F), Color(0xFFB98A36), Color(0xFF3F8576), Color(0xFF5674A8), Color(0xFF8562A0), Color(0xFF6B8640)],
    Color(0xFF1E1C18),
    Color(0x66D9CB8F),
    Color(0xFF3A3731),
    Color(0xFF8D8A84),
  );

  static NotebookInk of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? night : day;

  Color tab(int i) => tabs[i % tabs.length];
}

/// The notebook's handwriting (Caveat) at [size], in [color].
TextStyle handwriting(double size, Color color, {FontWeight weight = FontWeight.w500}) =>
    TextStyle(fontFamily: 'Caveat', fontSize: size, height: 1.15, color: color, fontWeight: weight);

class _NotebookPagesState extends State<NotebookPages> {
  late final PageController _pages = PageController();
  final _tabs = ScrollController();
  int _at = 0;

  static const _tabWidth = 30.0;
  static const _tabHeight = 46.0;

  @override
  void didUpdateWidget(NotebookPages old) {
    super.didUpdateWidget(old);
    // A book's last mark removed: its page goes, and the one after takes
    // its place.
    if (_at >= widget.pages.length && widget.pages.isNotEmpty) {
      _at = widget.pages.length - 1;
      if (_pages.hasClients) _pages.jumpToPage(_at);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _turnTo(int i) {
    if (!_pages.hasClients) return;
    final far = (i - _at).abs() > 1;
    // Far off, it opens there; the next page over turns.
    if (far || Motion.reduced(context)) {
      _pages.jumpToPage(i);
    } else {
      unawaited(_pages.animateToPage(i, duration: Motion.of(context, Motion.page), curve: Motion.emphasized));
    }
  }

  void _turned(int i) {
    setState(() => _at = i);
    // Its tab in view.
    if (!_tabs.hasClients) return;
    final view = _tabs.position.viewportDimension;
    final top = i * (_tabHeight + 4);
    final off = _tabs.offset;
    if (top < off || top + _tabHeight > off + view) {
      unawaited(_tabs.animateTo(
        (top - view / 2 + _tabHeight / 2).clamp(0.0, _tabs.position.maxScrollExtent),
        duration: Motion.of(context, Motion.quick),
        curve: Motion.out,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = NotebookInk.of(context);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.s, Gap.xs, 0, Gap.m + bottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: ink.tone.paperOf(context).copyWith(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(4), right: Radius.circular(10)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: ink.tone.dark ? 0.5 : 0.16),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(4), right: Radius.circular(10)),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: PageView.builder(
                        controller: _pages,
                        itemCount: widget.pages.length,
                        onPageChanged: _turned,
                        itemBuilder: (context, i) => _NotebookPage(
                          key: ValueKey(widget.pages[i].$1),
                          number: i + 1,
                          bookId: widget.pages[i].$1,
                          marks: widget.pages[i].$2,
                          title: widget.titleOf(widget.pages[i].$1, widget.pages[i].$2),
                          entries: widget.journal[widget.pages[i].$1] ?? const [],
                          onJournal: widget.onJournal,
                          onJournalHold: widget.onJournalHold,
                          book: widget.books[widget.pages[i].$1],
                          gone: !widget.present(widget.pages[i].$1),
                          ink: ink,
                          onOpen: widget.onOpen,
                          onAction: widget.onAction,
                        ),
                      ),
                    ),
                    // The spiral, over every page.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: IgnorePointer(child: CustomPaint(painter: NotebookSpiral(ink.rings, ink.tone.paper!.last))),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: _tabWidth + 6,
            child: ListView.builder(
              controller: _tabs,
              padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.l),
              itemCount: widget.pages.length,
              itemBuilder: (context, i) => _Tab(
                number: i + 1,
                title: widget.titleOf(widget.pages[i].$1, widget.pages[i].$2),
                colour: ink.tab(i),
                ink: ink.tabInk,
                open: i == _at,
                width: _tabWidth,
                height: _tabHeight,
                onTap: () => _turnTo(i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coloured tab on the notebook's edge, numbered; the open page's stands
/// out further.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.number,
    required this.title,
    required this.colour,
    required this.ink,
    required this.open,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final int number;
  final String title;
  final Color colour;
  final Color ink;
  final bool open;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Semantics(
          button: true,
          selected: open,
          label: 'Page $number: $title',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: Motion.of(context, Motion.quick),
                curve: Motion.out,
                width: open ? width + 6 : width,
                height: height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: open ? colour : Color.lerp(colour, Colors.white, 0.18),
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                  boxShadow: [
                    if (open)
                      BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 4, offset: const Offset(1, 1)),
                  ],
                ),
                child: Text(
                  '$number',
                  style: Skin.ui(size: 13, weight: FontWeight.w800, color: ink),
                ),
              ),
            ),
          ),
        ),
      );
}

/// One book's page.
class _NotebookPage extends StatelessWidget {
  const _NotebookPage({
    super.key,
    required this.number,
    required this.bookId,
    required this.marks,
    required this.title,
    this.entries = const [],
    this.onJournal,
    this.onJournalHold,
    required this.book,
    required this.gone,
    required this.ink,
    required this.onOpen,
    required this.onAction,
  });

  final int number;
  final String bookId;
  final List<Mark> marks;
  final String title;

  /// The book's journal, newest first.
  final List<JournalEntry> entries;
  final void Function(JournalEntry)? onJournal;
  final void Function(JournalEntry)? onJournalHold;
  final LibraryEntry? book;
  final bool gone;
  final NotebookInk ink;
  final void Function(Mark) onOpen;
  final void Function(Mark) onAction;

  @override
  Widget build(BuildContext context) {
    final tone = ink.tone;
    final text = tone.ink!;
    final soft = tone.inkSoft!;
    final quotes = [
      for (final m in marks)
        if (m.kind == MarkKind.quote) m
    ];
    final bookmarks = [
      for (final m in marks)
        if (m.kind == MarkKind.bookmark) m
    ];
    final notes = quotes.where((m) => m.note != null).length;
    final author = book?.authorLine ?? '';
    final newest = [for (final m in marks) m.created, for (final e in entries) e.created]
        .reduce((a, b) => a.isAfter(b) ? a : b);
    String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    return ListView(
      padding: const EdgeInsets.fromLTRB(34, Gap.xl, Gap.l, Gap.xl),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Taped(book: book, title: title, ink: ink),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: Gap.xs),
                  Text(title,
                      maxLines: 3, overflow: TextOverflow.ellipsis, style: handwriting(28, text, weight: FontWeight.w700)),
                  if (author.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(author, maxLines: 2, overflow: TextOverflow.ellipsis, style: handwriting(19, soft)),
                  ],
                  const SizedBox(height: Gap.s),
                  Text(
                    [
                      if (entries.isNotEmpty) count(entries.length, 'thought'),
                      if (quotes.isNotEmpty) count(quotes.length, 'quote'),
                      if (notes > 0) count(notes, 'note'),
                      if (bookmarks.isNotEmpty) count(bookmarks.length, 'bookmark'),
                    ].join(' · '),
                    style: handwriting(17, soft),
                  ),
                  if (gone) Text('no longer in your library', style: handwriting(17, tone.accent!)),
                ],
              ),
            ),
            _Badge(number: number, colour: ink.tab(number - 1), ink: ink.tabInk),
          ],
        ),
        const SizedBox(height: Gap.xl),
        // The journal first: what the reader thought, then what they kept.
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.m),
            child: JournalEntryCard(
              entry: e,
              ink: ink,
              onTap: onJournal == null ? null : () => onJournal!(e),
              onHold: onJournalHold == null ? null : () => onJournalHold!(e),
            ),
          ),
        if (entries.isNotEmpty && quotes.isNotEmpty) const SizedBox(height: Gap.m),
        for (final m in quotes) _Quote(mark: m, ink: ink, onOpen: onOpen, onAction: onAction),
        if (bookmarks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.s),
            child: Text(
              'Bookmarks',
              style: handwriting(24, text, weight: FontWeight.w700).copyWith(
                decoration: TextDecoration.underline,
                decorationColor: tone.accent,
                decorationThickness: 1.5,
              ),
            ),
          ),
          for (final m in bookmarks) _Bookmark(mark: m, ink: ink, onOpen: onOpen, onAction: onAction),
        ],
        const SizedBox(height: Gap.xl),
        Center(
          child: Transform.rotate(
            angle: -0.02,
            child: Text('last saved ${savedWhen(newest)}', style: handwriting(18, soft)),
          ),
        ),
      ],
    );
  }
}

/// The cover, taped onto the page as a photo is: a white border, a slight
/// tilt, two strips of tape over its top corners.
class _Taped extends StatelessWidget {
  const _Taped({required this.book, required this.title, required this.ink});

  final LibraryEntry? book;
  final String title;
  final NotebookInk ink;

  static const width = 78.0;

  @override
  Widget build(BuildContext context) {
    Widget tape(double angle) => Transform.rotate(
          angle: angle,
          child: Container(width: 40, height: 14, color: ink.tape),
        );
    final b = book;
    return ExcludeSemantics(
      child: Transform.rotate(
        angle: -0.045,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
              decoration: BoxDecoration(
                color: ink.photo,
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 4, offset: const Offset(1, 2))
                ],
              ),
              child: b != null
                  ? BookCover(entry: b, width: width, shadow: false)
                  : SizedBox(
                      width: width,
                      height: width * 1.5,
                      child: Center(
                        child: Text(
                          title.isEmpty ? '?' : title.characters.first.toUpperCase(),
                          style: handwriting(44, ink.tone.inkSoft!, weight: FontWeight.w700),
                        ),
                      ),
                    ),
            ),
            Positioned(top: -6, left: -12, child: tape(-0.55)),
            Positioned(top: -6, right: -12, child: tape(0.55)),
          ],
        ),
      ),
    );
  }
}

/// The page's number, as a small round sticker.
class _Badge extends StatelessWidget {
  const _Badge({required this.number, required this.colour, required this.ink});

  final int number;
  final Color colour;
  final Color ink;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          child: Text('$number', style: Skin.ui(size: 12.5, weight: FontWeight.w800, color: ink)),
        ),
      );
}

/// A quote as copied out: in the book's type, under its highlighter, your
/// note beneath it in pen, and where it was.
class _Quote extends StatelessWidget {
  const _Quote({required this.mark, required this.ink, required this.onOpen, required this.onAction});

  final Mark mark;
  final NotebookInk ink;
  final void Function(Mark) onOpen;
  final void Function(Mark) onAction;

  @override
  Widget build(BuildContext context) {
    final tone = ink.tone;
    final wash = markSwatch(mark.colour, tone.accent!).withValues(alpha: tone.dark ? 0.32 : 0.26);
    final where = [if (mark.chapter != null) mark.chapter!, savedWhen(mark.created)].join(' · ');
    return Semantics(
      button: true,
      hint: 'Opens the book here. Press and hold for a note, Share or Remove.',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onOpen(mark),
        onLongPress: () => onAction(mark),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: '“${mark.text}”',
                  style: TextStyle(
                    fontFamily: 'Newsreader',
                    fontStyle: FontStyle.italic,
                    fontSize: 16.5,
                    height: 1.5,
                    color: tone.ink,
                    background: Paint()..color = wash,
                  ),
                ),
                maxLines: 12,
                overflow: TextOverflow.ellipsis,
              ),
              if (mark.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s, left: Gap.s),
                  // Caveat has no arrows: the pen's mark is drawn.
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3, right: 6),
                        child: Icon(Icons.east_rounded, size: 18, color: ink.pen),
                      ),
                      Expanded(child: Text(mark.note!, style: handwriting(21, ink.pen))),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: Gap.s),
                child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: handwriting(16, tone.inkSoft!)),
              ),
              const SizedBox(height: Gap.s),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bookmark extends StatelessWidget {
  const _Bookmark({required this.mark, required this.ink, required this.onOpen, required this.onAction});

  final Mark mark;
  final NotebookInk ink;
  final void Function(Mark) onOpen;
  final void Function(Mark) onAction;

  @override
  Widget build(BuildContext context) {
    final tone = ink.tone;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onOpen(mark),
      onLongPress: () => onAction(mark),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3, right: Gap.s),
              child: Icon(Icons.subdirectory_arrow_right_rounded, size: 18, color: tone.accent),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (mark.chapter != null)
                    Text(mark.chapter!, maxLines: 1, overflow: TextOverflow.ellipsis, style: handwriting(19, tone.ink!)),
                  Text(
                    mark.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Newsreader', fontSize: 14.5, height: 1.4, color: tone.inkSoft),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The spiral binding down the page's left edge: punched holes, and the
/// wire through each.
class NotebookSpiral extends CustomPainter {
  const NotebookSpiral(this.wire, this.paper);

  final Color wire;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 26.0;
    final hole = Paint()..color = Color.lerp(paper, Colors.black, 0.55)!;
    final ring = Paint()
      ..color = wire
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final count = math.max(1, (size.height / step).floor());
    final top = (size.height - (count - 1) * step) / 2;
    for (var i = 0; i < count; i++) {
      final y = top + i * step;
      canvas.drawCircle(Offset(12, y), 3.2, hole);
      // The wire comes over the edge and into the hole.
      canvas.drawArc(Rect.fromCircle(center: Offset(5, y - 1), radius: 7), math.pi * 1.05, math.pi * 0.9, false, ring);
    }
  }

  @override
  bool shouldRepaint(NotebookSpiral old) => old.wire != wire || old.paper != paper;
}

/// When something was saved, said on this phone's own calendar.
String savedWhen(DateTime saved) {
  final t = saved.toLocal();
  final days = DateTime.now().difference(t).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]}';
}
