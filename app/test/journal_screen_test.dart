// The Journal, its own section apart from Saved: a notebook (a page a book,
// with tabs to turn to one) or a list, remembered; Saved keeps to quotes
// and bookmarks.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/journal.dart';
import 'package:tomevoice_spike/journal_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/notebook.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/saved_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_journal_screen');
    store = LibraryStore(tmp);
    JournalStore.instance.reset();
    MarkStore.instance.reset();
    ListeningPrefs.reset();
  });

  tearDown(() {
    JournalStore.instance.reset();
    MarkStore.instance.reset();
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  Future<void> thought(String book, String title, int chapter, String why, {int minutes = 0}) =>
      JournalStore.instance.put(JournalEntry(
        id: '$book$chapter',
        bookId: book,
        bookTitle: title,
        created: DateTime.now().toUtc().subtract(Duration(minutes: minutes)),
        stamp: JournalStamp(at: ReadingCursor(sectionIndex: chapter - 1), chapter: chapter - 1, number: chapter),
        answers: [
          const JournalAnswer(question: 'How am I feeling?', pick: 'Good'),
          JournalAnswer(question: 'Why?', text: why),
        ],
      ));

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => store.index());
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
  }

  testWidgets('a list first; the notebook once picked, a page a book, its tabs turning to one; remembered', (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.', minutes: 5);
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    await pump(tester, JournalScreen(store: store));

    // The list is the first look (the owner's choice, 18 November).
    expect(find.byType(NotebookPages), findsNothing);
    expect(find.textContaining('Anne waited long enough.'), findsOneWidget);
    expect(find.textContaining('Dorothea deserves better.'), findsOneWidget);
    await tester.tap(find.byTooltip('Show as a notebook'));
    await tester.pumpAndSettle();
    expect(find.byType(NotebookPages), findsOneWidget);
    expect(ListeningPrefs.memory.journalNotebook, isTrue);
    // The newest book's page first.
    expect(find.text('Anne waited long enough.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Page 2: Middlemarch'));
    await tester.pumpAndSettle();
    expect(find.text('Dorothea deserves better.'), findsOneWidget);
    expect(find.text('1 thought'), findsOneWidget);
    expect(find.textContaining('Thoughts up to chapter 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Show as a list'));
    await tester.pumpAndSettle();
    expect(find.byType(NotebookPages), findsNothing);
    expect(ListeningPrefs.memory.journalNotebook, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("from a book's page: the whole journal, opened at that book; a book found by search", (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.', minutes: 5);
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    // In the list: every book's card, each the same height.
    await pump(tester, JournalScreen(store: store, bookId: 'm'));
    expect(find.textContaining('Dorothea deserves better.'), findsOneWidget);
    expect(find.textContaining('Anne waited long enough.'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('journal m'))).height,
        tester.getSize(find.byKey(const ValueKey('journal p'))).height);
    // A book found by its name.
    await tester.enterText(find.byType(TextField), 'persua');
    await tester.pumpAndSettle();
    expect(find.textContaining('Dorothea deserves better.'), findsNothing);
    expect(find.textContaining('Anne waited long enough.'), findsOneWidget);

    // As a notebook: at that book's page, with every book's tab.
    ListeningPrefs.memory.journalNotebook = true;
    await pump(tester, JournalScreen(key: UniqueKey(), store: store, bookId: 'm'));
    expect(find.byType(NotebookPages), findsOneWidget);
    expect(find.text('Dorothea deserves better.'), findsOneWidget);
    expect(find.bySemanticsLabel('Page 1: Persuasion'), findsOneWidget);
    expect(find.bySemanticsLabel('Page 2: Middlemarch'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("each book one card; a tap opens its journal, every entry whole, and the others a tap away", (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.', minutes: 5);
    await thought('m', 'Middlemarch', 5, 'Lydgate chose badly.', minutes: 2);
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    await pump(tester, JournalScreen(store: store));
    // Two books, two cards: Middlemarch's shows its latest entry alone.
    expect(find.byKey(const ValueKey('journal m')), findsOneWidget);
    expect(find.byKey(const ValueKey('journal p')), findsOneWidget);
    expect(find.textContaining('Lydgate chose badly.'), findsOneWidget);
    expect(find.textContaining('Dorothea deserves better.'), findsNothing);
    expect(find.textContaining('2 entries'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('journal m')));
    await tester.pumpAndSettle();
    expect(find.byType(BookJournalScreen), findsOneWidget);
    expect(find.text('Dorothea deserves better.'), findsOneWidget);
    expect(find.text('Lydgate chose badly.'), findsOneWidget);
    expect(find.text('Anne waited long enough.'), findsNothing);
    expect(find.byTooltip('Export as Markdown'), findsOneWidget);
    await tester.tap(find.text('All books’ journals'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('journal p')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a book's journal with nothing in it: no export", (tester) async {
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    await pump(tester, BookJournalScreen(store: store, bookId: 'm', bookTitle: 'Middlemarch'));
    expect(find.text('No journal for this book yet'), findsOneWidget);
    expect(find.byTooltip('Export as Markdown'), findsNothing);
  });

  testWidgets('empty, it says how to write', (tester) async {
    await pump(tester, JournalScreen(store: store));
    expect(find.text('No journal yet'), findsOneWidget);
    expect(find.byTooltip('Show as a list'), findsNothing);
  });

  testWidgets('Saved keeps to quotes and bookmarks: no journal, no notebook there', (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.');
    await MarkStore.instance
        .add(bookId: 'm', bookTitle: 'Middlemarch', kind: MarkKind.quote, at: ReadingCursor.zero, text: 'A quote.');
    await pump(tester, SavedScreen(store: store));
    expect(find.text('A quote.'), findsOneWidget);
    expect(find.textContaining('Journal'), findsNothing);
    expect(find.byTooltip('Show as a notebook'), findsNothing);
    expect(find.text('Dorothea deserves better.'), findsNothing);
  });

  testWidgets('Write asks which book, the last opened first, and opens its page at its place', (tester) async {
    await tester.runAsync(() async {
      final f = File('${tmp.path}/incoming/x/tide.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('# Chapter 1: Low\n\nThe tide went out.\n\n# Chapter 2: High\n\nThe tide came in.');
      await store.importFile(PickedFile(path: f.path, name: 'tide.md'));
    });
    await pump(tester, JournalScreen(store: store));
    expect(find.text('No journal yet'), findsOneWidget);

    // At least 20 rounds, and on until [until] is there (opening the book's
    // page is real file work, slower on a busy CI runner), up to 200.
    Future<void> settle([Finder? until]) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
        if (i >= 19 && (until == null || until.evaluate().isNotEmpty)) break;
      }
      // There now, perhaps only just: the page's slide in finished too.
      if (until != null) {
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    await tester.tap(find.text('Write'));
    await settle(find.text('Write about'));
    expect(find.text('Write about'), findsOneWidget);
    await tester.tap(find.text('tide').last);
    await settle(find.text('HOW AM I FEELING?'));
    expect(find.text('HOW AM I FEELING?'), findsOneWidget);
    expect(find.text('WRITING AT CHAPTER 1'), findsOneWidget);

    await tester.tap(find.text('Good'));
    await tester.tap(find.text('Done'));
    await settle();
    expect(JournalStore.instance.all.single.stamp.label, 'up to chapter 1');
    expect(find.text('No journal yet'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
