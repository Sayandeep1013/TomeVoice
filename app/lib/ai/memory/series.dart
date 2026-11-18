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
/// Talk knows them. A name already here is not made twice. Returns how
/// many entities came over.
int followOn(String path, String previous) {
  final from = MemoryDb.open(previous);
  final to = MemoryDb.open(path);
  try {
    final g = BookGraph(to);
    return to.inTransaction(() {
      final ids = <int, int>{};
      final end = (from.db.select('SELECT max(ch) last FROM notes').first['last'] as int?) ?? 1 << 30;
      for (final e in from.db.select(
          'SELECT id, kind, name, about, mentions FROM entities WHERE merged_into IS NULL ORDER BY mentions DESC')) {
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
        for (final a in from.db.select('SELECT alias FROM aliases WHERE entity = ?', [e['id']])) {
          g.alias(id, a['alias'] as String, beforeThisBook);
        }
        to.db.execute('INSERT OR IGNORE INTO appearances(entity, ch) VALUES (?, ?)', [id, beforeThisBook]);
      }
      for (final f in from.db.select('SELECT entity, attr, value FROM facts WHERE until_ch IS NULL')) {
        final id = ids[f['entity']];
        if (id == null) continue;
        to.db.execute('INSERT INTO facts(entity, attr, value, from_ch) VALUES (?, ?, ?, ?)',
            [id, f['attr'], f['value'], beforeThisBook]);
      }
      for (final r in from.db.select('SELECT a, rel, b, note FROM relations WHERE until_ch IS NULL')) {
        final a = ids[r['a']], b = ids[r['b']];
        if (a == null || b == null) continue;
        to.db.execute('INSERT INTO relations(a, rel, b, from_ch, note) VALUES (?, ?, ?, ?, ?)',
            [a, r['rel'], b, beforeThisBook, r['note']]);
      }
      for (final t in from.db.select("SELECT title, norm, about FROM threads WHERE status = 'open'")) {
        to.db.execute("INSERT INTO threads(title, norm, about, raised_ch, status) VALUES (?, ?, ?, ?, 'open')",
            [t['title'], t['norm'], t['about'], beforeThisBook]);
      }
      // Its story: the arcs (or its chapters' summaries, for a short book)
      // as one account, the third level, before this book.
      final arcs = [
        for (final r in from.db.select('SELECT summary FROM arcs WHERE level = 1 ORDER BY from_ch')) r['summary'] as String,
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
