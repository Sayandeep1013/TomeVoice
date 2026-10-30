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

  test('an unreadable library list is kept aside, not written over', () async {
    File('${tmp.path}/library.json').writeAsStringSync('{"books": [ {"id": "cut sho');
    // As the app finds it when it next starts.
    final fresh = LibraryStore(tmp);
    expect(await fresh.list(), isEmpty);
    expect(File('${tmp.path}/library.json.broken').readAsStringSync(), contains('cut sho'));
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
  });
}
