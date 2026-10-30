// A voice for each of a book's characters: the cast as the settings keep it
// (and a backup carries it), the limits on the voices it reads with, the
// scheduler giving each line its speaker's voice (and Save as audio the
// same), and natural voices never loaded past what the phone holds, nor
// reloaded between two characters' lines.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart' show PipelineSettings;
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/backup.dart';
import 'package:tomevoice_spike/cast.dart';
import 'package:tomevoice_spike/export_audio.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speakers.dart';
import 'package:tomevoice_spike/speech_service.dart';

final _o = String.fromCharCode(0x201C);
final _c = String.fromCharCode(0x201D);

late Directory _dir;

const _kristin = 'neural:en_US-kristin-medium';
const _norman = 'neural:en_US-norman-medium';
const _alan = 'neural:en_GB-alan-medium';
const _cori = 'neural:en_GB-cori-medium';

/// A Kokoro model holding many speakers, and three of them.
const _pack = NeuralPack(
  id: 'kokoro-multi-lang-v1_0',
  kind: NeuralKind.kokoro,
  name: 'Kokoro',
  file: 'model.onnx',
  bytes: 0,
  sampleRate: 24000,
);
final _kokoro = [
  for (final (sid, name) in const [(0, 'af_heart'), (1, 'am_adam'), (2, 'bf_emma')])
    NeuralVoice('${_pack.id}:$name', name, 'en-US', 0, kind: NeuralKind.kokoro, pack: _pack, sid: sid, sampleRate: 24000),
];

