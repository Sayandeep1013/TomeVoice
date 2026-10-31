// Moving a web novel to another source: how its chapters are matched to the
// other site's list (by number and title, in order), and what goes with it
// (the place, downloads, quotes and bookmarks, read marks, its settings,
// its shelf, chapters waiting to download).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/download_queue.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/novel_move.dart';
import 'package:tomevoice_spike/novel_move_screen.dart';
import 'package:tomevoice_spike/novel_screen.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/read_marks.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';

List<ChapterItem> _list(List<String> names, {String site = 'a'}) =>
    [for (var i = 0; i < names.length; i++) ChapterItem(name: names[i], path: '$site/$i')];

Map<int, int> _match(List<String> from, List<String> to) => matchChapters(_list(from), _list(to, site: 'b')).to;

PluginInfo _plugin(String id) =>
    PluginInfo(id: id, name: 'Site $id', site: 'https://$id.test/', lang: 'English', version: '1', url: 'https://x/$id.js');

/// Sites as the tests make them up: [novels] by path, each found by a
/// search at every site.
class _Sites extends SourceEngine {
  _Sites() : super.forTests();

  final novels = <String, SourceNovel>{};

  /// A chapter that comes once this is done; the chapters asked for.
  final gates = <String, Future<void>>{};
  final asked = <String>[];

  @override
  Future<String> chapter(PluginInfo p, String path) async {
    asked.add(path);
    final gate = gates[path];
    if (gate != null) await gate;
    return '<p>The words of $path, enough to read.</p>';
  }

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async => novels[path] ?? (throw StateError('no $path'));

  @override
  Future<List<NovelItem>> search(PluginInfo p, String query, int page) async =>
      [NovelItem(name: '$query at ${p.name}', path: 'shadow-${p.id}')];
}

class _Installed extends SourceStore {
  _Installed(super.root, this.plugins) : super(defaults: const []);

  final List<PluginInfo> plugins;

  @override
  Future<List<PluginInfo>> installed() async => plugins;

  @override
  Future<PluginInfo?> installedById(String id) async => plugins.where((p) => p.id == id).firstOrNull;
}

