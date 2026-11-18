import 'dart:convert';

/// One chapter's notes as the Builder gives them, read and checked. Every
/// reference to a place in the chapter is a passage number ([at]), as the
/// chapter was numbered when it was sent; references to the cast are an
/// existing entity's ref (`e12`) or a new one's (`new:Name`).
class ChapterNotes {
  const ChapterNotes({
    required this.chapter,
    required this.summary,
    this.entities = const [],
    this.events = const [],
    this.facts = const [],
    this.relations = const [],
    this.threads = const [],
    this.reveals = const [],
    this.quotes = const [],
    this.newKinds = const [],
    this.raw,
  });

  final int chapter;
  final String summary;
  final List<NoteEntity> entities;
  final List<NoteEvent> events;
  final List<NoteFact> facts;
  final List<NoteRelation> relations;
  final List<NoteThread> threads;
  final List<NoteReveal> reveals;
  final List<NoteQuote> quotes;
  final List<({String name, String about})> newKinds;

  /// The chapter's part of the reply as it came, kept with the notes.
  final Map<String, Object?>? raw;
}

class NoteEntity {
  const NoteEntity({required this.ref, required this.kind, required this.name, this.aliases = const [], this.about});

  final String ref;
  final String kind;
  final String name;
  final List<String> aliases;
  final String? about;
}

class NoteEvent {
  const NoteEvent({
    required this.what,
    this.who = const [],
    this.to = const [],
    this.where,
    this.using = const [],
    this.why,
    this.result,
    this.at,
    this.importance = 2,
    this.after = const [],
  });

  final String what;

  /// Who did it, to whom, where, with what: entity refs.
  final List<String> who;
  final List<String> to;
  final String? where;
  final List<String> using;
  final String? why;
  final String? result;
  final int? at;

  /// 1 (a passing moment) to 5 (it changes the story).
  final int importance;

  /// Earlier events it follows from: a known event's ref (`v31`), or the
  /// number of an earlier event in this reply's list for the chapter (`#2`).
  final List<String> after;
}

class NoteFact {
  const NoteFact({required this.of, required this.attr, required this.value, this.at});

  final String of;
  final String attr;
  final String value;
  final int? at;
}

class NoteRelation {
  const NoteRelation({required this.a, required this.rel, required this.b, this.ends = false, this.at, this.note});

  final String a;
  final String rel;
  final String b;

  /// The relation ends here, rather than begins.
  final bool ends;
  final int? at;
  final String? note;
}

enum ThreadStep { raised, advanced, resolved }

class NoteThread {
  const NoteThread({required this.title, this.ref, required this.step, this.what, this.at});

  final String title;

  /// A known thread's ref (`t4`), when it is one.
  final String? ref;
  final ThreadStep step;
  final String? what;
  final int? at;
}

class NoteReveal {
  const NoteReveal({required this.what, this.overturns, this.at});

  final String what;
  final String? overturns;
  final int? at;
}

class NoteQuote {
  const NoteQuote({required this.text, this.by, this.at});

  final String text;
  final String? by;
  final int? at;
}

/// The reply was not notes: what was wrong, to send back once.
class NotesFormatException implements Exception {
  const NotesFormatException(this.message);

  final String message;

  @override
  String toString() => 'NotesFormatException: $message';
}

/// The JSON object in [reply]: the whole of it, or the part between the
/// first { and the last } when the model wrapped it in words or a fence.
Map<String, Object?> jsonObjectIn(String reply) {
  var t = reply.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
  if (fence != null) t = fence.group(1)!;
  Object? v;
  try {
    v = jsonDecode(t);
  } on FormatException {
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b <= a) throw const NotesFormatException('The reply holds no JSON object.');
    try {
      v = jsonDecode(t.substring(a, b + 1));
    } on FormatException catch (e) {
      throw NotesFormatException('The JSON does not parse: ${e.message}');
    }
  }
  if (v is! Map) throw const NotesFormatException('The reply is not a JSON object.');
  return v.cast<String, Object?>();
}

String? _str(Object? v) {
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  if (v is num) return v.toString();
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.replaceAll(RegExp(r'[^0-9-]'), ''));
  return null;
}

List<String> _strs(Object? v) {
  if (v is String) return [if (v.trim().isNotEmpty) v.trim()];
  if (v is! List) return const [];
  return [for (final x in v) if (_str(x) != null) _str(x)!];
}

