// The reader's comforts: the page's brightness (the window's own, and the
// page darkened below the phone's lowest) and its warmth, over every view
// of the page and never over the bars or the player; and auto-scroll, a
// steady scroll or a page turned every so often, held by a touch, stopped
// at a chapter's end, never with the voice, and never started by itself
// with TalkBack on.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/auto_scroll.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/page_light.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/paged_view.dart';
import 'package:tomevoice_spike/pages_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_player_bar.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');
const _shot = ValueKey('screen');

late Directory _tmp;
final _calls = <MethodCall>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final blank = String.fromCharCodes([10, 10]);

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_reader_comforts');
    _calls.clear();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    var n = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      _calls.add(call);
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
            {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
          ],
        'outputDir' => _tmp.path,
        'synthesise' => () {
            final f = File('${_tmp.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
            return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
          }(),
        'playerEnqueue' => 0,
        'playerPosition' => 0,
        'requestFocus' => 'granted',
        'pdfInfo' => {
            'pages': 2,
            'sizes': [612, 792, 612, 792],
          },
        'pdfRender' => '${_tmp.path}/page.jpg',
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

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// Two chapters of short paragraphs, each its own sentence: a chapter
  /// takes a screen or two.
  ReadingLayout short({int paragraphs = 14}) => ReadingLayout.build(ingestString(
        [
          '# Alpha',
          for (var p = 0; p < paragraphs; p++) 'Alpha line $p ends here.',
          '# Beta',
          for (var p = 0; p < paragraphs; p++) 'Beta line $p ends here.',
        ].join(blank),
        filename: 'short.md',
        title: 'Short',
      ));

  Future<void> open(WidgetTester tester, ReadingLayout layout, {LibraryStore? store, ReadingCursor? at, String? pdf}) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: RepaintBoundary(
        key: _shot,
        child: ReaderScreen(
          layout: layout,
          store: store,
          initialCursor: at ?? ReadingCursor.zero,
          sourcePath: pdf,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// What the window was told, in order (-1: the phone's own again).
  List<double> levels() => [
        for (final c in _calls)
          if (c.method == 'screenBrightness') ((c.arguments as Map)['level'] as num).toDouble(),
      ];

  /// The page's veils (not the one past the safe area), where they lie.
  List<Rect> veils(WidgetTester tester) => [
        for (final e in find.byType(LightVeil).evaluate())
          if ((e.widget as LightVeil).around == null)
            if (e.renderObject case final RenderBox box) box.localToGlobal(Offset.zero) & box.size,
      ];

  /// The reader's sheet, at its Read tab.
  Future<void> readTab(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Reading settings'));
    await tester.pumpAndSettle();
  }

  void closeSheet(WidgetTester tester) => Navigator.of(tester.element(find.byKey(const Key('reader-settings')))).pop();

  /// The screen as drawn, a pixel to a logical pixel.
  Future<(ByteData, int)> shot(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final width = image.width;
      image.dispose();
      return (data, width);
    }))!;
  }

  /// The red, green and blue at [p] in [s].
  List<int> rgb((ByteData, int) s, Offset p) {
    final i = (p.dy.round() * s.$2 + p.dx.round()) * 4;
    return [s.$1.getUint8(i), s.$1.getUint8(i + 1), s.$1.getUint8(i + 2)];
  }

  /// [after] is [before] with each channel multiplied by [by].
  void multiplied(List<int> before, List<int> after, List<double> by, String why) {
    for (var c = 0; c < 3; c++) {
      expect(after[c], closeTo(before[c] * by[c], 3), reason: '$why, channel $c: $before to $after');
    }
  }

  /// [after] is [before], give or take [give] in each channel.
  void kept(List<int> before, List<int> after, String why, {int give = 1}) {
    for (var c = 0; c < 3; c++) {
      expect(after[c], closeTo(before[c], give), reason: '$why, channel $c: $before to $after');
    }
  }

  group('the page’s light', () {
    test('the slider: the phone’s lowest a quarter of the way along, darker past it, squared above it', () {
      expect(PageLight.phone.window, isNull);
      expect(PageLight.phone.clear, isTrue);
      expect(const PageLight(brightness: 1).window, 1);
      expect(const PageLight(brightness: PageLight.below).window, 0);
      expect(const PageLight(brightness: 0.625).window, closeTo(0.25, 1e-9), reason: 'half way up the phone’s part');
      expect(const PageLight(brightness: 0.1).window, 0, reason: 'below its lowest, the phone stays at it');
      expect(const PageLight(brightness: 0.5).keep, 1);
      expect(const PageLight(brightness: 0).keep, PageLight.deepest);
      expect(const PageLight(brightness: 0).clear, isFalse);
      // The amber takes blue most, and black stays black.
      final warm = const PageLight(warmth: 1).filter;
      expect(warm.r, 1);
      expect(warm.b, lessThan(warm.g));
      expect(const PageLight(warmth: 1).lit(const Color(0xFF000000)), const Color(0xFF000000));
      // A colour drawn over the veil, as the veil would leave it.
      final dim = const PageLight(brightness: 0).lit(const Color(0x80FFFFFF));
      expect(dim.a, closeTo(0x80 / 255, 1e-9), reason: 'its alpha kept');
      expect(dim.r, closeTo(PageLight.deepest, 1e-9));
    });

    testWidgets('as the phone has it until set: the window is never asked', (tester) async {
      await open(tester, short());
      expect(levels(), isEmpty);
      expect(find.byType(LightVeil), findsWidgets);
      await finish(tester);
      expect(levels(), isEmpty, reason: 'nothing to give back');
    });

    testWidgets('Brightness in the Read tab is the window’s; the phone’s own again when the book closes',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, short());
      await readTab(tester);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('As the phone is'), findsWidgets);
      // The sheet's first slider (the player's scrubber, behind it, is one too).
      final brightness = find.descendant(of: find.byKey(const Key('reader-settings')), matching: find.byType(Slider)).first;
      // TalkBack hears what the screen says.
      expect(find.semantics.byValue('Brightness As the phone is'), findsOne);
      expect(find.semantics.byValue('Warmth Off'), findsOne);
      semantics.dispose();
      await tester.drag(brightness, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.pageBrightness, 1);
      expect(levels().last, 1);
      expect(find.text('100%'), findsOneWidget);
      // As far left as it goes: the phone's lowest.
      await tester.drag(brightness, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.pageBrightness, 0);
      expect(levels().last, 0);
      expect(find.text('Darker than the phone'), findsOneWidget);
      // While a slider moves the window is told often, not at every step,
      // and the last one heard is the one it keeps.
      _calls.clear();
      final slider = tester.widget<Slider>(brightness);
      for (var i = 0; i < 20; i++) {
        slider.onChanged!(0.3 + i * 0.02);
        await tester.pump(const Duration(milliseconds: 10));
      }
      slider.onChangeEnd!(0.68);
      await tester.pump(const Duration(milliseconds: 100));
      expect(levels().length, inInclusiveRange(2, 8), reason: 'no more than every 50 ms');
      expect(levels().last, closeTo(const PageLight(brightness: 0.68).window!, 1e-9));
      closeSheet(tester);
      await tester.pumpAndSettle();
      await finish(tester);
      expect(levels().last, -1, reason: 'given back as the book closed');
    });

    testWidgets('As the phone is puts brightness and warmth back', (tester) async {
      ListeningPrefs.memory
        ..pageBrightness = 0.1
        ..pageWarmth = 0.5;
      await open(tester, short());
      expect(levels().last, 0, reason: 'opened at the phone’s lowest');
      await readTab(tester);
      expect(find.text('Darker than the phone'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget, reason: 'the warmth');
      await tester.tap(find.text('As the phone is'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.pageBrightness, isNull);
      expect(ListeningPrefs.memory.pageWarmth, 0);
      expect(levels().last, -1);
      expect(find.text('Off'), findsOneWidget);
      closeSheet(tester);
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('below the phone’s lowest the page darkens, out to the screen’s edges; the bars and the player do not',
        (tester) async {
      phone(tester);
      tester.view.padding = const FakeViewPadding(top: 66, bottom: 44);
      ListeningPrefs.memory.pageTone = 'ink';
      await open(tester, short());
      final card = tester.getRect(find.byType(ReaderPlayerBar));
      final back = tester.getCenter(find.byTooltip('Back to library'));
      final page = {
        'the status bar': const Offset(200, 10),
        'the ground under the top bar': Offset(3, back.dy),
        'the page beside the text': const Offset(5, 400),
        'the ground beside the player': Offset(card.left + 4, card.center.dy),
        'the gesture bar': const Offset(200, 845),
      };
      final player = Offset(card.left + 12 + 40, card.bottom - 12 - 4);
      // The bar's button is all but opaque: a little of the ground shows.
      final button = Offset(back.dx - 14, back.dy);
      final before = await shot(tester);
      ListeningPrefs.memory
        ..pageBrightness = 0
        ..save();
      await tester.pumpAndSettle();
      final after = await shot(tester);
      for (final e in page.entries) {
        multiplied(rgb(before, e.value), rgb(after, e.value), const [0.3, 0.3, 0.3], e.key);
      }
      kept(rgb(before, player), rgb(after, player), 'the player');
      kept(rgb(before, button), rgb(after, button), 'the back button', give: 12);
      // Warm: blue goes most, and the bars are still as they were.
      ListeningPrefs.memory
        ..pageBrightness = null
        ..pageWarmth = 1
        ..save();
      await tester.pumpAndSettle();
      final warm = await shot(tester);
      final f = const PageLight(warmth: 1).filter;
      final beside = page['the page beside the text']!;
      multiplied(rgb(before, beside), rgb(warm, beside), [f.r, f.g, f.b], 'warmed');
      kept(rgb(before, player), rgb(warm, player), 'the player, warmed');
      await finish(tester);
    });

    testWidgets('in pages it lies over the pages, and the fades the bars stand on are drawn in it', (tester) async {
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none'
        ..pageTone = 'papyrus'
        ..pageBrightness = 0;
      await open(tester, short());
      // Opened with no library, the page takes its first change of the
      // settings for a change of layout: made here, before the bars come up.
      ListeningPrefs.memory.save();
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      // The paper's colours at the bars, as the veil leaves the paper.
      const light = PageLight(brightness: 0);
      final top = light.lit(PageTone.papyrus.paper!.first);
      final foot = light.lit(PageTone.papyrus.paper!.last);
      bool fade(List<Color> colors) => find
          .byWidgetPredicate((w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient is LinearGradient &&
              listEquals(((w.decoration as BoxDecoration).gradient! as LinearGradient).colors, colors))
          .evaluate()
          .isNotEmpty;
      expect(fade([top, top, top.withValues(alpha: 0)]), isTrue);
      expect(fade([foot.withValues(alpha: 0), foot, foot]), isTrue);
      expect(veils(tester), contains(tester.getRect(find.byType(PagedBook))));
      // Over the pages, under the bars: the player is as it was.
      final card = tester.getRect(find.byType(ReaderPlayerBar));
      final player = Offset(card.left + 12 + 40, card.bottom - 12 - 4);
      final dim = await shot(tester);
      ListeningPrefs.memory
        ..pageBrightness = null
        ..save();
      await tester.pumpAndSettle();
      final plain = await shot(tester);
      kept(rgb(plain, player), rgb(dim, player), 'the player');
      multiplied(rgb(plain, const Offset(5, 400)), rgb(dim, const Offset(5, 400)), const [0.3, 0.3, 0.3], 'the page');
      await finish(tester);
    });

    testWidgets("on a PDF's real pages too", (tester) async {
      // A page as the phone draws it: a picture, here a pale one.
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(const Color(0xFFF4F1EA), BlendMode.src);
        final image = await recorder.endRecording().toImage(8, 8);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        File('${_tmp.path}/page.jpg').writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
      ListeningPrefs.memory.pdfPages = true;
      final book = ingestPdfText(id: 'p', pages: [
        'First page text is long enough to be a real page of a book, honestly.',
        'Second page text is also long enough to count as a page of a book.',
      ]);
      await open(tester, ReadingLayout.build(book), pdf: '${_tmp.path}/b.pdf');
      final pages = tester.getRect(find.byType(PdfPagesView));
      expect(veils(tester).any((r) => r.contains(pages.center) && r.height >= pages.height - 1), isTrue);
      final at = Offset(pages.center.dx, pages.top + 40);
      final before = await shot(tester);
      ListeningPrefs.memory
        ..pageBrightness = 0
        ..save();
      await tester.pumpAndSettle();
      multiplied(rgb(before, at), rgb(await shot(tester), at), const [0.3, 0.3, 0.3], 'the real page');
      await finish(tester);
    });

    testWidgets('the veil is drawn once: the page scrolling under it does not draw it again', (tester) async {
      ListeningPrefs.memory.pageBrightness = 0;
      await open(tester, short(paragraphs: 40));
      final list = find.byType(ScrollablePositionedList);
      final text = tester.getRect(list);
      // The veil over the text: a layer of its own, holding one picture.
      final veil = find
          .byType(LightVeil)
          .evaluate()
          .firstWhere((e) => (e.widget as LightVeil).around == null && tester.getRect(find.byWidget(e.widget)).contains(text.center));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.descendant(of: find.byWidget(veil.widget), matching: find.byType(RepaintBoundary)).first);
      final picture = boundary.debugLayer!.firstChild;
      expect(picture, isA<PictureLayer>());
      Rect para() => tester.getRect(find
          .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Alpha line 3 '))
          .first);
      final was = para();
      await tester.drag(list, const Offset(0, -300));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(para().top, lessThan(was.top - 100), reason: 'the page did scroll');
      expect(identical(boundary.debugLayer!.firstChild, picture), isTrue, reason: 'the veil was not drawn again');
      // And nothing in it is drawn offscreen.
      for (final kind in [ColorFiltered, ShaderMask, BackdropFilter, Opacity]) {
        expect(find.descendant(of: find.byWidget(veil.widget), matching: find.byType(kind)), findsNothing);
      }
      await finish(tester);
    });

    testWidgets('Settings has neither: they are the page’s, set over it', (tester) async {
      phone(tester);
      late LibraryStore store;
      await tester.runAsync(() async {
        store = LibraryStore(_tmp);
        await ListeningPrefs.load(_tmp.path);
      });
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
      await tester.pumpAndSettle();
      expect(find.text('Brightness'), findsNothing);
      expect(find.text('Auto-scroll'), findsNothing);
      await finish(tester);
    });
  });

  group('auto-scroll', () {
    Finder line(String start) =>
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(start)).first;

    /// Start it from the Read tab, and let the sheet go.
    Future<void> start(WidgetTester tester, {bool settle = true}) async {
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final button = find.text('Start auto-scroll');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('reader-settings')), findsNothing, reason: 'the sheet closes onto the page');
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> run(WidgetTester tester, Duration d) async {
      for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 100)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<int> saved(WidgetTester tester, LibraryStore store, ReadingLayout layout, bool Function(int) until) async {
      var unit = 0;
      for (var i = 0; i < 100 && !until(unit); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 50));
        unit = layout.unitForCursor((await tester.runAsync(() => store.cursorFor(layout.book.id)))!, saved: true);
      }
      return unit;
    }

    testWidgets('the scroll moves steadily at its lines a minute, the bars away, the place following the eyes and saved',
        (tester) async {
      final store = LibraryStore(_tmp);
      final layout = short(paragraphs: 40);
      await open(tester, layout, store: store);
      await start(tester);
      expect(find.byTooltip('Search').hitTestable(), findsNothing, reason: 'reading alone');
      final was = tester.getRect(line('Alpha line 5 ')).top;
      await run(tester, const Duration(seconds: 4));
      // 24 lines a minute of 19 px at 1.6: 12.2 px a second.
      final went = was - tester.getRect(line('Alpha line 5 ')).top;
      expect(went, inInclusiveRange(4 * 12.16 * 0.85, 4 * 12.16 * 1.1));
      // The place is where the eyes are, saved as a scroll by hand saves
      // it, and no wash follows them about.
      await run(tester, const Duration(seconds: 8));
      expect(await saved(tester, store, layout, (u) => u > 0), greaterThan(0));
      final washed = StringBuffer();
      for (final t in tester.widgetList<RichText>(find.byType(RichText))) {
        t.text.visitChildren((s) {
          if (s is TextSpan && s.style?.backgroundColor != null) washed.write(s.text ?? '');
          return true;
        });
      }
      expect(washed.toString(), isEmpty);
      await finish(tester);
    });

    testWidgets('a touch holds it, and it goes on a moment after; the pill slows, quickens, holds and stops it',
        (tester) async {
      await open(tester, short(paragraphs: 40));
      await start(tester);
      double at() =>
          tester.getRect(line('Alpha line 4 ')).top - tester.getRect(find.byType(ScrollablePositionedList)).top;
      final g = await tester.startGesture(tester.getCenter(find.byType(ScrollablePositionedList)));
      await tester.pump(const Duration(milliseconds: 100));
      final held = at();
      await run(tester, const Duration(seconds: 2));
      expect(at(), held, reason: 'held while the finger is down');
      await g.up();
      await tester.pump();
      await run(tester, const Duration(milliseconds: 1000));
      expect(at(), held, reason: 'still a moment after');
      await run(tester, const Duration(seconds: 2));
      expect(at(), lessThan(held), reason: 'then on again');
      // That tap brought the bars, and the pill with them.
      expect(find.text('24 lines a minute').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Scroll faster'));
      await tester.pump();
      expect(find.text('27 lines a minute'), findsOneWidget);
      expect(ListeningPrefs.memory.autoScrollLines, 27);
      await tester.tap(find.byTooltip('Scroll slower'));
      await tester.pump();
      expect(ListeningPrefs.memory.autoScrollLines, 24);
      await tester.tap(find.byTooltip('Pause auto-scroll'));
      await tester.pump();
      final paused = at();
      await run(tester, const Duration(seconds: 3));
      expect(at(), paused, reason: 'held until Go on');
      await tester.tap(find.byTooltip('Go on'));
      await run(tester, const Duration(seconds: 1));
      expect(at(), lessThan(paused));
      await tester.tap(find.byTooltip('Stop auto-scroll'));
      await tester.pumpAndSettle();
      final stopped = at();
      await run(tester, const Duration(seconds: 3));
      expect(at(), stopped);
      expect(find.byType(AutoScrollPill), findsNothing);
      await finish(tester);
    });

    testWidgets('it stops as the next chapter reaches the middle of the page; Go on carries on', (tester) async {
      ListeningPrefs.memory.autoScrollLines = 90;
      await open(tester, short());
      await start(tester);
      const said = 'End of chapter: auto-scroll stopped.';
      for (var i = 0; i < 300 && find.text(said).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(said), findsOneWidget);
      // The next chapter's row (its label 56 dp below the row's top) at the
      // middle of the page.
      final page = tester.getRect(find.byType(ScrollablePositionedList));
      double next() => tester.getRect(find.text('CHAPTER 2').first).top - 56;
      final stopped = next();
      expect(stopped, closeTo(page.top + page.height / 2, 4));
      await run(tester, const Duration(seconds: 2));
      expect(next(), stopped, reason: 'stopped');
      await tester.tap(find.text('Go on'));
      await run(tester, const Duration(seconds: 2));
      expect(next(), lessThan(stopped), reason: 'on into Beta');
      await finish(tester);
    });

    testWidgets("it stops at the book's end, and says so", (tester) async {
      ListeningPrefs.memory.autoScrollLines = 90;
      final layout = short();
      await open(tester, layout, at: cursorOf(layout.units[layout.chapterFirstUnit[1]]));
      await start(tester);
      const said = 'End of the book: auto-scroll stopped.';
      for (var i = 0; i < 300 && find.text(said).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(said), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AutoScrollPill), findsNothing);
      await finish(tester);
    });

    testWidgets('never with the voice: Play stops it, and starting it stops the voice', (tester) async {
      await open(tester, short(paragraphs: 40));
      await start(tester);
      await tester.tapAt(tester.getCenter(find.byType(ScrollablePositionedList)));
      await tester.pumpAndSettle();
      expect(find.byType(AutoScrollPill), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AutoScrollPill), findsNothing, reason: 'the voice moves the page now');
      // Started again while the voice reads (the glow and the ring move:
      // no settling): the voice stops.
      await start(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byType(AutoScrollPill), findsOneWidget);
      await finish(tester);
    });

    testWidgets('in pages a page turns every so often, the place with it; it stops on the chapter’s last page',
        (tester) async {
      final store = LibraryStore(_tmp);
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none'
        ..autoPageSeconds = 5;
      final layout = short(paragraphs: 30);
      await open(tester, layout, store: store);
      final book = tester.widget<PagedBook>(find.byType(PagedBook));
      final first = book.controller.range!.$1;
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      await start(tester);
      expect(find.text('A page every 5 s').hitTestable(), findsNothing, reason: 'its pill goes with the bars');
      await run(tester, const Duration(milliseconds: 5500));
      final second = book.controller.range!.$1;
      expect(second, greaterThan(first));
      // A finger on the page holds it (moved a little, so as not to be a
      // press and hold); the place went with the page, saved.
      final g = await tester.startGesture(tester.getCenter(find.byType(PagedBook)));
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(await saved(tester, store, layout, (u) => u == second), second);
      await run(tester, const Duration(seconds: 6));
      expect(book.controller.range!.$1, second, reason: 'held while the finger is down');
      await g.up();
      const said = 'End of chapter: auto-scroll stopped.';
      for (var i = 0; i < 600 && find.text(said).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(said), findsOneWidget);
      expect(book.controller.range!.$2, layout.chapterFirstUnit[1], reason: "on Alpha's last page");
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Go on'));
      await tester.pumpAndSettle();
      expect(layout.chapterOfUnit(book.controller.range!.$1), 1, reason: 'on into Beta');
      await finish(tester);
    });

    testWidgets('with TalkBack on it never starts again by itself: a touch holds it until Go on', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await open(tester, short(paragraphs: 40));
      await start(tester);
      double at() =>
          tester.getRect(line('Alpha line 4 ')).top - tester.getRect(find.byType(ScrollablePositionedList)).top;
      final began = at();
      await run(tester, const Duration(seconds: 1));
      expect(at(), lessThan(began), reason: 'started by the reader, it goes');
      await tester.tapAt(tester.getCenter(find.byType(ScrollablePositionedList)));
      await tester.pumpAndSettle();
      final held = at();
      await run(tester, const Duration(seconds: 5));
      expect(at(), held, reason: 'not on again by itself');
      expect(find.byTooltip('Go on'), findsOneWidget);
      await tester.tap(find.byTooltip('Go on'));
      await run(tester, const Duration(seconds: 1));
      expect(at(), lessThan(held));
      await finish(tester);
    });

    test('its steps: a speed from before between them goes to the nearest; a minute and more reads as minutes', () {
      final prefs = ListeningPrefs(autoScrollLines: 25, autoPageSeconds: 31);
      final auto = AutoScroll(() => prefs);
      expect(auto.label(pages: false), '25 lines a minute');
      auto.speedUp(pages: false);
      expect(prefs.autoScrollLines, 27);
      auto.speedUp(pages: true);
      expect(prefs.autoPageSeconds, 25, reason: 'faster in pages is less time on each');
      prefs.autoPageSeconds = autoPageWaits.first;
      expect(auto.canSpeedUp(pages: true), isFalse);
      prefs.autoScrollLines = autoScrollSpeeds.last;
      expect(auto.canSpeedUp(pages: false), isFalse);
      expect(waitLabel(90), '1 min 30 s');
      expect(waitLabel(120), '2 min');
      auto.dispose();
    });
  });
}
