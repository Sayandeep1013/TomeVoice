// A long web novel's page holds a window of its chapters (see
// LibraryStore.webWindow). Read on to the window's end, aloud or not, on the
// scroll or in pages, the page goes on into the chapters after it as they
// come to the phone: the same page and the same voice, with no break, no
// page built again, nothing to tap. And the place a page saves as it goes
// is measured by its own chapters, not by the next window's.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/paged_view.dart';
import 'package:tomevoice_spike/player_controls.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/web_reader.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;
final _calls = <MethodCall>[];

/// The player the tests steer: where its head is, and what it was given.
var _head = 0;
var _queued = 0;

/// How much speech was queued, still to be heard, when the first sentence
/// of the chapter after the page's was asked for.
int? _aheadAtNext;

int _count(String method) => _calls.where((c) => c.method == method).length;

const _plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');

String _chapter(int i) =>
    '<p>Part ${i + 1} begins on this page. It goes on a little.</p><p>Part ${i + 1} ends here. Then the next.</p>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('tv_web_window');
    _calls.clear();
    _head = 0;
    _queued = 0;
    _aheadAtNext = null;
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    SourceEngine.instance.attach(SourceStore(_tmp, defaults: const []));
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
        // puts it.
        'synthesise' => () {
            if (((call.arguments as Map)['text'] as String).startsWith('Part 6 begins')) {
              _aheadAtNext ??= _queued - _head;
            }
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
        _ => null,
      };
    });
  });

  tearDown(() async {
    await BackgroundReading.current.value?.stop();
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

  /// Real IO and isolates, a frame between, until [until] holds.
  Future<void> io(WidgetTester tester, bool Function() until, {int tries = 120}) async {
    for (var i = 0; i < tries && !until(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// A web novel of [chapters], [onPhone] of them downloaded, its place in
  /// [at]: its page opens on a window of them.
  Future<(LibraryStore, LibraryEntry)> novel(
    WidgetTester tester, {
    int chapters = 8,
    required Iterable<int> onPhone,
    int at = 2,
  }) async {
    late LibraryStore store;
    late LibraryEntry entry;
    await tester.runAsync(() async {
      store = LibraryStore(_tmp);
      final id = (await store.addWebNovel(
        _plugin,
        SourceNovel(path: 'n', name: 'Novel', chapters: [
          for (var i = 0; i < chapters; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
        ]),
      ))
          .id;
      for (final i in onPhone) {
        await store.saveChapter(id, i, 'Chapter ${i + 1}', _chapter(i));
      }
      await store.saveCursor(id, ReadingCursor(sectionIndex: at), 0.1);
      entry = (await store.list(all: true)).firstWhere((e) => e.id == id);
    });
    return (store, entry);
  }

  Future<void> openPage(WidgetTester tester, LibraryStore store, LibraryEntry entry) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: WebNovelReader(store: store, entry: entry)));
    await io(tester, () => find.byType(ReaderScreen).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ReaderScreen), findsOneWidget);
  }

  /// The chapters after the page's, fetched ahead while it is read, as the
  /// page fetches them.
  Future<void> fetchedAhead(WidgetTester tester, LibraryStore store, String id, Iterable<int> chapters) =>
      tester.runAsync(() async {
        for (final i in chapters) {
          await store.saveChapter(id, i, 'Chapter ${i + 1}', _chapter(i));
        }
      });

  ReaderScreen page(WidgetTester tester) => tester.widget<ReaderScreen>(find.byType(ReaderScreen));
  PlaybackScheduler player(WidgetTester tester) => tester.widget<PlayButton>(find.byType(PlayButton)).player;

  /// The chapter (section) the voice is reading.
  int reading(WidgetTester tester) {
    final p = player(tester);
    return p.units[p.unit.value.clamp(0, p.units.length - 1)].sectionIndex;
  }

  /// How far the page in front has faded in: 1 once it is all there.
  double shown(WidgetTester tester) => tester
      .widget<FadeTransition>(find.ancestor(of: find.byType(ReaderScreen), matching: find.byType(FadeTransition)).first)
      .opacity
      .value;

  /// Read aloud from the place to chapter [to], the head moving on a little
  /// at a time; whatever happens on the way is told to [seen].
  Future<void> readAloudTo(WidgetTester tester, int to, void Function() seen) async {
    // In pages, the player comes up with a tap in the middle.
    if (find.byType(PagedBook).evaluate().isNotEmpty) {
      await tester.tapAt(tester.getCenter(find.byType(PagedBook)));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Play'));
    await io(tester, () => _count('playerEnqueue') > 0);
    var joining = false;
    for (var i = 0; i < 600 && reading(tester) < to; i++) {
      _head += 1200;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
      await tester.pump(const Duration(milliseconds: 40));
      seen();
      // The chapters after the window are joined on while the voice is in
      // its last two: given the moment that takes, as a phone's chapters,
      // minutes long, give it.
      if (!joining && reading(tester) >= 3) {
        joining = true;
        await io(tester, () => page(tester).layout.chapters.contains(5), tries: 100);
      }
    }
  }

  for (final pages in [false, true]) {
    final how = pages ? 'in pages' : 'on the scroll';

    testWidgets('read aloud $how, the voice goes on past the chapters the page opened with, the page and voice the same',
        (tester) async {
      ListeningPrefs.memory
        ..pages = pages
        ..pageTurn = 'none';
      final (store, entry) = await novel(tester, onPhone: [0, 1, 2, 3, 4]);
      await openPage(tester, store, entry);
      expect(page(tester).layout.chapters, [0, 1, 2, 3, 4], reason: 'the window the page opens with');
      await fetchedAhead(tester, store, entry.id, [5, 6, 7]);
      final state = tester.state(find.byType(ReaderScreen));
      var blinked = false;
      var rebuilt = false;
      PlaybackScheduler? voice;
      // Counted once it reads: its start stops what the player held.
      int? stops;
      await readAloudTo(tester, 5, () {
        voice ??= player(tester);
        stops ??= _count('playerStop');
        if (shown(tester) < 1) blinked = true;
        if (!identical(tester.state(find.byType(ReaderScreen)), state)) rebuilt = true;
      });
      expect(reading(tester), 5, reason: 'the voice did not read on into chapter 6');
      expect(rebuilt, isFalse, reason: 'the page was built again at the edge');
      expect(blinked, isFalse, reason: 'the page faded out and in again at the edge');
      expect(identical(player(tester), voice), isTrue, reason: 'another voice took over at the edge');
      expect(_count('playerStop'), stops, reason: 'the voice was stopped at the edge and started again');
      expect(_aheadAtNext, greaterThan(0), reason: "the voice ran dry at the edge, waiting for the next chapter's first words");
      expect(BackgroundReading.current.value, isNull, reason: 'the voice was handed on to read without the page');
      expect(page(tester).layout.chapters, containsAll([5, 6, 7]), reason: 'the page does not show the chapters read');
      await finish(tester);
    });
  }

  testWidgets('read on the scroll, the chapters after the page\'s follow its last, with nothing to tap', (tester) async {
    final (store, entry) = await novel(tester, onPhone: [0, 1, 2, 3, 4]);
    await openPage(tester, store, entry);
    await fetchedAhead(tester, store, entry.id, [5, 6, 7]);
    final state = tester.state(find.byType(ReaderScreen));
    final next = find.textContaining('Part 6 begins');
    final list = find.byType(ScrollablePositionedList);
    for (var i = 0; i < 40 && next.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pump();
      // The eyes come to rest: the place goes there.
      await tester.pump(const Duration(milliseconds: 300));
      await io(tester, () => false, tries: 8);
    }
    expect(next, findsWidgets, reason: "chapter 6 did not follow chapter 5's end");
    expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue, reason: 'the page was built again');
    await finish(tester);
  });

  testWidgets('turned in pages, the first page of the chapter after the page\'s follows its last, with nothing to tap',
      (tester) async {
    ListeningPrefs.memory
      ..pages = true
      ..pageTurn = 'none';
    final (store, entry) = await novel(tester, onPhone: [0, 1, 2, 3, 4]);
    await openPage(tester, store, entry);
    await fetchedAhead(tester, store, entry.id, [5, 6, 7]);
    final state = tester.state(find.byType(ReaderScreen));
    bool onNext() {
      final range = tester.widget<PagedBook>(find.byType(PagedBook)).controller.range;
      final layout = page(tester).layout;
      return range != null && range.$1 < layout.units.length && layout.units[range.$1].sectionIndex >= 5;
    }

    for (var i = 0; i < 30 && !onNext(); i++) {
      final box = tester.getRect(find.byType(PagedBook));
      await tester.tapAt(Offset(box.right - 20, box.center.dy));
      await tester.pump();
      await io(tester, () => false, tries: 6);
    }
    expect(onNext(), isTrue, reason: "chapter 6's first page did not follow chapter 5's last");
    expect(identical(tester.state(find.byType(ReaderScreen)), state), isTrue, reason: 'the page was built again');
    await finish(tester);
  });

  testWidgets("a page going saves its place measured by its own chapters, not the next window's", (tester) async {
    // A hundred chapters: the first five on the phone, and eighty to
    // eighty-five, far enough on that the window round them holds none of
    // the first.
    final (store, entry) = await novel(tester, chapters: 100, onPhone: [0, 1, 2, 3, 4, 80, 81, 82, 83, 84, 85]);
    await openPage(tester, store, entry);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pump();
    }
    // Three sentences into chapter 3, where it opened.
    final layout = page(tester).layout;
    final unit = layout.chapterFirstUnit[layout.chapters.indexOf(2)] + 3;
    expect(layout.units[unit].sectionIndex, 2);
    // Off to chapter 81 from the whole novel's Contents.
    await tester.tap(find.byKey(const ValueKey('contents')));
    await io(tester, () => find.byType(TextField).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '81');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 81'));
    // Opened as quickly as a phone opens chapters it has: before its wait
    // screen would show, so the page goes as the next one comes.
    for (var i = 0; i < 200; i++) {
      if (find.byType(ReaderScreen).evaluate().isNotEmpty && page(tester).layout.chapters.first == 80) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(page(tester).layout.chapters.first, 80);
    // The place the page saved as it went, written.
    await io(tester, () => false, tries: 30);
    await tester.runAsync(store.settlePlaces);
    await tester.pump();
    final saved = (await tester.runAsync(() => store.list(all: true)))!.firstWhere((e) => e.id == entry.id);
    final (first, count) = layout.chapterRange(layout.chapterOfUnit(unit));
    final expected = (2 + (unit - first) / count) / 100;
    expect(saved.progress, closeTo(expected, 0.001), reason: "measured by the next window's chapters");
    await finish(tester);
  });
}
