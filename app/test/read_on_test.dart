// Reading on: a web novel read past the end of its window of chapters, in
// the background or handed on by its page, with the card in the shade
// saying "playing" all the way (said "paused" for a moment, Android 12+
// took the reading out of the foreground for good); the chapters joined on
// as the voice finished not passed over; and a page that no longer has the
// card leaving it to the reading that does.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_controller.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/web_reader.dart';

const _channel = MethodChannel('tomevoice/tts');

const _plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');

/// Chapter [i] (from 0): "Part 1" is the first.
String _chapter(int i) => '<p>Part ${i + 1} of the story begins on this page. It ends here, for now.</p>';

/// Until [done] holds, or [within] has passed.
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!done() && watch.elapsed < within) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late _Site site;
  late SourceEngine before;

  /// What the platform was asked, by method, and the texts it was asked to say.
  final calls = <String, List<Object?>>{};
  final asked = <String>[];

  /// The player's head stays where the test puts it; a stop takes it back.
  var head = 0;
  var queued = 0;

  /// The player's next stop, and the voice's next cancel, wait for these.
  Future<void> Function()? onStop;
  Future<void> Function()? onCancel;

  /// A book asked for from outside the app ("takeMediaPlay"), once.
  Map<String, Object?>? outside;

  int count(String method) => calls[method]?.length ?? 0;
  List<Map<Object?, Object?>> sessions() => [...?calls['session']?.cast<Map<Object?, Object?>>()];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_read_on');
    calls.clear();
    asked.clear();
    head = 0;
    queued = 0;
    onStop = null;
    onCancel = null;
    outside = null;
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    // As the app sets it: every player's start is seen.
    PlaybackScheduler.beforePlay = BackgroundReading.claim;
    before = SourceEngine.instance;
    site = _Site()..attach(_Installed(tmp));
    SourceEngine.instance = site;
    var n = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      (calls[call.method] ??= []).add(call.arguments);
      switch (call.method) {
        case 'synthesise':
          asked.add((call.arguments as Map)['text'] as String);
          final f = File('${tmp.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
          return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
        case 'playerEnqueue':
          final start = queued;
          queued += ((call.arguments as Map)['pcm'] as Uint8List).length ~/ 2;
          return start;
        case 'playerStop':
          final hold = onStop;
          onStop = null;
          if (hold != null) await hold();
          queued = 0;
          head = 0;
          return null;
        case 'cancelSynthesis':
          final hold = onCancel;
          onCancel = null;
          if (hold != null) await hold();
          return null;
        case 'playerPosition':
          return head;
        case 'requestFocus':
          return 'granted';
        case 'takeMediaPlay':
          final a = outside;
          outside = null;
          return a;
        case 'listEngines':
        case 'listVoices':
          return const [];
        case 'outputDir':
          return tmp.path;
      }
      return null;
    });
  });

  tearDown(() async {
    await BackgroundReading.current.value?.stop();
    messenger.setMockMethodCallHandler(_channel, null);
    SourceEngine.instance = before;
    PlaybackScheduler.beforePlay = null;
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// A web novel of [chapters] on the site, the first [onPhone] of them
  /// downloaded, its place in chapter [at] (from 0): a window of its
  /// chapters round there is 20 to 59.
  Future<(LibraryStore, String)> novel({int chapters = 70, int onPhone = 60, int at = 30}) async {
    final store = LibraryStore(tmp);
    final id = (await store.addWebNovel(
      _plugin,
      SourceNovel(path: 'n', name: 'Novel', chapters: [
        for (var i = 0; i < chapters; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
      ]),
    ))
        .id;
    for (var i = 0; i < onPhone; i++) {
      await store.saveChapter(id, i, 'Chapter ${i + 1}', _chapter(i));
    }
    await store.saveCursor(id, ReadingCursor(sectionIndex: at), 0.4);
    return (store, id);
  }

  /// [id] read in the background from its place, as the library's player reads it.
  Future<BackgroundReading> listen(LibraryStore store, String id) async {
    final entry = (await store.list(all: true)).firstWhere((e) => e.id == id);
    await BackgroundReading.startFrom(store, entry);
    return BackgroundReading.current.value!;
  }

  /// The chapter [bg] reads, from 0.
  int reading(BackgroundReading bg) => bg.layout.units[bg.player.unit.value.clamp(0, bg.layout.units.length - 1)].sectionIndex;

  /// What is wrong with what the [card] was told while the reading went
  /// on, or null for nothing.
  String? stopped(List<Map<Object?, Object?>> card) {
    if (card.isEmpty) return 'the card was told nothing';
    if (card.any((s) => s['active'] != true)) return 'the card was taken away';
    if (card.any((s) => s['playing'] != true)) {
      return 'the card was told the reading had stopped: Android 12+ takes it out of the foreground for good';
    }
    return null;
  }

  group('the card says playing all the way', () {
    test("read in the background past its window's end, into chapters fetched then", () async {
      final (store, id) = await novel();
      final bg = await listen(store, id);
      expect(bg.layout.chapters.last, 59);
      // The chapters after the window cannot be had yet (offline), so none
      // are joined on as the voice nears the end: it reaches it.
      site.offline = true;
      final enqueued = count('playerEnqueue');
      await bg.player.play(bg.layout.units.length - 1);
      await _until(() => count('playerEnqueue') > enqueued);
      final from = sessions().length;
      // Back online as the voice stops at the end: fetched, and read on into.
      onStop = () async {
        site.offline = false;
      };
      head = 1 << 30;
      await _until(() => bg.player.isPlaying && reading(bg) > 59);
      expect(reading(bg), 60, reason: 'it did not read on at the next chapter');
      expect(stopped(sessions().sublist(from)), isNull);
    });

    test("handed on by a book's page at the end of its chapters", () async {
      final (store, id) = await novel();
      final layout = await store.loadLayout(id, around: 30);
      final view = _Page(web: true);
      final page = ReaderController(
        layout: layout,
        view: view,
        initialCursor: const ReadingCursor(sectionIndex: 59),
        store: store,
      );
      addTearDown(page.dispose);
      await page.goTo(layout.units.length - 1, play: true);
      await _until(() => page.player.isPlaying && count('playerEnqueue') > 0);
      final from = sessions().length;
      head = 1 << 30;
      await _until(() => BackgroundReading.current.value?.player.isPlaying ?? false);
      final bg = BackgroundReading.current.value!;
      expect(reading(bg), 60, reason: 'it did not read on at the next chapter');
      expect(view.reached, [true]);
      expect(stopped(sessions().sublist(from)), isNull);
    });

    test('started from outside the app (the resume card, a headset, Android Auto)', () async {
      final (store, id) = await novel();
      outside = {'book': id, 'reading': false};
      await MediaRequests.take(() async => store);
      final bg = BackgroundReading.current.value;
      expect(bg?.bookId, id);
      await _until(() => bg!.player.isPlaying);
      expect(stopped(sessions()), isNull);
    });
  });

  group('chapters joined on as the voice finishes are read, not passed over', () {
    test('in the background', () async {
      final (store, id) = await novel();
      final bg = await listen(store, id);
      // The chapters after the window come from the site as the voice
      // reads its last sentence: held until it has finished.
      final gate = site.gate = Completer<void>();
      final enqueued = count('playerEnqueue');
      await bg.player.play(bg.layout.units.length - 1);
      await _until(() => count('playerEnqueue') > enqueued);
      final from = sessions().length;
      // They are joined on while the player stops at the end.
      onStop = () async {
        site.gate = null;
        gate.complete();
        await _until(() => bg.layout.chapters.contains(60));
      };
      head = 1 << 30;
      await _until(() => bg.player.isPlaying && reading(bg) > 59);
      expect(bg.layout.chapters, containsAll([60, 61, 62]));
      expect(reading(bg), 60, reason: 'the chapters joined on were passed over');
      await _until(() => asked.any((t) => t.startsWith('Part 61 ')));
      expect(asked.where((t) => t.startsWith('Part 61 ')), isNotEmpty);
      expect(stopped(sessions().sublist(from)), isNull);
    });

    test("on a book's page, handing its reading on", () async {
      final (store, id) = await novel(onPhone: 63);
      final layout = await store.loadLayout(id, around: 30);
      expect(layout.chapters.last, 59);
      final longer = (await joinNextChapters(store, id, layout))!;
      expect(longer.chapters.last, 62);
      final page = ReaderController(
        layout: layout,
        view: _Page(web: true),
        initialCursor: const ReadingCursor(sectionIndex: 59),
        store: store,
      );
      addTearDown(page.dispose);
      await page.goTo(layout.units.length - 1, play: true);
      await _until(() => page.player.isPlaying && count('playerEnqueue') > 0);
      // The page's window grows (WebNovelReader joins the next chapters on)
      // while its voice stops at the end of what it had.
      var widened = false;
      onStop = () async {
        widened = page.widen(longer);
      };
      head = 1 << 30;
      await _until(() => BackgroundReading.current.value?.player.isPlaying ?? false);
      expect(widened, isTrue);
      final bg = BackgroundReading.current.value!;
      expect(reading(bg), 60, reason: 'the chapters joined on were passed over');
    });
  });

  test("a page moved while paused, and another book started from outside: the page leaves that book's card alone",
      () async {
    final store = LibraryStore(tmp);
    final books = <LibraryEntry>[];
    for (final name in ['alpha.txt', 'beta.txt']) {
      final f = File('${tmp.path}/incoming/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 30}\n\n'
            'Chapter 2\n\n${'It keeps going here. ' * 30}');
      books.add(await store.importFile(PickedFile(path: f.path, name: name)));
    }
    final (a, b) = (books.first, books.last);
    final view = _Page();
    final page = ReaderController(
      layout: await store.loadLayout(a.id),
      view: view,
      initialCursor: ReadingCursor.zero,
      store: store,
    );
    await page.togglePlay();
    await _until(() => page.player.isPlaying && count('playerEnqueue') > 0);
    await page.togglePlay();
    expect(page.player.state.value, PlayState.paused);
    // Moved while paused (the card's Next): its voice stops, and the card
    // stays up, paused there.
    await page.goTo(5);
    expect(page.player.state.value, PlayState.idle);
    expect(sessions().last['book'], a.id);
    expect(sessions().last['playing'], isFalse);

    // Android Auto starts the other book.
    outside = {'book': b.id, 'reading': true};
    await MediaRequests.take(() async => store);
    final bg = BackgroundReading.current.value!;
    expect(bg.bookId, b.id);
    await _until(() => bg.player.isPlaying);
    final from = sessions().length;

    // The page, still there with the app in the background, moves its
    // place (scrolled), and is then closed.
    page.moveQuietly(8);
    view.mounted = false;
    page
      ..leaving = true
      ..dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final after = sessions().sublist(from);
    expect(after.where((s) => s['active'] == false), isEmpty,
        reason: "the page ended the other book's card, and with it its audio and the phone kept awake");
    expect(after.where((s) => s['book'] == a.id), isEmpty, reason: 'the page put its own book back on the card');
    expect(identical(BackgroundReading.current.value, bg), isTrue);
    expect(bg.player.isPlaying, isTrue);
  });
}

/// The site: a chapter asked for waits for [gate] while it is set, and
/// cannot be had while [offline]. Its list never grows.
class _Site extends SourceEngine {
  _Site() : super.forTests();

  Completer<void>? gate;
  var offline = false;

  @override
  Future<String> chapter(PluginInfo p, String path) async {
    final wait = gate;
    if (wait != null) await wait.future;
    if (offline) throw const SocketException('offline');
    return _chapter(int.parse(path.substring(1)));
  }

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async => throw const SocketException('offline');
}

/// The site's plugin, installed.
class _Installed extends SourceStore {
  _Installed(super.root) : super(defaults: const []);

  @override
  Future<List<PluginInfo>> installed() async => const [_plugin];

  @override
  Future<PluginInfo?> installedById(String id) async => id == _plugin.id ? _plugin : null;
}

/// A book's page, as its reading sees it; [web] for a web novel's, whose
/// next chapters are still on the site.
class _Page implements ReaderView {
  _Page({this.web = false});

  final bool web;

  @override
  bool mounted = true;

  /// What the page was told at the end of its chapters: whether it was read aloud.
  final reached = <bool>[];

  @override
  Future<void> Function({required bool playing, bool browse})? get onReachedEnd =>
      web ? ({required bool playing, bool browse = false}) async => reached.add(playing) : null;

  @override
  ValueChanged<int>? get onChapterChanged => null;

  @override
  double Function(int u)? get progressOf => null;

  @override
  void changed() {}

  @override
  void reveal(int unit, {bool force = false}) {}

  @override
  void placeMoved() {}

  @override
  void say(String text) {}

  @override
  void saveLine() {}

  @override
  void turnPage(int delta) {}

  @override
  void playStateChanged() {}
}
