// Checking web novels for new chapters: what is recorded, how many sites are
// asked at once, and what a check made with the app closed may change.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/background_check.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/updates.dart';

/// Sites as the tests make them up: each novel's chapter list by path, or
/// an error to throw; with the calls in flight counted per site.
class _Sites extends SourceEngine {
  _Sites() : super.forTests();

  final lists = <String, Object>{};
  final delays = <String, Duration>{};
  final inFlight = <String, int>{};
  var mostAtOnceOneSite = 0;
  var mostAtOnce = 0;
  var asked = 0;

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async {
    asked++;
    inFlight[p.id] = (inFlight[p.id] ?? 0) + 1;
    final all = inFlight.values.fold(0, (a, b) => a + b);
    if (inFlight[p.id]! > mostAtOnceOneSite) mostAtOnceOneSite = inFlight[p.id]!;
    if (all > mostAtOnce) mostAtOnce = all;
    try {
      await Future<void>.delayed(delays[path] ?? const Duration(milliseconds: 30));
      final got = lists[path];
      if (got is Exception) throw got;
      return SourceNovel(path: path, name: path, chapters: got as List<ChapterItem>);
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

List<ChapterItem> _chapters(String novel, int n, {int from = 1}) =>
    [for (var i = from; i < from + n; i++) ChapterItem(name: 'Chapter $i', path: '$novel/ch-$i')];

void main() {
  late Directory tmp;
  late LibraryStore store;
  late _Sites sites;
  late SourceEngine before;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_updates');
    store = LibraryStore(tmp);
    sites = _Sites();
    before = SourceEngine.instance;
    SourceEngine.instance = sites;
    sites.attach(_Installed(tmp, [_plugin('a'), _plugin('b')]));
  });

  tearDown(() {
    SourceEngine.instance = before;
    LibraryStore.secretOpen.value = false;
    tmp.deleteSync(recursive: true);
  });

  Future<String> add(String plugin, String path, int chapters) async {
    final e = await store.addWebNovel(_plugin(plugin), SourceNovel(path: path, name: 'Novel $path', chapters: _chapters(path, chapters)));
    sites.lists[path] = _chapters(path, chapters);
    return e.id;
  }

  test('new chapters are logged by their address; a few sites are asked at once, each one at a time', () async {
    for (var i = 0; i < 3; i++) {
      await add('a', 'a$i', 5);
      await add('b', 'b$i', 5);
    }
    sites.lists['a1'] = _chapters('a1', 7);
    final updates = Updates(store);
    final r = await updates.checkAll();
    expect((r.found, r.checked, r.failed), (2, 6, 0));
    expect(sites.mostAtOnceOneSite, 1, reason: 'no site is asked about two novels at once');
    expect(sites.mostAtOnce, 2, reason: 'but both sites at the same time');
    final log = await updates.log();
    expect(log.items.map((c) => c.path), ['a1/ch-7', 'a1/ch-6'], reason: 'newest first');
    expect(log.checked, isNotNull);
    expect(log.problems, isEmpty);
  });

  test('Clear empties the list as shown, and nothing else: Undo puts it back beside what came since', () async {
    final a0 = await add('a', 'a0', 5);
    await add('b', 'b0', 5);
    sites.lists['a0'] = _chapters('a0', 7);
    sites.lists['b0'] = _chapters('b0', 6);
    final updates = Updates(store);
    await updates.checkAll();
    final raw = jsonDecode(File('${tmp.path}/updates.json').readAsStringSync()) as Map;
    final all = (await updates.log()).items;
    expect(all, hasLength(3));

    // A novel on a shut secret shelf is not shown, and not cleared.
    final shown = [for (final c in all) if (!c.path!.startsWith('b0')) c];
    await updates.forget(shown);
    var log = await updates.log();
    expect(log.items.map((c) => c.path), ['b0/ch-6']);
    expect(log.checked, isNotNull, reason: 'when the sites were last asked stays');
    final after = jsonDecode(File('${tmp.path}/updates.json').readAsStringSync()) as Map;
    expect({...after}..remove('new'), {...raw}..remove('new'), reason: 'everything else in the log is as it was');

    // Checks go on as ever, and Undo puts the cleared ones back with the new.
    sites.lists['a0'] = _chapters('a0', 8);
    await updates.checkAll();
    await updates.keepAgain(shown);
    log = await updates.log();
    expect(log.items.map((c) => c.path).toSet(), {'a0/ch-8', 'a0/ch-7', 'a0/ch-6', 'b0/ch-6'});
    expect(log.items.first.path, 'a0/ch-8', reason: 'newest first');
    expect((await store.webNovel(a0))?.chapters, hasLength(8), reason: 'the novel kept its chapters');
  });

  test('a run that reaches no site is not recorded as a check; why each source failed is kept', () async {
    await add('a', 'a0', 3);
    await add('a', 'a1', 3);
    await add('b', 'b0', 3);
    sites.lists['a0'] = SourceException('The site took too long to answer.');
    sites.lists['a1'] = SourceException('The site took too long to answer.');
    sites.lists['b0'] = ChallengeException('https://b.test/novel', pluginId: 'b');
    final updates = Updates(store);
    final r = await updates.checkAll();
    expect((r.checked, r.failed), (0, 3));
    final log = await updates.log();
    expect(log.checked, isNull, reason: 'offline, or every site down: tried again soon');
    expect(log.attempted, isNotNull);
    final problems = {for (final p in log.problems) p.pluginId: p};
    expect((problems['a']!.novels, problems['a']!.kind), (2, CheckProblemKind.failed));
    expect((problems['b']!.kind, problems['b']!.url), (CheckProblemKind.challenge, 'https://b.test/novel'));

    // Tried again no sooner than half an hour on.
    sites.asked = 0;
    expect(await updates.checkIfDue(UpdateEvery.daily), 0);
    expect(sites.asked, 0);
  });

  test('a source that is not installed is said, and a list that looks wrong is not stored', () async {
    final id = await add('a', 'a0', 10);
    await store.addWebNovel(_plugin('gone'), SourceNovel(path: 'g0', name: 'Gone', chapters: _chapters('g0', 2)));
    sites.lists['a0'] = _chapters('a0', 2);
    final updates = Updates(store);
    await updates.checkAll();
    final problems = {for (final p in (await updates.log()).problems) p.pluginId: p.kind};
    expect(problems, {'gone': CheckProblemKind.missing, 'a': CheckProblemKind.refused});
    expect((await store.webNovel(id))!.chapters, hasLength(10));
  });

  test('away from the app, only lists grown at their end are stored, and the index is left alone', () async {
    final grown = await add('a', 'a0', 5);
    final shifted = await add('b', 'b0', 5);
    sites.lists['a0'] = _chapters('a0', 6);
    // A chapter put in at the start: downloads would have to move.
    sites.lists['b0'] = [const ChapterItem(name: 'Prologue', path: 'b0/pro'), ..._chapters('b0', 5)];
    final index = File('${tmp.path}/library.json').readAsStringSync();

    final r = await Updates(LibraryStore(tmp), background: true).checkAll();
    expect(r.found, 1);
    expect(File('${tmp.path}/library.json').readAsStringSync(), index, reason: "the app's engine owns the index");
    expect((await store.webNovel(grown))!.chapters, hasLength(6));
    expect((await store.webNovel(shifted))!.chapters, hasLength(5), reason: 'left for the app to take');

    // The app, on opening: the counts reach the shelf.
    final app = LibraryStore(tmp);
    await Updates(app).takeCounts();
    expect((await app.list()).firstWhere((e) => e.id == grown).chapterCount, 6);
    expect(jsonDecode(File('${tmp.path}/updates.json').readAsStringSync()), isNot(contains('counts')));
  });

  /// library.json with books kept before series were, whose titles share
  /// one: found, it would be written in. The index as it is then.
  String withSeriesToFind() {
    final file = File('${tmp.path}/library.json');
    final raw = jsonDecode(file.readAsStringSync()) as Map;
    var n = 0;
    for (final title in ['A Game of Thrones A Song of Ice and Fire 1', 'A Storm of Swords A Song of Ice and Fire 3']) {
      (raw['books'] as List).add({
        'id': '00000000000000a${n++}',
        'title': title,
        'authors': <String>[],
        'source': 'epub',
        'wordCount': 1000,
        'sourcePath': '',
        'addedAt': DateTime(2026, 1, n).toIso8601String(),
        'category': 'reading',
      });
    }
    file.writeAsStringSync(jsonEncode(raw));
    return file.readAsStringSync();
  }

  test("away from the app, nothing found reading the index (a series, a place to take in) is written to it", () async {
    final a = await add('a', 'a0', 3);
    sites.lists['a0'] = _chapters('a0', 4);
    final index = withSeriesToFind();
    // A place saved after the index was last written: taken in, it would be
    // written a moment on.
    File('${store.bookDir(a)}/cursor.json').writeAsStringSync(jsonEncode({
      'cursor': const ReadingCursor(sectionIndex: 2).toJson(),
      'progress': 0.8,
      'at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
    }));
    final away = LibraryStore(tmp, readOnly: true)..placeWindow = const Duration(milliseconds: 20);
    expect((await Updates(away, background: true).checkAll()).found, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await store.webNovel(a))!.chapters, hasLength(4), reason: "the novel's own list is written as ever");
    expect(File('${tmp.path}/library.json').readAsStringSync(), index, reason: "the app's engine owns the index");
  });

