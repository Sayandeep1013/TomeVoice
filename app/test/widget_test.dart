// Widget tests for the library, reading surface and the pop-out settings panel.
//
// The screen talks to the platform on startup (launchArgs, listEngines,
// listVoices, outputDir), so the method channel is mocked. These are structure
// and wiring checks; the audio pipeline is tested in packages/tomevoice_audio
// and ingestion in packages/tomevoice_document, where they run without Flutter.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/brand.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/settings_panel.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
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
        'outputDir' => Directory.systemTemp.path,
        'stop' => null,
        'play' => null,
        'pickDocument' => null,
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

  Future<void> pumpReader(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Specimen'));
    await tester.pumpAndSettle();
  }

  group('library', () {
    testWidgets('is the home surface', (tester) async {
      await pumpApp(tester);
      expect(find.byType(BrandMark), findsWidgets);
      expect(find.textContaining('TomeVoice'), findsWidgets);
      expect(find.text('Specimen'), findsOneWidget);
      expect(find.textContaining('quick brown fox'), findsWidgets);
      expect(find.text('IMPORT A FILE'), findsOneWidget);
      expect(find.text('YOUR BOOKS'), findsOneWidget);
      expect(find.text('IMPORTED BOOKS APPEAR HERE.'), findsOneWidget);

      final bookTitle = tester.widget<Text>(find.text('Specimen'));
      expect(bookTitle.style?.fontFamily, 'Ojuju',
          reason: 'Ojuju is the title face, not the page');
      final pangram = tester.widget<Text>(
        find.textContaining('quick brown fox').first,
      );
      expect(pangram.style?.fontFamily, 'serif',
          reason: 'the pangram on the shelf is book text, not a title');
    });
  });

  group('reading surface', () {
    testWidgets('renders the chrome from the reference design',
        (tester) async {
      await pumpReader(tester);

      expect(find.text('Library'), findsWidgets);
      expect(find.textContaining('VOICE:'), findsOneWidget);
      expect(find.textContaining('SPEED:'), findsOneWidget);
      expect(find.textContaining('GAP:'), findsOneWidget);
    });

    testWidgets('the text is the loudest thing on screen', (tester) async {
      await pumpReader(tester);

      final display = tester.widget<Text>(
        find.textContaining('quick brown fox').first,
      );
      expect(display.style?.fontFamily, 'serif',
          reason: 'book text is a reading face, not Ojuju');
      expect(display.style?.fontSize, greaterThan(18));
    });

    testWidgets('sentence chevrons advance the visible sentence',
        (tester) async {
      await pumpReader(tester);
      expect(find.textContaining('quick brown fox'), findsWidgets);
      expect(find.textContaining('1 /'), findsOneWidget);

      await tester.tap(find.byTooltip('Next sentence'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Pack my box'), findsWidgets);
      expect(find.textContaining('2 /'), findsOneWidget);
    });

    testWidgets('tapping a sentence starts from there', (tester) async {
      await pumpReader(tester);
      expect(find.textContaining('1 /'), findsOneWidget);

      await tester.tap(find.textContaining('Pack my box'));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 /'), findsOneWidget);
    });

    testWidgets('starts on a preset rather than an arbitrary state',
        (tester) async {
      await pumpReader(tester);
      expect(find.textContaining('PRESET: NATURAL'), findsOneWidget);
    });
  });

  group('voice selection', () {
    testWidgets('language beats quality', (tester) async {
      await pumpReader(tester);

      expect(find.textContaining('EN-GB-LANGUAGE'), findsOneWidget);
      expect(find.textContaining('AR-LANGUAGE'), findsNothing);
    });

    testWidgets('offline beats a higher-scoring network voice',
        (tester) async {
      await pumpReader(tester);
      expect(find.textContaining('EN-US-NETWORK'), findsNothing);
    });
  });

  group('pop-out panel', () {
    testWidgets('is closed until an edge tab is tapped', (tester) async {
      await pumpReader(tester);
      expect(find.byType(SettingsPanel), findsNothing);
    });

    testWidgets('opens on the speech tab and shows the presets',
        (tester) async {
      await pumpReader(tester);

      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPanel), findsOneWidget);
      expect(find.text('Dyslexia'), findsOneWidget);
      expect(find.text('Learning'), findsOneWidget);
    });

    testWidgets('exposes the controls that actually change the audio',
        (tester) async {
      await pumpReader(tester);
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
      await pumpReader(tester);

      await tester.tap(find.byIcon(Icons.graphic_eq_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Pitch'), findsOneWidget);
      expect(find.textContaining('ENGINE'), findsWidgets);
    });

    testWidgets('applying a preset updates the reading surface',
        (tester) async {
      await pumpReader(tester);
      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dyslexia'));
      await tester.pumpAndSettle();

      expect(find.textContaining('GAP: 150MS'), findsOneWidget);
    });

    testWidgets('speed defaults to the engine, not the pitch-shifting stub',
        (tester) async {
      await pumpReader(tester);
      await tester.tap(find.byIcon(Icons.text_fields_rounded));
      await tester.pumpAndSettle();

      expect(find.text('via engine'), findsOneWidget);
      expect(find.text('via DSP stub'), findsNothing);
    });
  });
}
