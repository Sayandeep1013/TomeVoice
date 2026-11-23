// What the library keeps in memory instead of reading again: a web novel's
// chapter list and the last books laid out. Each is read afresh as soon as
// what it came from changes, by the store or by anything else.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/speech_service.dart' show PickedFile;

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_caches');
    store = LibraryStore(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  const plugin = PluginInfo(id: 'site', name: 'Site', site: 'https://site.test/', lang: 'English', version: '1', url: '');
  List<ChapterItem> listOf(int n) => [for (var i = 1; i <= n; i++) ChapterItem(name: 'Chapter $i', path: 'ch/$i')];

  group("a web novel's chapter list", () {
    test('is decoded once while its file is unchanged', () async {
      final id = (await store.addWebNovel(plugin, SourceNovel(path: 'n', name: 'N', chapters: listOf(5)))).id;
      final a = await store.webNovel(id);
      final b = await store.webNovel(id);
      expect(a, isNotNull);
      expect(identical(a, b), isTrue);
    });

    test("is read again after the store's own write", () async {
      final id = (await store.addWebNovel(plugin, SourceNovel(path: 'n', name: 'N', chapters: listOf(5)))).id;
      expect((await store.webNovel(id))!.chapters, hasLength(5));
      await store.saveWebChapters(id, listOf(7));
      expect((await store.webNovel(id))!.chapters, hasLength(7));
    });

    test('is read again after a write from elsewhere (the engine that checks away from the app)', () async {
      final id = (await store.addWebNovel(plugin, SourceNovel(path: 'n', name: 'N', chapters: listOf(5)))).id;
      final info = (await store.webNovel(id))!;
      final away = LibraryStore(tmp, readOnly: true);
      expect(await away.appendWebChapters(id, info, listOf(9)), isTrue);
      expect((await store.webNovel(id))!.chapters, hasLength(9));
    });

    test('is gone with its file', () async {
      final id = (await store.addWebNovel(plugin, SourceNovel(path: 'n', name: 'N', chapters: listOf(5)))).id;
      expect(await store.webNovel(id), isNotNull);
      File('${tmp.path}/books/$id/novel.json').deleteSync();
      expect(await store.webNovel(id), isNull);
    });

    test('a long one is decoded away from the UI, the same', () async {
      final id = (await store.addWebNovel(plugin, SourceNovel(path: 'long', name: 'Long', chapters: listOf(3000)))).id;
      expect(File('${tmp.path}/books/$id/novel.json').lengthSync(), greaterThan(64 * 1024));
      final info = (await store.webNovel(id))!;
      expect(info.chapters, hasLength(3000));
      expect(info.chapters.last.name, 'Chapter 3000');
    });
  });

  group('the last books laid out', () {
    late String id;

    setUp(() async {
      final text = File('${tmp.path}/incoming/s/book.txt')..createSync(recursive: true);
      text.writeAsStringSync([
        for (var c = 1; c <= 3; c++) 'Chapter $c\n\n${List.filled(30, 'A sentence of chapter $c goes on.').join(' ')}',
      ].join('\n\n'));
      id = (await store.importFile(PickedFile(path: text.path, name: 'book.txt'))).id;
    });

    test('are not parsed again when opened again', () async {
      final a = await store.loadLayout(id);
      final b = await store.loadLayout(id);
      expect(identical(a, b), isTrue);
    });

    test('are made again when the book is cut into other chapters', () async {
      final a = await store.loadLayout(id);
      final after = await store.setTextChapters(id, const TextChapters.words(200));
      expect(identical(a, after), isFalse);
      expect(identical(await store.loadLayout(id), a), isFalse);
    });

    test('are made again when the parsed book changed on disk', () async {
      final a = await store.loadLayout(id);
      final parsed = File('${tmp.path}/books/$id/parsed.json');
      // As a restore or another copy of the app would leave it.
      parsed.writeAsStringSync('${parsed.readAsStringSync()} ');
      expect(identical(await store.loadLayout(id), a), isFalse);
    });

    test('are forgotten when the book is removed', () async {
      await store.loadLayout(id);
      await store.remove(id);
      await expectLater(store.loadLayout(id), throwsA(anything));
    });
  });

  test('Find a passage in a web novel searches its chapter files a few at a time, and finds each place', () async {
    final names = [for (var i = 1; i <= 90; i++) 'Chapter $i'];
    final id = (await store.addWebNovel(plugin, SourceNovel(path: 'big', name: 'Big', chapters: listOf(90)))).id;
    for (var i = 0; i < 90; i++) {
      final words = i == 3 || i == 85 ? 'The lantern was lit at last.' : 'Nothing much happened here.';
      await store.saveChapter(id, i, names[i], '<p>${names[i]} begins. $words</p>');
    }
    final r = await store.findInWebNovel(id, 'lantern');
    expect((r.searched, r.all), (90, 90));
    expect([for (final p in r.found) p.chapter], [3, 85]);
    expect(r.found.last.title, 'Chapter 86');
    expect(r.found.last.at.sectionIndex, 85);
    final p = r.found.first;
    expect(p.text.substring(p.start, p.end).toLowerCase(), 'lantern');
    // The place opens on the sentence: the same one a whole layout has.
    final whole = await store.loadLayout(id);
    final unit = whole.unitForCursor(p.at);
    expect(whole.units[unit].text, contains('lantern'));
    expect((await store.findInWebNovel(id, 'lanterns', wholeWords: true)).found, isEmpty);
    // Only the chapters on the phone.
    final some = (await store.addWebNovel(plugin, SourceNovel(path: 'some', name: 'Some', chapters: listOf(10)))).id;
    await store.saveChapter(some, 2, 'Chapter 3', '<p>A lantern again.</p>');
    final s = await store.findInWebNovel(some, 'lantern');
    expect((s.searched, s.all, s.found.length), (1, 10, 1));
    expect(s.found.single.chapter, 2);
  });
}
