// Series memory: books whose memories are read together, in their order;
// each keeps its own memory, and the series read as one (All books) is made
// from them: chapters one after another, a person met in several books one
// entry.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/series_db.dart';
import 'package:tomevoice_spike/ai/memory/series_store.dart';

/// A memory of [texts] chapters at [path]: Sunny in each, and [other] met
/// in its first chapter.
String _memory(String path, List<String> texts, String other) {
  final m = MemoryDb.open(path);
  final g = BookGraph(m);
  for (var ch = 0; ch < texts.length; ch++) {
    m.indexChapter(
      ch: ch,
      section: ch,
      title: 'Chapter ${ch + 1}',
      hash: 'h$ch',
      chunks: [TextChunk(start: MemoryPlace(chapter: ch, section: ch), text: texts[ch])],
    );
  }
  final made = <String, int>{};
  void note(int ch, ChapterNotes n) => g.apply(n, [MemoryPlace(chapter: ch, section: ch)], made);
  note(0, ChapterNotes(chapter: 0, summary: 'It begins.', entities: [
    const NoteEntity(ref: 'new:Sunny', kind: 'person', name: 'Sunny'),
    NoteEntity(ref: 'new:$other', kind: 'person', name: other),
  ], relations: [
    NoteRelation(a: 'Sunny', rel: 'ally of', b: 'new:$other', at: 1),
  ]));
  for (var ch = 1; ch < texts.length; ch++) {
    note(ch, ChapterNotes(chapter: ch, summary: 'Chapter ${ch + 1} goes on.', events: [
      NoteEvent(what: 'Sunny goes on in chapter ${ch + 1}', who: const ['Sunny'], importance: 3, at: 1),
    ]));
  }
  m.close();
  return path;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_series');
    SeriesStore.instance.reset();
  });

  tearDown(() {
    SeriesStore.instance.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  test('a book carries on from another: a series in order, kept, and undone without touching the books', () async {
    final store = SeriesStore.instance;
    await store.attach(tmp);
    final s = await store.carryOn('b2', earlier: 'b1', name: 'Shadow Slave');
    expect(s.books, ['b1', 'b2']);
    // After the last; then one slipped in after the first.
    await store.carryOn('b3', earlier: 'b2', name: 'x');
    await store.carryOn('b1a', earlier: 'b1', name: 'x');
    expect(store.ofBook('b3')!.books, ['b1', 'b1a', 'b2', 'b3']);
    expect(store.ofBook('b3')!.before('b2'), ['b1', 'b1a']);
    expect(store.all, hasLength(1));
    expect(store.ofBook('b1')!.name, 'Shadow Slave');

    // Kept beside the library, and read back.
    SeriesStore.instance.reset();
    await store.attach(tmp);
    expect(store.ofBook('b2')!.books, ['b1', 'b1a', 'b2', 'b3']);

    await store.rename(s.id, 'The Nightmare');
    await store.remove('b1a');
    expect(store.byId(s.id)!.books, ['b1', 'b2', 'b3']);
    expect(store.byId(s.id)!.name, 'The Nightmare');
    // A book gone from the library leaves its series.
    await store.keepOnly({'b1', 'b3'});
    expect(store.byId(s.id)!.books, ['b1', 'b3']);
    await store.dissolve(s.id);
    expect(store.all, isEmpty);
    expect(store.ofBook('b1'), isNull);
  });

  test('a series with one book left is a series no more', () async {
    final store = SeriesStore.instance;
    await store.attach(tmp);
    await store.carryOn('b2', earlier: 'b1', name: 'S');
    await store.remove('b2');
    expect(store.all, isEmpty);
  });

  test('the series read as one: each book after the one before, a person met in both one entry', () {
    final one = _memory('${tmp.path}/one.db', ['Sunny wakes.', 'Sunny walks.', 'Sunny fights.'], 'Cassie');
    final two = _memory('${tmp.path}/two.db', ['Sunny returns.', 'Sunny leads.'], 'Nephis');
    final out = '${tmp.path}/series.db';
    final starts = buildSeriesDb(out, [(path: one, title: 'Book One'), (path: two, title: 'Book Two')]);
    expect(starts, [0, 3]);

    final m = MemoryDb.open(out);
    addTearDown(m.close);
    // Five chapters, numbered on: Book 2's first is the series' fourth.
    final chapters = [for (final r in m.db.select('SELECT ch, title FROM chapters ORDER BY ch')) (r['ch'], r['title'])];
    expect(chapters.map((c) => c.$1), [0, 1, 2, 3, 4]);
    expect(chapters[3].$2, 'Book 2 · Chapter 1');
    // Sunny once; Cassie and Nephis each.
    final names = [for (final r in m.db.select('SELECT name FROM entities WHERE merged_into IS NULL ORDER BY name')) r['name']];
    expect(names, ['Cassie', 'Nephis', 'Sunny']);
    final sunny = m.db.select("SELECT id, first_ch, last_ch FROM entities WHERE name = 'Sunny'").single;
    // Seen from Book 1's first chapter to Book 2's last.
    final seen = [for (final r in m.db.select('SELECT ch FROM appearances WHERE entity = ? ORDER BY ch', [sunny['id']])) r['ch']];
    expect(seen.first, 0);
    expect(seen.last, 4);
    // Book 2's ties sit in Book 2's chapters.
    final nephis = m.db.select("SELECT r.from_ch FROM relations r JOIN entities e ON e.id = r.b WHERE e.name = 'Nephis'").single;
    expect(nephis['from_ch'], 3);

    // Made again only when a book changed: the same answer at once.
    expect(buildSeriesDb(out, [(path: one, title: 'Book One'), (path: two, title: 'Book Two')]), [0, 3]);
  });
}
