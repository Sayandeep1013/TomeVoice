import 'dart:convert';
import 'dart:io';

import 'memory_db.dart';

/// A series read as one, for its "All books" view: a memory made from the
/// books' own, read-only, so Who's who, the graph, Chapter by chapter and
/// Threads show the whole series. Each book's chapters follow the book
/// before's (Book 2's first chapter comes after Book 1's last), titled
/// "Book 2 · …"; a person met in several books is one entry, matched by
/// name. Nothing is copied into the books' own memories: this is made from
/// them, and made again when one of them changes. The word index is not in
/// it (Find where looks in each book).
///
/// [books] are the series' memories in order. Returns the chapter each
/// book starts at, in this memory's numbering.
List<int> buildSeriesDb(String out, List<({String path, String title})> books) {
  final sig = _signature(books);
  if (File(out).existsSync()) {
    final m = MemoryDb.open(out);
    try {
      if (m.meta('series_sig') == sig) {
        return [for (final s in (jsonDecode(m.meta('series_starts') ?? '[]') as List)) (s as num).toInt()];
      }
    } on Object {
      // Unreadable: made again.
    } finally {
      m.close();
    }
  }
  final tmp = File('$out.making');
  if (tmp.existsSync()) tmp.deleteSync();
  final m = MemoryDb.open(tmp.path);
  final starts = <int>[];
  try {
    final db = m.db;
    db.execute('BEGIN');
    // Every name already here (lower case), whichever book it came from.
    final byName = <String, int>{};
    var offset = 0;
    for (final (k, b) in books.indexed) {
      starts.add(offset);
      if (!File(b.path).existsSync()) continue;
      final src = MemoryDb.open(b.path);
      try {
        final s = src.db;
        final last = (s.select('SELECT coalesce(max(ch), -1) n FROM chapters').first['n'] as int);
        int at(int ch) => ch + offset;
        int? atOr(Object? ch) => ch is int ? (ch < 0 ? null : ch + offset) : null;
        final book = 'Book ${k + 1}';

        for (final r in s.select('SELECT name, about, core, accepted FROM kinds')) {
          db.execute('INSERT OR IGNORE INTO kinds(name, about, core, accepted) VALUES (?, ?, ?, ?)',
              [r['name'], r['about'], r['core'], r['accepted']]);
        }
        for (final r in s.select('SELECT * FROM chapters WHERE ch >= 0')) {
          final title = (r['title'] as String?)?.trim();
          db.execute(
              'INSERT INTO chapters(ch, section, title, hash, sentences, indexed, noted) VALUES (?, ?, ?, ?, ?, ?, ?)', [
            at(r['ch'] as int),
            at(r['section'] as int),
            '$book · ${title == null || title.isEmpty ? 'Chapter ${(r['ch'] as int) + 1}' : title}',
            r['hash'],
            r['sentences'],
            r['indexed'],
            r['noted'],
          ]);
        }
        for (final r in s.select('SELECT * FROM notes WHERE ch >= 0')) {
          db.execute('INSERT INTO notes(ch, summary, raw, model, made) VALUES (?, ?, ?, ?, ?)',
              [at(r['ch'] as int), r['summary'], r['raw'], r['model'], r['made']]);
        }

        // People and things: one entry a name across the books.
        final ids = <int, int>{};
        for (final r in s.select('SELECT * FROM entities WHERE merged_into IS NULL')) {
          final name = r['name'] as String;
          final key = name.trim().toLowerCase();
          final first = atOr(r['first_ch']);
          final lastCh = atOr(r['last_ch']);
          final known = byName[key];
          if (known != null) {
            ids[r['id'] as int] = known;
            db.execute(
                'UPDATE entities SET mentions = mentions + ?, last_ch = max(coalesce(last_ch, -1), coalesce(?, -1)), '
                'first_ch = coalesce(first_ch, ?), about = coalesce(?, about) WHERE id = ?',
                [r['mentions'] ?? 0, lastCh, first, r['about'], known]);
          } else {
            db.execute('INSERT INTO entities(kind, name, about, first_ch, last_ch, mentions) VALUES (?, ?, ?, ?, ?, ?)',
                [r['kind'], name, r['about'], first, lastCh, r['mentions'] ?? 0]);
            final id = db.lastInsertRowId;
            ids[r['id'] as int] = id;
            byName[key] = id;
          }
        }
        // Merged-away ones point at what they were merged into.
        for (final r in s.select('SELECT id, merged_into FROM entities WHERE merged_into IS NOT NULL')) {
          final to = ids[r['merged_into']];
          if (to != null) ids[r['id'] as int] = to;
        }
        int? e(Object? id) => id == null ? null : ids[id];

        for (final r in s.select('SELECT * FROM aliases')) {
          final id = e(r['entity']);
          if (id == null) continue;
          db.execute('INSERT OR IGNORE INTO aliases(entity, alias, norm, ch) VALUES (?, ?, ?, ?)',
              [id, r['alias'], r['norm'], atOr(r['ch'])]);
        }
        for (final r in s.select('SELECT * FROM appearances WHERE ch >= 0')) {
          final id = e(r['entity']);
          if (id == null) continue;
          db.execute('INSERT OR IGNORE INTO appearances(entity, ch) VALUES (?, ?)', [id, at(r['ch'] as int)]);
        }
        final events = <int, int>{};
        for (final r in s.select('SELECT * FROM events WHERE ch >= 0')) {
          db.execute(
              'INSERT INTO events(ch, sec, blk, sen, what, why, result, place, importance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [at(r['ch'] as int), r['sec'], r['blk'], r['sen'], r['what'], r['why'], r['result'], e(r['place']),
                r['importance']]);
          events[r['id'] as int] = db.lastInsertRowId;
        }
        for (final r in s.select('SELECT * FROM event_roles')) {
          final ev = events[r['event']], id = e(r['entity']);
          if (ev == null || id == null) continue;
          db.execute('INSERT INTO event_roles(event, entity, role) VALUES (?, ?, ?)', [ev, id, r['role']]);
        }
        for (final r in s.select('SELECT * FROM event_links')) {
          final a = events[r['a']], c = events[r['b']];
          if (a == null || c == null) continue;
          db.execute('INSERT INTO event_links(a, b, how) VALUES (?, ?, ?)', [a, c, r['how']]);
        }
        for (final r in s.select('SELECT * FROM facts WHERE from_ch >= 0')) {
          final id = e(r['entity']);
          if (id == null) continue;
          db.execute(
              'INSERT INTO facts(entity, attr, value, from_ch, until_ch, sec, blk, sen) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
              [id, r['attr'], r['value'], at(r['from_ch'] as int), atOr(r['until_ch']), r['sec'], r['blk'], r['sen']]);
        }
        for (final r in s.select('SELECT * FROM relations WHERE from_ch >= 0')) {
          final a = e(r['a']), c = e(r['b']);
          if (a == null || c == null) continue;
          db.execute(
              'INSERT INTO relations(a, rel, b, from_ch, until_ch, sec, blk, sen, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [a, r['rel'], c, at(r['from_ch'] as int), atOr(r['until_ch']), r['sec'], r['blk'], r['sen'], r['note']]);
        }
        for (final r in s.select('SELECT * FROM reveals WHERE ch >= 0')) {
          db.execute('INSERT INTO reveals(ch, sec, blk, sen, what, overturns) VALUES (?, ?, ?, ?, ?, ?)',
              [at(r['ch'] as int), r['sec'], r['blk'], r['sen'], r['what'], r['overturns']]);
        }
        for (final r in s.select('SELECT * FROM quotes WHERE ch >= 0')) {
          db.execute('INSERT INTO quotes(ch, sec, blk, sen, text, speaker) VALUES (?, ?, ?, ?, ?, ?)',
              [at(r['ch'] as int), r['sec'], r['blk'], r['sen'], r['text'], e(r['speaker'])]);
        }
        final threads = <int, int>{};
        for (final r in s.select('SELECT * FROM threads WHERE raised_ch >= 0')) {
          db.execute('INSERT INTO threads(title, norm, about, raised_ch, resolved_ch, status) VALUES (?, ?, ?, ?, ?, ?)',
              [r['title'], r['norm'], r['about'], at(r['raised_ch'] as int), atOr(r['resolved_ch']), r['status']]);
          threads[r['id'] as int] = db.lastInsertRowId;
        }
        for (final r in s.select('SELECT * FROM thread_steps WHERE ch >= 0')) {
          final t = threads[r['thread']];
          if (t == null) continue;
          db.execute('INSERT INTO thread_steps(thread, ch, sec, blk, sen, what, step) VALUES (?, ?, ?, ?, ?, ?, ?)',
              [t, at(r['ch'] as int), r['sec'], r['blk'], r['sen'], r['what'], r['step']]);
        }
        for (final r in s.select('SELECT * FROM arcs WHERE from_ch >= 0 AND level < 3')) {
          db.execute('INSERT OR IGNORE INTO arcs(level, from_ch, to_ch, summary) VALUES (?, ?, ?, ?)',
              [r['level'], at(r['from_ch'] as int), at(r['to_ch'] as int), r['summary']]);
        }
        offset += last + 1;
      } finally {
        src.close();
      }
    }
    m.setMeta('begun', '1');
    m.setMeta('series_starts', jsonEncode(starts));
    m.setMeta('series_titles', jsonEncode([for (final b in books) b.title]));
    m.setMeta('series_sig', sig);
    db.execute('COMMIT');
  } finally {
    m.close();
  }
  final done = File(out);
  if (done.existsSync()) done.deleteSync();
  tmp.renameSync(out);
  return starts;
}

/// What the books held when the series' memory was made: a change in one
/// (more chapters noted, a rebuild) makes it again.
String _signature(List<({String path, String title})> books) => [
      for (final b in books)
        if (File(b.path).existsSync()) '${b.path}:${File(b.path).statSync().size}:${File(b.path).lastModifiedSync().millisecondsSinceEpoch}' else '${b.path}:-',
    ].join('|');
