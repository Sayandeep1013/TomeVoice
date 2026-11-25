// The Builder: each chapter's notes read from the model's reply (checked,
// the broken parts left out), merged into the book's graph (one cast across
// names, facts and relations over time, events and what led to what,
// threads from raised to resolved), and a whole book built a batch at a
// time against a provider, a bad reply asked again, a spent key waited for.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';
import 'package:tomevoice_spike/ai/memory/cast_tidy.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_builder.dart';
import 'package:tomevoice_spike/ai/memory/meaning.dart';
import 'package:tomevoice_spike/ai/memory/memory_background.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/memory_service.dart';
import 'package:tomevoice_spike/ai/memory/theories.dart';
import 'package:tomevoice_spike/ai/memory/word_index.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/secrets.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _p = MemoryPlace(chapter: 0, section: 0);

List<MemoryPlace> _places(int ch, int n) =>
    [for (var i = 0; i < n; i++) MemoryPlace(chapter: ch, section: ch, block: i, sentence: 0)];

void main() {
  group('reading the notes', () {
    test('a fenced reply, a single chapter without its list, the broken parts left out', () {
      final notes = parseChapterNotes(
        '```json\n{"summary": "Sunny wakes.", "entities": [{"ref": "new:Sunny", "kind": "Person", "name": "Sunny"}, {"kind": "x"}],'
        ' "events": [{"what": "He wakes", "at": 3}, {"who": ["new:Sunny"]}, {"what": "Far", "at": 99}],'
        ' "facts": [{"of": "new:Sunny", "attr": "Rank", "value": "Sleeper"}, {"of": "new:Sunny", "attr": "age"}]}\n```',
        [4],
        passages: 10,
      ).single;
      expect(notes.chapter, 4);
      expect(notes.summary, 'Sunny wakes.');
      expect(notes.entities.single.kind, 'person');
      expect(notes.events.map((e) => (e.what, e.at)), [('He wakes', 3), ('Far', null)]);
      expect(notes.facts.single.attr, 'rank');
    });

    test('a chapter missing, or no JSON at all, is an error to send back', () {
      expect(
        () => parseChapterNotes('{"chapters": [{"ch": 1, "summary": "One."}]}', [1, 2]),
        throwsA(isA<NotesFormatException>().having((e) => e.message, 'message', contains('chapter 2'))),
      );
      expect(() => parseChapterNotes('Sorry, I cannot.', [1]), throwsA(isA<NotesFormatException>()));
      expect(() => parseChapterNotes('{"chapters": [{"ch": 1}]}', [1]), throwsA(isA<NotesFormatException>()));
    });

    test('the threads and relations read their steps', () {
      final n = parseChapterNotes(
        jsonEncode({
          'chapters': [
            {
              'ch': 0,
              'summary': 's',
              'threads': [
                {'title': 'Who is the Weaver?', 'step': 'raised'},
                {'title': 'The door', 'ref': 't3'},
                {'title': 'The oath', 'step': 'Resolved'},
              ],
              'relations': [
                {'a': 'e1', 'rel': 'Ally of', 'b': 'e2', 'change': 'ends'},
              ],
            },
          ],
        }),
        [0],
      ).single;
      expect(n.threads.map((t) => t.step), [ThreadStep.raised, ThreadStep.advanced, ThreadStep.resolved]);
      expect(n.relations.single.ends, isTrue);
      expect(n.relations.single.rel, 'ally of');
    });
  });

  group('the graph', () {
    late MemoryDb m;
    late BookGraph g;

    setUp(() {
      m = MemoryDb.inMemory();
      for (var ch = 0; ch < 3; ch++) {
        m.indexChapter(ch: ch, section: ch, title: 'C$ch', hash: 'h$ch', chunks: const [TextChunk(start: _p, text: 'x')]);
      }
      g = BookGraph(m);
    });
    tearDown(() => m.close());

    int idOf(String name) => g.byName(name)!;

    test('one cast across chapters and names; facts and relations over time; events and what led to what', () {
      final made = <String, int>{};
      g.apply(
        const ChapterNotes(
          chapter: 0,
          summary: 'Sunless is chosen by the Spell.',
          entities: [
            NoteEntity(ref: 'new:Sunless', kind: 'person', name: 'Sunless', aliases: ['Sunny'], about: 'A boy of the outskirts'),
            NoteEntity(ref: 'new:The Spell', kind: 'term', name: 'The Spell'),
          ],
          events: [
            NoteEvent(what: 'The Spell chooses Sunny', who: ['new:The Spell'], to: ['new:Sunless'], at: 2, importance: 5),
            NoteEvent(what: 'He is taken to the police', to: ['new:Sunless'], after: ['#1'], at: 4),
          ],
          facts: [NoteFact(of: 'new:Sunless', attr: 'rank', value: 'Sleeper', at: 2)],
          threads: [NoteThread(title: 'What is the Spell?', step: ThreadStep.raised, at: 1)],
          quotes: [NoteQuote(text: 'Well, that is just great.', by: 'Sunny', at: 3)],
        ),
        _places(0, 5),
        made,
        model: 'm',
      );
      final sunny = idOf('Sunny');
      expect(idOf('sunless'), sunny);
      expect(g.byName('the spell'), isNotNull);
      expect(m.db.select('SELECT count(*) n FROM event_links').first['n'], 1);
      final ev = m.db.select("SELECT id, blk FROM events WHERE what LIKE 'The Spell%'").first;
      expect(ev['blk'], 1, reason: 'passage 2 is the second place');
      expect(m.db.select('SELECT speaker FROM quotes').first['speaker'], sunny);

      // Chapter 1 knows him as e<id> and by a new name; he rises; an ally
      // joins him; the thread is answered.
      made.clear();
      g.apply(
        ChapterNotes(
          chapter: 1,
          summary: 'Sunny awakens and meets Nephis.',
          entities: [
            NoteEntity(ref: 'e$sunny', kind: 'person', name: 'Sunless', aliases: const ['Lord of Shadows']),
            const NoteEntity(ref: 'new:Nephis', kind: 'person', name: 'Nephis', aliases: ['Changing Star']),
          ],
          events: [NoteEvent(what: 'Sunny survives the First Nightmare', who: ['e$sunny'], after: [
            'v${ev['id']}',
          ], importance: 4)],
          facts: [
            NoteFact(of: 'e$sunny', attr: 'rank', value: 'Awakened'),
            NoteFact(of: 'e$sunny', attr: 'rank', value: 'awakened'),
          ],
          relations: [NoteRelation(a: 'e$sunny', rel: 'ally of', b: 'new:Nephis')],
          threads: const [NoteThread(title: 'what is the spell', step: ThreadStep.resolved)],
        ),
        _places(1, 3),
        made,
      );
      expect(idOf('Lord of Shadows'), sunny);
      expect(idOf('Changing Star'), idOf('Nephis'));
      final ranks = m.db.select('SELECT value, from_ch, until_ch FROM facts WHERE entity = ? ORDER BY from_ch', [sunny]);
      expect([for (final r in ranks) (r['value'], r['from_ch'], r['until_ch'])], [('Sleeper', 0, 1), ('Awakened', 1, null)]);
      expect(m.db.select('SELECT count(*) n FROM event_links').first['n'], 2);
      expect(m.db.select('SELECT status, resolved_ch FROM threads').single.values, ['resolved', 1]);
      expect(m.db.select('SELECT mentions, first_ch, last_ch FROM entities WHERE id = ?', [sunny]).single.values, [2, 0, 1]);

      // Chapter 2: the alliance ends.
      g.apply(
        ChapterNotes(chapter: 2, summary: 'They part.', relations: [
          NoteRelation(a: 'e$sunny', rel: 'ally of', b: 'e${idOf('Nephis')}', ends: true),
        ]),
        _places(2, 1),
        {},
      );
      expect(m.db.select('SELECT from_ch, until_ch FROM relations').single.values, [1, 2]);
      expect(m.db.select('SELECT ch FROM chapters WHERE noted = 1').length, 3);

      // Named in a text, and what the Builder is told before chapter 3.
      expect(g.namedIn('Later, the Changing Star spoke to the Lord of Shadows.'), {sunny, idOf('Nephis')});
      final c = g.contextFor([3], 'Nephis drew her sword.');
      expect(c.entities.any((l) => l.startsWith('e$sunny person "Sunless"') && l.contains('rank: Awakened')), isTrue);
      expect(c.events.any((l) => l.contains('The Spell chooses Sunny')), isTrue);
      expect(c.kinds.map((k) => k.name), contains('person'));
    });

    test('two cards for one person merged; a chapter forgotten and made again', () {
      g.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Cassie', kind: 'person', name: 'Cassie'),
          NoteEntity(ref: 'new:Cassia', kind: 'person', name: 'Cassia'),
        ], facts: [
          NoteFact(of: 'new:Cassia', attr: 'sight', value: 'blind'),
        ]),
        _places(0, 1),
        {},
      );
      final cassie = g.byName('Cassie')!, cassia = g.byName('Cassia')!;
      g.merge(cassia, cassie);
      expect(g.byName('Cassia'), cassie);
      expect(m.db.select('SELECT entity FROM facts').single['entity'], cassie);
      expect(g.live(cassia), cassie);

      g.forgetChapter(0);
      expect(m.db.select('SELECT count(*) n FROM facts').first['n'], 0);
      expect(m.db.select('SELECT noted FROM chapters WHERE ch = 0').single['noted'], 0);
    });

    test('a merge undone: the card merged away stands again with its names, chapters and facts', () {
      g.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Cassie', kind: 'person', name: 'Cassie'),
          NoteEntity(ref: 'new:Cassia', kind: 'person', name: 'Cassia'),
        ], facts: [
          NoteFact(of: 'new:Cassia', attr: 'sight', value: 'blind'),
          NoteFact(of: 'new:Cassie', attr: 'voice', value: 'soft'),
        ]),
        _places(0, 1),
        {},
      );
      g.apply(
        const ChapterNotes(chapter: 1, summary: 's', entities: [
          NoteEntity(ref: 'new:Cassia', kind: 'person', name: 'Cassia'),
        ]),
        _places(1, 1),
        {},
      );
      final cassie = g.byName('Cassie')!, cassia = g.byName('Cassia')!;
      int count(String sql, List<Object?> args) => m.db.select(sql, args).first.columnAt(0) as int;
      g.merge(cassia, cassie, by: 'ai');
      expect(count('SELECT count(*) FROM appearances WHERE entity = ?', [cassie]), 2);
      final made = g.merges().single;
      expect((made.from, made.into, made.fromName, made.intoName, made.byAi), (cassia, cassie, 'Cassia', 'Cassie', true));
      expect(g.merges(into: cassia), isEmpty);

      expect(g.undoMerge(made.id), isTrue);
      expect(g.undoMerge(made.id), isFalse);
      expect(g.merges(), isEmpty);
      expect(g.live(cassia), cassia);
      expect(g.byName('Cassia'), cassia);
      // Cassie keeps only her own: one chapter, her own fact and name.
      expect(count('SELECT count(*) FROM appearances WHERE entity = ?', [cassie]), 1);
      expect(m.db.select('SELECT attr FROM facts WHERE entity = ?', [cassie]).single['attr'], 'voice');
      expect(m.db.select('SELECT attr FROM facts WHERE entity = ?', [cassia]).single['attr'], 'sight');
      expect(count("SELECT count(*) FROM aliases WHERE entity = ? AND norm = 'cassia'", [cassie]), 0);
      expect(m.db.select('SELECT mentions FROM entities WHERE id = ?', [cassia]).single['mentions'], 2);
    });

    test("what someone is, as known at a chapter: a later description does not leak back", () {
      g.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Oren', kind: 'person', name: 'Captain Oren', about: 'A harbour captain'),
        ]),
        _places(0, 1),
        {},
      );
      final oren = g.byName('Captain Oren')!;
      g.apply(
        ChapterNotes(chapter: 2, summary: 's', entities: [
          NoteEntity(ref: 'e$oren', kind: 'person', name: 'Captain Oren', about: 'The wrecker who rang the bell'),
        ]),
        _places(2, 1),
        {},
      );
      expect(describedAt(m, oren, 0), 'A harbour captain');
      expect(describedAt(m, oren, 1), 'A harbour captain');
      expect(describedAt(m, oren, 2), 'The wrecker who rang the bell');
      // Not a fact of its own on the card.
      expect(m.db.select("SELECT count(*) n FROM facts WHERE attr = 'description'").first['n'], 1);
    });

    test("a name on someone else's card goes to whoever goes by it; pronouns and someone's are not names", () {
      g.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Silver Haired Girl', kind: 'person', name: 'Silver Haired Girl'),
          NoteEntity(ref: 'new:Lanard', kind: 'person', name: 'Lanard'),
        ]),
        _places(0, 1),
        {},
      );
      final girl = g.byName('Silver Haired Girl')!, lanard = g.byName('Lanard')!;
      g.apply(
        ChapterNotes(chapter: 1, summary: 's', entities: [
          NoteEntity(
              ref: 'e$girl', kind: 'person', name: 'Nephis', aliases: const ['Changing Star', 'she', 'her teacher', 'creature']),
        ]),
        _places(1, 1),
        {},
      );
      // Known by a description, then named: called by the name.
      expect(m.db.select('SELECT name FROM entities WHERE id = ?', [girl]).single['name'], 'Nephis');
      expect(g.byName('Changing Star'), girl);
      for (final n in ['she', 'her teacher', 'creature']) {
        expect(g.byName(n), isNull, reason: n);
      }
      // The model's number for Lanard, with Nephis's name: hers.
      g.apply(
        ChapterNotes(chapter: 2, summary: 's', entities: [
          NoteEntity(ref: 'e$lanard', kind: 'person', name: 'Nephis', aliases: const ['Neph']),
        ]),
        _places(2, 1),
        {},
      );
      expect(g.byName('Neph'), girl);
      expect(m.db.select('SELECT count(*) n FROM appearances WHERE entity = ?', [lanard]).first['n'], 1);
      expect(keepsAsName('Doofus'), isTrue);
      expect(keepsAsName('the blind girl'), isTrue);
      expect(isProperName('Changing Star'), isTrue);
      expect(isProperName('Silver Haired Girl'), isFalse);
      expect(isProperName('Lady'), isFalse);
    });

    test("a minor character's card that took another's story hands it over from that chapter", () {
      g.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Lanard', kind: 'person', name: 'Lanard'),
          NoteEntity(ref: 'new:Nephis', kind: 'person', name: 'Nephis'),
        ]),
        _places(0, 1),
        {},
      );
      final lanard = g.byName('Lanard')!, nephis = g.byName('Nephis')!;
      g.apply(
        ChapterNotes(chapter: 2, summary: 's', entities: [
          NoteEntity(ref: 'e$lanard', kind: 'person', name: 'Lanard', aliases: const ['Changing Star']),
        ], facts: [
          NoteFact(of: 'e$lanard', attr: 'rank', value: 'Saint'),
        ]),
        _places(2, 1),
        {},
      );
      g.handOver(lanard, nephis, 1);
      expect(g.byName('Changing Star'), nephis);
      expect(g.byName('Lanard'), lanard);
      expect(m.db.select('SELECT ch FROM appearances WHERE entity = ? ORDER BY ch', [lanard]).map((r) => r['ch']), [0]);
      expect(m.db.select('SELECT entity FROM facts').single['entity'], nephis);
    });

    test('a caught-up book is tidied again only after enough new chapters', () {
      final dir = Directory.systemTemp.createTempSync('tv_tidy_due');
      final path = '${dir.path}/memory.db';
      final mm = MemoryDb.open(path);
      for (var c = 0; c < 40; c++) {
        mm.indexChapter(ch: c, section: c, title: 'C$c', hash: 'h$c', chunks: const [TextChunk(start: _p, text: 'x')]);
      }
      mm.db.execute('UPDATE chapters SET noted = 1');
      mm.close();
      expect(castTidyDue(path), isTrue, reason: 'never tidied and caught up');
      markCastTidied(path);
      expect(castTidyDue(path), isFalse);
      var m = MemoryDb.open(path);
      m.indexChapter(ch: 40, section: 40, title: 'C40', hash: 'h40', chunks: const [TextChunk(start: _p, text: 'x')]);
      m.db.execute('UPDATE chapters SET noted = 1');
      m.close();
      expect(castTidyDue(path), isFalse, reason: 'one new chapter of a followed book is not worth a tidy call');
      m = MemoryDb.open(path);
      for (var c = 41; c < 41 + tidyAtLeast; c++) {
        m.indexChapter(ch: c, section: c, title: 'C$c', hash: 'h$c', chunks: const [TextChunk(start: _p, text: 'x')]);
      }
      m.db.execute('UPDATE chapters SET noted = 1');
      m.close();
      expect(castTidyDue(path), isTrue);
      try {
        dir.deleteSync(recursive: true);
      } on Object {/* Windows file locks */}
    });

    test('the cast tidied by the AI: two cards made one, a description named, a wrong name taken off', () {
      final dir = Directory.systemTemp.createTempSync('tv_cast');
      final path = '${dir.path}/memory.db';
      var mm = MemoryDb.open(path);
      var gg = BookGraph(mm);
      mm.indexChapter(ch: 0, section: 0, title: 'C0', hash: 'h0', chunks: const [TextChunk(start: _p, text: 'x')]);
      gg.apply(
        const ChapterNotes(chapter: 0, summary: 's', entities: [
          NoteEntity(ref: 'new:Silver Haired Girl', kind: 'person', name: 'Silver Haired Girl'),
          NoteEntity(ref: 'new:Neph', kind: 'person', name: 'Neph'),
          NoteEntity(ref: 'new:Cassia', kind: 'person', name: 'Cassia'),
        ]),
        _places(0, 1),
        {},
      );
      final girl = gg.byName('Silver Haired Girl')!, neph = gg.byName('Neph')!, cassia = gg.byName('Cassia')!;
      gg.alias(girl, 'Nephis', 0, own: true);
      gg.alias(cassia, 'Changing Star', 0, own: true);
      mm.close();
      final changes = applyCastTidy(path, {
        'same': [
          {'keep': girl, 'merge': [neph, 999]},
        ],
        'names': [
          {'id': girl, 'name': 'Nephis'},
          {'id': cassia, 'name': 'Queen of Everything'},
        ],
        'wrong': [
          {'id': 'e$cassia', 'names': ['Changing Star']},
        ],
      }, {girl, neph, cassia});
      expect(changes, 3);
      mm = MemoryDb.open(path);
      gg = BookGraph(mm);
      expect(gg.live(neph), girl);
      expect(gg.byName('Neph'), girl);
      expect(mm.db.select('SELECT name FROM entities WHERE id = ?', [girl]).single['name'], 'Nephis');
      expect(mm.db.select('SELECT name FROM entities WHERE id = ?', [cassia]).single['name'], 'Cassia');
      expect(gg.answersTo(cassia, 'Changing Star'), isFalse);
      expect(mm.meta('cast_tidied'), isNotNull);
      expect(castTidyDue(path), isFalse);
      mm.close();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file.
      }
    });

    test('names given as identifiers are written as a reader would', () {
      expect(tidyName('Mountain_King'), 'Mountain King');
      expect(tidyName("Puppeteer's_Shroud"), "Puppeteer's Shroud");
      expect(tidyName('LordOfTheDead'), 'Lord of the Dead');
      expect(tidyName('McDonald'), 'McDonald');
      expect(tidyName('CentralChamber'), 'Central Chamber');
      expect(tidyName('SilverHairedGirl'), 'Silver Haired Girl');
      expect(tidyName('MacArthur'), 'MacArthur');
      expect(tidyName('DeShawn'), 'DeShawn');
      expect(tidyName('TheMountain'), 'The Mountain');
      expect(notAName('#2'), isTrue);
      expect(notAName('v31'), isTrue);
      expect(notAName('Vale'), isFalse);
      expect(normName('StoneSaint'), normName('Stone Saint'));
      expect(tidyName('Sunless'), 'Sunless');
      expect(normName('Mountain_King'), normName('Mountain King'));
    });

    test('a memory made before: its identifier names are tidied once, and found by their tidy form', () {
      final dir = Directory.systemTemp.createTempSync('tv_tidy');
      final path = '${dir.path}/memory.db';
      var old = MemoryDb.open(path);
      old.db.execute("INSERT INTO entities(kind, name, first_ch, last_ch, mentions) VALUES ('person', 'StoneSaint', 0, 0, 1)");
      final id = old.db.lastInsertRowId;
      old.db.execute("INSERT INTO aliases(entity, alias, norm, ch) VALUES (?, 'StoneSaint', 'stonesaint', 0)", [id]);
      old.db.execute('PRAGMA user_version = 2');
      old.close();
      old = MemoryDb.open(path);
      final graph = BookGraph(old);
      expect(old.db.select('SELECT name FROM entities WHERE id = ?', [id]).single['name'], 'Stone Saint');
      expect(graph.byName('Stone Saint'), id);
      expect(graph.byName('StoneSaint'), id);
      expect(graph.namedIn('Then the Stone Saint moved.'), {id});
      old.close();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file.
      }
    });

    test('a chapter noted late slots into its place in time, not over what came after', () {
      final made = <String, int>{};
      g.apply(
        const ChapterNotes(chapter: 2, summary: 's', entities: [
          NoteEntity(ref: 'new:Sunny', kind: 'person', name: 'Sunny'),
          NoteEntity(ref: 'new:Nephis', kind: 'person', name: 'Nephis'),
        ], facts: [
          NoteFact(of: 'new:Sunny', attr: 'rank', value: 'Awakened'),
        ], relations: [
          NoteRelation(a: 'new:Sunny', rel: 'ally of', b: 'new:Nephis'),
        ]),
        _places(2, 1),
        made,
      );
      final sunny = g.byName('Sunny')!;
      final nephis = g.byName('Nephis')!;
      // Chapter 0 arrives later: a Sleeper then, allies already.
      g.apply(
        ChapterNotes(chapter: 0, summary: 's', facts: [
          NoteFact(of: 'e$sunny', attr: 'rank', value: 'Sleeper'),
        ], relations: [
          NoteRelation(a: 'e$sunny', rel: 'ally of', b: 'e$nephis'),
        ]),
        _places(0, 1),
        {},
      );
      final ranks = m.db.select('SELECT value, from_ch, until_ch FROM facts WHERE entity = ? ORDER BY from_ch', [sunny]);
      expect([for (final r in ranks) (r['value'], r['from_ch'], r['until_ch'])], [('Sleeper', 0, 2), ('Awakened', 2, null)]);
      expect(m.db.select('SELECT from_ch, until_ch FROM relations').single.values, [0, null]);
    });

    test('a reason reads after its event without a doubled because', () {
      expect(because('To cause shipwrecks'), 'because to cause shipwrecks');
      expect(because('Because he wanted gold.'), 'because he wanted gold');
      expect(because('Oren feared the Order'), 'because Oren feared the Order');
    });

    test('names compare without case, accents, marks or "the"', () {
      expect(normName('The Lord-of-Shadows!'), 'lord of shadows');
      expect(normName('Éclair'), 'eclair');
    });
  });

  group('meaning search', () {
    test('vectors kept small, read back close; the nearest moments found, kept to the line', () {
      final v = [0.5, -0.25, 0.125, 0.0];
      final back = unpackVector(packVector(v));
      for (var i = 0; i < v.length; i++) {
        expect(back[i], closeTo(v[i], 0.01));
      }
      final m = MemoryDb.inMemory();
      m.close();
      final tmp = Directory.systemTemp.createTempSync('tv_meaning');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/memory.db';
      final db = MemoryDb.open(path);
      for (var ch = 0; ch < 3; ch++) {
        db.indexChapter(ch: ch, section: ch, title: 'C', hash: 'h$ch', chunks: [TextChunk(start: MemoryPlace(chapter: ch, section: ch), text: 't')]);
        db.db.execute('INSERT INTO notes(ch, summary) VALUES (?, ?)', [ch, ['Snow and cold', 'A feast', 'Freezing again'][ch]]);
      }
      db.close();
      expect(pendingMeaning(path, 'emb').map((i) => i.text), ['Snow and cold', 'A feast', 'Freezing again']);
      keepVectors(path, 'emb', pendingMeaning(path, 'emb'), [
        [1, 0, 0],
        [0, 1, 0],
        [0.9, 0.1, 0],
      ]);
      expect(pendingMeaning(path, 'emb'), isEmpty);
      expect(pendingMeaning(path, 'other').length, 3);
      final cold = meaningSearch(path, 'emb', [1, 0, 0], limit: 2);
      expect(cold.map((h) => h.ch), [0, 2]);
      expect(meaningSearch(path, 'emb', [1, 0, 0], upTo: 1, limit: 2).map((h) => h.ch), [0, 1]);
    });
  });

  group('building a book', () {
    late Directory tmp;
    late LibraryStore store;
    late HttpServer server;
    late List<Map<String, Object?>> sent;
    late Future<void> Function(HttpRequest req, Map<String, Object?> body) answer;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tv_builder');
      store = LibraryStore(tmp);
      AiRing.instance.reset();
      sent = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = (jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, Object?>();
        sent.add(body);
        await answer(req, body);
      });
      await AiRing.instance.put(AiKey(
        id: 'k',
        provider: AiProvider.inception,
        label: 'Mercury',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        secret: 's',
        models: const {AiJob.builder: 'mercury-3'},
      ));
    });

    tearDown(() async {
      await server.close(force: true);
      AiRing.instance.reset();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    Future<void> reply(HttpRequest req, int status, Object body) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    }

    Map<String, Object?> chat(String content) => {
          'choices': [
            {'message': {'role': 'assistant', 'content': content}, 'finish_reason': 'stop'},
          ],
          'usage': {'prompt_tokens': 1000, 'completion_tokens': 200},
        };

    /// Notes for every chapter the request carries.
    String notesFor(Map<String, Object?> body) {
      final prompt = ((body['messages'] as List).last as Map)['content'] as String;
      final chs = [for (final m in RegExp(r'### ch: (\d+)').allMatches(prompt)) int.parse(m.group(1)!)];
      return jsonEncode({
        'chapters': [
          for (final ch in chs)
            {
              'ch': ch,
              'summary': 'Chapter $ch happens.',
              'entities': [
                {'ref': ch == 0 ? 'new:Mira' : (prompt.contains('"Mira"') ? 'e1' : 'new:Mira'), 'kind': 'person', 'name': 'Mira'},
              ],
              'events': [
                {'what': 'Mira acts in $ch', 'who': [ch == 0 ? 'new:Mira' : 'e1'], 'at': 1, 'importance': 3},
              ],
            },
        ],
      });
    }

    Future<String> book(int chapters) async {
      final text = [for (var i = 0; i < chapters; i++) '# Chapter ${i + 1}: Part\n\nMira walked on. The road was long.'].join('\n\n');
      final f = File('${tmp.path}/incoming/road.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      final id = (await store.importFile(PickedFile(path: f.path, name: 'road.md'))).id;
      await WordIndexer(store).index(id);
      return MemoryDb.pathIn(store.bookDir(id));
    }

    test('every chapter noted, a batch at a time, the cast carried from one to the next', () async {
      final path = await book(5);
      answer = (req, body) => reply(req, 200, chat(notesFor(body)));
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 2));
      final est = await b.estimate();
      expect(est.chapters, 5);
      expect(est.calls, 3);
      final s = await b.run();
      expect(s.phase, BuildPhase.done);
      expect((s.noted, s.total), (5, 5));
      expect(sent.length, 3);
      expect(sent.first['response_format'], {'type': 'json_object'});
      // The second batch was told of Mira, and used her ref.
      expect(((sent[1]['messages'] as List).last as Map)['content'], contains('e1 person "Mira"'));
      final m = MemoryDb.open(path);
      addTearDown(m.close);
      expect(m.db.select('SELECT count(*) n FROM entities').first['n'], 1);
      expect(m.db.select('SELECT mentions FROM entities').first['mentions'], 5);
      expect(m.db.select('SELECT count(*) n FROM events').first['n'], 5);
      expect(AiRing.instance.today('k').calls, 3);
    });

    test('the story so far: a summary of every 25 chapters, once their notes are made and the reading is past', () async {
      final path = await book(27);
      answer = (req, body) {
        final system = ((body['messages'] as List).first as Map)['content'] as String;
        if (system.contains('story so far')) return reply(req, 200, chat('In these chapters Mira walks on.'));
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 400000, chapters: 10));
      expect((await b.run()).phase, BuildPhase.done);
      final m = MemoryDb.open(path);
      addTearDown(m.close);
      final arcs = m.db.select('SELECT level, from_ch, to_ch, summary FROM arcs');
      expect([for (final r in arcs) (r['level'], r['from_ch'], r['to_ch'], r['summary'])],
          [(1, 0, 24, 'In these chapters Mira walks on.')]);
      final asked = sent.where((b) => (((b['messages'] as List).first as Map)['content'] as String).contains('story so far'));
      expect(asked.length, 1);
      final made = ((asked.single['messages'] as List).last as Map)['content'] as String;
      expect(made, contains('Chapter 25: Chapter 24 happens.'));
      expect(made, isNot(contains('Chapter 26:')));
    });

    test("a theory checked as chapters are noted; its verdict hidden until the reader reaches it", () async {
      final path = await book(3);
      final id = addTheory(path, 'Mira is walking home.', 0);
      answer = (req, body) {
        final prompt = ((body['messages'] as List).last as Map)['content'] as String;
        if (prompt.contains('stated these theories')) {
          return reply(req, 200, chat(jsonEncode({
            'verdicts': [
              {'id': id, 'status': 'confirmed', 'ch': 3, 'why': 'She reaches her door.'},
            ],
          })));
        }
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 8));
      expect((await b.run()).phase, BuildPhase.done);
      final asked = sent.where((b) => (((b['messages'] as List).last as Map)['content'] as String).contains('stated these theories'));
      expect(asked.single.toString(), contains('#$id (stated at chapter 1): Mira is walking home.'));
      // At chapter 2 the reader cannot know yet; at 3 they can, once.
      expect(theoriesAt(path, 1).single.status, 'open');
      expect(untold(path, 1), isEmpty);
      final known = theoriesAt(path, 2).single;
      expect((known.status, known.decidedCh, known.verdict), ('confirmed', 2, 'She reaches her door.'));
      expect(untold(path, 2).single.id, id);
      markTold(path, [id]);
      expect(untold(path, 2), isEmpty);
      // As the journal keeps it: the reader's words, then the AI's verdict.
      final lines = settledLines(known);
      expect(lines.map((l) => l.mine), [true, false]);
      expect(lines.first.text, 'My theory, at chapter 1: Mira is walking home.');
      expect(lines.last.text, 'It was right: chapter 3 settled it. She reaches her door.');
    });

    test('kept up as it is read: a begun memory takes in new chapters; a book never built is left alone', () async {
      const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
      final id = (await store.addWebNovel(
        plugin,
        SourceNovel(path: 'n', name: 'Road', chapters: [
          for (var i = 0; i < 6; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
        ]),
      ))
          .id;
      for (var i = 0; i < 3; i++) {
        await store.saveChapterAt(id, 'c$i', '<p>Mira walked on. The road was long.</p>');
      }
      answer = (req, body) => reply(req, 200, chat(notesFor(body)));
      final service = MemoryService.instance
        ..reset()
        ..attach(store, router: AiRouter(pause: Duration.zero));
      addTearDown(service.reset);
      // Never built: nothing is spent on it.
      await service.keepUp(id, force: true);
      expect(sent, isEmpty);

      await service.build(id);
      expect(service.stateOf(id).value.noted, 3);
      // The app opened again, and AI chat asks first whether the book may
      // go to the AI: the memory is read all the same, not left blank (the
      // Memory page said "Not built yet" over a whole memory).
      service
        ..reset()
        ..attach(store, router: AiRouter(pause: Duration.zero));
      expect(service.maySend(id), isTrue);
      for (var i = 0; i < 200 && service.stateOf(id).value.noted == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(service.stateOf(id).value.noted, 3);
      expect(service.stateOf(id).value.exists, isTrue);
      final calls = sent.length;
      await store.saveChapterAt(id, 'c3', '<p>Mira reached the river.</p>');
      await store.saveChapterAt(id, 'c4', '<p>Mira crossed it.</p>');
      await service.keepUp(id, force: true);
      expect(service.stateOf(id).value.noted, 5);
      expect(sent.length, greaterThan(calls));
      // Not again so soon, unless forced.
      final now = sent.length;
      await store.saveChapterAt(id, 'c5', '<p>Mira rested.</p>');
      await service.keepUp(id);
      expect(sent.length, now);

      // Paused by the reader: kept up no more, even as chapters come, until
      // they go on.
      service.pause(id);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.keepUp(id, force: true);
      expect(sent.length, now);
      await service.build(id);
      expect(sent.length, greaterThan(now));
      final afterGoOn = sent.length;

      // Kept away from the AI: nothing more is sent, even forced.
      await service.setPrivate(id, true);
      expect(service.maySend(id), isFalse);
      await service.keepUp(id, force: true);
      await service.build(id);
      expect(sent.length, afterGoOn);
      await service.setPrivate(id, false);
      expect(service.maySend(id), isTrue);
    });

    test('with the app closed: the memories begun are built, others left alone', () async {
      final begun = await book(4);
      final f = File('${tmp.path}/incoming/other.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('# Chapter 1: One\n\nNobody asked for this one.');
      final other = (await store.importFile(PickedFile(path: f.path, name: 'other.md'))).id;
      await WordIndexer(store).index(other);
      final m = MemoryDb.open(begun)..setMeta('begun', '1');
      m.close();
      answer = (req, body) => reply(req, 200, chat(notesFor(body)));
      addTearDown(() => Secrets.home = null);
      final out = await runBackgroundBuild(
        libraryRoot: tmp.path,
        internalRoot: tmp.path,
        router: AiRouter(pause: Duration.zero),
      );
      expect(out['noted'], 4);
      final left = MemoryDb.open(MemoryDb.pathIn(store.bookDir(other)));
      addTearDown(left.close);
      expect(left.db.select('SELECT count(*) n FROM notes').first['n'], 0);
      expect(sent.every((b) => !b.toString().contains('Nobody asked')), isTrue);
    });

    test('built as far as the reader asks; new chapters wait for them when not built by themselves', () async {
      const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
      final id = (await store.addWebNovel(
        plugin,
        SourceNovel(path: 'n', name: 'Road', chapters: [
          for (var i = 0; i < 10; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
        ]),
      ))
          .id;
      for (var i = 0; i < 8; i++) {
        await store.saveChapterAt(id, 'c$i', '<p>Mira walked on, step $i. The road was long.</p>');
      }
      answer = (req, body) => reply(req, 200, chat(notesFor(body)));
      final service = MemoryService.instance
        ..reset()
        ..attach(store, router: AiRouter(pause: Duration.zero));
      addTearDown(service.reset);
      final path = service.pathOf(id);

      // Up to chapter 3: what it would take is counted to there.
      expect((await service.estimate(id, to: 2)).chapters, 3);
      expect((await service.estimate(id, all: true)).chapters, 8);
      await service.setBuildTo(id, 2);
      await service.build(id);
      var s = service.stateOf(id).value;
      expect((s.noted, s.leftUnder, s.buildTo, s.autoBuild), (3, 0, 2, true));
      // Kept up by itself, it still stops where the reader asked.
      final calls = sent.length;
      await service.keepUp(id, force: true);
      expect(service.stateOf(id).value.noted, 3);
      expect(sent.length, calls);

      // The next two: chapters 4 and 5, then it stops.
      expect(await service.nthLeftOf(id, 2), 4);
      expect(await service.nthLeftOf(id, 50), 7);
      await service.setBuildTo(id, await service.nthLeftOf(id, 2));
      expect(service.stateOf(id).value.leftUnder, 2);
      await service.build(id);
      s = service.stateOf(id).value;
      expect((s.noted, s.lastNoted, s.leftUnder), (5, 4, 0));

      // Not built by itself: a new chapter waits for the reader, though its
      // words are indexed for Talk's search.
      await service.setAutoBuild(id, false);
      await service.setBuildTo(id, null);
      final before = sent.length;
      await store.saveChapterAt(id, 'c8', '<p>Mira reached the river.</p>');
      await service.keepUp(id, force: true);
      s = service.stateOf(id).value;
      expect(sent.length, before);
      expect((s.noted, s.indexed, s.leftUnder, s.autoBuild), (5, 9, 4, false));

      // With the app closed, too: unless a build the reader asked for is not
      // done yet.
      addTearDown(() => Secrets.home = null);
      Future<Map<String, Object?>> closed() =>
          runBackgroundBuild(libraryRoot: tmp.path, internalRoot: tmp.path, router: AiRouter(pause: Duration.zero));
      expect((await closed())['noted'], 0);
      expect(sent.length, before);
      final m = MemoryDb.open(path)..setMeta(askedMeta, '1');
      m.close();
      expect((await closed())['noted'], 4);
      final after = MemoryDb.open(path);
      addTearDown(after.close);
      expect(after.meta(askedMeta), isNull);
      expect(after.db.select('SELECT count(*) n FROM chapters WHERE noted = 1').first['n'], 9);
    });

    test('with a key that can embed, each chapter noted also gets its vector', () async {
      final path = await book(3);
      await AiRing.instance.put(AiKey(
        id: 'e',
        provider: AiProvider.gemini,
        label: 'Gemini',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        secret: 'g',
        models: const {AiJob.embedder: 'text-embedding'},
      ));
      answer = (req, body) {
        if (req.uri.path.endsWith('/embeddings')) {
          final input = body['input'] as List;
          return reply(req, 200, {
            'data': [
              for (var i = 0; i < input.length; i++)
                {'embedding': [1.0, i.toDouble(), 0.5]},
            ],
          });
        }
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 8));
      expect((await b.run()).phase, BuildPhase.done);
      final m = MemoryDb.open(path);
      addTearDown(m.close);
      expect(m.db.select("SELECT count(*) n FROM vectors WHERE owner = 'note' AND model = 'text-embedding'").first['n'], 3);
      expect(m.db.select("SELECT count(*) n FROM vectors WHERE owner = 'event'").first['n'], 3);
    });

    test("a web novel's space freed once its memory has read the chapters; the passed-over tried again", () async {
      const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
      final id = (await store.addWebNovel(
        plugin,
        SourceNovel(path: 'n', name: 'Road', chapters: [
          for (var i = 0; i < 5; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
        ]),
      ))
          .id;
      for (var i = 0; i < 3; i++) {
        await store.saveChapterAt(id, 'c$i', '<p>Mira walked on past the willow $i.</p>');
      }
      answer = (req, body) => reply(req, 200, chat(notesFor(body)));
      final service = MemoryService.instance
        ..reset()
        ..attach(store, router: AiRouter(pause: Duration.zero));
      addTearDown(service.reset);
      expect((await service.chaptersOf(id))!.onPhone, 3);
      await service.build(id);
      final before = (await service.chaptersOf(id))!;
      expect((before.total, before.onPhone, before.noted), (5, 3, 3));
      expect(before.bytes, greaterThan(0));

      // A chapter that came after the build is not read yet: it stays.
      await store.saveChapterAt(id, 'c3', '<p>Mira slept.</p>');
      final freed = await service.freeSpace(id);
      expect(freed.chapters, 3);
      expect(freed.bytes, greaterThan(0));
      expect(store.downloadedChapters(id), {3});
      // The memory still has their words.
      final m = MemoryDb.open(MemoryDb.pathIn(store.bookDir(id)));
      expect(m.search('willow').length, 3);
      m.db.execute("UPDATE chapters SET noted = 0, note_error = 'x' WHERE ch = 1");
      m.close();
      await service.refresh(id);
      expect(service.stateOf(id).value.skipped, 1);
      await service.retrySkipped(id);
      for (var i = 0; i < 200 && (service.stateOf(id).value.skipped > 0 || service.isBuilding(id)); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await service.refresh(id);
      expect(service.stateOf(id).value.skipped, 0);
    });

    test('a broken reply is asked again with what was wrong; a chapter that will not come is passed over', () async {
      final path = await book(2);
      var calls = 0;
      answer = (req, body) {
        calls++;
        final prompt = ((body['messages'] as List).last as Map)['content'] as String;
        if (calls == 1) return reply(req, 200, chat('Here are the notes you wanted!'));
        // Chapter 1 never comes right.
        if (prompt.contains('### ch: 1') || prompt.contains('Send the whole JSON')) {
          return reply(req, 200, chat('{"chapters": []}'));
        }
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 2));
      final s = await b.run();
      expect(s.phase, BuildPhase.done);
      expect(s.noted, 1);
      expect(s.skipped, 1);
      expect(((sent[1]['messages'] as List).last as Map)['content'], contains('holds no JSON object'));
    });

    test('every key spent: it stops, and says when it can go on', () async {
      final path = await book(2);
      answer = (req, body) async {
        req.response.statusCode = 429;
        req.response.headers.set('retry-after', '3600');
        req.response.write('{"error":{"message":"quota"}}');
        await req.response.close();
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero));
      final s = await b.run();
      expect(s.phase, BuildPhase.resting);
      expect(s.until!.difference(DateTime.now()).inMinutes, closeTo(60, 2));
      expect(s.noted, 0);
    });

    test('built with its first key only, unless the reader lets the next take over', () async {
      final path = await book(2);
      await AiRing.instance.put(AiKey(
        id: 'paid',
        provider: AiProvider.inception,
        label: 'Paid',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        secret: 'p',
        models: const {AiJob.builder: 'mercury-3'},
      ));
      final keys = <String>[];
      answer = (req, body) async {
        final k = req.headers.value('authorization') ?? '';
        keys.add(k);
        if (k == 'Bearer s') {
          req.response.statusCode = 429;
          req.response.headers.set('retry-after', '600');
          req.response.write('{"error":{"message":"quota"}}');
          await req.response.close();
          return;
        }
        await reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 8));
      final s = await b.run();
      expect(s.phase, BuildPhase.resting);
      expect(s.error, 'has reached its limit for now');
      expect(keys, ['Bearer s'], reason: 'the paid key was never sent anything');
      // "Let the next key take over" (or "Go on with Paid").
      final m = MemoryDb.open(path)..setMeta(buildKeysMeta, 'only:paid');
      m.close();
      expect((await b.run()).phase, BuildPhase.done);
      expect(keys.last, 'Bearer p');
    });

    test('a reply with the first chapters only: those kept, the rest asked again, not all of it', () async {
      final path = await book(4);
      var calls = 0;
      answer = (req, body) {
        calls++;
        if (calls == 1) {
          // Notes for chapters 0 and 1 of the four sent; 2 and 3 missing.
          final all = jsonDecode(notesFor(body)) as Map;
          return reply(req, 200, chat(jsonEncode({'chapters': (all['chapters'] as List).take(2).toList()})));
        }
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 8));
      final s = await b.run();
      expect((s.phase, s.noted), (BuildPhase.done, 4));
      expect(sent.length, 2, reason: 'one call for the two that did not come');
      final second = ((sent[1]['messages'] as List).last as Map)['content'] as String;
      expect(second, isNot(contains('### ch: 0')));
      expect(second, contains('### ch: 2'));
    });

    test('a theory is held up to the story once a span, not after every batch', () async {
      final path = await book(30);
      addTheory(path, 'Mira is walking home.', 0);
      answer = (req, body) {
        final system = ((body['messages'] as List).first as Map)['content'] as String;
        final prompt = ((body['messages'] as List).last as Map)['content'] as String;
        if (system.contains('story so far')) return reply(req, 200, chat('Mira walks on.'));
        if (prompt.contains('stated these theories')) return reply(req, 200, chat('{"verdicts": []}'));
        return reply(req, 200, chat(notesFor(body)));
      };
      final b = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 400000, chapters: 2));
      expect((await b.run()).phase, BuildPhase.done);
      final checks = sent.where((b) => (((b['messages'] as List).last as Map)['content'] as String).contains('stated these theories'));
      // 15 batches; one check with the first 25 chapters' account. The 5
      // after are too few to be worth a call of their own.
      expect(checks.length, 1);
    });
  });
}
