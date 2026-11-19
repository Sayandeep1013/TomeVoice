import 'dart:isolate';

import 'graph.dart';
import 'memory_db.dart';

/// The chapter rows carried over from an earlier book of a series stand
/// at: before this book's first chapter.
const beforeThisBook = -1;

/// The memory at [path] made to follow on from the one at [previous] (the
/// earlier book of a series): its cast and things come over with their
/// names and how they stood at its end, the relations that held, the
/// threads it left open, and its story as one account, all placed before
/// this book's first chapter, so the Builder links this book to them and
/// Talk knows them. A name already here is not made twice. With [upTo]
/// (the reader stopped there in the earlier book, and the spoiler guard is
/// on), only what stood at that chapter comes over. Returns how many
/// entities came over.
int followOn(String path, String previous, {int? upTo}) {
  final from = MemoryDb.open(previous);
  final to = MemoryDb.open(path);
  try {
    final g = BookGraph(to);
    return to.inTransaction(() {
      final ids = <int, int>{};
      final last = (from.db.select('SELECT max(ch) last FROM notes').first['last'] as int?) ?? 1 << 30;
      final cut = upTo != null && upTo < last;
      final end = cut ? upTo : last;
      for (final e in from.db.select(
          'SELECT id, kind, name, about, mentions FROM entities WHERE merged_into IS NULL '
          'AND (first_ch IS NULL OR first_ch <= ?) ORDER BY mentions DESC',
          [end])) {
        final name = e['name'] as String;
        var id = g.byName(name, kind: e['kind'] as String);
        if (id == null) {
          to.db.execute(
            'INSERT INTO entities(kind, name, about, first_ch, last_ch, mentions) VALUES (?, ?, ?, ?, ?, 0)',
            [e['kind'], name, e['about'], beforeThisBook, beforeThisBook],
          );
          id = to.db.lastInsertRowId;
        }
        ids[e['id'] as int] = id;
        for (final a in from.db.select('SELECT alias FROM aliases WHERE entity = ? AND (ch IS NULL OR ch <= ?)', [e['id'], end])) {
          g.alias(id, a['alias'] as String, beforeThisBook);
        }
        to.db.execute('INSERT OR IGNORE INTO appearances(entity, ch) VALUES (?, ?)', [id, beforeThisBook]);
      }
      for (final f in from.db.select(
          'SELECT entity, attr, value FROM facts WHERE from_ch <= ? AND (until_ch IS NULL OR until_ch > ?)', [end, end])) {
        final id = ids[f['entity']];
        if (id == null) continue;
        to.db.execute('INSERT INTO facts(entity, attr, value, from_ch) VALUES (?, ?, ?, ?)',
            [id, f['attr'], f['value'], beforeThisBook]);
      }
      for (final r in from.db.select(
          'SELECT a, rel, b, note FROM relations WHERE from_ch <= ? AND (until_ch IS NULL OR until_ch > ?)', [end, end])) {
        final a = ids[r['a']], b = ids[r['b']];
        if (a == null || b == null) continue;
        to.db.execute('INSERT INTO relations(a, rel, b, from_ch, note) VALUES (?, ?, ?, ?, ?)',
            [a, r['rel'], b, beforeThisBook, r['note']]);
      }
      for (final t in from.db.select(cut
          ? 'SELECT title, norm, about FROM threads WHERE raised_ch <= ? AND (resolved_ch IS NULL OR resolved_ch > ?)'
          : "SELECT title, norm, about FROM threads WHERE status = 'open' AND ? = ?",
          [end, end])) {
        to.db.execute("INSERT INTO threads(title, norm, about, raised_ch, status) VALUES (?, ?, ?, ?, 'open')",
            [t['title'], t['norm'], t['about'], beforeThisBook]);
      }
      // Its story: the arcs (or its chapters' summaries, for a short book)
      // as one account, the third level, before this book.
      final arcs = [
        for (final r in from.db.select('SELECT summary FROM arcs WHERE level = 1 AND to_ch <= ? ORDER BY from_ch', [end]))
          r['summary'] as String,
      ];
      final story = arcs.isNotEmpty
          ? arcs
          : [for (final r in from.db.select('SELECT summary FROM notes WHERE ch <= ? ORDER BY ch', [end])) r['summary'] as String];
      if (story.isNotEmpty) {
        to.db.execute(
          'INSERT INTO arcs(level, from_ch, to_ch, summary) VALUES (3, ?, ?, ?) '
          'ON CONFLICT(level, from_ch) DO UPDATE SET summary = excluded.summary',
          [beforeThisBook, beforeThisBook, story.join(' ')],
        );
      }
      return ids.length;
    });
  } finally {
    from.close();
    to.close();
  }
}

Future<int> followOnOff(String path, String previous) => Isolate.run(() => followOn(path, previous));

/// The memory at [path] made to follow on from those at [previous] (in the
/// series' order, each with how far the reader went in it, or null for all
/// of it): what came over before is taken out first, so this is also how a
/// changed earlier book is brought over again. Returns how many entities
/// came over.
int followOnAll(String path, List<({String path, int? upTo})> previous) {
  final to = MemoryDb.open(path);
  try {
    to.inTransaction(() => to.dropNotesOf(beforeThisBook));
  } finally {
    to.close();
  }
  var n = 0;
  for (final p in previous) {
    n += followOn(path, p.path, upTo: p.upTo);
  }
  return n;
}

Future<int> followOnAllOff(String path, List<({String path, int? upTo})> previous) =>
    Isolate.run(() => followOnAll(path, previous));
