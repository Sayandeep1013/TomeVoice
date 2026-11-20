// AI chat: conversations kept and found again; the tools it calls (Who's
// who, the cast, the graph's ties, theories, the journal, earlier chats),
// every one kept to each book's spoiler line; the tool loop numbering what
// it finds so answers cite it; what it keeps about the reader; the screens.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/ai/ai_chat_screen.dart';
import 'package:tomevoice_spike/ai/ai_client.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';
import 'package:tomevoice_spike/ai/ai_screen.dart';
import 'package:tomevoice_spike/ai/chat/chat_engine.dart';
import 'package:tomevoice_spike/ai/chat/chat_links.dart';
import 'package:tomevoice_spike/ai/chat/chat_store.dart';
import 'package:tomevoice_spike/ai/chat/chat_tools.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/journal.dart';
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


class _Real extends HttpOverrides {}

JournalEntry _thought(String book, String title, int chapter, String text, {String id = ''}) => JournalEntry(
      id: id.isEmpty ? '$book$chapter' : id,
      bookId: book,
      bookTitle: title,
      created: DateTime.now().toUtc(),
      stamp: JournalStamp(at: ReadingCursor(sectionIndex: chapter), chapter: chapter, number: chapter + 1),
      page: text,
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_chat');
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ChatStore.instance.reset();
    ListeningPrefs.reset();
  });

  tearDown(() {
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ChatStore.instance.reset();
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  test('chats and notes kept as files and read back; the same note kept once', () async {
    final store = ChatStore.instance;
    await store.attach(tmp);
    final c = store.start(['b1'])
      ..title = 'Who is Sunny?'
      ..messages.addAll([
        ChatMessage(mine: true, text: 'Who is Sunny?'),
        ChatMessage(
          mine: false,
          text: 'A Sleeper [S1].',
          sources: {1: const ChatSource(n: 1, label: 'ch 1', bookId: 'b1', chapter: 0, section: 0)},
          looked: ["Who's who: Sunny"],
        ),
      ]);
    await store.put(c);
    await store.remember('Likes short answers');
    await store.remember('likes short answers');
    expect(store.notes.length, 1);

    store.reset();
    await store.attach(tmp);
    final back = store.byId(c.id)!;
    expect(back.title, 'Who is Sunny?');
    expect(back.books, ['b1']);
    expect(back.messages.last.sources[1]!.bookId, 'b1');
    expect(back.messages.last.looked, ["Who's who: Sunny"]);
    expect(back.answers, 1);
    expect(store.notes.single.text, 'Likes short answers');

    await store.remove(c.id);
    expect(File('${tmp.path}/chats/${c.id}.json').existsSync(), isFalse);
  });

  test("the new tools: the cast, the graph's ties, chapter stretches, all kept to the line", () {
    final path = _memory(tmp);
    expect(bookTool(path, 1, 'cast', const {}).map((i) => i.text).join(), contains('Sunless (person)'));
    expect(bookTool(path, null, 'connections', const {'name': 'Sunny'}).map((i) => i.text).join(), contains('ally of Cassie'));
    expect(bookTool(path, null, 'connections', const {'name': 'Nobody'}).single.text, contains('Nobody and nothing'));
    // A stretch of notes stops at the line.
    final notes = bookTool(path, 1, 'chapter_notes', const {'chapter': 1, 'to_chapter': 5});
    expect(notes.where((n) => n.text.contains('past where the reader is')).length, 3);
    expect(bookTool(path, 1, 'who_is', const {'name': 'sunny'}).map((i) => i.text).join(), contains('Sleeper'));
    expect(bookTool(path, null, 'theories', const {}).single.text, contains('no theories'));
  });

  test('the journal searched within each line; earlier chats found by their words', () {
    const book = ChatBook(key: 'b1', id: 'b1', title: 'Shadow Slave', memoryPath: '', line: 1);
    final entries = [
      _thought('b1', 'Shadow Slave', 0, 'I love Sunny and his shadow.'),
      _thought('b1', 'Shadow Slave', 4, 'The Weaver twist about Sunny!'),
      _thought('b2', 'Other', 0, 'Sunny weather.'),
    ];
    final hits = journalHits(entries, {'b1': book}, 'Sunny');
    expect(hits.map((h) => h.text), ['I love Sunny and his shadow.']);
    expect(journalHits(entries, {'b1': book}, '').length, 1);

    final chat = Chat(id: 'c1', title: 'Cassie', books: const ['b1'], messages: [
      ChatMessage(mine: true, text: 'Is Cassie blind?'),
      ChatMessage(mine: false, text: 'She is a seer.'),
    ]);
    final found = pastHits([chat], const [], 'what did we say about cassie');
    expect(found.single.chatId, 'c1');
    expect(pastHits([chat], const [], 'cassie', notChat: 'c1'), isEmpty);
  });

  group('asking', () {
    // The widget binding answers every HttpClient with 400: these talk to a
    // provider on this machine, so they get a real one.
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
        models: const {AiJob.talker: 'flash', AiJob.builder: 'lite'},
      ));
    });
    tearDown(() => server.close(force: true));

    Map<String, Object?> said(String text) => {
          'choices': [
            {'message': {'role': 'assistant', 'content': text}, 'finish_reason': 'stop'},
          ],
        };

    Map<String, Object?> calls(List<(String, Map<String, Object?>)> tools) => {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  for (final (i, (name, args)) in tools.indexed)
                    {'id': 'c$i', 'type': 'function', 'function': {'name': name, 'arguments': jsonEncode(args)}},
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        };

    test("tools called on the way, each look named; the answer cites them; a note kept; the line said", () async {
      final path = _memory(tmp);
      await JournalStore.instance.put(_thought('id1', 'Shadow Slave', 0, 'I worry about Cassie.'));
      final books = {
        'b1': ChatBook(key: 'b1', id: 'id1', title: 'Shadow Slave', memoryPath: path, line: 1, here: 1),
      };
      final chat = ChatStore.instance.start(['id1'])..messages.add(ChatMessage(mine: true, text: 'How is Sunny tied to Cassie?'));
      final reply = ChatMessage(mine: false, text: '');
      chat.messages.add(reply);
      replies
        ..add(calls([
          ('connections', {'book': 'b1', 'name': 'Sunny'}),
          ('search_journal', {'query': 'Cassie'}),
          ('remember', {'note': 'Worries about Cassie', 'book': 'b1'}),
        ]))
        ..add(said('Sunny is an ally of Cassie [S90]. You worried about her [S91].'));
      final engine = ChatEngine(
        chat: chat,
        books: books,
        router: AiRouter(client: client, pause: Duration.zero),
        stream: false,
      );
      var changes = 0;
      await engine.answer(ChatProgress(reply), onChange: () => changes++);

      final system = ((sent.first['messages'] as List).first as Map)['content'] as String;
      expect(system, contains('b1: "Shadow Slave"'));
      expect(system, contains('nothing after chapter 2'));
      expect((sent.first['tools'] as List).map((t) => (t as Map)['function']['name']),
          containsAll(['who_is', 'connections', 'search_journal', 'search_past_chats', 'remember']));
      final answers = [for (final m in sent[1]['messages'] as List) if ((m as Map)['role'] == 'tool') m['content'] as String];
      expect(answers[0], contains('ally of Cassie'));
      expect(answers[1], contains('I worry about Cassie'));
      expect(answers[2], 'Kept.');
      expect(reply.looked, ['The graph around Sunny', 'Your journal, for "Cassie"', 'Kept a note about you']);
      expect(ChatStore.instance.notes.single.bookTitle, 'Shadow Slave');
      expect(reply.text, startsWith('Sunny is an ally'));
      expect(reply.error, isNull);
      expect(changes, greaterThan(0));
      // Numbers it never gave are not sources.
      expect(reply.sources, isEmpty);
    });

    test('a long chat folds its older part into a summary; a chat about one book goes in its journal', () async {
      final chat = ChatStore.instance.start(const []);
      for (var i = 0; i < 14; i++) {
        chat.messages
          ..add(ChatMessage(mine: true, text: 'Question $i'))
          ..add(ChatMessage(mine: false, text: 'Answer $i'));
      }
      replies.add(said('They talked about fourteen things.'));
      final engine = ChatEngine(chat: chat, books: const {}, router: AiRouter(client: client, pause: Duration.zero));
      expect(await engine.compact(), isTrue);
      expect(chat.summary, 'They talked about fourteen things.');
      expect(chat.summarisedAt, 28 - ChatEngine.keptVerbatim);
      // The summary call went to the Building key's model.
      expect(sent.single['model'], 'lite');
    });
  });

  testWidgets('AI chat with no key points to its settings; the gear opens AI settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AiChatScreen(store: LibraryStore(tmp))));
    await tester.pumpAndSettle();
    expect(find.text('Talk about your books'), findsOneWidget);
    await tester.tap(find.byTooltip('AI settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AiScreen), findsOneWidget);
    expect(find.text('AI settings'), findsOneWidget);
  });

  testWidgets('with a key: New chat, the chats grouped, and what the AI remembers', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await AiRing.instance.put(const AiKey(
        id: 'k1',
        provider: AiProvider.gemini,
        label: 'Gemini',
        baseUrl: 'https://example.com/v1',
        secret: 's',
        models: {AiJob.talker: 'flash'},
      ));
      final c = ChatStore.instance.start(const [])
        ..title = 'Which book next?'
        ..pinned = true
        ..messages.addAll([ChatMessage(mine: true, text: 'Which book next?'), ChatMessage(mine: false, text: 'Dune.')]);
      await ChatStore.instance.put(c);
      await ChatStore.instance.remember('Prefers short answers');
    });
    await tester.pumpWidget(MaterialApp(home: AiChatScreen(store: LibraryStore(tmp))));
    await tester.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('Which book next?'), findsOneWidget);
    expect(find.textContaining('All your books'), findsOneWidget);
    expect(find.textContaining('1 note'), findsOneWidget);
    await tester.tap(find.text('What the AI remembers about you'));
    await tester.pumpAndSettle();
    expect(find.text('Prefers short answers'), findsOneWidget);
    await tester.tap(find.byTooltip('Forget this'));
    await tester.pumpAndSettle();
    expect(ChatStore.instance.notes, isEmpty);
  });

  test('an answer as the journal keeps it: its marks as the chapters they named', () {
    final m = ChatMessage(mine: false, text: 'He is a **Sleeper** [S1]. Not yet [S2] .', sources: {
      1: const ChatSource(n: 1, label: 'ch 1', bookId: 'b', chapter: 0, section: 0),
      2: const ChatSource(n: 2, label: 'Journal'),
    });
    expect(journalText(m), 'He is a Sleeper (ch 1). Not yet.');
    expect(chatTitleFrom('  What   happened to the Weaver in the dark city, and why did it matter so much?'),
        hasLength(lessThanOrEqualTo(29)));
  });
}
