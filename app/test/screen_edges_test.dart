// What sits at a screen's edges: the text and the shelf fade into the ground
// at their edges only (a mask over all of it drew it all again offscreen on
// every frame it moved).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_card.dart';
import 'package:tomevoice_spike/library_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/ui.dart';
import 'package:tomevoice_spike/voice_glow.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_screen_edges');
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

  /// Two chapters long enough to scroll and to fill several pages.
  ReadingLayout longBook() {
    final para = List.filled(30, 'A long paragraph of the story goes on here for a while.').join(' ');
    return ReadingLayout.build(ingestString(
      '# Alpha\n\n${List.filled(12, para).join('\n\n')}\n\n'
      '# Beta\n\nBeta opens here. ${List.filled(12, para).join('\n\n')}',
      filename: 'novel.md',
    ));
  }

  Future<void> openReader(WidgetTester tester, ReadingLayout layout) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: ReaderScreen(layout: layout),
    ));
    await tester.pumpAndSettle();
  }

  /// Dispose the tree and let any snack bar or timer run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  group('the text fades into the ground', () {
    testWidgets('at its two edges only, over the page tone, its glow and all', (tester) async {
      ListeningPrefs.memory.pageTone = 'papyrus';
      phone(tester);
      await openReader(tester, longBook());
      final text = find.byType(ScrollablePositionedList);
      final area = tester.getRect(text);
      expect(find.ancestor(of: text, matching: find.byType(ShaderMask)), findsNothing,
          reason: 'no mask over the whole text');
      final fades = find.byType(GroundFade);
      expect(fades, findsNWidgets(2));
      expect(tester.getRect(fades.at(0)), Rect.fromLTWH(area.left, area.top, area.width, 18));
      expect(tester.getRect(fades.at(1)), Rect.fromLTWH(area.left, area.bottom - 28, area.width, 28));
      expect(tester.widget<GroundFade>(fades.at(0)).top, isTrue);
      expect(tester.widget<GroundFade>(fades.at(1)).top, isFalse);
      // Every mask on the screen is one of the strips.
      for (final m in find.byType(ShaderMask).evaluate()) {
        expect((m.renderObject! as RenderBox).size.height, lessThanOrEqualTo(28));
      }

      // Each draws the page's own ground (its tone and vignette) where the
      // real one is, at its size.
      final ground = find.byType(PageGround).first;
      final origin = tester.getTopLeft(ground);
      for (var i = 0; i < 2; i++) {
        final copy = find.descendant(of: fades.at(i), matching: find.byType(PageGround));
        expect(tester.widget<PageGround>(copy).tone, PageTone.papyrus);
        expect(tester.widget<PageGround>(copy).vignette, isTrue);
        final box = tester.renderObject<RenderBox>(copy);
        expect(box.size, tester.getSize(ground));
        expect(box.localToGlobal(Offset.zero), origin, reason: 'lined up with the ground it draws again');
      }
      // The voice's glow shows through the fade at the foot, as it did under
      // the mask: drawn there too, in its place on the ground.
      expect(find.descendant(of: fades.at(1), matching: find.byType(VoiceGlow)), findsOneWidget);
      expect(find.descendant(of: fades.at(0), matching: find.byType(VoiceGlow)), findsNothing);
      // They are pictures: a tap goes through to the text.
      expect(tester.widget<IgnorePointer>(find.descendant(of: fades.at(1), matching: find.byType(IgnorePointer)).first).ignoring,
          isTrue);

      // A new tone follows into the fades.
      ListeningPrefs.memory
        ..pageTone = 'dusk'
        ..save();
      await tester.pumpAndSettle();
      expect(tester.widget<PageGround>(find.descendant(of: fades.at(0), matching: find.byType(PageGround))).tone,
          PageTone.dusk);
      await finish(tester);
    });

    testWidgets('on its side, the foot fades under the glow, which is over the text there', (tester) async {
      phone(tester, onItsSide: true);
      await openReader(tester, longBook());
      final fades = find.byType(GroundFade);
      expect(fades, findsNWidgets(2));
      expect(find.descendant(of: fades.at(1), matching: find.byType(VoiceGlow)), findsNothing);
      await finish(tester);
    });
  });

  testWidgets('the shelf fades into the ground under the dock, at its foot only', (tester) async {
    phone(tester);
    await tester.runAsync(() async {
      final store = LibraryStore(_tmp);
      for (final name in ['alpha.txt', 'beta.txt']) {
        final f = File('${_tmp.path}/incoming/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 40}\n\n'
              'Chapter 2\n\n${'It keeps going here. ' * 40}');
        final made = await store.importFile(PickedFile(path: f.path, name: name));
        if (name == 'alpha.txt') {
          // Being read: the dock comes up with it.
          final layout = await store.loadLayout(made.id);
          await store.saveCursor(made.id, cursorOf(layout.units[3]), 0.3, where: 'Chapter 1');
        }
      }
    });
    await tester.pumpWidget(const SpikeApp());
    for (var i = 0; i < 40 && find.byType(BookCover).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(ContinueDock), findsOneWidget);

    final cover = find.byType(BookCover).first;
    expect(find.ancestor(of: cover, matching: find.byType(ShaderMask)), findsNothing,
        reason: 'no mask over the whole shelf');
    final fade = find.byType(GroundFade);
    expect(fade, findsOneWidget);
    final shelf = tester.getRect(find.ancestor(of: fade, matching: find.byType(Stack)).first);
    final strip = tester.getRect(fade);
    expect(strip.bottom, shelf.bottom);
    expect(strip.height, 130);
    expect(strip.width, shelf.width);
    expect(tester.widget<GroundFade>(fade).top, isFalse);
    // The ground drawn again where the library's is.
    final copy = tester.renderObject<RenderBox>(find.descendant(of: fade, matching: find.byType(DecoratedBox)).first);
    expect(copy.localToGlobal(Offset.zero), Offset.zero);
    expect(copy.size, tester.getSize(find.byType(LibraryScreen)));
    await finish(tester);
  });
}
