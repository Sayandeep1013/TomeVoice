// Saved: a book's heading goes with its last row, folding as it folds,
// never before it; and comes back with it on Undo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/saved_screen.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    MarkStore.instance.reset();
    tmp = Directory.systemTemp.createTempSync('tv_saved');
    store = LibraryStore(tmp);
  });

  tearDown(() {
    MarkStore.instance.reset();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpSaved(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => store.index());
    await tester.pumpWidget(MaterialApp(home: SavedScreen(store: store)));
    await tester.pumpAndSettle();
  }

  /// How open the fold round [text] is: 1 open, 0 shut.
  double fold(WidgetTester tester, String text) =>
      tester.widget<Align>(find.ancestor(of: find.text(text), matching: find.byType(Align)).first).heightFactor ?? 1;

  Future<void> quote(String book, String title, String text) => MarkStore.instance
      .add(bookId: book, bookTitle: title, kind: MarkKind.quote, at: ReadingCursor.zero, text: text);

  testWidgets("a book's heading folds away with its last quote, not before it", (tester) async {
    await quote('a', 'Persuasion', 'There could have been no two hearts so open.');
    await quote('b', 'Emma', 'One half of the world cannot understand the pleasures of the other.');
    await pumpSaved(tester);
    expect(find.text('Persuasion'), findsOneWidget);

    // Emma's only quote, removed with its button.
    final row = find.ancestor(of: find.textContaining('One half of the world'), matching: find.byType(Dismissible));
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Remove')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    // Half way: the row and its heading are folding together.
    final heading = fold(tester, 'Emma');
    final last = fold(tester, 'One half of the world cannot understand the pleasures of the other.');
    expect(heading, inExclusiveRange(0, 1));
    expect(heading, closeTo(last, 0.01));
    expect(fold(tester, 'Persuasion'), 1, reason: 'another book keeps its heading');

    await tester.pumpAndSettle();
    expect(find.text('Emma'), findsNothing);
    expect(MarkStore.instance.forBook('b'), isEmpty);

    // Undo: back it comes, heading and all.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Emma'), findsOneWidget);
    expect(fold(tester, 'Emma'), 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a heading stays while its book has another quote', (tester) async {
    await quote('a', 'Persuasion', 'There could have been no two hearts so open.');
    await quote('a', 'Persuasion', 'She had been forced into prudence in her youth.');
    await pumpSaved(tester);
    final row = find.ancestor(of: find.textContaining('forced into prudence'), matching: find.byType(Dismissible));
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Remove')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(fold(tester, 'Persuasion'), 1);
    await tester.pumpAndSettle();
    expect(find.text('Persuasion'), findsOneWidget);
    expect(find.textContaining('forced into prudence'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('swiped away, the last quote takes its heading as it shrinks', (tester) async {
    await quote('b', 'Emma', 'One half of the world cannot understand the pleasures of the other.');
    await pumpSaved(tester);
    await tester.drag(find.textContaining('One half of the world'), const Offset(-600, 0));
    // Frame by frame through the swipe and the shrink after it: the heading
    // folds while the row shrinks, and is never gone while the row is there.
    var folding = false;
    for (var i = 0; i < 60; i++) {
      final heading = find.text('Emma').evaluate().isNotEmpty;
      final row = find.textContaining('One half of the world').evaluate().isNotEmpty;
      expect(row && !heading, isFalse, reason: 'the heading went before its row');
      if (!heading) break;
      final t = fold(tester, 'Emma');
      if (t > 0 && t < 1) folding = true;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(folding, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Emma'), findsNothing);
    expect(MarkStore.instance.forBook('b'), isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });
}
