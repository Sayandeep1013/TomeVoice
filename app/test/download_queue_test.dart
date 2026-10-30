// The download queue: chapters keep coming without the page that asked for
// them, a site is asked one chapter at a time and not too fast, failures are
// tried again later (as the site asks, when it says), and nothing waits on a
// chapter whose place in the list moved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/download_queue.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';

/// Sites as the tests make them up: each chapter's text by path, or what to
/// throw (a list of throws is used up one per try); when each was asked.
class _Sites extends SourceEngine {
  _Sites() : super.forTests();

  final pages = <String, Object>{};
  final asked = <String, List<DateTime>>{};
  final inFlight = <String, int>{};
  var mostAtOnceOneSite = 0;

  @override
  Future<String> chapter(PluginInfo p, String path) async {
    (asked[path] ??= []).add(DateTime.now());
    inFlight[p.id] = (inFlight[p.id] ?? 0) + 1;
    if (inFlight[p.id]! > mostAtOnceOneSite) mostAtOnceOneSite = inFlight[p.id]!;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      var page = pages[path] ?? '<p>The words of $path, enough to read.</p>';
      if (page is List && page.isNotEmpty) page = page.removeAt(0);
      if (page is Exception) throw page;
      return page as String;
    } finally {
      inFlight[p.id] = inFlight[p.id]! - 1;
    }
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

void main() {
  late Directory tmp;
  late LibraryStore store;
  late _Sites sites;
  late SourceEngine before;
  final queues = <DownloadQueue>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_queue');
    store = LibraryStore(tmp);
    sites = _Sites();
    before = SourceEngine.instance;
    SourceEngine.instance = sites;
    sites.attach(_Installed(tmp, [_plugin('a'), _plugin('b')]));
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
      // Windows may still hold a file a moment; best effort.
    }
  });

  /// A queue of the test's own, paused and let finish when the test ends.
  DownloadQueue queue({Duration pace = const Duration(milliseconds: 1500), Duration backoff = const Duration(seconds: 5)}) {
    final q = DownloadQueue.forTests(pace: pace, backoff: backoff);
    queues.add(q);
    return q;
  }

  Future<(String, List<ChapterItem>)> novel(String plugin, String path, int n) async {
    final chapters = [for (var i = 1; i <= n; i++) ChapterItem(name: 'Chapter $i', path: '$path/$i')];
    final e = await store.addWebNovel(_plugin(plugin), SourceNovel(path: path, name: 'Novel $path', chapters: chapters));
    return (e.id, chapters);
  }

  Future<void> until(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(within);
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('did not happen in time');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('chapters come down one at a time per site, paced, two sites at once', () async {
    final (a, ac) = await novel('a', 'na', 4);
    final (b, bc) = await novel('b', 'nb', 2);
    final q = queue(pace: const Duration(milliseconds: 150));
    await q.attach(store);
    expect(await q.add(a, ac), 4);
    expect(await q.add(b, bc), 2);
    expect(await q.add(a, ac.sublist(0, 2)), 0, reason: 'queued already');
    await until(() => q.of(a) == null && q.of(b) == null);
    expect((store.downloadedChapters(a).length, store.downloadedChapters(b).length), (4, 2));
    expect(sites.mostAtOnceOneSite, 1);
    final times = [for (var i = 1; i <= 4; i++) sites.asked['na/$i']!.single];
    for (var i = 1; i < times.length; i++) {
      expect(times[i].difference(times[i - 1]), greaterThanOrEqualTo(const Duration(milliseconds: 140)),
          reason: 'a pause between two requests to one site');
    }
    expect(sites.asked['nb/1']!.single.isBefore(times[1]), isTrue, reason: 'the other site did not wait');
    expect(q.of(a), isNull);
  });

  test('the queue is kept on disk: it carries on where it was when the app opens again', () async {
    final (a, ac) = await novel('a', 'na', 3);
    final q = queue();
    await q.attach(store);
    await q.pause();
    await q.add(a, ac);
    expect(jsonDecode(File('${tmp.path}/downloads.json').readAsStringSync())['jobs'], hasLength(3));

    // The app again, later: the queue as it was, paused, until Resume.
    final app = LibraryStore(tmp);
    final again = queue(pace: Duration.zero);
    await again.attach(app);
    expect((again.paused, again.of(a)!.waiting), (true, 3));
    await again.resume();
    await until(() => app.downloadedChapters(a).length == 3);
  });

  test('a failure is tried again later, as long as the site asks; then it is said', () async {
    final (a, ac) = await novel('a', 'na', 2);
    sites.pages['na/1'] = [RateLimitedException(const Duration(milliseconds: 300)), '<p>Words at last, enough to read.</p>'];
    sites.pages['na/2'] = SourceException('The site took too long to answer.');
    final q = queue(pace: Duration.zero, backoff: const Duration(milliseconds: 20));
    await q.attach(store);
    await q.add(a, ac);
    await until(() => store.hasChapter(a, 0));
    final tries = sites.asked['na/1']!;
    expect(tries[1].difference(tries[0]), greaterThanOrEqualTo(const Duration(milliseconds: 290)),
        reason: 'Retry-After is waited out');
    await until(() => q.of(a)?.failed == 1);
    expect(sites.asked['na/2'], hasLength(DownloadQueue.maxTries));
    final gaps = [for (var i = 1; i < sites.asked['na/2']!.length; i++) sites.asked['na/2']![i].difference(sites.asked['na/2']![i - 1])];
    expect(gaps.last, greaterThan(gaps.first), reason: 'the wait grows each time');
    expect(q.of(a)!.problem, contains('too long'));

    // Retry starts it again.
    sites.pages['na/2'] = '<p>It came, enough words to read.</p>';
    await q.retry(a);
    await until(() => q.of(a) == null);
    expect(store.hasChapter(a, 1), isTrue);
  });

  test('a source that needs the reader stops its novel, saying why', () async {
    final (a, ac) = await novel('a', 'na', 2);
    await store.addWebNovel(_plugin('gone'), SourceNovel(path: 'ng', name: 'Gone', chapters: ac));
    final gone = LibraryStore.webId('gone', 'ng');
    final q = queue(pace: Duration.zero);
    await q.attach(store);
    await q.add(gone, ac);
    await until(() => q.of(gone)?.failed == 2);
    expect(q.of(gone)!.problem, contains('not installed'));
    expect(sites.asked, isEmpty);
    await q.add(a, ac);
    await until(() => store.downloadedChapters(a).length == 2, within: const Duration(seconds: 5));
  });

  test('a chapter whose place moved after it was queued is saved at its new place', () async {
    final (a, ac) = await novel('a', 'na', 3);
    final q = queue(pace: Duration.zero);
    await q.attach(store);
    await q.pause();
    await q.add(a, [ac[2]]);
    // The site put a prologue first: chapter 3 is now the fourth entry.
    await store.saveWebChapters(a, [const ChapterItem(name: 'Prologue', path: 'na/0'), ...ac]);
    await q.resume();
    await until(() => store.downloadedChapters(a).isNotEmpty);
    expect(store.downloadedChapters(a), {3});
  });
}