  test("the check made with the app closed reads the library without writing its index", () async {
    await add('a', 'a0', 3);
    final index = withSeriesToFind();
    final internal = Directory('${tmp.path}/internal')..createSync();
    addTearDown(ListeningPrefs.reset);
    await runBackgroundCheck(libraryRoot: tmp.path, sourcesRoot: internal.path);
    expect(File('${tmp.path}/library.json').readAsStringSync(), index);
  });

  test('away from the app, the check stops before its next write once the app opens, keeping what it did', () async {
    final a = await add('a', 'a0', 3);
    final b = await add('b', 'b0', 3);
    sites.lists['a0'] = _chapters('a0', 4);
    sites.lists['b0'] = _chapters('b0', 4);
    // b0's site is slow; the app opens once a0 has been stored.
    sites.delays['b0'] = const Duration(milliseconds: 400);
    final updates = Updates(store, background: true, stopWhen: () async => (await store.webNovel(a))!.chapters.length == 4);
    final r = await updates.checkAll();
    expect(r.found, 1);
    final grown = [for (final id in [a, b]) (await store.webNovel(id))!.chapters.length];
    expect(grown..sort(), [3, 4], reason: 'one novel stored, the other left to the app');
    final log = await updates.log();
    expect(log.items, hasLength(1), reason: 'what was done is logged');
    expect((log.checked, log.attempted), (null, null), reason: "not a whole check: the app's own is still due");
    expect(await Updates(store).checkIfDue(UpdateEvery.daily), 1, reason: 'and finds the rest');
  });

