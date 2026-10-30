// Saving a chapter or a book as audio: what a save covers, the renderer
// that makes each sentence as reading aloud makes it (the same sound, with
// chapters where they start), stopping part way, the encoder's
// back-pressure, the save from the first sentence to the file, and a save
// with no activity: swiped away from Recents it goes on, its notification's
// Cancel stops it, and opened again TomeVoice shows it.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState, Size;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart' show PipelineSettings;
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/export_audio.dart';
import 'package:tomevoice_spike/main.dart' show SpikeApp;
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/mp4_chapters.dart';
import 'package:tomevoice_spike/neural_voices.dart' show isNeural, wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reading_rules.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';

import 'mp4_fixtures.dart';

late Directory _dir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('tomevoice_export');
    ListeningPrefs.reset();
    MarkStore.instance.reset();
    SpeechService.resetQueue();
    PlaybackScheduler.beforePlay = null;
    AudioExport.current.value = null;
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(AudioExport.channel, null);
    // A test that took the window away gives it back.
    await _lifecycle(AppLifecycleState.resumed);
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('what a save covers', () {
    final layout = ReadingLayout.build(ingestString(
      [for (var c = 1; c <= 3; c++) '# Chapter $c\n\nThe text of chapter $c goes on for a while. It ends here.'].join('\n\n'),
      filename: 'plan.md',
    ));

    test('one chapter as an .m4a, or the whole book as an .m4b marked at each chapter', () {
      final one = ExportPlan.chapter(layout, 1);
      final (first, count) = layout.chapterRange(1);
      expect((one.from, one.to), (first, first + count));
      expect(one.marks, isEmpty);
      expect(one.extension, 'm4a');
      expect(one.firstTitle, 'Chapter 2');
      final book = ExportPlan.book(layout);
      expect((book.from, book.to), (0, layout.units.length));
      expect(book.marks.map((m) => m.title), ['Chapter 1', 'Chapter 2', 'Chapter 3']);
      expect(book.marks.map((m) => m.unit), [for (var c = 0; c < 3; c++) layout.chapterFirstUnit[c]]);
      expect(book.extension, 'm4b');
      expect(book.chars, layout.units.fold<int>(0, (n, u) => n + u.text.length));
      expect(book.charsBefore(layout.chapterFirstUnit[1]), layout.units.take(layout.chapterFirstUnit[1]).fold<int>(0, (n, u) => n + u.text.length));
    });

    test('a book of more chapters than a chpl box holds is marked at every third', () {
      final long = ReadingLayout.build(ingestString(
        [for (var c = 1; c <= 600; c++) '# Chapter $c\n\nChapter $c has a line.'].join('\n\n'),
        filename: 'long.md',
      ));
      final plan = ExportPlan.book(long);
      expect(plan.chapters, 600);
      expect(plan.marks, hasLength(200));
      expect(plan.markEvery, 3);
      expect(plan.marks[1].title, 'Chapter 4');
    });

    test('sizes, rates, names and times', () {
      expect(fileBytes(const Duration(hours: 1)), (3600 * 8000 * 1.02).round() + 64 * 1024);
      expect(spaceWanted(100), 200 + 50 * 1024 * 1024);
      expect(aacRate(22050), 22050);
      expect(aacRate(23000), 24000);
      expect(aacRate(96000), 48000);
      expect(safeFileName('Emma: Volume / One?'), 'Emma Volume One');
      expect(safeFileName('...'), 'TomeVoice');
      expect(durationLabel(const Duration(minutes: 125)), '2 h 5 min');
      expect(durationLabel(const Duration(seconds: 20)), 'under a minute');
      expect(roughLength(ExportPlan.book(layout), 1.0, 0).inMilliseconds, (layout.totalWords / 165 * 60000).round());
      expect(
        progressLabel(const ExportStatus(ExportPhase.making,
            progress: RenderProgress(done: 50, total: 100, chapter: 3, chapters: 12), left: Duration(minutes: 10))),
        'Chapter 3 of 12 · 50% · about 10 min left',
      );
    });
  });

  group('making it', () {
    final open = String.fromCharCode(0x201C);
    final close = String.fromCharCode(0x201D);
    final book = ingestString(
      [
        '# Chapter 1: Arrival',
        'Klein looked up at the grey sky. ${open}We should go now,$close she said. He nodded once.',
        '* * *',
        'The road ran on for miles. "It is late," said Audrey, "and cold."',
        '# Chapter 2: Night',
        '${open}Are you coming with us?$close The night was cold, and Klein said nothing at all.',
        '# Chapter 3: Morning',
        'Morning came at last. They went on.',
      ].join('\n\n'),
      filename: 'making.md',
    );
    final layout = ReadingLayout.build(book);

    test('a saved book is the sound reading it aloud queues, sentence after sentence, chapters where they start',
        () async {
      final reading = _Voices('r');
      final player = _recipe(reading, layout);
      await player.play(0);
      await _until(() => player.state.value == PlayState.idle);
      player.dispose();

      final saving = _Voices('s');
      final sink = _Sink();
      final made = await AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(saving, layout), sink: sink).run();

      expect(saving.asked, reading.asked, reason: 'other speech was asked for');
      expect(saving.asked.any((a) => a.text.contains('Klein')), isFalse, reason: 'the fix for Klein was not said');
      expect(sink.bytes.toBytes(), [for (final q in reading.queued) ...q], reason: 'it sounds different from reading');
      expect(sink.opens, 1);
      expect(sink.rate, 24000, reason: "the dialogue voice's rate was not brought to the narrator's");
      expect(made.frames * 2, sink.bytes.length);
      expect(made.unsaid, 0);

      // Each chapter is marked where its first sentence starts.
      final said = [
        for (var i = 0; i < layout.units.length; i++)
          if (PlaybackScheduler.sayable(_said(layout.units[i]).text)) i,
      ];
      expect(said, hasLength(reading.queued.length));
      Duration at(int unit) {
        var frames = 0;
        for (var k = 0; k < said.length && said[k] < unit; k++) {
          frames += reading.queued[k].length ~/ 2;
        }
        return Duration(microseconds: frames * 1000000 ~/ 24000);
      }

      expect(made.marks.map((m) => m.title), ['Chapter 1: Arrival', 'Chapter 2: Night', 'Chapter 3: Morning']);
      expect(made.marks.map((m) => m.start), [for (var c = 0; c < 3; c++) at(layout.chapterFirstUnit[c])]);
    });

    test('a chapter with nothing said gives its mark to the next', () async {
      final sink = _Sink();
      final voice = _recipe(_Voices('q'), layout,
          respell: (u) => u.sectionIndex == layout.units[layout.chapterFirstUnit[1]].sectionIndex
              ? const Respelled.same('* * *')
              : _said(u));
      final made = await AudioRenderer(plan: ExportPlan.book(layout), voice: voice, sink: sink).run();
      expect(made.marks.map((m) => m.title), ['Chapter 1: Arrival', 'Chapter 3: Morning']);
    });

    test('stopped part way: the sentence being made is called off, and nothing more is made', () async {
      final v = _Voices('c')..holdAt = 2;
      final sink = _Sink();
      final renderer = AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(v, layout), sink: sink);
      final run = renderer.run();
      await _until(() => v.holding);
      renderer.cancel();
      await expectLater(run, throwsA(isA<ExportCancelled>()));
      expect(v.cancels, 1);
      final asked = v.asked.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(v.asked.length, asked, reason: 'it went on making sentences');
      expect(sink.pieces, hasLength(2));
    });

    test('a sentence stopped by something else is made again, not skipped', () async {
      final clean = _Sink();
      await AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(_Voices('a'), layout), sink: clean).run();
      var once = true;
      final v = _Voices('b')
        ..failWith = (text, voice) {
          if (!once || !text.contains('road')) return null;
          once = false;
          return PlatformException(code: 'TTS_STOPPED');
        };
      final sink = _Sink();
      await AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(v, layout), sink: sink).run();
      expect(sink.bytes.toBytes(), clean.bytes.toBytes());
    });

    test('a line the voice will not say is left out and counted; three in a row stop the save', () async {
      final one = _Voices('e')
        ..failWith = (text, _) => text.contains('road') ? PlatformException(code: 'TTS_ERROR', message: 'Synthesis failed') : null;
      final made = await AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(one, layout), sink: _Sink()).run();
      expect(made.unsaid, 1);
      final all = _Voices('f')..failWith = (_, __) => PlatformException(code: 'TTS_ERROR', message: 'Synthesis failed');
      await expectLater(
        AudioRenderer(plan: ExportPlan.book(layout), voice: _recipe(all, layout), sink: _Sink()).run(),
        throwsA(isA<ExportFailed>().having((e) => e.message, 'message', 'Synthesis failed')),
      );
      expect(all.asked, hasLength(3));
    });

    test('a natural voice that stops is asked once more, then the save stops and says which voice', () async {
      final v = _Voices('n')..failWith = (_, voice) => isNeural(voice) ? Exception('the model would not load') : null;
      await expectLater(
        AudioRenderer(
          plan: ExportPlan.chapter(layout, 0),
          voice: _recipe(v, layout, narrator: 'neural:en_US-kristin-medium', dialogue: null),
          sink: _Sink(),
        ).run(),
        throwsA(isA<ExportFailed>().having((e) => e.message, 'message', contains('Kristin could not speak'))),
      );
      expect(v.asked, hasLength(2));
    });
  });

  group('to the encoder', () {
    test('in pieces, never more than two unanswered, all of it and in order', () async {
      final replies = <Completer<void>>[];
      final got = BytesBuilder();
      final sizes = <int>[];
      var waiting = 0;
      var most = 0;
      messenger.setMockMethodCallHandler(AudioExport.channel, (call) async {
        if (call.method == 'begin') return '${_dir.path}/x.m4a';
        if (call.method != 'write') return null;
        final pcm = (call.arguments as Map)['pcm'] as Uint8List;
        got.add(pcm);
        sizes.add(pcm.length);
        most = math.max(most, ++waiting);
        final reply = Completer<void>();
        replies.add(reply);
        await reply.future;
        waiting--;
        return null;
      });
      final sink = ChannelPcmSink(AudioExport.channel, chunkBytes: 1000);
      await sink.open(24000);
      final pcm = Uint8List.fromList([for (var i = 0; i < 4500; i++) i & 0xFF]);
      var added = false;
      unawaited(sink.add(pcm).then((_) => added = true));
      await pumpEventQueue();
      expect(waiting, 2);
      expect(added, isFalse, reason: 'it did not wait for the encoder');
      var flushed = false;
      for (var turn = 0; !flushed; turn++) {
        if (turn > 200) fail('the pieces stopped coming');
        if (replies.isNotEmpty) replies.removeAt(0).complete();
        await pumpEventQueue();
        if (added && !flushed && replies.isEmpty && waiting == 0) {
          await sink.flush();
          flushed = true;
        }
      }
      expect(most, 2);
      expect(sizes, [1000, 1000, 1000, 1000, 500]);
      expect(got.toBytes(), pcm);
    });

    test('out of space: the next piece is not sent, and the save hears why', () async {
      var writes = 0;
      messenger.setMockMethodCallHandler(AudioExport.channel, (call) async {
        if (call.method == 'write') {
          writes++;
          throw PlatformException(code: 'SPACE', message: 'The phone is out of space');
        }
        return null;
      });
      final sink = ChannelPcmSink(AudioExport.channel, chunkBytes: 100, inFlight: 1);
      await expectLater(
        () async {
          await sink.add(Uint8List(1000));
          await sink.flush();
        }(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'SPACE')),
      );
      expect(writes, 1);
    });
  });

  group('a save', () {
    final layout = ReadingLayout.build(ingestString(
      [
        '# Chapter 1',
        'The first chapter has a line or two. Then it ends.',
        '# Chapter 2',
        'The second chapter is short as well. It ends too.',
      ].join('\n\n'),
      filename: 'save.md',
    ));
    final calls = <String>[];
    final args = <String, Map<Object?, Object?>>{};
    late String made;

    void platform({Object? Function(MethodCall call)? answer}) {
      calls.clear();
      args.clear();
      made = '${_dir.path}/made.m4a';
      messenger.setMockMethodCallHandler(AudioExport.channel, (call) async {
        calls.add(call.method);
        args[call.method] = (call.arguments as Map?) ?? const {};
        final own = answer?.call(call);
        if (own is Exception) throw own;
        if (own != null) return own;
        return switch (call.method) {
          'begin' => made,
          'finish' => () {
              File(made).writeAsBytesSync(fakeMp4(moovFirst: true, room: 4096).bytes);
              return {'path': made, 'bytes': File(made).lengthSync(), 'durationMs': 1000};
            }(),
          'publish' => {'uri': 'content://media/external/audio/media/7', 'where': 'Audiobooks/Save/Save.m4b'},
          _ => null,
        };
      });
    }

    Future<void> ended(AudioExport job) => _until(() => !job.status.value.running && AudioExport.current.value == null);

    test('from the first sentence to the saved file: chapters and tags in it, the play hook given back', () async {
      platform();
      final told = <PlaybackScheduler?>[];
      final hook = told.add;
      PlaybackScheduler.beforePlay = hook;
      final job = AudioExport.start(
        plan: ExportPlan.book(layout),
        voice: _recipe(_Voices('j'), layout, dialogue: null),
        bookTitle: 'Save',
        author: 'A. Writer',
      );
      expect(AudioExport.current.value, same(job));
      await ended(job);
      expect(job.status.value.phase, ExportPhase.saved);
      expect(job.status.value.uri, 'content://media/external/audio/media/7');
      expect(calls.first, 'start');
      expect(calls, containsAllInOrder(['start', 'begin', 'write', 'finish', 'publish', 'done']));
      expect(calls, isNot(contains('abort')));
      expect(args['begin']?['sampleRate'], 24000);
      expect(args['begin']?['bitRate'], 64000);
      expect(args['publish']?['name'], 'Save.m4b');
      expect(args['publish']?['folder'], 'Save');
      final b = File(made).readAsBytesSync();
      final moov = mp4Children(b, 0, b.length).singleWhere((x) => x.type == 'moov');
      final chapters = chaptersIn(b, boxAt(b, moov, ['udta', 'chpl']));
      expect(chapters.map((c) => c.$2), ['Chapter 1', 'Chapter 2']);
      expect(chapters.first.$1, 0);
      expect(identical(PlaybackScheduler.beforePlay, hook), isTrue, reason: 'the hook was not given back');
      expect(AudioExport.current.value, isNull);
      PlaybackScheduler.beforePlay = null;
    });

    test('a book read aloud while it saves stops the save and says why; a voice sample does not', () async {
      platform();
      final told = <PlaybackScheduler?>[];
      PlaybackScheduler.beforePlay = told.add;
      final v = _Voices('k')..holdAt = 1;
      final job = AudioExport.start(plan: ExportPlan.book(layout), voice: _recipe(v, layout), bookTitle: 'Save');
      await _until(() => v.holding);
      PlaybackScheduler.beforePlay!(null);
      expect(job.status.value.running, isTrue, reason: "a voice's sample stopped the save");
      final reader = _recipe(_Voices('o'), layout);
      PlaybackScheduler.beforePlay!(reader);
      expect(told, [null, reader], reason: 'what the app does before reading did not happen');
      await ended(job);
      expect(job.status.value.phase, ExportPhase.cancelled);
      expect(job.status.value.message, AudioExport.readingBegan);
      expect(calls, contains('abort'));
      expect(args['abort']?['notice'], AudioExport.readingBegan);
      expect(calls, isNot(contains('publish')));
      reader.dispose();
      PlaybackScheduler.beforePlay = null;
    });

    test('stopped by the reader: nothing kept, the chosen document deleted, no notice', () async {
      platform();
      final v = _Voices('m')..holdAt = 1;
      final job = AudioExport.start(
        plan: ExportPlan.book(layout),
        voice: _recipe(v, layout),
        bookTitle: 'Save',
        destination: 'content://documents/document/7',
      );
      await _until(() => v.holding);
      job.cancel();
      await ended(job);
      expect(job.status.value.phase, ExportPhase.cancelled);
      expect(job.status.value.message, isNull);
      expect(calls, containsAllInOrder(['abort', 'discard']));
      expect(args['abort']?['notice'], isNull);
      expect(args['discard']?['uri'], 'content://documents/document/7');
      expect(calls, isNot(contains('finish')));
      PlaybackScheduler.beforePlay = null;
    });

    test('out of space part way: it stops, deletes what it made, and says so', () async {
      platform(
        answer: (call) => call.method == 'write' ? PlatformException(code: 'SPACE', message: 'The phone is out of space') : null,
      );
      final job = AudioExport.start(plan: ExportPlan.chapter(layout, 0), voice: _recipe(_Voices('s'), layout), bookTitle: 'Save');
      await ended(job);
      expect(job.status.value.phase, ExportPhase.failed);
      expect(job.status.value.message, contains('ran out of space'));
      expect(calls, contains('abort'));
      expect(args['abort']?['notice'], contains('ran out of space'));
      expect(calls, isNot(contains('publish')));
      PlaybackScheduler.beforePlay = null;
    });

    // With no activity: Android took the window (a swipe from Recents)
    // and the engine stayed for the save (ReadingCore.kt), which nothing on
    // this side may need a window for.

    test('the window gone, it goes on to the file, and its end is said in a notification', () async {
      platform();
      final v = _Voices('g')..gateAt = 1;
      final job = AudioExport.start(plan: ExportPlan.book(layout), voice: _recipe(v, layout, dialogue: null), bookTitle: 'Save');
      await _until(() => v.atGate);
      await _lifecycle(AppLifecycleState.inactive);
      await _lifecycle(AppLifecycleState.hidden);
      await _lifecycle(AppLifecycleState.paused);
      await _lifecycle(AppLifecycleState.detached);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(job.status.value.running, isTrue, reason: 'the save stopped with the window');
      expect(calls, isNot(contains('abort')));
      v.gate.complete();
      await ended(job);
      expect(job.status.value.phase, ExportPhase.saved);
      expect(calls, containsAllInOrder(['start', 'begin', 'write', 'finish', 'publish', 'done']));
      expect(calls, isNot(contains('abort')));
      expect(args['done']?['title'], 'Saved as audio: Save');
      expect(args['done']?['uri'], 'content://media/external/audio/media/7');
      PlaybackScheduler.beforePlay = null;
    });

    test("the window gone, its notification's Cancel still stops it: nothing kept, no notice", () async {
      platform();
      final v = _Voices('x')..holdAt = 1;
      final job = AudioExport.start(
        plan: ExportPlan.book(layout),
        voice: _recipe(v, layout),
        bookTitle: 'Save',
        destination: 'content://documents/document/9',
      );
      await _until(() => v.holding);
      await _lifecycle(AppLifecycleState.paused);
      await _lifecycle(AppLifecycleState.detached);
      // The notification's Cancel, as AudioExport.kt hands it on.
      await _fromPlatform(const MethodCall('exportEvent', {'type': 'cancel'}));
      await ended(job);
      expect(job.status.value.phase, ExportPhase.cancelled);
      expect(job.status.value.message, isNull);
      expect(v.cancels, 1, reason: 'the sentence being made was not called off');
      expect(calls, containsAllInOrder(['abort', 'discard']));
      expect(args['abort']?['notice'], isNull, reason: 'a notice for a stop the reader asked for');
      expect(args['discard']?['uri'], 'content://documents/document/9');
      expect(calls, isNot(contains('finish')));
      PlaybackScheduler.beforePlay = null;
    });

    test("stopped by Android's limit with no window, it waits, and goes on as TomeVoice is opened", () async {
      platform();
      final v = _Voices('t')..gateAt = 1;
      final job = AudioExport.start(plan: ExportPlan.book(layout), voice: _recipe(v, layout, dialogue: null), bookTitle: 'Save');
      await _until(() => v.atGate);
      await _lifecycle(AppLifecycleState.paused);
      await _lifecycle(AppLifecycleState.detached);
      // Android 15's six hours a day used up: the service stopped.
      await _fromPlatform(const MethodCall('exportEvent', {'type': 'timeout'}));
      expect(job.status.value.waiting, isTrue);
      final starts = calls.where((c) => c == 'start').length;
      // Opened again: a new window on the same engine.
      await _lifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((c) => c == 'start').length, starts + 1, reason: 'the service was not started again');
      expect(job.status.value.waiting, isFalse);
      v.gate.complete();
      await ended(job);
      expect(job.status.value.phase, ExportPhase.saved);
      PlaybackScheduler.beforePlay = null;
    });
  });

  group('opened again', () {
    final layout = ReadingLayout.build(ingestString(
      '# Chapter 1\n\nThe first chapter has a line or two. Then it ends.\n\n'
      '# Chapter 2\n\nThe second chapter is short as well. It ends too.',
      filename: 'again.md',
    ));

    /// A platform event on the reading channel, as the phone sends one.
    Future<void> event(WidgetTester tester, Map<String, Object?> e) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'tomevoice/tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall('platformEvent', e)),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    testWidgets('onto a save going on, or from its notification: its progress shows once, and Stop stops it',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      const tts = MethodChannel('tomevoice/tts');
      messenger.setMockMethodCallHandler(tts, (call) async => switch (call.method) {
            'launchArgs' => <String, Object?>{},
            'outputDir' => _dir.path,
            // The save's notification, tapped (AudioExportService).
            'widgetLaunch' => <String, Object?>{'page': 'export'},
            'listEngines' => const <Object?>[],
            'listVoices' => const <Object?>[],
            _ => null,
          });
      addTearDown(() => messenger.setMockMethodCallHandler(tts, null));
      final calls = <String>[];
      messenger.setMockMethodCallHandler(AudioExport.channel, (call) async {
        calls.add(call.method);
        return null;
      });
      await tester.pumpWidget(const SpikeApp());
      for (var i = 0; i < 40 && find.text('Library').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('Saving as audio'), findsNothing, reason: 'progress with no save');

      final v = _Voices('o')..holdAt = 0;
      final job = AudioExport.start(plan: ExportPlan.book(layout), voice: _recipe(v, layout), bookTitle: 'Again');
      await tester.pumpAndSettle();
      expect(job.status.value.running, isTrue);

      // A new window on the engine that went on saving.
      await event(tester, {'type': 'shown'});
      expect(find.text('Saving as audio'), findsOneWidget, reason: 'opened again, the save did not show');
      // (The sheet's header sets the file's name in capitals.)
      expect(find.text('AGAIN.M4B'), findsOneWidget);
      // Then its notification, tapped: the same sheet, not a second.
      await event(tester, {'type': 'widgetLaunch'});
      expect(find.text('Saving as audio'), findsOneWidget);
      expect(find.text('Stop saving'), findsOneWidget);

      await tester.tap(find.text('Stop saving'));
      await tester.pumpAndSettle();
      expect(find.text('Not saved'), findsOneWidget);
      expect(job.status.value.phase, ExportPhase.cancelled);
      expect(calls, contains('abort'));
      expect(AudioExport.current.value, isNull);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // Nothing going on now: opened again, nothing shows.
      await event(tester, {'type': 'shown'});
      expect(find.text('Not saved'), findsNothing);
      expect(find.text('Saving as audio'), findsNothing);
      PlaybackScheduler.beforePlay = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}

/// The app's window going or coming back, as the engine tells Dart.
Future<void> _lifecycle(AppLifecycleState state) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
      (_) {},
    );

