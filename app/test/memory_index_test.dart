// A book's memory, its first layer: the word index. Every word of every
// chapter findable, each find tagged with its chapter and sentence; kept to
// the reader's line when the spoiler guard is on; a chapter whose text
// changed indexed again (and its notes dropped), one that did not, left.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/word_index.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_memory');
    store = LibraryStore(tmp);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  Future<String> import(String name, String text) async {
    final f = File('${tmp.path}/incoming/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    return (await store.importFile(PickedFile(path: f.path, name: name))).id;
  }

  const tide = '# Chapter 1: Low\n\nThe tide went out past the weaver\'s hut. Gulls cried.\n\n'
      '# Chapter 2: High\n\nThe tide came in. The weaver mended her nets by the fire.\n\n'
      '# Chapter 3: Storm\n\nA storm broke over the bay. Nobody saw the weaver again.';

  test('every chapter in the index, each find with its chapter and sentence', () async {
    final id = await import('tide.md', tide);
    final indexer = WordIndexer(store);
    final steps = <int>[];
    expect(await indexer.index(id, onProgress: (p) => steps.add(p.done)), 3);
    expect(steps.last, 3);

    final db = MemoryDb.open(indexer.pathOf(id));
    addTearDown(db.close);
    expect(db.indexedSpan().count, 3);
    final hits = db.search('weaver', inOrder: true);
    expect(hits.map((h) => h.place.chapter), [0, 1, 2]);
    expect(hits.first.snippet, contains('«weaver'));
    // The start of a word finds it; quotes keep words together.
    expect(db.search('weav').length, 3);
    expect(db.search('"mended her nets"').single.place.chapter, 1);
    expect(db.search('nets fire').single.place.chapter, 1);
    // The guard: nothing past the line.
    expect(db.search('weaver', upTo: 1).map((h) => h.place.chapter).toSet(), {0, 1});
    expect(db.countByChapter('tide'), {0: 1, 1: 1});
    // Odd typing does not break it.
    expect(db.search('"'), isEmpty);
    expect(db.search('AND OR *'), isEmpty);
  });

  test('indexing again does nothing; a changed chapter is indexed again and loses its notes', () async {
    final id = await import('tide.md', tide);
    final indexer = WordIndexer(store);
    await indexer.index(id);
    expect(await indexer.index(id), 0);

    final db = MemoryDb.open(indexer.pathOf(id));
    db.db.execute("UPDATE chapters SET noted = 1 WHERE ch IN (0, 1)");
    db.close();

    final changed = tide.replaceFirst('Gulls cried.', 'Gulls cried and wheeled.');
    final layout = await store.loadLayout(id);
    // The same book, its first chapter's text changed.
    final chapters = [
      for (var c = 0; c < layout.chapters.length; c++) chapterForIndex(layout, c)!,
    ];
    final edited = IndexedChapter(
      chapter: 0,
      section: chapters[0].section,
      title: chapters[0].title,
      hash: 'changed',
      chunks: [TextChunk(start: chapters[0].chunks.first.start, text: changed.split('\n\n')[1])],
    );
    expect(writeIndex(indexer.pathOf(id), [edited, chapters[1], chapters[2]]), 1);
    final after = MemoryDb.open(indexer.pathOf(id));
    addTearDown(after.close);
    expect(after.search('wheeled').single.place.chapter, 0);
    final noted = {
      for (final r in after.db.select('SELECT ch, noted FROM chapters')) r['ch'] as int: r['noted'] as int,
    };
    expect(noted, {0: 0, 1: 1, 2: 0});
  });

  test("a web novel: the chapters on the phone, by their numbers; the rest join once downloaded", () async {
    const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
    final id = (await store.addWebNovel(
      plugin,
      SourceNovel(path: 'n', name: 'Novel', chapters: [
        for (var i = 0; i < 250; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'c$i'),
      ]),
    ))
        .id;
    Future<void> download(int i) => store.saveChapterAt(
        id, 'c$i', '<p>Part ${i + 1} of the story. ${i == 120 ? 'The Weaver smiled.' : 'Nothing much.'}</p>');

    for (var i = 0; i < 150; i++) {
      if (i != 40) await download(i);
    }
    final indexer = WordIndexer(store);
    expect(await indexer.index(id), 149);
    var db = MemoryDb.open(indexer.pathOf(id));
    expect(db.search('weaver').single.place.chapter, 120);
    expect(db.search('weaver').single.place.section, 120);
    expect(db.chapterText(40), isEmpty);
    db.close();

    await download(40);
    await download(200);
    expect(await indexer.index(id), 2);
    db = MemoryDb.open(indexer.pathOf(id));
    addTearDown(db.close);
    expect(db.indexedSpan(), (count: 151, last: 200));
    expect(db.chapterText(200).single.text, contains('Part 201'));
  });

  test("chunks keep to a few sentences, and say where each starts", () async {
    final long = List.generate(30, (i) => 'Sentence number $i is here.').join(' ');
    final id = await import('long.md', '# Chapter 1: One\n\n$long');
    final layout = await store.loadLayout(id);
    final ch = chapterForIndex(layout, 0)!;
    expect(ch.chunks.length, greaterThan(4));
    expect(ch.chunks.every((c) => c.units <= 5), isTrue);
    expect(ch.chunks.map((c) => c.units).reduce((a, b) => a + b), greaterThanOrEqualTo(30));
    final second = ch.chunks[1].start;
    expect(second.section, ch.section);
    expect(second.sentence > 0 || second.block > 0, isTrue);
  });

  test("a chapter's text read and replaced by a jump to its rows; a memory made before learns where they are", () {
    final dir = Directory.systemTemp.createTempSync('tv_rows');
    final path = '${dir.path}/memory.db';
    var m = MemoryDb.open(path);
    TextChunk chunk(int ch, String text) => TextChunk(start: MemoryPlace(chapter: ch, section: ch), text: text);
    for (var ch = 0; ch < 3; ch++) {
      m.indexChapter(ch: ch, section: ch, title: 'C$ch', hash: 'h$ch', chunks: [chunk(ch, 'First of $ch.'), chunk(ch, 'Then $ch.')]);
    }
    m.indexChapter(ch: 1, section: 1, title: 'C1', hash: 'h1b', chunks: [chunk(1, 'All new.')]);
    expect(m.chapterText(1).map((c) => c.text), ['All new.']);
    expect(m.chapterText(0).map((c) => c.text), ['First of 0.', 'Then 0.']);
    expect(m.chapterText(2).map((c) => c.text), ['First of 2.', 'Then 2.']);
    expect(m.db.select('SELECT chars FROM chapter_rows WHERE ch = 1').single['chars'], 'All new.'.length);
    // As a memory made before version 5 was: no record of where the rows are.
    m.db.execute('DROP TABLE chapter_rows');
    m.db.execute('PRAGMA user_version = 4');
    m.close();
    m = MemoryDb.open(path);
    expect(m.chapterText(2).map((c) => c.text), ['First of 2.', 'Then 2.']);
    expect(m.chapterText(1).map((c) => c.text), ['All new.']);
    m.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold the file.
    }
  });

  test('a fresh memory has the core kinds and the version', () {
    final db = MemoryDb.inMemory();
    addTearDown(db.close);
    final kinds = [for (final r in db.db.select('SELECT name FROM kinds ORDER BY name')) r['name']];
    expect(kinds, ['creature', 'faction', 'item', 'person', 'place', 'power', 'term', 'title']);
    expect(db.db.select('PRAGMA user_version').first.columnAt(0), MemoryDb.version);
    db.setMeta('guard', 'on');
    expect(db.meta('guard'), 'on');
    db.setMeta('guard', null);
    expect(db.meta('guard'), isNull);
  });
}
