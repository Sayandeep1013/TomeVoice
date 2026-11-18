// Who's who and the memory graph: the book's entities by kind and name, as
// they stood at a chapter; the graph's relations as of that chapter, and
// the pairs who shared events; laid out the same each time, inside its
// square; the screens drawing them, a tap picking a node.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/memory/chapter_notes.dart';
import 'package:tomevoice_spike/ai/memory/graph.dart';
import 'package:tomevoice_spike/ai/memory/graph_screen.dart';
import 'package:tomevoice_spike/ai/memory/ledger.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
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
    bool linked(GraphData g, String label) =>
        g.edges.any((e) => {e.a, e.b}.containsAll({sunny, cassie}) && e.label == label);
    expect(linked(graphAt(path, at: 2), 'ally of'), isTrue);
    final after = graphAt(path);
    expect(linked(after, 'ally of'), isFalse, reason: 'they parted in chapter 4');
    expect(linked(after, '2 events together'), isTrue);
    expect(graphAt(path, at: 0).nodes.map((n) => n.name).toSet(), {'Sunless', 'Forgotten Shore'});
    expect(graphAt(path, kinds: {'place'}).nodes.single.name, 'Forgotten Shore');
    // Round one: Nephis knows nobody yet.
    final nephis = ledger(path, query: 'nephis').single.id;
    expect(graphAt(path, focus: nephis).nodes.single.name, 'Nephis');
    expect(graphAt(path, focus: sunny).nodes.length, 3);
  });

  test('laid out the same each time, inside its square, linked nodes nearer', () {
    final path = _memory(tmp);
    final g = graphAt(path);
    final a = layoutGraph(g), b = layoutGraph(g);
    expect(a, b);
    for (final p in a.values) {
      expect(p.x, inInclusiveRange(0, 1000));
      expect(p.y, inInclusiveRange(0, 1000));
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
    expect(find.textContaining('4 shown'), findsOneWidget);
    final painter = tester.widget<CustomPaint>(
        find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(CustomPaint)).first).painter as GraphPainter;
    final sunny = painter.data.nodes.firstWhere((n) => n.name == 'Sunless');
    final at = painter.at[sunny.id]!;
    // Fitted to the screen: the canvas drawn smaller than its thousand.
    final box = tester.getRect(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(CustomPaint)).first);
    final scale = box.width / 1000;
    expect(scale, lessThan(1));
    await tester.tapAt(box.topLeft + Offset(at.x, at.y) * scale);
    await tester.pump();
    expect(find.textContaining('Sunless · people'), findsOneWidget);
    expect(find.text('Centre on'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
