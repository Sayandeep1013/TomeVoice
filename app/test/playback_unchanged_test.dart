// Reading aloud, sentence by sentence, exactly as it was before saving as
// audio came to share the making of a sentence with it: the same speech
// asked of the voices, in the same order and never two at once, and the
// same sound queued for the player, byte for byte (pauses, word gaps,
// levelling, a second voice's rate brought to the stream's).
//
// The oracle below is the scheduler's own code for one sentence as it stood
// before (scheduler.dart, _fill), copied here so it cannot drift with it.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/dialogue.dart';
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/reading_rules.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('tomevoice_unchanged'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

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
    ].join('\n\n'),
    filename: 'unchanged.md',
  );
  final layout = ReadingLayout.build(book);

  const base = PipelineSettings(wordGapMs: 60, sentencePauseMs: 300, paragraphPauseMs: 600);
  PipelineSettings settingsFor(String text) => base.copyWith(text: text, speedScale: 1.25, pitchSemitones: -2);
  const rules = [SayRule(from: 'Klein', to: 'Kline')];
  Respelled said(Speakable u) => respellUnit(u, rules);
  int pauseAfter(int i) => 200 + 50 * (i % 3);
  bool quoteOpenAt(int i) => i == 3;
  double pitchOf(String? voice) => voice == 'dialogue' ? 3.0 : 0.0;

  test('reading aloud asks for the same speech and queues the same sound as before', () async {
    final voices = _Voices(dir, 'a');
    final player = PlaybackScheduler(
      service: voices,
      units: layout.units,
      settingsFor: settingsFor,
      engineIdOf: () => 'engine',
      voiceNameOf: () => 'narrator',
      pauseAfter: pauseAfter,
      respell: said,
      dialogueVoiceOf: () => 'dialogue',
      pitchOf: pitchOf,
      quoteOpenAt: quoteOpenAt,
    );
    await player.play(0);
    for (var i = 0; i < 400 && player.state.value != PlayState.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(player.state.value, PlayState.idle, reason: 'the book was not read to its end');
    player.dispose();

    // The sentences as the scheduler made them before, one by one.
    final expected = _Voices(dir, 'b');
    final queued = <Uint8List>[];
    double? levelDb;
    int? streamRate;
    var resampled = 0;
    final sayable = RegExp(r'[\p{L}\p{N}]', unicode: true);
    for (var i = 0; i < layout.units.length; i++) {
      final text = said(layout.units[i]).text;
      if (!sayable.hasMatch(text)) continue;
      final s = settingsFor(text);
      final open = quoteOpenAt(i);
      final native = !(open || text.contains(RegExp('[“”"«»「」„]')))
          ? await expected.synthesise(
              text: text,
              engineId: 'engine',
              voiceName: 'narrator',
              rate: s.speedScale,
              pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
            )
          : await speakWithDialogue(
              svc: expected,
              text: text,
              startsInside: open,
              narrator: 'narrator',
              dialogueVoice: 'dialogue',
              engineId: 'engine',
              rate: s.speedScale,
              pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
              dialoguePitch: SpeechService.semitonesToPitch(pitchOf('dialogue')),
              level: s.normaliseLoudness,
            );
      final r = await renderInBackground(
        native: native,
        settings: s.copyWith(speedScale: 1.0, sentencePauseMs: 0, text: text),
        pauseAfterMs: pauseAfter(i),
        levelDb: levelDb,
      );
      final to = streamRate ??= r.sampleRate;
      if (to != r.sampleRate) resampled++;
      queued.add(to == r.sampleRate ? r.pcm : resamplePcm16(r.pcm, r.sampleRate, to));
      levelDb = r.gainDb;
    }

    expect(queued.length, greaterThan(5));
    expect(resampled, greaterThan(0), reason: 'no sentence was in the dialogue voice alone');
    expect(voices.overlapped, isFalse, reason: 'two sentences were made at once');
    expect(voices.asked, expected.asked, reason: 'other speech was asked for');
    expect(voices.asked.map((a) => a.voice).toSet(), {'narrator', 'dialogue'});
    expect(voices.asked.any((a) => a.text.contains('Klein')), isFalse, reason: 'the fix for Klein was not said');
    expect(voices.queued.length, queued.length);
    for (var k = 0; k < queued.length; k++) {
      expect(voices.queued[k], queued[k], reason: 'sentence $k sounds different');
    }
  });
}

/// A phone voice that says each line as a tone, a word a burst with a breath
/// between (its pitch the voice's, the dialogue voice at another rate), and
/// reports where its words start as Android does; a player that has heard
/// whatever it was given. Everything asked is kept.
class _Voices extends SpeechService {
  _Voices(this.dir, this.prefix);

  final Directory dir;
  final String prefix;
  final asked = <({String text, String? voice, double rate, double pitch, String? engine})>[];
  final queued = <Uint8List>[];
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
      asked.add((text: text, voice: voiceName, rate: rate, pitch: pitch, engine: engineId));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      return _speech(text, voiceName);
    } finally {
      _busy--;
    }
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
    final f = File('${dir.path}/$prefix${_n++}.wav')..writeAsBytesSync(wavBytes(Float32List.fromList(samples), rate));
    return {'wavPath': f.path, 'engineId': 'test', 'rangeEvents': events};
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
  Future<void> cancelSynthesis() async {}

  @override
  Future<void> setVolume(double volume) async {}
}
