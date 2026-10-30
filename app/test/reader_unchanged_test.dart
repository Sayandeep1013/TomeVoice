// The reader as it stood before it was taken apart into a controller, one
// page style and widgets of their own: where a book opens and the place it
// saves, the page's type and colours on the scroll and in pages, the player
// and Now Playing, the bars, a press and hold, search and the way back, the
// sleep timer and a book's own speed, the card in the notification shade and
// the headset's buttons, a PDF's real pages, a turn of the phone or a new
// size, TalkBack, the fades at the text's edges, and the page keys. Taking
// reader_screen.dart apart changes none of these.
//
// The page's look below (lookOf) is the reader's own code for it as it
// stood before, copied here so it cannot drift with the code it pins.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/now_playing.dart';
import 'package:tomevoice_spike/page_curl.dart';
import 'package:tomevoice_spike/page_tone.dart';
import 'package:tomevoice_spike/paged_view.dart';
import 'package:tomevoice_spike/pages_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/rules_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/stats.dart';
import 'package:tomevoice_spike/theme.dart';
import 'package:tomevoice_spike/ui.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;
final _calls = <MethodCall>[];

/// The player the tests steer: where its head is, and what it was given.
var _head = 0;
var _queued = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final blank = String.fromCharCodes([10, 10]);

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_reader_unchanged');
    _calls.clear();
    _head = 0;
    _queued = 0;
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
        // Each sentence a moment of silence; the head stays where the test
        // puts it, so a sentence is being heard for as long as it needs.
        'synthesise' => () {
            final f = File('${_tmp.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
            return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
          }(),
        'playerEnqueue' => () {
            final start = _queued;
            _queued += ((call.arguments as Map)['pcm'] as Uint8List).length ~/ 2;
            return start;
          }(),
        'playerStop' => () {
            _queued = 0;
            _head = 0;
            return null;
          }(),
        'playerPosition' => _head,
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

  void phone(WidgetTester tester, {bool onItsSide = false}) {
    tester.view.physicalSize = onItsSide ? const Size(2340, 1080) : const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  /// Dispose the tree and let any snack bar or timer run out.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// Two chapters of sentences each with words of its own ("Paragraph 3
  /// sentence 7 ..."), long enough to scroll and to fill several pages.
  String numberedText({int paragraphs = 8}) {
    String para(int p) => [for (var s = 0; s < 10; s++) 'Paragraph $p sentence $s runs on for a while here.'].join(' ');
    return [
      '# Alpha',
      for (var p = 0; p < paragraphs; p++) para(p),
      '# Beta',
      for (var p = paragraphs; p < 2 * paragraphs; p++) para(p),
    ].join(blank);
  }

  ReadingLayout numbered({int paragraphs = 8}) =>
      ReadingLayout.build(ingestString(numberedText(paragraphs: paragraphs), filename: 'numbered.md', title: 'Numbered'));

  Future<void> open(WidgetTester tester, ReadingLayout layout,
      {ReadingCursor at = ReadingCursor.zero, LibraryStore? store, ThemeData? theme, bool onItsSide = false}) async {
    phone(tester, onItsSide: onItsSide);
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: ReaderScreen(layout: layout, initialCursor: at, store: store),
    ));
    await tester.pumpAndSettle();
  }

  /// A shelf to open a book from, and come back to.
  Future<NavigatorState> shelf(WidgetTester tester) async {
    phone(tester);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Scaffold(body: Text('Shelf'))));
    return nav.currentState!;
  }

  /// Text of every span drawn with a background wash: the place.
  String washed(WidgetTester tester) {
    final out = StringBuffer();
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      t.textSpan?.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null) out.write(span.text ?? '');
        return true;
      });
    }
    return out.toString();
  }

  /// The colour behind the place on the scroll.
  Color? washColour(WidgetTester tester) {
    Color? found;
    for (final t in tester.widgetList<RichText>(find.byType(RichText))) {
      t.text.visitChildren((s) {
        if (s is TextSpan && s.style?.backgroundColor != null) found ??= s.style!.backgroundColor;
        return true;
      });
    }
    return found;
  }

  PagedBook book(WidgetTester tester) => tester.widget<PagedBook>(find.byType(PagedBook));

  /// The sentences on the page (or pages) shown.
  (int, int) onPage(WidgetTester tester) => book(tester).controller.range!;

  bool holds(WidgetTester tester, int unit) {
    final (first, end) = onPage(tester);
    return first <= unit && unit < end;
  }

  Future<void> turnOn(WidgetTester tester, {int pages = 1}) async {
    final box = tester.getRect(find.byType(PagedBook));
    for (var i = 0; i < pages; i++) {
      await tester.tapAt(Offset(box.right - 20, box.center.dy));
      await tester.pumpAndSettle();
    }
  }

  /// A platform event, as the phone sends one.
  Future<void> event(WidgetTester tester, Map<String, Object?> e) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'tomevoice/tts',
      const StandardMethodCodec().encodeMethodCall(MethodCall('platformEvent', e)),
      (_) {},
    );
    await tester.pump();
  }

  /// Let real IO and isolates (the render after each sentence) run, a frame
  /// between, until [until] holds.
  Future<void> io(WidgetTester tester, bool Function() until) async {
    for (var i = 0; i < 80 && !until(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> playing(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await io(tester, () => _calls.any((c) => c.method == 'playerEnqueue'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Pause'), findsOneWidget);
  }

  List<Map<Object?, Object?>> sessions() => [
        for (final c in _calls)
          if (c.method == 'session') c.arguments as Map,
      ];

  bool? lastOn(String method) =>
      (_calls.where((c) => c.method == method).lastOrNull?.arguments as Map?)?['on'] as bool?;

  /// The place saved in [store], once its writing is done: each test here
  /// saves a place past the book's start, once, and a busy phone (or test
  /// machine) can take a while to write it.
  Future<int> saved(WidgetTester tester, LibraryStore store, ReadingLayout layout) async {
    var unit = 0;
    for (var i = 0; i < 200 && unit == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
      final cursor = (await tester.runAsync(() => store.cursorFor(layout.book.id)))!;
      unit = layout.unitForCursor(cursor, saved: true);
    }
    return unit;
  }

  /// A match in the search sheet, to tap.
  Finder match(String text) => find
      .descendant(
        of: find.byType(BottomSheet),
        matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(text)),
      )
      .first;

  /// How long [words] take at [speed]: the 165 words a minute the player
  /// and the card count in.
  int msFor(int words, {double speed = 1}) => (words / (165 * speed) * 60000).round();

  /// The sheet with the speed, the sleep timer and the voice: [label] picked
  /// in its sleep timer.
  Future<void> sleepChoice(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Voice'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Sleep timer'))).pop();
    await tester.pumpAndSettle();
  }

  group('where a book opens, and the place it saves', () {
    testWidgets('it opens at the place saved: washed on the scroll, on the page shown in pages', (tester) async {
      final layout = numbered();
      final k = layout.chapterFirstUnit[1] + 25;
      await open(tester, layout, at: cursorOf(layout.units[k]));
      expect(washed(tester), startsWith(layout.units[k].text));
      expect(find.textContaining('2/2'), findsOneWidget);
      await finish(tester);

      ListeningPrefs.memory.pages = true;
      await open(tester, layout, at: cursorOf(layout.units[k]));
      expect(book(tester).startUnit, k);
      expect(book(tester).marked.value, k);
      expect(holds(tester, k), isTrue, reason: 'the page shown holds the place');
      expect(find.textContaining('2/2'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a book opened from the library opens where it was left', (tester) async {
      phone(tester);
      final store = LibraryStore(_tmp);
      late LibraryEntry entry;
      late ReadingLayout layout;
      await tester.runAsync(() async {
        final f = File('${_tmp.path}/incoming/story.md')
          ..createSync(recursive: true)
          ..writeAsStringSync(numberedText());
        entry = await store.importFile(PickedFile(path: f.path, name: 'story.md'));
        layout = await store.loadLayout(entry.id);
        await store.saveCursor(entry.id, cursorOf(layout.units[30]), 0.3, where: 'Alpha');
      });
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Scaffold(body: Text('Shelf'))));
      unawaited(openBook(nav.currentContext!, store, entry));
      for (var i = 0; i < 60 && find.byType(ReaderScreen).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(washed(tester), startsWith(layout.units[30].text));
      await finish(tester);
    });

    testWidgets('read on by scrolling, the place is where the eyes are, and is saved there', (tester) async {
      final store = LibraryStore(_tmp);
      final layout = numbered();
      await open(tester, layout, store: store);
      final list = find.byType(ScrollablePositionedList);
      await tester.drag(list, const Offset(0, -900));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 2));
      final at = await saved(tester, store, layout);
      expect(at, greaterThan(0));
      // The sentence that crosses a line just under the top of the text.
      final area = tester.getRect(list);
      final line = area.top + area.height * 0.12;
      final paragraph = tester.getRect(find
          .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(layout.units[at].text))
          .first);
      expect(paragraph.top <= line && paragraph.bottom > line, isTrue, reason: 'paragraph at $paragraph, line at $line');
      expect(washed(tester), isEmpty, reason: 'the wash does not follow the eyes about');
      await finish(tester);
    });

    testWidgets('Back saves the place, even straight after it moved', (tester) async {
      final store = LibraryStore(_tmp);
      final layout = numbered();
      final nav = await shelf(tester);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(layout: layout, store: store))));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('Next sentence'));
        await tester.pump();
      }
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Shelf'), findsOneWidget);
      expect(await saved(tester, store, layout), 3);
      await finish(tester);
    });

    testWidgets('in pages, a page turned by hand takes the place with it, saved; Play reads from there',
        (tester) async {
      final store = LibraryStore(_tmp);
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none';
      final layout = numbered();
      await open(tester, layout, store: store);
      await turnOn(tester, pages: 2);
      final (first, _) = onPage(tester);
      expect(first, greaterThan(0));
      await tester.pump(const Duration(seconds: 2));
      expect(await saved(tester, store, layout), first);
      expect(book(tester).marked.value, -1, reason: 'the wash does not follow the page');
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(book(tester).marked.value, first);
      await finish(tester);
    });

    testWidgets("the book's Contents: parts as dividers, the chapter read marked, found by its number or words",
        (tester) async {
      final layout = ReadingLayout.build(ingestString(
        [
          '# Part One: Arrival',
          'The part begins with a sentence or two of its own here.',
          '# The Road',
          'A chapter of the road, long enough to be read.',
          '# The River',
          'A chapter of the river, long enough to be read.',
        ].join(blank),
        filename: 'parts.md',
        title: 'Parts',
      ));
      await open(tester, layout, at: cursorOf(layout.units[layout.chapterFirstUnit[1]]));
      await tester.tap(find.byKey(const ValueKey('contents')));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      Finder inSheet(Finder f) => find.descendant(of: sheet, matching: f);
      expect(inSheet(find.text('Contents')), findsOneWidget);
      expect(inSheet(find.text('3 CHAPTERS')), findsOneWidget);
      expect(inSheet(find.text('Find a chapter')), findsOneWidget);
      // A part reads as a divider, in capitals and the soft ink.
      final part = tester.widget<Text>(inSheet(find.text('PART ONE: ARRIVAL')));
      expect(part.style!.color, Skin.inkSoftOn(tester.element(find.byType(ReaderScreen))));
      // The chapter being read, in the accent as type (its ink, which reads
      // on the sheet: the full accent was too pale there by day), with the
      // voice's sign.
      final ink = Skin.accentInkOf(tester.element(find.byType(ReaderScreen)));
      final road = tester.widget<Text>(inSheet(find.text('The Road')));
      expect(road.style!.color, ink);
      expect(tester.widget<Text>(inSheet(find.text('2'))).style!.color, ink);
      expect(tester.widget<Icon>(inSheet(find.byIcon(Icons.graphic_eq_rounded))).color, ink);
      // The numbers in a column for short ones.
      expect(tester.getSize(find.ancestor(of: inSheet(find.text('2')), matching: find.byType(SizedBox)).first).width, 40);
      // A drag down the list leaves the keyboard as it is.
      expect(tester.widget<ListView>(inSheet(find.byType(ListView))).keyboardDismissBehavior,
          isNot(ScrollViewKeyboardDismissBehavior.onDrag));
      // Found by its number, or by words of its title.
      await tester.enterText(inSheet(find.byType(TextField)), '3');
      await tester.pumpAndSettle();
      expect(inSheet(find.text('The River')), findsOneWidget);
      expect(inSheet(find.text('The Road')), findsNothing);
      await tester.enterText(inSheet(find.byType(TextField)), 'road');
      await tester.pumpAndSettle();
      expect(inSheet(find.text('The Road')), findsOneWidget);
      expect(inSheet(find.text('The River')), findsNothing);
      await tester.enterText(inSheet(find.byType(TextField)), 'nothing like it');
      await tester.pumpAndSettle();
      expect(inSheet(find.text('No chapters match.')), findsOneWidget);
      await tester.enterText(inSheet(find.byType(TextField)), '');
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.text('The River')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(washed(tester), startsWith('The River'));
      expect(find.text('Back to where you were'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a jump leaves a way back to where the reading was; Stay here keeps the new place', (tester) async {
      await open(tester, numbered());
      await tester.tap(find.byKey(const ValueKey('contents')));
      await tester.pumpAndSettle();
      expect(find.text('Find a chapter'), findsOneWidget);
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();
      expect(find.text('Back to where you were'), findsOneWidget);
      await tester.tap(find.byTooltip('Stay here'));
      await tester.pumpAndSettle();
      expect(find.text('Back to where you were'), findsNothing);
      expect(washed(tester), startsWith('Beta'));
      expect(find.textContaining('2/2'), findsOneWidget);
      await finish(tester);
    });
  });

  group('the page looks the same in every view', () {
    /// The page's look as the reader built it before (its _pageLook).
    PageLook lookOf(BuildContext context, ListeningPrefs p) {
      final scale = p.textSize / 19;
      final tone = PageTone.byId(p.pageTone);
      final ink = tone.inkOf(context);
      final accent = tone.accentOf(context);
      return PageLook(
        text: Skin.page(context, size: p.textSize, font: p.bookFont, height: p.lineHeight).copyWith(color: ink),
        heading: Skin.title(context, size: 22 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: ink),
        chapterHeading:
            Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: accent),
        title: Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(color: accent),
        label: Skin.meta(context, size: 11, color: accent).copyWith(fontWeight: FontWeight.w600),
        status: Skin.meta(context, size: 10, color: tone.inkSoft),
        accent: accent,
        sentenceWash: tone.isApp ? Skin.sentenceWash(context) : accent.withValues(alpha: tone.dark ? 0.22 : 0.16),
        wordWash: tone.isApp ? Skin.wordWash(context) : accent.withValues(alpha: tone.dark ? 0.5 : 0.36),
        textScaler: MediaQuery.textScalerOf(context),
        justify: p.justify,
        indent: p.indent,
        margin: p.margin,
      );
    }

    bool hasFade(WidgetTester tester, List<Color> colors) => find
        .descendant(
          of: find.byType(ReaderScreen),
          matching: find.byWidgetPredicate((w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient is LinearGradient &&
              listEquals(((w.decoration as BoxDecoration).gradient! as LinearGradient).colors, colors)),
        )
        .evaluate()
        .isNotEmpty;

    testWidgets("the scroll and pages are set alike, in the page tone's ink, paper and accent", (tester) async {
      for (final (tone, brightness) in [
        (PageTone.app, Brightness.light),
        (PageTone.app, Brightness.dark),
        (PageTone.papyrus, Brightness.dark),
        (PageTone.eink, Brightness.light),
        (PageTone.dusk, Brightness.light),
      ]) {
        final why = '${tone.id} on a ${brightness.name} phone';
        ListeningPrefs.memory
          ..pages = false
          ..pageTone = tone.id
          ..textSize = 21
          ..lineHeight = 1.7;
        phone(tester);
        await tester.pumpWidget(MaterialApp(
          key: ValueKey(why),
          theme: ThemeData(useMaterial3: true, brightness: brightness),
          home: ReaderScreen(layout: numbered()),
        ));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(ReaderScreen));
        final look = lookOf(context, ListeningPrefs.memory);
        final dark = tone.dark || (tone.isApp && Skin.isDark(context));

        // The scroll.
        TextStyle styleOf(String start) => (tester
                .widget<RichText>(find
                    .byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(start))
                    .first)
                .text as TextSpan)
            .style!;
        final body = styleOf('Paragraph 0 sentence 0');
        expect(body.color, look.text.color, reason: why);
        expect(body.fontFamily, look.text.fontFamily, reason: why);
        expect(body.fontSize, look.text.fontSize, reason: why);
        expect(body.height, look.text.height, reason: why);
        expect(body.letterSpacing, look.text.letterSpacing, reason: why);
        final heading = styleOf('Alpha');
        expect(heading.color, look.chapterHeading.color, reason: why);
        expect(heading.fontSize, look.chapterHeading.fontSize, reason: why);
        expect(tester.widget<Text>(find.text('CHAPTER 1').first).style, look.label, reason: why);
        expect(washColour(tester), look.sentenceWash, reason: why);
        // The top bar in the tone's ink, the ground in its paper, and the
        // phone's bars drawn to suit it.
        final bar = find.byKey(const ValueKey('contents'));
        expect(tester.widget<Text>(find.descendant(of: bar, matching: find.text('Numbered'))).style!.color,
            tone.ink ?? Skin.inkOn(context),
            reason: why);
        expect(tester.widget<Text>(find.descendant(of: bar, matching: find.text('ALPHA'))).style!.color,
            tone.inkSoft ?? Skin.inkFaintOn(context),
            reason: why);
        final ground = tester.widget<PageGround>(find.byType(PageGround).first);
        expect(ground.tone, tone, reason: why);
        expect(ground.vignette, isTrue, reason: why);
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find
            .descendant(
              of: find.byType(ReaderScreen),
              matching: find.byWidgetPredicate((w) => w is AnnotatedRegion<SystemUiOverlayStyle>),
            )
            .first);
        expect(region.value.statusBarIconBrightness, dark ? Brightness.light : Brightness.dark, reason: why);
        expect(region.value.systemNavigationBarIconBrightness, dark ? Brightness.light : Brightness.dark, reason: why);

        // Pages: the same look.
        ListeningPrefs.memory
          ..pages = true
          ..save();
        await tester.pumpAndSettle();
        final paged = book(tester);
        expect(paged.look.text, look.text, reason: why);
        expect(paged.look.heading, look.heading, reason: why);
        expect(paged.look.chapterHeading, look.chapterHeading, reason: why);
        expect(paged.look.title, look.title, reason: why);
        expect(paged.look.label, look.label, reason: why);
        expect(paged.look.status, look.status, reason: why);
        expect(paged.look.accent, look.accent, reason: why);
        expect(paged.look.sentenceWash, look.sentenceWash, reason: why);
        expect(paged.look.wordWash, look.wordWash, reason: why);
        expect(paged.look.textScaler, look.textScaler, reason: why);
        expect(paged.look.justify, look.justify, reason: why);
        expect(paged.look.indent, look.indent, reason: why);
        expect(paged.look.margin, look.margin, reason: why);
        expect(paged.paper, tone.paperOf(context), reason: why);
        expect(paged.crease, dark ? Colors.black : tone.inkOf(context), reason: why);
        expect(tester.widget<PageGround>(find.byType(PageGround).first).vignette, isFalse, reason: why);
        // The bars over the pages fade into the paper, top and foot.
        final top = tone.paper?.first ?? Skin.ground(context).colors.first;
        final foot = tone.paper?.last ?? Skin.groundFoot(context);
        expect(hasFade(tester, [top, top, top.withValues(alpha: 0)]), isTrue, reason: why);
        expect(hasFade(tester, [foot.withValues(alpha: 0), foot, foot]), isTrue, reason: why);
      }
      await finish(tester);
    });

    testWidgets("on its side, the scroll fades into the page's paper before the dock", (tester) async {
      // Changed on purpose: it faded into the app's ground whatever the
      // tone, a band across the foot of Papyrus, Ink and Dusk.
      for (final tone in [PageTone.app, PageTone.papyrus, PageTone.eink, PageTone.dusk]) {
        ListeningPrefs.memory.pageTone = tone.id;
        await open(tester, numbered(), onItsSide: true);
        final foot = tone.paper?.last ?? Skin.groundFoot(tester.element(find.byType(ReaderScreen)));
        expect(hasFade(tester, [foot.withValues(alpha: 0), foot]), isTrue, reason: tone.id);
        await finish(tester);
      }
    });

    testWidgets("Now Playing sets the book in the reader's text size, in its own face, white", (tester) async {
      ListeningPrefs.memory
        ..textSize = 24
        ..bookFont = BookFont.literata
        ..lineHeight = 1.8
        ..pageTone = 'papyrus';
      await open(tester, ReadingLayout.build(specimenBook()));
      await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      final now = find.byType(NowPlayingScreen);
      final text = tester.widget<Text>(find.descendant(of: now, matching: find.textContaining('quick brown fox')).first);
      expect(text.style,
          TextStyle(fontFamily: 'Newsreader', fontSize: 24, height: 1.5, color: Colors.white.withValues(alpha: 0.4)));
      await finish(tester);
    });
  });

  group('the player and Now Playing', () {
    String barLine(ReadingLayout l, int u, {double speed = 1}) {
      final minutes = ((l.totalWords - l.wordsBefore[u]) / (165 * speed)).round();
      final pct = (progressFraction(l.units, u) * 100).round();
      return '$pct%  ·  ${minutes}M LEFT';
    }

    testWidgets('the player says how far through and how long is left; its buttons move the place', (tester) async {
      final layout = numbered();
      await open(tester, layout);
      String line() => tester.widget<Text>(find.textContaining('LEFT')).data!;
      VoidCallback? button(String tip) =>
          tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton))).onPressed;
      expect(line(), barLine(layout, 0));
      expect(find.text('1×'), findsOneWidget);
      expect(find.text('EN · UK'), findsOneWidget);
      expect(button('Previous chapter'), isNull);
      expect(button('Previous sentence'), isNull);

      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith(layout.units[1].text));
      expect(line(), barLine(layout, 1));
      await tester.tap(find.byTooltip('Previous sentence'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Alpha'));

      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Beta'));
      expect(line(), barLine(layout, layout.chapterFirstUnit[1]));
      expect(button('Next chapter'), isNull, reason: 'the last chapter');
      await tester.tap(find.byTooltip('Previous chapter'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Alpha'));
      await finish(tester);
    });

    testWidgets('Now Playing reads with the same place: its buttons move it, and it closes on it', (tester) async {
      final layout = numbered();
      await open(tester, layout);
      await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      final now = find.byType(NowPlayingScreen);
      expect(find.descendant(of: now, matching: find.text('NOW READING')), findsOneWidget);
      // The title, and the plain cover drawn for a book without a picture.
      expect(find.descendant(of: now, matching: find.text('Numbered')), findsNWidgets(2));
      expect(find.descendant(of: now, matching: find.text('ALPHA')), findsOneWidget);
      await tester.tap(find.descendant(of: now, matching: find.byTooltip('Next sentence')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: now, matching: find.byTooltip('Next chapter')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: now, matching: find.text('BETA')), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(washed(tester), startsWith('Beta'));
      expect(find.textContaining('2/2'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("the listening sheet's reading rules are the book's own, by its title", (tester) async {
      final layout = numbered();
      await open(tester, layout);
      await tester.tap(find.byTooltip('Voice'));
      await tester.pumpAndSettle();
      final sheet = find.descendant(of: find.byKey(const Key('reader-settings')), matching: find.byType(Scrollable)).first;
      final rules = find.byIcon(Icons.rule_rounded);
      await tester.scrollUntilVisible(rules, 300, scrollable: sheet);
      await tester.pumpAndSettle();
      await tester.tap(rules);
      await tester.pumpAndSettle();
      final screen = tester.widget<RulesScreen>(find.byType(RulesScreen));
      expect(screen.bookId, layout.book.id);
      expect(screen.bookTitle, 'Numbered');
      await finish(tester);
    });

    testWidgets('in pages, the player comes up with the bars and opens Now Playing', (tester) async {
      ListeningPrefs.memory.pages = true;
      await open(tester, numbered());
      expect(find.byTooltip('Play').hitTestable(), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Play').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Search').hitTestable(), findsOneWidget);
      await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      expect(find.text('NOW READING'), findsOneWidget);
      await finish(tester);
    });
  });

  group('bars, a press and hold, and search', () {
    testWidgets('a tap on the scrolling text puts the bars away and another brings them back; '
        'a tap that stops a fling only stops it', (tester) async {
      await open(tester, numbered());
      final list = find.byType(ScrollablePositionedList);
      void shown(bool on) {
        expect(find.byTooltip('Search').hitTestable(), on ? findsOneWidget : findsNothing);
        expect(find.byTooltip('Play').hitTestable(), on ? findsOneWidget : findsNothing);
      }

      shown(true);
      await tester.tapAt(tester.getRect(list).center);
      await tester.pumpAndSettle();
      shown(false);
      await tester.tapAt(tester.getRect(list).center);
      await tester.pumpAndSettle();
      shown(true);

      await tester.fling(list, const Offset(0, -500), 2500);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(tester.getRect(list).center);
      await tester.pumpAndSettle();
      shown(true);
      await finish(tester);
    });

    testWidgets("in pages, press and hold offers the sentence's actions, and Read from here reads it",
        (tester) async {
      ListeningPrefs.memory.pages = true;
      await open(tester, numbered());
      await tester.longPressAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      for (final action in [
        'Read from here',
        'Save as a quote',
        'Share as a picture',
        'Bookmark here',
        'Copy',
        'Save as audio…',
        'Translate',
      ]) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      expect(find.textContaining(RegExp('^Look up "')), findsOneWidget);
      expect(find.textContaining(RegExp('^Fix how "')), findsOneWidget);
      await tester.tap(find.text('Read from here'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(holds(tester, book(tester).marked.value), isTrue, reason: 'the sentence held, on this page');
      expect(find.byTooltip('Pause'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a search match is shown and stepped through; Back puts the matches away, then the way back is there',
        (tester) async {
      await open(tester, numbered());
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'sentence 7 runs');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(match('sentence 7 runs'));
      await tester.pumpAndSettle();
      expect(find.text('“sentence 7 runs”  1 of 8'), findsOneWidget);
      expect(washed(tester), startsWith('Paragraph 0 sentence 7'));
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.text('“sentence 7 runs”  2 of 8'), findsOneWidget);
      expect(washed(tester), startsWith('Paragraph 1 sentence 7'));
      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('“sentence 7 runs”  1 of 8'), findsOneWidget);

      // Back puts the matches away before it leaves the book.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining(' of 8'), findsNothing);
      expect(find.byType(ReaderScreen), findsOneWidget);
      // The jump to the first match left the way back.
      await tester.tap(find.text('Back to where you were'));
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Alpha'));
      expect(find.text('Back to where you were'), findsNothing);
      await finish(tester);
    });

    testWidgets('Done puts the matches away', (tester) async {
      await open(tester, numbered());
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'sentence 3 runs');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(match('sentence 3 runs'));
      await tester.pumpAndSettle();
      expect(find.textContaining(' of 8'), findsOneWidget);
      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(find.textContaining(' of 8'), findsNothing);
      expect(find.text('Back to where you were'), findsOneWidget);
      await finish(tester);
    });
  });

  group('the sleep timer and the speed', () {
    testWidgets('a sleep timer counts down on the player, says when it pauses, and goes when turned off',
        (tester) async {
      await open(tester, numbered());
      await sleepChoice(tester, '15 min');
      expect(find.textContaining('SLEEP 15M'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing, reason: 'no room for how far through as well');
      // (The minutes left are counted by the clock on the wall, which a test
      // does not move: only the timer's own time passes here.)
      await tester.pump(const Duration(seconds: 61));
      expect(find.textContaining('SLEEP 15M'), findsOneWidget);
      await sleepChoice(tester, 'Off');
      expect(find.textContaining('SLEEP'), findsNothing);
      await sleepChoice(tester, '15 min');
      await tester.pump(const Duration(minutes: 15));
      await tester.pump();
      expect(find.text('Sleep timer: paused.'), findsOneWidget);
      expect(find.textContaining('SLEEP'), findsNothing);
      await finish(tester);
    });

    testWidgets("set to the chapter's end, it pauses as the next chapter begins", (tester) async {
      await open(tester, numbered());
      await sleepChoice(tester, 'Chapter');
      expect(find.textContaining('SLEEP AT CHAPTER END'), findsOneWidget);
      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SLEEP AT CHAPTER END'), findsOneWidget, reason: 'still in the chapter');
      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pumpAndSettle();
      expect(find.text('End of chapter: paused.'), findsOneWidget);
      expect(find.textContaining('SLEEP'), findsNothing);
      await finish(tester);
    });

    testWidgets('the sleep timer while reading aloud: the player shows it, and Now Playing too', (tester) async {
      await open(tester, ReadingLayout.build(specimenBook()));
      await playing(tester);
      await sleepChoice(tester, '30 min');
      expect(find.textContaining('SLEEP 30M'), findsOneWidget);
      await tester.fling(find.byTooltip('Speed'), const Offset(0, -300), 1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final now = find.byType(NowPlayingScreen);
      expect(find.descendant(of: now, matching: find.textContaining('SLEEP 30M')), findsOneWidget);
      expect(find.descendant(of: now, matching: find.text('Sleep on')), findsOneWidget);
      await finish(tester);
    });

    testWidgets("a book's own speed shows on the player, counts its time, and goes to the card", (tester) async {
      final layout = numbered();
      ListeningPrefs.memory
        ..setOwnSpeed(layout.book.id, true)
        ..setSpeed(1.5, book: layout.book.id);
      expect(ListeningPrefs.memory.settings.speedScale, 1.0);
      await open(tester, layout);
      expect(find.text('1.5×'), findsOneWidget);
      final minutes = (layout.totalWords / (165 * 1.5)).round();
      expect(find.textContaining('${minutes}M LEFT'), findsOneWidget);
      await playing(tester);
      expect(sessions().last['speed'], 1.5);
      expect(sessions().last['durationMs'], msFor(layout.wordsBefore[layout.chapterFirstUnit[1]], speed: 1.5));
      await finish(tester);
    });
  });

  group('the card and the headset', () {
    testWidgets('the card names the book and the chapter, says where it is, and follows play and pause',
        (tester) async {
      final layout = numbered();
      await open(tester, layout);
      expect(sessions(), isEmpty, reason: 'no card for a book not read aloud');
      await playing(tester);
      var s = sessions().last;
      expect(s['active'], isTrue);
      expect(s['title'], 'Numbered');
      expect(s['subtitle'], 'Alpha');
      expect(s['playing'], isTrue);
      expect(s['cover'], isNull);
      // Changed on purpose: it went without the book, which the reading in
      // the background names (see the test after this one).
      expect(s['book'], layout.book.id);
      expect(s['speed'], 1.0);
      expect(s['positionMs'], 0);
      final chapterEnd = layout.chapterFirstUnit[1];
      expect(s['durationMs'], msFor(layout.wordsBefore[chapterEnd]));

      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sessions().last['positionMs'], msFor(layout.wordsBefore[1]));

      // In the next chapter, the card names it and counts from its start.
      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pump(const Duration(milliseconds: 100));
      s = sessions().last;
      expect(s['subtitle'], 'Beta');
      expect(s['playing'], isTrue);
      expect(s['positionMs'], 0);
      expect(s['durationMs'], msFor(layout.totalWords - layout.wordsBefore[chapterEnd]));

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(milliseconds: 100));
      s = sessions().last;
      expect(s['active'], isTrue);
      expect(s['playing'], isFalse);

      // The player's own buttons, paused, move the place and end the
      // reading: the card goes (the card's own buttons keep it, below).
      final before = sessions().length;
      await tester.tap(find.byTooltip('Previous chapter'));
      await tester.pump(const Duration(milliseconds: 100));
      final after = sessions().sublist(before);
      expect(after.first['subtitle'], 'Alpha');
      expect(after.first['playing'], isFalse);
      expect(after.last['active'], isFalse);
      expect(find.byTooltip('Play'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("the card names the book being read, as the background's does, unless it is on a secret shelf",
        (tester) async {
      // A Play from outside the app (Android Auto, a spoken request) for
      // the book on the card is the card's own Play; one for another book
      // starts that book. Without the book, the page's own was taken for
      // another, and started again from outside.
      final store = LibraryStore(_tmp);
      late LibraryEntry entry;
      late ReadingLayout layout;
      await tester.runAsync(() async {
        final f = File('${_tmp.path}/incoming/story.md')
          ..createSync(recursive: true)
          ..writeAsStringSync(numberedText());
        entry = await store.importFile(PickedFile(path: f.path, name: 'story.md'));
        layout = await store.loadLayout(entry.id);
      });
      await open(tester, layout, store: store);
      await playing(tester);
      expect(sessions().last['book'], entry.id);
      expect(sessions().last['title'], layout.book.metadata.title);

      await tester.runAsync(() async {
        final secret = await store.addCategory('Secret', secret: true);
        await store.moveBooks({entry.id}, secret.id);
      });
      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pump(const Duration(milliseconds: 100));
      final s = sessions().last;
      expect(s['active'], isTrue);
      expect(s['title'], 'TomeVoice', reason: 'not named on the lock screen');
      expect(s['book'], isNull, reason: 'nor played from outside the app');
      await finish(tester);
    });

    testWidgets("the card's stop ends the reading and takes the card away", (tester) async {
      await open(tester, numbered());
      await playing(tester);
      expect(sessions().last['active'], isTrue);
      await event(tester, {'type': 'action', 'action': 'stop'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(sessions().last['active'], isFalse);
      expect(find.byTooltip('Play'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("the card's buttons: next and previous, seek, speed and save", (tester) async {
      final layout = numbered();
      await open(tester, layout);
      await event(tester, {'type': 'action', 'action': 'next'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith(layout.units[1].text));
      await event(tester, {'type': 'action', 'action': 'prev'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Alpha'));

      // Seek: the sentence that far into the chapter, at 165 words a minute.
      const ms = 20000;
      const target = ms / 60000 * 165;
      var u = 0;
      while (u + 1 < layout.chapterFirstUnit[1] && layout.wordsBefore[u + 1] <= target) {
        u++;
      }
      expect(u, greaterThan(1));
      await event(tester, {'type': 'action', 'action': 'seek', 'value': ms});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith(layout.units[u].text));

      await event(tester, {'type': 'action', 'action': 'speed'});
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.speedFor(layout.book.id), 1.25);
      expect(ListeningPrefs.memory.settings.speedScale, 1.25, reason: "everyone's: the book has none of its own");
      expect(find.text('1.25×'), findsOneWidget);
      // 1.5, 2, then round to the slowest after the fastest.
      for (var i = 0; i < 3; i++) {
        await event(tester, {'type': 'action', 'action': 'speed'});
      }
      expect(ListeningPrefs.memory.speedFor(layout.book.id), 0.75);

      await event(tester, {'type': 'action', 'action': 'save'});
      await tester.pumpAndSettle();
      final marks = MarkStore.instance.forBook(layout.book.id);
      expect(marks, hasLength(1));
      expect(marks.single.kind, MarkKind.quote);
      expect(marks.single.text, layout.units[u].text);
      expect(find.text('Saved to your quotes.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('set to skip 30 seconds, the card goes that far; previous at the start of a chapter goes back one',
        (tester) async {
      ListeningPrefs.memory.skipBy = SkipBy.seconds;
      final layout = numbered();
      await open(tester, layout);
      const words = 30 * 165 / 60;
      var v = 0;
      while (v < layout.units.length - 1 && layout.wordsBefore[v + 1] <= words) {
        v++;
      }
      await event(tester, {'type': 'action', 'action': 'next'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith(layout.units[v].text));

      ListeningPrefs.memory.skipBy = SkipBy.chapter;
      await event(tester, {'type': 'action', 'action': 'next'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Beta'));
      // A few sentences in, previous goes to the chapter's start; at its
      // start, to the chapter before.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('Next sentence'));
        await tester.pumpAndSettle();
      }
      await event(tester, {'type': 'action', 'action': 'prev'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Beta'));
      await event(tester, {'type': 'action', 'action': 'prev'});
      await tester.pumpAndSettle();
      expect(washed(tester), startsWith('Alpha'));
      await finish(tester);
    });

    testWidgets('paused, the card moves the place and stays up, paused, until Play', (tester) async {
      final layout = numbered();
      await open(tester, layout);
      await playing(tester);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(milliseconds: 100));
      await event(tester, {'type': 'action', 'action': 'next'});
      await tester.pump(const Duration(milliseconds: 100));
      final s = sessions().last;
      expect(s['active'], isTrue);
      expect(s['playing'], isFalse);
      expect(s['positionMs'], msFor(layout.wordsBefore[1]));
      expect(washed(tester), startsWith(layout.units[1].text));
      expect(find.byTooltip('Play'), findsOneWidget);
      await event(tester, {'type': 'action', 'action': 'play'});
      await io(tester, () => sessions().last['playing'] == true);
      expect(sessions().last['playing'], isTrue);
      expect(sessions().last['positionMs'], msFor(layout.wordsBefore[1]));
      await finish(tester);
    });

    testWidgets('unplugged it pauses at once; the audio taken for good, it does not come back by itself',
        (tester) async {
      await open(tester, ReadingLayout.build(specimenBook()));
      await playing(tester);
      await event(tester, {'type': 'noisy'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Play'), findsOneWidget);
      await playing(tester);
      await event(tester, {'type': 'focusLoss'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Play'), findsOneWidget);
      await event(tester, {'type': 'focusGain'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Play'), findsOneWidget, reason: 'not resumed');
      await finish(tester);
    });
  });

  group("a PDF's real pages", () {
    Future<void> openPdf(WidgetTester tester) async {
      final book = ingestPdfText(id: 'p', pages: [
        'First page text is long enough to be a real page of a book, honestly.',
        'Second page text is also long enough to count as a page of a book.',
      ]);
      phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(layout: ReadingLayout.build(book), sourcePath: '${_tmp.path}/b.pdf'),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('in pages, the button switches between the real pages and the text, keeping the bars to hand',
        (tester) async {
      ListeningPrefs.memory.pages = true;
      await openPdf(tester);
      expect(find.byType(PagedBook), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show the real pages'));
      await tester.pumpAndSettle();
      expect(ListeningPrefs.memory.pdfPages, isTrue);
      expect(find.byType(PdfPagesView), findsOneWidget);
      expect(find.byType(PageCurl), findsOneWidget);
      expect(find.byType(PagedBook), findsNothing);
      // The real pages keep the bars: a tap there reads from the page.
      expect(find.byTooltip('Show as text').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Play').hitTestable(), findsOneWidget);
      expect(find.byType(GroundFade), findsNothing);
      await tester.tap(find.byTooltip('Show as text'));
      await tester.pumpAndSettle();
      expect(find.byType(PagedBook), findsOneWidget);
      expect(find.byType(PdfPagesView), findsNothing);
      await finish(tester);
    });

    testWidgets('press and hold on a real page reads from it; a tap does not', (tester) async {
      ListeningPrefs.memory.pdfPages = true;
      await openPdf(tester);
      await tester.drag(find.byType(PdfPagesView), const Offset(0, -350));
      await tester.pumpAndSettle();
      final second = tester.getRect(find.byType(InteractiveViewer).at(1));
      final at = Offset(second.center.dx, second.top + 60);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.longPressAt(at);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Pause'), findsOneWidget);
      // (Not settled: the ring round Pause turns while a sentence is made.)
      ListeningPrefs.memory
        ..pdfPages = false
        ..save();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(washed(tester), startsWith('Second page'));
      await finish(tester);
    });
  });

  group('turned or given a new size', () {
    testWidgets('pages keep their sentence through a turn of the phone and a new text size', (tester) async {
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none';
      await open(tester, numbered());
      await turnOn(tester, pages: 3);
      final (first, _) = onPage(tester);
      phone(tester, onItsSide: true);
      await tester.pumpAndSettle();
      expect(holds(tester, first), isTrue, reason: 'on its side');
      phone(tester);
      await tester.pumpAndSettle();
      expect(holds(tester, first), isTrue, reason: 'upright again');
      ListeningPrefs.memory
        ..textSize = 26
        ..save();
      await tester.pumpAndSettle();
      expect(holds(tester, first), isTrue, reason: 'a bigger text size');
      await finish(tester);
    });

    testWidgets('the scroll keeps the paragraph at the top through a new text size and a narrower window',
        (tester) async {
      await open(tester, numbered());
      final list = find.byType(ScrollablePositionedList);
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      Finder para(int p) =>
          find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Paragraph $p sentence 0 '));
      final top = tester.getRect(list).top;
      final p = [for (var i = 0; i < 16; i++) i]
          .firstWhere((i) => para(i).evaluate().isNotEmpty && tester.getRect(para(i).first).bottom > top);
      final was = tester.getRect(para(p).first).top;
      ListeningPrefs.memory
        ..textSize = 25
        ..save();
      await tester.pumpAndSettle();
      expect(tester.getRect(para(p).first).top, closeTo(was, 1), reason: 'a new text size');
      tester.view.physicalSize = const Size(1040, 2340);
      await tester.pumpAndSettle();
      expect(tester.getRect(para(p).first).top, closeTo(was, 1), reason: 'a narrower window');
      await finish(tester);
    });
  });

  group('TalkBack', () {
    testWidgets("turns the reader's pages by their actions, and the place goes with them", (tester) async {
      final semantics = tester.ensureSemantics();
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none';
      await open(tester, numbered());
      final before = onPage(tester).$1;
      final node = tester.getSemantics(find.byWidgetPredicate((w) =>
          w is Semantics && (w.properties.customSemanticsActions?.keys.any((a) => a.label == 'Next page') ?? false)));
      final next = CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Next page'));
      node.owner!.performAction(node.id, SemanticsAction.customAction, next);
      await tester.pumpAndSettle();
      final (first, _) = onPage(tester);
      expect(first, greaterThan(before));
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(book(tester).marked.value, first);
      semantics.dispose();
      await finish(tester);
    });

    testWidgets("a screen reader's double tap on a paragraph of the scroll reads from its start", (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, numbered());
      SemanticsNode? found;
      bool visit(SemanticsNode n) {
        if (n.label.startsWith('Paragraph 1 sentence 0 ') && n.getSemanticsData().hasAction(SemanticsAction.tap)) {
          found ??= n;
        }
        n.visitChildren(visit);
        return true;
      }

      final root = tester.getSemantics(find.byType(ScrollablePositionedList)).owner!.rootSemanticsNode!;
      visit(root);
      final node = found!;
      expect(node.getSemanticsData().hint, 'Double tap to read from here');
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(find.byTooltip('Pause'), findsOneWidget);
      // The paragraph is below the screen: the page travels to it (a fade,
      // a jump, a frame, then a scroll the rest of the way).
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 700));
      expect(washed(tester), startsWith('Paragraph 1 sentence 0 '));
      semantics.dispose();
      await finish(tester);
    });
  });

  group('the edges', () {
    testWidgets('pages have no fades over the text, and no darkened edge; the scroll has its two', (tester) async {
      await open(tester, numbered());
      expect(find.byType(GroundFade), findsNWidgets(2));
      await finish(tester);
      ListeningPrefs.memory.pages = true;
      await open(tester, numbered());
      expect(find.byType(GroundFade), findsNothing);
      expect(tester.widget<PageGround>(find.byType(PageGround).first).vignette, isFalse);
      await finish(tester);
    });

    testWidgets('a message sits above the player, and at the foot while the bars are away', (tester) async {
      await open(tester, numbered());
      Future<Rect> message() async {
        await event(tester, {'type': 'action', 'action': 'save'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        return tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);
      }

      final play = tester.getRect(find.byTooltip('Play'));
      final up = await message();
      expect(up.bottom, lessThanOrEqualTo(play.top));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getRect(find.byType(ScrollablePositionedList)).center);
      await tester.pumpAndSettle();
      final down = await message();
      expect(down.bottom, greaterThan(play.bottom), reason: 'with the player put away');
      await finish(tester);
    });
  });

  group('reading aloud', () {
    testWidgets('listening, a scroll is a look around; Back to reading brings the page back to the voice',
        (tester) async {
      await open(tester, numbered());
      await playing(tester);
      expect(find.text('Back to reading').hitTestable(), findsNothing);
      await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -1200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Back to reading').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget, reason: 'the voice reads on');
      await tester.tap(find.text('Back to reading'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 700));
      expect(washed(tester), startsWith('Alpha'));
      expect(find.text('Back to reading').hitTestable(), findsNothing);
      await finish(tester);
    });

    testWidgets('read aloud to its end: the words heard and the chapter finished are counted, and it says so',
        (tester) async {
      StatsStore.instance.reset();
      final layout = ReadingLayout.build(ingestString(
        [
          '# One',
          'The first sentence is here. The second follows it.',
          '# Two',
          'The third sentence is here. The last one ends it.',
        ].join(blank),
        filename: 'short.md',
        title: 'Short',
      ));
      await open(tester, layout);
      await playing(tester);
      // The player's head moves on as a speaker's would, a little ahead of
      // the clock, so the voice never runs dry waiting for its next sentence.
      const finished = 'Finished. That is the end of the book.';
      for (var i = 0; i < 600 && find.text(finished).evaluate().isEmpty; i++) {
        _head += 1500;
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(finished), findsOneWidget);
      final t = StatsStore.instance.totals();
      expect(t.words, layout.wordsBefore[layout.units.length - 1] - layout.wordsBefore[1]);
      expect(t.chapters, 1);
      await finish(tester);
    });

    testWidgets('reading by scrolling counts as time spent reading', (tester) async {
      StatsStore.instance.reset();
      await open(tester, numbered());
      await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 16));
      final t = StatsStore.instance.totals();
      expect(t.readMs, greaterThan(0));
      expect(t.listenMs, 0);
      await finish(tester);
    });

    testWidgets("a web novel's page: its numbers and place in the whole work, its own contents, and the way on",
        (tester) async {
      final layout = numbered();
      final sections = <int>[];
      final ends = <(bool, bool)>[];
      final contents = <(int, bool)>[];
      phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
          layout: layout,
          onChapterChanged: sections.add,
          progressOf: (u) => 0.5,
          positionOf: (u) => '${layout.units[u].sectionIndex + 41}/90',
          chapterNumberOf: (c) => c + 41,
          endLabel: 'Check for new chapters',
          onReachedEnd: ({required bool playing, bool browse = false}) async => ends.add((playing, browse)),
          openContents: (context, {required int section, required bool playing}) => contents.add((section, playing)),
        ),
      ));
      await tester.pumpAndSettle();
      final first = layout.units[0].sectionIndex;
      expect(find.textContaining('${first + 41}/90'), findsOneWidget);
      expect(find.text('CHAPTER 41'), findsWidgets);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(find.textContaining('LEFT IN CHAPTER'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('contents')));
      await tester.pump();
      expect(contents, [(first, false)]);

      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pumpAndSettle();
      final second = layout.units[layout.chapterFirstUnit[1]].sectionIndex;
      expect(sections, [second]);
      // Next chapter in the last one here: on to the site's next.
      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pump();
      expect(ends, [(false, false)]);
      // The button at the end of the page looks ahead, keeping the place.
      // (Settled each time: the list's second copy, kept for its long
      // scrolls, can hold the button a moment before the list itself does.)
      final button = find.text('Check for new chapters');
      for (var i = 0; i < 40 && button.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -500));
        await tester.pumpAndSettle();
      }
      await tester.tap(button);
      await tester.pump();
      expect(ends, [(false, false), (false, true)]);
      await finish(tester);
    });
  });

  group("the card's sums, one for a book's page and the background", () {
    test('where the card shows a sentence: how far into its chapter, and how long the chapter is', () {
      final layout = numbered();
      final second = layout.chapterFirstUnit[1];
      expect(cardClock(layout, 0, 1), (positionMs: 0, durationMs: msFor(layout.wordsBefore[second])));
      expect(cardClock(layout, 3, 1.5),
          (positionMs: msFor(layout.wordsBefore[3], speed: 1.5), durationMs: msFor(layout.wordsBefore[second], speed: 1.5)));
      expect(cardClock(layout, second + 2, 1),
          (positionMs: msFor(layout.wordsBefore[second + 2] - layout.wordsBefore[second]),
           durationMs: msFor(layout.totalWords - layout.wordsBefore[second])));
    });

    test('the seek bar let go, previous by chapter, and the next speed', () {
      final layout = numbered();
      final second = layout.chapterFirstUnit[1];
      expect(seekTarget(layout, 5, 0, 1), 0, reason: "the chapter's start");
      expect(seekTarget(layout, second + 5, 0, 1), second);
      // 20 seconds is 55 words at 165 a minute: past the heading and five
      // sentences of ten words each.
      expect(seekTarget(layout, 0, 20000, 1), 6);
      expect(seekTarget(layout, 0, 20000, 2), 11, reason: 'twice the words at twice the speed');
      expect(seekTarget(layout, 0, 1 << 30, 1), second - 1, reason: 'never past the chapter');
      expect(chapterStartBehind(layout, second, 1), isNull, reason: 'at its start: the chapter before');
      expect(chapterStartBehind(layout, second + 1, 1), isNull, reason: 'within three seconds');
      expect(chapterStartBehind(layout, second + 3, 1), second);
      expect([for (final s in [0.75, 1.0, 1.1, 1.25, 1.5, 2.0]) nextSpeed(s)], [1.0, 1.25, 1.25, 1.5, 2.0, 0.75]);
    });

    test('a sentence heard to its end counts its words, and the next chapter begun, a chapter', () {
      StatsStore.instance.reset();
      final layout = numbered();
      final second = layout.chapterFirstUnit[1];
      countHeard(layout, 3, 4, playing: true);
      countHeard(layout, 4, 6, playing: true);
      countHeard(layout, -1, 0, playing: true);
      countHeard(layout, 6, 7, playing: false);
      expect(StatsStore.instance.totals().words, layout.wordsBefore[4] - layout.wordsBefore[3]);
      expect(StatsStore.instance.totals().chapters, 0);
      countHeard(layout, second - 1, second, playing: true);
      expect(StatsStore.instance.totals().chapters, 1);
    });
  });

  group('a book read on in the background', () {
    /// A book read aloud on its page and left: it reads on without the page.
    Future<BackgroundReading> readOnWithoutIt(WidgetTester tester, ReadingLayout layout) async {
      final store = LibraryStore(_tmp);
      final nav = await shelf(tester);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(layout: layout, store: store))));
      await tester.pumpAndSettle();
      await playing(tester);
      await nav.maybePop();
      await tester.pumpAndSettle();
      final bg = BackgroundReading.current.value!;
      expect(bg.bookId, layout.book.id);
      return bg;
    }

    testWidgets("its card's buttons: pause and play, next and previous, seek, speed and save", (tester) async {
      final layout = numbered();
      final bg = await readOnWithoutIt(tester, layout);
      var s = sessions().last;
      expect(s['active'], isTrue);
      expect(s['title'], 'Numbered');
      expect(s['book'], layout.book.id);
      await event(tester, {'type': 'action', 'action': 'pause'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(bg.playing, isFalse);
      expect(sessions().last['playing'], isFalse);

      // Paused, the card's buttons move the place, which waits there.
      await event(tester, {'type': 'action', 'action': 'next'});
      expect(bg.unit, 1);
      expect(sessions().last['positionMs'], msFor(layout.wordsBefore[1]));
      await event(tester, {'type': 'action', 'action': 'prev'});
      expect(bg.unit, 0);
      // Seek: the sentence that far into the chapter, at 165 words a minute.
      const ms = 20000;
      var u = 0;
      while (u + 1 < layout.chapterFirstUnit[1] && layout.wordsBefore[u + 1] <= ms / 60000 * 165) {
        u++;
      }
      expect(u, greaterThan(1));
      await event(tester, {'type': 'action', 'action': 'seek', 'value': ms});
      expect(bg.unit, u);
      // By chapter: on to the next; back, a few sentences in, to its start,
      // and at its start to the chapter before.
      final second = layout.chapterFirstUnit[1];
      ListeningPrefs.memory.skipBy = SkipBy.chapter;
      await event(tester, {'type': 'action', 'action': 'next'});
      expect(bg.unit, second);
      ListeningPrefs.memory.skipBy = SkipBy.sentence;
      for (var i = 0; i < 3; i++) {
        await event(tester, {'type': 'action', 'action': 'next'});
      }
      expect(bg.unit, second + 3);
      ListeningPrefs.memory.skipBy = SkipBy.chapter;
      await event(tester, {'type': 'action', 'action': 'prev'});
      expect(bg.unit, second);
      await event(tester, {'type': 'action', 'action': 'prev'});
      expect(bg.unit, 0);
      expect(sessions().last['subtitle'], 'Alpha');
      expect(sessions().last['durationMs'], msFor(layout.wordsBefore[second]));

      // Speed: the next of the common speeds, on the card too.
      await event(tester, {'type': 'action', 'action': 'speed'});
      expect(ListeningPrefs.memory.speedFor(layout.book.id), 1.25);
      expect(sessions().last['speed'], 1.25);
      // Save this line: the sentence it waits at.
      await event(tester, {'type': 'action', 'action': 'save'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(MarkStore.instance.forBook(layout.book.id).single.text, layout.units[0].text);

      // Play: from where it was moved to.
      await event(tester, {'type': 'action', 'action': 'play'});
      await io(tester, () => bg.playing);
      expect(bg.player.unit.value, 0);
      s = sessions().last;
      expect(s['playing'], isTrue);
      expect(s['speed'], 1.25);
      await bg.stop();
      expect(sessions().last['active'], isFalse);
      await finish(tester);
    });

    testWidgets("the phone's audio: unplugged it pauses; a moment's loss comes back, a long one or one for good does not",
        (tester) async {
      final bg = await readOnWithoutIt(tester, ReadingLayout.build(specimenBook()));
      expect(bg.playing, isTrue);
      await event(tester, {'type': 'noisy'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(bg.playing, isFalse);
      await event(tester, {'type': 'focusGain'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(bg.playing, isFalse, reason: 'unplugged is not a loss to come back from');

      await event(tester, {'type': 'action', 'action': 'play'});
      await io(tester, () => bg.playing);
      await event(tester, {'type': 'focusLossTransient'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(bg.playing, isFalse);
      await event(tester, {'type': 'focusGain'});
      await io(tester, () => bg.playing);
      expect(bg.playing, isTrue, reason: 'taken a moment, and given back');

      await event(tester, {'type': 'focusLossTransient'});
      await tester.pump(const Duration(minutes: 2));
      await event(tester, {'type': 'focusGain'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(bg.playing, isFalse, reason: 'a long call does not resume on its own');

      await event(tester, {'type': 'action', 'action': 'play'});
      await io(tester, () => bg.playing);
      await event(tester, {'type': 'focusLoss'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(bg.playing, isFalse);
      await event(tester, {'type': 'focusGain'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(bg.playing, isFalse, reason: 'taken for good');
      await bg.stop();
      await finish(tester);
    });
  });

  group('the page keys and the screen', () {
    testWidgets('the volume keys turn the text pages while nothing is read aloud', (tester) async {
      ListeningPrefs.memory
        ..pages = true
        ..pageTurn = 'none'
        ..volumeKeys = true;
      await open(tester, numbered());
      ListeningPrefs.memory.save();
      await tester.pumpAndSettle();
      expect(lastOn('volumeKeysTurnPages'), isTrue);
      final before = onPage(tester).$1;
      await event(tester, {'type': 'pageKey', 'delta': 1});
      await tester.pumpAndSettle();
      expect(onPage(tester).$1, greaterThan(before));
      await event(tester, {'type': 'pageKey', 'delta': -1});
      await tester.pumpAndSettle();
      expect(onPage(tester).$1, before);
      // Read aloud, the keys are the volume's again.
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
      await playing(tester);
      expect(lastOn('volumeKeysTurnPages'), isFalse);
      await finish(tester);
    });

    testWidgets('kept on, the screen stays on while the book is open, and not after', (tester) async {
      await open(tester, numbered());
      ListeningPrefs.memory
        ..keepScreenOn = true
        ..save();
      await tester.pumpAndSettle();
      expect(lastOn('keepScreenOn'), isTrue);
      await finish(tester);
      expect(lastOn('keepScreenOn'), isFalse);
    });

    testWidgets('the place is saved when the app goes to the background', (tester) async {
      final store = LibraryStore(_tmp);
      final layout = numbered();
      await open(tester, layout, store: store);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Next sentence'));
        await tester.pump();
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await saved(tester, store, layout), 2, reason: 'saved at once, not after the usual wait');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await finish(tester);
    });

    testWidgets("the fast scroller's thumb moves the place, as a scroll by hand does", (tester) async {
      final semantics = tester.ensureSemantics();
      final layout = numbered(paragraphs: 45);
      await open(tester, layout);
      final slider = tester.getSemantics(find.bySemanticsLabel('Fast scroll'));
      for (var i = 0; i < 4; i++) {
        slider.owner!.performAction(slider.id, SemanticsAction.increase);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(washed(tester), isEmpty, reason: 'the place moved quietly');
      await tester.tap(find.byTooltip('Play'));
      await tester.pump(const Duration(milliseconds: 100));
      final read = washed(tester);
      expect(read, startsWith('Paragraph '));
      final p = int.parse(RegExp('^Paragraph ([0-9]+) ').firstMatch(read)!.group(1)!);
      expect(p, greaterThan(5), reason: 'read from where the thumb went, not the start');
      semantics.dispose();
      await finish(tester);
    });
  });
}
