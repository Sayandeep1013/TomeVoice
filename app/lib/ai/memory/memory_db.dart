import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'chapter_notes.dart' show tidyName;
import 'graph.dart' show normName, notAName;

/// A place in a book, exact to the sentence: the reader's own cursor
/// (section, block, sentence) and the reading chapter it is in. Every row
/// of a memory made from the text carries one, so the spoiler guard can
/// keep to the reader's line and an answer can cite where it read.
class MemoryPlace {
  const MemoryPlace({required this.chapter, required this.section, this.block = 0, this.sentence = 0});

  /// The reading chapter, from 0 (a web novel's chapter is its section).
  final int chapter;
  final int section;
  final int block;
  final int sentence;

  /// Ordered as the book reads.
  int compareTo(MemoryPlace o) {
    if (section != o.section) return section.compareTo(o.section);
    if (block != o.block) return block.compareTo(o.block);
    return sentence.compareTo(o.sentence);
  }

  @override
  bool operator ==(Object other) =>
      other is MemoryPlace &&
      other.chapter == chapter &&
      other.section == section &&
      other.block == block &&
      other.sentence == sentence;

  @override
  int get hashCode => Object.hash(chapter, section, block, sentence);

  @override
  String toString() => 'ch$chapter §$section ¶$block.$sentence';
}

/// A few sentences of a chapter, as the word index keeps them.
class TextChunk {
  const TextChunk({required this.start, required this.text, this.units = 1});

  final MemoryPlace start;
  final String text;

  /// How many sentences it holds.
  final int units;
}

/// A match in the word index: where, and the words round it with the
/// matched ones between « and ».
class TextHit {
  const TextHit({required this.place, required this.snippet, required this.text, required this.rank});

  final MemoryPlace place;
  final String snippet;

  /// The whole chunk.
  final String text;
  final double rank;
}

/// One book's memory: a SQLite file in the book's folder (memory.db), so it
/// goes with the book into a backup, a move or a replace, and Forget
/// deletes it. Made by the word index on the phone (free) and by the
/// Builder's chapter notes (AI); read by Talk, the cards, recaps and the
/// graph. Opened anywhere: it is FFI, so a background isolate opens its own.
///
/// Its layers, each row tagged with where in the book it came from:
/// - chapters: each chapter's title, the hash of its text, whether it is in
///   the word index and has notes;
/// - text: the word index (FTS5), a few sentences a row;
/// - notes: each chapter's summary, and its notes as the Builder gave them;
/// - the graph: entities (with aliases and the chapters they appear in),
///   events (with who took part and how they led to one another), facts
///   that change over time, relations over time, reveals, quotes;
/// - the story so far: arc summaries, and threads from raised to resolved;
/// - the reader: theories, and what they asked about.
class MemoryDb {
  MemoryDb._(this.db, this.path);

  final Database db;
  final String path;

  static const version = 4;

  static String pathIn(String bookDir) => '$bookDir/memory.db';

  static bool existsIn(String bookDir) => File(pathIn(bookDir)).existsSync();

  static bool existsAt(String path) => File(path).existsSync();

  /// The memory at [path], made if it is not there yet.
  static MemoryDb open(String path) {
    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    final m = MemoryDb._(db, path);
    m._setUp();
    return m;
  }

  /// A memory kept nowhere, for tests.
  static MemoryDb inMemory() {
    final m = MemoryDb._(sqlite3.openInMemory(), ':memory:');
    m._setUp();
    return m;
  }

  void close() => db.close();

  void _forgetNotNames() {
    for (final r in db.select('SELECT id, name FROM entities')) {
      if (!notAName(r['name'] as String)) continue;
      final id = r['id'];
      for (final t in ['aliases', 'appearances', 'event_roles', 'facts']) {
        db.execute('DELETE FROM $t WHERE entity = ?', [id]);
      }
      db.execute('DELETE FROM relations WHERE a = ? OR b = ?', [id, id]);
      db.execute('UPDATE quotes SET speaker = NULL WHERE speaker = ?', [id]);
      db.execute('DELETE FROM entities WHERE id = ?', [id]);
    }
  }

  void _tidyNames() {
    for (final r in db.select('SELECT id, name FROM entities')) {
      final name = r['name'] as String, tidy = tidyName(name);
      if (tidy != name) db.execute('UPDATE entities SET name = ? WHERE id = ?', [tidy, r['id']]);
    }
    final rows = db.select('SELECT entity, alias, norm, ch FROM aliases');
    db.execute('DELETE FROM aliases');
    for (final r in rows) {
      final norm = normName(r['alias'] as String);
      if (norm.isEmpty) continue;
      db.execute('INSERT OR IGNORE INTO aliases(entity, alias, norm, ch) VALUES (?, ?, ?, ?)',
          [r['entity'], tidyName(r['alias'] as String), norm, r['ch']]);
    }
  }

