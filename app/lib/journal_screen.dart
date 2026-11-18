import 'dart:async';

import 'package:flutter/material.dart';

import 'journal.dart';
import 'journal_page.dart';
import 'library_store.dart';
import 'notebook.dart';
import 'prefs.dart';
import 'quote_export.dart';
import 'theme.dart';
import 'ui.dart';

/// The reading journal, apart from Saved: what was thought about each book,
/// as a notebook (a page a book, the first look) or as a list, newest book
/// first. With [bookId], one book's alone (from its page).
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key, required this.store, this.bookId});

  final LibraryStore store;
  final String? bookId;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  final _journal = JournalStore.instance;
  Map<String, LibraryEntry> _books = const {};
  Set<String> _present = const {};
  bool _loaded = false;
  String _query = '';

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

  /// An entry opened to change it, its stamp kept.
  Future<void> _edit(JournalEntry e) =>
      openJournal(context, bookId: e.bookId, bookTitle: e.bookTitle, stampNow: () => e.stamp, entry: e);

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    // Not a book's on a shut secret shelf (in the library, but not on the
    // shelves shown); a book no longer in the library keeps its thoughts.
    final mine = !_loaded
        ? const <JournalEntry>[]
        : [
            for (final e in _journal.all)
              if ((widget.bookId == null || e.bookId == widget.bookId) &&
                  (_books.containsKey(e.bookId) || !_present.contains(e.bookId)))
                e,
          ];
    final thoughts = [
      for (final e in mine)
        if (q.isEmpty || e.words.toLowerCase().contains(q) || e.bookTitle.toLowerCase().contains(q)) e,
    ];
    final byBook = <String, List<JournalEntry>>{};
    for (final e in thoughts) {
      byBook.putIfAbsent(e.bookId, () => []).add(e);
    }
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
                  Expanded(child: ScreenTopBar(title: 'Journal', onBack: () => Navigator.of(context).maybePop())),
                  if (mine.isNotEmpty) ...[
                    IconButton(
                      tooltip: _notebook ? 'Show as a list' : 'Show as a notebook',
                      icon: Icon(_notebook ? Icons.view_agenda_outlined : Icons.auto_stories_outlined),
                      onPressed: () => _setNotebook(!_notebook),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: ExportQuotesButton(store: widget.store, bookId: widget.bookId, journal: true),
                    ),
                  ],
                ],
              ),
              if (mine.length > 6 && !_notebook)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: SearchField(hint: 'Search your journal', onChanged: (v) => setState(() => _query = v)),
                ),
              Expanded(
                child: FadeIn(
                  trigger: _notebook,
                  child: !_loaded
                      ? const SizedBox.shrink()
                      : thoughts.isEmpty
                      ? EmptyState(
                          icon: Icons.edit_note_rounded,
                          title: q.isNotEmpty ? 'Nothing matches' : 'No journal yet',
                          body: q.isNotEmpty
                              ? 'Try other words.'
                              : 'Tap the pen on the player while you read or listen, and write how the book '
                                  'makes you feel. Each entry keeps the chapter you were at.',
                        )
                      : _notebook
                      ? NotebookPages(
                          pages: [for (final id in byBook.keys) (id, const [])],
                          books: _books,
                          present: _present.contains,
                          onOpen: (_) {},
                          onAction: (_) {},
                          journal: byBook,
                          onJournal: (e) => unawaited(_edit(e)),
                          onJournalHold: (e) => unawaited(removeJournalEntry(context, e)),
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

  /// Each book's entries on a strip of the notebook's paper.
  Widget _list(BuildContext context, Map<String, List<JournalEntry>> byBook) {
    final ink = NotebookInk.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        for (final MapEntry(key: id, value: entries) in byBook.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
            child: Text(_books[id]?.title ?? entries.first.bookTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
          ),
          DecoratedBox(
            key: ValueKey('journal $id'),
            decoration: ink.tone.paperOf(context).copyWith(borderRadius: BorderRadius.circular(Radii.card / 1.5)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in entries)
                    JournalEntryCard(
                      entry: e,
                      ink: ink,
                      onTap: () => unawaited(_edit(e)),
                      onHold: () => unawaited(removeJournalEntry(context, e)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
