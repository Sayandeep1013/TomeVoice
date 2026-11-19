import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import '../../library_store.dart';
import 'memory_db.dart';

/// One chapter as the word index takes it.
class IndexedChapter {
  const IndexedChapter({
    required this.chapter,
    required this.section,
    required this.title,
    required this.hash,
    required this.chunks,
  });

  final int chapter;
  final int section;
  final String title;
  final String hash;
  final List<TextChunk> chunks;
}

/// The longest a chunk of the word index grows, in characters, before the
/// next sentence starts another; and the most sentences in one.
const _chunkChars = 420;
const _chunkUnits = 5;

/// Chapter [c] of [l] (its reading chapter), its sentences in chunks of a
/// few (never across a section), with the hash of its text, kept as chapter
/// [number] of the memory: a book's own chapter for a file, but a web
/// novel's chapter by its place in the novel's list (its section), as the
/// layout counts only the chapters on the phone. Null for a chapter with no
/// text.
IndexedChapter? chapterForIndex(ReadingLayout l, int c, {int? number}) {
  if (c < 0 || c >= l.chapters.length) return null;
  final first = l.chapterFirstUnit[c];
  final end = c + 1 < l.chapters.length ? l.chapterFirstUnit[c + 1] : l.units.length;
  if (end <= first) return null;
  final chunks = <TextChunk>[];
  final all = StringBuffer();
  MemoryPlace? start;
  final text = StringBuffer();
  var units = 0;
  void flush() {
    if (start != null && text.isNotEmpty) chunks.add(TextChunk(start: start!, text: text.toString(), units: units));
    start = null;
    text.clear();
    units = 0;
  }

  for (var u = first; u < end; u++) {
    final s = l.units[u];
    final t = s.text.trim();
    if (t.isEmpty) continue;
    if (start != null && (s.sectionIndex != start!.section || text.length >= _chunkChars || units >= _chunkUnits)) {
      flush();
    }
    start ??= MemoryPlace(chapter: number ?? c, section: s.sectionIndex, block: s.blockIndex, sentence: s.sentenceIndex);
    if (text.isNotEmpty) text.write(' ');
    text.write(t);
    all
      ..write(t)
      ..write('\n');
    units++;
  }
  flush();
  if (chunks.isEmpty) return null;
  final section = l.chapters[c];
  final sections = l.book.sections;
  final title = section < sections.length ? (sections[section].title ?? '') : '';
  return IndexedChapter(
    chapter: number ?? c,
    section: section,
    title: title,
    hash: sha1.convert(utf8.encode(all.toString())).toString(),
    chunks: chunks,
  );
}

/// [chapters] put in the word index of the memory at [path], those whose
/// text is as it was skipped. How many were (re)indexed.
int writeIndex(String path, List<IndexedChapter> chapters) {
  final db = MemoryDb.open(path);
  try {
    final have = db.indexedHashes();
    var n = 0;
    for (final c in chapters) {
      if (have[c.chapter] == c.hash) continue;
      db.indexChapter(ch: c.chapter, section: c.section, title: c.title, hash: c.hash, chunks: c.chunks);
      n++;
    }
    return n;
  } finally {
    db.close();
  }
}

// On another isolate, each closure made here from plain values (one made in
// the indexer's methods could carry the indexer and its library).
Future<int> _writeOff(String path, List<IndexedChapter> chapters) => Isolate.run(() => writeIndex(path, chapters));

Future<Set<int>> _indexedOff(String path) => Isolate.run(() {
      final db = MemoryDb.open(path);
      try {
        return db.indexedHashes().keys.toSet();
      } finally {
        db.close();
      }
    });

Future<int> _webBatchOff(String dir, String id, String path, Set<int> batch) => Isolate.run(() {
      final layout = loadWebChaptersSync(dir, id, batch);
      final chapters = [
        for (final (c, section) in layout.chapters.indexed)
          if (batch.contains(section)) chapterForIndex(layout, c, number: section),
      ].whereType<IndexedChapter>().toList();
      return writeIndex(path, chapters);
    });

/// How far a book's word index is.
class IndexProgress {
  const IndexProgress(this.done, this.total);

  final int done;
  final int total;
}

/// The word index of whole books, made on the phone: free, offline, and
/// with every word findable from any chapter. Made off the UI thread's
/// isolate; a web novel a hundred chapters at a time (only those on the
/// phone; others join as they are downloaded).
class WordIndexer {
  WordIndexer(this.store);

  final LibraryStore store;

  /// The memory file of book [id].
  String pathOf(String id) => MemoryDb.pathIn(store.bookDir(id));

  /// Book [id]'s word index brought up to date. Returns how many chapters
  /// were (re)indexed. For a web novel, the chapters in [again] (saved anew
  /// since) are read again even if indexed: a changed one is indexed afresh.
  Future<int> index(String id, {Set<int> again = const {}, void Function(IndexProgress p)? onProgress}) async {
    final entry = (await store.list(all: true)).where((e) => e.id == id).firstOrNull;
    if (entry == null) return 0;
    final path = pathOf(id);
    if (entry.isWeb) return _indexWeb(id, path, onProgress, again: again);
    final layout = await store.loadLayout(id);
    // Taken apart here (a walk over its sentences), written there.
    final chapters = [
      for (var c = 0; c < layout.chapters.length; c++) chapterForIndex(layout, c),
    ].whereType<IndexedChapter>().toList();
    onProgress?.call(IndexProgress(0, chapters.length));
    final n = await _writeOff(path, chapters);
    onProgress?.call(IndexProgress(chapters.length, chapters.length));
    return n;
  }

  Future<int> _indexWeb(String id, String path, void Function(IndexProgress p)? onProgress,
      {Set<int> again = const {}}) async {
    final dir = store.bookDir(id);
    final have = await _indexedOff(path);
    final on = store.downloadedChapters(id).toList()..sort();
    final todo = [for (final c in on) if (!have.contains(c) || again.contains(c)) c];
    var done = on.length - todo.length;
    onProgress?.call(IndexProgress(done, on.length));
    var n = 0;
    for (var i = 0; i < todo.length; i += 100) {
      final batch = todo.sublist(i, i + 100 > todo.length ? todo.length : i + 100).toSet();
      n += await _webBatchOff(dir, id, path, batch);
      done += batch.length;
      onProgress?.call(IndexProgress(done, on.length));
    }
    return n;
  }
}
