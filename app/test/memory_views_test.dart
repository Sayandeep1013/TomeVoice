// Who's who and the memory graph: the book's entities by kind and name, as
// they stood at a chapter; the graph's relations as of that chapter, and
// the pairs who shared events; laid out the same each time, inside its
// square; the screens drawing them, a tap picking a node.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/graph3d_view.dart';
import 'package:tomevoice_spike/ai/memory/graph_screen.dart';
import 'package:tomevoice_spike/ai/memory/hand_off.dart';
import 'package:tomevoice_spike/ai/memory/ledger.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/ai/memory/series.dart';
import 'package:tomevoice_spike/ai/talk/answer_pack.dart';
import 'package:tomevoice_spike/ai/memory/whos_who_screen.dart';

/// Sunny meets Cassie (ch 1, allies), fights beside her twice (ch 2), they
/// part (ch 3); Nephis comes in chapter 3; the Forgotten Shore is where.
String _memory(Directory tmp) {
  final path = '${tmp.path}/memory.db';
  final m = MemoryDb.open(path);
  final g = BookGraph(m);
  for (var ch = 0; ch < 4; ch++) {
    m.indexChapter(ch: ch, section: ch, title: 'C$ch', hash: 'h$ch',
        chunks: [TextChunk(start: MemoryPlace(chapter: ch, section: ch), text: 'Chapter $ch.')]);
  }
  final made = <String, int>{};
  void note(ChapterNotes n) => g.apply(n, [MemoryPlace(chapter: n.chapter, section: n.chapter)], made);
  note(const ChapterNotes(chapter: 0, summary: 's', entities: [
    NoteEntity(ref: 'new:Sunless', kind: 'person', name: 'Sunless', aliases: ['Sunny'], about: 'A slum boy'),
    NoteEntity(ref: 'new:Forgotten Shore', kind: 'place', name: 'Forgotten Shore'),
  ]));
  note(const ChapterNotes(chapter: 1, summary: 's', entities: [
    NoteEntity(ref: 'new:Cassie', kind: 'person', name: 'Cassie'),
  ], relations: [
    NoteRelation(a: 'Sunny', rel: 'ally of', b: 'Cassie'),
  ]));
  note(const ChapterNotes(chapter: 2, summary: 's', events: [
    NoteEvent(what: 'They fight', who: ['Sunny', 'Cassie'], where: 'Forgotten Shore'),
    NoteEvent(what: 'They fight again', who: ['Sunny', 'Cassie']),
  ]));
  note(const ChapterNotes(chapter: 3, summary: 's', entities: [
    NoteEntity(ref: 'new:Nephis', kind: 'person', name: 'Nephis'),
  ], relations: [
    NoteRelation(a: 'Sunny', rel: 'ally of', b: 'Cassie', ends: true),
  ]));
  m.close();
  return path;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tv_views'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  test("who's who: by kind, by any name, as of a chapter, in the order asked", () {
    final path = _memory(tmp);
    expect(ledger(path).map((e) => e.name), ['Sunless', 'Cassie', 'Forgotten Shore', 'Nephis']);
    expect(ledger(path, at: 2).map((e) => e.name), isNot(contains('Nephis')));
    expect(ledger(path, kind: 'place').single.name, 'Forgotten Shore');
    expect(ledger(path, query: 'sun').single.name, 'Sunless');
    expect(ledger(path, order: LedgerOrder.name).map((e) => e.name).first, 'Cassie');
    expect(ledger(path, order: LedgerOrder.firstMet).last.name, 'Nephis');
    expect(ledger(path).first.mentions, 4);
    expect(ledgerKinds(path), [(kind: 'person', count: 3, core: true), (kind: 'place', count: 1, core: true)]);
  });

  test('the graph as of a chapter: a relation while it held, the events two shared', () {
    final path = _memory(tmp);
    final sunny = ledger(path, query: 'sunny').single.id;
    final cassie = ledger(path, query: 'cassie').single.id;
    // Every link keeps the chapters it held, so the timeline can show any
    // chapter without the nodes moving: allies from chapter 2, parted in 4.
    final ally = graphAt(path).edges.singleWhere((e) => {e.a, e.b}.containsAll({sunny, cassie}));
    expect((ally.label, ally.kind, ally.fromCh, ally.untilCh), ('ally of', LinkKind.bond, 1, 3));
    expect(ally.at(2), isTrue);
    expect(ally.at(3), isFalse, reason: 'they parted in chapter 4');
    // Up to chapter 3 it had not ended yet.
    expect(graphAt(path, at: 2).edges.where((e) => e.related).single.untilCh, isNull);
    expect(linkKindOf('sworn enemy of'), LinkKind.conflict);
    expect(linkKindOf('member of'), LinkKind.belongs);
    expect(linkKindOf('elder sister of'), LinkKind.family);
    expect(mainOf(path), sunny);
    expect(graphAt(path, at: 0).nodes.map((n) => n.name).toSet(), {'Sunless', 'Forgotten Shore'});
    expect(graphAt(path, kinds: {'place'}).nodes.single.name, 'Forgotten Shore');
    // Round one: Nephis knows nobody yet.
    final nephis = ledger(path, query: 'nephis').single.id;
    expect(graphAt(path, focus: nephis).nodes.single.name, 'Nephis');
    expect(graphAt(path, focus: sunny).nodes.length, 3);
  });

  test('the hand-off pack: the story, who matters as they stand, kept to the line', () {
    final path = _memory(tmp);
    final all = handOffMarkdown(path, title: 'Shadow Slave', author: 'Guiltythree', journal: const ['up to chapter 2: I like Cassie.']);
    expect(all, startsWith('# Shadow Slave — Guiltythree'));
    expect(all, contains('**Sunless** (person, from ch 1), also Sunny. A slum boy'));
    expect(all, contains('**Nephis**'));
    expect(all, contains("## The reader's journal"));
    final kept = handOffMarkdown(path, title: 'Shadow Slave', line: 1, here: 1);
    expect(kept, contains('please do not reveal anything after it'));
    expect(kept, isNot(contains('Nephis')));
    expect(kept, contains('Sunless ally of Cassie'));
  });

  test("a series: the next book's memory starts with the cast, how they stood, open threads and the story", () {
    final first = _memory(tmp);
    final m = MemoryDb.open(first);
    m.db.execute("INSERT INTO threads(title, norm, about, raised_ch, status) VALUES ('Who is the Weaver?', 'who is weaver', NULL, 0, 'open')");
    m.db.execute("INSERT INTO facts(entity, attr, value, from_ch) SELECT id, 'rank', 'Awakened', 3 FROM entities WHERE name = 'Sunless'");
    m.close();
    final second = '${tmp.path}/two/memory.db';
    MemoryDb.open(second).close();
    expect(followOn(second, first), 4);
    expect(ledger(second, query: 'sunny').single.firstCh, beforeThisBook);
    final pack = buildPack(PackInput(path: second, question: 'What rank is Sunny?', here: 0)).map((i) => i.text).join(' | ');
    expect(pack, contains('rank: Awakened'));
    expect(pack, contains('First met in an earlier book'));
    expect(pack, contains('"Who is the Weaver?" (raised an earlier book)'));
    expect(pack, contains('Before this book (the earlier books of the series): s s s s'));
    // Again: no one made twice.
    followOn(second, first);
    expect(ledger(second).length, 4);
  });

  test('kinds the AI suggests: listed, accepted for the Builder, or turned down', () {
    final path = _memory(tmp);
    final m = MemoryDb.open(path);
    m.db.execute("INSERT INTO kinds(name, about, core, accepted) VALUES ('aspect', 'A power', 0, 0), ('rune', 'A mark', 0, 0)");
    m.close();
    expect(proposedKinds(path).map((k) => k.name), ['aspect', 'rune']);
    decideKind(path, 'aspect', accept: true);
    decideKind(path, 'rune', accept: false);
    expect(proposedKinds(path), isEmpty);
    final after = MemoryDb.open(path);
    expect(after.db.select("SELECT accepted FROM kinds WHERE name = 'aspect'").single['accepted'], 1);
    expect(after.db.select("SELECT * FROM kinds WHERE name = 'rune'"), isEmpty);
    after.close();
  });

  test('a question asked before comes back: "at ch 4, they asked"', () {
    final path = _memory(tmp);
    noteAsked(path, 'Why did Cassie leave Sunny?', 3);
    noteAsked(path, 'What is the Forgotten Shore?', 1);
    final items = buildPack(PackInput(path: path, question: 'Tell me about Cassie again', here: 3))
        .where((i) => i.section == 'What the reader asked before')
        .map((i) => i.text);
    expect(items, ['At ch 4, they asked: "Why did Cassie leave Sunny?"']);
  });

  test('a series kept to how far the earlier book was read, brought over again cleanly, and searched by Talk', () {
    final first = '${tmp.path}/books/one/memory.db';
    Directory('${tmp.path}/books/one').createSync(recursive: true);
    File(_memory(tmp)).copySync(first);
    final second = '${tmp.path}/books/two/memory.db';
    Directory('${tmp.path}/books/two').createSync(recursive: true);
    MemoryDb.open(second).close();

    // Read to chapter 2 of the first book: Nephis (chapter 4) stays there,
    // and Sunny and Cassie are still allies.
    expect(followOnAll(second, [(path: first, upTo: 1)]), 3);
    expect(ledger(second).map((e) => e.name), isNot(contains('Nephis')));
    final kept = MemoryDb.open(second);
    expect(kept.db.select("SELECT count(*) n FROM relations WHERE rel = 'ally of'").first['n'], 1);
    kept.close();

    // All of it, brought over again: nobody twice, and the alliance that
    // ended by the first book's end gone.
    expect(followOnAll(second, [(path: first, upTo: null)]), 4);
    expect(ledger(second).length, 4);
    final all = MemoryDb.open(second);
    expect(all.db.select("SELECT count(*) n FROM relations WHERE rel = 'ally of'").first['n'], 0);
    all.setMeta('follows', 'one');
    all.setMeta('follows_titles', 'Book One');
    all.close();

    // Talk: the earlier book found, its cards and text cited by book.
    final books = earlierBooks(second);
    expect(books.single.title, 'Book One');
    expect(books.single.id, 'one');
    final pack = earlierPack('Who is Cassie?', books);
    expect(pack.map((i) => i.label), contains('Book One · ch 2'));
    expect(pack.first.section, 'From Book One, an earlier book');
    final found = searchEarlier('"Chapter 2"', books);
    expect(found.single.label, 'Book One · ch 3');
  });

  test('laid out the same each time, inside its square, no two nodes touching', () {
    final path = _memory(tmp);
    for (final g in [graphAt(path), graphAt(path, focus: ledger(path, query: 'sunny').single.id, depth: 2)]) {
      final a = layoutGraph(g), b = layoutGraph(g);
      expect(a.at, b.at);
      expect(a.size, greaterThanOrEqualTo(1000));
      for (final p in a.at.values) {
        expect(p.x, inInclusiveRange(0, a.size));
        expect(p.y, inInclusiveRange(0, a.size));
      }
      final nodes = g.nodes;
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          final p = a.at[nodes[i].id]!, q = a.at[nodes[j].id]!;
          final d = math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2));
          expect(d, greaterThan((spaceDp(nodes[i].weight) + spaceDp(nodes[j].weight)) * canvasPerDp),
              reason: '${nodes[i].name} and ${nodes[j].name} overlap');
        }
      }
      // Round someone: they are in the middle.
      if (g.focus != null) expect(a.at[g.focus]!, (x: a.size / 2, y: a.size / 2));
    }
  });

  test('as a ball: the same each time, the person at the middle, those linked nearer than the rest', () {
    final path = _memory(tmp);
    final sunny = ledger(path, query: 'sunny').single.id;
    final g = graphAt(path, focus: sunny, depth: 2);
    final a = layoutGraph3d(g), b = layoutGraph3d(g);
    expect(a, b);
    expect(a[sunny], (x: 0.0, y: 0.0, z: 0.0));
    double dist(int id) => math.sqrt(math.pow(a[id]!.x, 2) + math.pow(a[id]!.y, 2) + math.pow(a[id]!.z, 2));
    final cassie = ledger(path, query: 'cassie').single.id;
    for (final n in g.nodes.where((n) => n.id != sunny)) {
      expect(dist(n.id), greaterThan(100), reason: '${n.name} sits on Sunny');
    }
    expect(dist(cassie), greaterThan(0));
  });

  test('a crowd of a hundred, round one person: none touching, the square grown to hold them', () {
    final nodes = [for (var i = 0; i < 100; i++) GraphNode(id: i, name: 'N$i', kind: 'person', weight: 50 - i % 50, firstCh: 0)];
    final edges = [
      for (var i = 1; i < 100; i++)
        GraphEdge(a: i < 40 ? 0 : (i % 39) + 1, b: i, label: 'ally of', kind: LinkKind.bond, fromCh: 0),
    ];
    final g = GraphData(nodes: nodes, edges: edges, lastCh: 1, focus: 0);
    final l = layoutGraph(g);
    expect(l.size, greaterThan(1000));
    for (var i = 0; i < 100; i++) {
      for (var j = i + 1; j < 100; j++) {
        final p = l.at[i]!, q = l.at[j]!;
        expect(math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2)),
            greaterThan((spaceDp(nodes[i].weight) + spaceDp(nodes[j].weight)) * canvasPerDp));
      }
    }
  });

  testWidgets("the screens: who's who lists and filters; the graph draws, a tap picks a node", (tester) async {
    final path = _memory(tmp);
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(MaterialApp(home: WhosWhoScreen(bookTitle: 'Shadow Slave', memoryPath: path)));
    await settle();
    expect(find.text('Sunless'), findsOneWidget);
    expect(find.text('Places 1'), findsOneWidget);
    await tester.tap(find.text('Places 1'));
    await settle();
    expect(find.text('Sunless'), findsNothing);
    expect(find.text('Forgotten Shore'), findsOneWidget);

    await tester.tap(find.byTooltip('The memory graph'));
    await settle();
    expect(find.byType(MemoryGraphScreen), findsOneWidget);
    // It opens on the whole web, a chip away from round the main character.
    expect(find.text('Round Sunless'), findsOneWidget);
    final painter = tester.widget<CustomPaint>(
        find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(CustomPaint)).first).painter as GraphPainter;
    final sunny = painter.data.nodes.firstWhere((n) => n.name == 'Sunless');
    final at = painter.at[sunny.id]!;
    // Fitted to the screen: the canvas (a square of the layout's side) drawn
    // smaller than it is.
    final canvas = find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(CustomPaint)).first;
    final box = tester.getRect(canvas);
    final scale = box.width / tester.getSize(canvas).width;
    expect(scale, lessThan(1));
    await tester.tapAt(box.topLeft + Offset(at.x, at.y) * scale);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Sunless'), findsOneWidget);
    expect(find.text('Centre here'), findsOneWidget);
    expect(find.text('Linked with…'), findsOneWidget);

    // The ball (3D) view is hidden for now: no toggle, and it is never drawn.
    expect(find.byTooltip('See it as a ball to turn (3D)'), findsNothing);
    expect(find.byType(Graph3dView), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}
