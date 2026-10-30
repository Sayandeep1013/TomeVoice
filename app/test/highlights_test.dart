// Saved quotes drawn in the text: their colours, the voice's washes over
// them, a tap on one, and the page in pages.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/highlights.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/paged_view.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

/// Paint calls, in order: a wash's colour (as 8-bit ARGB: a paint keeps
/// its colour in single precision), or 'text' for the words.
class _Recorder implements Canvas {
  final calls = <Object>[];

  @override
  void drawRRect(RRect rrect, Paint paint) => calls.add(paint.color.toARGB32());

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) => calls.add('text');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Mark _quote(ReadingLayout l, int unit, {int span = 1, MarkColour colour = MarkColour.accent, String id = 'q'}) => Mark(
      id: id,
      bookId: l.book.id,
      bookTitle: l.book.metadata.title,
      kind: MarkKind.quote,
      at: cursorOf(l.units[unit]),
      span: span,
      text: [for (var i = unit; i < unit + span; i++) l.units[i].text].join(' '),
      created: DateTime(2026, 10, 1, 9, unit),
      colour: colour,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    MarkStore.instance.reset();
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    tmp = Directory.systemTemp.createTempSync('tomevoice_marks');
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

  group('a quote', () {
    test('keeps its colour, and marks saved before colours are the accent', () {
      final old = Mark.fromJson({
        'id': 'a',
        'book': 'b',
        'kind': 'quote',
        'at': {'sectionIndex': 0, 'blockIndex': 1, 'sentenceIndex': 2},
        'text': 'Words.',
        'created': '2026-01-02T03:04:05.000',
      })!;
      expect(old.colour, MarkColour.accent);
      expect(old.edited, isNull);
      expect(old.toJson().containsKey('colour'), isFalse);

      final green = old.withColour(MarkColour.green);
      expect(green.edited, isNotNull);
      expect(green.changed.isAfter(old.changed), isTrue);
      final back = Mark.fromJson(green.toJson())!;
      expect(back.colour, MarkColour.green);
      expect(back.edited, green.edited);
      // A note kept with a new colour, and a colour with a new note.
      expect(back.withNote('Why').withColour(MarkColour.blue).note, 'Why');
      expect(back.withNote('Why').colour, MarkColour.green);
      expect(Mark.fromJson({...green.toJson(), 'colour': 'mauve'})!.colour, MarkColour.accent);
    });

    test('is found by halves exactly where a saved place is found', () {
      final l = ReadingLayout.build(specimenBook());
      for (var u = 0; u < l.units.length; u++) {
        final c = cursorOf(l.units[u]);
        expect(unitAtCursor(l.units, c), l.unitForCursor(c, saved: true));
      }
      for (final c in [
        const ReadingCursor(sectionIndex: 0, blockIndex: 0, sentenceIndex: 9),
        const ReadingCursor(sectionIndex: 0, blockIndex: 7, sentenceIndex: 0),
        const ReadingCursor(sectionIndex: 4, blockIndex: 0, sentenceIndex: 0),
      ]) {
        expect(unitAtCursor(l.units, c), l.unitForCursor(c, saved: true));
      }
    });

    test('washes its sentences, newest on top; bookmarks and missing chapters do not', () {
      final l = ReadingLayout.build(specimenBook());
      final older = _quote(l, 1, span: 2, colour: MarkColour.yellow, id: 'old');
      final newer = _quote(l, 2, colour: MarkColour.blue, id: 'new');
      final bookmark = Mark(
        id: 'bm',
        bookId: l.book.id,
        bookTitle: '',
        kind: MarkKind.bookmark,
        at: cursorOf(l.units[0]),
        text: l.units[0].text,
        created: DateTime(2026),
      );
      final elsewhere = _quote(l, 0, id: 'gone').movedTo(const ReadingCursor(sectionIndex: 40, blockIndex: 0, sentenceIndex: 0));
      // Saved newest first, as the store keeps them.
      final map = highlightUnits(l, [newer, older, bookmark, elsewhere]);
      expect(map.keys.toSet(), {1, 2});
      expect(map[1]!.id, 'old');
      expect(map[2]!.id, 'new');
    });
  });

  group('washes', () {
    final l = ReadingLayout.build(specimenBook());
    final item = l.items[l.unitItem[0]];
    const sentence = Color(0x40FF0000);
    const word = Color(0x80FF0000);
    const hl = Color(0x5500FF00);

    test("the voice's sentence and word lie over a quote", () {
      final quotes = {0: _quote(l, 0), 1: _quote(l, 1, id: 'two')};
      final runs = washRuns(
        layout: l,
        item: item,
        quotes: quotes,
        quoteWash: (_) => hl,
        spoken: 0,
        sentenceWash: sentence,
        wordWash: word,
        wordStart: 4,
        wordEnd: 9,
      );
      final text = item.block!.text;
      String of(Color c) => [for (final r in runs) if (r.wash == c) text.substring(r.start, r.end)].join('|');
      expect(of(Color.alphaBlend(word, hl)), 'quick');
      expect(of(Color.alphaBlend(sentence, hl)), 'The | brown fox jumps over the lazy dog.');
      expect(of(hl), 'Pack my box with five dozen liquor jugs.');
      // Every character once, in order.
      expect(runs.first.start, 0);
      for (var i = 1; i < runs.length; i++) {
        expect(runs[i].start, runs[i - 1].end);
      }
      expect(runs.last.end, text.length);
    });

    test('a quote of two sentences is one wash, across the gap', () {
      final both = _quote(l, 0, span: 2);
      final runs = washRuns(
        layout: l,
        item: item,
        quotes: {0: both, 1: both},
        quoteWash: (_) => hl,
        spoken: -1,
        sentenceWash: sentence,
        wordWash: word,
      );
      expect([for (final r in runs) if (r.wash == hl) item.block!.text.substring(r.start, r.end)],
          ['The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.']);
    });

    test('nothing saved and nothing read: one plain run', () {
      final runs = washRuns(
        layout: l,
        item: item,
        quotes: const {},
        quoteWash: (_) => hl,
        spoken: -1,
        sentenceWash: sentence,
        wordWash: word,
      );
      expect(runs, hasLength(1));
      expect(runs.single.wash, isNull);
    });
  });

  group('on the scrolling page', () {
    Future<ReadingLayout> pump(WidgetTester tester, {Mark Function(ReadingLayout l)? saved}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final l = ReadingLayout.build(specimenBook());
      if (saved != null) await MarkStore.instance.restore(saved(l));
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: l)));
      await tester.pumpAndSettle();
      return l;
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    /// Background of each washed span, by its text.
    Map<String, Color> washes(WidgetTester tester) {
      final out = <String, Color>{};
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        t.textSpan?.visitChildren((span) {
          final bg = span is TextSpan ? span.style?.backgroundColor : null;
          if (bg != null) out[(span as TextSpan).text ?? ''] = bg;
          return true;
        });
      }
      return out;
    }

    Future<void> tapOn(WidgetTester tester, String words) async {
      final finder = find.textContaining(words).first;
      final para = tester.renderObject<RenderParagraph>(finder);
      final start = para.text.toPlainText().indexOf(words);
      final box = para.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + 4)).first;
      await tester.tapAt(para.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();
    }

    testWidgets('a saved quote is washed in its colour, and the read sentence over it', (tester) async {
      final l = await pump(tester, saved: (l) => _quote(l, 1, colour: MarkColour.yellow));
      const quote = 'Pack my box with five dozen liquor jugs.';
      final before = washes(tester);
      // The place (the first sentence) has the voice's wash; the quote its own.
      final sentence = before['The quick brown fox jumps over the lazy dog.']!;
      final yellow = before[quote]!;
      expect(yellow, isNot(sentence));
      expect(yellow.a, lessThan(1));

      // The voice moves onto the quote: its wash lies over the yellow.
      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();
      expect(washes(tester)[quote], Color.alphaBlend(sentence, yellow));
      expect(l.units[1].text, quote);
      await finish(tester);
    });

    testWidgets('a tap on a quote opens its note and actions; elsewhere it does not', (tester) async {
      await pump(tester, saved: (l) => _quote(l, 1).withNote('Every letter'));
      await tapOn(tester, 'TomeVoice reads a document');
      expect(find.text('Remove the quote'), findsNothing, reason: 'that paragraph holds no quote');
      // The bars went away with that tap, moving the page: a tap that soon
      // after would only stop a scroll.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));

      await tapOn(tester, 'Pack my box');
      expect(find.text('Every letter'), findsOneWidget);
      expect(find.text('Change the note'), findsOneWidget);
      expect(find.text('Read from here'), findsOneWidget);
      await tester.tap(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Green highlight'));
      await tester.pumpAndSettle();
      expect(MarkStore.instance.all.single.colour, MarkColour.green);
      await tester.tap(find.text('Remove the quote'));
      await tester.pumpAndSettle();
      expect(MarkStore.instance.all, isEmpty);
      expect(washes(tester).keys, isNot(contains('Pack my box with five dozen liquor jugs.')));
      await finish(tester);
    });
  });

  group('in pages', () {
    final para = List.generate(40, (i) => 'Sentence number $i of the paragraph runs on a little.').join(' ');
    final layout = ReadingLayout.build(ingestString('# One\n\n${List.filled(6, para).join('\n\n')}', filename: 'b.md'));
    const look = PageLook(
      text: TextStyle(fontSize: 19, height: 1.5, color: Colors.black),
      heading: TextStyle(fontSize: 22, color: Colors.black),
      chapterHeading: TextStyle(fontSize: 28, color: Colors.brown),
      title: TextStyle(fontSize: 28, color: Colors.brown),
      label: TextStyle(fontSize: 11, color: Colors.brown),
      status: TextStyle(fontSize: 10, color: Colors.grey),
      accent: Colors.brown,
      sentenceWash: Color(0x44FFEB3B),
      wordWash: Color(0x88FF9800),
      textScaler: TextScaler.noScaling,
      justify: false,
      indent: false,
      margin: 24,
    );

    testWidgets('quotes are painted under the voice, and the pages are not cut again', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final first = layout.items.indexWhere((i) => i.unitCount > 1);
      final unit = layout.items[first].firstUnit;
      final marked = ValueNotifier<int>(unit);
      final word = ValueNotifier<WordMark>(WordMark(unit, 0, 8));
      final controller = PagedController();
      Widget book(ValueListenable<Map<int, Mark>> highlights) => MaterialApp(
            home: Scaffold(
              body: PagedBook(
                layout: layout,
                look: look,
                controller: controller,
                startUnit: 0,
                marked: marked,
                word: word,
                chapterName: (c) => 'One',
                onPage: (unit, {required byHand}) {},
                onTapMiddle: () {},
                onHold: (item, offset) {},
                pictureOf: (block, size) => SizedBox.fromSize(size: size),
                turn: PageTurn.none,
                highlights: highlights,
              ),
            ),
          );
      final none = ValueNotifier<Map<int, Mark>>(const {});
      await tester.pumpWidget(book(none));
      await tester.pumpAndSettle();

      List<CustomPainter> slices() => [
            for (final c in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
              if (c.painter?.runtimeType.toString() == '_SlicePainter') c.painter!,
          ];
      final laidBefore = [for (final p in slices()) (p as dynamic).laid];
      final range = controller.range;

      // A quote saved (a new map, as the reader's Highlights gives), and the
      // page built again with it.
      final q = _quote(layout, unit, span: 2, colour: MarkColour.blue);
      await tester.pumpWidget(book(ValueNotifier({unit: q, unit + 1: q})));
      await tester.pump();

      final blue = highlightWash(MarkColour.blue, accent: look.accent, dark: false).toARGB32();
      final painted = slices().map((p) {
        final r = _Recorder();
        p.paint(r, const Size(400, 4000));
        return r.calls;
      }).firstWhere((calls) => calls.contains(blue));
      final lastBlue = painted.lastIndexOf(blue);
      final firstSentence = painted.indexOf(look.sentenceWash.toARGB32());
      final firstWord = painted.indexOf(look.wordWash.toARGB32());
      expect(firstSentence, greaterThan(lastBlue), reason: "the voice's sentence over the quote");
      expect(firstWord, greaterThan(firstSentence), reason: 'and its word over that');
      expect(painted.last, 'text');

      // Painted only: the same laid-out paragraphs and the same page.
      final laidAfter = [for (final p in slices()) (p as dynamic).laid];
      expect(laidAfter, isNotEmpty);
      for (final laid in laidAfter) {
        expect(laidBefore.any((b) => identical(b, laid)), isTrue);
      }
      expect(controller.range, range);
    });
  });
}
