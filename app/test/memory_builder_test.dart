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
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_builder.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/word_index.dart';
import 'package:tomevoice_spike/library_store.dart';
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
        m.indexChapter(ch: ch, section: ch, title: 'C$ch', hash: 'h$ch', chunks: [TextChunk(start: _p, text: 'x')]);
      }
      g = BookGraph(m);
    });
    tearDown(() => m.close());

    int idOf(String name) => g.byName(name)!;

    test('one cast across chapters and names; facts and relations over time; events and what led to what', () {
      final made = <String, int>{};
      g.apply(
        ChapterNotes(
          chapter: 0,
          summary: 'Sunless is chosen by the Spell.',
          entities: const [
            NoteEntity(ref: 'new:Sunless', kind: 'person', name: 'Sunless', aliases: ['Sunny'], about: 'A boy of the outskirts'),
            NoteEntity(ref: 'new:The Spell', kind: 'term', name: 'The Spell'),
          ],
          events: const [
            NoteEvent(what: 'The Spell chooses Sunny', who: ['new:The Spell'], to: ['new:Sunless'], at: 2, importance: 5),
            NoteEvent(what: 'He is taken to the police', to: ['new:Sunless'], after: ['#1'], at: 4),
          ],
          facts: const [NoteFact(of: 'new:Sunless', attr: 'rank', value: 'Sleeper', at: 2)],
          threads: const [NoteThread(title: 'What is the Spell?', step: ThreadStep.raised, at: 1)],
          quotes: const [NoteQuote(text: 'Well, that is just great.', by: 'Sunny', at: 3)],
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

    test('names compare without case, accents, marks or "the"', () {
      expect(normName('The Lord-of-Shadows!'), 'lord of shadows');
      expect(normName('Éclair'), 'eclair');
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
  });
}
