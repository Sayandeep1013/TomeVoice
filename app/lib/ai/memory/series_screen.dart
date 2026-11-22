import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import 'chapter_notes_screen.dart';
import 'graph_screen.dart';
import 'memory_section.dart' show BookMemorySection;
import 'memory_service.dart';
import 'series_db.dart';
import 'series_flow.dart' show pickBookForMemory;
import 'series_store.dart';
import 'threads_screen.dart';
import 'whos_who_screen.dart';

Future<List<int>> _buildOff(String out, List<({String path, String title})> books) =>
    Isolate.run(() => buildSeriesDb(out, books));

/// A series' memory: All (the books read as one: Who's who, the graph,
/// Chapter by chapter, Threads across them) or one book at a time, each
/// its own memory as on its page. The menu renames the series, adds a book
/// after the last, takes one out (its memory stays) or undoes the series.
class SeriesMemoryScreen extends StatefulWidget {
  const SeriesMemoryScreen({super.key, required this.seriesId});

  final String seriesId;

  @override
  State<SeriesMemoryScreen> createState() => _SeriesMemoryScreenState();
}

class _SeriesMemoryScreenState extends State<SeriesMemoryScreen> {
  final _service = MemoryService.instance;

  /// Which is shown: null for All, else a book's place in the series.
  int? _book;
  Map<String, String> _titles = const {};

  /// The series read as one, once made, and where each book starts in it.
  String? _allPath;
  List<int> _starts = const [];
  bool _making = false;

  MemorySeries? get _series => SeriesStore.instance.byId(widget.seriesId);

  @override
  void initState() {
    super.initState();
    SeriesStore.instance.changes.addListener(_changed);
    unawaited(_loadTitles());
  }

