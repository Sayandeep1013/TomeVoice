// A PDF's real pages on a phone: each page zooms (a pinch, or two taps),
// and a pinch never turns a page; at night a dark page tone draws the page
// dark; the page keys and the taps at the sides turn its pages as they turn
// the text's; and with Crop margins each page shows only its print, every
// page one shape.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/page_crop.dart';
import 'package:tomevoice_spike/page_curl.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/pages_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/theme.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;
final _calls = <MethodCall>[];

/// Where the phone finds each page's print (fractions of the page); a page
/// not named has margins all round.
final _printsAt = <int, List<double>?>{};
const _usual = [0.12, 0.08, 0.88, 0.92];
const _letter = 612 / 792;

Rect? _printOf(int page) {
  final b = _printsAt.containsKey(page) ? _printsAt[page] : _usual;
  return b == null ? null : Rect.fromLTRB(b[0], b[1], b[2], b[3]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_pdf_pages');
    _calls.clear();
    _printsAt.clear();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
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
        'playerPosition' => 0,
        'pdfInfo' => {
            'pages': 3,
            'sizes': [612, 792, 612, 792, 612, 792],
          },
        // Never drawn in a test: the page shows its number, which says which
        // page is on screen.
        'pdfRender' => '${_tmp.path}/page.jpg',
        'pdfPrint' => [
            for (final p in (call.arguments as Map)['pages'] as List) _printsAt.containsKey(p) ? _printsAt[p] : _usual,
          ],
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

  Future<void> openPdf(WidgetTester tester, {ThemeData? theme}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    ListeningPrefs.memory.pdfPages = true;
    final book = ingestPdfText(id: 'p', pages: [
      for (var i = 1; i <= 3; i++) 'Page $i of the book has text enough to be a real page of it, honestly.',
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: ReaderScreen(layout: ReadingLayout.build(book), sourcePath: '${_tmp.path}/b.pdf'),
    ));
    await tester.pumpAndSettle();
  }

  /// Dispose the tree and let any timer run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// The volume key, as the phone sends it while the keys turn pages.
  Future<void> pageKey(WidgetTester tester, int delta) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'tomevoice/tts',
      const StandardMethodCodec().encodeMethodCall(MethodCall('platformEvent', {'type': 'pageKey', 'delta': delta})),
      (_) {},
    );
    await tester.pump();
  }

  Matrix4 zoomOf(WidgetTester tester) =>
      tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value;

  /// A finger drawn across the page in small steps, as a hand moves (a pan
  /// starts only once the finger has gone some way).
  Future<void> slide(WidgetTester tester, Offset from, Offset by) async {
    final finger = await tester.startGesture(from);
    for (var i = 0; i < 12; i++) {
      await finger.moveBy(by / 12);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.up();
    await tester.pumpAndSettle();
  }

  /// The page on screen, by the number it shows.
  String shown() => find
      .descendant(of: find.byType(PdfPagesView), matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((t) => RegExp(r'^\d+$').hasMatch(t))
      .join(',');

  for (final turn in ['curl', 'slide', 'none']) {
    testWidgets('a pinch zooms a page and turns none; zoomed, a drag moves it; two taps bring it back ($turn)',
        (tester) async {
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = turn;
      await openPdf(tester);
      expect(shown(), '1');
      final page = find.byType(InteractiveViewer);
      expect(page, findsOneWidget);
      final c = tester.getCenter(page);

      // Two fingers apart, the second moving across the page as a turn on
      // does: the page comes closer and stays.
      final a = await tester.startGesture(c + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 20));
      final b = await tester.startGesture(c - const Offset(40, 0));
      for (var i = 0; i < 6; i++) {
        await b.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(zoomOf(tester).getMaxScaleOnAxis(), greaterThan(1.5));
      expect(shown(), '1', reason: 'the pinch turned no page');

      // Zoomed in, a drag moves the page under the finger and turns nothing.
      final x = zoomOf(tester).storage[12];
      await slide(tester, c, const Offset(-150, 0));
      expect(zoomOf(tester).storage[12], lessThan(x - 50));
      expect(shown(), '1');
      // Nor does a tap at a side.
      final box = tester.getRect(page);
      await tester.tapAt(Offset(box.right - 10, box.center.dy));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(shown(), '1');

      // Two taps: the whole page again, and it turns again.
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(c);
      await tester.pumpAndSettle();
      expect(zoomOf(tester).getMaxScaleOnAxis(), closeTo(1, 0.001));
      await tester.dragFrom(c + const Offset(100, 0), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(shown(), '2');

      // Two taps in the middle come closer, there.
      final mid = tester.getCenter(find.byType(InteractiveViewer));
      await tester.tapAt(mid);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(mid);
      await tester.pumpAndSettle();
      expect(zoomOf(tester).getMaxScaleOnAxis(), greaterThan(2));
      await finish(tester);
    });
  }

  testWidgets('scrolled, a page zooms too, and holds the list still while zoomed in', (tester) async {
    await openPdf(tester);
    final first = find.byType(InteractiveViewer).first;
    final c = tester.getCenter(first);
    await tester.tapAt(c);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    expect(tester.widget<InteractiveViewer>(first).transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(2));
    final top = tester.getTopLeft(first).dy;
    final y = tester.widget<InteractiveViewer>(first).transformationController!.value.storage[13];
    // A drag up moves the page under the finger, not the list.
    await slide(tester, c, const Offset(0, -200));
    expect(tester.getTopLeft(first).dy, top);
    expect(tester.widget<InteractiveViewer>(first).transformationController!.value.storage[13], lessThan(y - 50));
    await finish(tester);
  });

  test('the dark page: white is its paper, black its ink, and a colour keeps its hue', () {
    final paper = PageTone.dusk.paper!.first;
    final ink = PageTone.dusk.ink!;
    final m = invertedPageMatrix(paper: paper, ink: ink);
    expect(m, hasLength(20));
    List<double> through(List<double> rgb) => [
          for (var r = 0; r < 3; r++)
            (m[r * 5] * rgb[0] + m[r * 5 + 1] * rgb[1] + m[r * 5 + 2] * rgb[2] + m[r * 5 + 4] / 255).clamp(0, 1),
        ];
    final white = through([1, 1, 1]);
    final black = through([0, 0, 0]);
    for (final (i, want) in [paper.r, paper.g, paper.b].indexed) {
      expect(white[i], closeTo(want, 0.002), reason: 'white turns to the paper');
    }
    for (final (i, want) in [ink.r, ink.g, ink.b].indexed) {
      expect(black[i], closeTo(want, 0.002), reason: 'black turns to the ink');
    }
    // A red figure stays red (lighter, as everything dark goes light).
    final red = through([0.7, 0.1, 0.1]);
    expect(red[0], greaterThan(red[1]));
    expect(red[0], greaterThan(red[2]));
    // Alpha is left as it is.
    expect(m.sublist(15), [0, 0, 0, 1, 0]);
  });

  testWidgets("on a dark page tone a PDF's pages are drawn in its paper and ink; on a light one, as printed",
      (tester) async {
    ListeningPrefs.memory.pageTone = 'dusk';
    await openPdf(tester);
    final inked = find.descendant(of: find.byType(PdfPagesView), matching: find.byType(ColorFiltered));
    expect(inked, findsWidgets);
    final filter = invertedPage(paper: PageTone.dusk.paper!.first, ink: PageTone.dusk.ink!);
    expect(tester.widget<ColorFiltered>(inked.first).colorFilter, filter);
    // Turned as a book, too.
    ListeningPrefs.memory
      ..pages = true
      ..save();
    await tester.pumpAndSettle();
    expect(tester.widget<ColorFiltered>(inked.first).colorFilter, filter);
    ListeningPrefs.memory
      ..pageTone = 'papyrus'
      ..save();
    await tester.pumpAndSettle();
    expect(inked, findsNothing);
    await finish(tester);
  });

  testWidgets("the app's own tone in the dark draws a PDF's pages dark too", (tester) async {
    await openPdf(tester, theme: ThemeData(brightness: Brightness.dark));
    final inked = find.descendant(of: find.byType(PdfPagesView), matching: find.byType(ColorFiltered));
    expect(inked, findsWidgets);
    final context = tester.element(find.byType(PdfPagesView));
    expect(tester.widget<ColorFiltered>(inked.first).colorFilter,
        invertedPage(paper: Skin.darkOn(context), ink: Skin.inkOn(context)));
    await finish(tester);
  });

  testWidgets("the page keys, a tap at a side and TalkBack turn a PDF's pages as they turn the text's",
      (tester) async {
    final semantics = tester.ensureSemantics();
    ListeningPrefs.memory
      ..pages = true
      ..pageTurn = 'slide'
      ..volumeKeys = true;
    await openPdf(tester);
    // With nothing read aloud, the volume keys are taken for turning.
    ListeningPrefs.memory.save();
    await tester.pumpAndSettle();
    expect(_calls.where((c) => c.method == 'volumeKeysTurnPages').last.arguments, {'on': true});
    expect(shown(), '1');
    await pageKey(tester, 1);
    await tester.pumpAndSettle();
    expect(shown(), '2');

    // A tap at the left side turns back; tapping the sides turned off, it
    // does not.
    final box = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(box.left + 10, box.center.dy));
    await tester.pumpAndSettle();
    expect(shown(), '1');
    ListeningPrefs.memory
      ..tapToTurn = false
      ..save();
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(box.right - 10, box.center.dy));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(shown(), '1');

    // TalkBack's own action.
    final book = tester.getSemantics(find.byWidgetPredicate((w) =>
        w is Semantics &&
        (w.properties.customSemanticsActions?.keys.any((a) => a.label == 'Next page') ?? false)));
    final next = CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Next page'));
    book.owner!.performAction(book.id, SemanticsAction.customAction, next);
    await tester.pumpAndSettle();
    expect(shown(), '2');

    // Set to turn at once, a key turns the page within the frame.
    ListeningPrefs.memory
      ..pageTurn = 'none'
      ..save();
    await tester.pumpAndSettle();
    await pageKey(tester, 1);
    expect(shown(), '3');
    semantics.dispose();
    await finish(tester);
  });

  group('Crop margins', () {
    /// The book's cut, as the view should find it from the three pages.
    CropPlan plan() => CropPlan.from(const [0, 1, 2], [for (var p = 0; p < 3; p++) _printOf(p)], List.filled(3, _letter))!;

    List<double> sides(Rect r) => [r.left, r.top, r.right, r.bottom];

    /// What each page was last drawn as: its pdfRender call's arguments.
    Map<int, Map<Object?, Object?>> drawn() => {
          for (final c in _calls.where((c) => c.method == 'pdfRender'))
            (c.arguments as Map)['page'] as int: c.arguments as Map,
        };

    Iterable<AspectRatio> frames(WidgetTester tester) => tester.widgetList<AspectRatio>(
        find.descendant(of: find.byType(PdfPagesView), matching: find.byType(AspectRatio)));

    testWidgets('it opens under Show the real pages in the reading settings, and is remembered', (tester) async {
      await openPdf(tester);
      await tester.tap(find.byTooltip('Reading settings'));
      await tester.pumpAndSettle();
      final crop = find.text('Crop margins');
      expect(crop, findsOneWidget);
      await tester.ensureVisible(crop);
      await tester.pumpAndSettle();
      await tester.tap(crop);
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.pdfCrop, isTrue);
      expect(ListeningPrefs.fromJson(ListeningPrefs.memory.toJson()).pdfCrop, isTrue);
      expect(ListeningPrefs.fromJson(const {}).pdfCrop, isFalse, reason: 'off unless chosen');
      // The pages behind the sheet were cut at once.
      expect(_calls.where((c) => c.method == 'pdfPrint'), isNotEmpty);
      for (final f in frames(tester)) {
        expect(f.aspectRatio, closeTo(plan().shownAspect, 1e-9));
      }
      // Text instead of the real pages: nothing to cut, so it is not offered.
      await tester.tap(find.text('Show the real pages'));
      await tester.pumpAndSettle();
      expect(find.text('Crop margins'), findsNothing);
      await finish(tester);
    });

    testWidgets("scrolled, each page shows only its print, every page one shape; one the cut cannot hold shows whole",
        (tester) async {
      // Page 2 is a picture to its edges.
      _printsAt[1] = [0, 0, 1, 1];
      ListeningPrefs.memory.pdfCrop = true;
      await openPdf(tester);
      final p = plan();
      expect(p.shownAspect, lessThan(_letter), reason: 'cut narrower than tall: the print fills the width');
      expect(frames(tester), isNotEmpty);
      for (final f in frames(tester)) {
        expect(f.aspectRatio, closeTo(p.shownAspect, 1e-9));
      }
      // Each page drawn as its own part of the page, at the width it shows.
      final pages = drawn();
      expect(pages[0]!['crop'], sides(p.cropFor(0, _printOf(0), _letter)!));
      expect(pages[1]!.containsKey('crop'), isFalse, reason: 'the picture is drawn whole');
      // The whole one sits in a cut page's place, kept whole.
      await tester.pumpAndSettle();
      final images = tester.widgetList<Image>(find.descendant(of: find.byType(PdfPagesView), matching: find.byType(Image)));
      expect(images.map((i) => i.fit), containsAll([BoxFit.fill, BoxFit.contain]));
      // Only the pages the cut was found from were looked at.
      expect(_calls.where((c) => c.method == 'pdfPrint'), hasLength(1));
      await finish(tester);
    });

    testWidgets('turned off and on again, the pages are whole and cut again, the top one kept in place',
        (tester) async {
      ListeningPrefs.memory.pdfCrop = true;
      await openPdf(tester);
      final first = find.descendant(of: find.byType(PdfPagesView), matching: find.byType(AspectRatio)).first;
      final top = tester.getTopLeft(first).dy;
      ListeningPrefs.memory
        ..pdfCrop = false
        ..save();
      await tester.pumpAndSettle();
      for (final f in frames(tester)) {
        expect(f.aspectRatio, _letter);
      }
      expect(tester.getTopLeft(first).dy, closeTo(top, 1));
      expect(drawn()[0]!.containsKey('crop'), isFalse);
      ListeningPrefs.memory
        ..pdfCrop = true
        ..save();
      await tester.pumpAndSettle();
      for (final f in frames(tester)) {
        expect(f.aspectRatio, closeTo(plan().shownAspect, 1e-9));
      }
      expect(_calls.where((c) => c.method == 'pdfPrint'), hasLength(1), reason: 'the cut is found once');
      await finish(tester);
    });

    testWidgets('turned as a book, each leaf is a cut page; the sides still turn it, and two taps zoom where tapped',
        (tester) async {
      ListeningPrefs.memory
        ..pdfCrop = true
        ..pages = true
        ..pageTurn = 'curl'
        ..pageTone = 'dusk';
      await openPdf(tester);
      final p = plan();
      final leaf = tester.getSize(find.byType(PageCurl));
      expect(leaf.width / leaf.height, closeTo(p.shownAspect, 0.01));
      // The dark tone still draws the cut page dark.
      expect(find.descendant(of: find.byType(PdfPagesView), matching: find.byType(ColorFiltered)), findsWidgets);
      expect(drawn()[0]?['crop'], sides(p.cropFor(0, _printOf(0), _letter)!));
      expect(shown(), '1');

      final box = tester.getRect(find.byType(PageCurl));
      await tester.tapAt(Offset(box.right - 10, box.center.dy));
      await tester.pumpAndSettle();
      expect(shown(), '2');
      expect(drawn()[1]?['crop'], sides(p.cropFor(1, _printOf(1), _letter)!));
      expect(p.cropFor(1, _printOf(1), _letter)!.left, closeTo(p.odd.left, 1e-9), reason: 'an odd page by its own box');

      // Two taps zoom in on the point tapped: it stays under the finger.
      final at = box.center + const Offset(20, -40);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      final view = find.byType(InteractiveViewer);
      final zoom = zoomOf(tester);
      expect(zoom.getMaxScaleOnAxis(), greaterThan(2));
      final local = at - tester.getTopLeft(view);
      final moved = MatrixUtils.transformPoint(zoom, local);
      expect((moved - local).distance, lessThan(1));
      await finish(tester);
    });
  });
}
