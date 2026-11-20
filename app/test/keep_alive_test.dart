// Long jobs kept going in the background (keep_alive.dart): the service is
// asked for as the first job begins and let go with the last, one
// notification says what runs, Android's daily limit holds the jobs until
// the app is in front again, a run that ended leaves where to go on from,
// and the battery hint is given once. And a book's memory: built on from
// the last chapter noted after the app was closed under it, never again
// from the start.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';
import 'package:tomevoice_spike/ai/memory/memory_builder.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/memory_service.dart';
import 'package:tomevoice_spike/ai/memory/word_index.dart';
import 'package:tomevoice_spike/keep_alive.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/speech_service.dart';

/// The platform's service as a test sees it.
class _Service implements KeepAlivePlatform {
  final shown = <KeepAliveNotice>[];
  var stops = 0;

  /// What it answers: false, as Android refusing to start it.
  var up = true;

  @override
  Future<bool> show(KeepAliveNotice notice) async {
    shown.add(notice);
    return up;
  }

  @override
  Future<void> stop() async => stops++;
}

KeepAliveJob _downloads({void Function()? onStop, void Function()? onHold, void Function()? onGoOn}) =>
    KeepAliveJob(
      key: 'downloads',
      kind: KeepAliveKind.downloads,
      text: '3 to go',
      done: 1,
      total: 4,
      resumable: true,
      onStop: onStop,
      onHold: onHold,
      onGoOn: onGoOn,
    );

KeepAliveJob _memory(String book, {void Function()? onStop, void Function()? onHold, void Function()? onGoOn}) =>
    KeepAliveJob(
      key: 'memory:$book',
      kind: KeepAliveKind.memory,
      text: 'The Road',
      resumable: true,
      onStop: onStop,
      onHold: onHold,
      onGoOn: onGoOn,
    );

/// A moment for the platform's answers to land.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

