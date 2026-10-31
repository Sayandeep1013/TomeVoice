import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, PlatformException;

import 'folders.dart';
import 'library_store.dart';
import 'marks.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart';

/// One book's quotes, as they go into a Markdown export.
typedef BookQuotes = ({String title, String author, List<Mark> quotes});

/// The quotes to export: every book's ([bookId] null) or one book's, by
/// book, leaving out what Saved does not show (a shut secret shelf's, see
/// LibraryStore.marksShown). Books in the order of their newest quote, as
/// Saved shows them.
Future<List<BookQuotes>> quotesToExport(LibraryStore store, {String? bookId}) async {
  final shown = await store.marksShown();
  final entries = {for (final e in await store.list(all: true)) e.id: e};
  final byBook = <String, List<Mark>>{};
  for (final m in MarkStore.instance.all) {
    if (m.kind != MarkKind.quote || !shown(m)) continue;
    if (bookId != null && m.bookId != bookId) continue;
    byBook.putIfAbsent(m.bookId, () => []).add(m);
  }
  return [
    for (final MapEntry(key: id, value: marks) in byBook.entries)
      (
        title: entries[id]?.title ?? marks.first.bookTitle,
        author: entries[id]?.authorLine ?? '',
        quotes: marks,
      ),
  ];
}

/// [books] as Markdown: each book's title and author, then its quotes in
/// the order they come in the book, under their chapters, each with its
/// note and colour.
String quotesMarkdown(List<BookQuotes> books) {
  final out = StringBuffer();
  for (final b in books) {
    if (b.quotes.isEmpty) continue;
    if (out.isNotEmpty) out.write('\n');
    out.writeln('# ${_inline(b.title.isEmpty ? 'Untitled' : b.title)}');
    if (b.author.trim().isNotEmpty) out.writeln('\n*${_inline(b.author.trim())}*');
    final quotes = [...b.quotes]..sort(_inBookOrder);
    String? chapter;
    var first = true;
    for (final m in quotes) {
      if (first || m.chapter != chapter) {
        chapter = m.chapter;
        out.writeln('\n## ${_inline(chapter ?? 'Without a chapter')}');
      }
      first = false;
      out.writeln();
      for (final line in m.text.trim().split('\n')) {
        out.writeln('> ${_lineStart(line.trim())}');
      }
      out.writeln();
      final note = m.note?.trim();
      if (note != null && note.isNotEmpty) {
        out.writeln('- Note: ${note.split('\n').map((l) => l.trim()).join('\n  ')}');
      }
      out.writeln('- Colour: ${m.colour.label}');
    }
  }
  return out.toString();
}

int _inBookOrder(Mark a, Mark b) {
  final s = a.at.sectionIndex.compareTo(b.at.sectionIndex);
  if (s != 0) return s;
  final p = a.at.blockIndex.compareTo(b.at.blockIndex);
  if (p != 0) return p;
  final t = a.at.sentenceIndex.compareTo(b.at.sentenceIndex);
  return t != 0 ? t : a.created.compareTo(b.created);
}

/// A title on one line.
String _inline(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

final _structural = RegExp(r'^(#|>|[-+*] |=|\d+[.)] )');

/// A quoted line that would read as Markdown's own (a heading, a list)
/// kept as words.
String _lineStart(String line) => _structural.hasMatch(line) ? '\\$line' : line;

/// A file name from [title]: no characters a folder refuses.
String exportFileName(String title) {
  final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = clean.length > 80 ? clean.substring(0, 80).trim() : clean;
  return '${short.isEmpty ? 'Quotes' : short} - quotes.md';
}

/// Export as Markdown: [books]' quotes saved as a file in a folder the
/// reader picks (remembered for next time), or copied to paste elsewhere.
Future<void> exportQuotes(BuildContext context, List<BookQuotes> books, {required String fileName}) async {
  final count = books.fold<int>(0, (n, b) => n + b.quotes.length);
  if (count == 0) {
    showSnack(context, 'No quotes to export.');
    return;
  }
  final prefs = ListeningPrefs.loaded ?? ListeningPrefs.memory;
  final known = prefs.exportFolder;
  final how = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader('Export as Markdown', subtitle: '$count ${count == 1 ? 'quote' : 'quotes'}'),
          SheetAction(
            icon: Icons.save_alt_rounded,
            label: known == null ? 'Save as a file' : 'Save to ${known.name}',
            detail: known == null ? 'In a folder on your phone or in Drive' : fileName,
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          if (known != null)
            SheetAction(
              icon: Icons.drive_folder_upload_outlined,
              label: 'Save to another folder',
              onTap: () => Navigator.pop(ctx, 'other'),
            ),
          SheetAction(
            icon: Icons.copy_rounded,
            label: 'Copy',
            detail: 'To paste into notes, a document or an email',
            onTap: () => Navigator.pop(ctx, 'copy'),
          ),
          const SizedBox(height: Gap.s),
        ],
      ),
    ),
  );
  if (how == null || !context.mounted) return;
  final markdown = quotesMarkdown(books);
  if (how == 'copy') {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (context.mounted) showSnack(context, 'Copied as Markdown.');
    return;
  }
  const folders = Folders();
  var folder = how == 'save' ? known : null;
  try {
    folder ??= await folders.pick();
    if (folder == null || !context.mounted) return;
    if (folder.uri != known?.uri) {
      prefs.exportFolder = folder;
      prefs.save();
    }
    final name = await folders.writeText(folder, fileName, markdown);
    if (context.mounted) showSnack(context, 'Saved $name to ${folder.name}.');
  } on PlatformException catch (e) {
    // The folder was taken away (or deleted): asked for again next time.
    if (e.code == 'FOLDER' && prefs.exportFolder?.uri == folder?.uri) {
      prefs.exportFolder = null;
      prefs.save();
    }
    if (context.mounted) showSnack(context, 'Could not save the file: ${e.message ?? e.code}', long: true);
  }
}

/// The Export button of Saved and of a book's page.
class ExportQuotesButton extends StatelessWidget {
  const ExportQuotesButton({super.key, required this.store, this.bookId});

  final LibraryStore store;

  /// One book's quotes; every book's when null.
  final String? bookId;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Export as Markdown',
        icon: Icon(Icons.ios_share_rounded, size: 22, color: Skin.inkSoftOn(context)),
        onPressed: () async {
          final books = await quotesToExport(store, bookId: bookId);
          if (!context.mounted) return;
          final name = bookId != null && books.length == 1
              ? exportFileName(books.single.title)
              : 'TomeVoice ${exportFileName(_today())}';
          await exportQuotes(context, books, fileName: name);
        },
      );

  static String _today() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
