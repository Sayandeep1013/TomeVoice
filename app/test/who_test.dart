// Who or what is "…": the book's memory first; when it has nothing, the
// name the held word is probably part of ("Six Finger", "the Nine"), to
// widen, narrow or type, then asked of the AI (no spoilers) or searched on
// the web (may spoil). Offered with or without a key.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/talk/answer_pack.dart';
import 'package:tomevoice_spike/ai/talk/name_card.dart';
import 'package:tomevoice_spike/ai/talk/phrase.dart';
import 'package:tomevoice_spike/ai/talk/who_sheet.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/reader_sheets.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

String _guess(String sentence, String word) => guessPhrase(sentence, word).text;

/// A memory that knows "Six Finger" (also "Six") and "the Nine".
String _memory(Directory tmp) {
  final path = '${tmp.path}/memory.db';
  final m = MemoryDb.open(path);
  final g = BookGraph(m);
  m.indexChapter(
    ch: 0,
    section: 0,
    title: 'Chapter 1',
    hash: 'h0',
    chunks: const [TextChunk(start: MemoryPlace(chapter: 0, section: 0), text: 'Six Finger met the Nine.')],
  );
  g.apply(
    const ChapterNotes(chapter: 0, summary: 'Six Finger meets the Nine.', entities: [
      NoteEntity(ref: 'new:Six Finger', kind: 'person', name: 'Six Finger'),
      NoteEntity(ref: 'new:the Nine', kind: 'group', name: 'the Nine'),
    ], facts: [
      NoteFact(of: 'new:Six Finger', attr: 'trade', value: 'thief', at: 1),
      NoteFact(of: 'new:the Nine', attr: 'number', value: 'nine of them', at: 1),
    ]),
    const [MemoryPlace(chapter: 0, section: 0)],
    <String, int>{},
  );
  m.close();
  return path;
}

FoundCard _card(String name) => (name: name, items: [PackItem('Card: $name', '$name, as known so far.')]);