void main() {
  group('a chapter\'s number, as its title gives it', () {
    test('after a word for chapter, at the start, or in Chinese', () {
      expect(chapterNumberOf('Chapter 12: The Fool'), 12);
      expect(chapterNumberOf('Ch. 12.5 - Interlude'), 12.5);
      expect(chapterNumberOf('c12'), 12);
      expect(chapterNumberOf('Episode 3'), 3);
      expect(chapterNumberOf('044. A Show of Trust'), 44);
      expect(chapterNumberOf('Chapter 1,234'), 1234);
      expect(chapterNumberOf('第12章 黎明'), 12);
    });

    test("a volume's, part's or title's number is not the chapter's", () {
      expect(chapterNumberOf('Volume 2 Chapter 4'), 4);
      expect(chapterNumberOf('Vol. 3 - 7: Rain'), 7);
      expect(chapterNumberOf('Chapter 9 Part 2'), 9);
      expect(chapterNumberOf('The 100 Doors'), isNull);
      expect(chapterNumberOf('Prologue'), isNull);
    });
  });

  group('matching one site\'s chapters to another\'s', () {
    test('the same chapters, each site naming them its own way', () {
      expect(
        _match(['Chapter 1: Dawn', 'Chapter 2: Dusk', 'Chapter 3: Night'], ['1. Dawn', 'Ch 2 - Dusk', 'Chapter 003 Night']),
        {0: 0, 1: 1, 2: 2},
      );
    });

    test('an announcement and a prologue the other site lists first', () {
      expect(_match(['Chapter 1', 'Chapter 2', 'Chapter 3'], ['Announcement', 'Prologue', 'Chapter 1', 'Chapter 2', 'Chapter 3']),
          {0: 2, 1: 3, 2: 4});
      expect(_match(['Prologue', 'Chapter 1', 'Chapter 2'], ['Notice', 'Prologue', 'Chapter 1', 'Chapter 2']), {0: 1, 1: 2, 2: 3});
    });

    test('half chapters keep their own place', () {
      expect(_match(['Chapter 12', 'Chapter 12.5', 'Chapter 13'], ['Ch. 12', 'Ch. 12.5', 'Ch. 13']), {0: 0, 1: 1, 2: 2});
    });

    test('volumes that start at 1 again on both sites', () {
      final old = [for (var v = 1; v <= 2; v++) for (var c = 1; c <= 3; c++) 'Volume $v Chapter $c'];
      final there = [for (var v = 1; v <= 2; v++) for (var c = 1; c <= 3; c++) 'Vol. $v Ch. $c'];
      expect(_match(old, there), {for (var i = 0; i < 6; i++) i: i});
    });

    test('a site that numbers on through the volumes: the first volume, never the second, by its numbers', () {
      final old = [for (var v = 1; v <= 2; v++) for (var c = 1; c <= 3; c++) 'Volume $v Chapter $c'];
      final there = [for (var c = 1; c <= 6; c++) 'Chapter $c'];
      final m = matchChapters(_list(old), _list(there, site: 'b'));
      expect({for (final e in m.to.entries) if (e.key < 3) e.key: e.value}, {0: 0, 1: 1, 2: 2});
      expect(m.to.keys.where((i) => i >= 3), isEmpty, reason: 'not taken for chapters 1 to 3 again');
      // The place in the second volume still finds its chapter, by where it falls.
      expect(m.follow(4), 4);
    });

    test('a number among the title\'s words is not a chapter\'s; the title finds it', () {
      final old = ['Chapter 20', 'Chapter 21', 'The 100 Doors', 'Chapter 23'];
      final there = ['Chapter 20', 'Chapter 21', 'Chapter 22: The 100 Doors', 'Chapter 23', for (var c = 24; c <= 100; c++) 'Chapter $c'];
      expect(_match(old, there), {0: 0, 1: 1, 2: 2, 3: 3});
    });

    test('titles with no numbers, found by their words', () {
      expect(
        _match(['Prologue', 'The Long Night', 'A Quiet Morning', 'Epilogue'],
            ['Prologue', 'Side Story: Rain', 'The Long Night', 'A Quiet Morning (revised)', 'Epilogue']),
        {0: 0, 1: 2, 2: 3, 3: 4},
      );
    });

    test('two translations, each titling a chapter its own way, between chapters both number', () {
      expect(
        _match(['1. Dawn', 'The Encounter', 'An Old Friend', '4. Night'], ['Chapter 1: Daybreak', 'Meeting', 'Old Acquaintance', 'Chapter 4: Evening']),
        {0: 0, 1: 1, 2: 2, 3: 3},
      );
    });

    test("at the lists' ends, a side story is not the other site's newest chapter", () {
      expect(_match(['Chapter 1', 'Chapter 2', 'Side Story: Rain'], ['Chapter 1', 'Chapter 2', 'Chapter 3']), {0: 0, 1: 1});
    });

    test('chapters the other site lacks are not matched; a place there goes where it would be', () {
      final m = matchChapters(
        _list(['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4', 'Chapter 5']),
        _list(['Chapter 1', 'Chapter 2', 'Chapter 4', 'Chapter 5'], site: 'b'),
      );
      expect(m.to, {0: 0, 1: 1, 3: 2, 4: 3});
      expect(m.follow(2), 2, reason: 'after chapter 2 there');
      expect(m.follow(0), 0);
      expect(m.matched, 4);
    });

    test('no place is given twice, and nothing matched sends a place to the same number', () {
      final m = matchChapters(_list(['Chapter 1', 'Chapter 1', 'Chapter 2']), _list(['Chapter 1', 'Chapter 2'], site: 'b'));
      expect(m.to.values.toSet().length, m.to.length);
      final none = matchChapters(_list(['Alpha', 'Beta', 'Gamma']), _list(['One', 'Two'], site: 'b'));
      expect(none.to, isEmpty);
      expect(none.follow(1), 1);
      expect(none.follow(2), 1, reason: 'within the other list');
    });
  });

  group('moving a novel', () {
    late Directory tmp;
    late LibraryStore store;
    late SourceEngine before;
    late DownloadQueue queue;
    final a = _plugin('a'), b = _plugin('b');

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tv_move');
      store = LibraryStore(tmp);
      ReadMarkStore.instance.reset();
      ListeningPrefs.reset();
      before = SourceEngine.instance;
      final sites = _Sites()..attach(_Installed(tmp, [a, b]));
      SourceEngine.instance = sites;
      await MarkStore.instance.attach(tmp);
      queue = DownloadQueue.forTests(pace: Duration.zero);
      await queue.attach(store);
      await queue.pause();
    });

    tearDown(() async {
      await queue.whenIdle();
      SourceEngine.instance = before;
      MarkStore.instance.reset();
      LibraryStore.secretOpen.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    /// A novel at site a: chapters 1 to [n], the first [downloaded] on the
    /// phone, read up to chapter [at] (its third sentence).
    Future<LibraryEntry> stored(int n, {int downloaded = 0, int at = -1}) async {
      final e = await store.addWebNovel(
          a, SourceNovel(path: 'novel', name: 'Shadow', chapters: [for (var i = 1; i <= n; i++) ChapterItem(name: 'Chapter $i', path: 'a/$i')]));
      for (var i = 0; i < downloaded; i++) {
        await store.saveChapter(e.id, i, 'Chapter ${i + 1}', '<p>Chapter ${i + 1} as site a has it.</p>');
      }
      if (at >= 0) await store.saveCursor(e.id, ReadingCursor(sectionIndex: at, blockIndex: 0, sentenceIndex: 2), (at + 0.5) / n);
      return (await store.list(all: true)).firstWhere((x) => x.id == e.id);
    }

    /// The same novel at site b, with a prologue first: every chapter one on.
    SourceNovel atB(int n) => SourceNovel(
          path: 'shadow-b',
          name: 'Shadow (B)',
          author: 'Writer',
          chapters: [
            const ChapterItem(name: 'Prologue', path: 'b/prologue'),
            for (var i = 1; i <= n; i++) ChapterItem(name: 'Ch. $i', path: 'b/$i'),
          ],
        );

    test('the place, downloads, quotes, read marks and settings go to the same chapters there', () async {
      final e = await stored(5, downloaded: 3, at: 2);
      final from = e.id;
      await MarkStore.instance.add(
          bookId: from, bookTitle: 'Shadow', kind: MarkKind.quote, at: const ReadingCursor(sectionIndex: 1), text: 'A line.');
      await ReadMarkStore.instance.mark(store, from, ['a/4'], read: true);
      final prefs = ListeningPrefs.memory
        ..voiceByBook[from] = 'voice-x'
        ..speedByBook[from] = 1.4;
      await queue.add(from, [const ChapterItem(name: 'Chapter 5', path: 'a/5')]);

      final plan = await planMove(store, e, b, atB(5));
      expect((plan.downloads, plan.carried, plan.marks, plan.readMarks, plan.place, plan.placeThere), (3, 3, 1, 1, 2, 3));
      expect(moveSummary(plan), contains('chapter 3, is chapter 4 there'));
      final moved = await moveNovel(store, e, plan, queue: queue);

      final to = LibraryStore.webId('b', 'shadow-b');
      expect(moved.id, to);
      final shelf = await store.list(all: true);
      expect(shelf.map((x) => x.id), [to], reason: 'one entry, swapped');
      expect((moved.plugin, moved.title, moved.chapterCount, moved.addedAt), ('b', 'Shadow (B)', 6, e.addedAt));
      expect(moved.cursor.sectionIndex, 3);
      expect(moved.cursor.sentenceIndex, 2, reason: 'its text came along, so the sentence holds');
      final cursor = jsonDecode(File('${store.bookDir(to)}/cursor.json').readAsStringSync()) as Map;
      expect((cursor['cursor'] as Map)['sectionIndex'], 3);

      // Each download under its chapter there, the prologue's place left free.
      expect(store.downloadedChapters(to), {1, 2, 3});
      final ch2 = jsonDecode(File('${store.bookDir(to)}/ch/2.json').readAsStringSync()) as Map;
      expect(ch2['title'], 'Chapter 2');
      expect(Directory(store.bookDir(from)).existsSync(), isFalse, reason: 'the old folder goes');

      final quote = MarkStore.instance.all.single;
      expect((quote.bookId, quote.at.sectionIndex, quote.text), (to, 2, 'A line.'));
      expect((await ReadMarkStore.instance.of(store, to)).read, {'b/4'});
      expect((prefs.voiceByBook[to], prefs.speedByBook[to], prefs.voiceByBook.containsKey(from)), ('voice-x', 1.4, false));
      expect(queue.waitingPaths(to), {'b/5'}, reason: 'what was waiting waits there');
      expect(queue.waitingPaths(from), isEmpty);
    });

    test('a download whose chapter is not there is kept aside, never deleted', () async {
      final e = await stored(3, downloaded: 3);
      final there = SourceNovel(path: 'shadow-b', name: 'Shadow', chapters: _list(['Chapter 1', 'Chapter 3'], site: 'b'));
      final plan = await planMove(store, e, b, there);
      expect((plan.downloads, plan.carried), (3, 2));
      expect(moveSummary(plan), contains('the 1 that match none are kept aside'));
      final moved = await moveNovel(store, e, plan, queue: queue);
      expect(store.downloadedChapters(moved.id), {0, 1});
      final aside = Directory('${store.bookDir(moved.id)}/ch/orphaned').listSync();
      expect(aside, hasLength(1));
    });

    test('a novel on a secret shelf stays on it, hidden while it is shut', () async {
      final e = await stored(3, downloaded: 1, at: 0);
      final shelf = await store.addCategory('Hidden', secret: true);
      await store.moveBooks({e.id}, shelf.id);
      final entry = (await store.list(all: true)).firstWhere((x) => x.id == e.id);
      final moved = await moveNovel(store, entry, await planMove(store, entry, b, atB(3)), queue: queue);
      expect(moved.category, shelf.id);
      expect(store.isSecret(moved.id), isTrue);
      LibraryStore.secretOpen.value = false;
      expect(await store.list(), isEmpty);
    });

    testWidgets('found at another source from its page, picked and moved: the page is then the novel there',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      const tts = MethodChannel('tomevoice/tts');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(tts, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(tts, null));
      Future<void> settle(bool Function() until) async {
        for (var i = 0; i < 80 && !until(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 400));
      }

      final e = (await tester.runAsync(() => stored(2, downloaded: 1, at: 1)))!;
      (SourceEngine.instance as _Sites).novels['shadow-b'] = atB(2);
      await tester.pumpWidget(MaterialApp(home: NovelScreen(store: store, plugin: a, path: 'novel', name: 'Shadow')));
      await settle(() => find.text('Chapter 2').evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('Novel options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to another source'));
      await settle(() => find.text('Shadow at Site b').evaluate().isNotEmpty);
      expect(find.text('Shadow at Site a'), findsNothing, reason: 'not the source it is at');
      await tester.tap(find.text('Shadow at Site b'));
      await settle(() => find.text('Move to Site b?').evaluate().isNotEmpty);
      expect(find.textContaining('Your place, chapter 2, is chapter 3 there.'), findsOneWidget);
      await tester.tap(find.text('Move'));
      await settle(() => find.text('Ch. 2').evaluate().isNotEmpty);
      // The old page's way out.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Prologue'), findsOneWidget, reason: "the novel's page there");
      expect(find.text('Chapter 1'), findsNothing);
      final shelf = (await tester.runAsync(() => store.list(all: true)))!;
      expect(shelf.single.id, LibraryStore.webId('b', 'shadow-b'));
      expect(shelf.single.addedAt, e.addedAt);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    test('a move that stops part way puts every download back, and what waited to download waits again', () async {
      final e = await stored(5, downloaded: 3, at: 2);
      await queue.add(e.id, [const ChapterItem(name: 'Chapter 5', path: 'a/5')]);
      final plan = await planMove(store, e, b, atB(5));
      final to = LibraryStore.webId('b', 'shadow-b');
      // Something in the way of a file the move writes there, after the
      // downloads have gone over (as a disk that fails part way).
      final inTheWay = Directory('${store.bookDir(to)}/cursor.json')..createSync(recursive: true);
      await expectLater(moveNovel(store, e, plan, queue: queue), throwsA(isA<FileSystemException>()));

      expect((await store.list(all: true)).single.id, e.id, reason: 'still the novel it was');
      expect(store.downloadedChapters(e.id), {0, 1, 2}, reason: 'its downloads back where they were');
      expect(jsonDecode(File('${store.bookDir(e.id)}/ch/1.json').readAsStringSync())['title'], 'Chapter 2');
      expect(queue.waitingPaths(e.id), {'a/5'});
      expect(File('${store.bookDir(e.id)}/moving.json').existsSync(), isFalse);
      expect(Directory(store.bookDir(to)).existsSync(), isTrue, reason: 'a folder there before is never taken away');

      // Tried again, it moves.
      inTheWay.deleteSync();
      final moved = await moveNovel(store, (await store.list(all: true)).single, plan, queue: queue);
      expect(store.downloadedChapters(moved.id), {1, 2, 3});
      expect(queue.waitingPaths(moved.id), {'b/5'});
    });

    test('a move the app closed in the middle of is put back as the novel next opens; nothing is deleted', () async {
      final e = await stored(4, downloaded: 2);
      final to = LibraryStore.webId('b', 'shadow-b');
      final old = store.bookDir(e.id), there = store.bookDir(to);
      // As a move leaves it when the app closes part way: every file noted,
      // two moved, the library not changed yet.
      Directory('$there/ch').createSync(recursive: true);
      await store.noteMove(e.id, to, [('ch/0.json', 'ch/1.json'), ('ch/1.json', 'ch/2.json'), ('ch/3.json', 'ch/4.json')]);
      File('$old/ch/0.json').renameSync('$there/ch/1.json');
      File('$old/ch/1.json').renameSync('$there/ch/2.json');

      // The app again, before the novel opens: chapter 1 read (and fetched)
      // once more meanwhile.
      final app = LibraryStore(tmp);
      await app.saveChapter(e.id, 0, 'Chapter 1', '<p>Chapter 1 again, fetched while its first copy was away.</p>');
      await app.settleWebChapters(e.id);
      expect(app.downloadedChapters(e.id), {0, 1});
      expect(jsonDecode(File('$old/ch/1.json').readAsStringSync())['title'], 'Chapter 2');
      expect(Directory('$old/ch/orphaned').listSync(), hasLength(1), reason: 'the copy that was away, kept aside');
      expect(Directory(there).existsSync(), isFalse, reason: 'the half-made folder goes, nothing of the novel in it');
      expect(File('$old/moving.json').existsSync(), isFalse);
    });

    test("a folder an older build's stopped move left there is kept: its downloads may be the only copies", () async {
      final e = await stored(5, downloaded: 2);
      final to = LibraryStore.webId('b', 'shadow-b');
      // Chapter 3's download, moved there by a build before 1.4 that then stopped.
      Directory('${store.bookDir(to)}/ch').createSync(recursive: true);
      File('${store.bookDir(to)}/ch/3.json').writeAsStringSync(jsonEncode({'title': 'Chapter 3', 'blocks': []}));
      final moved = await moveNovel(store, e, await planMove(store, e, b, atB(5)), queue: queue);
      expect(store.downloadedChapters(moved.id), {1, 2, 3});
    });

    test('a chapter on its way down as the novel moves is not waited for, and never lands in the old folder', () async {
      final e = await stored(3, downloaded: 1);
      final sites = SourceEngine.instance as _Sites;
      final gate = Completer<void>();
      sites.gates['a/2'] = gate.future;
      await queue.resume();
      await queue.add(e.id, [const ChapterItem(name: 'Chapter 2', path: 'a/2')]);
      for (var i = 0; i < 100 && !sites.asked.contains('a/2'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final moved = await moveNovel(store, e, await planMove(store, e, b, atB(3)), queue: queue);
      // It comes once the novel has moved: nothing is written for the old one.
      gate.complete();
      for (var i = 0; i < 100 && !store.hasChapter(moved.id, 2); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await queue.whenIdle();
      expect(Directory(store.bookDir(e.id)).existsSync(), isFalse, reason: 'not made again');
      expect(store.downloadedChapters(moved.id), {1, 2}, reason: 'it came down again there');
    });

    test('refused: one already in the library, or a list that did not come in whole', () async {
      final e = await stored(3);
      await store.addWebNovel(b, atB(3));
      await expectLater(planMove(store, e, b, atB(3)), throwsA(isA<MoveRefused>()));
      final partial = SourceNovel(path: 'other', name: 'Shadow', chapters: atB(3).chapters, complete: false);
      await expectLater(planMove(store, e, b, partial), throwsA(isA<MoveRefused>()));
      expect((await store.list(all: true)).map((x) => x.id), contains(e.id), reason: 'nothing moved');
    });
  });
}
