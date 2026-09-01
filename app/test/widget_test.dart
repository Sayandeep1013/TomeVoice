// Smoke tests for the spike screen.
//
// Replaces the stub `flutter create` generates, which references a `MyApp`
// class this project does not have.
//
// The screen talks to the platform on startup (listEngines, listVoices), so the
// method channel is mocked here. These are build-and-render checks; the audio
// pipeline is tested in packages/tomevoice_audio, where it runs without Flutter.

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
        'listVoices' => [
            {
              'name': 'en-us-x-good',
              'locale': 'en_US',
              'quality': 400,
              'networkRequired': false,
            },
            {
              'name': 'en-us-x-network',
              'locale': 'en_US',
              'quality': 500,
              'networkRequired': true,
            },
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

  /// The screen is a lazily-built ListView, so widgets below the fold are not
  /// in the tree at all. A tall surface keeps every control built, which is
  /// simpler and less brittle than scrolling to each one.
  Future<void> pumpTall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
  }

  testWidgets('queries engines and voices on startup', (tester) async {
    await pumpTall(tester);

    expect(calls, contains('listEngines'));
    expect(calls, contains('listVoices'));
    expect(find.text('TomeVoice audio spike'), findsOneWidget);
    expect(find.text('Synthesise'), findsOneWidget);
  });

  testWidgets('renders every control', (tester) async {
    await pumpTall(tester);

    expect(find.textContaining('Word gap'), findsOneWidget);
    expect(find.textContaining('Sentence pause'), findsOneWidget);
    // 'Speed' appears twice by design: the slider label and the mode switch.
    expect(find.textContaining('Speed'), findsWidgets);
    expect(find.byType(Slider), findsNWidgets(3));
  });

  testWidgets('speed defaults to the engine, not the pitch-shifting stub',
      (tester) async {
    await pumpTall(tester);

    // Regression guard. The DSP stub is a naive resampler that doubles the
    // pitch at 2x; it must never be the default a listener hears.
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isTrue);
    expect(find.textContaining('engine (natural)'), findsOneWidget);
  });

  testWidgets('prefers the best offline voice over a better network one',
      (tester) async {
    await pumpTall(tester);

    // A network voice scores higher but is useless offline, so the offline
    // voice must win the default.
    final dropdowns =
        tester.widgetList<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdowns.length, 2, reason: 'engine picker and voice picker');
    expect(dropdowns.last.initialValue, 'en-us-x-good');
  });

  testWidgets('Play and Export stay disabled until a run exists',
      (tester) async {
    await pumpTall(tester);

    for (final label in ['Play', 'Export WAV + JSON']) {
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull, reason: '$label should be disabled');
    }
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

    await pumpTall(tester);

    expect(find.textContaining('Could not list engines'), findsOneWidget);
  });
}
