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
          'afresh as the memory builds.',
      action: 'Read it again',
    );
    if (!sure) return;
    await go(c.ch);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Chapter by chapter', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: notes == null
                    ? const Center(child: CircularProgressIndicator())
                    : notes.isEmpty
                        ? const EmptyState(
                            icon: Icons.menu_book_outlined,
                            title: 'No chapters yet',
                            body: 'Build the memory, and what it notes of each chapter shows here.',
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xl + bottom),
                            itemCount: notes.length,
                            itemBuilder: (context, i) => _chapter(context, notes[i]),
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
        borderRadius: BorderRadius.circular(Radii.row + 4),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.xs, Gap.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.accentInkOf(context))),
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
