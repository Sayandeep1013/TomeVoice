// The loudness the glow behind the player follows.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/speech_service.dart';

/// [ms] of a 220 Hz tone whose loudness is [db] (RMS, dB below full scale).
List<double> tone(double db, int ms, {int rate = 22050}) {
  final peak = math.pow(10, db / 20) * math.sqrt2;
  return [for (var i = 0; i < rate * ms ~/ 1000; i++) peak * math.sin(2 * math.pi * 220 * i / rate)];
}

void main() {
  test('one level every 20 ms, rounded up', () {
    expect(speechLevels(List.filled(22050, 0.0), 22050).length, 50);
    expect(speechLevels(List.filled(441 * 2 + 1, 0.0), 22050).length, 3);
  });

  test('silence is nothing, a full voice is everything, the ear in between', () {
    expect(speechLevels(List.filled(4410, 0.0), 22050).every((l) => l == 0), isTrue);
    expect(speechLevels(tone(-60, 200), 22050).every((l) => l == 0), isTrue);
    expect(speechLevels(tone(-6, 200), 22050).every((l) => l == 255), isTrue);
    // -30 dB is half way between -50 and -10.
    for (final l in speechLevels(tone(-30, 200), 22050)) {
      expect(l, closeTo(128, 4));
    }
  });

  test('the same voice at another sample rate gives the same levels', () {
    final a = speechLevels(tone(-20, 200, rate: 24000), 24000);
    final b = speechLevels(tone(-20, 200), 22050);
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i], closeTo(b[i], 2));
    }
  });
}
