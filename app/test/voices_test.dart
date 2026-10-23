// Voices: dialogue split from narration, audio joined across sample rates,
// and natural-voice audio in the form the pipeline reads.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/dialogue.dart';
import 'package:tomevoice_spike/neural_voices.dart';

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
}
