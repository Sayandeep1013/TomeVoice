// Listening, polished: a jump that does not wait for the sentences it
// overtook, a paused book that costs nothing, natural voices let go when
// they are not read with, a long web novel read a window of chapters at a
// time with no break at the window's edge, and the sleep timer's fade.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart' show PipelineSettings;
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/web_reader.dart';

const _channel = MethodChannel('tomevoice/tts');

/// The first sentence is long and has its clauses: a natural voice makes it
/// in three pieces.
const _long = 'The rain came down over the harbour all night, and the boats knocked together at '
    'their moorings, while the keeper slept on in his chair by the lamp.';

final _book = ingestString(
  [
    '# Chapter 1: Harbour',
    '$_long Then morning came. The gulls woke first. A bell rang out.',
    'The keeper rose at last. He looked out to sea. Nothing moved there.',
    'A boat came in at noon. It carried letters. One was for him.',
    'He read it twice. Then he laughed. The sea was calm.',
  ].join('\n\n'),
  filename: 'harbour.md',
);

/// Until [done] holds, or [within] has passed.
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!done() && watch.elapsed < within) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A WAV of [seconds] of quiet at [rate], written to [path].
String _quiet(String path, {double seconds = 0.1, int rate = 24000}) {
  File(path).writeAsBytesSync(wavBytes(Float32List((rate * seconds).round()), rate));
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final layout = ReadingLayout.build(_book);
  final text = [for (final u in layout.units) u.text];

  late Directory tmp;

  /// What the platform was asked, by method, and the texts it was asked to say.
  final calls = <String, List<Object?>>{};
  final asked = <String>[];

  /// The phone's voice holds the next sentence it is asked for until this
  /// completes (a long one, under way when a jump comes).
  Completer<void>? hold;

  /// Where the player's head is; it creeps on with every look, so the
  /// scheduler never takes it for a player that died.
  var head = 0;
  var queued = 0;

  int count(String method) => calls[method]?.length ?? 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_listening');
    calls.clear();
    asked.clear();
    hold = null;
    head = 0;
    queued = 0;
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    var n = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      (calls[call.method] ??= []).add(call.arguments);
      switch (call.method) {
        case 'synthesise':
          final said = (call.arguments as Map)['text'] as String;
          asked.add(said);
          final wait = hold;
          if (wait != null) {
            hold = null;
            await wait.future;
          }
          return <String, Object?>{
            'wavPath': _quiet('${tmp.path}/s${n++}.wav'),
            'engineId': 'test',
            'rangeEvents': const [],
          };
        case 'playerEnqueue':
          final start = queued;
          queued += ((call.arguments as Map)['pcm'] as Uint8List).length ~/ 2;
          return start;
        case 'playerStop':
          queued = 0;
          head = 0;
          return null;
        case 'playerPosition':
          return head < queued ? ++head : head;
        case 'requestFocus':
          return 'granted';
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
    NeuralEngine.workerForTests = null;
    NeuralEngine.instance.forgetWorkerForTests();
    NeuralEngine.instance.idleAfter = NeuralEngine.idleUnload;
    _Worker.closeAll();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  PlaybackScheduler scheduler({String? voice}) => PlaybackScheduler(
        service: const SpeechService(),
        units: layout.units,
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => voice,
        pauseAfter: (_) => 100,
      );

  group('a jump', () {
    test('drops the sentences it overtook, and the one jumped to is made next', () async {
      final player = scheduler();
      addTearDown(player.dispose);
      hold = Completer<void>();
      final first = hold!;
      unawaited(player.play(0));
      await _until(() => asked.isNotEmpty);
      expect(asked, [text[0]], reason: 'the first sentence is being made');

      // Two jumps while it is made: the first one's sentence waits its turn.
      unawaited(player.play(5));
      await _until(() => count('requestFocus') == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      unawaited(player.play(9));
      await _until(() => count('requestFocus') == 3);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, [text[0]], reason: 'nothing else is made while one is');

      first.complete();
      await _until(() => count('playerEnqueue') > 0);
      expect(asked.take(2), [text[0], text[9]], reason: 'the sentence jumped to is made next');
      expect(asked, isNot(contains(text[5])), reason: 'a sentence nobody will hear was made');
      expect(player.unit.value, 9);
      await player.stop();
    });

    test('with a natural voice, the sentence being made stops at its next piece, and the one jumped to is made next',
        () async {
      final worker = _Worker();
      NeuralEngine.workerForTests = worker.start;
      final player = scheduler(voice: 'neural:en_US-kristin-medium');
      addTearDown(player.dispose);
      final long = text.indexOf(_long);
      expect(long, isNonNegative);
      worker.hold = Completer<void>();
      final piece = worker.hold!;
      unawaited(player.play(long));
      await _until(() => worker.said.isNotEmpty);
      final pieces = clausePieces(_long);
      expect(pieces, hasLength(3), reason: 'a long sentence is made in pieces');
      expect(worker.said, [pieces.first.text]);

      unawaited(player.play(long + 4));
      await _until(() => count('requestFocus') == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      piece.complete();
      await _until(() => worker.said.length >= 2);
      expect(worker.said[1], text[long + 4], reason: 'the sentence jumped to is made next');
      expect(worker.said, isNot(contains(pieces[1].text)), reason: 'the rest of the overtaken sentence was made');
      expect(worker.ops.where((m) => m['op'] == 'drop'), isNotEmpty, reason: 'its first piece is not kept');
      await _until(() => count('playerEnqueue') > 0);
      expect(player.unit.value, long + 4);
      await player.stop();
    });
  });

  group('while paused', () {
    test('nothing is polled or made, and both start again on Play', () async {
      final service = _Player(tmp);
      final player = PlaybackScheduler(
        service: service,
        units: [for (var i = 0; i < 40; i++) ...layout.units],
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => null,
        pauseAfter: (_) => 100,
      );
      addTearDown(player.dispose);
      // Every timer the scheduler sets, and which of them repeat.
      final timers = <Timer>[];
      final repeating = <Timer>[];
      final spec = ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          final t = parent.createTimer(zone, duration, f);
          timers.add(t);
          return t;
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          final t = parent.createPeriodicTimer(zone, period, f);
          timers.add(t);
          repeating.add(t);
          return t;
        },
      );
      Future<void> inZone(Future<void> Function() f) => runZoned(f, zoneSpecification: spec);

      await inZone(() => player.play(0));
      // Ten seconds queued ahead (a second a sentence): it waits for room.
      await _until(() => service.made >= 10);
      expect(repeating.where((t) => t.isActive), hasLength(1), reason: 'the head is followed while it plays');
      await inZone(() => player.pause());
      // A sentence under way when it paused is finished.
      var made = -1;
      while (made != service.made) {
        made = service.made;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      final set = timers.length;
      final polled = service.polled;
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(repeating.where((t) => t.isActive), isEmpty, reason: 'the 40 ms poll ran on while paused');
      expect(timers.length, set, reason: 'something woke on a timer while paused');
      expect(service.polled, polled, reason: 'the head was asked for while paused');
      expect(service.made, made, reason: 'speech was made while paused');

      await inZone(() => player.resume());
      expect(repeating.where((t) => t.isActive), hasLength(1));
      await _until(() => service.polled > polled);
      expect(service.polled, greaterThan(polled), reason: 'Play did not follow the head again');
      await player.stop();
    });
  });

  group('natural voices', () {
    late _Worker worker;

    setUp(() {
      worker = _Worker();
      NeuralEngine.workerForTests = worker.start;
    });

    test('a voice switched away from is let go at once, before the next one loads', () async {
      var voice = 'neural:en_US-kristin-medium';
      final player = PlaybackScheduler(
        service: const SpeechService(),
        units: layout.units,
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => voice,
        pauseAfter: (_) => 100,
      );
      addTearDown(player.dispose);
      unawaited(player.play(0));
      await _until(() => worker.said.length >= 4);
      expect(worker.held, ['en_US-kristin-medium']);

      // Another voice chosen: reading starts again with it.
      voice = 'neural:en_US-norman-medium';
      unawaited(player.play(player.unit.value));
      await _until(() => worker.ops.any((m) => m['op'] == 'say' && m['model'] == 'en_US-norman-medium'));
      final ops = worker.ops;
      final firstNorman = ops.indexWhere((m) => m['op'] == 'say' && m['model'] == 'en_US-norman-medium');
      final letGo = ops.indexWhere((m) => m['op'] == 'unload' && (m['keep'] as List?)?.join() == 'en_US-norman-medium');
      expect(letGo, isNonNegative, reason: 'Kristin was kept after the switch');
      expect(letGo, lessThan(firstNorman), reason: 'Norman loaded while Kristin was still held');
      expect(worker.held, ['en_US-norman-medium']);
      await player.stop();
    });

    test('a voice is let go a while after reading pauses, and loaded again for Play', () async {
      NeuralEngine.instance.idleAfter = const Duration(milliseconds: 400);
      final service = _Natural(tmp);
      final player = PlaybackScheduler(
        service: service,
        units: [for (var i = 0; i < 20; i++) ...layout.units],
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => 'neural:en_US-kristin-medium',
        pauseAfter: (_) => 100,
      );
      addTearDown(player.dispose);
      unawaited(player.play(0));
      await _until(() => worker.said.length >= 3);
      expect(worker.held, ['en_US-kristin-medium']);
      await player.pause();
      // Ten seconds are queued, and nothing more is made: then it is let go.
      await _until(() => worker.held.isEmpty);
      expect(worker.held, isEmpty, reason: 'the model stayed in memory while nothing was read');
      expect(worker.ops.last['op'], 'unload');
      expect(worker.ops.last['model'], isNull, reason: 'every voice goes');

      // Read from somewhere else: loaded again.
      unawaited(player.play(5));
      await _until(() => worker.held.isNotEmpty);
      expect(worker.held, ['en_US-kristin-medium']);
      await player.stop();
    });
  });

  group('a long web novel', () {
    late LibraryStore store;
    late String id;
    const chapters = _chapters;

    setUp(() async {
      store = LibraryStore(tmp);
      id = await _addNovel(tmp, store);
    });

    Future<BackgroundReading> listen() async {
      final entry = (await store.list(all: true)).firstWhere((e) => e.id == id);
      await BackgroundReading.startFrom(store, entry);
      return BackgroundReading.current.value!;
    }

    test('listening reads a window of its chapters round the place, not the whole novel', () async {
      final bg = await listen();
      final read = bg.layout.chapters;
      expect(read.first, 20, reason: 'ten chapters before the place');
      expect(read.last, 59, reason: 'thirty from it on');
      expect(bg.layout.units[bg.player.unit.value].sectionIndex, 30, reason: 'it reads from its place');
      expect(bg.player.units, hasLength(bg.layout.units.length));
    });

    test("near the window's end the next chapters are joined on, and the voice goes on into them unbroken",
        () async {
      final bg = await listen();
      final player = bg.player;
      final before = bg.layout;
      final lastChapter = before.chapterFirstUnit[before.chapters.length - 1];
      await player.play(lastChapter);
      final stops = count('playerStop');
      await _until(() => bg.layout.chapters.last == chapters - 1);
      expect(bg.layout.chapters.last, chapters - 1, reason: 'the chapters after the window were not joined on');
      expect(bg.layout.chapters.first, 20, reason: 'the window is not loaded again from the start of the novel');
      expect(identical(bg.player, player), isTrue, reason: 'a new player starts a new stream: a break');
      expect(player.units, hasLength(bg.layout.units.length));
      expect(continuesLayout(bg.layout, before), isTrue);

      // It reads on into them: no stop, no new start.
      await _until(() => asked.any((t) => t.startsWith('Part 61 ')));
      expect(asked.where((t) => t.startsWith('Part 61 ')), isNotEmpty, reason: 'the voice did not go on into them');
      expect(count('playerStop'), stops, reason: 'the stream was stopped between the chapters');
      expect(player.state.value, isNot(PlayState.idle));
    });

    test('a window that no longer reads the same is not joined on to', () async {
      final bg = await listen();
      final now = bg.layout;
      final other = await store.loadLayout(id, around: 45);
      expect(continuesLayout(other, now), isFalse);
      expect(continuesLayout(now, now), isTrue);
    });
  });

  testWidgets('a web novel opened while it reads in the background takes its voice back, unbroken', (tester) async {
    late LibraryStore store;
    late LibraryEntry entry;
    await tester.runAsync(() async {
      store = LibraryStore(tmp);
      final id = await _addNovel(tmp, store);
      entry = (await store.list(all: true)).firstWhere((e) => e.id == id);
      await BackgroundReading.startFrom(store, entry);
      // Read on to chapter 46, its place saved there: a window round it
      // would not be the one the voice reads.
      final bg = BackgroundReading.current.value!;
      await bg.player.play(bg.layout.units.indexWhere((u) => u.sectionIndex == 45));
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      await _until(() => count('playerEnqueue') > 0);
    });
    final bg = BackgroundReading.current.value!;
    final player = bg.player;
    final stops = count('playerStop');
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: WebNovelReader(store: store, entry: entry)));
    await tester.pump(const Duration(milliseconds: 100));
    // (Time for a page that loads its own chapters to do so.)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(BackgroundReading.current.value, isNull, reason: 'the page did not take the voice back');
    expect(count('playerStop'), stops, reason: 'the voice was stopped and started again');
    expect(player.isPlaying, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  group('the sleep timer', () {
    test('fades the voice over its last half minute, then pauses it; Play is at full volume again', () async {
      final service = _Player(tmp);
      final player = PlaybackScheduler(
        service: service,
        units: layout.units,
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => null,
        pauseAfter: (_) => 100,
      );
      await player.play(0);
      await _until(() => player.state.value == PlayState.playing);

      // Not yet in its last half minute: the voice stays as it is.
      player.fadeOutBy(DateTime.now().add(PlaybackScheduler.fadeLength + const Duration(milliseconds: 700)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(service.volumes, isEmpty, reason: 'it faded before its last half minute');
      await _until(() => service.volumes.isNotEmpty);
      expect(service.volumes.first, greaterThan(0.9), reason: 'the fade starts from full volume');
      player.endFade();
      expect(service.volumes.last, 1.0);

      // A timer about to run out: down to nothing, paused, then at full
      // volume for the next Play.
      service.volumes.clear();
      final bg = BackgroundReading.adopt(
        player: player,
        layout: layout,
        store: LibraryStore(tmp),
        bookId: '0123456789abcdef',
        title: 'Harbour',
        cover: null,
        language: 'en',
        web: false,
        sleepAt: DateTime.now().add(const Duration(milliseconds: 1600)),
        sleep: SleepChoice.min15,
      );
      await _until(() => player.state.value == PlayState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.state.value, PlayState.paused, reason: 'the timer did not stop the voice');
      final fade = service.volumes.sublist(0, service.volumes.length - 1);
      expect(fade, isNotEmpty);
      for (var i = 1; i < fade.length; i++) {
        expect(fade[i], lessThanOrEqualTo(fade[i - 1]), reason: 'the voice grew louder as it faded');
      }
      expect(fade.first, lessThan(0.01), reason: 'with a second and a half left, the voice is nearly gone');
      expect(service.volumes.last, 1.0, reason: 'Play after the timer would be silent');
      final settled = service.volumes.length;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(service.volumes, hasLength(settled), reason: 'the fade went on after the timer');
      await bg.stop();
    });
  });
}

/// How many chapters the long web novel has.
const _chapters = 80;

/// A web novel of [_chapters] chapters in [store], every one on the phone
/// (as a long novel downloaded whole is), its place in chapter 31; its id.
Future<String> _addNovel(Directory tmp, LibraryStore store) async {
  SourceEngine.instance.attach(SourceStore(tmp, defaults: const []));
  PlaybackScheduler.beforePlay ??= BackgroundReading.claim;
  const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
  final id = (await store.addWebNovel(
    plugin,
    SourceNovel(path: 'n', name: 'Novel', chapters: [
      for (var i = 0; i < _chapters; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
    ]),
  ))
      .id;
  for (var i = 0; i < _chapters; i++) {
    final section = webChapterSection(
      index: i,
      title: 'Chapter ${i + 1}',
      html: '<p>Part ${i + 1} of the story begins on this page. It ends here, for now.</p>',
    );
    File('${store.bookDir(id)}/ch/$i.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(section.toJson()));
  }
  await store.saveCursor(id, const ReadingCursor(sectionIndex: 30), 0.4);
  return id;
}

/// A stand-in for the natural voices' worker, run on the test's own
/// isolate: it answers as the worker does, holds the models it is asked for
/// (one at a time, as a phone with room for one does), and keeps every
/// message it was sent.
class _Worker {
  _Worker() {
    _all.add(this);
  }

  /// Every one made, to close after each test.
  static final _all = <_Worker>[];

  static void closeAll() {
    for (final w in _all) {
      w._inbox?.close();
    }
    _all.clear();
  }

  final ops = <Map<Object?, Object?>>[];
  final held = <String>[];
  ReceivePort? _inbox;

  /// The next piece waits for this before it is made.
  Completer<void>? hold;

  /// The pieces it was asked to make, in order.
  List<String> get said => [
        for (final m in ops)
          if (m['op'] == 'say') m['text']! as String,
      ];

  void start(SendPort engine) {
    final inbox = _inbox = ReceivePort();
    engine.send(inbox.sendPort);
    unawaited(_serve(inbox, engine));
  }

  Future<void> _serve(ReceivePort inbox, SendPort engine) async {
    // One message at a time, as the worker takes them.
    await for (final msg in inbox) {
      final m = Map<Object?, Object?>.from(msg as Map);
      ops.add(m);
      switch (m['op']) {
        case 'unload':
          final keep = m['keep'];
          held.removeWhere((v) => keep is List ? !keep.contains(v) : m['model'] == null || v == m['model']);
          engine.send({'id': m['id']});
        case 'say':
          final model = m['model']! as String;
          if (!held.contains(model)) {
            held
              ..clear()
              ..add(model);
          }
          final wait = hold;
          if (wait != null) {
            hold = null;
            await wait.future;
          }
          if (m['last'] == true) {
            final path = _quiet(m['out']! as String, seconds: 1, rate: 22050);
            engine.send({'id': m['id'], 'wav': path, 'loadMs': 0, 'joins': const <int>[], 'threads': const <int>[]});
          } else {
            engine.send({'id': m['id'], 'loadMs': 0, 'threads': const <int>[]});
          }
      }
    }
  }
}

/// A phone voice that says each line as a second of quiet, and a player
/// whose head moves only while it plays; it counts what it is asked.
class _Player extends SpeechService {
  _Player(this.dir);

  final Directory dir;
  var made = 0;
  var polled = 0;
  final volumes = <double>[];
  var _head = 0;
  var _frames = 0;
  var _paused = false;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async =>
      {'wavPath': _quiet('${dir.path}/p${made++}.wav', seconds: 1), 'engineId': 'test', 'rangeEvents': const []};

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

  /// The head creeps on (never past what is queued) while it plays.
  @override
  Future<int> position({bool raw = false}) async {
    polled++;
    if (!_paused && _head < _frames) _head++;
    return _head;
  }

  @override
  Future<String> requestFocus() async => SpeechService.focusGranted;

  @override
  Future<void> stopPlayback() async {
    _frames = 0;
    _head = 0;
  }

  @override
  Future<void> pausePlayback() async => _paused = true;

  @override
  Future<void> resumePlayback() async => _paused = false;

  @override
  Future<void> cancelSynthesis() async {}

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
}

/// The phone's player as [_Player] has it, with the voice itself the real
/// one: natural voices go to the engine (and so to the stand-in worker).
class _Natural extends _Player {
  _Natural(super.dir);

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) =>
      const SpeechService().synthesise(
          text: text, engineId: engineId, voiceName: voiceName, rate: rate, pitch: pitch, urgent: urgent);
}
