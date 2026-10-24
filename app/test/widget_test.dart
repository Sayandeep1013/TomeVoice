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
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_card.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/brand.dart';
import 'package:tomevoice_spike/library_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/pages_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';
import 'package:tomevoice_spike/voices.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;
final _calls = <String>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('tomevoice_test');
    _calls.clear();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      _calls.add(call.method);
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

  /// Two books in the store, pumped as the app; returns their entries.
  Future<List<LibraryEntry>> pumpShelf(WidgetTester tester,
      {bool openFirst = false, bool secondToLater = false}) async {
    phone(tester);
    late List<LibraryEntry> made;
    await tester.runAsync(() async {
      final store = LibraryStore(_tmp);
      made = [];
      for (final name in ['alpha.txt', 'beta.txt']) {
        final f = File('${_tmp.path}/incoming/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 40}\n\n'
              'Chapter 2\n\n${'It keeps going here. ' * 40}');
        made.add(await store.importFile(PickedFile(path: f.path, name: name)));
      }
      if (secondToLater) await store.moveBooks({made.last.id}, 'later');
      if (openFirst) {
        final layout = await store.loadLayout(made.first.id);
        await store.saveCursor(made.first.id, cursorOf(layout.units[3]), 0.3, where: 'Chapter 1');
      }
    });
    await tester.pumpWidget(const SpikeApp());
    for (var i = 0; i < 40 && find.byType(BookCover).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    return made;
  }

  /// Let real file IO and isolates finish, then settle the frame.
  Future<void> settleIo(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 60 && !(until?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
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

      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Your shelf is empty'), findsOneWidget);
      expect(find.text('Add books'), findsOneWidget, reason: 'the empty shelf says how to start');
      expect(find.byTooltip('Add books'), findsOneWidget, reason: 'and the header always can');
      expect(find.text('PDF'), findsOneWidget);

      // The menu at the top left holds the rest of the app.
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(BrandMark), findsWidgets);
      expect(find.text('TomeVoice'), findsOneWidget);
      for (final place in ['History', 'Categories', 'Settings', 'About']) {
        expect(find.text(place), findsOneWidget, reason: place);
      }
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
      expect(find.text('NEW'), findsNWidgets(2), reason: 'tiles mark unopened books');
      expect(find.byType(BookTile), findsNWidgets(2), reason: 'covers are the default view');
      expect(find.byTooltip('Add books'), findsOneWidget);
      expect(find.byType(ContinueDock), findsNothing, reason: 'nothing has been opened yet');
      await finish(tester);
    });

    testWidgets('the list view spells out where you are', (tester) async {
      File('${_tmp.path}/prefs.json').writeAsStringSync('{"gridView": false}');
      await pumpShelf(tester);
      expect(find.byType(BookRow), findsNWidgets(2));
      expect(find.textContaining('NOT STARTED'), findsNWidgets(2));
      await finish(tester);
    });
  });

  group('covers', () {
    testWidgets('a wrong picture is one tap from being replaced', (tester) async {
      phone(tester);
      await tester.runAsync(() async {
        final store = LibraryStore(_tmp);
        final f = File('${_tmp.path}/incoming/book.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('A book about covers and choosing them well. The end.');
        final e = await store.importFile(PickedFile(path: f.path, name: 'book.txt'));
        final pic = File('${_tmp.path}/incoming/wrong.jpg')..writeAsBytesSync([1, 2, 3]);
        await store.setCover(e.id, CoverMode.custom, picture: PickedFile(path: pic.path, name: 'wrong.jpg'));
      });
      await tester.pumpWidget(const SpikeApp());
      await settleIo(tester, until: () => find.text('book').evaluate().isNotEmpty);

      await tester.tap(find.text('book'));
      await settleIo(tester,
          until: () =>
              find.text('Chapters').evaluate().isNotEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.tap(find.byTooltip('Book options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change cover'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a different picture'), findsOneWidget);

      await tester.tap(find.text('Choose a different picture'));
      await tester.pumpAndSettle();
      expect(_calls, contains('pickImage'));
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

    testWidgets('swiping the player up opens Now Playing; close goes back', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      expect(find.text('NOW READING'), findsOneWidget);
      // The sentence to be read, large, in the reading face.
      final now = tester.widgetList<Text>(find.textContaining('quick brown fox'))
          .where((t) => (t.style?.fontSize ?? 0) > 20);
      expect(now, isNotEmpty);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('NOW READING'), findsNothing);
      await finish(tester);
    });

    testWidgets('on its side, the player floats over the foot of the text', (tester) async {
      tester.view.physicalSize = const Size(2392, 1080);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        home: ReaderScreen(layout: ReadingLayout.build(specimenBook())),
      ));
      await tester.pumpAndSettle();
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      // One row along the foot: play low on the screen, with sleep and save
      // beside it.
      expect(tester.getCenter(find.byTooltip('Play')).dy, greaterThan(size.height * 0.7));
      expect(find.byTooltip('Sleep timer'), findsOneWidget);
      expect(find.byTooltip('Save this line'), findsOneWidget);
      // The text keeps the height, and a comfortable line on the wide screen.
      final text = tester.getRect(find.textContaining('quick brown fox').first);
      expect(text.top, lessThan(200));
      expect(text.width, lessThanOrEqualTo(720));
      await finish(tester);
    });

    testWidgets('holding a sentence offers to keep it, and keeps it', (tester) async {
      await pumpReader(tester, specimenBook());
      final before = MarkStore.instance.all.length;
      await tester.longPress(find.textContaining('Pack my box').first);
      await tester.pumpAndSettle();
      expect(find.text('Read from here'), findsOneWidget);
      expect(find.text('Save as a quote'), findsOneWidget);
      expect(find.text('Bookmark here'), findsOneWidget);
      expect(find.textContaining('Fix how'), findsOneWidget);
      await tester.tap(find.text('Save as a quote'));
      await tester.pumpAndSettle();
      // The sheet: take in the next sentence too, add a note, save.
      expect(find.text('Save a quote'), findsOneWidget);
      await tester.tap(find.byTooltip('One sentence more after'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Every pangram at once');
      await tester.tap(find.text('Save 2 sentences'));
      await tester.pumpAndSettle();
      expect(MarkStore.instance.all.length, before + 1);
      final saved = MarkStore.instance.all.first;
      expect(saved.kind, MarkKind.quote);
      expect(saved.span, 2);
      expect(saved.note, 'Every pangram at once');
      await finish(tester);
    });

    testWidgets('book text is set in the reading face', (tester) async {
      await pumpReader(tester, specimenBook());
      final text = tester.widget<Text>(find.textContaining('quick brown fox').first);
      expect(text.style?.fontFamily, 'Newsreader');
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

    testWidgets('press and hold, Read from here, reads from there; a tap does not', (tester) async {
      await pumpReader(tester, specimenBook());
      final target = find.textContaining('Press and hold any sentence');
      await tester.dragUntilVisible(target, find.byType(ScrollablePositionedList), const Offset(0, -200));
      await tester.pumpAndSettle();
      final before = washed(tester);
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      expect(washed(tester), before);
      await tester.longPress(target);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read from here'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(washed(tester), anyOf(startsWith('Open the library'),
          startsWith('Playback walks'), startsWith('Press and hold any sentence')));
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

    testWidgets('looking ahead names the chapter on screen; Play goes back to the voice', (tester) async {
      phone(tester);
      final layout = ReadingLayout.build(chaptered);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        // A web novel's numbers, and the second chapter looked ahead to.
        home: ReaderScreen(layout: layout, chapterNumberOf: (c) => c + 3221, viewSection: layout.chapters[1]),
      ));
      await tester.pumpAndSettle();

      expect(find.text('CHAPTER 3222'), findsOneWidget);
      expect(find.textContaining('CHAPTER 2: BETA  ·  3222/'), findsOneWidget);
      expect(find.text('Back to reading'), findsOneWidget);
      // The place being read has not moved.
      expect(washed(tester), 'Chapter 1: Alpha');

      await tester.tap(find.byTooltip('Play'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('CHAPTER 1: ALPHA  ·  3221/'), findsOneWidget);
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
      // The picture gets the whole screen, not the close button's corner.
      final viewer = tester.getSize(find.byType(InteractiveViewer));
      expect(viewer.width, tester.view.physicalSize.width / tester.view.devicePixelRatio);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PictureViewer), findsNothing);
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
      // A voice is named, not shown as an engine code.
      expect(find.text('English (UK) · Voice 1'), findsOneWidget);
      final sheet = find.descendant(
        of: find.byKey(const Key('reader-settings')),
        matching: find.byType(Scrollable),
      ).first;
      for (final title in ['Style', 'Fine-tune']) {
        await tester.scrollUntilVisible(find.text(title), 200, scrollable: sheet);
        expect(find.text(title), findsOneWidget, reason: title);
      }

      // How the page looks is the other tab.
      expect(find.text('Text size'), findsNothing);
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      for (final title in ['Text size', 'Font', 'Line spacing', 'Margins']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Theme'), findsNothing, reason: 'theme lives in Settings');
      await finish(tester);
    });

    testWidgets('picking a voice keeps the list in place and says something', (tester) async {
      await pumpReader(tester, specimenBook());
      await tester.tap(find.byTooltip('Listening settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change').first); // The voice; the second is for dialogue.
      await tester.pumpAndSettle();

      expect(find.text('IN USE'), findsOneWidget);
      List<String> regions() => [
            for (final t in tester.widgetList<Text>(find.byType(Text)))
              if (t.data == 'UK' || t.data == 'US') t.data!,
          ];
      expect(regions(), ['UK', 'US']);

      _calls.clear();
      await tester.tap(find.text('Voice 1').last); // the American one
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_calls, contains('synthesise'), reason: 'the chosen voice says a line');
      expect(regions(), ['UK', 'US'], reason: 'choosing does not move it to the top');
      expect(find.text('English (US) · Voice 1'), findsOneWidget, reason: 'shown as in use');
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

    test('a cover can be your own picture, plain, or automatic', () async {
      final store = LibraryStore(_tmp);
      final src = File('${_tmp.path}/incoming/c.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('A short story about covers. It ends here.');
      final entry = await store.importFile(PickedFile(path: src.path, name: 'c.txt'));
      expect(entry.coverMode, CoverMode.auto);
      expect(entry.shownCover, isNull, reason: 'a text file has no cover of its own');

      final pic = File('${_tmp.path}/incoming/me.jpg')..writeAsBytesSync([1, 2, 3]);
      var e = await store.setCover(entry.id, CoverMode.custom,
          picture: PickedFile(path: pic.path, name: 'me.jpg'));
      expect(e!.coverMode, CoverMode.custom);
      expect(File(e.shownCover!).existsSync(), isTrue);
      final first = e.shownCover;

      e = await store.setCover(entry.id, CoverMode.plain);
      expect(e!.shownCover, isNull);
      expect(e.customCover, first, reason: 'the picture is kept for later');

      final pic2 = File('${_tmp.path}/incoming/me2.png')..writeAsBytesSync([4, 5]);
      e = await store.setCover(entry.id, CoverMode.custom,
          picture: PickedFile(path: pic2.path, name: 'me2.png'));
      expect(e!.shownCover, isNot(first), reason: 'a new name so the image cache refreshes');
      expect(File(first!).existsSync(), isFalse, reason: 'the old picture is removed');

      final listed = (await store.list()).single;
      expect(listed.coverMode, CoverMode.custom);
      expect(listed.shownCover, e.shownCover);
    });

    test('re-parsing a book keeps the place the reader was at', () async {
      final store = LibraryStore(_tmp);
      final src = File('${_tmp.path}/incoming/pages.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('placeholder');
      final entry = await store.importFile(PickedFile(path: src.path, name: 'pages.txt'));
      // Store it the old way: a PDF with one section per page.
      final old = Book(
        id: entry.id,
        metadata: const BookMetadata(title: 'Old', language: 'en'),
        source: SourceKind.pdf,
        toc: const [],
        sections: [
          for (var p = 0; p < 30; p++)
            Section(id: 's$p', index: p, title: 'Page ${p + 1}', blocks: [
              makeBlock(
                role: BlockRole.paragraph,
                text: 'This is the only sentence on page number ${p + 1} of the book.',
                anchor: PageAnchor(p),
              ),
            ]),
        ],
      );
      File('${_tmp.path}/books/${entry.id}/parsed.json')
          .writeAsStringSync(encodeReport({'v': 3, 'book': old.toJson()}));
      await store.saveCursor(entry.id, const ReadingCursor(sectionIndex: 21), 0.7);

      final layout = await store.loadLayout(entry.id);
      expect(layout.chapters.length, lessThan(30), reason: 'regrouped');
      final cursor = await store.cursorFor(entry.id);
      expect(layout.units[layout.unitForCursor(cursor)].text, contains('page number 22 '));
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

  group('categories', () {
    test('a library starts with Reading and Later; books can move between them', () async {
      final store = LibraryStore(_tmp);
      final f = File('${_tmp.path}/incoming/a.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('A book that will move shelves. It ends.');
      final e = await store.importFile(PickedFile(path: f.path, name: 'a.txt'));
      var idx = await store.index();
      expect(idx.categories.map((c) => c.name), ['Reading', 'Later']);
      expect(idx.inCategory('reading').map((x) => x.id), [e.id], reason: 'new books go to the default');

      await store.moveBooks({e.id}, 'later');
      idx = await store.index();
      expect(idx.inCategory('later').map((x) => x.id), [e.id]);
      expect(idx.inCategory('reading'), isEmpty);
    });

    test('categories can be renamed, added and deleted without losing books', () async {
      final store = LibraryStore(_tmp);
      final f = File('${_tmp.path}/incoming/b.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('Another book, for the shelf tests. The end.');
      final e = await store.importFile(PickedFile(path: f.path, name: 'b.txt'));
      final fav = await store.addCategory('Favourites');
      await store.moveBooks({e.id}, fav.id);

      var idx = await store.index();
      await store.saveCategories([
        for (final c in idx.categories) c.id == 'reading' ? c.renamed('Now reading') : c,
      ]);
      idx = await store.index();
      expect(idx.categories.map((c) => c.name), ['Now reading', 'Later', 'Favourites']);

      // Deleting Favourites puts its book back on the first shelf.
      await store.saveCategories([for (final c in idx.categories) if (c.id != fav.id) c]);
      idx = await store.index();
      expect(idx.categories, hasLength(2));
      expect(idx.inCategory('reading').map((x) => x.id), [e.id]);
      expect((await store.list()).single.id, e.id, reason: 'no book is deleted with a category');
    });

    testWidgets('swiping the shelf moves to the next category', (tester) async {
      await pumpShelf(tester, secondToLater: true);
      expect(find.byType(BookCover), findsOneWidget, reason: 'one book left on Reading');
      expect(find.text('alpha'), findsOneWidget);
      await tester.fling(find.byType(PageView).first, const Offset(-500, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text('beta'), findsOneWidget, reason: 'Later holds the moved book');
      await finish(tester);
    });

    testWidgets('long-press selects books, and Move offers the categories', (tester) async {
      await pumpShelf(tester);
      await tester.longPress(find.byType(BookTile).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byType(BookTile).last);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Move to…'));
      await settleIo(tester, until: () => find.text('New category…').evaluate().isNotEmpty);
      expect(find.text('Later'), findsWidgets);
      expect(find.text('New category…'), findsOneWidget);
      await finish(tester);
    });
  });

  group('book page', () {
    testWidgets('tapping a book shows its chapters, voice and Play', (tester) async {
      await pumpShelf(tester);
      await tester.tap(find.text('alpha'));
      await settleIo(tester, until: () => find.text('Chapter 2').evaluate().isNotEmpty);

      expect(find.byType(BookScreen), findsOneWidget);
      expect(find.text('Listen'), findsOneWidget);
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('VOICE FOR THIS BOOK'), findsOneWidget);
      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);

      // A chapter opens the reader right there.
      await tester.tap(find.text('Chapter 2'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(washed(tester), 'Chapter 2');
      await finish(tester);
    });

    testWidgets('the cover flies from the shelf to the book page and back', (tester) async {
      final made = await pumpShelf(tester);
      final tag = CoverHero.tag(made.first.id);
      Finder heroes() => find.byWidgetPredicate((w) => w is Hero && w.tag == tag);

      expect(heroes(), findsOneWidget, reason: 'one cover per book on the shelf');
      await tester.tap(find.text('alpha'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // Mid-flight the cover is drawn above both screens, outside either hero.
      final flying = find.byType(BookCover).evaluate().where((e) => e.findAncestorWidgetOfExactType<Hero>() == null);
      expect(flying, isNotEmpty, reason: 'the cover is in flight');

      await settleIo(tester, until: () => find.text('Chapter 2').evaluate().isNotEmpty);
      expect(find.byType(BookScreen), findsOneWidget);
      expect(heroes(), findsOneWidget, reason: 'the book page has the one cover under that tag');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(BookScreen), findsNothing);
      expect(find.byType(BookTile), findsNWidgets(2), reason: 'the shelf is back, cover in place');
      await finish(tester);
    });

    testWidgets('a book being read waits at the bottom, one tap from playing', (tester) async {
      await pumpShelf(tester, openFirst: true);
      expect(find.byType(ContinueDock), findsOneWidget);
      expect(find.byTooltip('Continue reading aloud'), findsOneWidget);
      expect(find.textContaining('30%'), findsWidgets);
      await finish(tester);
    });
  });

  group('motion', () {
    Future<void> pumpChoice(WidgetTester tester, {required bool still}) async {
      var value = 'One';
      await tester.pumpWidget(MaterialApp(
        theme: Skin.themeFor(Palette.forest, Brightness.light),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: still),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  child: StatefulBuilder(
                    builder: (context, setState) => ChoiceRow<String>(
                      options: const [('One', 'One'), ('Two', 'Two'), ('Three', 'Three')],
                      value: value,
                      onChanged: (v) => setState(() => value = v),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
    }

    double highlight(WidgetTester tester) => tester
        .getCenter(find.descendant(of: find.byType(AnimatedPositioned), matching: find.byType(DecoratedBox)))
        .dx;

    testWidgets('a choice slides its highlight to the tapped segment', (tester) async {
      await pumpChoice(tester, still: false);
      final from = highlight(tester);
      expect(from, closeTo(tester.getCenter(find.text('One')).dx, 1));

      await tester.tap(find.text('Three'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final to = tester.getCenter(find.text('Three')).dx;
      expect(highlight(tester), allOf(greaterThan(from + 1), lessThan(to - 1)), reason: 'on its way');
      await tester.pumpAndSettle();
      expect(highlight(tester), closeTo(to, 1));
    });

    testWidgets('with animations off the highlight moves at once', (tester) async {
      await pumpChoice(tester, still: true);
      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(highlight(tester), closeTo(tester.getCenter(find.text('Two')).dx, 1));
    });
  });

  group('settings', () {
    testWidgets('has theme, reading, listening and library groups', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(_tmp))));
      await settleIo(tester);
      final list = find.byType(Scrollable).first;
      for (final title in ['Theme', 'Text size', 'Speed', 'Categories', 'About TomeVoice']) {
        await tester.scrollUntilVisible(find.text(title), 300, scrollable: list);
        expect(find.text(title), findsOneWidget, reason: title);
      }
      await finish(tester);
    });

    testWidgets('a colour theme can be picked; Black and Paper fix the brightness', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(_tmp))));
      await settleIo(tester);
      for (final name in ['Forest', 'Lavender', 'Ocean', 'Black', 'Paper']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      await tester.tap(find.text('Lavender'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.paletteId, 'lavender');
      expect(Palette.lavender.modeFor(ThemeMode.light), ThemeMode.light);
      expect(Palette.black.modeFor(ThemeMode.light), ThemeMode.dark);
      expect(Palette.paper.modeFor(ThemeMode.dark), ThemeMode.light);

      await tester.tap(find.text('Black'));
      await tester.pumpAndSettle();
      expect(find.text('Black is always dark.'), findsOneWidget);
      await finish(tester);
    });

    test('voices get names people can read', () {
      final catalog = VoiceCatalog.instance;
      catalog.voices = [
        for (final (name, locale) in const [
          ('en-us-x-iog-local', 'en-US'),
          ('en-us-x-iol-local', 'en-US'),
          ('en-us-x-iol-network', 'en-US'),
          ('en-gb-x-gba-local', 'en-GB'),
          ('en-us-language', 'en-US'),
        ])
          VoiceInfo(name: name, locale: locale, quality: 400, networkRequired: name.endsWith('network'), installed: true),
      ];
      String named(String n) => catalog.friendlyName(catalog.byName(n)!);
      expect(named('en-us-x-iog-local'), 'Voice 1');
      expect(named('en-us-x-iol-local'), 'Voice 2');
      expect(named('en-us-x-iol-network'), 'Voice 2', reason: 'the same speaker, online');
      expect(named('en-gb-x-gba-local'), 'Voice 1', reason: 'counted per region');
      expect(named('en-us-language'), 'Default voice');
      catalog.voices = const [];
    });
  });
}