/// Characters who speak [lines] times each, most first.
List<Character> _people(List<(String, int)> lines) => [
      for (final (name, n) in lines) Character(name, gender: Gender.unknown, lines: n),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('tomevoice_cast');
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    PlaybackScheduler.beforePlay = null;
  });
  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('the cast, as the settings keep it', () {
    final darcy = Character('Darcy', also: ['Mr. Darcy'], gender: Gender.male, lines: 66);
    final elizabeth = Character('Elizabeth', gender: Gender.female, lines: 225);

    test('its people (the names they go by, their sex, their lines) and their voices', () {
      final cast = BookCast([elizabeth, darcy], {'Darcy': _alan, 'Elizabeth': BookCast.narrator});
      final back = BookCast.fromJson(jsonDecode(jsonEncode(cast.toJson())))!;
      expect(back.people.map((c) => c.name), ['Elizabeth', 'Darcy']);
      expect(back.people[1].also, {'Mr. Darcy'});
      expect(back.people[1].gender, Gender.male);
      expect(back.people[0].lines, 225);
      expect(back.voices, {'Darcy': _alan, 'Elizabeth': BookCast.narrator});
      expect(BookCast.fromJson('nonsense'), isNull);
      expect(BookCast.fromJson({'people': 'none'}), isNull);
      final stray = BookCast.fromJson({
        'people': [
          {'name': 'Jane'},
        ],
        'voices': {'Jane': 'a', 'Nobody': 'b'},
      })!;
      expect(stray.voices, {'Jane': 'a'}, reason: 'a voice for someone not in the cast was kept');
    });

    test("kept per book with the book's other voices, and only while someone has a voice", () {
      final p = ListeningPrefs();
      p.setCast('b1', BookCast([elizabeth]));
      expect(p.castByBook, isEmpty, reason: 'a cast that gives nobody a voice was kept');
      p.setCast('b1', BookCast([elizabeth, darcy], {'Darcy': _alan}));
      p.voiceByBook['b1'] = _kristin;
      final back = ListeningPrefs.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>);
      expect(back.castByBook['b1']!.voices, {'Darcy': _alan});
      expect(back.castByBook['b1']!.people.map((c) => c.name), ['Elizabeth', 'Darcy']);
      expect(back.voiceByBook['b1'], _kristin);
      back.setCast('b1', back.castByBook['b1']!.withVoice('Darcy', null));
      expect(back.castByBook, isEmpty);
      expect(ListeningPrefs().toJson().containsKey('castByBook'), isFalse, reason: 'every prefs file grew a key');
    });

    test('read again from the book, each voice stays with its character, by any name it goes by', () {
      final cast = BookCast([elizabeth, darcy], {'Darcy': _alan, 'Elizabeth': BookCast.narrator});
      // Read again, "Mr. Darcy" now the name the tags use most.
      final again = cast.refound([
        Character('Elizabeth', gender: Gender.female, lines: 230),
        Character('Mr. Darcy', also: ['Darcy'], gender: Gender.male, lines: 70),
        Character('Jane', gender: Gender.female, lines: 50),
      ]);
      expect(again.voices, {'Elizabeth': BookCast.narrator, 'Mr. Darcy': _alan});
      expect(again.people.map((c) => c.lines), [230, 70, 50]);
    });

    test('a voice taken off the phone leaves the cast', () {
      final cast = BookCast([elizabeth, darcy], {'Darcy': _alan, 'Elizabeth': _norman});
      expect(cast.without({_alan}).voices, {'Elizabeth': _norman});
    });

    test('a backup carries it, with the settings it is kept in', () async {
      final root = Directory('${_dir.path}/root')..createSync();
      final staging = Directory('${_dir.path}/root/.restore')..createSync();
      for (final d in [root, staging]) {
        File('${d.path}/library.json').writeAsStringSync(jsonEncode({'categories': [], 'books': []}));
      }
      final mine = ListeningPrefs()..setCast('b1', BookCast([elizabeth, darcy], {'Darcy': _alan}));
      File('${staging.path}/prefs.json').writeAsStringSync(jsonEncode(mine.toJson()));
      final info = BackupInfo(format: backupFormat, created: DateTime(2026), root: root.path, books: 0, chapters: false);
      final r = await addToLibrary(root, StagedBackup(staging, info), settings: true);
      expect(r.settings, isTrue);
      final restored = ListeningPrefs.fromJson(
        jsonDecode(File('${root.path}/prefs.json').readAsStringSync()) as Map<String, Object?>,
      );
      expect(restored.castByBook['b1']!.voices, {'Darcy': _alan});
    });
  });

  group('the voices it reads with', () {
    test('at most four of their own, the characters who speak most first', () {
      final people = _people([for (var i = 0; i < 6; i++) ('P$i', 60 - i)]);
      final cast = BookCast(people, {for (var i = 0; i < 6; i++) 'P$i': 'phone-$i'});
      final got = castVoices(cast, narrator: 'phone-n', dialogue: 'phone-d', slots: 2);
      expect(got, {0: 'phone-0', 1: 'phone-1', 2: 'phone-2', 3: 'phone-3'});
      expect(castRefusal(cast.withVoice('P5', null), 'P5', 'phone-5', narrator: 'phone-n', dialogue: 'phone-d', slots: 2),
          'The characters already have $maxCastVoices voices');
      // The same voice for two, the narrator's, or the dialogue voice: no new voice.
      final shared = BookCast(people, {
        for (var i = 0; i < 4; i++) 'P$i': 'phone-$i',
        'P4': 'phone-0',
        'P5': 'phone-d',
      });
      expect(castVoices(shared, narrator: 'phone-n', dialogue: 'phone-d', slots: 2), hasLength(6));
    });

    test('no natural voice whose model the phone could not keep loaded with the narrator', () {
      final people = _people([('Zorian', 30), ('Kirielle', 20), ('Benisek', 10)]);
      final cast = BookCast(people, {'Zorian': _norman, 'Kirielle': _alan, 'Benisek': 'phone-b'});
      // Two held: the narrator's and Zorian's. Kirielle's would be a third.
      expect(castVoices(cast, narrator: _kristin, dialogue: 'phone-d', slots: 2), {0: _norman, 2: 'phone-b'});
      // One held: the narrator's only.
      expect(castVoices(cast, narrator: _kristin, dialogue: 'phone-d', slots: 1), {2: 'phone-b'});
      expect(
        castRefusal(cast.withVoice('Kirielle', null), 'Kirielle', _alan, narrator: _kristin, dialogue: 'phone-d', slots: 1),
        'This phone keeps one natural voice loaded at a time',
      );
      // A phone narrator: room for two natural characters.
      expect(castVoices(cast, narrator: 'phone-n', dialogue: 'phone-d', slots: 2), {0: _norman, 1: _alan, 2: 'phone-b'});
      // A natural narrator and dialogue voice already past the room: nothing more.
      expect(castVoices(cast, narrator: _kristin, dialogue: _cori, slots: 1), {2: 'phone-b'});
    });

    test("one model's speakers (Kokoro) share it: as many as the other limits allow", () {
      NeuralVoices.instance.useCatalog(NeuralCatalog([...firstNeuralVoices, ..._kokoro], {_pack.id: _pack}));
      final people = _people([('A', 30), ('B', 20), ('C', 10)]);
      final cast = BookCast(people, {for (var i = 0; i < 3; i++) 'ABC'[i]: _kokoro[i].voiceName});
      // A phone narrator and one slot: one model, three speakers of it.
      expect(castVoices(cast, narrator: 'phone-n', dialogue: null, slots: 1), hasLength(3));
      // A Kokoro narrator: the same model, so its other speakers cost nothing.
      expect(castVoices(cast, narrator: _kokoro[0].voiceName, dialogue: null, slots: 1), hasLength(3));
      // A Piper narrator and one slot: no room for the Kokoro model at all.
      expect(castVoices(cast, narrator: _kristin, dialogue: null, slots: 1), isEmpty);
    });

    test('the narrator\'s voice for one read in it; a voice gone from the phone is the dialogue voice', () {
      final cast = BookCast(_people([('A', 2), ('B', 1)]), {'A': BookCast.narrator, 'B': 'gone'});
      expect(castVoices(cast, narrator: 'phone-n', dialogue: 'phone-d', slots: 1, here: (v) => v != 'gone'), {0: 'phone-n'});
    });
  });

  group('reading with a cast', () {
    final book = ingestString(
      [
        '# Chapter 1',
        '${_o}We should go,$_c said Zorian. ${_o}Now.$_c',
        'Kirielle shook her head. ${_o}Not yet.$_c',
        '${_o}Why not?$_c',
        '${_o}Because.$_c',
        'The rain went on all night over the roofs.',
        '${_o}Fine,$_c called a guard.',
      ].join('\n\n'),
      filename: 'cast.md',
    );
    final layout = ReadingLayout.build(book);
    final people = [
      Character('Zorian', gender: Gender.male, lines: 3),
      Character('Kirielle', gender: Gender.female, lines: 2),
    ];

    PlaybackScheduler player(
      _Voices voices, {
      BookCast? cast,
      Future<Int32List> Function(BookText part, List<Character> people)? attribute,
      bool withCast = true,
    }) {
      final prefs = ListeningPrefs();
      if (cast != null) prefs.setCast('b', cast);
      return PlaybackScheduler(
        service: voices,
        units: layout.units,
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => 'engine',
        voiceNameOf: () => 'narrator',
        pauseAfter: (_) => 100,
        dialogueVoiceOf: () => 'dialogue',
        speakers: withCast
            ? CastReading(
                bookId: 'b',
                layout: () => layout,
                prefs: () => prefs,
                narrator: () => 'narrator',
                dialogue: () => 'dialogue',
                attribute: attribute ?? (part, people) async => speakersOf(part, CastIndex(people)),
                slots: 2,
                here: (_) => true,
              )
            : null,
      );
    }

    Future<List<({String text, String? voice})>> read(PlaybackScheduler p, _Voices v) async {
      await p.play(0);
      await _until(() => p.state.value == PlayState.idle);
      p.dispose();
      expect(v.overlapped, isFalse, reason: 'two sentences were made at once');
      return v.asked;
    }

    final cast = BookCast(people, {'Zorian': 'zorian', 'Kirielle': BookCast.narrator});

    test("each line in its speaker's voice; a line it cannot place in the dialogue voice", () async {
      final v = _Voices('a');
      final asked = await read(player(v, cast: cast), v);
      expect([for (final a in asked) if (a.voice == 'zorian') a.text], ['${_o}We should go,$_c', '${_o}Now.$_c', '${_o}Why not?$_c']);
      expect([for (final a in asked) if (a.voice == 'dialogue') a.text], ['${_o}Fine,$_c']);
      // Kirielle is read in the narrator's voice: her lines are not cut.
      expect(asked.where((a) => a.text.contains('Not yet')).single, (text: '${_o}Not yet.$_c', voice: 'narrator'));
      expect(asked.where((a) => a.text.contains('Because')).single.voice, 'narrator');
      expect(asked.where((a) => a.text.contains('said Zorian')).single.voice, 'narrator');
    });

    test('a book with no cast, or a cast that gives nobody a voice, reads as before', () async {
      final none = _Voices('n');
      final before = await read(player(none, withCast: false), none);
      expect({for (final a in before) if (a.text.startsWith(_o)) a.voice}, {'dialogue'});
      for (final give in [null, BookCast(people)]) {
        final v = _Voices('e');
        expect(await read(player(v, cast: give), v), before);
      }
    });

    test('the same when the book is read for its speakers on another isolate, taking a while', () async {
      final quick = _Voices('q');
      final expected = await read(player(quick, cast: cast), quick);
      final slow = _Voices('s');
      final asked = await read(
        player(
          slow,
          cast: cast,
          attribute: (part, people) async {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            return Isolate.run(() => speakersOf(part, CastIndex(people)));
          },
        ),
        slow,
      );
      expect(asked, expected);
    });

    test('Save as audio gives each line the voice reading gives it', () async {
      final reading = _Voices('r');
      final heard = await read(player(reading, cast: cast), reading);
      final saving = _Voices('w');
      await AudioRenderer(plan: ExportPlan.book(layout), voice: player(saving, cast: cast), sink: _Sink()).run();
      expect(saving.asked, heard);
      expect(await player(_Voices('x'), cast: cast).quoteVoiceAt(layout.units.indexWhere((u) => u.text.contains('Why'))), 'zorian');
    });
  });

  group('natural voices for the characters', () {
    late _Worker worker;
    final lines = <String>[
      '# Chapter 1',
      for (var i = 0; i < 4; i++) ...[
        '${_o}Line $i of mine,$_c said Zorian.',
        '${_o}Line $i of mine too,$_c said Kirielle.',
        '${_o}And mine,$_c said Benisek.',
      ],
    ];
    final layout = ReadingLayout.build(ingestString(lines.join('\n\n'), filename: 'three.md'));
    final people = [
      Character('Zorian', gender: Gender.male, lines: 4),
      Character('Kirielle', gender: Gender.female, lines: 4),
      Character('Benisek', gender: Gender.male, lines: 3),
    ];

    setUp(() {
      worker = _Worker();
      NeuralEngine.workerForTests = worker.start;
      messenger.setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), (call) async => null);
    });
    tearDown(() {
      NeuralEngine.workerForTests = null;
      NeuralEngine.instance.forgetWorkerForTests();
      NeuralEngine.instance.slotsForTests = null;
      worker.close();
      messenger.setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), null);
    });

    Future<void> readAll(int slots) async {
      NeuralEngine.instance.slotsForTests = slots;
      final prefs = ListeningPrefs()
        ..setCast('b', BookCast(people, {'Zorian': _norman, 'Kirielle': _alan, 'Benisek': _cori}));
      final voices = _Natural();
      final p = PlaybackScheduler(
        service: voices,
        units: layout.units,
        settingsFor: (t) => const PipelineSettings().copyWith(text: t),
        engineIdOf: () => null,
        voiceNameOf: () => _kristin,
        pauseAfter: (_) => 100,
        dialogueVoiceOf: () => 'phone-dialogue',
        speakers: CastReading(
          bookId: 'b',
          layout: () => layout,
          prefs: () => prefs,
          narrator: () => _kristin,
          dialogue: () => 'phone-dialogue',
          attribute: (part, people) async => speakersOf(part, CastIndex(people)),
          here: (_) => true,
        ),
      );
      await p.play(0);
      await _until(() => p.state.value == PlayState.idle, within: const Duration(seconds: 30));
      p.dispose();
      expect(voices.phone.where((t) => t.contains('Line 3 of mine too')), isNotEmpty,
          reason: "a character without room for their voice is read in the dialogue voice");
    }

    test('two held: the narrator and the character who speaks most, each loaded once', () async {
      await readAll(2);
      expect(worker.most, lessThanOrEqualTo(2), reason: 'more models were held than the phone keeps');
      expect(worker.loads, {'en_US-kristin-medium': 1, 'en_US-norman-medium': 1},
          reason: 'a model was loaded again between lines, or one with no room was loaded');
      expect(worker.said.where((s) => s.model == 'en_US-norman-medium').map((s) => s.text),
          contains('${_o}Line 3 of mine,$_c'));
    });

    test('one held: only the narrator, the characters in the dialogue voice', () async {
      await readAll(1);
      expect(worker.most, 1);
      expect(worker.loads.keys, ['en_US-kristin-medium']);
    });
  });
}

