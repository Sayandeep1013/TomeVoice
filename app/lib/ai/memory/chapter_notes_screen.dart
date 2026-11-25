import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import 'memory_db.dart';

/// One chapter as the memory has it: its title, and what the AI noted of
/// it (null: not read yet), or why it was passed over.
typedef ChapterNote = ({int ch, String title, String? summary, String? error});

/// The chapters of the memory at [path], in order, within chapter [upTo]
/// when the spoiler guard is on.
List<ChapterNote> chapterNotes(String path, int? upTo) {
  if (!MemoryDb.existsAt(path)) return const [];
  final m = MemoryDb.open(path);
  try {
    return [
      for (final r in m.db.select(
        'SELECT c.ch, c.title, c.note_error, n.summary FROM chapters c LEFT JOIN notes n ON n.ch = c.ch '
        'WHERE c.ch >= 0 ${upTo == null ? '' : 'AND c.ch <= $upTo'} ORDER BY c.ch',
      ))
        (
          ch: r['ch'] as int,
          title: (r['title'] as String?) ?? '',
          summary: r['summary'] as String?,
          error: r['note_error'] as String?,
        ),
    ];
  } finally {
    m.close();
  }
}

/// Chapter [ch]'s notes taken out of the memory at [path], so it is read
/// again when the memory next builds.
void forgetChapterNotes(String path, int ch) {
  final m = MemoryDb.open(path);
  try {
    m.inTransaction(() => m.dropNotesOf(ch));
  } finally {
    m.close();
  }
}

/// What a typed [query] reads as a chapter's number: "120", "ch 120",
/// "Ch. 120", "chapter 120". Null when it is not one.
int? chapterNumberIn(String query) {
  final m = _numbered.firstMatch(query.trim());
  return m == null ? null : int.tryParse(m.group(1)!);
}

final _numbered = RegExp(r'^(?:ch(?:apter)?\.?\s*)?#?(\d+)$', caseSensitive: false);

/// The [notes] a search for [query] finds, in the book's order (or the
/// newest first, [newestFirst]): the chapter of that number first, then
/// those whose title or notes hold every word typed. Everything when
/// nothing is typed.
List<ChapterNote> findChapterNotes(List<ChapterNote> notes, String query, {bool newestFirst = false}) {
  final ordered = newestFirst ? notes.reversed.toList() : notes;
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return ordered;
  final number = chapterNumberIn(q);
  final words = q.split(RegExp(r'\s+'));
  final byNumber = <ChapterNote>[];
  final byWords = <ChapterNote>[];
  for (final c in ordered) {
    if (number != null && c.ch + 1 == number) {
      byNumber.add(c);
      continue;
    }
    final text = '${c.title}\n${c.summary ?? ''}'.toLowerCase();
    if (words.every(text.contains)) byWords.add(c);
  }
  return [...byNumber, ...byWords];
}

Future<List<ChapterNote>> _notesOff(String path, int? upTo) => Isolate.run(() => chapterNotes(path, upTo));

/// [forgetChapterNotes] on another isolate.
Future<void> forgetChapterNotesOff(String path, int ch) => Isolate.run(() => forgetChapterNotes(path, ch));

/// A book's memory > Chapter by chapter: what the AI noted of each chapter,
/// to look over; a poor one read again.
class ChapterNotesScreen extends StatefulWidget {
  const ChapterNotesScreen({
    super.key,
    required this.bookTitle,
    required this.memoryPath,
    this.line,
    this.onReadAgain,
  });

  final String bookTitle;
  final String memoryPath;
  final int? line;

  /// Chapter [ch] read again by the AI (its notes are dropped, and it is
  /// built afresh). Null: not offered (no key, or the book is kept away).
  final Future<void> Function(int ch)? onReadAgain;

  @override
  State<ChapterNotesScreen> createState() => _ChapterNotesScreenState();
}

class _ChapterNotesScreenState extends State<ChapterNotesScreen> {
  List<ChapterNote>? _notes;
  String _query = '';

