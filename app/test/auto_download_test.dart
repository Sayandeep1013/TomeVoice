// New chapters downloading by themselves as a check finds them: the rules
// (off unless a novel asks, on Wi-Fi only unless it says any network), the
// app's engine queueing them, and the closed-app check fetching what it has
// time for and leaving the rest to the app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/auto_download.dart';
import 'package:tomevoice_spike/download_queue.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/updates.dart';

/// Sites as the tests make them up: each novel's list by path; chapters'
/// words made up; what was fetched counted.
class _Sites extends SourceEngine {
  _Sites() : super.forTests();

  final lists = <String, List<ChapterItem>>{};
  final fetched = <String>[];

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async =>
      SourceNovel(path: path, name: path, chapters: lists[path] ?? const []);

  @override
  Future<String> chapter(PluginInfo p, String path) async {
    fetched.add(path);
    return '<p>The words of $path, enough to read.</p>';
  }
}

class _Installed extends SourceStore {
  _Installed(super.root, this.plugins) : super(defaults: const []);

  final List<PluginInfo> plugins;

  @override
  Future<List<PluginInfo>> installed() async => plugins;

  @override
  Future<PluginInfo?> installedById(String id) async => plugins.where((p) => p.id == id).firstOrNull;
}

PluginInfo _plugin(String id) =>
    PluginInfo(id: id, name: 'Site $id', site: 'https://$id.test/', lang: 'English', version: '1', url: 'https://x/$id.js');

List<ChapterItem> _chapters(String novel, int n) => [for (var i = 1; i <= n; i++) ChapterItem(name: 'Chapter $i', path: '$novel/$i')];

NewChapter _new(String book, String path) =>
    NewChapter(bookId: book, title: 'Novel', index: 0, name: path, path: path, foundAt: DateTime(2026, 10, 31));

