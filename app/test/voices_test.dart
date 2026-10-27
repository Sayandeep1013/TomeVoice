// Voices: dialogue split from narration, audio joined across sample rates,
// and natural-voice audio in the form the pipeline reads.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/dialogue.dart';
import 'package:tomevoice_spike/listen_sheet.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
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
