// Small accessibility gaps: type on a page tone that reads at AA contrast,
// targets a finger can hit (48 dp), a fast scroller a screen reader can say
// and step, and Now Playing in the reader's own text size.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/fast_scroller.dart';
import 'package:tomevoice_spike/library_store.dart' show specimenBook;
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/now_playing.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/theme.dart';

const _channel = MethodChannel('tomevoice/tts');

/// WCAG's contrast between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  late Directory tmp;

  setUp(() {
    MarkStore.instance.reset();
    tmp = Directory.systemTemp.createTempSync('tv_a11y');
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
        'outputDir' => tmp.path,
        'playerPosition' => 0,
        'playerEnqueue' => 0,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// Dispose the tree and let any snack bar or scheduler timer run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<void> pumpReader(WidgetTester tester, {Size size = const Size(1080, 2340)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: ReaderScreen(layout: ReadingLayout.build(specimenBook())),
    ));
    await tester.pumpAndSettle();
  }

  group('contrast', () {
    test('the soft ink and the accent of each page tone read at 4.5:1 on its paper', () {
      for (final tone in PageTone.all.where((t) => !t.isApp)) {
        for (final paper in tone.paper!) {
          expect(contrast(tone.inkSoft!, paper), greaterThanOrEqualTo(4.5), reason: '${tone.label} soft ink');
          expect(contrast(tone.accent!, paper), greaterThanOrEqualTo(4.5), reason: '${tone.label} accent');
        }
      }
    });

    test("Papyrus's soft ink reads on the darkened edge under the top bar's chapter line", () {
      // The chapter line starts about 7% of the way down the paper, where
      // the vignette is at about nine tenths of its strength.
      const tone = PageTone.papyrus;
      final paper = Color.lerp(tone.paper!.first, tone.paper!.last, 0.07)!;
      final edge = Color.alphaBlend(tone.vignette!.withValues(alpha: tone.vignette!.a * 0.91), paper);
      expect(contrast(tone.inkSoft!, edge), greaterThanOrEqualTo(4.5));
    });

    test('each tone keeps its character: the soft ink stays softer than the ink', () {
      for (final tone in PageTone.all.where((t) => !t.isApp)) {
        for (final paper in tone.paper!) {
          expect(contrast(tone.ink!, paper), greaterThan(contrast(tone.inkSoft!, paper)), reason: tone.label);
        }
      }
    });
  });

  group('targets', () {
    testWidgets('a round button takes 48 dp for a finger and still draws its circle at 44', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RoundButton(icon: Icons.search_rounded, tooltip: 'Search', onTap: () => taps++),
                RoundButton(icon: Icons.menu_rounded, tooltip: 'Menu', size: 42, onTap: () {}),
              ],
            ),
          ),
        ),
      ));
      final search = find.byTooltip('Search');
      expect(tester.getSize(search), const Size(48, 48));
      expect(tester.getSize(find.descendant(of: search, matching: find.byType(Capsule))), const Size(44, 44));
      expect(tester.getSize(find.byTooltip('Menu')), const Size(48, 48));

      // A tap in the margin round the circle is the button's.
      final box = tester.getRect(search);
      await tester.tapAt(box.topLeft + const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(taps, 1);
      await tester.tapAt(box.topLeft - const Offset(2, 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(taps, 1, reason: 'outside the 48 dp square is not the button');

      // One node per button, a button, the size of the target.
      final node = tester.getSemantics(search);
      expect(node.rect.size, const Size(48, 48));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets("the reader's top bar draws its circles where they were", (tester) async {
      await pumpReader(tester);
      // As before the targets grew: 12 dp in from the side and 8 down, 8 apart.
      final back = find.descendant(of: find.byTooltip('Back to library'), matching: find.byType(Capsule));
      expect(tester.getTopLeft(back), const Offset(12, 8));
      expect(tester.getSize(back), const Size(44, 44));
      expect(tester.getSize(find.byTooltip('Back to library')), const Size(48, 48));
      final search = tester.getRect(find.descendant(of: find.byTooltip('Search'), matching: find.byType(Capsule)));
      final bookmark =
          tester.getRect(find.descendant(of: find.byTooltip('Bookmark this page'), matching: find.byType(Capsule)));
      expect(bookmark.left - search.right, 8);
      expect(search.top, 8);
      await finish(tester);
    });

    testWidgets("the player's handle opens Now Playing from a target a finger's height", (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReader(tester);
      final node = tester.getSemantics(find.bySemanticsLabel('Open Now Playing'));
      expect(node.rect.height, greaterThanOrEqualTo(48));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      // Below the thin handle, on the line of what is left: still the handle's.
      await tester.tap(find.textContaining('LEFT'));
      await tester.pumpAndSettle();
      expect(find.text('NOW READING'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      // The chips beside it are still their own.
      await tester.tap(find.byTooltip('Speed'));
      await tester.pumpAndSettle();
      expect(find.text('NOW READING'), findsNothing);
      handle.dispose();
      await finish(tester);
    });

    testWidgets('on its side, sleep and save take 48 dp, and the cover opens Now Playing from 52', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReader(tester, size: const Size(2392, 1080));
      // The whole button, not its drawn circle (where its tooltip sits).
      Size target(String tip) =>
          tester.getSize(find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)));
      expect(target('Sleep timer'), const Size(48, 48));
      expect(target('Save this line'), const Size(48, 48));
      // The cover is the dock's way in for a screen reader; the strip with
      // the handle in it is a second way for a finger.
      final cover = tester.getSemantics(find.bySemanticsLabel('Open Now Playing'));
      expect(cover.rect.width, greaterThanOrEqualTo(48));
      expect(cover.rect.height, greaterThanOrEqualTo(48));
      handle.dispose();
      await finish(tester);
    });
  });

  group('fast scroller', () {
    Future<ScrollController> pumpList(WidgetTester tester, List<bool> dragged) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FastScroller(
            controller: controller,
            labelAt: (f) => 'Chapter ${(f * 99).round() + 1}',
            onDrag: dragged.add,
            child: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 100,
              itemBuilder: (_, i) => Text('Row $i'),
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('a screen reader has a slider that says where the list is, shown or not', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpList(tester, []);
      final node = tester.getSemantics(find.bySemanticsLabel('Fast scroll'));
      final data = node.getSemanticsData();
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.value, 'Chapter 1, 0%');
      expect(data.increasedValue, 'Chapter 6, 5%');
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isFalse, reason: 'already at the top');
      handle.dispose();
    });

    testWidgets('its increase and decrease step through the list, as a drag let go there', (tester) async {
      final handle = tester.ensureSemantics();
      final dragged = <bool>[];
      final controller = await pumpList(tester, dragged);
      SemanticsNode slider() => tester.getSemantics(find.bySemanticsLabel('Fast scroll'));
      final owner = slider().owner!;

      owner.performAction(slider().id, SemanticsAction.increase);
      await tester.pump();
      final max = controller.position.maxScrollExtent;
      expect(controller.offset, closeTo(max * 0.05, 0.5));
      expect(dragged, [true, false]);
      expect(slider().getSemanticsData().value, 'Chapter 6, 5%');

      owner.performAction(slider().id, SemanticsAction.increase);
      await tester.pump();
      owner.performAction(slider().id, SemanticsAction.decrease);
      await tester.pump();
      expect(controller.offset, closeTo(max * 0.05, 0.5));
      expect(slider().getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
      await tester.pump(const Duration(seconds: 2));
      handle.dispose();
    });

    testWidgets('a short list has no thumb, for a finger or a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FastScroller(
            controller: controller,
            child: ListView(controller: controller, children: const [Text('One'), Text('Two')]),
          ),
        ),
      ));
      await tester.pump();
      expect(find.bySemanticsLabel('Fast scroll'), findsNothing);
      handle.dispose();
    });
  });

  testWidgets("Now Playing sets the book in the reader's text size", (tester) async {
    ListeningPrefs.memory.textSize = 26;
    await pumpReader(tester);
    await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('NOW READING'), findsOneWidget);
    final passage = tester.widget<Text>(
      find.descendant(of: find.byType(NowPlayingScreen), matching: find.textContaining('quick brown fox')).first,
    );
    expect(passage.style?.fontSize, 26);
    await finish(tester);
  });
}
