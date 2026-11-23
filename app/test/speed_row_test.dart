// The speed control: a speed between the common ones (1.35 after + and −)
// shows in the row of speeds as a segment of its own, lit, in its place;
// on a phone's width the six still fit without scrolling.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/theme.dart';

void main() {
  // The interface's own face, so widths are a phone's, not the test font's
  // (every letter a square).
  setUpAll(() async {
    final loader = FontLoader(Skin.uiFamily)..addFont(rootBundle.load('assets/fonts/Figtree-Variable.ttf'));
    await loader.load();
  });
  tearDown(ListeningPrefs.reset);

  Future<ListeningPrefs> pumpSpeed(WidgetTester tester, double speed) async {
    // A small phone: 360 dp wide, the sheet's own margins inside it.
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final prefs = ListeningPrefs.memory..setSpeed(speed);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
          child: StatefulBuilder(
            builder: (context, setState) => SpeedControl(
              prefs: prefs,
              onChanged: ({required bool restart}) => setState(() {}),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return prefs;
  }

  Finder inRow(String text) => find.descendant(of: find.byKey(const Key('speed-row')), matching: find.text(text));

  testWidgets('a speed between the common ones is shown and lit in the row', (tester) async {
    final prefs = await pumpSpeed(tester, 1.0);
    expect(inRow('1×'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('speed-row')), matching: find.byType(SingleChildScrollView)),
        findsNothing);

    // + seven times: 1.35.
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byTooltip('Faster'));
      await tester.pumpAndSettle();
    }
    expect(prefs.speedFor(null), closeTo(1.35, 0.0001));
    expect(find.text('1.35×'), findsOneWidget, reason: 'the value above the row');
    expect(inRow('1.35'), findsOneWidget, reason: 'and its own segment in the row');
    final labels = [
      for (final t in tester.widgetList<Text>(find.descendant(
          of: find.byKey(const Key('speed-row')), matching: find.byType(Text))))
        t.data,
    ];
    expect(labels, ['0.75', '1', '1.25', '1.35', '1.5', '2'], reason: 'in its place among the others');
    expect(tester.takeException(), isNull, reason: 'no overflow at 360 dp');
    expect(find.descendant(of: find.byKey(const Key('speed-row')), matching: find.byType(SingleChildScrollView)),
        findsNothing,
        reason: 'six fit without scrolling');
    expect(
      find.ancestor(of: inRow('1.35'), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true)),
      findsOneWidget,
      reason: 'lit',
    );

    // A common speed picked: the extra segment goes.
    await tester.tap(inRow('1.5'));
    await tester.pumpAndSettle();
    expect(prefs.speedFor(null), 1.5);
    expect(inRow('1.35'), findsNothing);
    expect(inRow('1.5×'), findsOneWidget);
  });
}
