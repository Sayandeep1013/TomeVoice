// Widget tests for the library, the reading surface and the listening sheet,
// plus the library store's background-isolate import path.
//
// The screens talk to the platform (voices, player, storage), so the method
// channel is mocked. These are structure and wiring checks; the audio pipeline
// is tested in packages/tomevoice_audio and ingestion in
// packages/tomevoice_document, where they run without Flutter.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_card.dart';
import 'package:tomevoice_spike/brand.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/pages_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('tomevoice_test');
    ListeningPrefs.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
            {
              'name': 'ar-language',
              'locale': 'ar',
              'quality': 500,
              'networkRequired': false,
              'installed': true,
            },
            {
              'name': 'en-gb-x-gba-local',
              'locale': 'en-GB',
              'quality': 300,
              'networkRequired': false,
              'installed': true,
            },
            {
              'name': 'en-us-x-iol-network',
              'locale': 'en-US',
              'quality': 500,
              'networkRequired': true,
              'installed': true,
            },
          ],
        'outputDir' => _tmp.path,
        'playerPosition' => 0,
        'pdfInfo' => {
            'pages': 2,
            'sizes': [612, 792, 612, 792],
          },
        'pdfRender' => '${_tmp.path}/page.jpg',
        'playerEnqueue' => 0,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpReader(WidgetTester tester, Book book) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: ReaderScreen(layout: ReadingLayout.build(book)),
    ));
    await tester.pumpAndSettle();
  }

  /// Dispose the tree and let any snack bar or scheduler timer run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// Text of every span drawn with a background wash: the spoken sentence.
  String washed(WidgetTester tester) {
    final out = StringBuffer();
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      t.textSpan?.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null) {
          out.write(span.text ?? '');
        }
        return true;
      });
    }
    return out.toString();
  }

  final chaptered = ingestString(
    'Title sheet\n\n'
    '# Chapter 1: Alpha\n\n'
    'First chapter has enough text that it counts as a real chapter to read.\n\n'
    '# Chapter 2: Beta\n\n'
    'Second chapter also has enough text that turning the page shows new sentences.',
    filename: 'novel.md',
  );

  group('library', () {
    testWidgets('an empty shelf says what to do', (tester) async {
      phone(tester);
      await tester.pumpWidget(const SpikeApp());
      // The shelf reads library.json with real file IO; each hop needs the
      // real event loop, then a pump to deliver it to the widget.
      for (var i = 0; i < 20 && find.text('Your shelf is empty').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(BrandMark), findsWidgets);
      expect(find.text('TomeVoice'), findsOneWidget);
      expect(find.text('Your shelf is empty'), findsOneWidget);
      expect(find.text('Add books'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
      await finish(tester);
    });
  });

  group('library rows', () {
    testWidgets('each book says what it is, how long, and where you are', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0; // a 360 dp wide phone
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final store = LibraryStore(_tmp);
        for (final name in ['first.txt', 'second.md']) {
          final f = File('${_tmp.path}/incoming/$name')
            ..createSync(recursive: true)
            // Different text per file: the book id is a hash of the contents.
            ..writeAsStringSync('${'A sentence with several words in it. ' * 400}\n\nThe end of $name.');
          await store.importFile(PickedFile(path: f.path, name: name));
        }
      });
      await tester.pumpWidget(const SpikeApp());
      for (var i = 0; i < 30 && find.byType(BookCover).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(BookCover), findsNWidgets(2));
      expect(find.text('TXT'), findsWidgets);
      expect(find.text('MD'), findsWidgets);
      expect(find.text('ENGLISH'), findsWidgets);
      expect(find.text('17 M'), findsWidgets, reason: '2,804 words at 165 wpm');
      expect(find.textContaining('NOT STARTED'), findsNWidgets(2));
      expect(find.text('Add books'), findsOneWidget);
      await finish(tester);
    });
  });

  group('reading surface', () {
    testWidgets('shows the book, its title and the player', (tester) async {
      await pumpReader(tester, specimenBook());

      expect(find.text('Specimen'), findsOneWidget);
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byTooltip('Speed'), findsOneWidget);
      expect(find.byTooltip('Voice'), findsOneWidget);
      expect(find.textContaining('LEFT'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('book text is a reading serif, not Ojuju', (tester) async {
      await pumpReader(tester, specimenBook());
      final text = tester.widget<Text>(find.textContaining('quick brown fox').first);
      expect(text.style?.fontFamily, 'serif');
      expect(text.style?.fontSize, greaterThanOrEqualTo(18));
      await finish(tester);
    });

    testWidgets('the sentence to be read is marked, and next moves it', (tester) async {
      await pumpReader(tester, specimenBook());
      expect(washed(tester), startsWith('The quick brown fox'));

      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Pack my box'));

      await tester.tap(find.byTooltip('Previous sentence'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('The quick brown fox'));
      await finish(tester);
    });

    testWidgets('tapping a paragraph reads from there', (tester) async {
      await pumpReader(tester, specimenBook());
      final target = find.textContaining('Tap any sentence');
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(washed(tester), anyOf(startsWith('Open the library'),
          startsWith('Playback walks'), startsWith('Tap any sentence')));
      await finish(tester);
    });

    testWidgets('opens on the first chapter, not a cover sheet', (tester) async {
      await pumpReader(tester, chaptered);
      expect(find.textContaining('Chapter 1: Alpha'), findsWidgets);
      expect(find.text('Title sheet'), findsNothing);

      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pumpAndSettle();
      expect(washed(tester), 'Chapter 2: Beta');
      await finish(tester);
    });

    testWidgets('contents lists chapters and jumps to one', (tester) async {
      await pumpReader(tester, chaptered);
      await tester.tap(find.byTooltip('Contents'));
      await tester.pumpAndSettle();

      expect(find.text('Contents'), findsOneWidget);
      await tester.tap(find.text('Chapter 2: Beta').last);
      await tester.pumpAndSettle();
      expect(washed(tester), 'Chapter 2: Beta');
      await finish(tester);
    });
  });

  group('pictures and pages', () {
    Book illustrated() {
      const text = 'The map below shows the whole of the kingdom and its seven '
          'great houses, from the Wall in the north to Dorne in the south.';
      final book = Book(
        id: 'pics',
        metadata: const BookMetadata(title: 'Pictures', language: 'en'),
        source: SourceKind.epub,
        toc: const [],
        sections: [
          Section(id: 's0', index: 0, title: 'Chapter 1', blocks: [
            makeBlock(role: BlockRole.heading, text: 'Chapter 1'),
            makeBlock(role: BlockRole.paragraph, text: text),
            makeBlock(role: BlockRole.figure, text: 'The Seven Kingdoms', image: 'OEBPS/map.png')
                .withImageSize(1200, 800),
            makeBlock(role: BlockRole.paragraph, text: text),
          ]),
        ],
      );
      return book;
    }

    testWidgets('a picture sits in the text and opens full screen', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(layout: ReadingLayout.build(illustrated()), bookDir: _tmp.path),
      ));
      await tester.pumpAndSettle();

      final picture = find.bySemanticsLabel('The Seven Kingdoms');
      expect(picture, findsOneWidget);
      await tester.ensureVisible(picture);
      await tester.tap(picture);
      await tester.pumpAndSettle();
      expect(find.byType(PictureViewer), findsOneWidget);
      await finish(tester);
    });

    testWidgets('pictures are not read aloud', (tester) async {
      final layout = ReadingLayout.build(illustrated());
      expect(layout.units.map((u) => u.text), isNot(contains('The Seven Kingdoms')));
      expect(layout.items.where((i) => i.isImage), hasLength(1));
    });

    testWidgets('a PDF can switch to its real pages', (tester) async {
      phone(tester);
      final book = ingestPdfText(id: 'p', pages: [
        'First page text is long enough to be a real page of a book, honestly.',
        'Second page text is also long enough to count as a page of a book.',
      ]);
      await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(layout: ReadingLayout.build(book), sourcePath: '${_tmp.path}/b.pdf'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show the real pages'));
      await tester.pumpAndSettle();
      expect(find.byType(PdfPagesView), findsOneWidget);
      expect(find.byTooltip('Show as text'), findsOneWidget);

      await tester.tap(find.byTooltip('Show as text'));
      await tester.pumpAndSettle();
      expect(find.byType(PdfPagesView), findsNothing);
      await finish(tester);
    });

    testWidgets('only PDFs offer the page view', (tester) async {
      await pumpReader(tester, specimenBook());
      expect(find.byTooltip('Show the real pages'), findsNothing);
      await finish(tester);
    });
  });

  group('voices', () {
    testWidgets('language beats quality, offline beats network', (tester) async {
      await pumpReader(tester, specimenBook());
      // The British offline voice, not the higher-scoring Arabic or the
      // network-only American one.
      expect(find.text('EN · UK'), findsOneWidget);
      await finish(tester);
    });
  });

  group('listening sheet', () {
    testWidgets('has speed, voice, style and fine-tune', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.tap(find.byTooltip('Listening settings'));
      await tester.pumpAndSettle();

      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('Sleep timer'), findsOneWidget);
      expect(find.text('Voice'), findsWidgets);
      expect(find.textContaining('English (UK)'), findsOneWidget);
      final sheet = find.byType(Scrollable).last;
      for (final title in ['Style', 'Text size', 'Fine-tune']) {
        await tester.scrollUntilVisible(find.text(title), 200, scrollable: sheet);
        expect(find.text(title), findsOneWidget, reason: title);
      }
      await finish(tester);
    });

    testWidgets('a sleep timer shows on the player', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.tap(find.byTooltip('Listening settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 min'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Sleep timer'))).pop();
      await tester.pumpAndSettle();
      expect(find.textContaining('SLEEP 30M'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a style changes the settings that are spoken', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.tap(find.byTooltip('Listening settings'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Dyslexia'));
      await tester.tap(find.text('Dyslexia'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.settings.wordGapMs, 150);
      expect(ListeningPrefs.memory.presetId, 'dyslexia');
      await finish(tester);
    });

    testWidgets('speed chip opens just the speed control', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.tap(find.byTooltip('Speed'));
      await tester.pumpAndSettle();

      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('Style'), findsNothing);
      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.settings.speedScale, 1.5);
      await finish(tester);
    });
  });

  group('library store', () {
    test('imports a text file off the UI isolate and loads its layout', () async {
      final store = LibraryStore(_tmp);
      final src = File('${_tmp.path}/incoming/story.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('Chapter 1\n\nOnce upon a time. The end came.\n\n'
            'Chapter 2\n\nAnother part begins here. It goes on.');
      final entry = await store.importFile(
        PickedFile(path: src.path, name: 'story.txt'),
      );
      expect(entry.title, 'story');
      expect(src.existsSync(), isFalse, reason: 'picker copy is cleaned up');

      final layout = await store.loadLayout(entry.id);
      expect(layout.chapters, hasLength(2));
      expect(layout.units.first.text, 'Chapter 1');

      await store.saveCursor(entry.id, cursorOf(layout.units[3]), 0.5,
          where: 'Chapter 2');
      final listed = (await store.list()).single;
      expect(listed.where, 'Chapter 2');
      expect(listed.progress, 0.5);

      // Re-importing keeps the place.
      src.writeAsStringSync('Chapter 1\n\nOnce upon a time. The end came.\n\n'
          'Chapter 2\n\nAnother part begins here. It goes on.');
      final again = await store.importFile(PickedFile(path: src.path, name: 'story.txt'));
      expect(again.progress, 0.5);
    });

    test('a book saved by an older build is parsed again', () async {
      final store = LibraryStore(_tmp);
      final src = File('${_tmp.path}/incoming/old.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('আমি বাড়ি যাই। তুমি কোথায় যাও?');
      final entry = await store.importFile(PickedFile(path: src.path, name: 'old.txt'));
      // Overwrite with the v1 shape: a bare Book, English, one sentence.
      final legacy = ingestString('placeholder text.');
      File('${_tmp.path}/books/${entry.id}/parsed.json')
          .writeAsStringSync(encodeReport(legacy.toJson()));

      final layout = await store.loadLayout(entry.id);
      expect(layout.book.metadata.language, 'bn');
      expect(layout.units, hasLength(2));
    });
  });
}
