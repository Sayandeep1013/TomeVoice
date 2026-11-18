// A TXT book's own chapter rule: a web novel saved as one file, headed
// "#1 The gate" and so on, which TomeVoice reads as one long chapter. Its
// page's Chapters lets the reader say where chapters start, shows what that
// makes before anything changes, and splits the book again: the place, a
// bookmark and a quote stay with their words, and the rule is kept.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/text_chapters_sheet.dart';

const _channel = MethodChannel('tomevoice/tts');

/// A paragraph of three sentences, numbered so that no two are alike.
String _para(int n) =>
    [for (var s = 0; s < 3; s++) 'Paragraph $n sentence $s goes on with more words here.'].join(' ');

/// Four chapters headed "#1 The gate number 1"..., three paragraphs each, a
/// paragraph a line.
final _novel = [
  'The Long Road',
  for (var c = 1; c <= 4; c++) ...[
    '#$c The gate number $c',
    for (var p = 0; p < 3; p++) _para(c * 10 + p),
  ],
].join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    MarkStore.instance.reset();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    tmp = Directory.systemTemp.createTempSync('tv_text_chapters');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => const [],
        'outputDir' => tmp.path,
        _ => null,
      };
    });
  });

  tearDown(() {
    MarkStore.instance.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  Future<(LibraryStore, LibraryEntry)> imported(String name, String text) async {
    final store = LibraryStore(tmp);
    final f = File('${tmp.path}/incoming/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    return (store, await store.importFile(PickedFile(path: f.path, name: name)));
  }

  /// The sentence of [layout] that starts with [words].
  int unitOf(ReadingLayout layout, String words) => layout.units.indexWhere((u) => u.text.startsWith(words));

  group('split again', () {
    test('by lines: the place, a bookmark and a quote stay with their words, and the rule is kept', () async {
      await MarkStore.instance.attach(tmp);
      final (store, entry) = await imported('road.txt', _novel);
      final before = await store.loadLayout(entry.id);
      expect(before.chapters, hasLength(1), reason: 'TomeVoice knows no "#1" chapter line');

      // The reader is in the third chapter's text; a bookmark and a quote
      // are in the fourth's and the second's.
      final at = unitOf(before, 'Paragraph 31 sentence 1');
      await store.saveCursor(entry.id, cursorOf(before.units[at]), 0.6, where: before.chapterTitle(0));
      final mark = unitOf(before, 'Paragraph 42 sentence 2');
      await MarkStore.instance.add(
        bookId: entry.id,
        bookTitle: entry.title,
        kind: MarkKind.bookmark,
        at: cursorOf(before.units[mark]),
        text: before.units[mark].text,
        chapter: before.chapterTitle(0),
      );
      final quote = unitOf(before, 'Paragraph 20 sentence 0');
      await MarkStore.instance.add(
        bookId: entry.id,
        bookTitle: entry.title,
        kind: MarkKind.quote,
        at: cursorOf(before.units[quote]),
        text: before.units[quote].text,
        span: 2,
      );

      final after = await store.setTextChapters(entry.id, const TextChapters.lines('#'));
      expect([for (var c = 0; c < after.chapters.length; c++) after.chapterTitle(c)],
          ['#1 The gate number 1', '#2 The gate number 2', '#3 The gate number 3', '#4 The gate number 4'],
          reason: 'the title line before the first is no chapter of its own');

      final place = after.unitForCursor(await store.cursorFor(entry.id), saved: true);
      expect(after.units[place].text, startsWith('Paragraph 31 sentence 1'));
      final shown = (await store.list()).firstWhere((e) => e.id == entry.id);
      expect(shown.textChapters, const TextChapters.lines('#'));
      expect(shown.where, '#3 The gate number 3', reason: 'the place is named by its chapter now');
      expect(after.units[after.unitForCursor(shown.cursor, saved: true)].text, startsWith('Paragraph 31 sentence 1'));

      final marks = MarkStore.instance.forBook(entry.id);
      final bookmark = marks.firstWhere((m) => m.kind == MarkKind.bookmark);
      expect(after.units[unitAtCursor(after.units, bookmark.at)].text, startsWith('Paragraph 42 sentence 2'));
      expect(bookmark.at.sectionIndex, after.units[unitOf(after, 'Paragraph 42')].sectionIndex);
      expect(bookmark.chapter, '#4 The gate number 4');
      final q = marks.firstWhere((m) => m.kind == MarkKind.quote);
      expect(after.units[unitAtCursor(after.units, q.at)].text, startsWith('Paragraph 20 sentence 0'));
      expect(q.span, 2);
      expect(q.chapter, isNull, reason: 'a mark that named no chapter is not given one');

      // Kept: the library and the book's own file say so, and the book opens
      // as it was split, the place where it was.
      final raw = jsonDecode(File('${tmp.path}/library.json').readAsStringSync()) as Map;
      final kept = (raw['books'] as List).cast<Map>().firstWhere((b) => b['id'] == entry.id);
      expect(TextChapters.fromJson(kept['chapters']), const TextChapters.lines('#'));
      final again = LibraryStore(tmp);
      final reopened = await again.loadLayout(entry.id);
      expect(reopened.chapters, hasLength(4));
      expect(reopened.units[reopened.unitForCursor(await again.cursorFor(entry.id), saved: true)].text,
          startsWith('Paragraph 31 sentence 1'));

      // Back to TomeVoice's own: one chapter again, the place still there.
      final auto = await again.setTextChapters(entry.id, const TextChapters.auto());
      expect(auto.chapters, hasLength(1));
      expect(auto.units[auto.unitForCursor(await again.cursorFor(entry.id), saved: true)].text,
          startsWith('Paragraph 31 sentence 1'));
      expect((await again.list()).firstWhere((e) => e.id == entry.id).textChapters.isAuto, isTrue);
    });

    test('every so many words', () async {
      final long = [for (var p = 0; p < 30; p++) _para(p)].join('\n');
      final (store, entry) = await imported('long.txt', long);
      expect((await store.loadLayout(entry.id)).chapters, hasLength(1));
      final after = await store.setTextChapters(entry.id, const TextChapters.words(200));
      // 7 paragraphs of 30 words make a part: 7, 7, 7, 7, and 2 joined on.
      expect(after.chapters, hasLength(4));
      expect(after.chapterTitle(3), 'Part 4');
    });

    test('a book imported again keeps its chapters, and its place in them', () async {
      final (store, entry) = await imported('road.txt', _novel);
      final split = await store.setTextChapters(entry.id, const TextChapters.lines('#'));
      final at = unitOf(split, 'Paragraph 21 sentence 2');
      await store.saveCursor(entry.id, cursorOf(split.units[at]), 0.4);
      final f = File('${tmp.path}/incoming/again/road.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync(_novel);
      final again = await store.importFile(PickedFile(path: f.path, name: 'road.txt'));
      expect(again.id, entry.id);
      expect(again.textChapters, const TextChapters.lines('#'));
      final layout = await store.loadLayout(entry.id);
      expect(layout.chapters, hasLength(4));
      expect(layout.units[layout.unitForCursor(await store.cursorFor(entry.id), saved: true)].text,
          startsWith('Paragraph 21 sentence 2'));
    });
  });

  group('the page', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    /// Real file IO and isolates run until [until], the frames following.
    Future<void> settle(WidgetTester tester, bool Function() until) async {
      for (var i = 0; i < 200 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(until(), isTrue, reason: 'waited too long');
      await tester.pumpAndSettle();
    }

    testWidgets('Chapters: lines picked, what they make shown, and the book split by them', (tester) async {
      phone(tester);
      late LibraryStore store;
      late LibraryEntry entry;
      await tester.runAsync(() async => (store, entry) = await imported('road.txt', _novel));
      await tester.pumpWidget(MaterialApp(home: BookScreen(store: store, entry: entry)));
      await settle(tester, () => find.text('1 CHAPTER').evaluate().isNotEmpty);

      expect(find.text('Found by TomeVoice'), findsOneWidget);
      await tester.tap(find.text('Found by TomeVoice'));
      // The book's text is read from its file, then what it makes is shown.
      await settle(tester, () => find.text('Split the book').evaluate().isNotEmpty && find.text('Reading the book…').evaluate().isEmpty);
      FilledButton split() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Split the book'));
      expect(split().onPressed, isNull, reason: 'nothing to change yet');

      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#');
      await settle(tester, () => find.text('4 CHAPTERS').evaluate().isNotEmpty);
      expect(find.text('#1 The gate number 1'), findsOneWidget);
      expect(split().onPressed, isNotNull);

      // A line nothing starts with makes nothing, and is not applied.
      await tester.enterText(find.byType(TextField), 'Volume');
      await settle(tester, () => find.textContaining('No line starts with that').evaluate().isNotEmpty);
      expect(split().onPressed, isNull);

      // A pattern with a mistake in it is said so.
      await tester.tap(find.text('A regular expression'));
      await tester.enterText(find.byType(TextField), r'^(#\d+');
      await settle(tester, () => find.textContaining('can’t read this pattern').evaluate().isNotEmpty);
      expect(split().onPressed, isNull);

      await tester.enterText(find.byType(TextField), r'^#\d+ The gate');
      await settle(tester, () => find.text('4 CHAPTERS').evaluate().isNotEmpty);
      await tester.tap(find.text('Split the book'));
      await settle(tester, () => find.text('4 CHAPTERS').evaluate().isNotEmpty && find.byType(SnackBar).evaluate().isNotEmpty);
      expect(find.text(r'Lines matching ^#\d+ The gate'), findsOneWidget);
      expect(find.textContaining('Split into 4 chapters'), findsOneWidget);
      final kept = (await tester.runAsync(() => store.list()))!.firstWhere((e) => e.id == entry.id);
      expect(kept.textChapters, const TextChapters.lines(r'^#\d+ The gate', regex: true));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('only a TXT book has Chapters', (tester) async {
      phone(tester);
      late LibraryStore store;
      late LibraryEntry entry;
      await tester.runAsync(() async => (store, entry) = await imported('road.md', '# One\n\nText here.\n\n# Two\n\nMore.'));
      await tester.pumpWidget(MaterialApp(home: BookScreen(store: store, entry: entry)));
      await settle(tester, () => find.text('2 CHAPTERS').evaluate().isNotEmpty);
      expect(find.text('Found by TomeVoice'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('by length', (tester) async {
      phone(tester);
      final text = [for (var p = 0; p < 300; p++) _para(p)].join('\n');
      TextChapters? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showTextChapters(
              context,
              title: 'Long',
              current: const TextChapters.auto(),
              load: () async => text,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Length'));
      await tester.pumpAndSettle();
      // 9,000 words: three of 3,000, the choice it starts at.
      expect(find.text('3 CHAPTERS'), findsOneWidget);
      expect(find.text('Part 1'), findsOneWidget);
      await tester.tap(find.text('1,000'));
      await tester.pumpAndSettle();
      expect(find.text('9 CHAPTERS'), findsOneWidget);
      expect(find.text('and 4 more'), findsOneWidget);
      await tester.tap(find.text('Split the book'));
      await tester.pumpAndSettle();
      expect(picked, const TextChapters.words(1000));
      expect(textChaptersLabel(picked!), 'Every 1,000 words');
    });
  });
}