/// A call from AudioExport.kt on the save's channel (its notification's
/// Cancel, Android stopping its service).
Future<void> _fromPlatform(MethodCall call) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      AudioExport.channel.name,
      AudioExport.channel.codec.encodeMethodCall(call),
      (_) {},
    );

Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 20)}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > within) fail('waited too long');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _rules = [SayRule(from: 'Klein', to: 'Kline')];
Respelled _said(Speakable u) => respellUnit(u, _rules);

/// The book's voice and settings, as readingScheduler would set them up:
/// a narrator, a dialogue voice of another rate, a word gap, pauses, a fix
/// for a name, and the narrator's pitch.
PlaybackScheduler _recipe(
  _Voices voices,
  ReadingLayout layout, {
  String narrator = 'narrator',
  String? dialogue = 'dialogue',
  Respelled Function(Speakable unit)? respell,
}) {
  const base = PipelineSettings(wordGapMs: 60, sentencePauseMs: 300, paragraphPauseMs: 600);
  return PlaybackScheduler(
    service: voices,
    units: layout.units,
    settingsFor: (text) => base.copyWith(text: text, speedScale: 1.25, pitchSemitones: -2),
    engineIdOf: () => 'engine',
    voiceNameOf: () => narrator,
    pauseAfter: (i) => 200 + 50 * (i % 3),
    respell: respell ?? _said,
    dialogueVoiceOf: () => dialogue,
    pitchOf: (voice) => voice == 'dialogue' ? 3.0 : 0.0,
    quoteOpenAt: (i) => i == 3,
  );
}