void main() {
  group('the rules', () {
    AutoDownload setting(String id) => switch (id) {
          'w' => AutoDownload.wifi,
          'a' => AutoDownload.any,
          _ => AutoDownload.off,
        };
    final found = [_new('w', 'w/1'), _new('a', 'a/1'), _new('o', 'o/1'), _new('w', 'w/2'), _new('a', 'a/1')];

    test('on Wi-Fi: every novel that asks; never one that does not', () {
      final p = planAutoDownloads(found, setting, unmetered: true);
      expect(p.now.map((k, v) => MapEntry(k, [for (final c in v) c.path])), {'w': ['w/1', 'w/2'], 'a': ['a/1']});
      expect(p.later, isEmpty);
    });

    test('off Wi-Fi: a novel on any network goes; one on Wi-Fi only waits for it', () {
      final p = planAutoDownloads(found, setting, unmetered: false);
      expect(p.now.keys, ['a']);
      expect([for (final c in p.later) c.path], ['w/1', 'w/2']);
    });

    test('off unless asked, on Wi-Fi only once asked; a chapter without its address is passed over', () {
      expect(AutoDownload.byName(null), AutoDownload.off);
      expect(AutoDownload.values[1], AutoDownload.wifi, reason: 'the first offered after Off');
      final old = NewChapter(bookId: 'a', title: 'Novel', index: 3, name: 'Chapter 4', foundAt: DateTime(2026));
      expect(planAutoDownloads([old], setting, unmetered: true).now, isEmpty);
    });

    test("a novel's choice is kept with the settings", () {
      final prefs = ListeningPrefs();
      AutoDownload.set('web-1', AutoDownload.any, prefs);
      AutoDownload.set('web-2', AutoDownload.wifi, prefs);
      final back = ListeningPrefs.fromJson(jsonDecode(jsonEncode(prefs.toJson())) as Map<String, Object?>);
      expect((AutoDownload.of('web-1', back), AutoDownload.of('web-2', back), AutoDownload.of('web-3', back)),
          (AutoDownload.any, AutoDownload.wifi, AutoDownload.off));
      AutoDownload.set('web-1', AutoDownload.off, back);
      expect(back.autoDownloadByNovel.containsKey('web-1'), isFalse);
    });
  });

  group('downloading them', () {
    late Directory tmp;
    late LibraryStore store;
    late _Sites sites;
    late SourceEngine before;
    late ListeningPrefs prefs;
    final queues = <DownloadQueue>[];

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tv_auto');
      store = LibraryStore(tmp);
      sites = _Sites();
      before = SourceEngine.instance;
      SourceEngine.instance = sites;
      sites.attach(_Installed(tmp, [_plugin('s')]));
      prefs = ListeningPrefs();
    });

    tearDown(() async {
      for (final q in queues) {
        await q.pause();
        await q.whenIdle();
      }
      queues.clear();
      SourceEngine.instance = before;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    /// A novel at site s with [n] chapters, set to [auto]; the site lists [more].
    Future<String> novel(String path, int n, AutoDownload auto, {int more = 2}) async {
      final e = await store.addWebNovel(_plugin('s'), SourceNovel(path: path, name: 'Novel $path', chapters: _chapters(path, n)));
      sites.lists[path] = _chapters(path, n + more);
      AutoDownload.set(e.id, auto, prefs);
      return e.id;
    }

    Future<DownloadQueue> paused() async {
      final q = DownloadQueue.forTests(pace: Duration.zero);
      queues.add(q);
      await q.attach(store);
      await q.pause();
      return q;
    }

    List<String> waiting(String book) => [
          for (final o in (jsonDecode(File('${tmp.path}/updates.json').readAsStringSync()) as Map)['auto'] as List? ?? const [])
            if ((o as Map)['book'] == book) o['path'] as String,
        ];

    test("in the app: a check's new chapters queued as each novel asks; Wi-Fi's wait for it", () async {
      final any = await novel('any', 3, AutoDownload.any);
      final wifi = await novel('wifi', 3, AutoDownload.wifi);
      final off = await novel('off', 3, AutoDownload.off);
      final q = await paused();
      var unmetered = false;
      final updates = Updates(store, auto: AutoDownloads(queue: q, unmetered: () async => unmetered, prefs: prefs));

      final r = await updates.checkAll();
      expect(r.found, 6);
      expect(q.waitingPaths(any), {'any/4', 'any/5'}, reason: 'any network: at once');
      expect(q.waitingPaths(wifi), isEmpty, reason: 'off Wi-Fi: waits');
      expect(q.waitingPaths(off), isEmpty);
      expect(waiting(wifi), ['wifi/4', 'wifi/5']);
      expect(waiting(off), isEmpty, reason: 'one that does not ask is not kept for later either');

      // Back to the app on Wi-Fi: they go.
      unmetered = true;
      await updates.takeWaiting();
      expect(q.waitingPaths(wifi), {'wifi/4', 'wifi/5'});
      expect(waiting(wifi), isEmpty);
    });

    test('in the app: one turned off while it waited is dropped', () async {
      final wifi = await novel('wifi', 3, AutoDownload.wifi);
      final q = await paused();
      var unmetered = false;
      final updates = Updates(store, auto: AutoDownloads(queue: q, unmetered: () async => unmetered, prefs: prefs));
      await updates.checkAll();
      AutoDownload.set(wifi, AutoDownload.off, prefs);
      unmetered = true;
      await updates.takeWaiting();
      expect(q.waitingPaths(wifi), isEmpty);
      expect(waiting(wifi), isEmpty);
    });

    test('away from the app: fetched while there is time, the rest left to the app once it opens', () async {
      final a = await novel('a', 2, AutoDownload.any, more: 3);
      final background = Updates(store, background: true);
      final r = await background.checkAll();
      expect(r.found, 3);
      var open = false;
      final got = await downloadAway(
        store,
        background,
        r.added,
        // The app opens once one chapter has come down.
        stopWhen: () async => open || (open = sites.fetched.isNotEmpty && store.downloadedChapters(a).isNotEmpty),
        unmetered: () async => true,
        until: DateTime.now().add(const Duration(minutes: 1)),
        pace: Duration.zero,
        prefs: prefs,
      );
      expect(got, 1);
      expect(store.downloadedChapters(a), {2});
      expect(waiting(a), ['a/4', 'a/5'], reason: 'left for the app');

      // The app opens: it queues what was left.
      final q = await paused();
      final app = Updates(store, auto: AutoDownloads(queue: q, unmetered: () async => true, prefs: prefs));
      await app.takeWaiting();
      expect(q.waitingPaths(a), {'a/4', 'a/5'});
    });

    test('away from the app: nothing fetched once out of time, or while downloads are paused', () async {
      final a = await novel('a', 2, AutoDownload.any);
      final background = Updates(store, background: true);
      final r = await background.checkAll();
      final outOfTime = await downloadAway(store, background, r.added,
          stopWhen: () async => false,
          unmetered: () async => true,
          until: DateTime.now().subtract(const Duration(seconds: 1)),
          pace: Duration.zero,
          prefs: prefs);
      expect(outOfTime, 0);
      expect(sites.fetched, isEmpty);
      expect(waiting(a), ['a/3', 'a/4']);

      File('${tmp.path}/downloads.json').writeAsStringSync(jsonEncode({'paused': true, 'jobs': []}));
      final held = await downloadAway(store, background, r.added,
          stopWhen: () async => false,
          unmetered: () async => true,
          until: DateTime.now().add(const Duration(minutes: 1)),
          pace: Duration.zero,
          prefs: prefs);
      expect(held, 0);
      expect(sites.fetched, isEmpty);
    });

    test("away from the app, off Wi-Fi: a novel on Wi-Fi only is left to wait, one on any network comes", () async {
      final wifi = await novel('w', 1, AutoDownload.wifi, more: 1);
      final any = await novel('n', 1, AutoDownload.any, more: 1);
      final background = Updates(store, background: true);
      final r = await background.checkAll();
      final got = await downloadAway(store, background, r.added,
          stopWhen: () async => false,
          unmetered: () async => false,
          until: DateTime.now().add(const Duration(minutes: 1)),
          pace: Duration.zero,
          prefs: prefs);
      expect(got, 1);
      expect(store.downloadedChapters(any), {1});
      expect(store.downloadedChapters(wifi), isEmpty);
      expect(waiting(wifi), ['w/2']);
    });
  });
}
