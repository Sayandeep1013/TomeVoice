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

  test('apostrophes are not quotes', () {
    expect(show(splitDialogue('Zorian’s idea wasn’t bad.')), 'N[Zorian’s idea wasn’t bad.]');
  });

  test('audio is resampled to join voices at different rates', () {
    final second = Float32List.fromList([for (var i = 0; i < 22050; i++) math.sin(i / 10)]);
    final up = resample(second, 22050, 24000);
    expect(up.length, 24000);
    expect(identical(resample(second, 22050, 22050), second), isTrue);
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
  });
}