  test('away from the app, sources whose sites need a browser check are skipped and said', () async {
    await add('a', 'a0', 3);
    sites.lists['a0'] = _chapters('a0', 4);
    File('${tmp.path}/sources/browser-hosts.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(['www.a.test']));
    final updates = Updates(store, background: true);
    final r = await updates.checkAll();
    expect((r.found, sites.asked), (0, 0));
    expect((await updates.log()).problems.single.kind, CheckProblemKind.challenge);
  });

  test("away from the app, one blog's browser check on a shared host does not skip another's source", () async {
    PluginInfo blog(String id, String site) =>
        PluginInfo(id: id, name: 'Blog $id', site: site, lang: 'English', version: '1', url: 'https://x/$id.js');
    final mine = blog('mine', 'https://mine.wordpress.com/'), theirs = blog('theirs', 'https://theirs.wordpress.com/');
    sites.attach(_Installed(tmp, [mine, theirs]));
    for (final p in [mine, theirs]) {
      await store.addWebNovel(p, SourceNovel(path: p.id, name: 'Novel ${p.id}', chapters: _chapters(p.id, 3)));
      sites.lists[p.id] = _chapters(p.id, 4);
    }
    File('${tmp.path}/sources/browser-hosts.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(['theirs.wordpress.com']));
    final updates = Updates(store, background: true);
    final r = await updates.checkAll();
    expect((r.found, sites.asked), (1, 1), reason: 'mine.wordpress.com is a site of its own');
    expect((await updates.log()).problems.single.pluginId, 'theirs');
  });

  test('the notification names novels, but not one on a secret shelf', () async {
    final open = await add('a', 'a0', 3);
    final hidden = await add('b', 'b0', 3);
    final shelf = await store.addCategory('Hidden', secret: true);
    await store.moveBooks({hidden}, shelf.id);
    await store.index(all: true);
    NewChapter c(String id, String title, int i) =>
        NewChapter(bookId: id, title: title, index: i, name: 'Chapter $i', foundAt: DateTime.now());
    final one = describeNewChapters(store, [c(hidden, 'Novel b0', 4), c(hidden, 'Novel b0', 5)]);
    expect((one['title'], one['text']), ('A novel', '2 new chapters'));
    final both = describeNewChapters(store, [c(open, 'Novel a0', 4), c(hidden, 'Novel b0', 4)]);
    expect((both['title'], both['text']), ('2 new chapters', 'Novel a0 and 1 more'));
    expect(both['lines'], ['Novel a0: a new chapter', 'A novel: a new chapter']);
    expect(jsonEncode(both), isNot(contains('b0')));
    // Open in the app (the worker asks the app's engine): still unnamed, as
    // the notification stays once the app is left and the shelf shuts.
    LibraryStore.secretOpen.value = true;
    expect(jsonEncode(describeNewChapters(store, [c(hidden, 'Novel b0', 4)])), isNot(contains('b0')));
  });
}
