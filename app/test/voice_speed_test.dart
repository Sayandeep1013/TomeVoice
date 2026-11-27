// Changing the speed while the voice reads, or while it is paused, and how
// soon the voice is heard: a run of taps on + is made again once, at the
// speed it was left on; a change made while paused is heard from the
// sentence on resume (it played on the old way before); a voice sample
// played meanwhile does not leave the resumed reading silent; the first
// sentence is made in two in the phone's voice as in a natural one; and the
// silences put in shrink above 1x.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/prefs.dart' show settingsFromJson, settingsToJson;
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tomevoice_speed'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  final book = ingestString(
    [
      '# Chapter 1',
      [for (var i = 1; i <= 30; i++) 'This is sentence number $i of the book.'].join(' '),
    ].join('\n\n'),
    filename: 'speed.md',
  );
  final layout = ReadingLayout.build(book);

  var speed = 1.0;
  var pitch = 0.0;
  setUp(() {
    speed = 1.0;
    pitch = 0.0;
  });

  PlaybackScheduler reader(_Voices voices, {List<Speakable>? units, bool quickStart = true, String voice = 'en-us'}) =>
      PlaybackScheduler(
        service: voices,
        units: units ?? layout.units,
        settingsFor: (text) => PipelineSettings(text: text, speedScale: speed, pitchSemitones: pitch),
        engineIdOf: () => 'engine',
        voiceNameOf: () => voice,
        pauseAfter: (_) => 300,
        quickStart: quickStart,
      );

  Future<void> until(bool Function() done, {int ms = 3000}) async {
    for (var waited = 0; waited < ms && !done(); waited += 10) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'waited $ms ms');
  }

  test('a run of taps on the speed is made again once, after the last, at the speed it was left on', () async {
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    // The sentence being heard when each restart came.
    final heardAt = <int>[];
    voices.onCancel = () => heardAt.add(player.unit.value);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    expect(voices.cancels, 1, reason: 'the first play');

    for (final s in [1.05, 1.1, 1.15, 1.2, 1.25]) {
      speed = s;
      player.remake();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    expect(voices.cancels, 1, reason: 'restarted while the taps were still coming');
    await until(() => voices.cancels == 2);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(voices.cancels, 2, reason: 'one restart for the run of taps, not one a tap');

    final heard = heardAt.last;
    final after = voices.asked.sublist(voices.askedAtCancel.last);
    expect(after, isNotEmpty);
    expect(after.first.text, layout.units[heard].text, reason: 'made again from the sentence being heard');
    expect(after.every((a) => a.rate == 1.25), isTrue, reason: 'at the speed it was left on');
    expect(player.remakeDue, isFalse);
  });

  group('a change of speed alone, with a natural voice', () {
    const natural = 'neural:test:voice';

    test('is heard at once: what was made is played at the new speed, not made again', () async {
      final voices = _Voices(dir);
      final player = reader(voices, voice: natural);
      addTearDown(player.dispose);
      await player.play(0);
      await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
      // Past the chapter's heading: a sentence of the book is being heard.
      await until(() => player.unit.value >= 1);
      final heardAt = <int>[];
      final queuedAt = <int>[];
      voices.onCancel = () {
        heardAt.add(player.unit.value);
        queuedAt.add(voices.queued.length);
      };
      final queuedBefore = voices.queued.length;
      // Each of the book's sentences, made at 1x: eight words and a pause.
      final whole = voices.queued.last.length;

      speed = 1.25;
      player.remake();
      await until(() => voices.cancels == 2);
      await until(() => !player.remakeDue);
      final heard = heardAt.last;
      final after = voices.asked.sublist(voices.askedAtCancel.last);
      expect(after.where((a) => a.text == layout.units[heard].text), isEmpty,
          reason: 'the sentence being heard is not made again');
      expect(voices.queued.length, greaterThan(queuedBefore), reason: 'queued again, stretched');
      // The first queued after the restart: the sentence heard, stretched.
      final stretched = voices.queued[queuedAt.last];
      expect(stretched.length, lessThan(whole * 0.9), reason: 'faster is shorter');
      expect(stretched.length, greaterThan(whole * 0.7), reason: 'by the speed, not more');
      expect(player.state.value, PlayState.playing);
      // What comes after what was made is made at the new speed.
      await until(() => voices.asked.length > voices.askedAtCancel.last);
      expect(voices.asked.skip(voices.askedAtCancel.last).every((a) => a.rate == 1.25), isTrue);
    });

    test('too big a change (1x to 3x) is made again, as before', () async {
      final voices = _Voices(dir);
      final player = reader(voices, voice: natural);
      addTearDown(player.dispose);
      await player.play(0);
      await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
      final heardAt = <int>[];
      voices.onCancel = () => heardAt.add(player.unit.value);

      speed = 3.0;
      player.remake();
      await until(() => voices.cancels == 2);
      await until(() => voices.asked.length > voices.askedAtCancel.last);
      final again = voices.asked[voices.askedAtCancel.last];
      expect(again.text, layout.units[heardAt.last].text);
      expect(again.rate, 3.0);
    });

    test('a change of anything else (the pitch) is made again, as before', () async {
      final voices = _Voices(dir);
      final player = reader(voices, voice: natural);
      addTearDown(player.dispose);
      await player.play(0);
      await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
      final heardAt = <int>[];
      voices.onCancel = () => heardAt.add(player.unit.value);

      speed = 1.25;
      pitch = 2;
      player.remake();
      await until(() => voices.cancels == 2);
      await until(() => voices.asked.length > voices.askedAtCancel.last);
      expect(voices.asked[voices.askedAtCancel.last].text, layout.units[heardAt.last].text);
    });

    test('stretched: the speech is shorter by the speed, its pitch kept', () {
      const rate = 24000;
      final samples = Float32List(rate);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = 0.4 * math.sin(2 * math.pi * 220 * i / rate);
      }
      final pcm = WavCodec.pcm16Bytes(AudioBuffer(samples, rate), silenceFrames: 2400);
      final out = restretchAll([(pcm: pcm, speechFrames: rate, silenceFrames: 1200, rate: rate, ratio: 1.25)]).single;
      expect(out.pcm.length ~/ 2, rate * 4 ~/ 5 + 1200);
      // Zero crossings per second: the same tone, so the same pitch.
      final data = ByteData.sublistView(out.pcm);
      var crossings = 0;
      for (var i = 1; i < rate * 4 ~/ 5; i++) {
        final a = data.getInt16((i - 1) * 2, Endian.little), b = data.getInt16(i * 2, Endian.little);
        if ((a < 0) != (b < 0)) crossings++;
      }
      expect(crossings / 0.8, closeTo(440, 15));
      expect(out.levels, isNotEmpty);
    });
  });

  test('a change made while paused is heard from the sentence when it resumes, not the old way', () async {
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    await player.pause(now: true);
    final heard = player.unit.value;

    speed = 2.0;
    player.remake();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(player.state.value, PlayState.paused, reason: 'a change does not start a paused book');
    expect(voices.cancels, 1);
    expect(player.remakeDue, isTrue);

    await player.resume();
    expect(voices.cancels, 2, reason: 'what was queued at the old speed is let go');
    await until(() => voices.asked.length > voices.askedAtCancel.last);
    final again = voices.asked[voices.askedAtCancel.last];
    expect(again.text, layout.units[heard].text);
    expect(again.rate, 2.0);
    expect(player.isPlaying, isTrue);
  });

  test('resumed with nothing changed, what was made is played on: nothing is made again', () async {
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    await player.pause(now: true);
    final enqueued = voices.queued.length;
    await player.resume();
    expect(voices.cancels, 1);
    expect(voices.resumes, 1);
    expect(voices.queued.length, enqueued, reason: 'the stream is played on, not queued again');
  });

  test('a voice sample played while paused: resumed, the sentence is queued again at once, not made again',
      () async {
    final voices = _Voices(dir);
    final player = reader(voices);
    addTearDown(player.dispose);
    await player.play(0);
    await until(() => player.state.value == PlayState.playing && voices.asked.length >= 3);
    await player.pause(now: true);
    final heard = player.unit.value;
    final asked = voices.asked.length;
    final enqueued = voices.queued.length;

    // A sample of a voice, tried in the sheet: it stops the stream and plays
    // into the player itself (speakSample).
    SpeechService.streamStops++;
    await player.resume();

    expect(voices.queued.length, greaterThan(enqueued), reason: 'its stream was gone: queued again');
    expect(voices.asked.skip(asked).where((a) => a.text == layout.units[heard].text), isEmpty,
        reason: 'what was made is queued again, not made afresh');
    expect(player.state.value, PlayState.playing);
  });

  test("a long first sentence in the phone's voice is made in two, its first clause first", () async {
    final long = ingestString(
      '# One\n\nIt was a bright cold day in April, and the clocks were striking thirteen across the town. Then quiet.',
      filename: 'long.md',
    );
    final units = ReadingLayout.build(long).units;
    final voices = _Voices(dir);
    final player = reader(voices, units: units);
    addTearDown(player.dispose);
    final first = units.indexWhere((u) => u.text.startsWith('It was'));
    await player.play(first);
    await until(() => voices.asked.length >= 2);
    expect(voices.asked[0].text, 'It was a bright cold day in April,');
    expect(voices.asked[1].text, ' and the clocks were striking thirteen across the town.');

    final whole = _Voices(dir);
    final off = reader(whole, units: units, quickStart: false);
    addTearDown(off.dispose);
    await off.play(first);
    await until(() => whole.asked.isNotEmpty);
    expect(whole.asked[0].text, units[first].text);
  });

  test('a long first sentence in a natural voice is queued a piece at a time, as the voice cuts it', () async {
    final clause = [
      'the rain came down on the long grey roofs of the old town for hours',
      'the lamps along the river were lit one after another',
      'the boats that had been out since dawn came back to the quay',
      'and the people who had waited went home to their suppers.',
    ];
    final sentence = 'All evening ${clause.join(', ')}';
    final long = ingestString('# One\n\n$sentence Then quiet.', filename: 'longer.md');
    final units = ReadingLayout.build(long).units;
    final first = units.indexWhere((u) => u.text.startsWith('All evening'));
    expect(units[first].text.length, greaterThan(240), reason: 'one sentence, not cut by the layout (280 at most)');

    final voices = _Voices(dir);
    final player = reader(voices, units: units, voice: 'neural:test:voice');
    addTearDown(player.dispose);
    await player.play(first);
    await until(() => voices.asked.any((a) => a.text.startsWith('Then')));
    final parts = voices.asked.takeWhile((a) => !a.text.startsWith('Then')).map((a) => a.text).toList();
    expect(parts.length, 4, reason: 'its first clause, then the rest at its commas');
    expect(parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim(), units[first].text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        reason: 'nothing left out or said twice');

    final phone = _Voices(dir);
    final plain = reader(phone, units: units);
    addTearDown(plain.dispose);
    await plain.play(first);
    await until(() => phone.asked.any((a) => a.text.startsWith('Then')));
    expect(phone.asked.takeWhile((a) => !a.text.startsWith('Then')).length, 2, reason: "the phone's voice: in two, as before");
  });

  group('the silences put in, at speed', () {
    test('shrink above 1x by the square root of the speed, and not below', () {
      expect(pauseScaleAt(1), 1);
      expect(pauseScaleAt(0.75), 1);
      expect(pauseScaleAt(2), closeTo(0.707, 0.001));
      expect(pauseScaleAt(3), closeTo(0.577, 0.001));
      const s = PipelineSettings(speedScale: 2, wordGapMs: 100, sentencePauseMs: 350);
      expect(pauseAtSpeed(350, s), 247);
      final inside = pausesAtSpeed(s);
      expect(inside.wordGapMs, 71);
      expect(inside.punctuation.commaMs, 106);
      expect(inside.punctuation.ellipsisMs, 212);
      expect(inside.speedScale, 2, reason: "the speed itself is the engine's");
    });

    test('kept as set when turned off, and at 1x', () {
      const off = PipelineSettings(speedScale: 3, wordGapMs: 100, pausesFollowSpeed: false);
      expect(pauseAtSpeed(350, off), 350);
      expect(identical(pausesAtSpeed(off), off), isTrue);
      const one = PipelineSettings(wordGapMs: 100);
      expect(pauseAtSpeed(350, one), 350);
      expect(pausesAtSpeed(one).wordGapMs, 100);
    });

    test('the choice is kept, and on for settings saved before it existed', () {
      final saved = settingsToJson(const PipelineSettings(pausesFollowSpeed: false));
      expect(settingsFromJson(saved).pausesFollowSpeed, isFalse);
      expect(settingsFromJson({...saved}..remove('pausesFollowSpeed')).pausesFollowSpeed, isTrue);
    });

    test('a sentence read at 2x is followed by a shorter pause than at 1x', () async {
      Future<int> tail(double at) async {
        final voices = _Voices(dir);
        final r = await makeSentence(
          service: voices,
          text: 'A short line to say.',
          settings: PipelineSettings(text: 'A short line to say.', speedScale: at),
          engineId: 'engine',
          narrator: 'en-us',
          dialogue: null,
          pauseAfterMs: () => 400,
        );
        return r!.totalFrames - r.speechFrames;
      }

      final one = await tail(1);
      final two = await tail(2);
      expect(one, 24000 * 400 ~/ 1000);
      expect(two, 24000 * 283 ~/ 1000);
    });
  });
}

/// A phone voice that says each line as a tone; a player whose head moves
/// on slowly, so reading goes on while a test looks. Everything asked is
/// kept, and where each restart came in it.
class _Voices extends SpeechService {
  _Voices(this.dir);

  final Directory dir;
  final asked = <({String text, double rate})>[];
  final queued = <Uint8List>[];

  /// How many sentences had been asked for at each cancel (a restart).
  final askedAtCancel = <int>[];
  var cancels = 0;
  var resumes = 0;
  void Function()? onCancel;
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
    queued.add(pcm);
    final start = _frames;
    _frames += pcm.length ~/ 2;
    return start;
  }

  /// A tenth of a second heard each time it is asked: never stuck, never at
  /// the end.
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
  Future<void> resumePlayback() async {
    resumes++;
  }

  @override
  Future<void> cancelSynthesis() async {
    cancels++;
    askedAtCancel.add(asked.length);
    onCancel?.call();
  }

  @override
  Future<void> setVolume(double volume) async {}
}
