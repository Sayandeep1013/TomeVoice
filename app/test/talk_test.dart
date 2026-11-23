// Talk: a question answered from the book's memory (the cards of the names
// asked about, the passages found, the latest chapters, open threads, the
// reader's journal), every source numbered so the answer cites chapters a
// tap looks at; the spoiler guard keeping it all to the reader's line; the
// model's tools looking further; the talk kept in the journal, and the
// journal's filter telling talks from the reader's own writing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/ai/ai_client.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_report.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/talk/answer_pack.dart';
import 'package:tomevoice_spike/ai/talk/name_card.dart';
import 'package:tomevoice_spike/ai/talk/talk_engine.dart';
import 'package:tomevoice_spike/ai/talk/talk_sheet.dart';
import 'package:tomevoice_spike/journal.dart';
import 'package:tomevoice_spike/journal_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';

/// A memory of five chapters: Sunny is a Sleeper until chapter 3, where he
/// awakens; the Weaver mystery is raised in chapter 1 and answered in 4.
String _memory(Directory tmp) {
  final path = '${tmp.path}/memory.db';
  final m = MemoryDb.open(path);
  final g = BookGraph(m);
  const texts = [
    'Sunny wakes in the cold. The Spell speaks of the Weaver.',
    'Sunny walks to the academy with Cassie.',
    'Sunny fights in the dark city and survives.',
    'Sunny awakens. He is a Sleeper no more.',
    'The Weaver is revealed to be a Daemon of Fate.',
  ];
  for (var ch = 0; ch < texts.length; ch++) {
    m.indexChapter(
      ch: ch,
      section: ch,
      title: 'Chapter ${ch + 1}',
      hash: 'h$ch',
      chunks: [TextChunk(start: MemoryPlace(chapter: ch, section: ch), text: texts[ch])],
    );
  }
  final made = <String, int>{};
  void note(int ch, ChapterNotes n) => g.apply(n, [MemoryPlace(chapter: ch, section: ch)], made);
  note(0, const ChapterNotes(chapter: 0, summary: 'Sunny is chosen by the Spell.', entities: [
    NoteEntity(ref: 'new:Sunless', kind: 'person', name: 'Sunless', aliases: ['Sunny']),
  ], facts: [
    NoteFact(of: 'new:Sunless', attr: 'rank', value: 'Sleeper', at: 1),
  ], threads: [
    NoteThread(title: 'Who is the Weaver?', step: ThreadStep.raised, what: 'The Spell names the Weaver', at: 1),
  ]));
  note(1, const ChapterNotes(chapter: 1, summary: 'Sunny meets Cassie.', entities: [
    NoteEntity(ref: 'new:Cassie', kind: 'person', name: 'Cassie'),
  ], relations: [
    NoteRelation(a: 'Sunny', rel: 'ally of', b: 'new:Cassie', at: 1),
  ]));
  note(2, const ChapterNotes(chapter: 2, summary: 'Sunny survives the dark city.', events: [
    NoteEvent(what: 'Sunny survives the dark city', who: ['Sunny'], importance: 4, at: 1),
  ]));
  note(3, const ChapterNotes(chapter: 3, summary: 'Sunny awakens.', facts: [
    NoteFact(of: 'Sunny', attr: 'rank', value: 'Awakened', at: 1),
  ]));
  note(4, const ChapterNotes(chapter: 4, summary: 'The Weaver is revealed.', threads: [
    NoteThread(title: 'Who is the Weaver?', step: ThreadStep.resolved, what: 'A Daemon of Fate', at: 1),
  ], reveals: [
    NoteReveal(what: 'The Weaver is a Daemon of Fate', at: 1),
  ]));
  m.close();
  return path;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_talk');
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ListeningPrefs.reset();
  });

  tearDown(() {
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  group('the pack', () {
    test("the journal goes only when it bears on the question, or the question is about it", () {
      const entries = [
        'ch 2, 2026-11-01: Sunny hides in the Dark Sea and I worry for him.',
        'ch 5, 2026-11-03: Nephis is cold, but kind underneath.',
        'ch 9, 2026-11-05: The weather in this book is always grim.',
      ];
      // Nothing shared: nothing of the journal sent.
      expect(journalFor('What rank is Cassie now?', entries), isEmpty);
      // A word shared with what was written, not with its "ch 2" label.
      expect(journalFor('Why does Sunny hide?', entries), [entries[0]]);
      expect(journalFor('What chapter is this?', entries), isEmpty);
      // The most shared first in rank; kept in the order written.
      expect(journalFor('Is Nephis kind to Sunny?', entries), [entries[0], entries[1]]);
      // About the reader's own writing: the latest, up to the cap.
      expect(journalFor('What did I write about the story?', entries), entries);
      expect(journalFor('Was my theory right?', entries, max: 2), [entries[1], entries[2]]);
      expect(journalFor('In my journal, what stood out?', const []), isEmpty);
    });

    test("Sunny's card as it stood at chapter 2: still a Sleeper, the Weaver still a mystery", () {
      final path = _memory(tmp);
      final items = buildPack(PackInput(path: path, question: 'What rank is Sunny now?', line: 1, here: 1));
      final text = items.map((i) => '${i.section}|${i.text}').join('\n');
      expect(text, contains('Card: Sunless|Sunless (person), also called Sunny.'));
      expect(text, contains('rank: Sleeper'));
      expect(text, isNot(contains('Awakened')));
      expect(text, contains('Sunless ally of Cassie'));
      expect(text, contains('Open threads|"Who is the Weaver?"'));
      expect(text, isNot(contains('Daemon')));
      expect(text, isNot(contains('ch 3:')), reason: 'no chapter past the line');
      expect(items.where((i) => i.section == 'Latest chapters').map((i) => i.place!.chapter), [0, 1]);
    });

    test('the story so far: the 250-chapter accounts, then only the 25-chapter ones they do not cover yet', () {
      final path = _memory(tmp);
      final m = MemoryDb.open(path);
      void arc(int level, int from, int to, String s) =>
          m.db.execute('INSERT INTO arcs(level, from_ch, to_ch, summary) VALUES (?, ?, ?, ?)', [level, from, to, s]);
      arc(3, -1, -1, 'Book one.');
      for (var from = 0; from < 275; from += 25) {
        arc(1, from, from + 24, 'Arc $from.');
      }
      arc(2, 0, 249, 'The first 250.');
      final at300 = [for (final r in storySoFar(m, 300)) '${r['summary']}'];
      expect(at300, ['Book one.', 'The first 250.', 'Arc 250.']);
      // Before the second level is made, the first level carries it.
      expect([for (final r in storySoFar(m, 60)) '${r['summary']}'], ['Book one.', 'Arc 0.', 'Arc 25.']);
      // Over the limit: the latest kept.
      expect([for (final r in storySoFar(m, 300, maxChars: 20)) '${r['summary']}'], ['Book one.', 'Arc 250.']);
      m.close();
      final pack = buildPack(PackInput(path: path, question: 'What happened?', here: 300))
          .where((i) => i.section == 'The story so far')
          .map((i) => i.text);
      expect(pack.where((t) => t.contains('Arc 0.')), isEmpty);
      expect(pack.where((t) => t.contains('The first 250.')).length, 1);
    });

    test('with the guard off, all it remembers: awakened, and the Weaver answered', () {
      final path = _memory(tmp);
      final text = buildPack(PackInput(path: path, question: 'Who is Sunny and what is the Weaver?', here: 4))
          .map((i) => i.text)
          .join('\n');
      expect(text, contains('rank: Awakened'));
      expect(text, isNot(contains('"Who is the Weaver?" (raised')), reason: 'a resolved thread is not open');
      expect(text, contains('Daemon of Fate'));
    });

    test('a held word finds its card by any of its names, as it stood at the line', () {
      final path = _memory(tmp);
      final card = findCard(path, 'Sunny', 'Sunny walks to the academy with Cassie.', 1)!;
      expect(card.name, 'Sunless');
      expect(card.items.map((i) => i.text).join(' | '), contains('rank: Sleeper'));
      expect(findCard(path, 'Sunny', '', null)!.items.map((i) => i.text).join(' | '), contains('rank: Awakened'));
      expect(findCard(path, 'academy', 'Sunny walks to the academy.', null), isNull);
      // "Sunny's" is Sunny.
      expect(findCard(path, "Sunny's", "Sunny's sword shone.", null)!.name, 'Sunless');
      expect(bareName('Oren’s'), 'Oren');
    });

    test('an answer as it is said aloud: no marks, in pieces of a sentence or a few', () {
      expect(spokenAnswer('He is **still** a Sleeper [S2]. He walked on [S3, S5].'), 'He is still a Sleeper. He walked on.');
      final long = List.generate(12, (i) => 'Sentence $i is a fairly ordinary sentence of the answer.').join(' ');
      final pieces = spokenPieces(long);
      expect(pieces.length, greaterThan(2));
      expect(pieces.every((p) => p.length <= 240), isTrue);
      expect(pieces.join(' '), long);
    });

    test('citation marks in the forms models write, ranges spelled out', () {
      final en = String.fromCharCode(0x2013);
      List<int>? nums(String t) {
        final m = citeMarks.allMatches('x $t y').toList();
        return m.length == 1 && m.single.group(0) == t ? citeNumbers(t) : null;
      }

      expect(nums('[S3, S5]'), [3, 5]);
      expect(nums('[S118${en}S119]'), [118, 119]);
      expect(nums('[S118-121]'), [118, 119, 120, 121]);
      expect(nums('[S4 to S6]'), [4, 5, 6]);
      expect(nums('[S1; S2]'), [1, 2]);
      expect(nums('[ S1 ]'), [1]);
      expect(nums('[s7]'), [7]);
      expect(nums('${String.fromCharCode(0x3010)}S9${String.fromCharCode(0x3011)}'), [9]);
      expect(nums('[S1-S99]'), [1, 99], reason: 'a range over 30 keeps only its ends');
      for (final t in ['[Sx]', '[1]', '[Sunny]', '[S3 dogs]']) {
        expect(citeMarks.hasMatch(t), isFalse, reason: t);
      }
      expect(spokenAnswer('He left [S118${en}S119].'), 'He left.');
    });

    test("the tools keep to the line too", () {
      final path = _memory(tmp);
      expect(runTool(path, 'read_chapter', {'chapter': 5}, 1).single.text, contains('past where the reader is'));
      expect(runTool(path, 'search_text', {'query': 'Daemon'}, 1), isEmpty);
      expect(runTool(path, 'search_text', {'query': 'Daemon'}, null).single.place!.chapter, 4);
      expect(runTool(path, 'card', {'name': 'sunny'}, 1).map((i) => i.text).join(), contains('Sleeper'));
      expect(runTool(path, 'thread', {'name': 'weaver'}, null).length, 2);
    });
  });

  group('asking', () {
    // The widget tests' binding answers every HttpClient with 400: these
    // talk to a provider on this machine, so they get a real one.
    late AiClient client;
    late HttpServer server;
    late List<Map<String, Object?>> sent;
    late List<Object> replies;

    setUp(() async {
      client = HttpOverrides.runWithHttpOverrides(() => AiClient(http: HttpClient()), _Real());
      sent = [];
      replies = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        sent.add((jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, Object?>());
        final r = replies.removeAt(0);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(r));
        await req.response.close();
      });
      await AiRing.instance.put(AiKey(
        id: 't',
        provider: AiProvider.gemini,
        label: 'Gemini',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        secret: 's',
        models: const {AiJob.talker: 'flash'},
      ));
    });
    tearDown(() => server.close(force: true));

    Map<String, Object?> said(String text) => {
          'choices': [
            {'message': {'role': 'assistant', 'content': text}, 'finish_reason': 'stop'},
          ],
        };

    Map<String, Object?> calls(String name, Map<String, Object?> args) => {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  {'id': 'c1', 'type': 'function', 'function': {'name': name, 'arguments': jsonEncode(args)}},
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        };

    test('the material numbered, the guard said, the answer citing it; a tool used on the way', () async {
      final path = _memory(tmp);
      replies
        ..add(calls('search_text', {'query': 'academy'}))
        ..add(said('Sunny is still a Sleeper [S2]. He walked to the academy [S99, S3].'));
      final engine = TalkEngine(memoryPath: path, bookTitle: 'Shadow Slave', router: AiRouter(client: client, pause: Duration.zero));
      final a = await engine.ask('What rank is Sunny?', line: 1, here: 1, journal: const ['up to chapter 1: I love Sunny.']);
      final first = sent.first;
      final system = ((first['messages'] as List).first as Map)['content'] as String;
      expect(system, contains('read up to chapter 2'));
      expect(system, contains('Do not use anything you may know of this book from elsewhere'));
      final user = ((first['messages'] as List).last as Map)['content'] as String;
      expect(user, contains('[S1] Sunless (person)'));
      expect(user, contains("## The reader's journal"));
      expect(user, contains('The reader asks: What rank is Sunny?'));
      expect((first['tools'] as List).length, talkTools.length);
      // The tool's answer went back numbered on from the pack.
      final toolAnswer = (sent[1]['messages'] as List).last as Map;
      expect(toolAnswer['role'], 'tool');
      expect(toolAnswer['content'], contains('ch 2: Sunny walks to the «academy»'));
      // Made-up numbers are dropped; real ones name their chapters.
      expect(a.cited.map((s) => s.n), [2, 3]);
      expect(a.cited.first.place, isNotNull);
    });

    testWidgets('the sheet: an answer with chapter chips that look there; the talk kept in the journal', (tester) async {
      final path = _memory(tmp);
      MemoryPlace? looked;
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TalkSheet(
            bookId: 'b',
            bookTitle: 'Shadow Slave',
            memoryPath: path,
            stampNow: () => const JournalStamp(at: ReadingCursor(sectionIndex: 1), chapter: 1, number: 2),
            line: () => null,
            here: () => 1,
            passage: () => 'Sunny walks to the academy with Cassie.',
            onLook: (p) => looked = p,
            engine: _Said(path, 'He met Cassie on the way [S7].', {
              7: const TalkSource(7, 'ch 2', MemoryPlace(chapter: 1, section: 1)),
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('What just happened?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Who did Sunny meet?');
      await tester.tap(find.byTooltip('Ask'));
      for (var i = 0; i < 100 && find.textContaining('He met Cassie', findRichText: true).evaluate().isEmpty && find.textContaining('could not').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.textContaining('could not'), findsNothing);
      expect(find.textContaining('He met Cassie', findRichText: true), findsOneWidget);
      // The chip names the chapter its source is in.
      expect(find.text('ch 2'), findsOneWidget);
      await tester.tap(find.text('ch 2').first);
      await tester.pumpAndSettle();
      expect(looked?.chapter, 1);

      // Closed: kept in the journal, its marks kept as chapters.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      final kept = JournalStore.instance.all.single;
      expect(kept.isTalk, isTrue);
      expect(kept.talk.first.text, 'Who did Sunny meet?');
      expect(kept.talk.last.text, 'He met Cassie on the way (ch 2).');
      expect(kept.stamp.label, 'up to chapter 2');
    });

    testWidgets('an answer reported from Talk: why asked, what is sent said, the answer hidden and not kept', (tester) async {
      final path = _memory(tmp);
      Map<String, String>? sent;
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TalkSheet(
            bookId: 'b',
            bookTitle: 'Shadow Slave',
            memoryPath: path,
            stampNow: () => const JournalStamp(at: ReadingCursor(sectionIndex: 1), chapter: 1, number: 2),
            line: () => null,
            here: () => 1,
            passage: () => '',
            onLook: (_) {},
            engine: _Said(path, 'He met Cassie on the way [S7].', {
              7: const TalkSource(7, 'ch 2', MemoryPlace(chapter: 1, section: 1)),
            }),
            sendReport: (r) async {
              sent = r;
              return true;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('ANSWERS BY AI, WHICH CAN BE WRONG'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Who did Sunny meet?');
      await tester.tap(find.byTooltip('Ask'));
      for (var i = 0; i < 100 && find.text('Report').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(find.text('Report this answer'), findsOneWidget);
      expect(find.textContaining('Nothing else from your book or your journal'), findsOneWidget);
      // No reason yet: nothing to send.
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send report')).onPressed, isNull);
      await tester.tap(find.text('Hateful or harassing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send report'));
      for (var i = 0; i < 40 && sent == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(sent!['reason'], 'Hateful or harassing');
      expect(sent!['question'], 'Who did Sunny meet?');
      expect(sent!['answer'], contains('He met Cassie'));
      expect(sent!['where'], 'Talk');
      expect(find.text('You reported this answer, and it is hidden.'), findsOneWidget);
      expect(find.textContaining('He met Cassie', findRichText: true), findsNothing);

      // Closed: a talk with no answer left is not kept.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(JournalStore.instance.all, isEmpty);
    });

    testWidgets('an empty answer is said, not left remembering for ever', (tester) async {
      final path = _memory(tmp);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TalkSheet(
            bookId: 'b',
            bookTitle: 'Shadow Slave',
            memoryPath: path,
            stampNow: () => const JournalStamp(at: ReadingCursor(sectionIndex: 1), chapter: 1, number: 2),
            line: () => null,
            here: () => 1,
            passage: () => '',
            onLook: (_) {},
            engine: _Said(path, '', const {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Who is Sunny?');
      await tester.tap(find.byTooltip('Ask'));
      for (var i = 0; i < 100 && find.textContaining('no answer').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.textContaining('The AI sent back no answer'), findsOneWidget);
      expect(find.text('Remembering…'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    });

    test('an answer held back: sexual words beside a child, in one sentence; the book\'s darkness is not', () {
      expect(aiAnswerHeld('In chapter 3 the child is described in sexual terms.'), isTrue);
      expect(aiAnswerHeld('A 15-year-old and porn.'), isTrue);
      expect(aiAnswerHeld('The children were starving after the siege. Later, two adults had sex.'), isFalse);
      expect(aiAnswerHeld('Sunny is a Sleeper; Nephis is cold but kind.'), isFalse);
      expect(aiSafetyRule, contains('under 18'));
    });

    testWidgets("the journal's filter: all, the reader's own writing, or the talks", (tester) async {
      final store = LibraryStore(tmp);
      await tester.runAsync(store.index);
      Future<void> put(String id, {List<TalkLine> talk = const [], String page = ''}) => JournalStore.instance.put(JournalEntry(
            id: id,
            bookId: 'gone',
            bookTitle: 'A book',
            created: DateTime.now().toUtc(),
            stamp: const JournalStamp(at: ReadingCursor(sectionIndex: 0), chapter: 0, number: 1),
            page: page,
            talk: talk,
          ));
      await put('a', page: 'My own words about it.');
      await put('b', talk: const [TalkLine(mine: true, text: 'Who is she?'), TalkLine(mine: false, text: 'The heroine.')]);
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: BookJournalScreen(store: store, bookId: 'gone', bookTitle: 'A book')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.text('My own words about it.'), findsOneWidget);
      expect(find.text('The heroine.'), findsOneWidget);
      await tester.tap(find.text('Talks'));
      await tester.pumpAndSettle();
      expect(find.text('My own words about it.'), findsNothing);
      expect(find.text('The heroine.'), findsOneWidget);
      await tester.tap(find.text('My writing'));
      await tester.pumpAndSettle();
      expect(find.text('My own words about it.'), findsOneWidget);
      expect(find.text('The heroine.'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

/// No overrides: HttpClient as it is outside tests.
class _Real extends HttpOverrides {}

/// A talk that answers at once with [text], citing [sources].
class _Said extends TalkEngine {
  _Said(String path, this.text, this.cites) : super(memoryPath: path, bookTitle: 'Shadow Slave');

  final String text;
  final Map<int, TalkSource> cites;

  @override
  Future<TalkAnswer> ask(
    String question, {
    int? line,
    int? here,
    String passage = '',
    List<String> journal = const [],
    void Function(String piece)? onText,
    bool theory = false,
  }) async =>
      TalkAnswer(text, cites);
}