  /// The latest chapters on top: what happened lately, without scrolling
  /// through a long web novel's thousands; or from the start.
  bool _newest = true;
  final _search = TextEditingController();
  final _list = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _list.dispose();
    super.dispose();
  }

  void _find(String v) {
    setState(() => _query = v);
    if (_list.hasClients) _list.jumpTo(0);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final n = await _notesOff(widget.memoryPath, widget.line);
    if (mounted) setState(() => _notes = n);
  }

  Future<void> _again(ChapterNote c) async {
    final go = widget.onReadAgain;
    if (go == null) return;
    final sure = await confirm(
      context,
      title: 'Read chapter ${c.ch + 1} again?',
      body: 'What the AI noted of it goes (its summary, and what it put in the cast and the graph), and it is read '
          "afresh as the memory builds (one more call). The other chapters' notes and your journal stay.",
      action: 'Read it again',
    );
    if (!sure) return;
    await go(c.ch);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    final shown = notes == null ? null : findChapterNotes(notes, _query, newestFirst: _newest);
    final searching = _query.trim().isNotEmpty;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: Skin.groundDecoration(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(
                title: 'Chapter by chapter',
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  if (notes != null && notes.length > 1)
                    PopupMenuButton<bool>(
                      tooltip: 'Order',
                      icon: const Icon(Icons.sort_rounded),
                      initialValue: _newest,
                      onSelected: (v) {
                        setState(() => _newest = v);
                        if (_list.hasClients) _list.jumpTo(0);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: true, child: Text('Newest first')),
                        PopupMenuItem(value: false, child: Text('From the start')),
                      ],
                    ),
                ],
              ),
              if (notes != null && notes.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xs),
                  child: SearchField(
                    controller: _search,
                    hint: 'Chapter number, or words in it',
                    onChanged: _find,
                    onClear: searching
                        ? () {
                            _search.clear();
                            _find('');
                          }
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.s),
                  child: Text(
                    (searching
                            ? '${shown!.length} OF ${notes.length} ${notes.length == 1 ? 'CHAPTER' : 'CHAPTERS'}'
                            : '${notes.length} ${notes.length == 1 ? 'CHAPTER' : 'CHAPTERS'}') +
                        (notes.length > 1 ? (_newest ? ' · NEWEST FIRST' : ' · FROM THE START') : ''),
                    style: Skin.meta(context),
                  ),
                ),
              ],
              Expanded(
                child: notes == null
                    ? const Center(child: CircularProgressIndicator())
                    : notes.isEmpty
                        ? const EmptyState(
                            icon: Icons.menu_book_outlined,
                            title: 'No chapters yet',
                            body: 'Build the memory, and what it notes of each chapter shows here.',
                          )
                        : shown!.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(Gap.xl),
                                child: Text('No chapters match.', style: Skin.label(context, size: 15)),
                              )
                            : ListView.builder(
                                controller: _list,
                                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xl + bottom),
                                itemCount: shown.length,
                                itemBuilder: (context, i) => _chapter(context, shown[i]),
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapter(BuildContext context, ChapterNote c) {
    final title = c.title.trim().isEmpty ? 'Chapter ${c.ch + 1}' : c.title.trim();
    final body = c.summary ??
        (c.error != null ? 'Passed over: ${c.error}' : 'Not read yet.');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Material(
        color: Skin.capsuleOn(context),
        shape: Skin.cardShape(context, Radii.row + 4),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.xs, Gap.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(children: [
                        // Its number, which a search by number finds: a book's own
                        // titles ("CHAPTER IX.") often count otherwise.
                        if (title != 'Chapter ${c.ch + 1}')
                          TextSpan(text: '${c.ch + 1}  ·  ', style: Skin.meta(context, size: 12)),
                        TextSpan(text: title),
                      ]),
                      style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.accentInkOf(context)),
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(
                      body,
                      style: Skin.ui(
                        size: 14,
                        weight: FontWeight.w400,
                        color: c.summary == null ? Skin.inkSoftOn(context) : Skin.inkOn(context),
                      ).copyWith(height: 1.4),
                    ),
                  ],
                ),
              ),
              if (widget.onReadAgain != null && (c.summary != null || c.error != null))
                PopupMenuButton<String>(
                  tooltip: 'More about chapter ${c.ch + 1}',
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (_) => unawaited(_again(c)),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'again', child: Text('Read this chapter again'))],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