/// Until [done] holds; fails after [within].
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > within) fail('waited too long');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A WAV of [seconds] of quiet at [rate], written to [path].
String _quiet(String path, {double seconds = 0.2, int rate = 22050}) {
  File(path).writeAsBytesSync(wavBytes(Float32List((rate * seconds).round()), rate));
  return path;
}

/// Phone voices that say each line as a short tone, reporting where words
/// start as Android does, and a player that has heard whatever it was
/// given. Every line asked for is kept, with its voice.
class _Voices extends SpeechService {
  _Voices(this.prefix);

  final String prefix;
  final asked = <({String text, String? voice})>[];
  var overlapped = false;
  var _busy = 0;
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
    if (_busy > 0) overlapped = true;
    _busy++;
    try {
      asked.add((text: text, voice: voiceName));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      const rate = 24000;
      final samples = <double>[];
      final events = <Map<String, int>>[];
      for (final m in RegExp(r'\S+').allMatches(text)) {
        events.add({'start': m.start, 'end': m.end, 'frame': samples.length});
        final n = rate * (20 + 4 * (m.end - m.start)) ~/ 1000;
        for (var i = 0; i < n; i++) {
          samples.add(0.3 * math.sin(2 * math.pi * 220 * i / rate));
        }
        samples.addAll(List.filled(rate * 30 ~/ 1000, 0.0));
      }
      final f = File('${_dir.path}/$prefix${_n++}.wav')..writeAsBytesSync(wavBytes(Float32List.fromList(samples), rate));
      return {'wavPath': f.path, 'engineId': 'test', 'rangeEvents': events};
    } finally {
      _busy--;
    }
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
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

/// The phone's player as [_Voices] has it, natural voices made by the engine
/// (and so the stand-in worker), the phone's own as quiet; the lines the
/// phone's voices said are kept.
class _Natural extends _Voices {
  _Natural() : super('p');