List<Map<String, Object?>> _maps(Object? v) => [
      if (v is List)
        for (final x in v)
          if (x is Map) x.cast<String, Object?>(),
    ];

/// The notes for each of [expected] chapters in [reply]. A chapter missing,
/// or with no summary, is an error, as is a reply that is not JSON; any
/// other part that is wrong (an event with no words, a fact with no value)
/// is left out rather than failing the chapter.
List<ChapterNotes> parseChapterNotes(String reply, List<int> expected, {int passages = 1 << 30}) {
  final v = jsonObjectIn(reply);
  final list = _maps(v['chapters']);
  // One chapter sent: its notes may come without the list round them.
  if (list.isEmpty && expected.length == 1 && v['summary'] != null) list.add({...v, 'ch': expected.single});
  final byCh = <int, Map<String, Object?>>{};
  for (final (i, c) in list.indexed) {
    final ch = _int(c['ch']) ?? (i < expected.length ? expected[i] : null);
    if (ch != null) byCh[ch] = c;
  }
  final missing = [for (final e in expected) if (byCh[e]?['summary'] == null) e];
  if (missing.isNotEmpty) {
    throw NotesFormatException(
        'No notes with a summary came for chapter${missing.length == 1 ? '' : 's'} ${missing.join(', ')}.');
  }
  int? at(Object? x) {
    final n = _int(x);
    return n == null || n < 1 || n > passages ? null : n;
  }

  return [
    for (final ch in expected)
      () {
        final c = byCh[ch]!;
        return ChapterNotes(
          chapter: ch,
          raw: c,
          summary: _str(c['summary'])!,
          entities: [
            for (final e in _maps(c['entities']))
              if (_str(e['name']) != null)
                NoteEntity(
                  ref: _str(e['ref']) ?? 'new:${_str(e['name'])}',
                  kind: (_str(e['kind']) ?? 'term').toLowerCase(),
                  name: _str(e['name'])!,
                  aliases: _strs(e['aliases']),
                  about: _str(e['about']),
                ),
          ],
          events: [
            for (final e in _maps(c['events']))
              if (_str(e['what']) != null)
                NoteEvent(
                  what: _str(e['what'])!,
                  who: _strs(e['who']),
                  to: _strs(e['to']),
                  where: _str(e['where']),
                  using: _strs(e['with']),
                  why: _str(e['why']),
                  result: _str(e['result']),
                  at: at(e['at']),
                  importance: (_int(e['importance']) ?? 2).clamp(1, 5),
                  after: _strs(e['after']),
                ),
          ],
          facts: [
            for (final f in _maps(c['facts']))
              if (_str(f['of']) != null && _str(f['attr']) != null && _str(f['value']) != null)
                NoteFact(of: _str(f['of'])!, attr: _str(f['attr'])!.toLowerCase(), value: _str(f['value'])!, at: at(f['at'])),
          ],
          relations: [
            for (final r in _maps(c['relations']))
              if (_str(r['a']) != null && _str(r['rel']) != null && _str(r['b']) != null)
                NoteRelation(
                  a: _str(r['a'])!,
                  rel: _str(r['rel'])!.toLowerCase(),
                  b: _str(r['b'])!,
                  ends: (_str(r['change']) ?? '').toLowerCase().startsWith('end'),
                  at: at(r['at']),
                  note: _str(r['note']),
                ),
          ],
          threads: [
            for (final t in _maps(c['threads']))
              if (_str(t['title']) != null)
                NoteThread(
                  title: _str(t['title'])!,
                  ref: _str(t['ref']),
                  step: switch ((_str(t['step']) ?? '').toLowerCase()) {
                    'resolved' || 'resolves' || 'resolve' => ThreadStep.resolved,
                    'advanced' || 'advances' || 'advance' => ThreadStep.advanced,
                    _ => _str(t['ref']) != null ? ThreadStep.advanced : ThreadStep.raised,
                  },
                  what: _str(t['what']),
                  at: at(t['at']),
                ),
          ],
          reveals: [
            for (final r in _maps(c['reveals']))
              if (_str(r['what']) != null) NoteReveal(what: _str(r['what'])!, overturns: _str(r['overturns']), at: at(r['at'])),
          ],
          quotes: [
            for (final q in _maps(c['quotes']))
              if (_str(q['text']) != null) NoteQuote(text: _str(q['text'])!, by: _str(q['by']), at: at(q['at'])),
          ],
          newKinds: [
            for (final k in _maps(c['new_kinds']))
              if (_str(k['name']) != null) (name: _str(k['name'])!.toLowerCase(), about: _str(k['about']) ?? ''),
          ],
        );
      }(),
  ];
}

