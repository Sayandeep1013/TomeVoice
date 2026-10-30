// NovelUpdates has no API for apps, so TomeVoice keeps no reading list
// there: what it has, once turned on, is a link on a novel's page that finds
// the novel there in the browser. Never for a novel on a shut secret shelf.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/novel_screen.dart';
import 'package:tomevoice_spike/novel_updates.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/sources/models.dart';

const _channel = MethodChannel('tomevoice/tts');

const _plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a search there for the title', () {
    expect(NovelUpdates.searchFor(' Shadow Slave '), 'https://www.novelupdates.com/?s=Shadow+Slave&post_type=seriesplans');
    expect(NovelUpdates.searchFor('Re:Zero & More'), startsWith('https://www.novelupdates.com/?s=Re%3AZero+%26+More'));
  });

  test('off until turned on, and kept with the settings', () {
    expect(ListeningPrefs().novelUpdates, isFalse);
    final on = ListeningPrefs()..novelUpdates = true;
    expect(ListeningPrefs.fromJson(jsonDecode(jsonEncode(on.toJson())) as Map<String, Object?>).novelUpdates, isTrue);
    expect(NovelUpdates.offered(on: false, hidden: false), isFalse);
    expect(NovelUpdates.offered(on: true, hidden: true), isFalse, reason: 'a shut secret shelf');
    expect(NovelUpdates.offered(on: true, hidden: false), isTrue);
  });

  group("on a novel's page", () {
    late Directory tmp;
    final opened = <String>[];
    var unlock = false;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tv_nu');
      opened.clear();
      unlock = false;
      ListeningPrefs.reset();
      ListeningPrefs.memory.novelUpdates = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'openUrl') opened.add((call.arguments as Map)['url'] as String);
        if (call.method == 'confirmUser') return unlock;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      LibraryStore.secretOpen.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> settle(WidgetTester tester, bool Function() until) async {
      for (var i = 0; i < 60 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<LibraryStore> stored(WidgetTester tester, {bool secret = false}) async {
      final store = LibraryStore(tmp);
      await tester.runAsync(() async {
        final e = await store.addWebNovel(_plugin,
            const SourceNovel(path: 'novel/1', name: 'Shadow Slave', chapters: [ChapterItem(name: 'Chapter 1', path: 'ch/1')]));
        if (secret) {
          final shelf = await store.addCategory('Hidden', secret: true);
          await store.moveBooks({e.id}, shelf.id);
        }
      });
      return store;
    }

    testWidgets('the link finds the novel there, in the browser', (tester) async {
      phone(tester);
      final store = await stored(tester);
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: _plugin, path: 'novel/1', name: 'Shadow Slave')));
      await settle(tester, () => find.text('Chapter 1').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Novel options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find on NovelUpdates'));
      await tester.pumpAndSettle();
      expect(opened, ['https://www.novelupdates.com/?s=Shadow+Slave&post_type=seriesplans']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('turned off, there is no link', (tester) async {
      phone(tester);
      ListeningPrefs.memory.novelUpdates = false;
      final store = await stored(tester);
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: _plugin, path: 'novel/1', name: 'Shadow Slave')));
      await settle(tester, () => find.text('Chapter 1').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Novel options'));
      await tester.pumpAndSettle();
      expect(find.text('Find on NovelUpdates'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a novel on a shut secret shelf has no link until the shelf is opened', (tester) async {
      phone(tester);
      final store = await stored(tester, secret: true);
      LibraryStore.secretOpen.value = false;
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: _plugin, path: 'novel/1', name: 'Shadow Slave')));
      // Shut: the page is the site's (no network here, so no chapters).
      await settle(tester, () => find.text('Add to library').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Novel options'));
      await tester.pumpAndSettle();
      expect(find.text('Find on NovelUpdates'), findsNothing);
      await tester.tapAt(const Offset(10, 600));
      await tester.pumpAndSettle();

      LibraryStore.secretOpen.value = true;
      await settle(tester, () => find.text('In your library').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Novel options'));
      await tester.pumpAndSettle();
      expect(find.text('Find on NovelUpdates'), findsOneWidget);
      expect(opened, isEmpty);
      LibraryStore.secretOpen.value = false;
      await tester.pumpWidget(const SizedBox());
    });
  });
}
