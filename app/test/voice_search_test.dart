// Natural voices' search: every word must match a voice's name, language,
// accent (as people say it), its being a woman's or a man's voice, or what
// is said of it.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/neural_screen.dart';
import 'package:tomevoice_spike/neural_voices.dart';

void main() {
  NeuralVoice voice(String id, String name, String locale, {String? gender}) => NeuralVoice.fromJson({
        'id': id,
        'engine': 'piper',
        'name': name,
        'locale': locale,
        'quality': 'medium',
        'bytes': 60000000,
        'sampleRate': 22050,
        'speakers': 1,
        if (gender != null) 'gender': gender,
        'licence': {'name': 'CC0', 'use': 'any'},
      }, const {})!;

  final alba = voice('en_GB-alba-medium', 'Alba', 'en-GB', gender: 'female');
  final ryan = voice('en_US-ryan-high', 'Ryan', 'en-US', gender: 'male');
  final hindi = voice('hi_IN-pratham-medium', 'Pratham', 'hi-IN', gender: 'male');

  test('a language, an accent as people say it, and a woman or a man', () {
    expect(voiceMatches(alba, 'british female'), isTrue);
    expect(voiceMatches(alba, 'United Kingdom'), isTrue);
    expect(voiceMatches(ryan, 'american'), isTrue);
    expect(voiceMatches(hindi, 'hindi'), isTrue);
    expect(voiceMatches(hindi, 'Pratham'), isTrue);
    expect(voiceMatches(alba, 'hindi'), isFalse);
  });

  test('"male" is not found in "female"', () {
    expect(voiceMatches(alba, 'male'), isFalse);
    expect(voiceMatches(ryan, 'male'), isTrue);
    expect(voiceMatches(ryan, 'female'), isFalse);
  });

  test('every word must match', () {
    expect(voiceMatches(alba, 'british male'), isFalse);
    expect(voiceMatches(ryan, 'english ryan'), isTrue);
  });
}
