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
import 'package:tomevoice_spike/problem_report.dart';
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

    testWidgets("Settings: sources and web novels stay; new versions from Play, not GitHub", (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: LibraryStore(tmp))));
      await tester.pumpAndSettle();
      final texts = await allTexts(tester);
      expect(texts, contains('Tell me about new versions'));
      expect(texts, contains('Asks Google Play whether a newer TomeVoice is out, and updates it here'));
      expect(texts.where((t) => t.contains('GitHub')), isEmpty);
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

    testWidgets('About: nothing points to GitHub; Privacy is its own page, reports go by email', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: AboutScreen(root: tmp)));
      await tester.pumpAndSettle();
      final texts = await allTexts(tester);
      // Updates come from Play, checked in the app.
      expect(texts, contains('Check for updates'));
      expect(texts, contains('New versions come from Google Play'));
      expect(texts, isNot(contains('Releases')));
      expect(texts, isNot(contains('Source code')));
      expect(texts.where((t) => t.contains('GitHub') || t.contains('github')), isEmpty);
      expect(texts, contains('Privacy'));
      expect(texts, contains('See every word it would say, then send it yourself by email'));
      expect(privacyUrl, isNot(contains('github')));
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
    expect(privacyUrl, contains('github.io'));
  });

  test('a problem report: GitHub in the GitHub build, an email in the Play one', () {
    const report = (title: 'Problem in TomeVoice 2.2.0', body: 'Line one\nA & B + C');
    final link = reportLink(report);
    if (playBuild) {
      expect(link.scheme, 'mailto');
      expect(link.path, reportEmail);
    } else {
      expect('${link.scheme}://${link.host}${link.path}', issuesUrl);
    }
    final mail = mailLink(report).toString();
    expect(mail, startsWith('mailto:$reportEmail?subject=Problem%20in%20TomeVoice%202.2.0&body='));
    expect(mail, contains('Line%20one%0AA%20%26%20B%20%2B%20C'));
    expect(mail, isNot(contains('+')));
  });

  test("the source code of this version, for the Play version's licences page", () {
    expect(sourceArchiveUrl('2.2.0'), '$repositoryUrl/archive/refs/tags/v2.2.0.zip');
    expect(sourceArchiveUrl('2.2.0+36'), '$repositoryUrl/archive/refs/tags/v2.2.0.zip');
    expect(sourceArchiveUrl(null), '$repositoryUrl/archive/refs/heads/main.zip');
  });
}
