// Pages keep the reader's sentence, not a page number, when they are cut
// afresh: a new text size or font, or the phone turned on its side.

import 'package:flutter/material.dart';
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

  Future<void> pump(WidgetTester tester, PageLook look) async {
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
          turn: PageTurn.none,
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
