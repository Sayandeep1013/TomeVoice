// Scene themes (scene.dart): a place drawn behind every screen (a dungeon,
// a forest, the sun and the rest, however many there are). Picked in Settings and kept; each main screen builds in each
// scene on a narrow and a wide phone with nothing overflowing; the page of a
// book never has the art behind its words; and with no scene picked the app
// draws exactly what it drew before.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_card.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/now_playing.dart';
import 'package:tomevoice_spike/own_colours.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/scene.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/theme.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;

/// Phones held upright: a narrow one and a wide one, in dp.
const _widths = [360.0, 412.0];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_scene');
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
    Skin.palette = Palette.forest;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester, double width) {
    const ratio = 2.75;
    tester.view.physicalSize = Size(width * ratio, width * ratio * 2340 / 1080);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<void> settleIo(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 80 && !(until?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// A scene's ground anywhere in the tree.
  Finder sceneGrounds() => find.byWidgetPredicate(
        (w) => (w is DecoratedBox && w.decoration is SceneGround) || (w is Container && w.decoration is SceneGround),
      );

  group('picked and kept', () {
    test('a scene taken away (2.6.3) opens as the one kept in its place', () {
      expect(Palette.byId('scene-starship').id, 'scene-solar');
      expect(Palette.byId('scene-obsidian').id, 'scene-solar');
      expect(Palette.byId('scene-gothic').id, 'scene-dungeon');
      expect(Palette.idNow('scene-silver-witch'), 'scene-silver-witch');
      final prefs = ListeningPrefs()..paletteId = 'scene-gothic';
      expect(chosenPaletteId(prefs), 'scene-dungeon', reason: 'shown chosen in Settings');
      expect(chosenPalette(prefs).scene, Scene.dungeon);
    });

    test('each scene is a dark-only theme of its own, found by its id, its book colour keeping the scene', () {
      expect(Palette.scenes.map((p) => p.scene), Scene.values);
      for (final p in Palette.scenes) {
        expect(Palette.all, contains(p));
        expect(Palette.byId(p.id), same(p));
        expect(p.only, Brightness.dark, reason: p.label);
        expect(p.withTint(0xFF3366AA).scene, p.scene, reason: 'a book cover tints it, the place stays');
      }
      for (final p in [Palette.forest, ...Palette.designer]) {
        expect(p.scene, isNull, reason: p.label);
      }
    });

    test('a scene picked is saved with the settings and chosen again when they are read back', () {
      for (final p in Palette.scenes) {
        final prefs = ListeningPrefs()..paletteId = p.id;
        final back = ListeningPrefs.fromJson(
          Map<String, Object?>.from(jsonDecode(jsonEncode(prefs.toJson())) as Map),
        );
        expect(back.paletteId, p.id);
        expect(chosenPalette(back).scene, p.scene);
      }
    });

    testWidgets('Designer themes shows the scenes first; one tapped is put on', (tester) async {
      phone(tester, 412);
      ListeningPrefs.memory.paletteId = 'forest';
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(_tmp))));
      await settleIo(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Designer themes'), 300, scrollable: list);
      expect(find.textContaining('${Scene.values.length} scenes'), findsOneWidget);
      expect(find.byType(ScenePreview), findsNWidgets(Scene.values.length), reason: 'a glimpse of each in the row');
      // The colour row has no scenes in it.
      for (final p in Palette.scenes) {
        expect(find.text(p.label), findsNothing, reason: p.label);
      }
      await tester.tap(find.text('Designer themes'));
      await tester.pumpAndSettle();
      // At the top: the scenes, the first ones in view.
      expect(find.text('SCENES'), findsOneWidget);
      expect(find.text('Enchanted forest'), findsOneWidget);
      expect(find.text('Silver witch'), findsOneWidget);
      // The colours come after all the scenes: scrolled down to, then back
      // up to the last scene.
      final sheet = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(find.text('COLOURS'), 300, scrollable: sheet);
      expect(find.text('COLOURS'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Dungeon'), -300, scrollable: sheet);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dungeon'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.paletteId, 'scene-dungeon');
      expect(find.text('Dungeon is always dark.'), findsOneWidget);
      await finish(tester);
    });
  });

  group('drawn', () {
    test('each backdrop, frame, panel and ornament draws at a narrow and a wide phone', () {
      for (final scene in Scene.values) {
        for (final w in _widths) {
          final size = Size(w, w * 2340 / 1080);
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          paintBackdrop(canvas, size, scene);
          paintCoverFrame(canvas, const Rect.fromLTWH(10, 10, 110, 165), scene, 8);
          paintCoverFrame(canvas, const Rect.fromLTWH(10, 10, 30, 45), scene, 4);
          paintPanel(canvas, Rect.fromLTWH(12, 600, w - 24, 140), scene, scene.corners(BorderRadius.circular(28)));
          paintPanel(canvas, const Rect.fromLTWH(12, 600, 40, 20), scene, scene.corners(null));
          recorder.endRecording().dispose();
        }
      }
    });

    test('each scene\'s buttons and its life draw, the life at any moment of a long while', () {
      for (final scene in Scene.values) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (final fill in [const Color(0xF2221A15), Palette.scenes[scene.index].accent]) {
          paintButton(canvas, const Rect.fromLTWH(0, 0, 44, 44), scene, fill, BorderRadius.circular(999));
          paintButton(canvas, const Rect.fromLTWH(0, 0, 120, 36), scene, fill, BorderRadius.circular(999));
        }
        final time = ValueNotifier<double>(0);
        final life = LifePainter(scene, time);
        for (final t in [0.0, 0.5, 3.3, 61.7, 3600.2]) {
          time.value = t;
          life.paint(canvas, const Size(412, 892));
          life.paint(canvas, const Size(360, 780));
        }
        recorder.endRecording().dispose();
        time.dispose();
      }
    });

    test('a scene keeps its own light when book colours are on; a plain theme takes the cover\'s', () {
      for (final p in Palette.scenes) {
        expect(p.withTint(0xFF3366AA).accent, p.accent, reason: p.label);
      }
      expect(Palette.forest.withTint(0xFF3366AA).accent, isNot(Palette.forest.accent));
    });

    test("the solar scene's panels are cut at two corners, as a hull's; the others' are round", () {
      const rect = Rect.fromLTWH(0, 0, 200, 100);
      final ship = panelPath(rect, Scene.solar, BorderRadius.circular(2));
      expect(ship.contains(const Offset(1, 1)), isFalse, reason: 'the top left is cut away');
      expect(ship.contains(const Offset(198, 2)), isTrue, reason: 'the top right is square');
      final stone = panelPath(rect, Scene.dungeon, BorderRadius.circular(12));
      expect(stone.contains(const Offset(100, 50)), isTrue);
    });

    test("a scene's corners: the solar scene's sharp, the others rounded but never a pill", () {
      expect(Scene.solar.corners(BorderRadius.circular(999)).topLeft.x, 2);
      expect(Scene.dungeon.corners(BorderRadius.circular(999)).topLeft.x, lessThanOrEqualTo(18));
      expect(Scene.dungeon.corners(BorderRadius.circular(999)).topLeft.x, greaterThan(6));
      expect(Scene.forest.corners(BorderRadius.circular(8)).topLeft.x, 8);
    });

    test('a backdrop is drawn once for a size and kept', () {
      final a = sceneBackdrop(Scene.dungeon, const Size(100, 200), 1);
      final b = sceneBackdrop(Scene.dungeon, const Size(100, 200), 1);
      expect(a, isNotNull);
      expect(identical(a, b), isTrue);
    });
  });

  /// Two books on the shelf, the app pumped in [palette] at [width].
  Future<void> shelf(WidgetTester tester, Palette palette, double width) async {
    phone(tester, width);
    ListeningPrefs.memory.paletteId = palette.id;
    await tester.runAsync(() async {
      final store = LibraryStore(_tmp);
      for (final name in ['alpha.txt', 'beta.txt']) {
        final f = File('${_tmp.path}/incoming/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 40}\n\n'
              'Chapter 2\n\n${'It keeps going here. ' * 40}');
        await store.importFile(PickedFile(path: f.path, name: name));
      }
    });
    await tester.pumpWidget(const SpikeApp());
    await settleIo(tester, until: () => find.byType(BookCover).evaluate().isNotEmpty);
  }

  for (final palette in Palette.scenes) {
    for (final width in _widths) {
      testWidgets('${palette.label} at ${width.round()} dp: the library, the drawer and the screens it opens', (tester) async {
        await shelf(tester, palette, width);
        expect(tester.takeException(), isNull);
        expect(sceneGrounds(), findsWidgets, reason: 'the scene behind the library');
        // Each cover on the shelf sits in the scene's frame.
        expect(
          find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CoverFramePainter),
          findsWidgets,
        );

        // The drawer: the scene, its crest and its foot.
        await tester.tap(find.byTooltip('Menu').first);
        await tester.pumpAndSettle();
        expect(find.byType(SceneOrnament), findsNWidgets(2));
        expect(find.byType(SceneDivider), findsWidgets);
        expect(tester.takeException(), isNull);

        for (final place in ['History', 'Journal', 'Settings', 'Library']) {
          final row = find.text(place);
          if (row.evaluate().isEmpty) {
            await tester.tap(find.byTooltip('Menu').first);
            await tester.pumpAndSettle();
          }
          // On a small phone the drawer's lower rows are scrolled to.
          await tester.ensureVisible(find.text(place).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text(place).last);
          await settleIo(tester);
          expect(tester.takeException(), isNull, reason: place);
          expect(sceneGrounds(), findsWidgets, reason: '$place in the scene');
          if (place == 'Settings') {
            expect(find.byWidgetPredicate((w) => w is Container && w.decoration is ScenePanel), findsWidgets,
                reason: 'settings groups on its panels');
          }
        }

        // A book's own page.
        await tester.tap(find.byType(BookCover).first);
        await settleIo(tester);
        expect(tester.takeException(), isNull, reason: 'the book page');
        await finish(tester);
      });
    }
  }

  testWidgets('an empty shelf in a scene shows its own picture, not the icon', (tester) async {
    phone(tester, 412);
    ListeningPrefs.memory.paletteId = Palette.dungeon.id;
    await tester.pumpWidget(const SpikeApp());
    await settleIo(tester, until: () => find.text('Your shelf is empty').evaluate().isNotEmpty);
    expect(find.text('Your shelf is empty'), findsOneWidget);
    expect(find.byType(SceneEmptyArt), findsOneWidget);
    await finish(tester);
  });

  for (final palette in Palette.scenes) {
    for (final width in _widths) {
      testWidgets("${palette.label} at ${width.round()} dp: a book's page is plain, the player and Now Playing dressed",
          (tester) async {
        phone(tester, width);
        Skin.palette = palette;
        await tester.pumpWidget(MaterialApp(
          theme: Skin.themeFor(palette, Brightness.dark),
          darkTheme: Skin.themeFor(palette, Brightness.dark),
          themeMode: ThemeMode.dark,
          home: ReaderScreen(layout: ReadingLayout.build(specimenBook())),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // No scene art anywhere under the words.
        final text = find.byType(ScrollablePositionedList);
        expect(text, findsWidgets);
        expect(
          find.ancestor(
            of: text.first,
            matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration is SceneGround),
          ),
          findsNothing,
        );
        expect(sceneGrounds(), findsNothing, reason: 'the reader has no backdrop at all');
        // The player on the scene's panel.
        expect(find.byWidgetPredicate((w) => w is Container && w.decoration is ScenePanel), findsWidgets);

        // Now Playing: the scene behind, the cover framed, the controls on a panel.
        await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
        await tester.pumpAndSettle();
        expect(find.byType(NowPlayingScreen), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'Now Playing');
        expect(find.descendant(of: find.byType(NowPlayingScreen), matching: sceneGrounds()), findsWidgets);
        expect(
          find.descendant(
            of: find.byType(NowPlayingScreen),
            matching: find.byWidgetPredicate((w) => w is CustomPaint && w.foregroundPainter is CoverFramePainter),
          ),
          findsOneWidget,
        );
        await finish(tester);
      });
    }
  }

  testWidgets('with no scene picked, nothing of a scene is drawn anywhere', (tester) async {
    await shelf(tester, Palette.forest, 412);
    expect(sceneGrounds(), findsNothing);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && (w.painter is CoverFramePainter || w.foregroundPainter is CoverFramePainter)),
        findsNothing);
    await tester.tap(find.byTooltip('Menu').first);
    await tester.pumpAndSettle();
    expect(find.byType(SceneOrnament), findsNothing);
    expect(find.byType(SceneDivider), findsNothing);
    await finish(tester);
  });
}
