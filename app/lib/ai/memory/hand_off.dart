import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../journal.dart';
import '../../speech_service.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../talk/answer_pack.dart' show chapterLabel;
import 'graph.dart' show describedSql;
import 'memory_db.dart';
import 'theories.dart';

/// A book's memory as one Markdown file, to talk about it in ChatGPT,
/// Gemini, NotebookLM or anywhere else: who the reader is in it (where they
/// are), the story so far, the people and things that matter most as they
/// stand, the threads still open, the reader's theories and journal. Kept to
/// chapter [line] when the guard is on (null: all of it).
String handOffMarkdown(
  String path, {
  required String title,
  String author = '',
  int? line,
  int? here,
  List<String> journal = const [],
  int cast = 40,
}) {
  final m = MemoryDb.open(path);
  try {
    final at = line ?? 1 << 30;
    final b = StringBuffer('# $title${author.isEmpty ? '' : ' — $author'}\n\n');
    b.writeln('A reader\'s companion notes, made by TomeVoice from the book itself.'
        '${line == null ? '' : ' They go only as far as chapter ${line + 1}: please do not reveal anything after it.'}'
        '${here == null ? '' : ' The reader is at chapter ${here + 1}.'}');
    b.writeln();

    final arcs = m.db.select(
        'SELECT from_ch, to_ch, summary FROM arcs WHERE level = 1 AND to_ch <= ? ORDER BY from_ch', [at]);
    final lastArc = arcs.isEmpty ? -1 : arcs.last['to_ch'] as int;
    b.writeln('## The story so far\n');
    for (final r in arcs) {
      b.writeln('**Chapters ${(r['from_ch'] as int) + 1}–${(r['to_ch'] as int) + 1}.** ${r['summary']}\n');
    }
    for (final r in m.db.select(
        'SELECT ch, summary FROM notes WHERE ch > ? AND ch <= ? ORDER BY ch', [lastArc, at])) {
      b.writeln('**Chapter ${(r['ch'] as int) + 1}.** ${r['summary']}\n');
    }

    b.writeln('## Who and what matters\n');
    for (final e in m.db.select(
      'SELECT e.id, e.name, e.kind, ${describedSql(at)} about, e.first_ch, '
      '(SELECT count(*) FROM appearances a WHERE a.entity = e.id AND a.ch <= ?) seen FROM entities e '
      'WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= ? ORDER BY seen DESC LIMIT ?',
      [at, at, cast],
    )) {
      final id = e['id'] as int;
      final names = [
        for (final a in m.db.select('SELECT alias FROM aliases WHERE entity = ? AND (ch IS NULL OR ch <= ?)', [id, at]))
          a['alias'] as String,
      ]..remove(e['name']);
      final facts = [
        for (final f in m.db.select(
            'SELECT attr, value FROM facts WHERE entity = ? AND from_ch <= ? AND (until_ch IS NULL OR until_ch > ?) '
            "AND attr != 'description'",
            [id, at, at]))
          '${f['attr']}: ${f['value']}',
      ];
      final rels = [
        for (final r in m.db.select(
          'SELECT r.rel, ea.name an, eb.name bn FROM relations r JOIN entities ea ON ea.id = r.a JOIN entities eb ON eb.id = r.b '
          'WHERE (r.a = ? OR r.b = ?) AND r.from_ch <= ? AND (r.until_ch IS NULL OR r.until_ch > ?) LIMIT 8',
          [id, id, at, at],
        ))
          '${r['an']} ${r['rel']} ${r['bn']}',
      ];
      b.writeln('- **${e['name']}** (${e['kind']}, from ${chapterLabel((e['first_ch'] as int?) ?? 0)})'
          '${names.isEmpty ? '' : ', also ${names.take(6).join(', ')}'}'
          '${(e['about'] as String?)?.isNotEmpty ?? false ? '. ${e['about']}' : ''}'
          '${facts.isEmpty ? '' : '. ${facts.join('; ')}'}'
          '${rels.isEmpty ? '' : '. ${rels.join('; ')}'}');
    }
    b.writeln();

    final threads = m.db.select(
      'SELECT title, about, raised_ch FROM threads WHERE raised_ch <= ? AND (resolved_ch IS NULL OR resolved_ch > ?) '
      'ORDER BY raised_ch',
      [at, at],
    );
    if (threads.isNotEmpty) {
      b.writeln('## Still unanswered\n');
      for (final t in threads) {
        b.writeln('- ${t['title']} (since ${chapterLabel(t['raised_ch'] as int)})${t['about'] == null ? '' : ': ${t['about']}'}');
      }
      b.writeln();
    }

    final mine = theoriesAt(path, here ?? at);
    if (mine.isNotEmpty) {
      b.writeln("## The reader's theories\n");
      for (final t in mine) {
        b.writeln('- ${t.text} (stated at ${chapterLabel(t.ch)}; ${t.decided ? t.status : 'still open'})');
      }
      b.writeln();
    }
    if (journal.isNotEmpty) {
      b.writeln("## The reader's journal\n");
      for (final j in journal) {
        b.writeln('- $j');
      }
      b.writeln();
    }
    return b.toString();
  } finally {
    m.close();
  }
}

Future<String> _handOffOff(String path, String title, String author, int? line, int? here, List<String> journal) =>
    Isolate.run(() => handOffMarkdown(path, title: title, author: author, line: line, here: here, journal: journal));

/// Copy or share a book's hand-off pack.
Future<void> showHandOff(
  BuildContext context, {
  required String memoryPath,
  required String bookId,
  required String title,
  String author = '',
  int? line,
  int? here,
}) async {
  final journal = [
    for (final e in JournalStore.instance.all)
      if (e.bookId == bookId && (line == null || e.stamp.chapter <= line))
        '${e.stamp.label}: ${e.words.replaceAll('\n', ' ')}',
  ];
  final how = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Talk about it elsewhere', subtitle: 'ChatGPT, Gemini, NotebookLM…'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
            child: Text(
              'The book as TomeVoice remembers it, in one page: the story so far, who matters, what is unanswered, '
              'your theories and journal${line == null ? '' : ', up to chapter ${line + 1}'}. Paste it into any chat.',
              style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(ctx)).copyWith(height: 1.4),
            ),
          ),
          SheetAction(icon: Icons.copy_rounded, label: 'Copy', onTap: () => Navigator.pop(ctx, 'copy')),
          SheetAction(icon: Icons.ios_share_rounded, label: 'Share as a file', onTap: () => Navigator.pop(ctx, 'share')),
          const SizedBox(height: Gap.s),
        ],
      ),
    ),
  );
  if (how == null || !context.mounted) return;
  final text = await _handOffOff(memoryPath, title, author, line, here, journal);
  if (!context.mounted) return;
  if (how == 'copy') {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showSnack(context, 'Copied. Paste it into the chat you like.');
    return;
  }
  final safe = title.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '').trim();
  final file = File('${Directory.systemTemp.path}/${safe.isEmpty ? 'book' : safe} - companion notes.md');
  await file.writeAsString(text);
  await const SpeechService().shareFile(file.path, mime: 'text/markdown');
}
