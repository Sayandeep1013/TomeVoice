// The shelf's orders and filters as they are used: from the View menu, the
// pills over the books, and a book's page; and nothing of a shut secret
// shelf's books in any of them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/book_card.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/organise_sheets.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    MarkStore.instance.reset();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    LibraryStore.secretOpen.value = false;
    tmp = Directory.systemTemp.createTempSync('tv_shelf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
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
    LibraryStore.secretOpen.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  var n = 0;
  Map<String, Object?> book(
    String title, {
    List<String> authors = const [],
    String series = '',
    double? number,
    List<String> tags = const [],
    double progress = 0,
    String shelf = 'reading',
    String source = 'epub',
    String language = 'en',
  }) =>
      {
        'id': 'b${(++n).toString().padLeft(15, '0')}',
        'title': title,
        'authors': authors,
        'source': source,
        'wordCount': 50000,
        'sourcePath': '',
        'addedAt': DateTime(2026, 1, n).toIso8601String(),
        if (progress > 0) 'openedAt': DateTime(2026, 2, n).toIso8601String(),
        'cursor': {'sectionIndex': 0, 'blockIndex': 0, 'sentenceIndex': 0},
        'progress': progress,
        'language': language,
        'category': shelf,
        'series': series,
        if (number != null) 'seriesIndex': number,
        if (tags.isNotEmpty) 'tags': tags,
      };

  /// [books] on the shelves, as the app finds them, in the list view.
  Future<void> pumpShelf(WidgetTester tester, List<Map<String, Object?>> books, {bool secret = false}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    File('${tmp.path}/prefs.json').writeAsStringSync('{"gridView": false}');
    File('${tmp.path}/library.json').writeAsStringSync(jsonEncode({
      'categories': [
        {'id': 'reading', 'name': 'Reading'},
        {'id': 'later', 'name': 'Later'},
        if (secret) {'id': 'hidden', 'name': 'Hidden', 'secret': true},
      ],
      'defaultCategory': 'reading',
      'books': books,
    }));
    await tester.pumpWidget(const SpikeApp());
    for (var i = 0; i < 40 && find.byType(BookRow).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// The titles on the shelf, top to bottom.
  List<String> shelf(WidgetTester tester) => [for (final r in tester.widgetList<BookRow>(find.byType(BookRow))) r.entry.title];

  Future<void> view(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('View and sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  /// Let real file work finish, then the frame.
  Future<void> io(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 60 && !(until?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  final books = [
    book('Persuasion', authors: ['Jane Austen'], tags: ['Classic'], progress: 1),
    book('A Clash of Kings', authors: ['George R. R. Martin'], series: 'A Song of Ice and Fire', number: 2,
        tags: ['Fantasy'], progress: 0.4),
    book('The Dispossessed', authors: ['Ursula K. Le Guin'], tags: ['Fantasy', 'Classic']),
    book('A Game of Thrones', authors: ['George R. R. Martin'], series: 'A Song of Ice and Fire', number: 1,
        tags: ['Fantasy'], progress: 1),
    book('Emma', authors: ['Austen, Jane'], source: 'pdf', language: 'fr'),
  ];

  testWidgets('the View menu sorts by author, family names first, a series in its order; and by series',
      (tester) async {
    await pumpShelf(tester, books);
    await view(tester, 'Sort: Author');
    expect(shelf(tester), ['Emma', 'Persuasion', 'The Dispossessed', 'A Game of Thrones', 'A Clash of Kings']);
    expect(ListeningPrefs.loaded!.sort, LibrarySort.author, reason: 'kept, as every order is');
    await view(tester, 'Sort: Series');
    expect(shelf(tester).take(2), ['A Game of Thrones', 'A Clash of Kings']);
    await view(tester, 'Sort: Title');
    expect(shelf(tester), ['A Clash of Kings', 'A Game of Thrones', 'Emma', 'Persuasion', 'The Dispossessed']);
    await finish(tester);
  });

  testWidgets('a filter narrows every shelf, says what it is, and Show all brings everything back', (tester) async {
    await pumpShelf(tester, books);
    await view(tester, 'Filter…');
    expect(find.text('Show only'), findsOneWidget);
    // Kinds with one choice only are not offered; these are.
    for (final pill in ['Not started', 'In progress', 'Finished', 'EPUB', 'PDF', 'English', 'French', 'Fantasy', 'Classic',
      'A Song of Ice and Fire']) {
      expect(find.widgetWithText(ChoicePill, pill), findsOneWidget, reason: pill);
    }
    await tester.tap(find.widgetWithText(ChoicePill, 'Fantasy'));
    await tester.pumpAndSettle();
    expect(find.text('3 OF 5 BOOKS'), findsOneWidget, reason: 'it says what it shows as it is chosen');
    await tester.tap(find.widgetWithText(ChoicePill, 'Finished'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(shelf(tester), ['A Game of Thrones'], reason: 'a Fantasy book, and finished');
    expect(find.byType(ActiveFilter), findsOneWidget);
    expect(find.byTooltip('Show more than Fantasy'), findsOneWidget);
    expect(find.byTooltip('Show more than Finished'), findsOneWidget);
    // Taking one away widens it again.
    await tester.tap(find.byTooltip('Show more than Finished'));
    await tester.pumpAndSettle();
    expect(shelf(tester), unorderedEquals(['A Clash of Kings', 'The Dispossessed', 'A Game of Thrones']));
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.byType(ActiveFilter), findsNothing);
    expect(shelf(tester), hasLength(5));
    await finish(tester);
  });

  testWidgets('narrowed to nothing on a shelf, it says so and offers everything', (tester) async {
    await pumpShelf(tester, [...books, book('Later Book', shelf: 'later')]);
    await view(tester, 'Filter…');
    await tester.tap(find.widgetWithText(ChoicePill, 'Fantasy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView).first, const Offset(-500, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Nothing on Later to show'), findsOneWidget);
    await tester.tap(find.text('Show all').last);
    await tester.pumpAndSettle();
    expect(shelf(tester), ['Later Book']);
    await finish(tester);
  });

  testWidgets('a shut secret shelf: its tags, series and language are never offered, nor counted', (tester) async {
    await pumpShelf(tester, [
      ...books,
      book('Cellar Notes', tags: ['Private'], series: 'Cellar Tales', number: 1, shelf: 'hidden', language: 'de'),
    ], secret: true);
    expect(shelf(tester), isNot(contains('Cellar Notes')));
    await view(tester, 'Filter…');
    expect(find.text('Private'), findsNothing);
    expect(find.text('Cellar Tales'), findsNothing);
    expect(find.text('German'), findsNothing);
    expect(find.text('ALL 5 BOOKS'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Nor found by searching for them.
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cellar');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "cellar"'.toUpperCase()), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a book's page shows its series and tags; its series opens in order, and tags are changed there",
      (tester) async {
    await pumpShelf(tester, books);
    await tester.tap(find.widgetWithText(BookRow, 'A Clash of Kings').first);
    // Until the page has tried its chapters (these books have no files): its
    // spinner would never let the frame settle.
    await io(tester,
        until: () =>
            find.byType(BookScreen).evaluate().isNotEmpty && find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(find.text('Book 2 of A Song of Ice and Fire'), findsOneWidget);
    expect(find.text('Fantasy'), findsOneWidget);

    await tester.tap(find.text('Book 2 of A Song of Ice and Fire'));
    await io(tester, until: () => find.text('2 BOOKS ON YOUR SHELVES').evaluate().isNotEmpty);
    final first = tester.getTopLeft(find.text('A Game of Thrones').last).dy;
    final second = tester.getTopLeft(find.text('A Clash of Kings').last).dy;
    expect(first, lessThan(second), reason: 'in the order of the series');
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fantasy'));
    await io(tester, until: () => find.text('Tags and series').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(ChoicePill, 'Classic'));
    await tester.enterText(find.widgetWithText(TextField, 'A new tag'), 'Lent to Sam');
    await tester.tap(find.text('Save'));
    await io(tester, until: () => find.text('Classic · Fantasy · Lent to Sam').evaluate().isNotEmpty);
    expect(find.text('Classic · Fantasy · Lent to Sam'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('selected books are tagged together', (tester) async {
    await pumpShelf(tester, books);
    await tester.longPress(find.widgetWithText(BookRow, 'Emma').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(BookRow, 'Persuasion').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Tag'));
    await io(tester, until: () => find.text('Tag 2 books').evaluate().isNotEmpty);
    await tester.tap(find.text('Classic'));
    await io(tester, until: () => find.text('1 selected').evaluate().isEmpty && find.byType(SnackBar).evaluate().isNotEmpty);
    expect(find.text('Tagged 2 books "Classic".'), findsOneWidget);
    final store = LibraryStore(tmp);
    late List<LibraryEntry> listed;
    await tester.runAsync(() async => listed = await store.list());
    expect(listed.firstWhere((e) => e.title == 'Emma').tags, ['Classic']);
    await finish(tester);
  });
}
