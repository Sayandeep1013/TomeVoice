// When the phone's voice cannot read a book: its speech service crashes on
// the text (Android's -4, Samsung's engine handed Bengali), the voice never
// answers, or no voice reads the book's letters at all. Reading stops at
// once with a line saying why, not after restarting the engine sentence by
// sentence (which made an old phone crawl), and is not taken for the end of
// the chapter (which left the media card on Playing).

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/ai/chat/chat_screen.dart' show answerLanguage;
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/voices.dart';

void main() {
  final book = ingestString(
    [
      '# Chapter 1',
      'The first line is here. The second line follows it. A third comes after. And a fourth to end.',
    ].join('\n\n'),
    filename: 'fails.md',
  );
  final layout = ReadingLayout.build(book);

  Future<(PlaybackScheduler, _Failing)> read(PlatformException fail, {String? Function()? noVoice}) async {
    final voices = _Failing(fail);
    final player = PlaybackScheduler(
      service: voices,
      units: layout.units,
      settingsFor: (text) => const PipelineSettings().copyWith(text: text),
      engineIdOf: () => 'com.samsung.SMT',
      voiceNameOf: () => 'en-us',
      pauseAfter: (_) => 0,
      noVoice: noVoice,
    );
    await player.play(0);
    for (var i = 0; i < 200 && player.state.value != PlayState.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return (player, voices);
  }

  test("the engine's service crashing (-4) stops reading at the first sentence, saying why", () async {
    final (player, voices) =
        await read(PlatformException(code: 'TTS_ERROR', message: 'Synthesis failed (code -4)'));
    expect(player.state.value, PlayState.idle);
    expect(voices.asked, 1, reason: 'each sentence asked restarts the engine');
    expect(player.error.value, contains('-4'));
    expect(player.error.value, contains('another voice'));
    expect(player.reachedEnd, isFalse, reason: 'an error is not the end of the chapter');
    player.dispose();
  });

  test('a voice that never answers is not asked again', () async {
    final (player, voices) = await read(PlatformException(code: 'TTS_TIMEOUT', message: 'No callback within 30s'));
    expect(voices.asked, 1);
    expect(player.error.value, PlaybackScheduler.timeoutHint);
    expect(player.reachedEnd, isFalse);
    player.dispose();
  });

  test('one bad sentence is still passed over, as before', () async {
    final (player, voices) = await read(PlatformException(code: 'TTS_ERROR', message: 'Synthesis failed (code -3)'));
    expect(voices.asked, 3, reason: 'three failures end it');
    expect(player.error.value, 'Synthesis failed (code -3)');
    expect(player.reachedEnd, isFalse);
    player.dispose();
  });

  test('no voice for the letters: nothing is asked of the engine', () async {
    final (player, voices) = await read(PlatformException(code: 'TTS_ERROR'), noVoice: () => 'No Bengali voice');
    expect(voices.asked, 0);
    expect(player.error.value, 'No Bengali voice');
    expect(player.state.value, PlayState.idle);
    player.dispose();
  });

  test('a Bengali book with only English voices has none; a natural voice or a Bengali one reads it', () {
    final catalog = VoiceCatalog.instance;
    addTearDown(() {
      catalog
        ..voices = const []
        ..loaded = false;
    });
    catalog
      ..voices = const [
        VoiceInfo(name: 'en-us', locale: 'en-US', quality: 400, networkRequired: false, installed: true),
      ]
      ..loaded = true;
    expect(catalog.bestFor('bn'), isNull);
    expect(catalog.noVoiceFor('bn', null), contains('No Bengali voice'));
    expect(catalog.noVoiceFor('bn', 'en-us'), isNotNull);
    expect(catalog.noVoiceFor('en', null), isNull, reason: 'Latin letters: any voice will do');
    expect(catalog.noVoiceFor('fr', 'en-us'), isNull);
    catalog.voices = [
      ...catalog.voices,
      const VoiceInfo(name: 'bn-in', locale: 'bn-IN', quality: 400, networkRequired: false, installed: true),
    ];
    expect(catalog.bestFor('bn')!.name, 'bn-in');
    expect(catalog.noVoiceFor('bn', 'bn-in'), isNull);
    expect(VoiceCatalog.readsLettersOf('hi', 'mr'), isTrue, reason: 'the same letters');
    expect(VoiceCatalog.readsLettersOf('hi', 'ur'), isTrue, reason: 'a relative');
    expect(VoiceCatalog.readsLettersOf('en', 'bn'), isFalse);
  });

  test("an AI answer is read in its own language's voice", () {
    expect(answerLanguage('Darcy is proud [S1].'), 'en');
    expect(answerLanguage('ডারসি অহংকারী, এবং এলিজাবেথ তাকে পছন্দ করে না।'), 'bn');
    expect(answerLanguage('Sunny (সানি) is the hero.'), 'en');
    expect(answerLanguage('1, 2, 3'), 'en');
  });
}

/// A phone voice that fails every sentence with [fail]; counts what it is
/// asked.
class _Failing extends SpeechService {
  _Failing(this.fail);

  final PlatformException fail;
  var asked = 0;

  @override
  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
    bool urgent = true,
  }) async {
    asked++;
    throw fail;
  }

  @override
  Future<int> enqueue(Uint8List pcm, int sampleRate) async => 0;

  @override
  Future<int> position({bool raw = false}) async => 0;

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
