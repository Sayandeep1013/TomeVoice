import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai/chat/chat_screen.dart';
import 'ai/chat/chat_store.dart';
import 'ai/talk/talk_view.dart';
import 'journal.dart';
import 'journal_page.dart';
import 'library_store.dart';
import 'notebook.dart';
import 'prefs.dart';
import 'quote_export.dart';
import 'theme.dart';
import 'ui.dart';

/// What groups a book's entries: its title, so the same novel from two
/// sources (or read again after it was removed and added back) is one book
/// in the journal.
String journalKey(String title) => title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// An entry opened: a chat from AI chat in AI chat, to carry on; a talk to
/// read again; the reader's own writing to change, its stamp kept.
Future<void> openJournalEntry(BuildContext context, LibraryStore store, JournalEntry e) {
  final chat = e.id.startsWith('chat-') ? ChatStore.instance.byId(e.id.substring(5)) : null;
  if (chat != null) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(store: store, chat: chat)));
  }
  return e.isTalk
      ? Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TalkTranscript(entry: e)))
      : openJournal(context, bookId: e.bookId, bookTitle: e.bookTitle, stampNow: () => e.stamp, entry: e);
}

/// The reading journal, apart from Saved: every book that has one, a card
/// each (all the same size: its name, how many entries, the latest's first
/// lines); a tap opens that book's journal, every entry in full. Or as a
/// notebook, a page a book, its tabs down the side. Newest book first.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key, required this.store, this.bookId, this.onlyTalks = false});

  final LibraryStore store;

  /// The book the notebook opens at (its page among all the others).
  final String? bookId;

  /// Opened from AI chat's past talks: the talks with the AI alone, at first.
  final bool onlyTalks;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  final _journal = JournalStore.instance;
  Map<String, LibraryEntry> _books = const {};
  Set<String> _present = const {};
  bool _loaded = false;
  String _query = '';

  /// Every book's card is this high, however much it has.
  static const _cardHeight = 138.0;

  /// Which entries show: all, the reader's own writing, or talks with the
  /// AI companion.
  late _Shown _shown = widget.onlyTalks ? _Shown.talks : _Shown.all;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  /// As a notebook, or as a list (remembered).
  bool get _notebook => _prefs.journalNotebook;

  void _setNotebook(bool on) {
    setState(() => _prefs.journalNotebook = on);
    _prefs.save();
  }

  @override
  void initState() {
    super.initState();
    _journal.changes.addListener(_changed);
    unawaited(_loadBooks());
  }

  @override
  void dispose() {
    _journal.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBooks() async {
    final shown = await widget.store.list();
    final all = await widget.store.list(all: true);
    if (!mounted) return;
    setState(() {
      _books = {for (final e in shown) e.id: e};
      _present = {for (final e in all) e.id};
      _loaded = true;
    });
  }

  /// A new entry: about [bookId] when given, else about the book picked.
  Future<void> _write([String? bookId]) async {
    final book = bookId == null ? await pickBookToWrite(context, widget.store) : _books[bookId];
    if (!mounted) return;
    if (book == null) {
      if (bookId != null) showSnack(context, 'That book is no longer in your library.');
      return;
    }
    await writeAbout(context, widget.store, book);
  }

  /// Book [id]'s journal, every entry in full.
  Future<void> _openBook(String id, String title) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BookJournalScreen(store: widget.store, bookId: id, bookTitle: title),
      ));

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    // Not a book's on a shut secret shelf (in the library, but not on the
    // shelves shown); a book no longer in the library keeps its thoughts.
    final mine = !_loaded
        ? const <JournalEntry>[]
        : [
            for (final e in _journal.all)
              if (_books.containsKey(e.bookId) || !_present.contains(e.bookId)) e,
          ];
    final talks = mine.any((e) => e.isTalk);
    final shown = talks ? _shown : _Shown.all;
    final thoughts = [
      for (final e in mine)
        if ((q.isEmpty || e.words.toLowerCase().contains(q) || e.bookTitle.toLowerCase().contains(q)) &&
            (shown == _Shown.all || (shown == _Shown.talks) == e.isTalk))
          e,
    ];
    // One book a title: the entries of the same novel from two sources
    // together, under the id of the one in the library (the newest else).
    final groups = <String, List<JournalEntry>>{};
    for (final e in thoughts) {
      groups.putIfAbsent(journalKey(e.bookTitle), () => []).add(e);
    }
    final byBook = <String, List<JournalEntry>>{
      for (final g in groups.values)
        (g.where((e) => _books.containsKey(e.bookId)).firstOrNull ?? g.first).bookId: g,
    };
    final books = {for (final e in mine) journalKey(e.bookTitle)};
    final at = widget.bookId;
    final openAt = at == null ? 0 : math.max(0, byBook.keys.toList().indexOf(at));
    return Scaffold(
      floatingActionButton: !_loaded
          ? null
          : FloatingActionButton.extended(
              onPressed: () => unawaited(_write()),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Write'),
            ),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ScreenTopBar(title: 'Journal', onBack: () => Navigator.of(context).maybePop())),
                  if (mine.isNotEmpty)
                    IconButton(
                      tooltip: _notebook ? 'Show as a list' : 'Show as a notebook',
                      icon: Icon(_notebook ? Icons.view_agenda_outlined : Icons.auto_stories_outlined),
                      onPressed: () => _setNotebook(!_notebook),
                    ),
                  // Only with something to export.
                  if (thoughts.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: ExportQuotesButton(store: widget.store, journal: true),
                    ),
                ],
              ),
              if (talks)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: ChoiceRow<_Shown>(
                    options: const [(_Shown.all, 'All'), (_Shown.mine, 'My writing'), (_Shown.talks, 'Talks')],
                    value: shown,
                    onChanged: (v) => setState(() => _shown = v),
                  ),
                ),
              // A book found by its name (or by words written about it).
              if (books.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: SearchField(
                      hint: 'Find a book, or words you wrote', onChanged: (v) => setState(() => _query = v)),
                ),
              Expanded(
                child: FadeIn(
                  trigger: _notebook,
                  child: !_loaded
                      ? const SizedBox.shrink()
                      : thoughts.isEmpty
                      ? EmptyState(
                          icon: Icons.edit_note_rounded,
                          title: q.isNotEmpty || shown != _Shown.all ? 'Nothing matches' : 'No journal yet',
                          body: q.isNotEmpty
                              ? 'Try other words.'
                              : shown != _Shown.all
                              ? 'Nothing of that kind yet.'
                              : 'Tap Write, or the pen on the player while you read or listen, and write how the '
                                  'book makes you feel. Each entry keeps the chapter you were at.',
                        )
                      : _notebook
                      ? NotebookPages(
                          pages: [for (final id in byBook.keys) (id, const [])],
                          books: _books,
                          present: _present.contains,
                          onOpen: (_) {},
                          onAction: (_) {},
                          journal: byBook,
                          onJournal: (e) => unawaited(openJournalEntry(context, widget.store, e)),
                          onJournalHold: (e) => unawaited(removeJournalEntry(context, e)),
                          onWrite: (id) => unawaited(_write(id)),
                          initialPage: openAt,
                        )
                      : _list(context, byBook),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Each book one card, all the same height: its name, how many entries
  /// and when the latest was, and the latest's first lines, cut with "…".
  /// A tap opens the book's journal.
  Widget _list(BuildContext context, Map<String, List<JournalEntry>> byBook) {
    final ink = NotebookInk.of(context);
    final ids = byBook.keys.toList();
    return ListView.builder(
      itemExtent: _cardHeight,
      // Room under the last card for the Write button.
      padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 96 + MediaQuery.viewPaddingOf(context).bottom),
      itemCount: ids.length,
      itemBuilder: (context, i) {
        final id = ids[i];
        final entries = byBook[id]!;
        final latest = entries.first;
        final title = _books[id]?.title ?? latest.bookTitle;
        final soft = ink.tone.inkSoft ?? Skin.inkSoftOn(context);
        return Padding(
          key: ValueKey('journal $id'),
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: ink.tone.paperOf(context).copyWith(borderRadius: BorderRadius.circular(Radii.card / 1.5)),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.card / 1.5),
                onTap: () => unawaited(_openBook(id, title)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
                            const SizedBox(height: 2),
                            Text(
                              '${entries.length} ${entries.length == 1 ? 'entry' : 'entries'} · latest '
                              '${latest.stamp.label}, ${savedWhen(latest.created)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: handwriting(16, soft, weight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Expanded(
                              child: Text(
                                latest.preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: handwriting(19, ink.pen).copyWith(height: 1.15),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: soft),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One book's journal: every entry in full on the notebook's paper, newest
/// first (a tap opens one to read or change); Write for this book; and a way
/// to every other book's journal.
class BookJournalScreen extends StatefulWidget {
  const BookJournalScreen({
    super.key,
    required this.store,
    required this.bookId,
    required this.bookTitle,
    this.stampNow,
    this.chapters,
  });

  final LibraryStore store;
  final String bookId;
  final String bookTitle;

  /// Where the story is, for a new entry (from the book's page); else as the
  /// Journal's Write finds it.
  final JournalStamp Function()? stampNow;

  /// The book's chapters, for picking which one an entry is about.
  final List<JournalChapter> Function()? chapters;

  @override
  State<BookJournalScreen> createState() => _BookJournalScreenState();
}

class _BookJournalScreenState extends State<BookJournalScreen> {
  final _journal = JournalStore.instance;
  _Shown _shown = _Shown.all;

  @override
  void initState() {
    super.initState();
    _journal.changes.addListener(_changed);
  }

  @override
  void dispose() {
    _journal.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _write() async {
    final stamp = widget.stampNow;
    if (stamp != null) {
      await openJournal(context,
          bookId: widget.bookId, bookTitle: widget.bookTitle, stampNow: stamp, chapters: widget.chapters?.call());
      return;
    }
    final book = (await widget.store.list(all: true)).where((e) => e.id == widget.bookId).firstOrNull;
    if (!mounted) return;
    if (book == null) {
      showSnack(context, 'That book is no longer in your library.');
      return;
    }
    await writeAbout(context, widget.store, book);
  }

  @override
  Widget build(BuildContext context) {
    // This book's, and the same title's from another source.
    final key = journalKey(widget.bookTitle);
    final all = [
      for (final e in _journal.all)
        if (e.bookId == widget.bookId || journalKey(e.bookTitle) == key) e,
    ];
    final talks = all.any((e) => e.isTalk);
    final shown = talks ? _shown : _Shown.all;
    final entries = [
      for (final e in all)
        if (shown == _Shown.all || (shown == _Shown.talks) == e.isTalk) e,
    ];
    final ink = NotebookInk.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_write()),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Write'),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ScreenTopBar(title: widget.bookTitle, onBack: () => Navigator.of(context).maybePop()),
                  ),
                  if (entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: ExportQuotesButton(store: widget.store, bookId: widget.bookId, journal: true),
                    ),
                ],
              ),
              // Every other book's journal, a tap away.
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page - Gap.s, 0, Gap.page, Gap.s),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => JournalScreen(store: widget.store, bookId: widget.bookId)),
                    ),
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('All books’ journals'),
                  ),
                ),
              ),
              if (talks)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: ChoiceRow<_Shown>(
                    options: const [(_Shown.all, 'All'), (_Shown.mine, 'My writing'), (_Shown.talks, 'Talks')],
                    value: shown,
                    onChanged: (v) => setState(() => _shown = v),
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? EmptyState(
                        icon: Icons.edit_note_rounded,
                        title: all.isEmpty ? 'No journal for this book yet' : 'Nothing of that kind yet',
                        body: all.isEmpty
                            ? 'Tap Write, or the pen on the player while you read or listen. Each entry keeps the '
                                'chapter you were at.'
                            : '',
                      )
                    // Each entry its own box, apart from the next: as many
                    // boxes as entries, newest first, each opened by itself.
                    : ListView.separated(
                        padding:
                            EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 96 + MediaQuery.viewPaddingOf(context).bottom),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: Gap.m),
                        itemBuilder: (context, i) => DecoratedBox(
                          key: ValueKey('entry ${entries[i].id}'),
                          decoration:
                              ink.tone.paperOf(context).copyWith(borderRadius: BorderRadius.circular(Radii.card / 1.5)),
                          child: Padding(
                            padding: const EdgeInsets.all(Gap.xs),
                            child: JournalEntryCard(
                              entry: entries[i],
                              ink: ink,
                              boxed: false,
                              onTap: () => unawaited(openJournalEntry(context, widget.store, entries[i])),
                              onHold: () => unawaited(removeJournalEntry(context, entries[i])),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Shown { all, mine, talks }
