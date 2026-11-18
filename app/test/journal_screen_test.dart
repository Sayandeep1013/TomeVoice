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

  testWidgets('a notebook first, a page a book, its tabs turning to one; then a list, remembered', (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.', minutes: 5);
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    await pump(tester, JournalScreen(store: store));

    expect(find.byType(NotebookPages), findsOneWidget);
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
    expect(find.text('Anne waited long enough.'), findsOneWidget);
    expect(find.text('Dorothea deserves better.'), findsOneWidget);
    expect(ListeningPrefs.memory.journalNotebook, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("one book's journal alone, from its page", (tester) async {
    await thought('m', 'Middlemarch', 3, 'Dorothea deserves better.');
    await thought('p', 'Persuasion', 7, 'Anne waited long enough.');
    ListeningPrefs.memory.journalNotebook = false;
    await pump(tester, JournalScreen(store: store, bookId: 'm'));
    expect(find.text('Dorothea deserves better.'), findsOneWidget);
    expect(find.text('Anne waited long enough.'), findsNothing);
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

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    await tester.tap(find.text('Write'));
    await settle();
    expect(find.text('Write about'), findsOneWidget);
    await tester.tap(find.text('tide').last);
    await settle();
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
