// Find a passage: the line under the search field says what the search is
// doing, and says nothing once there is too little to search for.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_search.dart';

void main() {
  testWidgets('"Searching…" goes when the query is cut below two letters while a search runs', (tester) async {
    // A long book: the whole of it is searched on a background isolate, so
    // the search is still running when the query is cut short.
    final layout = ReadingLayout.build(ingestString(
      [for (var p = 0; p < 160; p++) List.generate(25, (i) => 'Sentence $p.$i goes on here.').join(' ')].join('\n\n'),
      filename: 'long.txt',
    ));
    expect(layout.units.length, greaterThan(3000));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBookSearch(context, layout: layout, chapter: 0, wholeBook: true, onPick: (_, __, ___) {}),
            child: const Text('Find'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'se');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('SEARCHING…'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 's');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('SEARCHING…'), findsNothing);
    expect(find.textContaining('NOT FOUND'), findsNothing);

    // The search that was running comes back out of date and changes
    // nothing.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();
    expect(find.text('SEARCHING…'), findsNothing);
    expect(find.textContaining('MATCHES'), findsNothing);
  });
}
