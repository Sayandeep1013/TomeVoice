// The Google Play build (--dart-define=TV_STORE=play, the CI's play job):
// Browse and Sources stay but no source list comes with the app, no
// self-updater, only the voices whose recordings are open unless the reader
// asks for more, and the guide saying nothing of what is not there. In the
// ordinary test run (the GitHub build) the Play group is skipped.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/guide.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/neural_voices.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/settings_screen.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/store_build.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_play');
    ListeningPrefs.reset();
  });
  tearDown(() {
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  /// Every text a long page shows, from its top to its foot.
  Future<Set<String>> allTexts(WidgetTester tester) async {
    final seen = <String>{};
    void collect() {
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final s = t.data ?? t.textSpan?.toPlainText();
        if (s != null) seen.add(s);
      }
    }

    collect();
    for (var i = 0; i < 60; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pumpAndSettle();
      collect();
    }
    return seen;
  }

  test('More voices: non-commercial and unstated ones, never none-granted or a game character', () async {
    final text = await File('assets/voices/catalog.json').readAsString();
    final all = NeuralCatalog.parse(text, openOnly: false);
    final open = NeuralCatalog.parse(text, openOnly: true, wide: false);
    final more = NeuralCatalog.parse(text, openOnly: true, wide: true);
    expect(open.voices.map((v) => v.licence.use).toSet(), {LicenceUse.free, LicenceUse.credit});
    expect(more.voices.length, greaterThan(open.voices.length));
    expect(more.voices.length, lessThan(all.voices.length));
    expect(more.voices.map((v) => v.licence.use), contains(LicenceUse.noncommercial));
    expect(more.voices.map((v) => v.licence.use), isNot(contains(LicenceUse.restricted)));
    expect(more.voices.where((v) => v.id.toLowerCase().contains('glados')), isEmpty);
    final names = {for (final v in more.forLanguage('en')) v.name};
    expect(names, containsAll(['Ryan', 'Lessac', 'Amy']));
    expect(names, isNot(contains('Alan')));
  });

  group('the Play build', skip: !playBuild, () {
    test('comes with no source list', () {
      expect(SourceStore.builtIn, isEmpty);
    });

    test('only voices whose recordings are open', () async {
      final all = NeuralCatalog.parse(await File('assets/voices/catalog.json').readAsString(), openOnly: false);
      final play = NeuralCatalog.parse(await File('assets/voices/catalog.json').readAsString(), wide: false);
      expect(play.voices.length, lessThan(all.voices.length));
      expect(play.voices.map((v) => v.licence.use).toSet(), {LicenceUse.free, LicenceUse.credit});
      expect(play.voices, isNotEmpty);
    });

    testWidgets('Settings: sources and web novels stay; no new-version check', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(tmp))));
      await tester.pumpAndSettle();
      final texts = await allTexts(tester);
      expect(texts, isNot(contains('Tell me about new versions')));
      for (final kept in [
        'Sources',
        'Import from NovelDokusha',
        'Download speed',
        'Reading rules',
        'Interview me',
        'About TomeVoice',
      ]) {
        expect(texts, contains(kept), reason: kept);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('About: no updates from GitHub, no Releases; Privacy and the source code stay', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: AboutScreen(root: tmp)));
      await tester.pumpAndSettle();
      final texts = await allTexts(tester);
      expect(texts, isNot(contains('Check for updates')));
      expect(texts, isNot(contains('Releases')));
      expect(texts, contains('Privacy'));
      expect(texts, contains('Source code'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets("the guide says the source lists are the reader's own", (tester) async {
      phone(tester);
      await tester.pumpWidget(const MaterialApp(home: GuideScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('from the source lists you add'), findsOneWidget);
      expect(find.textContaining('web novels from their sites'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  test('the GitHub build keeps everything', skip: playBuild, () {
    expect(playBuild, isFalse);
  });
}
