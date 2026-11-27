// The voice log (voice_log.dart): off, it notes nothing; on, reading aloud
// notes when each start was asked for and heard, every sentence made (its
// length, alphabet, time to make against time to say, speed and voice) and
// never a book's words; a change of speed is timed from the last tap; the
// log is kept on the phone, read back and cleared; and its summary says in
// plain words whether the phone keeps up, the gaps, the errors and which
// voice read which alphabet.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/voice_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final log = VoiceLog.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tomevoice_voicelog');
    log.reset();
  });
  tearDown(() {
    log.reset();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  final book = ingestString(
    [
      '# Chapter 1',
      [for (var i = 1; i <= 20; i++) 'Sunny walked past the ruined tower number $i.'].join(' '),
    ].join('\n\n'),
    filename: 'log.md',
  );
  final layout = ReadingLayout.build(book);

  var speed = 1.0;
  setUp(() => speed = 1.0);

  PlaybackScheduler reader(_Voices voices) => PlaybackScheduler(
        service: voices,
        units: layout.units,
        settingsFor: (text) => PipelineSettings(text: text, speedScale: speed),
        engineIdOf: () => 'engine',
        voiceNameOf: () => 'en-us',
        pauseAfter: (_) => 300,
      );

  Future<void> until(bool Function() done, {int ms = 3000}) async {
    for (var waited = 0; waited < ms && !done(); waited += 10) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'waited $ms ms');
  }

  test('off, reading aloud notes nothing', () async {
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    await player.stop();
    expect(log.on, isFalse);
    expect(log.events, isEmpty);
  });

  test("on, a start is noted asked and heard, each sentence made with its length and alphabet, never its words",
      () async {
    log.onForTests = true;
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && log.events.where((e) => e.kind == 'made').length >= 3);
    await player.pause();
    await player.stop();

    final kinds = log.events.map((e) => e.kind).toList();
    expect(kinds.first, 'ask');
    expect(log.events.first.s('for'), 'Play');
    expect(log.events.first.s('voice'), 'en-us');
    final sound = log.events.firstWhere((e) => e.kind == 'sound');
    expect(sound.s('after'), 'Play');
    expect(sound.n('ms'), isNotNull);
    final made = log.events.where((e) => e.kind == 'made').toList();
    expect(made.first.s('script'), 'Latin');
    expect(made.map((e) => e.n('chars')), anyElement(greaterThan(20)), reason: 'the heading, then sentences');
    expect(made.first.n('speechMs'), greaterThan(0));
    expect(made.first.n('speed'), 1.0);
    expect(kinds, containsAll(['pause', 'stop']));

    final text = voiceLogText(log.events, header: const ['Phone: a test']);
    for (final word in ['Sunny', 'ruined', 'tower', 'Chapter']) {
      expect(text, isNot(contains(word)), reason: "a book's words never go in the log");
    }
    expect(text, contains('Phone: a test'));
    expect(text, contains('After Play: the voice was heard in'));
  });

  test('a run of speed taps is timed from the last tap to the voice heard again', () async {
    log.onForTests = true;
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    for (final s in [1.25, 1.5, 1.75]) {
      speed = s;
      player.remake();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await until(() => log.events.any((e) => e.kind == 'sound' && e.s('after') == 'a change of speed or voice'));
    final ask = log.events.lastWhere((e) => e.kind == 'ask');
    expect(ask.s('for'), 'a change of speed or voice');
    expect(ask.n('speed'), 1.75);
    final heard = log.events.lastWhere((e) => e.kind == 'sound');
    expect(heard.n('ms'), greaterThanOrEqualTo(PlaybackScheduler.remakeAfter.inMilliseconds),
        reason: 'counted from the last tap, the wait for more taps included');
    await player.stop();
  });

  test('kept on the phone: on and its notes come back when the app opens again; cleared, they are gone', () async {
    await log.attach(dir);
    await log.setOn(true);
    log.note('made', {'chars': 40, 'script': 'Bengali', 'ms': 900, 'speechMs': 2000, 'speed': 1.0, 'voice': 'bn-in'});
    await log.flush();
    log.reset();
    await log.attach(dir);
    expect(log.on, isTrue);
    expect(log.events.map((e) => e.kind), containsAll(['log on', 'made']));
    expect(log.events.firstWhere((e) => e.kind == 'made').s('script'), 'Bengali');

    await log.clear();
    expect(log.events, isEmpty);
    expect(File('${dir.path}/${VoiceLog.fileName}').existsSync(), isFalse);
    await log.setOn(false);
    expect(File('${dir.path}/${VoiceLog.onName}').existsSync(), isFalse);
  });

  test('only the last notes are kept', () {
    log.onForTests = true;
    for (var i = 0; i < VoiceLog.keep + 50; i++) {
      log.note('made', {'n': i});
    }
    expect(log.events.length, VoiceLog.keep);
    expect(log.events.first.n('n'), 50);
  });

  test('the summary says in plain words how quick, whether it keeps up, the gaps, errors and voices', () {
    final t = DateTime(2026, 11, 23, 10);
    VoiceEvent e(String kind, Map<String, Object?> f) => VoiceEvent(t, kind, f);
    final events = [
      e('sound', {'after': 'Play', 'ms': 2800}),
      e('sound', {'after': 'Play', 'ms': 2400}),
      e('sound', {'after': 'a change of speed or voice', 'ms': 3200}),
      for (var i = 0; i < 4; i++) e('made', {'chars': 60, 'script': 'Latin', 'ms': 900, 'speechMs': 3000, 'speed': 1.0, 'voice': 'en-in'}),
      for (var i = 0; i < 4; i++) e('made', {'chars': 60, 'script': 'Latin', 'ms': 2600, 'speechMs': 1500, 'speed': 2.0, 'voice': 'en-in'}),
      e('made', {'chars': 50, 'script': 'Bengali', 'ms': 700, 'speechMs': 2000, 'speed': 1.0, 'voice': 'en-in'}),
      e('gap', {'ms': 1400}),
      e('gap', {'ms': 300}),
      e('error', {'code': 'TTS_TIMEOUT', 'message': 'no answer'}),
      e('memory low', {}),
    ];
    final s = voiceLogSummary(events).join('\n');
    expect(s, contains('After Play: the voice was heard in 2.8 s as a rule (2 times; slowest 2.8 s)'));
    expect(s, contains('After a change of speed or voice: the voice was heard in 3.2 s (once)'));
    expect(s, contains('At ${speedLabel(1)}: a sentence was made in 30% of the time it takes to say'));
    expect(s, contains('At ${speedLabel(2)}'));
    expect(s, contains('cannot keep up at this speed'));
    expect(s.split('\n').firstWhere((l) => l.startsWith('At ${speedLabel(1)}')), isNot(contains('cannot keep up')));
    expect(s, contains('ran dry 2 times'));
    expect(s, contains('1 over a second'));
    expect(s, contains('Bengali sentences were read by: en-in (1)'));
    expect(s, contains('TTS_TIMEOUT'));
    expect(s, contains('Android asked for memory back once'));
  });

  test('a log with only a resume says so; a natural voice loaded again is counted', () {
    final t = DateTime(2026, 11, 23, 22);
    VoiceEvent e(String kind, Map<String, Object?> f) => VoiceEvent(t, kind, f);
    final s = voiceLogSummary([
      e('resume', {}),
      e('voice loaded', {'voice': 'en_GB-jenny_dioco-medium', 'ms': 9000, 'waitedFor': true}),
      e('voice loaded', {'voice': 'en_GB-jenny_dioco-medium', 'ms': 7000}),
      e('made', {'chars': 103, 'script': 'Latin', 'ms': 20111, 'speechMs': 5250, 'speed': 1.0, 'voice': 'neural:x'}),
    ]).join('\n');
    expect(s, contains('Reading was only resumed with the log on'));
    expect(s, contains('A natural voice was loaded 2 times, in 9.0 s as a rule (slowest 9.0 s)'));
    expect(voiceLogSummary([e('made', {'chars': 10, 'ms': 1, 'speechMs': 2})]).first,
        startsWith('No start was timed yet'));
  });

  test('speeds are shown as the reader set them', () {
    final x = String.fromCharCode(0xD7);
    expect(speedLabel(1), '1$x');
    expect(speedLabel(1.15), '1.15$x');
    expect(speedLabel(2.5), '2.5$x');
  });

  test("a sentence's alphabet, told from its letters", () {
    expect(scriptOf('Sunny walked on.'), 'Latin');
    expect(scriptOf('সানি হেঁটে গেল।'), 'Bengali');
    expect(scriptOf('सनी चला गया।'), 'Devanagari');
    expect(scriptOf('桑尼走了。'), 'CJK');
    expect(scriptOf('Санни ушёл.'), 'Cyrillic');
    expect(scriptOf('... 123 !!'), 'none');
  });
}

