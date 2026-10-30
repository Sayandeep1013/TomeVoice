// Voices: dialogue split from narration, audio joined across sample rates,
// and natural-voice audio in the form the pipeline reads.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/dialogue.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/listening_session.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/voices.dart';

VoiceInfo phone(String name, String locale) =>
    VoiceInfo(name: name, locale: locale, quality: 400, networkRequired: false, installed: true);

String show(List<Part> parts) => [for (final p in parts) '${p.spoken ? 'D' : 'N'}[${p.text}]'].join(' ');

void main() {
  test('dialogue is what is in quotation marks, around the speech tags', () {
    expect(show(splitDialogue('“Run,” she said, “now.”')), 'D[“Run,”] N[ she said, ] D[“now.”]');
    expect(show(splitDialogue('He said nothing.')), 'N[He said nothing.]');
    expect(show(splitDialogue('He whispered «stay» and left.')), 'N[He whispered ] D[«stay»] N[ and left.]');
  });

  test('a quote running over sentences is followed into each', () {
    expect(show(splitDialogue('“I came here all fired up.')), 'D[“I came here all fired up.]');
    expect(show(splitDialogue('Why couldn’t you?” she asked.')), 'D[Why couldn’t you?”] N[ she asked.]');
  });

  test('straight quotes over several sentences, told from the paragraph', () {
    // "I will go. You stay here. I'll be back," he said.
    expect(show(splitDialogue('"I will go.', startsInside: false)), 'D["I will go.]');
    expect(show(splitDialogue('You stay here.', startsInside: true)), 'D[You stay here.]');
    expect(show(splitDialogue('I\'ll be back," he said.', startsInside: true)), 'D[I\'ll be back,"] N[ he said.]');
  });

  test('apostrophes are not quotes', () {
    expect(show(splitDialogue('Zorian’s idea wasn’t bad.')), 'N[Zorian’s idea wasn’t bad.]');
  });

  test('audio is resampled to join voices at different rates', () {
    final second = Float32List.fromList([for (var i = 0; i < 22050; i++) math.sin(i / 10)]);
    final up = resample(second, 22050, 24000);
    expect(up.length, 24000);
    expect(identical(resample(second, 22050, 22050), second), isTrue);
  });

  test('a sentence at another rate joins the stream at its rate, not a new one', () {
    // A second of 16-bit PCM at 24000 Hz (a phone voice) after a natural
    // voice at 22050: converted, so the player is not restarted.
    final pcm = Int16List.fromList([for (var i = 0; i < 24000; i++) (math.sin(i / 10) * 20000).round()]);
    final out = resamplePcm16(pcm.buffer.asUint8List(), 24000, 22050);
    expect(out.lengthInBytes, 22050 * 2);
    final back = Int16List.view(out.buffer, out.offsetInBytes, out.lengthInBytes ~/ 2);
    expect(back.reduce(math.max), closeTo(20000, 300));
    // An odd offset (a slice of a larger buffer) still works.
    final odd = Uint8List(pcm.lengthInBytes + 1)..setRange(1, pcm.lengthInBytes + 1, pcm.buffer.asUint8List());
    expect(resamplePcm16(Uint8List.sublistView(odd, 1), 24000, 22050).lengthInBytes, 22050 * 2);
  });

  test('a natural voice writes the WAV the pipeline reads', () {
    final samples = Float32List.fromList([0, 0.5, -0.5, 1, -1, 0.25]);
    final decoded = WavCodec.decode(wavBytes(samples, 22050));
    expect(decoded.sampleRate, 22050);
    expect(decoded.frameCount, samples.length);
    for (var i = 0; i < samples.length; i++) {
      expect(decoded.samples[i], closeTo(samples[i], 1 / 16000));
    }
  });

  test('natural voices are named apart from the phone\'s', () {
    expect(isNeural('neural:en_US-kristin-medium'), isTrue);
    expect(isNeural('en-us-x-iob-local'), isFalse);
    expect(neuralVoiceFor('neural:en_GB-alan-medium')?.name, 'Alan');
    expect(neuralVoiceFor('neural:nobody'), isNull);
    for (final v in neuralVoices) {
      // Full precision: the fp16 models crash ONNX Runtime on the phone.
      expect(v.url, endsWith('vits-piper-${v.id}.tar.bz2'));
      expect(v.sizeMb, v.hd ? 110 : 64);
    }
    // Piper's own sample of each voice, to hear before downloading it.
    expect(neuralVoices.first.sampleUrl,
        'https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/kristin/medium/samples/speaker_0.mp3');
    expect(neuralVoiceFor('neural:en_GB-jenny_dioco-medium')!.sampleUrl,
        endsWith('/en/en_GB/jenny_dioco/medium/samples/speaker_0.mp3'));
  });

  test('each voice keeps its own pitch; the one pitch all voices shared is not carried over', () {
    final prefs = ListeningPrefs.fromJson({
      'settings': {'pitchSemitones': -7.4, 'speedScale': 1.25},
      'pitchByVoice': {'en-us-x-iob-local': -3.0},
    });
    expect(prefs.settings.pitchSemitones, 0, reason: 'on a Google voice it switched every voice to the old model');
    expect(prefs.settings.speedScale, 1.25);
    expect(prefs.pitchOf('en-us-x-iob-local'), -3);
    expect(prefs.pitchOf('bn-in-x-bnd-local'), 0, reason: 'another voice does not inherit it');
    expect(prefs.settingsFor('en-us-x-iob-local').pitchSemitones, -3);
    expect(prefs.settingsFor(null).pitchSemitones, 0);

    prefs.setPitch('bn-in-x-bnd-local', 2);
    prefs.setPitch('en-us-x-iob-local', 0);
    final again = ListeningPrefs.fromJson(prefs.toJson());
    expect(again.pitchByVoice, {'bn-in-x-bnd-local': 2.0}, reason: 'back at 0 is no entry at all');
  });

  test("Google's language alias is not listed beside the speaker it stands for", () {
    final catalog = VoiceCatalog.instance;
    catalog.voices = [
      phone('bn-IN-language', 'bn-IN'),
      phone('bn-in-x-bnc-local', 'bn-IN'),
      phone('bn-in-x-bnd-local', 'bn-IN'),
      phone('as-IN-language', 'as-IN'),
    ];
    expect([for (final v in catalog.forLanguage('bn')) v.name], ['bn-in-x-bnc-local', 'bn-in-x-bnd-local']);
    expect(catalog.forLanguage('bn', keep: 'bn-IN-language').map((v) => v.name), contains('bn-IN-language'),
        reason: 'the voice in use keeps its row');
    expect([for (final v in catalog.forLanguage('as')) v.name], ['as-IN-language'],
        reason: 'an alias with no named speakers is the only voice there is');
    expect(catalog.bestFor('bn')!.isAlias, isFalse);
    expect(catalog.friendlyName(catalog.byName('bn-in-x-bnd-local')!), 'Voice 2');
  });

  test('a long sentence is made in pieces cut where the voice pauses anyway', () {
    expect(clausePieces('Short and sweet, as it is.'), [(start: 0, text: 'Short and sweet, as it is.')]);
    const text = 'The old man, who had walked for hours along the river, sat down at last; '
        'he was tired, and the evening was coming on fast over the hills.';
    final pieces = clausePieces(text);
    expect(pieces.length, greaterThan(1));
    for (final p in pieces) {
      expect(text.substring(p.start).startsWith(p.text), isTrue, reason: 'pieces start where they say');
      expect(p.text.length, greaterThanOrEqualTo(40), reason: '"${p.text}" is too short to sound like a clause');
    }
    expect(pieces.map((p) => p.text).join(' '), text);
    // Each piece keeps its mark, so the voice still says it as a clause.
    expect(pieces.first.text, endsWith(','));
  });

  test('two natural voices stay loaded only on a phone with the memory for them', () {
    expect(NeuralEngine.slotsFor(null), 1);
    expect(NeuralEngine.slotsFor(3700 * 1024), 1, reason: 'a 4 GB phone');
    expect(NeuralEngine.slotsFor(5600 * 1024), 2, reason: 'a 6 GB phone reports about 5.6');
    expect(NeuralEngine.slotsFor(11200 * 1024), 2);
  });

  test('a dialogue line keeps each voice\'s own word timings, moved to where it sits', () async {
    // A phone voice's narration at 24 kHz, then a natural voice's quote at
    // 22050 Hz, joined at the narrator's rate.
    final narration = AudioBuffer(Float32List.fromList(List.filled(2400, 0.2)), 24000);
    final quote = AudioBuffer(Float32List.fromList(List.filled(2205, 0.2)), 22050);
    const text = 'She said “run” now';
    final pieces = [
      (
        audio: narration,
        offset: 0,
        timings: const [
          WordTiming(charStart: 0, charEnd: 3, frameStart: 0, frameEnd: 1200, source: WordTimingSource.engineReported),
          WordTiming(charStart: 4, charEnd: 8, frameStart: 1200, frameEnd: 2400, source: WordTimingSource.engineReported),
        ],
      ),
      (
        audio: quote,
        offset: text.indexOf('“'),
        timings: const [
          WordTiming(charStart: 1, charEnd: 4, frameStart: 0, frameEnd: 2205, source: WordTimingSource.anchored),
        ],
      ),
    ];
    final native = await joinParts(pieces, narratorRate: 24000);
    await File(native['wavPath']! as String).delete();
    final joined = SpeechService.timingsFromMaps(native['wordTimings']! as List, 4800);
    expect(joined, hasLength(3));
    expect(joined[1].source, WordTimingSource.engineReported, reason: 'the phone\'s timings were thrown away');
    expect(text.substring(joined[2].charStart, joined[2].charEnd), 'run');
    expect(joined[2].frameStart, 2400, reason: 'after the narration, at its rate');
    expect(joined[2].frameEnd, 4800);
    expect(joined[2].source, WordTimingSource.anchored);
  });

  test('timings already worked out are used as they are; with none, the pauses are found', () {
    final audio = AudioBuffer(Float32List.fromList([...List.filled(2400, 0.5), ...List.filled(2400, 0.0)]), 24000);
    final given = SpeechService.wordTimingsFor({
      'wordTimings': SpeechService.timingsToMaps(const [
        WordTiming(charStart: 0, charEnd: 2, frameStart: 10, frameEnd: 20, source: WordTimingSource.engineReported),
      ]),
    }, audio, 'Hi');
    expect(given.single.frameStart, 10);
    final found = SpeechService.wordTimingsFor({'rangeEvents': const []}, audio, 'Hello there');
    expect(found, hasLength(2));
    expect(found.every((t) => t.source == WordTimingSource.anchored), isTrue);
    expect(found.last.frameStart, lessThan(2400), reason: 'shared over the voice, not its silence');
  });

  test('settings saved before per-book speed and the skip choice load as they were', () {
    final old = ListeningPrefs.fromJson({
      'settings': {'speedScale': 1.25},
      'voiceByBook': {'b1': 'en-us-x-iob-local'},
    });
    expect(old.speedFor('b1'), 1.25);
    expect(old.speedByBook, isEmpty);
    expect(old.skipBy, SkipBy.sentence);
    expect(old.highlightOffset(SpeechService.routeBluetooth), 0);

    old.setOwnSpeed('b1', true);
    old.setSpeed(2.0, book: 'b1');
    old.setSpeed(0.9, book: 'b2');
    old.skipBy = SkipBy.chapter;
    old.highlightOffsetMs[SpeechService.routeBluetooth] = 120;
    final again = ListeningPrefs.fromJson(old.toJson());
    expect(again.speedFor('b1'), 2.0);
    expect(again.speedFor('b2'), 0.9, reason: 'a book without its own speed sets everyone\'s');
    expect(again.settings.speedScale, 0.9);
    expect(again.skipBy, SkipBy.chapter);
    expect(again.highlightOffset(SpeechService.routeBluetooth), 120);
    again.setOwnSpeed('b1', false);
    expect(again.speedFor('b1'), 0.9);
  });

  test('skip buttons: a sentence, 30 seconds, or left to the chapter', () {
    final layout = ReadingLayout.build(ingestString(
      '# One\n\n${'Sentence of six words said here. ' * 40}\n\n# Two\n\nAnother chapter starts here.',
      filename: 'b.md',
    ));
    expect(skipTarget(layout, 5, 1, SkipBy.sentence, 1, Duration.zero), 6);
    expect(skipTarget(layout, 5, -1, SkipBy.sentence, 1, Duration.zero), 4);
    expect(skipTarget(layout, 5, -1, SkipBy.sentence, 1, const Duration(seconds: 3)), 5,
        reason: 'under way, previous starts it again');
    // 30 s at 165 words a minute is about 82 words: about 14 sentences of 6.
    final on = skipTarget(layout, 5, 1, SkipBy.seconds, 1, Duration.zero)!;
    expect(on - 5, inInclusiveRange(12, 15));
    final faster = skipTarget(layout, 5, 1, SkipBy.seconds, 2, Duration.zero)!;
    expect(faster - 5, greaterThan(on - 5), reason: '30 seconds at 2x is more words');
    expect(skipTarget(layout, 5, 1, SkipBy.chapter, 1, Duration.zero), isNull);
  });

  test("a language the phone has no voice for is read in a related one, else in the phone's own", () {
    final catalog = VoiceCatalog.instance;
    addTearDown(() {
      catalog.voices = const [];
      catalog.phoneLanguage = null;
    });
    catalog.phoneLanguage = 'hi';
    catalog.voices = [
      phone('ru-ru-x-ruc-local', 'ru-RU'),
      phone('hi-in-x-hia-local', 'hi-IN'),
      phone('ar-xa-x-arc-local', 'ar-XA'),
      phone('en-us-x-iob-local', 'en-US'),
    ];
    for (final l in ['uk', 'be', 'bg', 'sr', 'mk']) {
      expect(catalog.bestFor(l)!.language, 'ru', reason: '$l went to ${catalog.bestFor(l)!.language}');
    }
    expect(catalog.bestFor('ur')!.language, 'hi');
    expect(catalog.bestFor('fa')!.language, 'ar');
    // No relative on the phone: its own language, not English.
    expect(catalog.bestFor('sv')!.language, 'hi');
    expect(catalog.bestFor('pl')!.language, 'hi');
    expect(languageName('be'), 'Belarusian');

    // A voice of its own wins.
    catalog.voices = [...catalog.voices, phone('uk-ua-x-hfd-local', 'uk-UA')];
    expect(catalog.bestFor('uk')!.language, 'uk');

    // The reader's usual Russian voice reads a Ukrainian book, not just any.
    catalog.voices = [
      phone('ru-ru-x-ruc-local', 'ru-RU'),
      const VoiceInfo(name: 'ru-ru-x-rud-local', locale: 'ru-RU', quality: 100, networkRequired: false, installed: true),
    ];
    final prefs = ListeningPrefs(voiceByLanguage: {'ru': 'ru-ru-x-rud-local'});
    final ukrainian = ListenController(prefs: prefs, language: 'uk', bookId: 'u1', onChanged: ({required bool restart}) {});
    expect(ukrainian.voiceName, 'ru-ru-x-rud-local');
  });

  test("a language's usual voice speaks that language", () {
    final catalog = VoiceCatalog.instance;
    catalog.voices = [
      phone('en-us-x-iob-local', 'en-US'),
      phone('bn-in-x-bnd-local', 'bn-IN'),
    ];
    // Saved by a Bengali novel the app took for English.
    final prefs = ListeningPrefs(voiceByLanguage: {'en': 'bn-in-x-bnd-local'});
    final english = ListenController(prefs: prefs, language: 'en', bookId: 'b1', onChanged: ({required bool restart}) {});
    expect(english.voiceName, 'en-us-x-iob-local');

    // Another language's voice for one book is that book's own.
    english.chooseVoice('bn-in-x-bnd-local');
    expect(english.voiceName, 'bn-in-x-bnd-local');
    expect(prefs.voiceByLanguage['en'], 'bn-in-x-bnd-local', reason: 'untouched, and still not used for English');
    final other = ListenController(prefs: prefs, language: 'en', bookId: 'b2', onChanged: ({required bool restart}) {});
    expect(other.voiceName, 'en-us-x-iob-local');

    final bengali = ListenController(prefs: prefs, language: 'bn', bookId: 'b3', onChanged: ({required bool restart}) {});
    bengali.chooseVoice('bn-in-x-bnd-local');
    expect(prefs.voiceByLanguage['bn'], 'bn-in-x-bnd-local');
  });
}
