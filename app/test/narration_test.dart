// A book's own recorded narration (an EPUB's media overlays), played: where
// its audio lies in the book's file, each sentence's stretch of it (whole,
// shared out of a paragraph's clip at the pause between, or joined from a
// sentence's phrases, lit as each is said), at the reader's speed and
// loudness; the scheduler reading from it, passing over what it leaves out
// and leaving the rest to the voice; saving it as audio; the choice in the
// voice picker; and a book imported before narrations were read.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/export_audio.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/narration.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/voices.dart';
import 'package:tomevoice_spike/zip_entries.dart';

import 'narration_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String epub;
  final book = ingestBytes(narratedEpub(), filename: 'tin-box.epub');
  final layout = ReadingLayout.build(book);
  int unit(String starts) {
    final u = layout.units.indexWhere((x) => x.text.startsWith(starts));
    expect(u, isNot(-1), reason: 'no sentence starts "$starts"');
    return u;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tv_narration');
    epub = (File('${dir.path}/book.epub')..writeAsBytesSync(narratedEpub())).path;
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    PlaybackScheduler.beforePlay = null;
    BookNarrationReader.files.clear();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
      // What the reader unpacked for this book (Chapter Three's file).
      for (final f in Directory('${Directory.systemTemp.path}/narration').listSync()) {
        if (f.uri.pathSegments.last.startsWith('tin-')) f.deleteSync();
      }
    } on FileSystemException {
      // Best effort.
    }
  });

  BookNarrationReader reader(WavDecoder decoder, {bool Function()? chosen, String? source}) => BookNarrationReader(
        bookId: 'tin',
        layout: () => layout,
        chosen: chosen ?? () => true,
        decode: decoder.call,
        source: source ?? epub,
      );

  group('the audio, from the book\'s own file', () {
    test('a stored file is a stretch of the EPUB; a compressed one is unpacked once', () {
      final entries = zipEntries(epub);
      expect(entries['OEBPS/audio/one.wav']!.stored, isTrue);
      expect(entries['OEBPS/audio/three.wav']!.method, 8);
      final cache = '${dir.path}/cache';
      final one = narrationSource(epub, 'OEBPS/audio/one.wav', cache, 'tin-0');
      expect(one.path, epub);
      final f = File(epub).openSync()..setPositionSync(one.offset);
      expect(f.readSync(one.length), toneWav(8.5, oneSounds));
      f.closeSync();
      expect(Directory(cache).existsSync(), isFalse, reason: 'nothing was to be unpacked');

      File('$cache/other-0.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      final three = narrationSource(epub, 'OEBPS/audio/three.wav', cache, 'tin-2');
      expect((three.path, three.offset), ('$cache/tin-2.wav', 0));
      expect(File(three.path).readAsBytesSync(), toneWav(8, threeSounds));
      expect(File('$cache/other-0.wav').existsSync(), isFalse, reason: "another book's copy was kept");
      expect(() => narrationSource(epub, 'OEBPS/audio/none.wav', cache, 'tin-9'), throwsA(isA<FileSystemException>()));
    });

    test('whether a book has one is read from its package alone', () {
      expect(epubHasNarration(epub), isTrue);
      final plain = File('${dir.path}/plain.epub')..writeAsBytesSync(utf8.encode('not a zip'));
      expect(epubHasNarration(plain.path), isFalse);
    });

    test("the decoder's audio is cut to the stretch, mixed down and brought to the voices' rate", () {
      // 100 frames of two channels at 8 kHz from 1 s: left 1000, right 3000.
      final pcm = Int16List(200);
      for (var i = 0; i < 100; i++) {
        pcm[2 * i] = 1000;
        pcm[2 * i + 1] = 3000;
      }
      final d = (pcm: pcm.buffer.asUint8List(), channels: 2, sampleRate: 8000, firstUs: 1000000, durationUs: -1);
      final same = monoAt(d, 1002500, 1010000, 8000);
      expect(same.length, 60);
      expect(same.first, closeTo(2000 / 32768, 1e-6));
      expect(monoAt(d, 0, -1, 8000).length, 100);
      expect(monoAt(d, 1000000, 1012500, 24000).length, 300);
    });
  });

  group("each sentence's stretch of the recording", () {
    Future<RenderedSpeech> make(BookNarrationReader r, String starts, {double speed = 1, int pause = 500, double? level}) async =>
        (await r.make(unit(starts), settings: PipelineSettings(speedScale: speed), pauseAfterMs: pause, levelDb: level))!;
    int ms(RenderedSpeech s, [int? frames]) => ((frames ?? s.speechFrames) * 1000 / s.sampleRate).round();

    test('a clip a sentence: its own, with the pause before the next clip; the usual pause only at a file\'s end', () async {
      final decoder = WavDecoder();
      final r = reader(decoder);
      final heading = await make(r, 'Chapter One');
      final box = await make(r, 'The box');
      final shelf = await make(r, 'It sat');
      final nobody = await make(r, 'Nobody');
      expect([for (final s in [heading, box, shelf, nobody]) s.sampleRate], everyElement(narrationRate));
      expect([for (final s in [heading, box, shelf, nobody]) ms(s)], [1200, 1800, 2800, 2200]);
      expect([for (final s in [heading, box, shelf]) s.totalFrames - s.speechFrames], [0, 0, 0]);
      expect(ms(nobody, nobody.totalFrames - nobody.speechFrames), 500, reason: 'the next clip is in another file');
      expect([for (final s in [heading, box, shelf, nobody]) s.timings], everyElement(isEmpty));
      expect(decoder.calls, hasLength(1), reason: 'the four came from one window of the file');
      expect(decoder.calls.single.path, epub);
      // The tone where the narrator speaks, silence where they do not.
      for (final s in [box, shelf]) {
        expect(s.levels.any((l) => l > 150), isTrue);
      }
    });

    test('a clip a paragraph is cut in the pause between its sentences, nothing lost or said twice', () async {
      final decoder = WavDecoder();
      final r = reader(decoder);
      final lid = await make(r, 'She lifted');
      final key = await make(r, 'Inside lay');
      final cut = 500 + ms(lid);
      expect(cut, inInclusiveRange(3200, 3600), reason: 'the pause between them is from 3.2 s to 3.6 s');
      // On to where the next clip starts (the pause after it, 0.75 s).
      expect(lid.speechFrames + key.speechFrames, (7250 - 500) * narrationRate ~/ 1000);
      expect(key.totalFrames, key.speechFrames);
      expect(decoder.calls, hasLength(1), reason: 'the cut and both sentences came from one window');
    });

    test('clips that overlap a little are joined where the next begins, with no pause put between', () async {
      final plain = ingestString('Hello there.\n\nAll is well.\n\nAnother day.', filename: 'three.md');
      final lines = ReadingLayout.build(plain);
      TextPlace at(int u, {bool end = false}) => (
            section: lines.units[u].sectionIndex,
            block: lines.units[u].blockIndex,
            offset: lines.unitOffset[u] + (end ? lines.units[u].text.length : 0),
          );
      NarrationClip clip(int u, int begin, int end) =>
          NarrationClip(start: at(u), end: at(u, end: true), audio: 0, beginMs: begin, endMs: end);
      final told = ReadingLayout.build(Book(
        id: plain.id,
        metadata: plain.metadata,
        sections: plain.sections,
        toc: plain.toc,
        source: plain.source,
        narration: Narration(audio: const ['a.wav'], clips: [clip(0, 0, 1000), clip(1, 990, 2000), clip(2, 2000, 3000)]),
      ));
      final archive = File('${dir.path}/a.zip')
        ..writeAsBytesSync(zipOf({'a.wav': toneWav(3.2, const [(0.1, 0.9), (1.1, 1.9), (2.1, 2.9)])}));
      final r = BookNarrationReader(
          bookId: 'tin', layout: () => told, chosen: () => true, decode: WavDecoder().call, source: archive.path);
      final made = [
        for (var u = 0; u < 3; u++)
          (await r.make(u, settings: const PipelineSettings(), pauseAfterMs: 400))!,
      ];
      expect([for (final s in made) ms(s)], [990, 1010, 1000]);
      expect([for (final s in made) ms(s, s.totalFrames - s.speechFrames)], [0, 0, 400]);
    });

    test('a sentence said in two clips is joined, each lit as it is said', () async {
      final r = reader(WavDecoder());
      final u = unit('When she turned');
      final s = await make(r, 'When she turned');
      final text = layout.units[u].text;
      expect(ms(s), 6000 - 1500);
      expect([for (final t in s.timings) text.substring(t.charStart, t.charEnd)], ['When she turned it', 'the box began to sing']);
      expect([for (final t in s.timings) t.frameStart], [0, (3600 - 1500) * narrationRate ~/ 1000]);
      expect(s.timings.last.frameEnd, s.speechFrames);
      expect(s.timings.every((t) => t.source.showsWord), isTrue);

      final fast = await make(r, 'When she turned', speed: 2);
      expect(fast.speechFrames, (s.speechFrames / 2).round());
      expect(fast.timings[1].frameStart, ((3600 - 1500) * narrationRate ~/ 1000 / 2).round());
    });

    test('a clip to the end of its file, from a compressed file unpacked for it', () async {
      final decoder = WavDecoder();
      final s = await make(reader(decoder), 'It sang');
      expect(ms(s), 8000 - 6000);
      expect(decoder.calls.last.path, isNot(epub));
      expect(decoder.calls.last.offset, 0);
    });

    test('faster with its pitch kept, and levelled moving on from the sentence before', () async {
      final r = reader(WavDecoder());
      final plain = await make(r, 'It sat');
      final fast = await make(r, 'It sat', speed: 1.5);
      expect(fast.speechFrames, (plain.speechFrames / 1.5).round());
      final levelled = await make(r, 'It sat', level: 0);
      expect(levelled.gainDb, closeTo(plain.gainDb! / 2, 1e-6));
      final quiet = await r.make(unit('It sat'),
          settings: const PipelineSettings(normaliseLoudness: false, compression: Compression.off), pauseAfterMs: 0);
      expect(quiet!.gainDb, isNull);
    });
  });

  group('how each sentence is read', () {
    test('as the plan says while the narration is chosen; every one by the voice while it is not', () {
      var on = true;
      final r = reader(WavDecoder(), chosen: () => on);
      expect(r.at(unit('The box')), NarrationRole.recorded);
      expect(r.at(unit('A line the narrator')), NarrationRole.passed);
      expect(r.at(unit('Chapter Two')), NarrationRole.voiced);
      on = false;
      expect([for (var u = 0; u < layout.units.length; u++) r.at(u)], everyElement(NarrationRole.voiced));
    });

    test("by the voice when the book's file is not on the phone", () {
      final r = reader(WavDecoder(), source: '${dir.path}/gone.epub');
      expect(r.at(unit('The box')), NarrationRole.voiced);
      final unknown = BookNarrationReader(bookId: 'nowhere', layout: () => layout, chosen: () => true);
      expect(unknown.at(unit('The box')), NarrationRole.voiced);
    });
  });

  group('read aloud', () {
    Future<_Player> read({bool chosen = true, WavDecoder? decoder}) async {
      final player = _Player(dir);
      final scheduler = PlaybackScheduler(
        service: player,
        units: layout.units,
        settingsFor: (text) => PipelineSettings(text: text),
        engineIdOf: () => 'engine',
        voiceNameOf: () => 'narrator',
        pauseAfter: (_) => 300,
        narration: reader(decoder ?? WavDecoder(), chosen: () => chosen),
      );
      await scheduler.play(0);
      for (var i = 0; i < 400 && scheduler.state.value != PlayState.idle; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(scheduler.state.value, PlayState.idle, reason: 'the book was not read to its end');
      player.notice = scheduler.notice.value;
      scheduler.dispose();
      return player;
    }

    test('from the narration where it says a line; the voice reads only what lies outside it', () async {
      final p = await read();
      expect(p.asked, ['Chapter Two']);
      expect(p.queued, hasLength(layout.units.length - 1), reason: 'the line it leaves out is passed over');
      expect(p.rates, everyElement(narrationRate), reason: "the voice's line is brought to the narration's stream");
      expect(p.notice, isNull);
    });

    test('in the voice, every line, while the narration is not chosen', () async {
      final p = await read(chosen: false);
      expect(p.asked, [for (final u in layout.units) u.text]);
    });

    test('a file that will not play leaves its lines to the voice, and says so', () async {
      // Chapter Three's file, the one unpacked from the book.
      final p = await read(decoder: _Failing((path) => path != epub));
      expect(p.asked, ['Chapter Two', 'Chapter Three', 'When she turned it, the box began to sing.', 'It sang until morning.']);
      expect(p.queued, hasLength(layout.units.length - 1));
      expect(p.notice, contains('could not be played'));
    });
  });

  test('saved as audio in the narration, the voice saying only what it does not', () async {
    final player = _Player(dir);
    final voice = PlaybackScheduler(
      service: player,
      units: layout.units,
      settingsFor: (text) => PipelineSettings(text: text),
      engineIdOf: () => 'engine',
      voiceNameOf: () => 'narrator',
      pauseAfter: (_) => 300,
      narration: reader(WavDecoder()),
    );
    final sink = _Sink();
    final made = await AudioRenderer(plan: ExportPlan.book(layout), voice: voice, sink: sink).run();
    voice.dispose();
    expect(player.asked, ['Chapter Two']);
    expect(sink.rate, narrationRate);
    expect(sink.pieces, hasLength(layout.units.length - 1));
    expect(made.frames, sink.bytes.length ~/ 2);
    // About the recording's own length: 26.5 s of clips, less what lies
    // between them, plus the voice's line.
    expect(made.length.inMilliseconds, inInclusiveRange(20000, 30000));
  });

  group('the choice', () {
    test('kept for the book; choosing a voice reads it in the voice again', () {
      final prefs = ListeningPrefs.memory;
      final c = ListenController(prefs: prefs, language: 'en', bookId: 'tin', narration: true, onChanged: ({required bool restart}) {});
      expect(c.narrated, isFalse);
      c.chooseNarration();
      expect(c.narrated, isTrue);
      expect(ListeningPrefs.fromJson(jsonDecode(jsonEncode(prefs.toJson())) as Map<String, Object?>).narratedBooks, {'tin'});
      c.chooseVoice('en-us-x-sfg-local');
      expect(c.narrated, isFalse);
      expect(prefs.toJson().containsKey('narratedBooks'), isFalse);
      final none = ListenController(prefs: prefs, language: 'en', bookId: 'tin', onChanged: ({required bool restart}) {});
      prefs.narratedBooks.add('tin');
      expect(none.narrated, isFalse, reason: 'a book with no narration cannot be read in one');
    });

    testWidgets("offered in the voice picker of a book that has one, and only there", (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final catalog = VoiceCatalog.instance;
      catalog.voices = const [
        VoiceInfo(name: 'en-us-x-sfg-local', locale: 'en-US', quality: 400, networkRequired: false, installed: true),
      ];
      catalog.loaded = true;
      addTearDown(() => catalog.voices = const []);
      final prefs = ListeningPrefs.memory;
      var restarts = 0;
      Future<ListenController> pick({required bool narration}) async {
        final c = ListenController(
          prefs: prefs,
          language: 'en',
          bookId: 'tin',
          narration: narration,
          onChanged: ({required bool restart}) => restarts += restart ? 1 : 0,
        );
        await tester.pumpWidget(MaterialApp(
          key: ValueKey(narration),
          home: Builder(
            builder: (context) => TextButton(onPressed: () => showVoicePicker(context, c), child: const Text('Voices')),
          ),
        ));
        await tester.tap(find.text('Voices'));
        await tester.pumpAndSettle();
        return c;
      }

      await pick(narration: false);
      expect(find.text("Book's own narration"), findsNothing);

      final c = await pick(narration: true);
      expect(find.text("Book's own narration"), findsOneWidget);
      expect(find.text('IN USE'), findsOneWidget);
      await tester.tap(find.text("Book's own narration"));
      await tester.pumpAndSettle();
      expect(c.narrated, isTrue);
      expect(restarts, 1, reason: 'a book being read goes on in the narration at once');
      expect(find.text('READS WHAT THE NARRATION LEAVES OUT'), findsOneWidget);
      expect(find.text('IN USE'), findsNothing);
    });
  });

  group('in the library', () {
    test('a book with one plays from its file; one imported before is read again for it', () async {
      final store = LibraryStore(dir);
      final entry = await store.importFile(PickedFile(path: epub, name: 'tin-box.epub'));
      var l = await store.loadLayout(entry.id);
      expect(l.book.narration, isNotNull);
      expect(BookNarrationReader.files[entry.id], entry.sourcePath);

      // As a build before narrations were read wrote it.
      final parsed = File('${store.bookDir(entry.id)}/parsed.json');
      final raw = jsonDecode(parsed.readAsStringSync()) as Map<String, Object?>;
      (raw['book'] as Map).remove('narration');
      raw.remove('n');
      parsed.writeAsStringSync(jsonEncode(raw));
      BookNarrationReader.files.clear();
      l = await store.loadLayout(entry.id);
      expect(l.book.narration?.clips, hasLength(10));
      expect(BookNarrationReader.files[entry.id], entry.sourcePath);
      expect((jsonDecode(parsed.readAsStringSync()) as Map)['n'], isNotNull);
    });

    test('an EPUB with none is only marked as looked at', () async {
      final store = LibraryStore(dir);
      final plain = File('${dir.path}/plain.epub')..writeAsBytesSync(_plainEpub());
      final entry = await store.importFile(PickedFile(path: plain.path, name: 'plain.epub'));
      final parsed = File('${store.bookDir(entry.id)}/parsed.json');
      final raw = jsonDecode(parsed.readAsStringSync()) as Map<String, Object?>;
      raw.remove('n');
      final before = jsonEncode(raw['book']);
      parsed.writeAsStringSync(jsonEncode(raw));
      final l = await store.loadLayout(entry.id);
      expect(l.book.narration, isNull);
      final after = jsonDecode(parsed.readAsStringSync()) as Map;
      expect(after['n'], isNotNull);
      expect(jsonEncode(after['book']), before, reason: 'it was not parsed again');
      expect(BookNarrationReader.files, isEmpty);
    });
  });
}

/// An EPUB 3 like the narrated one, its package naming no narration.
Uint8List _plainEpub() => narratedEpub(title: 'Plain', overlays: false);

/// A phone voice that says each line as a short tone, and a player that has
/// heard whatever it was given. What was asked and queued is kept.
class _Player extends SpeechService {
  _Player(this.dir);

  final Directory dir;
  final asked = <String>[];
  final queued = <Uint8List>[];
  final rates = <int>[];
  String? notice;
  var _frames = 0;
  var _n = 0;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    asked.add(text);
    final samples = Float32List(22050 ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = 0.3 * math.sin(2 * math.pi * 200 * i / 22050);
    }
    final f = File('${dir.path}/voice${_n++}.wav')..writeAsBytesSync(wavBytes(samples, 22050));
    return {'wavPath': f.path, 'engineId': 'test'};
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    queued.add(pcm);
    rates.add(sampleRate);
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

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
  Future<void> cancelSynthesis() async {}

  @override
  Future<void> setVolume(double volume) async {}
}

/// A decoder that cannot read the files [broken] says (a format the phone
/// has no decoder for).
class _Failing extends WavDecoder {
  _Failing(this.broken);

  final bool Function(String path) broken;

  @override
  Future<DecodedAudio> call({
    required String path,
    required int offset,
    required int length,
    required int beginUs,
    required int endUs,
  }) async {
    if (broken(path)) throw Exception('No decoder for $path');
    return super.call(path: path, offset: offset, length: length, beginUs: beginUs, endUs: endUs);
  }
}

class _Sink implements PcmSink {
  int? rate;
  final bytes = BytesBuilder();
  final pieces = <int>[];

  @override
  Future<void> open(int sampleRate) async => rate = sampleRate;

  @override
  Future<void> add(Uint8List pcm) async {
    bytes.add(pcm);
    pieces.add(pcm.length);
  }

  @override
  Future<void> flush() async {}
}
