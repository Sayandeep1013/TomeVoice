// A press held the way a finger holds it still counts as a tap. In 2.6.3 the
// give under the finger (motion.dart's Jelly) put a Transform above the
// button once it began to move and took it away at rest; that swap built the
// InkWell anew mid-press and dropped the tap, so rows, sheet actions, round
// buttons and Play needed tapping again and again. adb's taps (down and up
// in the same instant) never saw it; a finger down for a tenth of a second
// or more did, nearly every time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/motion.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';

/// Down on [target], held [hold] in frames, then up: a finger's tap.
Future<void> holdAndLift(WidgetTester tester, Finder target, Duration hold) async {
  final finger = await tester.startGesture(tester.getCenter(target));
  var left = hold;
  const frame = Duration(milliseconds: 16);
  while (left > Duration.zero) {
    await tester.pump(left < frame ? left : frame);
    left -= frame;
  }
  await finger.up();
  await tester.pumpAndSettle();
}

Widget _page(Widget child, {bool still = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: still),
          child: Scaffold(body: ListView(children: [child])),
        ),
      ),
    );

void main() {
  final before = Skin.palette;
  tearDown(() => Skin.palette = before);

  const holds = [
    Duration(milliseconds: 40),
    Duration(milliseconds: 120),
    Duration(milliseconds: 300),
  ];

  for (final scene in [false, true]) {
    final where = scene ? 'in a scene' : 'in a plain theme';
    for (final hold in holds) {
      final held = '${hold.inMilliseconds} ms';

      testWidgets('a settings row takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var taps = 0;
        await tester.pumpWidget(_page(SettingRow(title: 'Book memories', onTap: () => taps++)));
        await holdAndLift(tester, find.text('Book memories'), hold);
        expect(taps, 1);
      });

      testWidgets('a switch row takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var on = false;
        await tester.pumpWidget(_page(StatefulBuilder(
          builder: (context, set) => SwitchRow(title: 'Animations', value: on, onChanged: (v) => set(() => on = v)),
        )));
        await holdAndLift(tester, find.text('Animations'), hold);
        expect(on, isTrue);
      });

      testWidgets('a sheet action takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var taps = 0;
        await tester.pumpWidget(
            _page(SheetAction(icon: Icons.play_arrow_rounded, label: 'Read from here', onTap: () => taps++)));
        await holdAndLift(tester, find.text('Read from here'), hold);
        expect(taps, 1);
      });

      testWidgets('a round button takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var taps = 0;
        await tester.pumpWidget(_page(Center(
          child: RoundButton(icon: Icons.psychology_outlined, tooltip: 'Book memories', onTap: () => taps++),
        )));
        await holdAndLift(tester, find.byIcon(Icons.psychology_outlined), hold);
        expect(taps, 1);
      });

      testWidgets('a capsule takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var taps = 0;
        await tester.pumpWidget(_page(Center(child: Capsule(onTap: () => taps++, child: const Text('Library')))));
        await holdAndLift(tester, find.text('Library'), hold);
        expect(taps, 1);
      });

      // Play is a Material and InkWell inside Jelly.listen (player_controls.dart).
      testWidgets('a button the way Play is built takes a tap held $held, $where', (tester) async {
        if (scene) Skin.palette = Palette.forestScene;
        var taps = 0;
        await tester.pumpWidget(_page(Center(
          child: Jelly.listen(
            strength: 1.3,
            child: Material(
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => taps++,
                child: const SizedBox(width: 54, height: 54, child: Icon(Icons.play_arrow_rounded)),
              ),
            ),
          ),
        )));
        await holdAndLift(tester, find.byIcon(Icons.play_arrow_rounded), hold);
        expect(taps, 1);
      });
    }
  }

  testWidgets('with animations off, a held tap still counts', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_page(SettingRow(title: 'Book memories', onTap: () => taps++), still: true));
    await holdAndLift(tester, find.text('Book memories'), const Duration(milliseconds: 200));
    expect(taps, 1);
  });

  testWidgets('a press that becomes a scroll is no tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_page(SettingRow(title: 'Book memories', onTap: () => taps++)));
    final finger = await tester.startGesture(tester.getCenter(find.text('Book memories')));
    await tester.pump(const Duration(milliseconds: 16));
    await finger.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    await finger.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
  });

  testWidgets('pressed, the row gives; let go, it is back to its shape', (tester) async {
    await tester.pumpWidget(_page(SettingRow(title: 'Book memories', onTap: () {})));
    Matrix4 shape() => tester
        .widget<Transform>(find.descendant(of: find.byType(Jelly), matching: find.byType(Transform)).first)
        .transform;
    expect(shape().isIdentity(), isTrue);
    final finger = await tester.startGesture(tester.getCenter(find.text('Book memories')));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 60));
    expect(shape().isIdentity(), isFalse);
    await finger.up();
    await tester.pumpAndSettle();
    expect(shape().isIdentity(), isTrue);
  });
}