void main() {
  group('the name a held word is part of', () {
    test('capitalised words next to it join it', () {
      expect(_guess('Six Finger walked into the hall.', 'Finger'), 'Six Finger');
      expect(_guess('Six Finger walked into the hall.', 'Six'), 'Six Finger');
      expect(_guess('When I saw Six Finger, I ran.', 'Finger'), 'Six Finger');
      expect(_guess('Changing Star of the Immortal Flame clan rose.', 'Star'), 'Changing Star of the Immortal Flame');
    });

    test('"of" between two capitals, and a title with its full stop', () {
      expect(_guess('He read Lord of Mysteries today.', 'Mysteries'), 'Lord of Mysteries');
      expect(_guess('He read Lord of Mysteries today.', 'Lord'), 'Lord of Mysteries');
      expect(_guess('Mr. Darcy smiled at her.', 'Darcy'), 'Mr. Darcy');
      expect(_guess('He spoke of Sunny.', 'Sunny'), 'Sunny', reason: 'a lone "of" before is no part of it');
    });

    test('"the" just before goes with the name', () {
      expect(_guess('Then the Nine came down from the hill.', 'Nine'), 'the Nine');
      expect(_guess('The Nine stood still.', 'Nine'), 'The Nine');
    });

    test('a capital that only opens the sentence is not glued on', () {
      expect(_guess('Then Sunny left the room.', 'Sunny'), 'Sunny');
      expect(_guess('Yesterday Sunny left.', 'Sunny'), 'Sunny');
      expect(_guess('He went home. Sunny stayed.', 'Sunny'), 'Sunny');
      expect(_guess('Sunny walked on.', 'Sunny'), 'Sunny', reason: 'a name may open the sentence');
    });

    test("possessives, quotes and stops are left out; a word ending 's ends the name", () {
      expect(_guess("Sunny's sword shone.", "Sunny's"), 'Sunny');
      expect(_guess("Sunny’s sword shone.", "Sunny’s"), 'Sunny');
      expect(_guess("She feared Sunny's Shadow most.", 'Shadow'), 'Shadow');
      expect(_guess('“Six Finger,” she said.', 'Finger'), 'Six Finger');
      expect(_guess('It was Nephis.', 'Nephis'), 'Nephis');
    });

    test('a word with no capital is looked up alone, and widened by hand', () {
      final g = guessPhrase('the man with six finger came.', 'six');
      expect(g.text, 'six');
      expect(g.canDropFirst, isFalse);
      expect(g.canDropLast, isFalse);
      final wider = g.addAfter();
      expect(wider.text, 'six finger');
      expect(wider.addBefore().text, 'with six finger');
      expect(wider.dropFirst().text, 'finger');
      expect(wider.dropLast().text, 'six');
    });

    test('at the edges of the sentence nothing more is added', () {
      final first = guessPhrase('Sunny left.', 'Sunny');
      expect(first.canAddBefore, isFalse);
      expect(first.addBefore().text, 'Sunny');
      final last = guessPhrase('Sunny left', 'left');
      expect(last.canAddAfter, isFalse);
      expect(last.addAfter().text, 'left');
      expect(last.addBefore().text, 'Sunny left');
    });

    test('a word the sentence does not have is looked up as it is', () {
      final g = guessPhrase('Nothing here.', 'Weaver');
      expect(g.text, 'Weaver');
      expect(g.canAddBefore || g.canAddAfter || g.canDropFirst || g.canDropLast, isFalse);
    });

    test('the web search and the question', () {
      expect(webSearchUrl('the Nine', 'Shadow Slave'),
          'https://www.google.com/search?q=%22the+Nine%22+Shadow+Slave');
      expect(webSearchUrl('the Nine', null), 'https://www.google.com/search?q=%22the+Nine%22');
      final q = whoQuestion('Six Finger', 'Six Finger walked in.');
      expect(q, contains('"Six Finger"'));
      expect(q, contains('Six Finger walked in.'));
      expect(q, contains('nothing from later'));
    });
  });

  group('the memory', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tv_who'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    test('a name of more than one word is found whole, from any of its words or all of them', () {
      final path = _memory(tmp);
      expect(findCard(path, 'Finger', 'Six Finger walked in.', null)!.name, 'Six Finger');
      expect(findCard(path, 'six finger', 'the man with six finger came.', null)!.name, 'Six Finger');
      expect(findCard(path, 'the Nine', 'They feared the Nine.', null)!.name, 'the Nine');
      expect(findCard(path, 'Nine', 'They feared the Nine.', null)!.name, 'the Nine');
      expect(findCard(path, 'finger', 'A finger pointed.', null), isNull);
    });
  });

  group('the sheet', () {
    Future<WhoPick?> Function() open(WidgetTester tester, PhraseSpan guess,
        {bool ai = false, bool memory = false, Future<FoundCard?> Function(String)? lookUp}) {
      WhoPick? picked;
      var done = false;
      return () async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showWhoSheet(context, guess: guess, ai: ai, memory: memory, lookUp: lookUp);
                  done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return done ? picked : null;
      };
    }

    testWidgets('without the AI: a web search only, and a line on what a key would add', (tester) async {
      await open(tester, guessPhrase('Six Finger walked in.', 'Six'))();
      expect(find.text('Who or what is it?'), findsOneWidget);
      expect(find.text('This book has no memory to look in'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Six Finger'), findsOneWidget);
      expect(find.text('Search the web (may spoil)'), findsOneWidget);
      expect(find.text('Ask the AI (no spoilers)'), findsNothing);
      expect(find.textContaining('With an AI key'), findsOneWidget);
    });

    testWidgets('with the AI: both, and the pick carries the words as they stand', (tester) async {
      WhoPick? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showWhoSheet(context,
                  guess: guessPhrase('the man with six finger came.', 'six'), ai: true, memory: false),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Ask the AI (no spoilers)'), findsOneWidget);
      expect(find.text('Search the web (may spoil)'), findsOneWidget);
      expect(find.textContaining('With an AI key'), findsNothing);

      // Widen: the word after, then the word before; narrow the start again.
      await tester.tap(find.byTooltip('Add the word after'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'six finger'), findsOneWidget);
      await tester.tap(find.byTooltip('Add the word before'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'with six finger'), findsOneWidget);
      await tester.tap(find.byTooltip('Drop the first word'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'six finger'), findsOneWidget);

      await tester.tap(find.text('Ask the AI (no spoilers)'));
      await tester.pumpAndSettle();
      expect(picked?.choice, WhoChoice.ai);
      expect(picked?.phrase, 'six finger');
    });

    testWidgets('typed words are what is searched', (tester) async {
      WhoPick? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  picked = await showWhoSheet(context, guess: guessPhrase('Nine came.', 'Nine'), ai: false, memory: false),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'the Nine of Ravenheart');
      await tester.pump();
      expect(find.textContaining('"the Nine of Ravenheart"'), findsOneWidget, reason: 'the search line names them');
      await tester.tap(find.text('Search the web (may spoil)'));
      await tester.pumpAndSettle();
      expect(picked?.choice, WhoChoice.web);
      expect(picked?.phrase, 'the Nine of Ravenheart');
    });

    testWidgets('with a memory, the words as changed are looked for again, and its card offered', (tester) async {
      WhoPick? picked;
      final asked = <String>[];
      Future<FoundCard?> lookUp(String p) async {
        asked.add(p);
        return p == 'six finger' ? _card('Six Finger') : null;
      }

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showWhoSheet(context,
                  guess: guessPhrase('the man with six finger came.', 'six'), ai: false, memory: true, lookUp: lookUp),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text("The book's memory has nothing on it yet"), findsOneWidget);
      expect(find.textContaining('Open its card'), findsNothing);

      await tester.tap(find.byTooltip('Add the word after'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(asked, isEmpty, reason: 'it waits for the words to settle');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(asked, ['six finger']);
      expect(find.text('Open its card: Six Finger'), findsOneWidget);

      await tester.tap(find.text('Open its card: Six Finger'));
      await tester.pumpAndSettle();
      expect(picked?.choice, WhoChoice.card);
      expect(picked?.card?.name, 'Six Finger');
    });
  });

  group('asking from the reader', () {
    Future<void> openFrom(WidgetTester tester,
        {required Future<FoundCard?> Function(String)? lookUp,
        void Function(String)? onAsk,
        Future<bool> Function(String)? openUrl,
        String sentence = 'Six Finger walked into the hall.',
        String word = 'Six'}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNameCard(
                context,
                memoryPath: null,
                word: word,
                sentence: sentence,
                line: 0,
                searchTitle: 'Shadow Slave',
                onAsk: onAsk,
                openUrl: openUrl,
                lookUp: lookUp,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a name the memory knows opens its card at once', (tester) async {
      await openFrom(tester, lookUp: (p) async => p == 'Six' ? _card('Six Finger') : null);
      expect(find.text('Six Finger'), findsOneWidget);
      expect(find.text('Six Finger, as known so far.'), findsOneWidget);
      expect(find.text('Who or what is it?'), findsNothing);
    });

    testWidgets('the memory knows the whole name only: found by the guess', (tester) async {
      final asked = <String>[];
      await openFrom(tester, lookUp: (p) async {
        asked.add(p);
        return p == 'Six Finger' ? _card('Six Finger') : null;
      });
      expect(asked, ['Six', 'Six Finger']);
      expect(find.text('Six Finger, as known so far.'), findsOneWidget);
    });

    testWidgets('nothing in the memory: the sheet; Ask the AI asks Talk with the words and the sentence',
        (tester) async {
      String? question;
      await openFrom(tester, lookUp: (_) async => null, onAsk: (q) => question = q);
      expect(find.text('Who or what is it?'), findsOneWidget);
      await tester.tap(find.text('Ask the AI (no spoilers)'));
      await tester.pumpAndSettle();
      expect(question, whoQuestion('Six Finger', 'Six Finger walked into the hall.'));
    });

    testWidgets('no memory and no key: the web search, with the book named', (tester) async {
      final opened = <String>[];
      await openFrom(tester, lookUp: null, openUrl: (u) async {
        opened.add(u);
        return true;
      });
      expect(find.text('This book has no memory to look in'), findsOneWidget);
      expect(find.text('Ask the AI (no spoilers)'), findsNothing);
      await tester.tap(find.text('Search the web (may spoil)'));
      await tester.pumpAndSettle();
      expect(opened, [webSearchUrl('Six Finger', 'Shadow Slave')]);
    });

    testWidgets('the sentence menu offers it with no key, named by the guessed name', (tester) async {
      String? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showSentenceActions(
                context,
                sentence: 'Then the Nine came down.',
                word: 'Nine',
                web: false,
                onSaveAsAudio: () {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Explain this'), findsNothing, reason: 'that one needs the AI');
      expect(find.text('Who or what is "the Nine"?'), findsOneWidget);
      expect(find.text('Search the web for it'), findsOneWidget);
      await tester.tap(find.text('Who or what is "the Nine"?'));
      await tester.pumpAndSettle();
      expect(picked, 'who');
    });
  });

  group('in the reader', () {
    late Directory tmp;
    final opened = <String>[];

    setUp(() {
      MarkStore.instance.reset();
      ListeningPrefs.reset();
      SpeechService.resetQueue();
      opened.clear();
      tmp = Directory.systemTemp.createTempSync('tv_who_reader');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'openUrl') {
          opened.add((call.arguments as Map)['url'] as String);
          return true;
        }
        return switch (call.method) {
          'launchArgs' => <String, Object?>{},
          'listEngines' => [
              {'name': 'com.google.android.tts', 'label': 'Google TTS'},
            ],
          'listVoices' => [
              {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
            ],
          'outputDir' => tmp.path,
          'playerPosition' => 0,
          'playerEnqueue' => 0,
          _ => null,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    testWidgets('with no key and no memory, holding a word offers it and searches the web', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final l = ReadingLayout.build(specimenBook());
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: l)));
      await tester.pumpAndSettle();

      const words = 'Pack my box';
      final finder = find.textContaining(words).first;
      final para = tester.renderObject<RenderParagraph>(finder);
      final start = para.text.toPlainText().indexOf(words);
      final box = para.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + 2)).first;
      await tester.longPressAt(para.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();

      expect(find.text('Who or what is "Pack"?'), findsOneWidget);
      expect(find.text('Explain this'), findsNothing);
      await tester.tap(find.text('Who or what is "Pack"?'));
      await tester.pumpAndSettle();
      expect(find.text('Ask the AI (no spoilers)'), findsNothing);
      await tester.tap(find.text('Search the web (may spoil)'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(opened.single, startsWith('https://www.google.com/search?q=%22Pack%22'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
