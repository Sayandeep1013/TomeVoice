// The library's files on the phone: changes made at the same moment both
// stay, and a damaged file is kept aside or rebuilt instead of costing the
// reader their shelf or a book.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;
  late String id;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tv_safety');
    store = LibraryStore(tmp);
    final copy = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/starter.epub');
    id = (await store.importFile(PickedFile(path: copy.path, name: 'Pride and Prejudice.epub'))).id;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a place saved while the book is moved keeps both', () async {
    final later = Category.defaults.last.id;
    await Future.wait([
      store.saveCursor(id, ReadingCursor.zero, 0.5),
      store.moveBooks({id}, later),
      store.forgetOpened('nobody'),
    ]);
    final e = (await store.list()).single;
    expect(e.progress, 0.5);
    expect(e.category, later);
  });

  test('a book another copy of the app added is not written over', () async {
    // Opened by a file manager, TomeVoice ran twice, each copy with the
    // index in memory: this one saving a place wrote out its list, without
    // the book the other had just imported.
    final other = LibraryStore(tmp);
    final text = File('${tmp.path}/incoming/s/other.txt')..createSync(recursive: true);
    text.writeAsStringSync('A book the other copy imported. It has a sentence or two.');
    final added = await other.importFile(PickedFile(path: text.path, name: 'other.txt'));
    await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.25);
    final onDisk = LibraryStore(tmp);
    expect([for (final e in await onDisk.list(all: true)) e.id], containsAll([id, added.id]));
    expect((await onDisk.list(all: true)).firstWhere((e) => e.id == id).progress, 0.25);
    // And this copy shows it too.
    expect((await store.list(all: true)).map((e) => e.id), contains(added.id));
  });

  test('an unreadable library list is kept aside, not written over', () async {
    File('${tmp.path}/library.json').writeAsStringSync('{"books": [ {"id": "cut sho');
    // As the app finds it when it next starts.
    final fresh = LibraryStore(tmp);
    expect(await fresh.list(), isEmpty);
    expect(File('${tmp.path}/library.json.broken').readAsStringSync(), contains('cut sho'));
  });

  test("the picker's copies go, imported or refused, each from its own folder", () async {
    PickedFile copyIn(String slot, String name, List<int> bytes) {
      final f = File('${tmp.path}/incoming/$slot/$name')..createSync(recursive: true);
      f.writeAsBytesSync(bytes);
      return PickedFile(path: f.path, name: name);
    }

    // Two picked at once with one name: both arrive, neither over the other.
    final a = await store.importFile(copyIn('s1', 'notes.txt', utf8.encode('The first book. It reads on for a while.')));
    final b = await store.importFile(copyIn('s2', 'notes.txt', utf8.encode('The second book. Another text entirely.')));
    expect(a.id, isNot(b.id));
    expect((await store.list(all: true)).map((e) => e.id), containsAll([a.id, b.id]));
    // Nothing to read: refused, and its copy goes too.
    await expectLater(store.importFile(copyIn('s3', 'empty.txt', const [])), throwsA(anything));
    expect(Directory('${tmp.path}/incoming').listSync(), isEmpty);
  });

  test('copies a crash left behind are swept after an hour; newer ones stay', () async {
    final stale = File('${tmp.path}/incoming/old.epub')..createSync(recursive: true);
    stale.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    final fresh = File('${tmp.path}/incoming/just-now/book.epub')..createSync(recursive: true);
    await store.sweepIncoming();
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('an entry of the wrong shape is passed over, not the whole shelf', () async {
    final index = File('${tmp.path}/library.json');
    final raw = Map<String, Object?>.from(jsonDecode(index.readAsStringSync()) as Map);
    final books = [...raw['books'] as List];
    // As a newer app, or a damaged restore, might have written it.
    books.add({'id': 'b${'0' * 15}', 'title': 'Odd', 'progress': 'half'});
    index.writeAsStringSync(jsonEncode({...raw, 'books': books}));
    final fresh = LibraryStore(tmp);
    expect([for (final e in await fresh.list(all: true)) e.id], [id]);
    // The odd one is still on the phone, in a copy the next save cannot touch.
    expect(File('${tmp.path}/library.json.broken').readAsStringSync(), contains('"Odd"'));
  });

  test('a book whose parsed copy was cut short opens from its own file', () async {
    File('${tmp.path}/books/$id/parsed.json').writeAsStringSync('{"v": 5, "book": {"id"');
    final layout = await store.loadLayout(id);
    expect(layout.units, isNotEmpty);
  });

  group('a web novel whose site list shifts', () {
    const plugin = PluginInfo(id: 'site', name: 'Site', site: 'https://site.test/', lang: 'English', version: '1', url: '');
    List<ChapterItem> listOf(List<String> names) => [for (final n in names) ChapterItem(name: n, path: n.toLowerCase())];
    // The site once listed an extra entry, X, before C; later it took it out.
    final before = listOf(['A', 'B', 'X', 'C', 'D']);
    final after = listOf(['A', 'B', 'C', 'D', 'E']);
    late String web;

    setUp(() async {
      await MarkStore.instance.attach(tmp);
      web = (await store.addWebNovel(plugin, SourceNovel(path: 'novel', name: 'Novel', chapters: before))).id;
      for (final i in [3, 4]) {
        await store.saveChapter(web, i, before[i].name, '<p>The words of ${before[i].name}.</p>');
      }
      await store.saveCursor(web, const ReadingCursor(sectionIndex: 3, blockIndex: 1), 0.6);
      await MarkStore.instance.add(
        bookId: web,
        bookTitle: 'Novel',
        kind: MarkKind.quote,
        at: const ReadingCursor(sectionIndex: 4),
        text: 'The words of D.',
      );
    });

    Future<void> expectFiledByChapter() async {
      final sections = (await store.loadLayout(web)).book.sections;
      expect(sections[2].title, 'C');
      expect(sections[2].blocks.map((b) => b.text), contains('The words of C.'));
      expect(sections[3].blocks.map((b) => b.text), contains('The words of D.'));
      expect(sections[4].blocks, isEmpty);
      expect(store.downloadedChapters(web), {2, 3});
      final cursor = await store.cursorFor(web);
      expect((cursor.sectionIndex, cursor.blockIndex), (2, 1));
      expect(MarkStore.instance.forBook(web).single.at.sectionIndex, 3);
    }

    test('downloads, the place and quotes move with their chapters', () async {
      await store.saveWebChapters(web, after);
      await expectFiledByChapter();
    });

    test('downloads an older build left in the wrong place are put back', () async {
      // As 1.0.2 left it: the new list stored, the downloads where they were.
      final file = File('${tmp.path}/books/$web/novel.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      json
        ..remove('filed')
        ..['chapters'] = [for (final c in after) c.toJson()];
      file.writeAsStringSync(jsonEncode(json));
      await store.settleWebChapters(web);
      await expectFiledByChapter();
    });

    test('a title the site has since corrected still finds its place, and keeps the next one', () async {
      // Shadow Slave: "Chapter 3115 Dark and Sinister" became "... Siniste"
      // in the list. Matched by its exact title only, it stayed put, and
      // the chapter moving onto its place was lost.
      final odd = listOf(['A', 'B', 'X', 'Chapter 3 Dark and Sinister', 'D']);
      final fixed = listOf(['A', 'B', 'Chapter 3 Dark and Siniste', 'D', 'E']);
      final other = (await store.addWebNovel(plugin, SourceNovel(path: 'other', name: 'Other', chapters: odd))).id;
      for (final i in [3, 4]) {
        await store.saveChapter(other, i, odd[i].name, '<p>The words of ${odd[i].name}.</p>');
      }
      final file = File('${tmp.path}/books/$other/novel.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      json
        ..remove('filed')
        ..['chapters'] = [for (final c in fixed) c.toJson()];
      file.writeAsStringSync(jsonEncode(json));
      await store.settleWebChapters(other);
      final sections = (await store.loadLayout(other)).book.sections;
      expect(sections[2].blocks.map((b) => b.text), contains('The words of Chapter 3 Dark and Sinister.'));
      expect(sections[3].blocks.map((b) => b.text), contains('The words of D.'));
      expect(store.downloadedChapters(other), {2, 3});
    });

    test('a list cut short by the site does not replace the stored one', () {
      expect(replacesChapterList(before, before), isFalse);
      expect(replacesChapterList(before, after), isTrue);
      expect(replacesChapterList(listOf([for (var i = 0; i < 100; i++) '$i']), listOf(['0', '1'])), isFalse);
    });

    test('a list is judged: same, taken, or refused with a reason', () {
      expect(judgeChapterList(before, before).change, ListChange.same);
      expect(judgeChapterList(before, after).change, ListChange.taken);
      expect(judgeChapterList(before, const []).why, contains('no chapters'));
      final partial = judgeChapterList(before, [...before, ...listOf(['F'])], complete: false);
      expect(partial.refused, isTrue);
      expect(partial.why, contains('incomplete'));
      final moved = judgeChapterList(before, [for (final c in before) ChapterItem(name: c.name, path: 'new/${c.path}')]);
      expect((moved.refused, moved.offered), (true, true));
      expect(moved.why, contains('5 of the 5'));
    });

    /// A novel of [names], its chapter i at [pathOf](i), with [downloaded]
    /// saved under their titles.
    Future<String> novelOf(String path, List<String> names, String Function(int i) pathOf, List<int> downloaded) async {
      final list = [for (var i = 0; i < names.length; i++) ChapterItem(name: names[i], path: pathOf(i))];
      final id = (await store.addWebNovel(plugin, SourceNovel(path: path, name: path, chapters: list))).id;
      for (final i in downloaded) {
        await store.saveChapter(id, i, names[i], '<p>The words of ${names[i]}.</p>');
      }
      return id;
    }

    Future<List<String>> texts(String id) async => [
          for (final s in (await store.loadLayout(id)).book.sections) s.blocks.map((b) => b.text).join(' '),
        ];

    test('a site that moved to another domain keeps every download, and its list is taken only when chosen', () async {
      final names = [for (var i = 1; i <= 6; i++) 'Chapter $i'];
      final id = await novelOf('moved', names, (i) => 'https://old.site/novel/ch-${i + 1}', [2, 3]);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 3), 0.5);
      final fresh = [for (var i = 0; i < 6; i++) ChapterItem(name: names[i], path: 'https://new.site/novel/ch-${i + 1}')];

      final verdict = await store.offerWebChapters(id, fresh);
      expect((verdict.refused, verdict.offered), (true, true));
      final kept = (await store.webNovel(id))!;
      expect(kept.chapters.first.path, 'https://old.site/novel/ch-1', reason: 'the stored list stays');
      expect(kept.refusal!.why, contains('new addresses'));
      expect(store.downloadedChapters(id), {2, 3});

      final chosen = await store.useOfferedChapters(id);
      expect(chosen.taken, isTrue);
      final now = (await store.webNovel(id))!;
      expect(now.chapters.first.path, 'https://new.site/novel/ch-1');
      expect(now.refusal, isNull);
      expect(store.downloadedChapters(id), {2, 3});
      expect((await texts(id))[3], contains('The words of Chapter 4.'));
      expect((await store.cursorFor(id)).sectionIndex, 3);
      expect(File('${tmp.path}/books/$id/offered.json').existsSync(), isFalse);
    });

    test('a plugin that writes its addresses another way: downloads find their chapters by title, shifted', () async {
      final names = [for (var i = 1; i <= 6; i++) 'Chapter $i'];
      final id = await novelOf('reformatted', names, (i) => 'chapter-${i + 1}', [1, 4]);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 4, blockIndex: 0), 0.7);
      await MarkStore.instance.add(
        bookId: id,
        bookTitle: 'Reformatted',
        kind: MarkKind.quote,
        at: const ReadingCursor(sectionIndex: 1),
        text: 'The words of Chapter 2.',
      );
      // The new plugin also lists a prologue first, and a new chapter.
      final fresh = [
        const ChapterItem(name: 'Prologue', path: 'c/0'),
        for (var i = 0; i < 6; i++) ChapterItem(name: names[i], path: 'c/${i + 1}'),
        const ChapterItem(name: 'Chapter 7', path: 'c/7'),
      ];
      expect((await store.offerWebChapters(id, fresh)).refused, isTrue, reason: 'every address changed');
      expect(store.downloadedChapters(id), {1, 4});

      expect((await store.useOfferedChapters(id)).taken, isTrue);
      expect(store.downloadedChapters(id), {2, 5});
      final t = await texts(id);
      expect(t[2], contains('The words of Chapter 2.'));
      expect(t[5], contains('The words of Chapter 5.'));
      expect((await store.cursorFor(id)).sectionIndex, 5);
      expect(MarkStore.instance.forBook(id).single.at.sectionIndex, 2);
      expect(Directory('${tmp.path}/books/$id/ch/orphaned').existsSync(), isFalse, reason: 'every download found its place');
    });

    test('a list cut short or not read to its end changes nothing; one taken anyway sets aside, never deletes', () async {
      final names = [for (var i = 1; i <= 100; i++) 'Chapter $i'];
      final id = await novelOf('long', names, (i) => 'ch/${i + 1}', [95, 96, 97, 98, 99]);
      final full = [for (var i = 0; i < 100; i++) ChapterItem(name: names[i], path: 'ch/${i + 1}')];

      final cut = await store.offerWebChapters(id, full.sublist(0, 50));
      expect((cut.refused, cut.offered), (true, false));
      expect(cut.why, contains('fewer than the 100'));
      final partial = await store.offerWebChapters(id, [...full, const ChapterItem(name: 'Chapter 101', path: 'ch/101')],
          complete: false);
      expect(partial.refused, isTrue);
      expect((await store.webNovel(id))!.chapters, hasLength(100));
      expect(store.downloadedChapters(id), {95, 96, 97, 98, 99});

      // The reader takes a list without the last three: their downloads are
      // kept aside, and come back when the site lists them again.
      await store.saveWebChapters(id, full.sublist(0, 97));
      expect(store.downloadedChapters(id), {95, 96});
      expect(Directory('${tmp.path}/books/$id/ch/orphaned').listSync(), hasLength(3));
      expect((await store.offerWebChapters(id, full)).taken, isTrue);
      expect(store.downloadedChapters(id), {95, 96, 97, 98, 99});
      expect((await texts(id))[99], contains('The words of Chapter 100.'));
      expect(Directory('${tmp.path}/books/$id/ch/orphaned').existsSync(), isFalse);
    });

    test('a novel of 3,000 chapters is opened a window at a time, not every chapter at once', () async {
      final names = [for (var i = 1; i <= 3000; i++) 'Chapter $i'];
      final id = await novelOf('huge', names, (i) => 'ch/$i', const []);
      final ch = Directory('${tmp.path}/books/$id/ch')..createSync(recursive: true);
      for (var i = 0; i < 3000; i++) {
        if (i == 1520) continue; // not on the phone: the window ends before it
        final s = webChapterSection(index: i, title: names[i], html: '<p>${names[i]} has words of its own to read.</p>');
        File('${ch.path}/$i.json').writeAsStringSync(jsonEncode(s.toJson()));
      }
      final sw = Stopwatch()..start();
      final window = await store.loadLayout(id, around: 1500);
      final windowTime = sw.elapsedMilliseconds;
      expect(window.book.sections, hasLength(3000), reason: 'every chapter keeps its place, and so every position');
      final read = window.units.map((u) => u.sectionIndex).toSet();
      expect((read.reduce((a, b) => a < b ? a : b), read.reduce((a, b) => a > b ? a : b)), (1490, 1519));
      expect(window.chapterTitle(0), 'Chapter 1491');
      sw
        ..reset()
        ..start();
      final whole = await store.loadLayout(id);
      final wholeTime = sw.elapsedMilliseconds;
      expect(whole.units.map((u) => u.sectionIndex).toSet(), hasLength(2999));
      // ignore: avoid_print
      print('A novel of 3,000 chapters opened in ${windowTime}ms as a window, ${wholeTime}ms whole.');
      expect(windowTime * 4, lessThan(wholeTime));
    });

    test('two downloads wanting one place: the other is set aside, not deleted', () async {
      // An older build left chapter 3's text under both 2 and 3.
      final names = ['A', 'B', 'C', 'D'];
      final id = await novelOf('twice', names, (i) => names[i].toLowerCase(), [2]);
      File('${tmp.path}/books/$id/ch/2.json').copySync('${tmp.path}/books/$id/ch/3.json');
      final file = File('${tmp.path}/books/$id/novel.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>..remove('filed');
      file.writeAsStringSync(jsonEncode(json));
      await store.settleWebChapters(id);
      expect(store.downloadedChapters(id), {2});
      expect(Directory('${tmp.path}/books/$id/ch/orphaned').listSync(), hasLength(1));
    });
  });
}
