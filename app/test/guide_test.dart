// The guide: shown by itself once, on a new install's first launch, and
// never to an update with a shelf or settings of its own; four cards,
// stepped through or skipped, each read out by TalkBack as it arrives; and
// shown again from Settings.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/guide.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_guide');
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    GuideScreen.onFirstLaunch = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return switch (call.method) {
        'launchArgs' => <String, Object?>{},
        'listEngines' => [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ],
        'listVoices' => [
            {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
          ],
        'outputDir' => _tmp.path,
        _ => null,
      };
    });
  });

  tearDown(() {
    GuideScreen.onFirstLaunch = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  /// The app opened on this folder, given the moment it takes a shelf to
  /// come up (and a guide over it).
  Future<void> launch(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(const SpikeApp());
    for (var i = 0; i < 40 && find.text('Library').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a first launch shows the guide once: its four cards stepped through, then the shelf', (tester) async {
    await launch(tester);
    expect(find.byType(GuideScreen), findsOneWidget);
    for (final (title, button) in [
      ('Bring your books', 'Next'),
      ('Press play', 'Next'),
      ('Two kinds of voice', 'Next'),
      ('Taps, holds and bars', 'Start reading'),
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
    }
    expect(find.byType(GuideScreen), findsNothing);
    expect(find.text('Library'), findsOneWidget);
    expect(ListeningPrefs.loaded!.guideShown, isTrue);
    // Kept, so the next launch does not show it.
    var kept = false;
    for (var i = 0; i < 40 && !kept; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 100));
      final f = File('${_tmp.path}/prefs.json');
      kept = f.existsSync() && f.readAsStringSync().contains('"guideShown":true');
    }
    expect(kept, isTrue);
    await finish(tester);
  });

  testWidgets('Skip, or Back, leaves it at any card', (tester) async {
    await launch(tester);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Press play'), findsOneWidget);
    // Back steps back a card, then Skip leaves.
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Bring your books'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.byType(GuideScreen), findsNothing);
    expect(find.text('Library'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an update, with books of its own, never sees it', (tester) async {
    await tester.runAsync(() async {
      final f = File('${_tmp.path}/incoming/story.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('A story already on the shelf, from before the guide.');
      await LibraryStore(_tmp).importFile(PickedFile(path: f.path, name: 'story.txt'));
    });
    await launch(tester);
    expect(find.text('Library'), findsOneWidget);
    expect(find.byType(GuideScreen), findsNothing);
    await finish(tester);
  });

  testWidgets('nor one with settings of its own and an empty shelf', (tester) async {
    File('${_tmp.path}/prefs.json').writeAsStringSync('{"gridView": false}');
    await launch(tester);
    expect(find.text('Library'), findsOneWidget);
    expect(find.byType(GuideScreen), findsNothing);
    await finish(tester);
  });

  testWidgets('TalkBack reads each card as it arrives, and every way out has a name', (tester) async {
    final semantics = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(const MaterialApp(home: GuideScreen()));
    await tester.pumpAndSettle();
    final title = tester.getSemantics(find.text('Bring your books'));
    expect(title.getSemanticsData().flagsCollection.isHeader, isTrue);
    expect(title.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(find.bySemanticsLabel('1 OF 4'), findsOneWidget);
    for (final name in ['Skip', 'Next']) {
      expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
    }
    expect(find.bySemanticsLabel('Back'), findsNothing, reason: 'not on the first card');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('Press play')).getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    semantics.dispose();
    await finish(tester);
  });

  testWidgets('Settings shows it again', (tester) async {
    phone(tester);
    late LibraryStore store;
    await tester.runAsync(() async {
      store = LibraryStore(_tmp);
      await ListeningPrefs.load(_tmp.path);
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();
    final again = find.text('Show the guide again');
    await tester.scrollUntilVisible(again, 400, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(again);
    await tester.pumpAndSettle();
    expect(find.byType(GuideScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(GuideScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    await finish(tester);
  });
}
