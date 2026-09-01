// Widget tests for the reading surface and the pop-out settings panel.
//
// The screen talks to the platform on startup (launchArgs, listEngines,
// listVoices), so the method channel is mocked. These are structure and
// wiring checks; the audio pipeline is tested in packages/tomevoice_audio,
// where it runs without Flutter at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/settings_panel.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        // Not a batch launch, so the reader is shown.
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
            // Higher quality but Arabic: must lose to the English voice.
            {
              'name': 'ar-language',
              'locale': 'ar',
              'quality': 500,
              'networkRequired': false,
            },
            {
              'name': 'en-GB-language',
              'locale': 'en_GB',
              'quality': 300,
              'networkRequired': false,
            },
            {
              'name': 'en-US-network',
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

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SpikeApp());
    await tester.pumpAndSettle();
  }

  group('reading surface', () {
    testWidgets('renders the chrome from the reference design',
        (tester) async {
      await pumpApp(tester);

      expect(find.text('Library'), findsOneWidget);
      // Monospace instrumentation, not headline copy.
      expect(find.textContaining('VOICE:'), findsOneWidget);
      expect(find.textContaining('SPEED:'), findsOneWidget);
      expect(find.textContaining('GAP:'), findsOneWidget);
    });

    testWidgets('the text is the loudest thing on screen', (tester) async {
      await pumpApp(tester);

      final display = tester.widget<Text>(
        find.textContaining('quick brown fox').first,
      );
      expect(display.style?.fontFamily, 'Ojuju',
          reason: 'the specimen face is reserved for the text being read');
      expect(display.style?.fontSize, greaterThan(24));
    });

    testWidgets('starts on a preset rather than an arbitrary state',
        (tester) async {
      await pumpApp(tester);
      expect(find.textContaining('PRESET: NATURAL'), findsOneWidget);
    });
  });

  group('voice selection', () {
    testWidgets('language beats quality', (tester) async {
      await pumpApp(tester);

      // ar-language scores 500 and en-GB only 300, but the text is English.
      // Ranking by quality alone once shipped an Arabic voice for English text.
      expect(find.textContaining('EN-GB-LANGUAGE'), findsOneWidget);
      expect(find.textContaining('AR-LANGUAGE'), findsNothing);
    });

    testWidgets('offline beats a higher-scoring network voice',
        (tester) async {
      await pumpApp(tester);
      // en-US-network scores 500 but needs a connection; en-GB wins.
      expect(find.textContaining('EN-US-NETWORK'), findsNothing);
    });
  });

  group('pop-out panel', () {
    testWidgets('is closed until an edge tab is tapped', (tester) async {
      await pumpApp(tester);
      expect(find.byType(SettingsPanel), findsNothing);
    });

    testWidgets('opens on the speech tab and shows the presets',
        (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPanel), findsOneWidget);
      expect(find.text('Dyslexia'), findsOneWidget);
      expect(find.text('Learning'), findsOneWidget);
    });

    testWidgets('exposes the controls that actually change the audio',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      for (final label in [
        'Word gap',
        'Comma',
        'Sentence',
        'Paragraph',
        'Volume',
        'Speed',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('opens on the voice tab from the top-right control',
        (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.graphic_eq_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Pitch'), findsOneWidget);
      expect(find.textContaining('ENGINE'), findsWidgets);
    });

    testWidgets('applying a preset updates the reading surface',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dyslexia'));
      await tester.pumpAndSettle();

      // Dyslexia is the preset the word-gap feature exists for.
      expect(find.textContaining('GAP: 150MS'), findsOneWidget);
    });

    testWidgets('speed defaults to the engine, not the pitch-shifting stub',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      expect(find.text('via engine'), findsOneWidget);
      expect(find.text('via DSP stub'), findsNothing);
    });
  });
}
