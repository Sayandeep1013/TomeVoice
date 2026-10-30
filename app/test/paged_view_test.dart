// Pages keep the reader's sentence, not a page number, when they are cut
// afresh: a new text size or font, or the phone turned on its side.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/paged_view.dart';
import 'package:tomevoice_spike/scheduler.dart';

void main() {
  ReadingLayout book() {
    final para = List.generate(40, (i) => 'Sentence number $i of the paragraph runs on a little.').join(' ');
    return ReadingLayout.build(ingestString(
      '# One\n\n${List.filled(20, para).join('\n\n')}',
      filename: 'book.md',
    ));
  }

  PageLook look(double size) => PageLook(
        text: TextStyle(fontSize: size, height: 1.5, color: Colors.black),
        heading: TextStyle(fontSize: size * 1.2, color: Colors.black),
        chapterHeading: TextStyle(fontSize: size * 1.5, color: Colors.brown),
        title: TextStyle(fontSize: size * 1.5, color: Colors.brown),
        label: const TextStyle(fontSize: 11, color: Colors.brown),
        status: const TextStyle(fontSize: 10, color: Colors.grey),
        accent: Colors.brown,
        sentenceWash: Colors.yellow,
        wordWash: Colors.orange,
        textScaler: TextScaler.noScaling,
        justify: false,
        indent: false,
        margin: 24,
      );

  late ReadingLayout layout;
  late PagedController controller;
  final marked = ValueNotifier<int>(-1);
  final word = ValueNotifier<WordMark>(WordMark.none);

  Future<void> pump(WidgetTester tester, PageLook look,
      {PageTurn turn = PageTurn.none, TextDirection direction = TextDirection.ltr}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PagedBook(
          layout: layout,
          look: look,
          controller: controller,
          startUnit: 0,
          marked: marked,
          word: word,
          chapterName: (c) => 'One',
          onPage: (unit, {required byHand}) {},
          onTapMiddle: () {},
          onHold: (item, offset) {},
          pictureOf: (block, size) => SizedBox.fromSize(size: size),
          turn: turn,
          textDirection: direction,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    layout = book();
    controller = PagedController();
  });

  void phone(WidgetTester tester, {bool onItsSide = false}) {
    tester.view.physicalSize = onItsSide ? const Size(2340, 1080) : const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  /// Whether [unit] is on the page (or pages) shown.
  bool showing(int unit) {
    final (first, end) = controller.range!;
    return first <= unit && unit < end;
  }

  Future<int> turnTo(WidgetTester tester, int pages) async {
    for (var i = 0; i < pages; i++) {
      controller.turn(1);
      await tester.pumpAndSettle();
    }
    return controller.range!.$1;
  }

  testWidgets('a bigger text size shows the same sentence, on a later page', (tester) async {
    phone(tester);
    await pump(tester, look(19));
    final first = await turnTo(tester, 6);
    expect(first, greaterThan(0));
    await pump(tester, look(26));
    expect(showing(first), isTrue, reason: 'the sentence that opened the page is still on it');
    // And back: still there, not drifted a page back by the two cuts.
    await pump(tester, look(19));
    expect(showing(first), isTrue);
    expect(controller.range!.$1, first);
  });

  testWidgets('turning the phone shows the same sentence', (tester) async {
    phone(tester);
    await pump(tester, look(19));
    final first = await turnTo(tester, 5);
    phone(tester, onItsSide: true);
    await tester.pumpAndSettle();
    expect(showing(first), isTrue, reason: 'on its side');
    phone(tester);
    await tester.pumpAndSettle();
    expect(showing(first), isTrue, reason: 'upright again');
  });

  testWidgets('TalkBack reads the page, and turns it by its actions', (tester) async {
    final semantics = tester.ensureSemantics();
    phone(tester);
    await pump(tester, look(19));
    // The page's own words, not only its chapter and count.
    expect(find.bySemanticsLabel(RegExp('Sentence number 0 of the paragraph')), findsWidgets);
    final before = controller.range!.$1;
    final book = tester.getSemantics(find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.customSemanticsActions?.isNotEmpty ?? false)));
    final next = CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Next page'));
    expect(book.getSemanticsData().customSemanticsActionIds, contains(next));
    book.owner!.performAction(book.id, SemanticsAction.customAction, next);
    await tester.pumpAndSettle();
    expect(controller.range!.$1, greaterThan(before));
    // The chapters either side are cut a moment after a page settles.
    await tester.pump(const Duration(milliseconds: 200));
    semantics.dispose();
  });

  group('a right-to-left book', () {
    ReadingLayout arabic() {
      final para = List.generate(40, (i) => 'هذه الجملة رقم $i من الفقرة تستمر قليلا.').join(' ');
      return ReadingLayout.build(ingestString('# واحد\n\n${List.filled(20, para).join('\n\n')}', filename: 'book.md'));
    }

    for (final turn in [PageTurn.none, PageTurn.curl]) {
      testWidgets('turns on at its left side and back at its right (${turn.name})', (tester) async {
        layout = arabic();
        phone(tester);
        await pump(tester, look(19), turn: turn, direction: TextDirection.rtl);
        final start = controller.range!.$1;
        final box = tester.getRect(find.byType(PagedBook));
        await tester.tapAt(Offset(box.left + box.width * 0.1, box.center.dy));
        await tester.pumpAndSettle();
        expect(controller.range!.$1, greaterThan(start), reason: 'the left side turns on');
        await tester.tapAt(Offset(box.right - box.width * 0.1, box.center.dy));
        await tester.pumpAndSettle();
        expect(controller.range!.$1, start, reason: 'the right side turns back');
        await tester.pump(const Duration(milliseconds: 200));
      });
    }

    testWidgets('its lines begin at the right', (tester) async {
      layout = arabic();
      phone(tester);
      await pump(tester, look(19), direction: TextDirection.rtl);
      // Pages cut by where right-to-left lines begin: every sentence is on a
      // page, none lost between two.
      var seen = controller.range!.$2;
      for (var i = 0; i < 4; i++) {
        controller.turn(1);
        await tester.pumpAndSettle();
        final (first, end) = controller.range!;
        expect(first, lessThanOrEqualTo(seen), reason: 'page ${i + 2} begins where the last ended');
        seen = end;
      }
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  testWidgets('only chapters near the page are kept cut, and one come back to is cut again', (tester) async {
    // Twelve short chapters, two or three pages each.
    final para = List.generate(30, (i) => 'Sentence number $i of the chapter runs on a little.').join(' ');
    layout = ReadingLayout.build(ingestString(
      [for (var c = 0; c < 12; c++) '# Chapter $c\n\n$para\n\n$para'].join('\n\n'),
      filename: 'book.md',
    ));
    expect(layout.chapters.length, 12);
    phone(tester);
    await pump(tester, look(19));
    var turns = 0;
    while (layout.chapterOfUnit(controller.range!.$1) < 11 && turns++ < 80) {
      controller.turn(1);
      await tester.pumpAndSettle();
      // The chapters either side are cut a moment after a page settles.
      await tester.pump(const Duration(milliseconds: 200));
      final here = layout.chapterOfUnit(controller.range!.$1);
      final kept = controller.keptChapters;
      expect(kept.every((c) => (c - here).abs() <= 2), isTrue, reason: 'in chapter $here, kept $kept');
    }
    expect(layout.chapterOfUnit(controller.range!.$1), 11, reason: 'turned through to the last chapter');
    expect(controller.keptChapters.length, lessThanOrEqualTo(5));
    // Back to the start: its pages are cut again, and show its first sentence.
    controller.showUnit(0, animate: false);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(showing(0), isTrue);
    expect(controller.keptChapters.every((c) => c <= 2), isTrue, reason: '${controller.keptChapters}');
    // And a new size still keeps the sentence the page is at.
    final first = await turnTo(tester, 3);
    phone(tester, onItsSide: true);
    await tester.pumpAndSettle();
    expect(showing(first), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a turn by hand after a new size moves the place on', (tester) async {
    phone(tester);
    await pump(tester, look(19));
    await turnTo(tester, 3);
    await pump(tester, look(24));
    final before = controller.range!;
    final next = await turnTo(tester, 1);
    expect(next, greaterThan(before.$1));
    // A new size now keeps the page turned to, not the old place.
    await pump(tester, look(19));
    expect(showing(next), isTrue);
  });
}