/// Voices that say each line as a tone, a word a burst (the dialogue voice
/// higher and at another rate), reporting where words start as Android
/// does; a player that has heard whatever it was given. [failWith] makes a
/// line fail; [holdAt] keeps that synthesis waiting until it is cancelled;
/// [gateAt] keeps it waiting until [gate] opens, then says it.
class _Voices extends SpeechService {
  _Voices(this.prefix);

  final String prefix;
  final asked = <({String text, String? voice, double rate, double pitch, String? engine})>[];
  final queued = <Uint8List>[];
  Object? Function(String text, String? voice)? failWith;
  int? holdAt;
  bool holding = false;
  int? gateAt;
  final gate = Completer<void>();
  bool atGate = false;
  int cancels = 0;
  Completer<void>? _held;
  var _n = 0;
  var _frames = 0;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    final k = asked.length;
    asked.add((text: text, voice: voiceName, rate: rate, pitch: pitch, engine: engineId));
    final error = failWith?.call(text, voiceName);
    if (error != null) throw error;
    if (k == holdAt) {
      final held = _held = Completer<void>();
      holding = true;
      await held.future;
      throw PlatformException(code: 'TTS_STOPPED', message: 'Synthesis cancelled');
    }
    if (k == gateAt) {
      atGate = true;
      await gate.future;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return _speech(text, voiceName);
  }

