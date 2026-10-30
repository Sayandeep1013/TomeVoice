// Reading from outside the app: a book asked for by the system's resume
// card, a headset's Play or Android Auto (ReadAloudService asks Dart through
// "takeMediaPlay"), the library both ways into the app share, and Settings >
// Listening's row about reading with the screen off.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/home_shell.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('a book asked for from outside the app', () {
    late Directory tmp;
    late LibraryStore store;
    late List<LibraryEntry> books;

    /// What the platform was asked, by method.
    final calls = <String, List<Object?>>{};

    /// What "takeMediaPlay" answers, once.
    Map<String, Object?>? asked;

    setUp(() async {
      LibraryStore.secretOpen.value = false;
      ListeningPrefs.reset();
      SpeechService.resetQueue();
      calls.clear();
      tmp = Directory.systemTemp.createTempSync('tv_outside');
      var n = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        (calls[call.method] ??= []).add(call.arguments);
        switch (call.method) {
          case 'takeMediaPlay':
            final a = asked;
            asked = null;
            return a;
          case 'synthesise':
            final f = File('${tmp.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
            return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
          case 'requestFocus':
            return 'granted';
          case 'playerPosition':
          case 'playerEnqueue':
            return 0;
          case 'listEngines':
          case 'listVoices':
            return const [];
          case 'outputDir':
            return tmp.path;
        }
        return null;
      });
      store = LibraryStore(tmp);
      books = [];
      for (final name in ['alpha.txt', 'beta.txt']) {
        final f = File('${tmp.path}/incoming/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 30}\n\n'
              'Chapter 2\n\n${'It keeps going here. ' * 30}');
        books.add(await store.importFile(PickedFile(path: f.path, name: name)));
      }
      // As MediaRequests.listen sets it when the app starts: every player's
      // start is seen, a page's too.
      PlaybackScheduler.beforePlay ??= BackgroundReading.claim;
    });

    tearDown(() async {
      await BackgroundReading.current.value?.stop();
      messenger.setMockMethodCallHandler(_channel, null);
      LibraryStore.secretOpen.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('is read in the background from its place, and the card names it', () async {
      final a = books.first;
      final layout = await store.loadLayout(a.id);
      await store.saveCursor(a.id, cursorOf(layout.units[5]), 0.2);

      asked = {'book': a.id, 'reading': false};
      await MediaRequests.take(() async => store);

      final bg = BackgroundReading.current.value;
      expect(bg?.bookId, a.id);
      expect(bg!.player.unit.value, layout.unitForCursor(cursorOf(layout.units[5]), saved: true));
      expect(calls['mediaPlayFailed'], isNull);
      final card = calls['session']!.cast<Map<Object?, Object?>>().lastWhere((s) => s['active'] == true);
      expect(card['book'], a.id, reason: 'a Play for the same book carries on with this reading');
    });

    test('nothing waiting: nothing happens', () async {
      await MediaRequests.take(() async => store);
      expect(BackgroundReading.current.value, isNull);
      expect(calls['mediaPlayFailed'], isNull);
    });

    test('a book on a shut secret shelf is not read, and the card put up for it goes', () async {
      final a = books.first;
      final secret = await store.addCategory('Secret', secret: true);
      await store.moveBooks({a.id}, secret.id);

      asked = {'book': a.id, 'reading': false};
      await MediaRequests.take(() async => store);
      expect(BackgroundReading.current.value, isNull);
      expect(calls['mediaPlayFailed'], hasLength(1));
      expect((calls['session'] ?? const []).cast<Map<Object?, Object?>>().where((s) => s['active'] == true), isEmpty);
    });

    test('a book no longer in the library is not read', () async {
      asked = {'book': 'gone', 'reading': false};
      await MediaRequests.take(() async => store);
      expect(BackgroundReading.current.value, isNull);
      expect(calls['mediaPlayFailed'], hasLength(1));
    });

    test('the book already reading in the background carries on, not again from its place', () async {
      final a = books.first;
      asked = {'book': a.id, 'reading': false};
      await MediaRequests.take(() async => store);
      final bg = BackgroundReading.current.value!;
      await bg.pause();
      expect(bg.player.state.value, PlayState.paused);

      asked = {'book': a.id, 'reading': true};
      await MediaRequests.take(() async => store);
      expect(identical(BackgroundReading.current.value, bg), isTrue);
      expect(bg.player.isPlaying, isTrue);
    });

    test("a book's page reading it carries on; another book stops the page's voice", () async {
      final a = books.first;
      final b = books.last;
      final layout = await store.loadLayout(a.id);
      // A book's page, as the reader makes its player.
      final page = readingScheduler(layout: layout, prefs: () => ListeningPrefs.memory, language: 'en', bookId: a.id);
      addTearDown(page.dispose);
      await page.play(0);
      await page.pause(now: true);
      expect(page.state.value, PlayState.paused);

      // The same book: the page reads on, and nothing else starts.
      asked = {'book': a.id, 'reading': true};
      await MediaRequests.take(() async => store);
      expect(page.isPlaying, isTrue);
      expect(BackgroundReading.current.value, isNull);

      // Another book: the page's voice stops, and that book reads.
      asked = {'book': b.id, 'reading': true};
      await MediaRequests.take(() async => store);
      expect(page.state.value, PlayState.idle);
      expect(BackgroundReading.current.value?.bookId, b.id);
    });

    test('the platform wakes Dart with mediaPlay', () async {
      MediaRequests.listen(() async => store);
      // Its own look on starting found nothing waiting.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(BackgroundReading.current.value, isNull);
      final a = books.first;
      asked = {'book': a.id, 'reading': false};
      await messenger.handlePlatformMessage(
        'tomevoice/tts',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('platformEvent', {'type': 'mediaPlay'})),
        (_) {},
      );
      for (var i = 0; i < 100 && BackgroundReading.current.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(BackgroundReading.current.value?.bookId, a.id);
    });
  });

  group('the library', () {
    late Directory one;
    late Directory two;
    var dir = '';

    setUp(() {
      ListeningPrefs.reset();
      one = Directory.systemTemp.createTempSync('tv_open_one');
      two = Directory.systemTemp.createTempSync('tv_open_two');
      dir = one.path;
      messenger.setMockMethodCallHandler(_channel, (call) async => call.method == 'outputDir' ? dir : null);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_channel, null);
      for (final d in [one, two]) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          // Best effort.
        }
      }
    });

    test('is opened once for its folder: the shelves and a book read with no screen share one store', () async {
      final first = await openLibrary();
      final again = await openLibrary();
      expect(identical(first.store, again.store), isTrue);
      expect(first.dir, one.path);

      // Another folder (a test's own) is another library.
      dir = two.path;
      ListeningPrefs.reset();
      final other = await openLibrary();
      expect(identical(other.store, first.store), isFalse);
      expect(other.dir, two.path);
    });
  });

  group('keep reading with the screen off', () {
    test("the makers that stop apps their own way, by the name the phone goes by", () {
      expect(aggressiveMaker('Xiaomi', 'Redmi'), (name: 'Redmi', page: 'xiaomi'));
      expect(aggressiveMaker('Xiaomi', 'POCO'), (name: 'POCO', page: 'xiaomi'));
      expect(aggressiveMaker('Xiaomi', 'Xiaomi'), (name: 'Xiaomi', page: 'xiaomi'));
      expect(aggressiveMaker('samsung', 'samsung'), (name: 'Samsung', page: 'samsung'));
      expect(aggressiveMaker('OnePlus', 'OnePlus'), (name: 'OnePlus', page: 'oneplus'));
      expect(aggressiveMaker('OPPO', 'OPPO'), (name: 'OPPO', page: 'oppo'));
      expect(aggressiveMaker('realme', 'realme'), (name: 'realme', page: 'realme'));
      expect(aggressiveMaker('vivo', 'iQOO'), (name: 'iQOO', page: 'vivo'));
      expect(aggressiveMaker('HUAWEI', 'HUAWEI'), (name: 'Huawei', page: 'huawei'));
      expect(aggressiveMaker('HONOR', 'HONOR'), (name: 'Honor', page: 'huawei'));
      expect(aggressiveMaker('Google', 'google'), isNull);
      expect(aggressiveMaker('Nothing', 'Nothing'), isNull);
      expect(aggressiveMaker('', ''), isNull);
    });

    Future<List<MethodCall>> pumpRow(WidgetTester tester, Map<String, Object?> status) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'batteryStatus' => status,
          'openBatterySettings' || 'openUrl' => true,
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ScreenOffRow())));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('not exempt on a Redmi: says so, opens the setting, and points to the maker\'s page', (tester) async {
      final calls = await pumpRow(tester, {'exempt': false, 'maker': 'Xiaomi', 'brand': 'Redmi'});
      expect(find.text('Keep reading with the screen off'), findsOneWidget);
      expect(find.textContaining('Battery saving may stop the voice'), findsOneWidget);
      final line = find.textContaining('dontkillmyapp.com/xiaomi');
      expect(line, findsOneWidget);
      expect(find.textContaining('Redmi phones'), findsOneWidget);

      await tester.tap(find.text('Keep reading with the screen off'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'openBatterySettings'), hasLength(1));

      await tester.tap(line);
      await tester.pumpAndSettle();
      final url = calls.lastWhere((c) => c.method == 'openUrl').arguments as Map;
      expect(url['url'], 'https://dontkillmyapp.com/xiaomi');
    });

    testWidgets('exempt on a phone that behaves: says it is allowed, and nothing more', (tester) async {
      await pumpRow(tester, {'exempt': true, 'maker': 'Google', 'brand': 'google'});
      expect(find.text('Keep reading with the screen off'), findsOneWidget);
      expect(find.textContaining('Allowed'), findsOneWidget);
      expect(find.textContaining('dontkillmyapp'), findsNothing);
    });

    testWidgets('a platform that cannot say shows nothing', (tester) async {
      messenger.setMockMethodCallHandler(_channel, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ScreenOffRow())));
      await tester.pumpAndSettle();
      expect(find.text('Keep reading with the screen off'), findsNothing);
    });

    testWidgets('back from the setting, the row says what it says now', (tester) async {
      final status = <String, Object?>{'exempt': false, 'maker': 'samsung', 'brand': 'samsung'};
      await pumpRow(tester, status);
      expect(find.textContaining('Battery saving may stop the voice'), findsOneWidget);
      status['exempt'] = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Allowed'), findsOneWidget);
      expect(find.textContaining('Samsung phones'), findsOneWidget);
    });
  });
}
