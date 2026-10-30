// What a finger can reach: the player's chips, its chapter scrubber and a
// row of choices are drawn thinner than Android's 48 dp target, and their
// taps reach that far without anything being drawn or laid out differently.
// Their neighbours keep their own taps: the strip that opens Now Playing,
// the buttons under the scrubber, the passage over Now Playing's.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/now_playing.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/ui.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('tv_tap_targets');
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
            {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
          ],
        'outputDir' => _tmp.path,
        'playerPosition' => 0,
        'playerEnqueue' => 0,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester, {bool onItsSide = false}) {
    tester.view.physicalSize = onItsSide ? const Size(2340, 1080) : const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> openReader(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: ReadingLayout.build(specimenBook()))));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  /// Whether a tap at [at] is [target]'s: the deepest thing it hits lies in
  /// it (a label's text is hit as itself, inside what draws it).
  bool reaches(WidgetTester tester, Finder target, Offset at) {
    final deepest = tester.hitTestOnBinding(at).path.map((e) => e.target).whereType<RenderObject>().firstOrNull;
    if (deepest == null) return false;
    final root = tester.renderObject(target);
    for (RenderObject? o = deepest; o != null; o = o.parent) {
      if (identical(o, root)) return true;
    }
    return false;
  }

  /// How tall [target] can be tapped down the line [x]: the run of points,
  /// half a dp apart, whose taps reach it, through its middle at [y].
  double tappable(WidgetTester tester, Finder target, double x, double y) {
    if (!reaches(tester, target, Offset(x, y))) return 0;
    var top = y, bottom = y;
    while (top > y - 60 && reaches(tester, target, Offset(x, top - 0.5))) {
      top -= 0.5;
    }
    while (bottom < y + 60 && reaches(tester, target, Offset(x, bottom + 0.5))) {
      bottom += 0.5;
    }
    return bottom - top + 0.5;
  }

  double tall(WidgetTester tester, Finder target) {
    final r = tester.getRect(target);
    return tappable(tester, target, r.center.dx, r.center.dy);
  }

  Finder button(String tip, {Finder? within}) {
    final all = find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton));
    return (within == null ? all : find.descendant(of: within, matching: all)).first;
  }

  final opener = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Open Now Playing');

  group("the reader's player, upright", () {
    testWidgets('its chips take a finger, and the strip over them still opens Now Playing', (tester) async {
      phone(tester);
      await openReader(tester);
      for (final tip in ['Speed', 'Voice']) {
        final chip = find.byTooltip(tip);
        expect(tester.getSize(chip).height, lessThan(40), reason: '$tip is drawn as it was');
        expect(tall(tester, chip), greaterThanOrEqualTo(48), reason: tip);
        // The top of the strip over it, and the strip beside it, are Now
        // Playing's still.
        final r = tester.getRect(chip);
        expect(reaches(tester, opener.first, Offset(r.center.dx, r.top - 17)), isTrue, reason: 'over $tip');
      }
      // The handle, and the strip over the line between the chips.
      final speed = tester.getRect(find.byTooltip('Speed'));
      final voice = tester.getRect(find.byTooltip('Voice'));
      final middle = (speed.right + voice.left) / 2;
      for (final dy in [-18.0, -8.0, 0.0, 10.0]) {
        expect(reaches(tester, opener.first, Offset(middle, speed.center.dy + dy)), isTrue, reason: 'between, at $dy');
      }
      // Nothing about the bar moved: the chips sit 6 dp over the scrubber.
      expect(tester.getRect(find.byType(Slider)).top - speed.bottom, closeTo(6, 0.5));
      await finish(tester);
    });

    testWidgets('its scrubber takes the gap over it and the strip over the buttons; the buttons keep theirs',
        (tester) async {
      phone(tester);
      await openReader(tester);
      final slider = find.byType(Slider);
      final s = tester.getRect(slider);
      expect(s.height, closeTo(26, 0.5), reason: 'drawn as it was');
      // Over a button, between a chip and the button's own 48 dp: 39 dp is
      // all there is (the chips' 6 dp gap, the slider, the buttons' 7).
      final under = tester.getRect(button('Previous chapter'));
      expect(tappable(tester, slider, under.center.dx, s.center.dy), greaterThanOrEqualTo(39));
      expect(tappable(tester, slider, under.center.dx, s.center.dy), lessThan(40), reason: 'into the button');
      for (final tip in ['Previous chapter', 'Previous sentence', 'Next sentence', 'Next chapter']) {
        final b = button(tip);
        expect(tall(tester, b), greaterThanOrEqualTo(48), reason: tip);
      }
      // The chips are not reached through the gap.
      final speed = tester.getRect(find.byTooltip('Speed'));
      expect(reaches(tester, find.byTooltip('Speed'), Offset(speed.center.dx, speed.bottom - 1)), isTrue);
      expect(reaches(tester, slider, Offset(speed.center.dx, speed.bottom + 1)), isTrue);
      await finish(tester);
    });
  });

  testWidgets("on its side, the dock's chips and scrubber take a finger", (tester) async {
    phone(tester, onItsSide: true);
    await openReader(tester);
    for (final tip in ['Speed', 'Voice']) {
      final chip = find.byTooltip(tip);
      expect(tester.getSize(chip).height, lessThan(40), reason: '$tip is drawn as it was');
      expect(tall(tester, chip), greaterThanOrEqualTo(48), reason: tip);
    }
    final slider = find.byType(Slider);
    expect(tester.getSize(slider).height, closeTo(26, 0.5));
    expect(tall(tester, slider), greaterThanOrEqualTo(48));
    for (final tip in ['Previous chapter', 'Next chapter', 'Sleep timer']) {
      expect(tall(tester, button(tip)), greaterThanOrEqualTo(48), reason: tip);
    }
    await finish(tester);
  });

  testWidgets("Now Playing's scrubber and chips take a finger, and its buttons keep theirs", (tester) async {
    phone(tester);
    await openReader(tester);
    await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    final now = find.byType(NowPlayingScreen);
    final slider = find.descendant(of: now, matching: find.byType(Slider));
    expect(tester.getSize(slider).height, closeTo(26, 0.5));
    expect(tall(tester, slider), greaterThanOrEqualTo(48));
    final chips = find.descendant(of: now, matching: find.byType(InkWell));
    var counted = 0;
    for (final e in chips.evaluate()) {
      final chip = find.byWidget(e.widget);
      final r = tester.getRect(chip);
      // The four chips along the foot (not the buttons over them).
      if (r.height > 40) continue;
      counted++;
      expect(tall(tester, chip), greaterThanOrEqualTo(48), reason: 'a chip at $r');
    }
    expect(counted, 4);
    for (final tip in ['Previous chapter', 'Previous sentence', 'Next sentence', 'Next chapter']) {
      expect(tall(tester, button(tip, within: now)), greaterThanOrEqualTo(48), reason: tip);
    }
    await finish(tester);
  });

  group('a row of choices', () {
    Future<List<int>> openRow(WidgetTester tester, {int count = 3}) async {
      final picked = <int>[];
      phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: StatefulBuilder(
              builder: (context, setState) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionTitle('Line spacing'),
                  const SizedBox(height: 12),
                  ChoiceRow<int>(
                    options: [for (var i = 0; i < count; i++) (i, 'Choice $i')],
                    value: picked.lastOrNull ?? 0,
                    onChanged: (v) => setState(() => picked.add(v)),
                  ),
                  const SizedBox(height: 8),
                  const Text('What the choice does.'),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return picked;
    }

    for (final count in [3, 9]) {
      testWidgets('each segment takes a finger, and a tap past the track picks the one under it'
          '${count > 3 ? ', when it scrolls' : ''}', (tester) async {
        final picked = await openRow(tester, count: count);
        final segments = find.byType(InkWell);
        expect(segments, findsNWidgets(count));
        for (final e in segments.evaluate().take(3)) {
          final segment = find.byWidget(e.widget);
          expect(tester.getSize(segment).height, lessThan(40), reason: 'drawn as it was');
          expect(tall(tester, segment), greaterThanOrEqualTo(48));
        }
        final second = tester.getRect(segments.at(1));
        await tester.tapAt(Offset(second.center.dx, second.top - 6));
        await tester.pumpAndSettle();
        expect(picked, [1]);
        final third = tester.getRect(segments.at(2));
        await tester.tapAt(Offset(third.center.dx, third.bottom + 6));
        await tester.pumpAndSettle();
        expect(picked, [1, 2]);
      });
    }
  });
}