// No test binding: with it every HTTP request answers 400, and the memory's
// tests ask a server of their own.
void main() {
  group('the jobs', () {
    test('the service is asked for as the first job begins, told of each change, and let go with the last', () async {
      final service = _Service();
      final keep = LongJobs.forTests(service, inFront: () => true, exempt: () async => true);
      keep.begin(_downloads());
      expect(keep.busy, isTrue);
      expect(service.shown, hasLength(1), reason: 'at once, as the job begins');
      expect(service.shown.last.title, 'Downloading chapters');
      expect(service.shown.last.text, '3 to go');
      expect((service.shown.last.done, service.shown.last.total), (1, 4));
      expect(service.shown.last.paused, 'Downloads paused');

      keep.begin(_memory('b'));
      await _settle();
      expect(service.shown.last.title, 'Downloading chapters', reason: 'the first begun leads');
      expect(service.shown.last.text, '3 to go · also building a memory');
      expect(service.shown.last.paused, 'Downloads and memory building paused');

      keep.update('downloads', text: '2 to go', done: 2);
      expect(service.shown.last.text, '2 to go · also building a memory');
      expect(service.shown.last.done, 2);
      await _settle();
      final told = service.shown.length;
      keep.update('downloads', text: '2 to go', done: 2);
      expect(service.shown, hasLength(told), reason: 'nothing new, nothing sent');

      keep.end('downloads');
      expect(service.shown.last.title, 'Building a memory');
      expect(service.shown.last.text, 'The Road');
      expect(service.stops, 0);
      expect(keep.busy, isTrue);

      keep.end('memory:b');
      expect(keep.busy, isFalse);
      expect(service.stops, 1, reason: 'the last one ended');
      keep.end('memory:b');
      expect(service.stops, 1, reason: 'ended twice, let go once');
    });

    test('a second start of the same work leaves it to the first', () {
      final service = _Service();
      final keep = LongJobs.forTests(service, inFront: () => false);
      final first = _memory('b');
      final second = _memory('b');
      keep.begin(first);
      keep.begin(second);
      expect(keep.jobs, hasLength(1));
      keep.end('memory:b', job: second);
      expect(keep.isRunning('memory:b'), isTrue, reason: 'the second found it running, and leaves it');
      keep.end('memory:b', job: first);
      expect(keep.isRunning('memory:b'), isFalse);
      expect(service.stops, 1);
    });

    test("the notification's Stop stops each job as its own Stop would", () async {
      final keep = LongJobs.forTests(_Service(), inFront: () => false);
      final stopped = <String>[];
      keep.begin(_downloads(onStop: () => stopped.add('downloads')));
      keep.begin(_memory('b', onStop: () => stopped.add('memory')));
      await keep.platformEvent('stop');
      expect(stopped, ['downloads', 'memory']);
    });

    test('refused (the app behind other apps): asked again once the app is in front', () async {
      final service = _Service()..up = false;
      final keep = LongJobs.forTests(service, inFront: () => false);
      keep.begin(_downloads());
      await _settle();
      expect(service.shown, hasLength(1));
      service.up = true;
      keep.cameToFront();
      await _settle();
      expect(service.shown, hasLength(2));
      // Up now: the same again is not sent.
      keep.update('downloads', text: '3 to go');
      expect(service.shown, hasLength(2));
    });

    test('what is said, in plain words', () {
      expect(pickedUpLine([KeepAliveKind.downloads]), 'Chapter downloads go on from where they stopped.');
      expect(pickedUpLine([KeepAliveKind.memory]), 'Memory building goes on from where it stopped.');
      expect(pickedUpLine([KeepAliveKind.downloads, KeepAliveKind.memory]),
          'Chapter downloads and memory building go on from where they stopped.');
      expect(heldLine([KeepAliveKind.memory]),
          'Memory building paused while TomeVoice was away: Android allows six hours a day. It goes on now.');
      expect(heldLine([KeepAliveKind.downloads, KeepAliveKind.memory]),
          startsWith('Downloads and memory building paused while TomeVoice was away'));
      final voice = KeepAliveJob(key: 'voice:x', kind: KeepAliveKind.voice, text: 'Alba');
      expect(keepAliveNotice([voice]).title, 'Downloading a voice');
      expect(keepAliveNotice([voice]).paused, 'The voice download paused');
      expect(keepAliveNotice(const []).title, '');
    });
  });

  group("Android's daily limit", () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tv_keep'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    test('each job is held and the service let go; in front again, they go on and the reader is told', () async {
      final service = _Service();
      final said = <String>[];
      var front = false;
      final keep = LongJobs.forTests(service,
          inFront: () => front, say: (text, {action, onAction}) => said.add(text));
      await keep.attach(tmp);
      final held = <String>[], goneOn = <String>[];
      final d = _downloads(onHold: () => held.add('downloads'), onGoOn: () => goneOn.add('downloads'));
      final m = _memory('b', onHold: () => held.add('memory'), onGoOn: () => goneOn.add('memory'));
      keep.begin(d);
      keep.begin(m);
      await keep.platformEvent('timeout');
      expect(held, ['downloads', 'memory']);
      expect(keep.busy, isFalse);
      expect(keep.held, isTrue);
      expect(service.stops, 1);
      // The memory's build lands its last batch and ends: still written
      // down, to go on.
      keep.end('memory:b', job: m);
      await keep.settled();
      expect(_resumeIn(tmp), containsAll(['downloads', 'memory:b']));

      // Behind other apps still: nothing goes on.
      expect(goneOn, isEmpty);
      front = true;
      keep.cameToFront();
      expect(goneOn, ['downloads', 'memory']);
      expect(keep.held, isFalse);
      expect(said.single, startsWith('Downloads and memory building paused while TomeVoice was away'));
    });

    test('nothing running: nothing to hold', () async {
      final service = _Service();
      final keep = LongJobs.forTests(service, inFront: () => true);
      await keep.platformEvent('timeout');
      expect(keep.held, isFalse);
      expect(service.stops, 0);
    });
  });

  group('where to go on from', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tv_keep'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    test('written down while a job runs, and gone when it ends', () async {
      final keep = LongJobs.forTests(_Service(), inFront: () => true);
      await keep.attach(tmp);
      keep.begin(_memory('b'), hint: false);
      keep.begin(KeepAliveJob(key: 'voice:x', kind: KeepAliveKind.voice));
      await keep.settled();
      expect(_resumeIn(tmp), ['memory:b'], reason: 'a voice download is not picked up by itself');
      keep.end('memory:b');
      await keep.settled();
      expect(_resumeIn(tmp), isEmpty);
    });

    test('a run that ended under a job: picked up the next time, and said once', () async {
      File('${tmp.path}/keep_alive.json').writeAsStringSync(jsonEncode({
        'resume': ['downloads', 'memory:b', 'memory:c'],
      }));
      final said = <String>[];
      final keep = LongJobs.forTests(_Service(),
          inFront: () => true, say: (text, {action, onAction}) => said.add(text), exempt: () async => true);
      await keep.attach(tmp);
      expect(keep.leftOver('memory:'), ['memory:b', 'memory:c']);
      keep.begin(_downloads());
      keep.begin(_memory('b'));
      // Not to go on (paused since, say): let go of.
      keep.end('memory:c');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(said, ['Chapter downloads and memory building go on from where they stopped.']);
      expect(keep.leftOver('memory:'), isEmpty);
      await keep.settled();
      expect(_resumeIn(tmp), unorderedEquals(['downloads', 'memory:b']));
    });

    test('a broken file: nothing to pick up', () async {
      File('${tmp.path}/keep_alive.json').writeAsStringSync('{not json');
      final keep = LongJobs.forTests(_Service(), inFront: () => true);
      await keep.attach(tmp);
      expect(keep.leftOver(''), isEmpty);
    });

    test('what waits for the app to be in front runs then, once', () {
      var front = false;
      final keep = LongJobs.forTests(_Service(), inFront: () => front);
      var ran = 0;
      keep.whenInFront(() => ran++);
      expect(ran, 0);
      front = true;
      keep.cameToFront();
      keep.cameToFront();
      expect(ran, 1);
      keep.whenInFront(() => ran++);
      expect(ran, 2, reason: 'in front already: at once');
    });
  });

  group('the battery hint', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tv_keep'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    test('once ever, only while battery saving holds TomeVoice back, with the setting a tap away', () async {
      final said = <(String, String?)>[];
      LongJobs make(bool exempt) => LongJobs.forTests(_Service(),
          inFront: () => true,
          exempt: () async => exempt,
          say: (text, {action, onAction}) => said.add((text, action)));

      final allowed = make(true);
      await allowed.attach(tmp);
      allowed.begin(_downloads());
      await _settle();
      expect(said, isEmpty, reason: 'battery saving leaves it alone');
      allowed.end('downloads');
      await allowed.settled();

      final keep = make(false);
      await keep.attach(tmp);
      keep.begin(_memory('b'), hint: false);
      await _settle();
      expect(said, isEmpty, reason: 'not one the reader started');
      keep.begin(_downloads());
      await _settle();
      expect(said.single.$1, 'Battery saving can stop this with the screen off.');
      expect(said.single.$2, 'Allow');
      expect(keep.hinted, isTrue);
      keep.end('downloads');
      keep.begin(_downloads());
      await _settle();
      expect(said, hasLength(1), reason: 'once');

      // Remembered with the library.
      keep.end('downloads');
      keep.end('memory:b');
      await keep.settled();
      final again = make(false);
      await again.attach(tmp);
      again.begin(_downloads());
      await _settle();
      expect(said, hasLength(1));
    });

    test('never with the app behind other apps', () async {
      final said = <String>[];
      final keep = LongJobs.forTests(_Service(),
          inFront: () => false, exempt: () async => false, say: (text, {action, onAction}) => said.add(text));
      await keep.attach(tmp);
      keep.begin(_downloads());
      await _settle();
      expect(said, isEmpty);
    });
  });

  group("a book's memory", () {
    late Directory tmp;
    late LibraryStore store;
    late HttpServer server;
    late List<int> asked;
    late Future<void> Function(HttpRequest req, Map<String, Object?> body) answer;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tv_keep_memory');
      store = LibraryStore(tmp);
      AiRing.instance.reset();
      asked = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = (jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, Object?>();
        await answer(req, body);
      });
      await AiRing.instance.put(AiKey(
        id: 'k',
        provider: AiProvider.custom,
        label: 'Test',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        secret: 's',
        models: const {AiJob.builder: 'test-model'},
      ));
    });

    tearDown(() async {
      MemoryService.instance.reset();
      await server.close(force: true);
      AiRing.instance.reset();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold a file.
      }
    });

    /// Notes for every chapter the request carries, and which they were.
    Future<void> notes(HttpRequest req, Map<String, Object?> body) async {
      final prompt = ((body['messages'] as List).last as Map)['content'] as String;
      final chs = [for (final m in RegExp(r'### ch: (\d+)').allMatches(prompt)) int.parse(m.group(1)!)];
      asked.addAll(chs);
      final content = jsonEncode({
        'chapters': [
          for (final ch in chs)
            {
              'ch': ch,
              'summary': 'Chapter $ch happens.',
              'entities': [
                {'ref': 'new:Mira', 'kind': 'person', 'name': 'Mira'},
              ],
            },
        ],
      });
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 100, 'completion_tokens': 20},
      }));
      await req.response.close();
    }

    Future<String> book(int chapters) async {
      final text =
          [for (var i = 0; i < chapters; i++) '# Chapter ${i + 1}: Part\n\nMira walked on. The road was long.'].join('\n\n');
      final f = File('${tmp.path}/incoming/road.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      final id = (await store.importFile(PickedFile(path: f.path, name: 'road.md'))).id;
      await WordIndexer(store).index(id);
      return id;
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(done(), isTrue, reason: 'did not happen in time');
    }

    int notedIn(String id) {
      final m = MemoryDb.open(MemoryDb.pathIn(store.bookDir(id)));
      try {
        return m.db.select('SELECT count(*) n FROM chapters WHERE noted = 1').first['n'] as int;
      } finally {
        m.close();
      }
    }

    test('closed under a build: built on from the last chapter noted the next time, and said', () async {
      final id = await book(4);
      final path = MemoryDb.pathIn(store.bookDir(id));
      // The first run: two chapters noted, then the app was closed under it
      // (the build stopped where it stood, with no pause of the reader's).
      answer = notes;
      final first = MemoryBuilder(path: path, router: AiRouter(pause: Duration.zero), limits: (tokens: 40000, chapters: 2));
      answer = (req, body) async {
        first.pause();
        await notes(req, body);
      };
      await first.run();
      expect(notedIn(id), 2);
      final m = MemoryDb.open(path)..setMeta('begun', '1');
      m.close();
      File('${tmp.path}/keep_alive.json').writeAsStringSync(jsonEncode({
        'resume': ['memory:$id'],
      }));

      // The next run.
      asked.clear();
      answer = notes;
      final said = <String>[];
      final keep = LongJobs.forTests(_Service(),
          inFront: () => true, exempt: () async => true, say: (text, {action, onAction}) => said.add(text));
      await keep.attach(tmp);
      final service = MemoryService.instance
        ..reset()
        ..keepAlive = keep
        ..attach(store, router: AiRouter(pause: Duration.zero));
      await service.resumeInterrupted();
      await until(() => notedIn(id) == 4 && !service.isBuilding(id) && !keep.busy);
      expect(asked, isNot(contains(0)), reason: 'a chapter noted is never sent again');
      expect(asked, isNot(contains(1)));
      expect(asked, containsAll([2, 3]));
      expect(said, contains('Memory building goes on from where it stopped.'));
      await keep.settled();
      expect(_resumeIn(tmp), isEmpty, reason: 'built: nothing more to go on with');
    });

    test('paused by the reader since: not built on by itself', () async {
      final id = await book(2);
      final path = MemoryDb.pathIn(store.bookDir(id));
      final m = MemoryDb.open(path)
        ..setMeta('begun', '1')
        ..setMeta('paused', '1');
      m.close();
      File('${tmp.path}/keep_alive.json').writeAsStringSync(jsonEncode({
        'resume': ['memory:$id'],
      }));
      answer = notes;
      final keep = LongJobs.forTests(_Service(), inFront: () => true, exempt: () async => true);
      await keep.attach(tmp);
      final service = MemoryService.instance
        ..reset()
        ..keepAlive = keep
        ..attach(store, router: AiRouter(pause: Duration.zero));
      await service.resumeInterrupted();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(asked, isEmpty);
      expect(keep.busy, isFalse);
      await keep.settled();
      expect(_resumeIn(tmp), isEmpty, reason: 'let go of');
    });

    test("held by Android's daily limit: the batch on its way lands, and it goes on once the app is in front",
        () async {
      final id = await book(6);
      final gate = Completer<void>();
      var calls = 0;
      answer = (req, body) async {
        calls++;
        if (calls == 1) await gate.future;
        await notes(req, body);
      };
      final service = _Service();
      final said = <String>[];
      final keep = LongJobs.forTests(service,
          inFront: () => true, exempt: () async => true, say: (text, {action, onAction}) => said.add(text));
      await keep.attach(tmp);
      final memory = MemoryService.instance
        ..reset()
        ..keepAlive = keep
        ..attach(store, router: AiRouter(pause: Duration.zero));
      final building = memory.build(id);
      await until(() => calls == 1);
      expect(keep.isRunning('memory:$id'), isTrue);
      expect(service.shown.first.title, 'Building a memory');
      await keep.platformEvent('timeout');
      gate.complete();
      await building;
      final landed = notedIn(id);
      expect(landed, inInclusiveRange(1, 5), reason: 'the batch on its way landed, and no more');
      expect(keep.busy, isFalse);
      // Not the reader's pause: nothing written into the memory.
      final m = MemoryDb.open(MemoryDb.pathIn(store.bookDir(id)));
      expect(m.meta('paused'), isNull);
      m.close();
      await keep.settled();
      expect(_resumeIn(tmp), ['memory:$id']);

      keep.cameToFront();
      expect(said.single, startsWith('Memory building paused while TomeVoice was away'));
      await until(() => notedIn(id) == 6 && !memory.isBuilding(id) && !keep.busy);
      await keep.settled();
      expect(_resumeIn(tmp), isEmpty);
    });

    test("the notification's Stop is the reader's Pause", () async {
      final id = await book(6);
      final gate = Completer<void>();
      var calls = 0;
      answer = (req, body) async {
        calls++;
        if (calls == 1) await gate.future;
        await notes(req, body);
      };
      final keep = LongJobs.forTests(_Service(), inFront: () => false);
      final memory = MemoryService.instance
        ..reset()
        ..keepAlive = keep
        ..attach(store, router: AiRouter(pause: Duration.zero));
      final building = memory.build(id);
      await until(() => calls == 1);
      await keep.platformEvent('stop');
      gate.complete();
      await building;
      expect(keep.busy, isFalse);
      expect(memory.stateOf(id).value.build.phase, BuildPhase.paused);
      // Kept paused: not built on as it is read, nor with the app closed.
      await until(() {
        final m = MemoryDb.open(MemoryDb.pathIn(store.bookDir(id)));
        try {
          return m.meta('paused') == '1';
        } finally {
          m.close();
        }
      });
    });
  });
}

List<Object?> _resumeIn(Directory tmp) {
  final f = File('${tmp.path}/keep_alive.json');
  if (!f.existsSync()) return const [];
  return (jsonDecode(f.readAsStringSync()) as Map)['resume'] as List? ?? const [];
}
