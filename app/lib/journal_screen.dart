import 'dart:async';

import 'package:flutter/material.dart';

import 'ai/talk/talk_view.dart';
import 'journal.dart';
import 'journal_page.dart';
import 'library_store.dart';
import 'notebook.dart';
import 'prefs.dart';
import 'quote_export.dart';
import 'theme.dart';
import 'ui.dart';

/// The reading journal, apart from Saved: what was thought about each book,
/// as a list (the first look) or as a notebook, a page a book, newest book
/// first. With [bookId], one book's alone (from its page).
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key, required this.store, this.bookId, this.onlyTalks = false});

  final LibraryStore store;
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

  /// A new entry: about [bookId] when given (a page's or a list's Write),
  /// else about the book picked.
  Future<void> _write([String? bookId]) async {
    final id = bookId ?? widget.bookId;
    final book = id == null ? await pickBookToWrite(context, widget.store) : _books[id];
    if (!mounted) return;
    if (book == null) {
      if (id != null) showSnack(context, 'That book is no longer in your library.');
      return;
    }
    await writeAbout(context, widget.store, book);
  }

  /// An entry opened to change it, its stamp kept; a talk, to read again.
  Future<void> _edit(JournalEntry e) => e.isTalk
      ? Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TalkTranscript(entry: e)))
      : openJournal(context, bookId: e.bookId, bookTitle: e.bookTitle, stampNow: () => e.stamp, entry: e);

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
    final talks = mine.any((e) => e.isTalk);
    final shown = talks ? _shown : _Shown.all;
    final thoughts = [
      for (final e in mine)
        if ((q.isEmpty || e.words.toLowerCase().contains(q) || e.bookTitle.toLowerCase().contains(q)) &&
            (shown == _Shown.all || (shown == _Shown.talks) == e.isTalk))
          e,
    ];
    final byBook = <String, List<JournalEntry>>{};
    for (final e in thoughts) {
      byBook.putIfAbsent(e.bookId, () => []).add(e);
    }
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
              if (talks)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: ChoiceRow<_Shown>(
                    options: const [(_Shown.all, 'All'), (_Shown.mine, 'My writing'), (_Shown.talks, 'Talks')],
                    value: shown,
                    onChanged: (v) => setState(() => _shown = v),
                  ),
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
                          onJournal: (e) => unawaited(_edit(e)),
                          onJournalHold: (e) => unawaited(removeJournalEntry(context, e)),
                          onWrite: (id) => unawaited(_write(id)),
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
      // Room under the last entry for the Write button.
      padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 96 + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        for (final MapEntry(key: id, value: entries) in byBook.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
            child: Row(
              children: [
                Expanded(
                  child: Text(_books[id]?.title ?? entries.first.bookTitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
                ),
                if (_books.containsKey(id))
                  TextButton.icon(
                    onPressed: () => unawaited(_write(id)),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Write'),
                  ),
              ],
            ),
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

enum _Shown { all, mine, talks }