  @override
  void dispose() {
    SeriesStore.instance.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_series == null) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _allPath = null);
    unawaited(_loadTitles());
  }

  Future<void> _loadTitles() async {
    final store = _service.library;
    if (store == null) return;
    final all = await store.list(all: true);
    if (!mounted) return;
    setState(() => _titles = {for (final e in all) e.id: e.title});
  }

  /// The series read as one: made (or found made) off the screen's thread.
  Future<String?> _all() async {
    final s = _series;
    final store = _service.library;
    if (s == null || store == null) return null;
    if (_allPath != null) return _allPath;
    setState(() => _making = true);
    try {
      final root = Directory(store.bookDir(s.books.first)).parent.parent.path;
      final out = '$root/memory_series/${s.id}.db';
      await Directory('$root/memory_series').create(recursive: true);
      final starts = await _buildOff(out, [
        for (final b in s.books) (path: _service.pathOf(b), title: _titles[b] ?? ''),
      ]);
      if (!mounted) return null;
      setState(() {
        _allPath = out;
        _starts = starts;
      });
      return out;
    } on Object catch (e) {
      if (mounted) showSnack(context, 'The series could not be read as one: $e');
      return null;
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  /// How far the reader may see in the series read as one: with a book's
  /// spoiler guard on, up to where they are in it (the books before it are
  /// read); otherwise all of it.
  Future<int?> _allLine() async {
    final s = _series;
    if (s == null) return null;
    for (final (i, b) in s.books.indexed) {
      final line = await _service.lineOf(b);
      if (line != null) return (i < _starts.length ? _starts[i] : 0) + line;
    }
    return null;
  }

  Future<void> _open(String what) async {
    final path = await _all();
    if (path == null || !mounted) return;
    final line = await _allLine();
    if (!mounted) return;
    final title = _series?.name ?? '';
    final Widget page = switch (what) {
      'who' => WhosWhoScreen(bookTitle: title, memoryPath: path, line: line, readOnly: true),
      'graph' => MemoryGraphScreen(bookTitle: title, memoryPath: path, line: line, here: line),
      'chapters' => ChapterNotesScreen(bookTitle: title, memoryPath: path, line: line),
      _ => ThreadsScreen(memoryPath: path, line: line),
    };
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _menu(String v) async {
    final s = _series;
    if (s == null) return;
    switch (v) {
      case 'rename':
        final t = await askText(context, title: 'Name this series', hint: s.name, initial: s.name);
        if (t != null && t.trim().isNotEmpty) await SeriesStore.instance.rename(s.id, t);
      case 'add':
        final store = _service.library;
        if (store == null) return;
        final book = await pickBookForMemory(context, store);
        if (book == null || !mounted || s.books.contains(book.id)) return;
        await SeriesStore.instance.carryOn(book.id, earlier: s.books.last, name: s.name);
        if (mounted) showSnack(context, '${book.title} is now Book ${s.books.length + 1}. Build its memory from its page.');
      case 'remove':
        final id = await showModalBottomSheet<String>(
          context: context,
          sheetAnimationStyle: sheetMotion(context),
          useSafeArea: true,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHeader('Take a book out of the series', subtitle: 'Its own memory stays'),
                for (final (i, b) in s.books.indexed)
                  ListTile(
                    title: Text('Book ${i + 1} · ${_titles[b] ?? b}'),
                    onTap: () => Navigator.of(ctx).pop(b),
                  ),
              ],
            ),
          ),
        );
        if (id != null) {
          setState(() => _book = null);
          await SeriesStore.instance.remove(id);
        }
      case 'dissolve':
        final ok = await confirm(context,
            title: 'Undo this series?',
            body: 'Each book keeps its own memory; they are no longer read together.',
            action: 'Undo series');
        if (ok) await SeriesStore.instance.dissolve(s.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _series;
    if (s == null) return const Scaffold();
    final book = _book;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: s.name,
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) => unawaited(_menu(v)),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename the series')),
                      PopupMenuItem(value: 'add', child: Text('Add a book after the last')),
                      PopupMenuItem(value: 'remove', child: Text('Take a book out')),
                      PopupMenuItem(value: 'dissolve', child: Text('Undo the series')),
                    ],
                  ),
                ],
              ),
              // All the books together, or one at a time.
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                  children: [
                    for (final i in [null, for (var i = 0; i < s.books.length; i++) i])
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.s),
                        child: ChoiceChip(
                          label: Text(i == null ? 'All books' : 'Book ${i + 1}'),
                          selected: book == i,
                          onSelected: (_) => setState(() => _book = i),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: book != null && book < s.books.length
                      ? [
                          Text(_titles[s.books[book]] ?? '', style: Skin.title(context, size: 20)),
                          const SizedBox(height: Gap.s),
                          BookMemorySection(
                            key: ValueKey(s.books[book]),
                            bookId: s.books[book],
                            bookTitle: _titles[s.books[book]] ?? '',
                            secret: false,
                            compact: false,
                          ),
                        ]
                      : [
                          Text(
                            'The ${s.books.length} books read as one: each book\'s chapters after the one before\'s, '
                            'and a person met in several books one entry. Each book keeps its own memory.',
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                                .copyWith(height: 1.4),
                          ),
                          const SizedBox(height: Gap.m),
                          for (final (i, b) in s.books.indexed)
                            ValueListenableBuilder<BookMemoryState>(
                              valueListenable: _service.stateOf(b),
                              builder: (context, st, _) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text('Book ${i + 1} · ${_titles[b] ?? ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(!File(_service.pathOf(b)).existsSync() || st.noted == 0
                                    ? 'No memory yet'
                                    : '${st.noted} chapters noted'),
                                onTap: () => setState(() => _book = i),
                              ),
                            ),
                          const SizedBox(height: Gap.m),
                          if (_making)
                            const Padding(
                              padding: EdgeInsets.all(Gap.m),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          for (final (key, title, sub) in const [
                            ('who', "Who's who", 'Everyone across the books, found by any name'),
                            ('graph', 'Graph', 'Who is linked to whom, across the books'),
                            ('chapters', 'Chapter by chapter', 'Every book\'s chapters, in order'),
                            ('threads', 'Threads', 'The open questions, across the books'),
                          ])
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              enabled: !_making,
                              title: Text(title),
                              subtitle: Text(sub),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => unawaited(_open(key)),
                            ),
                        ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
