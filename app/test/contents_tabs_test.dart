// A book's Contents with parts: a coloured tab for each down the side,
// which opens its part, the one in view standing out; and the part's
// divider marked in its tab's colour.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/chapter_finder.dart';

void main() {
  final titles = <String>[];
  for (var p = 1; p <= 4; p++) {
    titles.add('Part $p: Of the ${['Shore', 'Tower', 'Sea', 'Gate'][p - 1]}');
    for (var c = 0; c < 8; c++) {
      titles.add('Chapter ${titles.length}');
    }
  }

  Future<void> pump(WidgetTester tester, {bool parts = true, List<String>? of}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChapterFinder(titles: of ?? titles, current: 1, parts: parts, numberWidth: 40)),
    ));
    await tester.pumpAndSettle();
  }

  void selected(WidgetTester tester, String label, bool yes) =>
      expect(tester.getSemantics(find.bySemanticsLabel(label)), isSemantics(isSelected: yes));

  testWidgets('a tab a part opens it, and the part in view stands out', (tester) async {
    await pump(tester);
    expect(find.bySemanticsLabel('Part 3: Of the Sea'), findsOneWidget);
    selected(tester, 'Part 1: Of the Shore', true);

    await tester.tap(find.bySemanticsLabel('Part 3: Of the Sea'));
    await tester.pumpAndSettle();
    expect(find.text('PART 3: OF THE SEA'), findsOneWidget);
    expect(tester.getTopLeft(find.text('PART 3: OF THE SEA')).dy, lessThan(300));
    selected(tester, 'Part 3: Of the Sea', true);
    selected(tester, 'Part 1: Of the Shore', false);
  });

  testWidgets('no tabs without parts, nor while searching', (tester) async {
    await pump(tester, of: [for (var c = 1; c <= 30; c++) 'Chapter $c']);
    expect(find.bySemanticsLabel(RegExp('^Part')), findsNothing);

    await pump(tester);
    await tester.enterText(find.byType(TextField), 'Sea');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Part 1: Of the Shore'), findsNothing);
  });

  testWidgets("chapters joined to their part's name share its tab, and show their own names", (tester) async {
    // As Flatland's contents join them: "Part I: This World · I: Of …".
    final joined = [
      'Preface',
      for (final (part, n) in [('Part I: This World', 12), ('Part II: Other Worlds', 10)])
        for (var c = 1; c <= n; c++) '$part · Chapter $c',
    ];
    await pump(tester, of: joined);
    expect(find.bySemanticsLabel('Part I: This World'), findsOneWidget);
    expect(find.bySemanticsLabel('Part II: Other Worlds'), findsOneWidget);
    // A chapter in a part reads as a chapter, by its own name.
    expect(find.text('Chapter 3'), findsWidgets);
    expect(find.textContaining('PART I'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Part II: Other Worlds'));
    await tester.pumpAndSettle();
    selected(tester, 'Part II: Other Worlds', true);
  });
}
