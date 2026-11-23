// The reading journal: entries written in the template's questions or on a
// blank page, each stamped with where the story had reached when Done was
// tapped (the chapter range when the voice read on meanwhile); kept in
// journal.json; shown in Saved; exported with the quotes; the questions the
// reader's own to change.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, ReadingLayout, ingestString;
import 'package:tomevoice_spike/book_card.dart' show relativeDay;
import 'package:tomevoice_spike/journal.dart';
import 'package:tomevoice_spike/notebook.dart' show savedWhen;
import 'package:tomevoice_spike/journal_page.dart';
import 'package:tomevoice_spike/journal_questions_screen.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/quote_export.dart';
import 'package:tomevoice_spike/stats.dart' show dayStartsAtHour;

void main() {
  late Directory tmp;
  final store = JournalStore.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_journal');
    store.reset();
    ListeningPrefs.reset();
  });

  tearDown(() {
    store.reset();
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  JournalStamp at(int number, {int? from}) =>
      JournalStamp(at: ReadingCursor(sectionIndex: number - 1), chapter: number - 1, number: number, fromNumber: from);

  group('the stamp', () {
    test('says how far the story had reached, or the chapters written across', () {
      expect(at(6).label, 'up to chapter 6');
      expect(at(6, from: 4).label, 'chapters 4 to 6');
      expect(at(6, from: 6).label, 'up to chapter 6');
    });

    test("is a layout's chapter, numbered as the reader numbers it", () {
      final layout = ReadingLayout.build(ingestString(
        '# Chapter 1: Alpha\n\nOne sentence here. And another.\n\n# Chapter 2: Beta\n\nTwo sentences there. Yes.',
        filename: 'book.md',
      ));
      final last = layout.units.length - 1;
      final s = stampAt(layout, last, numberOf: (c) => c + 411);
      expect(s.chapter, 1);
      expect(s.number, 412);
      expect(s.title, 'Chapter 2: Beta');
      expect(stampAt(layout, 0).number, 1);
    });
  });

  group('the store', () {
    test('keeps entries in journal.json, newest first, and reads them back', () async {
      await store.attach(tmp);
      final a = JournalEntry(
        id: 'a',
        bookId: 'book',
        bookTitle: 'Book',
        created: DateTime.utc(2026, 11, 1),
        stamp: at(3),
        answers: const [JournalAnswer(question: 'How am I feeling?', pick: 'Good'), JournalAnswer(question: 'Why?', text: 'Because.')],
      );
      final b = JournalEntry(id: 'b', bookId: 'book', bookTitle: 'Book', created: DateTime.utc(2026, 11, 2), stamp: at(9), page: 'Raw words.');
      await store.put(a);
      await store.put(b);
      expect(store.forBook('book').map((e) => e.id), ['b', 'a']);

      store.reset();
      await store.attach(tmp);
      final back = store.forBook('book');
      expect(back.map((e) => e.id), ['b', 'a']);
      expect(back.last.feeling, 'Good');
      expect(back.last.answers.last.text, 'Because.');
      expect(back.first.isPage, isTrue);
      expect(back.first.stamp.label, 'up to chapter 9');

      // Changed in place; then moved to another book (a file replaced).
      await store.put(a.copyWith(page: '', answers: const [JournalAnswer(question: 'Why?', text: 'Changed.')]));
      expect(store.forBook('book').last.answers.single.text, 'Changed.');
      await store.rebook('book', 'other', (c) => ReadingCursor(sectionIndex: c.sectionIndex + 1));
      expect(store.forBook('book'), isEmpty);
      expect(store.forBook('other').map((e) => e.stamp.at.sectionIndex), [9, 3]);
      await store.removeBook('other');
      expect(store.all, isEmpty);
    });

    test('a broken file starts empty, kept aside', () async {
      File('${tmp.path}/journal.json').writeAsStringSync('{not json');
      await store.attach(tmp);
      expect(store.all, isEmpty);
      expect(File('${tmp.path}/journal.json.broken').existsSync(), isTrue);
    });
  });

  group('the page', () {
    // The store in memory only: a file written inside a widget test's fake
    // clock never finished, and the page waited on it.
    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: home)));
      await tester.pumpAndSettle();
    }

    Widget opener(JournalStamp Function() stamp, {JournalEntry? entry}) => Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => openJournal(context, bookId: 'book', bookTitle: 'Shadow Slave', stampNow: stamp, entry: entry),
              child: const Text('Write'),
            ),
          ),
        );

    testWidgets('answered and Done: kept, stamped where the voice had read on to', (tester) async {
      var chapter = 4;
      await pump(tester, opener(() => at(chapter)));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      expect(find.text('HOW AM I FEELING?'), findsOneWidget);
      expect(find.text('WRITING AT CHAPTER 4'), findsOneWidget);

      await tester.tap(find.text('Loving it'));
      await tester.enterText(find.byType(TextField).at(1), 'Sunny fought back.');
      await tester.pump();
      // The voice read on meanwhile.
      chapter = 6;
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final e = store.forBook('book').single;
      expect(e.feeling, 'Loving it');
      expect(e.answers.map((a) => a.question), ['How am I feeling?', 'Why?']);
      expect(e.stamp.label, 'chapters 4 to 6');
      expect(e.stamp.number, 6);
      expect(find.text('In your journal, chapters 4 to 6.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a blank page; and leaving with words written asks first', (tester) async {
      await pump(tester, opener(() => at(2)));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blank page'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Just thoughts, no questions.');
      await tester.pump();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keep what you wrote?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      final e = store.forBook('book').single;
      expect(e.isPage, isTrue);
      expect(e.page, 'Just thoughts, no questions.');
      expect(e.stamp.label, 'up to chapter 2');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('nothing written: nothing kept, nothing asked', (tester) async {
      await pump(tester, opener(() => at(2)));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keep what you wrote?'), findsNothing);
      expect(store.all, isEmpty);
      expect(find.text('Write'), findsOneWidget);
    });

    testWidgets('changed later, it keeps its stamp', (tester) async {
      final old = JournalEntry(
        id: 'x',
        bookId: 'book',
        bookTitle: 'Shadow Slave',
        created: DateTime.utc(2026, 11, 1),
        stamp: at(3),
        answers: const [JournalAnswer(question: 'Why?', text: 'First words.')],
      );
      await store.put(old);
      await pump(tester, opener(() => at(99), entry: old));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      expect(find.text('First words.'), findsOneWidget);
      // The questions not answered then are there to answer now.
      expect(find.text('WHAT STOOD OUT?'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'First words.'), 'Second words.');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final e = store.forBook('book').single;
      expect(e.answers.single.text, 'Second words.');
      expect(e.stamp.label, 'up to chapter 3');
      expect(e.edited, isNotNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an entry opened and closed unchanged asks nothing; a change can be thrown away', (tester) async {
      final old = JournalEntry(
        id: 'y',
        bookId: 'book',
        bookTitle: 'Shadow Slave',
        created: DateTime.utc(2026, 11, 1),
        stamp: at(3),
        answers: const [JournalAnswer(question: 'Why?', text: 'First words.')],
      );
      await store.put(old);
      await pump(tester, opener(() => at(99), entry: old));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keep your changes?'), findsNothing);
      expect(find.text('Write'), findsOneWidget);
      // Changed, then thrown away: the entry stays as it was.
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'First words.'), 'Other words.');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Keep your changes?'), findsOneWidget);
      await tester.tap(find.text('Throw away'));
      await tester.pumpAndSettle();
      expect(store.forBook('book').single.answers.single.text, 'First words.');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  test('the export carries the journal under the book, in the order written', () {
    final md = quotesMarkdown([
      (
        title: 'Shadow Slave',
        author: 'Guiltythree',
        quotes: const [],
        journal: [
          JournalEntry(id: 'b', bookId: 's', bookTitle: 'Shadow Slave', created: DateTime.utc(2026, 11, 5, 12), stamp: at(9), page: 'A page.'),
          JournalEntry(
            id: 'a',
            bookId: 's',
            bookTitle: 'Shadow Slave',
            created: DateTime.utc(2026, 11, 1, 12),
            stamp: at(6, from: 4),
            answers: const [JournalAnswer(question: 'How am I feeling?', pick: 'Good'), JournalAnswer(question: 'Why?', text: 'It moved.')],
          ),
        ],
      ),
    ]);
    expect(md, contains('# Shadow Slave'));
    expect(md, contains('## Journal'));
    expect(md.indexOf('### Chapters 4 to 6, 2026-11-01'), lessThan(md.indexOf('### Up to chapter 9, 2026-11-05')));
    expect(md, contains('- **How am I feeling?** Good'));
    expect(md, contains('- **Why?** It moved.'));
    expect(md, contains('A page.'));
  });

  group('the questions', () {
    test("TomeVoice's own until the reader sets theirs", () {
      final p = ListeningPrefs();
      expect(journalQuestionsOf(p), defaultJournalQuestions);
      p.journalQuestions = [const JournalQuestion('Who do I trust?', picks: ['Nephis', 'Cassie']).toJson()];
      expect(journalQuestionsOf(p).single.picks, ['Nephis', 'Cassie']);
      final back = ListeningPrefs.fromJson(p.toJson());
      expect(journalQuestionsOf(back).single.text, 'Who do I trust?');
      expect(back.journalAsk, isFalse);
    });

    testWidgets('a question added in Settings is asked next time', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: JournalQuestionsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('How am I feeling?'), findsOneWidget);
      await tester.tap(find.text('Add a question'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Who do I trust least now?');
      await tester.pump();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(find.text('Who do I trust least now?'), findsOneWidget);
      final asked = journalQuestionsOf(ListeningPrefs.memory);
      expect(asked.last.text, 'Who do I trust least now?');
      expect(asked.length, defaultJournalQuestions.length + 1);

      // Removed, then TomeVoice's own again.
      await tester.tap(find.byTooltip('Remove').last);
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.journalQuestions, isNull, reason: "the defaults again: nothing of the reader's kept");
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('when it was written', () {
    test('calendar days, not 24-hour spans, and the year when it is not this one', () {
      final now = DateTime(2026, 11, 23, 8, 30);
      expect(savedWhen(DateTime(2026, 11, 23, 0, 5), now: now), 'today');
      expect(savedWhen(DateTime(2026, 11, 22, 23, 50), now: now), 'yesterday', reason: 'last night, seen this morning');
      expect(savedWhen(DateTime(2026, 11, 20, 9), now: now), '3 days ago');
      expect(savedWhen(DateTime(2026, 10, 12, 9), now: now), '12 Oct');
      expect(savedWhen(DateTime(2025, 10, 12, 9), now: now), '12 Oct 2025');
      expect(savedWhen(DateTime(2026, 11, 24, 9), now: now), 'today', reason: 'a clock behind never says "-1 days ago"');
      expect(savedWhen(DateTime.utc(2026, 11, 22, 12), now: now), isNot('today'));
    });

    test("History's day begins at 4 am, as Stats' does", () {
      // Read at 2:30 am, looked at that morning: the night before.
      final morning = DateTime(2026, 11, 23, 9);
      expect(relativeDay(DateTime(2026, 11, 23, 2, 30), now: morning, startHour: dayStartsAtHour), 'yesterday');
      expect(relativeDay(DateTime(2026, 11, 23, 4, 10), now: morning, startHour: dayStartsAtHour), 'today');
      // Still up at 3 am: what was read at 11 pm is still tonight.
      final late = DateTime(2026, 11, 24, 3);
      expect(relativeDay(DateTime(2026, 11, 23, 23), now: late, startHour: dayStartsAtHour), 'today');
      expect(relativeDay(DateTime(2026, 11, 23, 2, 30), now: late, startHour: dayStartsAtHour), 'yesterday');
      // Calendar days stay the default (journal, Saved).
      expect(relativeDay(DateTime(2026, 11, 23, 2, 30), now: morning), 'today');
      // An older one is named by its reading day.
      expect(relativeDay(DateTime(2026, 11, 13, 1), now: morning, startHour: dayStartsAtHour), '12 Nov');
    });
  });

  group('the preview', () {
    test('each answer on a line of its own, without its question', () {
      final e = JournalEntry(
        id: 'a',
        bookId: 'book',
        bookTitle: 'Book',
        created: DateTime.utc(2026, 11, 1),
        stamp: at(3),
        answers: const [
          JournalAnswer(question: 'How am I feeling?', pick: 'Good'),
          JournalAnswer(question: 'Why?', text: 'The fight.\n\nAnd the twist.'),
          JournalAnswer(question: 'What stood out?'),
        ],
      );
      expect(e.preview, 'Good\nThe fight.\nAnd the twist.');
      final page = JournalEntry(
          id: 'b', bookId: 'book', bookTitle: 'Book', created: DateTime.utc(2026, 11, 2), stamp: at(9), page: ' One.\n\n Two. ');
      expect(page.preview, 'One.\nTwo.');
    });
  });
}
