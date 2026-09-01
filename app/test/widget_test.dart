// Smoke test for the spike screen.
//
// Replaces the stub `flutter create` generates, which references a `MyApp`
// class this project does not have.
//
// The screen talks to the platform on startup (listEngines), so the method
// channel is mocked here. This is a build-and-render check, not a test of the
// audio pipeline — that lives in packages/tomevoice_audio, where it can run
// without Flutter at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/main.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
            {'name': 'com.acme.tts', 'label': 'Acme TTS'},
          ],
        'outputDir' => '/tmp',
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('renders the controls and queries engines on startup',
      (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();

    expect(calls, contains('listEngines'));

    expect(find.text('TomeVoice audio spike'), findsOneWidget);
    expect(find.textContaining('Word gap'), findsOneWidget);
    expect(find.textContaining('Speed'), findsOneWidget);
    expect(find.textContaining('Sentence pause'), findsOneWidget);
    expect(find.text('Synthesise'), findsOneWidget);
  });

  testWidgets('Play and Export stay disabled until a run exists',
      (tester) async {
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();

    // Nothing has been synthesised, so there is nothing to play or export.
    final play = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Play'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(play.onPressed, isNull);

    final export = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Export WAV + JSON'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(export.onPressed, isNull);
  });

  testWidgets('surfaces engine failures instead of failing silently',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'listEngines') {
        throw PlatformException(code: 'ENGINE_LIST', message: 'no engines');
      }
      return null;
    });

    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not list engines'), findsOneWidget);
  });
}