class _Voices extends SpeechService {
  _Voices(this.dir);

  final Directory dir;
  final asked = <({String text, double rate})>[];
  var _n = 0;
  var _frames = 0;
  var _head = 0;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
    String? previousText,
    String? nextText,
  }) async {
    asked.add((text: text, rate: rate));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    const sr = 24000;
    final samples = <double>[];
    final events = <Map<String, int>>[];
    for (final m in RegExp(r'\S+').allMatches(text)) {
      events.add({'start': m.start, 'end': m.end, 'frame': samples.length});
      const n = sr * 120 ~/ 1000;
      for (var i = 0; i < n; i++) {
        samples.add(0.4 * math.sin(2 * math.pi * 220 * i / sr) * math.sin(math.pi * i / n));
      }
      samples.addAll(List.filled(sr * 30 ~/ 1000, 0.0));
    }
    final f = File('${dir.path}/s${_n++}.wav')..writeAsBytesSync(wavBytes(Float32List.fromList(samples), sr));
    return {'wavPath': f.path, 'engineId': 'test', 'rangeEvents': events};
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async {
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

  @override
  Future<int> position({bool raw = false}) async {
    _head = math.min(_head + 2400, math.max(0, _frames - 1));
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
  Future<void> pausePlayback() async {}

  @override
  Future<void> resumePlayback() async {}

  @override
  Future<void> cancelSynthesis() async {}

  @override
  Future<void> setVolume(double volume) async {}
}