  final phone = <String>[];

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    if (isNeural(voiceName)) {
      return const SpeechService()
          .synthesise(text: text, engineId: engineId, voiceName: voiceName, rate: rate, pitch: pitch, urgent: urgent);
    }
    phone.add(text);
    return {'wavPath': _quiet('${_dir.path}/phone${phone.length}.wav', rate: 24000), 'engineId': 'test', 'rangeEvents': const []};
  }
}

/// The natural voices' worker as the real one keeps models: up to the
/// phone's slots, the one used longest ago let go first. It counts each
/// model's loads and the most it held at once.
class _Worker {
  final held = <String>[];
  final loads = <String, int>{};
  final said = <({String model, String text})>[];
  var most = 0;
  ReceivePort? _inbox;

  void start(SendPort engine) {
    final inbox = _inbox = ReceivePort();
    engine.send(inbox.sendPort);
    unawaited(_serve(inbox, engine));
  }

  void close() => _inbox?.close();

  Future<void> _serve(ReceivePort inbox, SendPort engine) async {
    await for (final msg in inbox) {
      final m = Map<Object?, Object?>.from(msg as Map);
      switch (m['op']) {
        case 'unload':
          final keep = m['keep'];
          held.removeWhere((v) => keep is List ? !keep.contains(v) : m['model'] == null || v == m['model']);
          engine.send({'id': m['id']});
        case 'drop':
          break;
        case 'say':
          final model = m['model']! as String;
          final slots = (m['slots'] as int? ?? 1).clamp(1, 2);
          if (held.remove(model)) {
            held.add(model);
          } else {
            while (held.length >= slots) {
              held.removeAt(0);
            }
            held.add(model);
            loads[model] = (loads[model] ?? 0) + 1;
          }
          most = math.max(most, held.length);
          said.add((model: model, text: m['text']! as String));
          if (m['last'] == true) {
            engine.send({
              'id': m['id'],
              'wav': _quiet(m['out']! as String),
              'loadMs': 0,
              'joins': const <int>[],
              'threads': const <int>[],
            });
          } else {
            engine.send({'id': m['id'], 'loadMs': 0, 'threads': const <int>[]});
          }
      }
    }
  }
}

/// An encoder that keeps nothing.
class _Sink implements PcmSink {
  @override
  Future<void> open(int sampleRate) async {}

  @override
  Future<void> add(Uint8List pcm) async {}

  @override
  Future<void> flush() async {}
}