  Map<String, Object?> _speech(String text, String? voice) {
    final rate = voice == 'dialogue' ? 22050 : 24000;
    final hz = voice == 'dialogue' ? 330.0 : 220.0;
    final samples = <double>[];
    final events = <Map<String, int>>[];
    void quiet(int ms) => samples.addAll(List.filled(rate * ms ~/ 1000, 0.0));
    quiet(30);
    for (final m in RegExp(r'\S+').allMatches(text)) {
      events.add({'start': m.start, 'end': m.end, 'frame': samples.length});
      final n = rate * (25 + 6 * (m.end - m.start)) ~/ 1000;
      for (var i = 0; i < n; i++) {
        samples.add(0.4 * math.sin(2 * math.pi * hz * i / rate) * math.sin(math.pi * i / n));
      }
      quiet(35);
    }
    final f = File('${_dir.path}/$prefix${_n++}.wav')..writeAsBytesSync(wavBytes(Float32List.fromList(samples), rate));
    return {'wavPath': f.path, 'engineId': 'test', 'rangeEvents': events};
  }

  @override
  Future<void> cancelSynthesis() async {
    cancels++;
    final held = _held;
    if (held != null && !held.isCompleted) held.complete();
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    queued.add(pcm);
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

  /// Everything queued has been heard: reading goes on to the end.
  @override
  Future<int> position({bool raw = false}) async => _frames;

  @override
  Future<String> requestFocus() async => SpeechService.focusGranted;

  @override
  Future<void> stopPlayback() async {}

  @override
  Future<void> pausePlayback() async {}

  @override
  Future<void> resumePlayback() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setHighlightOffsets({required int bluetoothMs, required int otherMs}) async {}
}

/// An encoder that keeps what it is given.
class _Sink implements PcmSink {
  int? rate;
  int opens = 0;
  final bytes = BytesBuilder();
  final pieces = <int>[];

  @override
  Future<void> open(int sampleRate) async {
    opens++;
    rate = sampleRate;
  }

  @override
  Future<void> add(Uint8List pcm) async {
    bytes.add(pcm);
    pieces.add(pcm.length);
  }

  @override
  Future<void> flush() async {}
}
