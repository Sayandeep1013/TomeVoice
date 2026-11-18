import 'dart:convert';
import 'dart:math' as math;

import 'chapter_notes.dart';
import 'memory_db.dart';

/// A name as the graph compares names: lower case, accents and marks gone,
/// "the" in front dropped, spaces single.
String normName(String s) {
  var t = s.toLowerCase();
  const from = 'àáâãäåāăąçćčďđèéêëēėęěìíîïīįıñńňòóôõöøōőŕřśšşťùúûüūůűųýÿźżž';
  const to = 'aaaaaaaaacccddeeeeeeeeiiiiiiinnnooooooooorrssstuuuuuuuuyyzzz';
  final b = StringBuffer();
  for (final r in t.runes) {
    final ch = String.fromCharCode(r);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  t = b.toString().replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ').trim();
  if (t.startsWith('the ')) t = t.substring(4);
  return t;
}

/// What entity [id] is, as known at chapter [at]: the description that
/// held then, or its first words.
String? describedAt(MemoryDb m, int id, int at) {
  final d = m.db.select(
    "SELECT value FROM facts WHERE entity = ? AND attr = 'description' AND from_ch <= ? ORDER BY from_ch DESC LIMIT 1",
    [id, at],
  );
  if (d.isNotEmpty) return d.first['value'] as String;
  return m.db.select('SELECT about FROM entities WHERE id = ?', [id]).firstOrNull?['about'] as String?;
}

/// The SQL for an entity's description at chapter [line], for a query on
/// entities `e`.
String describedSql(int line) =>
    "coalesce((SELECT f.value FROM facts f WHERE f.entity = e.id AND f.attr = 'description' AND f.from_ch <= $line "
    'ORDER BY f.from_ch DESC LIMIT 1), e.about)';

/// A reason as it follows an event: "because …", without a "because" the
/// model already gave, and its first word in lower case when it is only a
/// small word ("To cause wrecks" reads "because to cause wrecks").
String because(String why) {
  var t = why.trim();
  final lead = RegExp(r'^because\s+', caseSensitive: false);
  t = t.replaceFirst(lead, '');
  final first = t.split(' ').first;
  const small = {'to', 'so', 'he', 'she', 'it', 'they', 'his', 'her', 'their', 'the', 'a', 'an', 'in', 'for', 'of', 'as', 'out'};
  if (small.contains(first.toLowerCase()) && first.isNotEmpty) t = first.toLowerCase() + t.substring(first.length);
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return 'because $t';
}

/// The words of [text], normalised, for finding known names in it.
List<String> _words(String text) => normName(text).split(' ').where((w) => w.isNotEmpty).toList();

/// The graph of one book, in its memory: the cast and everything else with
/// a name (entities), what happened (events, who took part, what led to
/// what), how things stood and changed (facts, relations, both over time),
/// the mysteries (threads), reveals and lines worth keeping. Notes from the
/// Builder are merged into it a chapter at a time.
class BookGraph {
  BookGraph(this.m) {
    _loadAliases();
  }

  final MemoryDb m;

  /// norm → entity ids that go by it.
  final _alias = <String, Set<int>>{};

  /// The longest alias, in words, so a text is searched for names that long.
  int _longest = 1;

  void _loadAliases() {
    for (final r in m.db.select(
        'SELECT a.norm, a.entity FROM aliases a JOIN entities e ON e.id = a.entity WHERE e.merged_into IS NULL')) {
      _addAlias(r['norm'] as String, r['entity'] as int);
    }
  }

  void _addAlias(String norm, int id) {
    if (norm.isEmpty) return;
    (_alias[norm] ??= {}).add(id);
    _longest = math.max(_longest, norm.split(' ').length);
  }

  /// [about] as what entity [id] is from chapter [ch]: its first words, or,
  /// once it has some, a description that holds from [ch] on (as a rank
  /// does), so a card at an earlier chapter is not told what comes later.
  void describe(int id, String about, int ch) {
    final e = m.db.select('SELECT about, first_ch FROM entities WHERE id = ?', [id]).firstOrNull;
    if (e == null) return;
    if (e['about'] == null || (e['first_ch'] as int?) == ch) {
      m.db.execute('UPDATE entities SET about = ? WHERE id = ?', [about, id]);
      return;
    }
    if (normName(aboutAt(id, ch) ?? '') == normName(about)) return;
    m.db.execute("UPDATE facts SET until_ch = ? WHERE entity = ? AND attr = 'description' AND until_ch IS NULL", [ch, id]);
    m.db.execute("INSERT INTO facts(entity, attr, value, from_ch) VALUES (?, 'description', ?, ?)", [id, about, ch]);
  }

  /// What entity [id] is, as known at chapter [at].
  String? aboutAt(int id, int at) => describedAt(m, id, at);

  /// The entity [id] stands for now (a merged one, the one it went into).
  int? live(int id) {
    var at = id;
    for (var i = 0; i < 20; i++) {
      final r = m.db.select('SELECT merged_into FROM entities WHERE id = ?', [at]);
      if (r.isEmpty) return null;
      final into = r.first['merged_into'] as int?;
      if (into == null) return at;
      at = into;
    }
    return at;
  }

  /// The entity going by [name], preferring one of [kind].
  int? byName(String name, {String? kind}) {
    final ids = _alias[normName(name)];
    if (ids == null || ids.isEmpty) return null;
    if (ids.length == 1 || kind == null) return live(ids.first);
    for (final id in ids) {
      final r = m.db.select('SELECT kind FROM entities WHERE id = ? AND merged_into IS NULL', [id]);
      if (r.isNotEmpty && r.first['kind'] == kind) return id;
    }
    return live(ids.first);
  }

  /// Entities named in [text]: every run of up to the longest alias's words
  /// that is one.
  Set<int> namedIn(String text) {
    final words = _words(text);
    final found = <int>{};
    for (var i = 0; i < words.length; i++) {
      final b = StringBuffer();
      for (var n = 0; n < _longest && i + n < words.length; n++) {
        if (n > 0) b.write(' ');
        b.write(words[i + n]);
        final ids = _alias[b.toString()];
        if (ids != null) found.addAll(ids);
      }
    }
    return found;
  }

  int _newEntity(String kind, String name, String? about, int ch) {
    m.db.execute(
      'INSERT INTO entities(kind, name, about, first_ch, last_ch, mentions) VALUES (?, ?, ?, ?, ?, 0)',
      [kind, name, about, ch, ch],
    );
    final id = m.db.lastInsertRowId;
    alias(id, name, ch);
    return id;
  }

  /// [name] kept as one of entity [id]'s names, first used in [ch].
  void alias(int id, String name, int ch) {
    final norm = normName(name);
    if (norm.isEmpty) return;
    m.db.execute('INSERT OR IGNORE INTO aliases(entity, alias, norm, ch) VALUES (?, ?, ?, ?)', [id, name.trim(), norm, ch]);
    _addAlias(norm, id);
  }

  void _appears(int id, int ch) {
    m.db.execute('INSERT OR IGNORE INTO appearances(entity, ch) VALUES (?, ?)', [id, ch]);
    if (m.db.updatedRows > 0) {
      m.db.execute(
        'UPDATE entities SET mentions = mentions + 1, last_ch = max(coalesce(last_ch, ?), ?), '
        'first_ch = min(coalesce(first_ch, ?), ?) WHERE id = ?',
        [ch, ch, ch, ch, id],
      );
    }
  }

  /// The entity a reference in notes means: `e12` (a known one), `new:Name`
  /// (one met in these notes, or by its name one already known), or a bare
  /// name the model wrote instead of a ref. Made when it is new and
  /// [create]; [kind] is the kind it is made as.
  int? resolve(String ref, int ch, Map<String, int> made, {String kind = 'term', bool create = true}) {
    final r = ref.trim();
    final known = RegExp(r'^e(\d+)$').firstMatch(r);
    if (known != null) return live(int.parse(known.group(1)!));
    final name = r.startsWith('new:') ? r.substring(4).trim() : r;
    if (name.isEmpty) return null;
    final key = normName(name);
    final had = made[key] ?? byName(name, kind: kind);
    if (had != null) {
      made[key] = had;
      return had;
    }
    if (!create) return null;
    final id = _newEntity(kind, name, null, ch);
    made[key] = id;
    return id;
  }

  /// One chapter's [notes] merged in: [passages] are where each of its
  /// passages starts, as it was numbered for the Builder; [made] holds the
  /// new entities of the reply it came in, by name, across its chapters.
  void apply(ChapterNotes notes, List<MemoryPlace> passages, Map<String, int> made, {String? model}) {
    final ch = notes.chapter;
    MemoryPlace? place(int? at) =>
        at == null || passages.isEmpty ? null : passages[(at - 1).clamp(0, passages.length - 1)];
    List<Object?> where(int? at) {
      final p = place(at);
      return [p?.section, p?.block, p?.sentence];
    }

    // New kinds first, as proposals the reader may accept.
    for (final k in notes.newKinds) {
      m.db.execute('INSERT OR IGNORE INTO kinds(name, about, core, accepted) VALUES (?, ?, 0, 0)', [k.name, k.about]);
    }

    // The cast: known ones found, new ones made, every name kept.
    for (final e in notes.entities) {
      final id = resolve(e.ref, ch, made, kind: e.kind) ?? resolve('new:${e.name}', ch, made, kind: e.kind)!;
      made[normName(e.name)] = id;
      alias(id, e.name, ch);
      for (final a in e.aliases) {
        alias(id, a, ch);
      }
      if (e.about != null) describe(id, e.about!, ch);
      _appears(id, ch);
    }

    int? who(String ref, String kind) {
      final id = resolve(ref, ch, made, kind: kind);
      if (id != null) _appears(id, ch);
      return id;
    }

    // Events, who took part, and what they followed from.
    final eventIds = <int>[];
    for (final e in notes.events) {
      final at = where(e.at);
      final placeId = e.where == null ? null : who(e.where!, 'place');
      m.db.execute(
        'INSERT INTO events(ch, sec, blk, sen, what, why, result, place, importance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [ch, ...at, e.what, e.why, e.result, placeId, e.importance],
      );
      final id = m.db.lastInsertRowId;
      eventIds.add(id);
      void role(Iterable<String> refs, String role, String kind) {
        for (final r in refs) {
          final ent = who(r, kind);
          if (ent != null) m.db.execute('INSERT INTO event_roles(event, entity, role) VALUES (?, ?, ?)', [id, ent, role]);
        }
      }

      role(e.who, 'did', 'person');
      role(e.to, 'to', 'person');
      role(e.using, 'with', 'item');
      if (placeId != null) m.db.execute('INSERT INTO event_roles(event, entity, role) VALUES (?, ?, ?)', [id, placeId, 'at']);
      for (final a in e.after) {
        int? from;
        final v = RegExp(r'^v(\d+)$').firstMatch(a.trim());
        final local = RegExp(r'^#(\d+)$').firstMatch(a.trim());
        if (v != null) {
          final n = int.parse(v.group(1)!);
          if (m.db.select('SELECT 1 FROM events WHERE id = ?', [n]).isNotEmpty) from = n;
        } else if (local != null) {
          final n = int.parse(local.group(1)!) - 1;
          if (n >= 0 && n < eventIds.length - 1) from = eventIds[n];
        }
        if (from != null) m.db.execute('INSERT INTO event_links(a, b, how) VALUES (?, ?, ?)', [from, id, 'led to']);
      }
    }

    // How things stand from here: the value before ends where this begins.
    for (final f in notes.facts) {
      final id = who(f.of, 'person');
      if (id == null) continue;
      final open = m.db.select(
          'SELECT id, value FROM facts WHERE entity = ? AND attr = ? AND until_ch IS NULL ORDER BY from_ch DESC LIMIT 1',
          [id, f.attr]);
      if (open.isNotEmpty && normName(open.first['value'] as String) == normName(f.value)) continue;
      if (open.isNotEmpty) m.db.execute('UPDATE facts SET until_ch = ? WHERE id = ?', [ch, open.first['id']]);
      m.db.execute(
        'INSERT INTO facts(entity, attr, value, from_ch, sec, blk, sen) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, f.attr, f.value, ch, ...where(f.at)],
      );
    }

    for (final r in notes.relations) {
      final a = who(r.a, 'person'), b = who(r.b, 'person');
      if (a == null || b == null || a == b) continue;
      final open = m.db.select(
          'SELECT id FROM relations WHERE a = ? AND b = ? AND rel = ? AND until_ch IS NULL LIMIT 1', [a, b, r.rel]);
      if (r.ends) {
        if (open.isNotEmpty) m.db.execute('UPDATE relations SET until_ch = ? WHERE id = ?', [ch, open.first['id']]);
      } else if (open.isEmpty) {
        m.db.execute(
          'INSERT INTO relations(a, rel, b, from_ch, sec, blk, sen, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [a, r.rel, b, ch, ...where(r.at), r.note],
        );
      }
    }

    for (final t in notes.threads) {
      int? id;
      final known = RegExp(r'^t(\d+)$').firstMatch(t.ref ?? '');
      if (known != null) {
        final n = int.parse(known.group(1)!);
        if (m.db.select('SELECT 1 FROM threads WHERE id = ?', [n]).isNotEmpty) id = n;
      }
      final norm = normName(t.title);
      id ??= m.db
          .select('SELECT id FROM threads WHERE norm = ? ORDER BY resolved_ch IS NOT NULL, id DESC LIMIT 1', [norm])
          .firstOrNull?['id'] as int?;
      if (id == null) {
        m.db.execute(
          'INSERT INTO threads(title, norm, about, raised_ch, status) VALUES (?, ?, ?, ?, ?)',
          [t.title, norm, t.what, ch, t.step == ThreadStep.resolved ? 'resolved' : 'open'],
        );
        id = m.db.lastInsertRowId;
        if (t.step == ThreadStep.resolved) m.db.execute('UPDATE threads SET resolved_ch = ? WHERE id = ?', [ch, id]);
      } else if (t.step == ThreadStep.resolved) {
        m.db.execute("UPDATE threads SET resolved_ch = ?, status = 'resolved' WHERE id = ?", [ch, id]);
      }
      m.db.execute(
        'INSERT INTO thread_steps(thread, ch, sec, blk, sen, what, step) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, ch, ...where(t.at), t.what, t.step.name],
      );
    }

    for (final r in notes.reveals) {
      m.db.execute('INSERT INTO reveals(ch, sec, blk, sen, what, overturns) VALUES (?, ?, ?, ?, ?, ?)',
          [ch, ...where(r.at), r.what, r.overturns]);
    }
    for (final q in notes.quotes) {
      final by = q.by == null ? null : who(q.by!, 'person');
      m.db.execute('INSERT INTO quotes(ch, sec, blk, sen, text, speaker) VALUES (?, ?, ?, ?, ?, ?)',
          [ch, ...where(q.at), q.text, by]);
    }

    m.db.execute(
      'INSERT INTO notes(ch, summary, raw, model, made) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(ch) DO UPDATE SET summary = excluded.summary, raw = excluded.raw, model = excluded.model, '
      'made = excluded.made',
      [ch, notes.summary, notes.raw == null ? null : jsonEncode(notes.raw), model, DateTime.now().toUtc().toIso8601String()],
    );
    m.db.execute('UPDATE chapters SET noted = 1, note_error = NULL WHERE ch = ?', [ch]);
  }

  /// Everything made from chapter [ch]'s notes taken out again, to make
  /// them anew (its text changed, or the reader asked).
  void forgetChapter(int ch) {
    final events = [for (final r in m.db.select('SELECT id FROM events WHERE ch = ?', [ch])) r['id'] as int];
    if (events.isNotEmpty) {
      final list = events.join(',');
      m.db.execute('DELETE FROM event_roles WHERE event IN ($list)');
      m.db.execute('DELETE FROM event_links WHERE a IN ($list) OR b IN ($list)');
    }
    m.db.execute('DELETE FROM events WHERE ch = ?', [ch]);
    m.db.execute('DELETE FROM facts WHERE from_ch = ?', [ch]);
    m.db.execute('UPDATE facts SET until_ch = NULL WHERE until_ch = ?', [ch]);
    m.db.execute('DELETE FROM relations WHERE from_ch = ?', [ch]);
    m.db.execute('UPDATE relations SET until_ch = NULL WHERE until_ch = ?', [ch]);
    m.db.execute('DELETE FROM thread_steps WHERE ch = ?', [ch]);
    m.db.execute('DELETE FROM threads WHERE raised_ch = ? AND id NOT IN (SELECT thread FROM thread_steps)', [ch]);
    m.db.execute("UPDATE threads SET resolved_ch = NULL, status = 'open' WHERE resolved_ch = ?", [ch]);
    m.db.execute('DELETE FROM reveals WHERE ch = ?', [ch]);
    m.db.execute('DELETE FROM quotes WHERE ch = ?', [ch]);
    m.db.execute('DELETE FROM appearances WHERE ch = ?', [ch]);
    m.db.execute('DELETE FROM notes WHERE ch = ?', [ch]);
    m.db.execute('UPDATE chapters SET noted = 0 WHERE ch = ?', [ch]);
  }

  /// [from] merged into [into]: its names, appearances, part in events,
  /// facts and relations become [into]'s; it stays, pointing there, so a
  /// merge can be undone.
  void merge(int from, int into) {
    if (from == into) return;
    m.db.execute('UPDATE entities SET merged_into = ? WHERE id = ?', [into, from]);
    for (final r in m.db.select('SELECT alias, ch FROM aliases WHERE entity = ?', [from])) {
      alias(into, r['alias'] as String, (r['ch'] as int?) ?? 0);
    }
    m.db.execute('INSERT OR IGNORE INTO appearances(entity, ch) SELECT ?, ch FROM appearances WHERE entity = ?', [into, from]);
    m.db.execute('UPDATE event_roles SET entity = ? WHERE entity = ?', [into, from]);
    m.db.execute('UPDATE events SET place = ? WHERE place = ?', [into, from]);
    m.db.execute('UPDATE facts SET entity = ? WHERE entity = ?', [into, from]);
    m.db.execute('UPDATE relations SET a = ? WHERE a = ?', [into, from]);
    m.db.execute('UPDATE relations SET b = ? WHERE b = ?', [into, from]);
    m.db.execute('UPDATE quotes SET speaker = ? WHERE speaker = ?', [into, from]);
    m.db.execute(
      'UPDATE entities SET mentions = (SELECT count(*) FROM appearances WHERE entity = ?), '
      'first_ch = (SELECT min(ch) FROM appearances WHERE entity = ?), '
      'last_ch = (SELECT max(ch) FROM appearances WHERE entity = ?) WHERE id = ?',
      [into, into, into, into],
    );
    for (final ids in _alias.values) {
      if (ids.remove(from)) ids.add(into);
    }
  }

  /// What the Builder is told before chapters [chapters] (their [text]):
  /// the kinds; the known entities named in them and the recent cast, each
  /// with how it stands; their recent events that mattered; the threads
  /// still open.
  BuilderContext contextFor(List<int> chapters, String text, {int maxEntities = 150}) {
    final first = chapters.reduce(math.min);
    final kinds = [
      for (final r in m.db.select('SELECT name, about FROM kinds WHERE accepted = 1 ORDER BY core DESC, name'))
        (name: r['name'] as String, about: r['about'] as String? ?? ''),
    ];
    final ids = <int>{...namedIn(text).map((i) => live(i)).whereType<int>()};
    // The cast of the last chapters, met by pronoun and title as often as
    // by name.
    for (final r in m.db.select(
      'SELECT entity FROM appearances WHERE ch < ? AND ch >= ? GROUP BY entity ORDER BY count(*) DESC LIMIT 25',
      [first, first - 30],
    )) {
      final id = live(r['entity'] as int);
      if (id != null) ids.add(id);
    }
    final rows = ids.isEmpty
        ? const <Map<String, Object?>>[]
        : [
            for (final r in m.db.select(
              'SELECT id, kind, name, about, mentions FROM entities WHERE id IN (${ids.join(',')}) AND merged_into IS NULL '
              'ORDER BY mentions DESC LIMIT ?',
              [maxEntities],
            ))
              {for (final c in r.keys) c: r[c]},
          ];
    final lines = <String>[];
    final shown = <int>[];
    for (final r in rows) {
      final id = r['id'] as int;
      shown.add(id);
      final names = [
        for (final a in m.db.select('SELECT alias FROM aliases WHERE entity = ? AND alias != ? LIMIT 6', [id, r['name']]))
          a['alias'] as String,
      ];
      final facts = [
        for (final f in m.db.select(
            "SELECT attr, value FROM facts WHERE entity = ? AND until_ch IS NULL AND from_ch < ? AND attr != 'description' "
            'ORDER BY from_ch DESC LIMIT 6',
            [id, first]))
          '${f['attr']}: ${f['value']}',
      ];
      lines.add([
        'e$id ${r['kind']} "${r['name']}"',
        if (names.isNotEmpty) 'aka ${names.join(', ')}',
        if ((aboutAt(id, first) ?? '').isNotEmpty) '— ${aboutAt(id, first)}',
        if (facts.isNotEmpty) '| ${facts.join('; ')}',
      ].join(' '));
    }
    final events = shown.isEmpty
        ? const <String>[]
        : [
            for (final e in m.db.select(
              'SELECT DISTINCT v.id, v.ch, v.what, v.result FROM events v JOIN event_roles r ON r.event = v.id '
              'WHERE r.entity IN (${shown.take(40).join(',')}) AND v.ch < ? AND v.importance >= 3 '
              'ORDER BY v.ch DESC, v.id DESC LIMIT 40',
              [first],
            ))
              'v${e['id']} (ch ${e['ch']}) ${e['what']}${e['result'] == null ? '' : ' → ${e['result']}'}',
          ];
    final threads = [
      for (final t in m.db.select(
        'SELECT t.id, t.title, t.raised_ch, max(s.ch) last FROM threads t LEFT JOIN thread_steps s ON s.thread = t.id '
        "WHERE t.status = 'open' AND t.raised_ch < ? GROUP BY t.id ORDER BY last DESC LIMIT 40",
        [first],
      ))
        't${t['id']} "${t['title']}" (raised ch ${t['raised_ch']})',
    ];
    return BuilderContext(kinds: kinds, entities: lines, events: events.reversed.toList(), threads: threads);
  }
}