  void _setUp() {
    // Talk reads while a theory is kept, or while the Builder writes: each
    // waits its turn for a moment rather than failing at once ("database
    // is locked", met on the phone).
    db.execute('PRAGMA busy_timeout = 8000');
    // One file, no -wal beside it: a backup or a move takes the book's
    // folder as it is.
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute('PRAGMA foreign_keys = OFF');
    final have = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (have >= version) return;
    db.execute('BEGIN');
    try {
      if (have < 1) _schema1();
      // 2: whether the reader has been told a theory's verdict.
      if (have < 2) db.execute('ALTER TABLE theories ADD COLUMN told INTEGER DEFAULT 0');
      // 3: names a model gave as identifiers (Mountain_King, StoneSaint)
      // written as a reader would, and every name's lookup form again.
      // 4: again, for "TheMountain"; and refs taken for names (#2, v31)
      // forgotten.
      if (have >= 1 && have < 4) _tidyNames();
      if (have >= 1 && have < 4) _forgetNotNames();
      db.execute('PRAGMA user_version = $version');
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _schema1() {
    db.execute('''
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);

CREATE TABLE IF NOT EXISTS chapters(
  ch INTEGER PRIMARY KEY,
  section INTEGER NOT NULL,
  title TEXT,
  hash TEXT,
  sentences INTEGER DEFAULT 0,
  indexed INTEGER DEFAULT 0,
  noted INTEGER DEFAULT 0,
  note_error TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS text USING fts5(
  body,
  ch UNINDEXED, sec UNINDEXED, blk UNINDEXED, sen UNINDEXED, units UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TABLE IF NOT EXISTS notes(
  ch INTEGER PRIMARY KEY,
  summary TEXT,
  raw TEXT,
  model TEXT,
  made TEXT
);

CREATE TABLE IF NOT EXISTS kinds(
  name TEXT PRIMARY KEY,
  about TEXT,
  core INTEGER DEFAULT 0,
  accepted INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS entities(
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  about TEXT,
  first_ch INTEGER,
  last_ch INTEGER,
  mentions INTEGER DEFAULT 0,
  merged_into INTEGER
);

CREATE TABLE IF NOT EXISTS aliases(
  entity INTEGER NOT NULL,
  alias TEXT NOT NULL,
  norm TEXT NOT NULL,
  ch INTEGER,
  PRIMARY KEY(entity, norm)
);
CREATE INDEX IF NOT EXISTS aliases_norm ON aliases(norm);

CREATE TABLE IF NOT EXISTS appearances(
  entity INTEGER NOT NULL,
  ch INTEGER NOT NULL,
  PRIMARY KEY(entity, ch)
);
CREATE INDEX IF NOT EXISTS appearances_ch ON appearances(ch);

CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY,
  ch INTEGER NOT NULL, sec INTEGER, blk INTEGER, sen INTEGER,
  what TEXT NOT NULL,
  why TEXT,
  result TEXT,
  place INTEGER,
  importance INTEGER DEFAULT 2
);
CREATE INDEX IF NOT EXISTS events_ch ON events(ch);

CREATE TABLE IF NOT EXISTS event_roles(
  event INTEGER NOT NULL,
  entity INTEGER NOT NULL,
  role TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS event_roles_entity ON event_roles(entity);
CREATE INDEX IF NOT EXISTS event_roles_event ON event_roles(event);

CREATE TABLE IF NOT EXISTS event_links(
  a INTEGER NOT NULL,
  b INTEGER NOT NULL,
  how TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS facts(
  id INTEGER PRIMARY KEY,
  entity INTEGER NOT NULL,
  attr TEXT NOT NULL,
  value TEXT NOT NULL,
  from_ch INTEGER NOT NULL,
  until_ch INTEGER,
  sec INTEGER, blk INTEGER, sen INTEGER
);
CREATE INDEX IF NOT EXISTS facts_entity ON facts(entity);

CREATE TABLE IF NOT EXISTS relations(
  id INTEGER PRIMARY KEY,
  a INTEGER NOT NULL,
  rel TEXT NOT NULL,
  b INTEGER NOT NULL,
  from_ch INTEGER NOT NULL,
  until_ch INTEGER,
  sec INTEGER, blk INTEGER, sen INTEGER,
  note TEXT
);
CREATE INDEX IF NOT EXISTS relations_a ON relations(a);
CREATE INDEX IF NOT EXISTS relations_b ON relations(b);

CREATE TABLE IF NOT EXISTS reveals(
  id INTEGER PRIMARY KEY,
  ch INTEGER NOT NULL, sec INTEGER, blk INTEGER, sen INTEGER,
  what TEXT NOT NULL,
  overturns TEXT
);

CREATE TABLE IF NOT EXISTS quotes(
  id INTEGER PRIMARY KEY,
  ch INTEGER NOT NULL, sec INTEGER, blk INTEGER, sen INTEGER,
  text TEXT NOT NULL,
  speaker INTEGER
);

CREATE TABLE IF NOT EXISTS threads(
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  norm TEXT NOT NULL,
  about TEXT,
  raised_ch INTEGER NOT NULL,
  resolved_ch INTEGER,
  status TEXT DEFAULT 'open'
);
CREATE INDEX IF NOT EXISTS threads_norm ON threads(norm);

CREATE TABLE IF NOT EXISTS thread_steps(
  thread INTEGER NOT NULL,
  ch INTEGER NOT NULL, sec INTEGER, blk INTEGER, sen INTEGER,
  what TEXT,
  step TEXT
);

CREATE TABLE IF NOT EXISTS arcs(
  level INTEGER NOT NULL,
  from_ch INTEGER NOT NULL,
  to_ch INTEGER NOT NULL,
  summary TEXT NOT NULL,
  PRIMARY KEY(level, from_ch)
);

CREATE TABLE IF NOT EXISTS theories(
  id INTEGER PRIMARY KEY,
  text TEXT NOT NULL,
  ch INTEGER NOT NULL,
  made TEXT NOT NULL,
  status TEXT DEFAULT 'open',
  decided_ch INTEGER,
  verdict TEXT,
  evidence TEXT
);

CREATE TABLE IF NOT EXISTS asked(
  id INTEGER PRIMARY KEY,
  ch INTEGER,
  question TEXT NOT NULL,
  at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vectors(
  owner TEXT NOT NULL,
  id INTEGER NOT NULL,
  ch INTEGER NOT NULL,
  model TEXT NOT NULL,
  v BLOB NOT NULL,
  PRIMARY KEY(owner, id)
);
''');
    const core = {
      'person': 'People and other characters who act and speak',
      'place': 'Places: lands, cities, buildings, realms',
      'faction': 'Groups: clans, orders, guilds, nations, families',
      'item': 'Things: weapons, artefacts, tools, treasures',
      'power': 'Powers, abilities, skills, spells, techniques',
      'title': 'Titles and ranks, as names held by someone',
      'creature': 'Creatures and kinds of being',
      'term': "The world's own words: concepts, systems, events with names",
    };
    final put = db.prepare('INSERT OR IGNORE INTO kinds(name, about, core, accepted) VALUES (?, ?, 1, 1)');
    for (final e in core.entries) {
      put.execute([e.key, e.value]);
    }
    put.close();
  }

  // ------------------------------------------------------------- meta

  String? meta(String k) {
    final r = db.select('SELECT v FROM meta WHERE k = ?', [k]);
    return r.isEmpty ? null : r.first.columnAt(0) as String?;
  }

  void setMeta(String k, String? v) {
    if (v == null) {
      db.execute('DELETE FROM meta WHERE k = ?', [k]);
    } else {
      db.execute('INSERT INTO meta(k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', [k, v]);
    }
  }

  /// [body] in one transaction: all of it kept, or none.
  T inTransaction<T>(T Function() body) {
    db.execute('BEGIN');
    try {
      final out = body();
      db.execute('COMMIT');
      return out;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---------------------------------------------------------- chapters

  /// Chapter [ch]'s text hash, when it is in the word index.
  String? indexedHash(int ch) {
    final r = db.select('SELECT hash FROM chapters WHERE ch = ? AND indexed = 1', [ch]);
    return r.isEmpty ? null : r.first.columnAt(0) as String?;
  }

  /// The chapters in the word index, with their hashes.
  Map<int, String> indexedHashes() => {
        for (final r in db.select('SELECT ch, hash FROM chapters WHERE indexed = 1')) r['ch'] as int: r['hash'] as String,
      };

  /// Chapter [ch] put in the word index, as [chunks]; whatever it held
  /// before goes. A chapter whose text changed loses its notes too: they
  /// are made again from the new text.
  void indexChapter({
    required int ch,
    required int section,
    required String title,
    required String hash,
    required List<TextChunk> chunks,
  }) {
    inTransaction(() {
      final was = db.select('SELECT hash, noted FROM chapters WHERE ch = ?', [ch]);
      final changed = was.isNotEmpty && was.first['hash'] != null && was.first['hash'] != hash;
      db.execute('DELETE FROM text WHERE ch = ?', [ch]);
      final put = db.prepare('INSERT INTO text(body, ch, sec, blk, sen, units) VALUES (?, ?, ?, ?, ?, ?)');
      var sentences = 0;
      for (final c in chunks) {
        put.execute([c.text, ch, c.start.section, c.start.block, c.start.sentence, c.units]);
        sentences += c.units;
      }
      put.close();
      db.execute(
        'INSERT INTO chapters(ch, section, title, hash, sentences, indexed, noted) VALUES (?, ?, ?, ?, ?, 1, 0) '
        'ON CONFLICT(ch) DO UPDATE SET section = excluded.section, title = excluded.title, hash = excluded.hash, '
        'sentences = excluded.sentences, indexed = 1'
        '${changed ? ', noted = 0, note_error = NULL' : ''}',
        [ch, section, title, hash, sentences],
      );
    });
  }

  /// How many chapters are in the word index, and the last of them.
  ({int count, int? last}) indexedSpan() {
    final r = db.select('SELECT count(*) n, max(ch) last FROM chapters WHERE indexed = 1').first;
    return (count: r['n'] as int, last: r['last'] as int?);
  }

  // -------------------------------------------------------- word index

  /// What the reader typed, as an FTS5 query: every word must be there,
  /// each as the start of a word ("weav" finds "weaver"), in any order;
  /// words in quotes as a phrase.
  static String? ftsQuery(String typed, {bool any = false}) {
    final parts = <String>[];
    final phrase = RegExp(r'"([^"]+)"');
    var rest = typed;
    for (final m in phrase.allMatches(typed)) {
      final words = _words(m.group(1)!);
      if (words.isNotEmpty) parts.add('"${words.join(' ')}"');
    }
    rest = rest.replaceAll(phrase, ' ');
    for (final w in _words(rest)) {
      parts.add('"$w"*');
    }
    return parts.isEmpty ? null : parts.join(any ? ' OR ' : ' AND ');
  }

  static List<String> _words(String s) => [
        for (final w in s.toLowerCase().split(RegExp(r"[^\p{L}\p{N}']+", unicode: true)))
          if (w.replaceAll("'", '').isNotEmpty) w.replaceAll('"', ''),
      ];

  /// Where [query] is found, best matches first, kept to chapters up to
  /// [upTo] when the spoiler guard is on (null: anywhere), or to [only].
  /// With [any], a place with any of the words is found, those with most
  /// first (for a question's words, which are never all in one place).
  List<TextHit> search(String query, {int? upTo, Set<int>? only, int limit = 50, bool inOrder = false, bool any = false}) {
    final q = ftsQuery(query, any: any);
    if (q == null) return const [];
    final where = [
      'text MATCH ?',
      if (upTo != null) 'ch <= $upTo',
      if (only != null && only.isNotEmpty) 'ch IN (${only.join(',')})',
    ].join(' AND ');
    try {
      final rows = db.select(
        "SELECT ch, sec, blk, sen, body, snippet(text, 0, '«', '»', '…', 14) AS snip, bm25(text) AS rank "
        'FROM text WHERE $where ORDER BY ${inOrder ? 'ch, sec, blk, sen' : 'rank'} LIMIT ?',
        [q, limit],
      );
      return [
        for (final r in rows)
          TextHit(
            place: MemoryPlace(
                chapter: r['ch'] as int, section: r['sec'] as int, block: r['blk'] as int, sentence: r['sen'] as int),
            snippet: r['snip'] as String,
            text: r['body'] as String,
            rank: (r['rank'] as num).toDouble(),
          ),
      ];
    } on SqliteException {
      return const [];
    }
  }

  /// How many chunks of each chapter match [query]: for "found in 42
  /// chapters".
  Map<int, int> countByChapter(String query, {int? upTo}) {
    final q = ftsQuery(query);
    if (q == null) return const {};
    try {
      return {
        for (final r in db.select(
          'SELECT ch, count(*) n FROM text WHERE text MATCH ?${upTo == null ? '' : ' AND ch <= $upTo'} GROUP BY ch ORDER BY ch',
          [q],
        ))
          r['ch'] as int: r['n'] as int,
      };
    } on SqliteException {
      return const {};
    }
  }

  /// The text of chapter [ch], in order, from the word index.
  List<TextChunk> chapterText(int ch) => [
        for (final r in db.select('SELECT body, sec, blk, sen, units FROM text WHERE ch = ? ORDER BY sec, blk, sen', [ch]))
          TextChunk(
            start: MemoryPlace(chapter: ch, section: r['sec'] as int, block: r['blk'] as int, sentence: r['sen'] as int),
            text: r['body'] as String,
            units: r['units'] as int,
          ),
      ];

  /// The size of the memory on the phone.
  int get bytes {
    if (path == ':memory:') return 0;
    final f = File(path);
    return f.existsSync() ? f.lengthSync() : 0;
  }
}
