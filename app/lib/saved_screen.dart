import 'dart:async';

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'book_tint.dart';
import 'highlights.dart';
import 'library_store.dart';
import 'marks.dart';
import 'quote_export.dart';
import 'quote_sheet.dart';
import 'reader_screen.dart';
import 'share_card.dart';
import 'theme.dart';
import 'ui.dart';

/// Everything saved from the books: quotes to read again or share, and
/// bookmarks to come back to, by book, newest first. With [bookId], only
/// what was saved from that book (See all, from its page).
class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key, required this.store, this.bookId});

  final LibraryStore store;
  final String? bookId;

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  final _marks = MarkStore.instance;
  MarkKind _kind = MarkKind.quote;
  Map<String, LibraryEntry> _books = const {};

  /// What may show (LibraryStore.marksShown): nothing of a book on a shut
  /// secret shelf, nor of a removed book that may have been on one. Nothing
  /// until it is known.
  bool Function(Mark) _shown = _none;
  static bool _none(Mark _) => false;

  /// Every book in the library, shown or not: a mark of none of them is of
  /// a book that is gone. Known once [_loaded].
  Set<String> _present = const {};
  bool _loaded = false;
  String _query = '';

  /// The mark last brought back with Undo: it opens into its place again
  /// instead of popping back.
  String? _back;

  /// Rows folding shut before their marks go (Remove).
  final _leaving = <String>{};

  /// Rows swiped away, which shrink by themselves (Dismissible).
  final _swiped = <String>{};

  @override
  void initState() {
    super.initState();
    _marks.changes.addListener(_changed);
    unawaited(_loadBooks());
  }

  @override
  void dispose() {
    _marks.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBooks() async {
    final list = await widget.store.list();
    final all = await widget.store.list(all: true);
    final shown = await widget.store.marksShown();
    if (mounted) {
      setState(() {
        _books = {for (final e in list) e.id: e};
        _present = {for (final e in all) e.id};
        _shown = shown;
        _loaded = true;
      });
    }
  }

  /// Clear [gone], marks of books no longer in the library, together; Undo
  /// puts them back.
  Future<void> _clearGone(List<Mark> gone) async {
    final quotes = _kind == MarkKind.quote;
    final what = quotes ? (gone.length == 1 ? 'quote' : 'quotes') : (gone.length == 1 ? 'bookmark' : 'bookmarks');
    final ok = await confirm(
      context,
      title: 'Clear ${gone.length} $what?',
      body: 'They are from books no longer in your library. Their words go with them.',
      action: 'Clear',
    );
    if (!ok || !mounted) return;
    await _marks.removeAll({for (final m in gone) m.id});
    if (!mounted) return;
    showSnack(
      context,
      'Cleared ${gone.length} $what.',
      actionLabel: 'Undo',
      onAction: () => unawaited(_marks.restoreAll(gone)),
    );
  }

  Future<void> _open(Mark m) async {
    if (_books.isEmpty) await _loadBooks();
    if (!mounted) return;
    final entry = _books[m.bookId];
    if (entry == null) {
      showSnack(context, 'That book is no longer in your library.');
      return;
    }
    await openBook(context, widget.store, entry, at: m);
  }

  Future<void> _editNote(Mark m) async {
    final note = await askNote(context, initial: m.note ?? '');
    if (note == null) return;
    await _marks.update(m.withNote(note));
  }

  /// Take [m] away: its row folds shut first, with its book's heading when
  /// it is the last of that book's, so the rows below close up over them;
  /// then the mark goes, and Undo is offered. A row swiped away ([swiped])
  /// has shrunk by itself already, its heading with it.
  Future<void> _delete(Mark m, {bool swiped = false}) async {
    if (!swiped) {
      if (!_leaving.add(m.id)) return;
      setState(() {});
      await Future<void>.delayed(Motion.of(context, Motion.standard));
    }
    await _marks.remove(m.id);
    _leaving.remove(m.id);
    _swiped.remove(m.id);
    if (!mounted) return;
    showSnack(
      context,
      m.kind == MarkKind.quote ? 'Quote removed.' : 'Bookmark removed.',
      actionLabel: 'Undo',
      onAction: () {
        _back = m.id;
        unawaited(_marks.restore(m));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final mine = [
      for (final m in _marks.all)
        if ((widget.bookId == null || m.bookId == widget.bookId) && _shown(m)) m,
    ];
    bool matches(Mark m) =>
        q.isEmpty ||
        m.text.toLowerCase().contains(q) ||
        m.bookTitle.toLowerCase().contains(q) ||
        (m.note?.toLowerCase().contains(q) ?? false);
    final marks = [for (final m in mine) if (m.kind == _kind && matches(m)) m];
    final byBook = <String, List<Mark>>{};
    for (final m in marks) {
      byBook.putIfAbsent(m.bookId, () => []).add(m);
    }
    final quotes = mine.where((m) => m.kind == MarkKind.quote).length;
    final bookmarks = mine.length - quotes;
    // Of books no longer in the library: offered to clear together.
    final gone = widget.bookId != null || !_loaded
        ? const <Mark>[]
        : [for (final m in mine) if (m.kind == _kind && !_present.contains(m.bookId)) m];
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ScreenTopBar(title: 'Saved', onBack: () => Navigator.of(context).maybePop())),
                  if (quotes > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: ExportQuotesButton(store: widget.store, bookId: widget.bookId),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                child: ChoiceRow<MarkKind>(
                  options: [
                    (MarkKind.quote, 'Quotes  $quotes'),
                    (MarkKind.bookmark, 'Bookmarks  $bookmarks'),
                  ],
                  value: _kind,
                  onChanged: (k) => setState(() => _kind = k),
                ),
              ),
              if (mine.length > 6)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: SearchField(hint: 'Search what you saved', onChanged: (v) => setState(() => _query = v)),
                ),
              Expanded(
                // Quotes and bookmarks fade into each other's place.
                child: FadeIn(
                  trigger: _kind,
                  child: !_loaded
                      ? const SizedBox.shrink()
                      : marks.isEmpty
                      ? EmptyState(
                          icon: _kind == MarkKind.quote ? Icons.format_quote_rounded : Icons.bookmark_border_rounded,
                          title: q.isNotEmpty
                              ? 'Nothing matches'
                              : (_kind == MarkKind.quote ? 'No quotes yet' : 'No bookmarks yet'),
                          body: q.isNotEmpty
                              ? 'Try other words.'
                              : 'Press and hold a sentence while reading, or tap Save on the player or the lock '
                                  'screen while listening.',
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                              Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                          children: [
                            if (gone.isNotEmpty && q.isEmpty) _goneRow(context, gone),
                            for (final entry in byBook.entries) ..._group(context, entry.key, entry.value),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _group(BuildContext context, String bookId, List<Mark> marks) {
    final book = _books[bookId];
    // The book's last rows going: its heading folds away with them, not
    // before them (it vanished while the last row was still folding).
    final closing = marks.every((m) => _leaving.contains(m.id) || _swiped.contains(m.id));
    return [
      Fold(
        key: ValueKey('book $bookId'),
        open: !closing,
        // Its only mark brought back with Undo: it opens with that row.
        appear: marks.length == 1 && marks.single.id == _back,
        child: Padding(
          padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
          child: Row(
            children: [
              if (book != null) ...[
                SizedBox(width: 30, child: BookCover(entry: book, width: 30, titled: false)),
                const SizedBox(width: Gap.m),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(marks.first.bookTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
                    if (_loaded && !_present.contains(bookId))
                      Text('No longer in your library'.toUpperCase(), style: Skin.meta(context, size: 9.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      for (final m in marks)
        // Keyed by mark, so each keeps its row as others come and go.
        Fold(
          key: ValueKey(m.id),
          open: !_leaving.contains(m.id),
          appear: m.id == _back,
          child: IgnorePointer(
            ignoring: _leaving.contains(m.id),
            child: BookTint(
              bookId: bookId,
              cover: book?.shownCover,
              child: Builder(builder: (context) => _tile(context, m, book)),
            ),
          ),
        ),
    ];
  }

  /// How many of what is listed are from books no longer in the library,
  /// with Clear for all of them.
  Widget _goneRow(BuildContext context, List<Mark> gone) {
    final quotes = _kind == MarkKind.quote;
    final what = quotes ? (gone.length == 1 ? 'quote is' : 'quotes are') : (gone.length == 1 ? 'bookmark is' : 'bookmarks are');
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Material(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.card / 1.5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.xs, Gap.xs),
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 19, color: Skin.inkSoftOn(context)),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(
                  '${gone.length} $what from books no longer in your library',
                  style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkSoftOn(context)),
                ),
              ),
              TextButton(onPressed: () => unawaited(_clearGone(gone)), child: const Text('Clear')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Mark m, LibraryEntry? book) => Dismissible(
        key: ValueKey(m.id),
        direction: DismissDirection.endToStart,
        // It shrinks as long as a row folds, so its heading (folding as it
        // starts, when it is the last) is gone with it, not before.
        resizeDuration: Motion.of(context, Motion.standard),
        confirmDismiss: (_) async {
          setState(() => _swiped.add(m.id));
          return true;
        },
        onDismissed: (_) => unawaited(_delete(m, swiped: true)),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: Gap.xl),
          child: Icon(Icons.delete_outline_rounded, color: Skin.inkFaintOn(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: Material(
            color: Skin.capsuleOn(context),
            borderRadius: BorderRadius.circular(Radii.card / 1.5),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.card / 1.5),
              onTap: () => _open(m),
              onLongPress: m.kind == MarkKind.quote
                  ? () => showQuoteShare(context, m, cover: book?.shownCover, author: book?.authorLine)
                  : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
                decoration: BoxDecoration(
                  // A quote's edge in its colour on the page.
                  border: Border(left: BorderSide(color: markSwatch(m.colour, Skin.accentOf(context)), width: 3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.text,
                            maxLines: m.kind == MarkKind.quote ? 6 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Newsreader',
                              fontStyle: m.kind == MarkKind.quote ? FontStyle.italic : FontStyle.normal,
                              fontSize: 16,
                              height: 1.4,
                              color: Skin.inkOn(context),
                            ),
                          ),
                          if (m.note != null) ...[
                            const SizedBox(height: Gap.s),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2, right: 6),
                                  child: Icon(Icons.sticky_note_2_outlined, size: 15, color: Skin.accentInkOf(context)),
                                ),
                                Expanded(
                                  child: Text(
                                    m.note!,
                                    style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkSoftOn(context)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  [if (m.chapter != null) m.chapter!, _when(m.created)].join(' · ').toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.meta(context, size: 10),
                                ),
                              ),
                              if (m.kind == MarkKind.quote) _colourButton(context, m),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.kind == MarkKind.quote)
                          IconButton(
                            tooltip: m.note == null ? 'Add a note' : 'Change the note',
                            icon: Icon(Icons.edit_note_rounded, size: 22, color: Skin.inkSoftOn(context)),
                            onPressed: () => unawaited(_editNote(m)),
                          ),
                        if (m.kind == MarkKind.quote)
                          IconButton(
                            tooltip: 'Share',
                            icon: Icon(Icons.ios_share_rounded, size: 20, color: Skin.accentInkOf(context)),
                            onPressed: () => showQuoteShare(context, m, cover: book?.shownCover, author: book?.authorLine),
                          ),
                        // Swiping away works too, but nothing on screen says so.
                        IconButton(
                          tooltip: 'Remove',
                          icon: Icon(Icons.delete_outline_rounded, size: 20, color: Skin.inkFaintOn(context)),
                          onPressed: () => unawaited(_delete(m)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// The quote's colour on the page, changed from a menu of the four.
  Widget _colourButton(BuildContext context, Mark m) {
    final accent = Skin.accentOf(context);
    Widget dot(MarkColour c, double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: markSwatch(c, accent), shape: BoxShape.circle),
        );
    return PopupMenuButton<MarkColour>(
      tooltip: 'Colour: ${m.colour.label}',
      onSelected: (c) => unawaited(_marks.update(m.withColour(c))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot(m.colour, 12),
            const SizedBox(width: 6),
            Text(m.colour.label.toUpperCase(), style: Skin.meta(context, size: 10)),
          ],
        ),
      ),
      itemBuilder: (_) => [
        for (final c in MarkColour.values)
          CheckedPopupMenuItem<MarkColour>(
            value: c,
            checked: c == m.colour,
            child: Row(children: [dot(c, 14), const SizedBox(width: Gap.m), Text(c.label)]),
          ),
      ],
    );
  }

  static String _when(DateTime saved) {
    // Kept in UTC; said on this phone's own calendar.
    final t = saved.toLocal();
    final days = DateTime.now().difference(t).inDays;
    if (days == 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 7) return '$days days ago';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]}';
  }
}

/// On a book's page: the latest few things saved from it, each opening the
/// book there, and See all for the rest. Nothing when none were saved.
class BookSavedSection extends StatelessWidget {
  const BookSavedSection({super.key, required this.store, required this.entry});

  final LibraryStore store;
  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: MarkStore.instance.changes,
        builder: (context, _, __) {
          final marks = MarkStore.instance.forBook(entry.id);
          if (marks.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: SectionTitle('Saved', note: '${marks.length}')),
                  if (marks.any((m) => m.kind == MarkKind.quote)) ExportQuotesButton(store: store, bookId: entry.id),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => SavedScreen(store: store, bookId: entry.id)),
                    ),
                    child: const Text('See all'),
                  ),
                ],
              ),
              const SizedBox(height: Gap.s),
              for (final m in marks.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Material(
                    color: Skin.capsuleOn(context),
                    borderRadius: BorderRadius.circular(Radii.card / 1.5),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.card / 1.5),
                      onTap: () => openBook(context, store, entry, at: m),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.m),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              m.kind == MarkKind.quote ? Icons.format_quote_rounded : Icons.bookmark_rounded,
                              size: 18,
                              color: Skin.accentInkOf(context),
                            ),
                            const SizedBox(width: Gap.m),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Newsreader',
                                      fontStyle: m.kind == MarkKind.quote ? FontStyle.italic : FontStyle.normal,
                                      fontSize: 15.5,
                                      height: 1.4,
                                      color: Skin.inkOn(context),
                                    ),
                                  ),
                                  if (m.note != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        m.note!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Skin.ui(size: 13.5, weight: FontWeight.w500, color: Skin.inkSoftOn(context)),
                                      ),
                                    ),
                                  if (m.chapter != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        m.chapter!.toUpperCase(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Skin.meta(context, size: 10),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}
