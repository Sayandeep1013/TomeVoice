// The loudness the glow behind the player follows.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/voice_glow.dart';

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

  testWidgets('the glow sleeps while it cannot be seen, and wakes when it can', (tester) async {
    final state = ValueNotifier(PlayState.playing);
    final level = ValueNotifier(0.5);
    final shown = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (context, on, _) => TickerMode(
          enabled: on,
          child: VoiceGlow(level: level, state: state),
        ),
      ),
    ));
    Future<int> stepsIn(Duration d) async {
      final before = VoiceGlow.debugSteps;
      for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 16)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      return VoiceGlow.debugSteps - before;
    }

    expect(await stepsIn(const Duration(seconds: 1)), greaterThan(20), reason: 'it does not glow while shown');

    // The player put away.
    shown.value = false;
    await tester.pump();
    expect(await stepsIn(const Duration(seconds: 1)), 0, reason: 'it ran on while hidden');

    // Shown, but the screen off (the app away).
    shown.value = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(await stepsIn(const Duration(seconds: 1)), 0, reason: 'it ran on with the screen off');

    // Back.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await stepsIn(const Duration(seconds: 1)), greaterThan(20), reason: 'it did not wake again');
    state.value = PlayState.idle;
    await tester.pump(const Duration(seconds: 2));
  });
}