/// What the Builder is told, once, before the chapters.
const builderInstructions = '''
You build the memory of a novel for its reader: notes on each chapter that let a companion answer questions about the story later, recall who is who, and trace what happened, to whom, why, and with what result. Work only from the text given. Never add what you may know of the book from elsewhere.

The chapters come numbered by passage: [1], [2], … Use those numbers in "at" to say where something happens.

You are given the cast and threads already known, each with a ref (e12 for an entity, v31 for an event, t4 for a thread). Use those refs whenever the text means one of them, even by another name, title or pronoun. Give a new entity the ref "new:<its name>", the same in every chapter of this reply.

Return one JSON object, nothing else:
{"chapters": [{
  "ch": <the chapter number given>,
  "summary": "<what happens, 60 to 120 words, plain and specific, in story order>",
  "entities": [{"ref": "e12" or "new:Name", "kind": "<one of the kinds>", "name": "<fullest name used>", "aliases": ["<other names, titles, nicknames used for them here>"], "about": "<one line: who or what it is; only for new ones, or when this chapter changes what they are>"}],
  "events": [{"what": "<what happened, one sentence>", "who": [refs who did it], "to": [refs it was done to], "where": "<place ref>", "with": [refs of items or powers used], "why": "<why, when the text says or shows it>", "result": "<what came of it>", "at": <passage>, "importance": <1 passing … 5 changes the story>, "after": ["v31" or "#2": earlier events it follows from]}],
  "facts": [{"of": "<ref>", "attr": "<rank, title, status, location, holder, appearance, age, power, affiliation, alive, …>", "value": "<its value from here on>", "at": <passage>}],
  "relations": [{"a": "<ref>", "rel": "<ally of, enemy of, sibling of, parent of, child of, mentor of, servant of, member of, leader of, rival of, loves, owns, bound to, …>", "b": "<ref>", "change": "begins" or "ends", "at": <passage>, "note": "<how, in a few words>"}],
  "threads": [{"title": "<a mystery, promise, prophecy, goal or foreshadowing, as a short name>", "ref": "t4 when known", "step": "raised" or "advanced" or "resolved", "what": "<what this chapter adds>", "at": <passage>}],
  "reveals": [{"what": "<something the text now states plainly that changes what was believed>", "overturns": "<what was believed before>", "at": <passage>}],
  "quotes": [{"text": "<a line worth remembering, word for word>", "by": "<ref>", "at": <passage>}],
  "new_kinds": [{"name": "<a kind of thing this world needs that the kinds given do not cover, e.g. aspect, flaw, memory, echo>", "about": "<what it is>"}]
}]}

Be thorough: every named character, place, group, item, power, title and term that appears; every event that matters to the story, usually 3 to 15 a chapter; every change of rank, title, place, holder, relation or state. Say why and with what result whenever the text gives it. Keep each string short and exact. Leave out a list that has nothing.
''';

/// What the Builder is told about the cast and threads already known.
class BuilderContext {
  const BuilderContext({this.kinds = const [], this.entities = const [], this.threads = const [], this.events = const []});

  /// Kinds of entity, with what each is.
  final List<({String name, String about})> kinds;

  /// Known entities that bear on these chapters: their ref line.
  final List<String> entities;
  final List<String> threads;
  final List<String> events;

  String render() {
    final b = StringBuffer()
      ..writeln('Kinds: ${[for (final k in kinds) '${k.name} (${k.about})'].join('; ')}.');
    if (entities.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Known cast and things:')
        ..writeAll(entities, '\n')
        ..writeln();
    }
    if (events.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Recent events:')
        ..writeAll(events, '\n')
        ..writeln();
    }
    if (threads.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Open threads:')
        ..writeAll(threads, '\n')
        ..writeln();
    }
    return b.toString();
  }
}

/// A chapter as the Builder is sent it: its number, title and passages.
String chapterForBuilder(int ch, String title, List<String> passages) {
  final b = StringBuffer('### ch: $ch · ${title.isEmpty ? 'Chapter ${ch + 1}' : title}\n');
  for (final (i, p) in passages.indexed) {
    b.writeln('[${i + 1}] $p');
  }
  return b.toString();
}
