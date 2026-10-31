// Quotes exported as Markdown: what goes in, in what order, and what never
// does (a shut secret shelf's).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/quote_export.dart';
import 'package:tomevoice_spike/speech_service.dart';

Mark _quote(ReadingLayout l, int unit, {MarkColour colour = MarkColour.accent, String id = 'q'}) => Mark(
      id: id,
      bookId: l.book.id,
      bookTitle: l.book.metadata.title,
      kind: MarkKind.quote,
      at: cursorOf(l.units[unit]),
      text: l.units[unit].text,
      created: DateTime(2026, 10, 1, 9, unit),
      colour: colour,
    );

void main() {
  late Directory tmp;

  setUp(() {
    MarkStore.instance.reset();
    tmp = Directory.systemTemp.createTempSync('tomevoice_export');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  final l = ReadingLayout.build(specimenBook());

  test('the title and author, then each quote in book order with its chapter, note and colour', () {
    final first = _quote(l, 0, colour: MarkColour.yellow, id: 'a').withNote('A pangram.\nThe classic one.');
    final later = _quote(l, l.units.length - 1, colour: MarkColour.blue, id: 'b');
    final md = quotesMarkdown([
      (title: 'Specimen', author: 'Ann Author', quotes: [later, first]),
    ]);
    expect(
      md,
      '# Specimen\n'
      '\n'
      '*Ann Author*\n'
      '\n'
      '## Without a chapter\n'
      '\n'
      '> The quick brown fox jumps over the lazy dog.\n'
      '\n'
      '- Note: A pangram.\n'
      '  The classic one.\n'
      '- Colour: Yellow\n'
      '\n'
      '> ${l.units.last.text}\n'
      '\n'
      '- Colour: Blue\n',
    );
  });

  test('chapters head their quotes; a line that reads as Markdown stays words', () {
    final a = Mark(
      id: 'x',
      bookId: 'b',
      bookTitle: 'T',
      kind: MarkKind.quote,
      at: const ReadingCursor(sectionIndex: 1, blockIndex: 0, sentenceIndex: 0),
      text: '# not a heading',
      chapter: 'Chapter 2',
      created: DateTime(2026),
    );
    final b = Mark(
      id: 'y',
      bookId: 'b',
      bookTitle: 'T',
      kind: MarkKind.quote,
      at: const ReadingCursor(sectionIndex: 0, blockIndex: 0, sentenceIndex: 0),
      text: 'Opening words.',
      chapter: 'Chapter 1',
      created: DateTime(2026),
    );
    final md = quotesMarkdown([(title: 'T', author: '', quotes: [a, b])]);
    expect(md.indexOf('## Chapter 1'), lessThan(md.indexOf('## Chapter 2')));
    expect(md, contains('> \\# not a heading'));
    expect(md, isNot(contains('*\n')), reason: 'no author line without an author');
  });

  test('several books, each under its own title', () {
    final md = quotesMarkdown([
      (title: 'One', author: 'A', quotes: [_quote(l, 0)]),
      (title: 'Empty', author: 'B', quotes: const []),
      (title: 'Two', author: 'C', quotes: [_quote(l, 1, id: 'z')]),
    ]);
    expect(RegExp('^# ', multiLine: true).allMatches(md).length, 2);
    expect(md, isNot(contains('# Empty')));
    expect(md.indexOf('# One'), lessThan(md.indexOf('# Two')));
  });

  test('a file name a folder takes', () {
    expect(exportFileName('Pride: and/Prejudice?'), 'Pride and Prejudice - quotes.md');
    expect(exportFileName(''), 'Quotes - quotes.md');
  });

  test("a shut secret shelf's quotes are not exported", () async {
    final store = LibraryStore(tmp);
    final open = await store.addCategory('Open');
    final secret = await store.addCategory('Hidden', secret: true);
    await store.ensure();
    Future<String> book(String name, String category) async {
      final f = File('${tmp.path}/incoming/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('Chapter 1\n\n${'The $name story goes on. ' * 30}');
      final e = await store.importFile(PickedFile(path: f.path, name: name));
      await store.moveBooks({e.id}, category);
      return e.id;
    }

    final shown = await book('shown.txt', open.id);
    final hidden = await book('hidden.txt', secret.id);
    for (final id in [shown, hidden]) {
      await MarkStore.instance.add(
        bookId: id,
        bookTitle: id,
        kind: MarkKind.quote,
        at: ReadingCursor.zero,
        text: 'Words from $id.',
      );
    }
    LibraryStore.secretOpen.value = false;
    expect([for (final b in await quotesToExport(store)) for (final q in b.quotes) q.bookId], [shown]);
    expect(await quotesToExport(store, bookId: hidden), isEmpty);
    LibraryStore.secretOpen.value = true;
    expect((await quotesToExport(store)).length, 2);
    LibraryStore.secretOpen.value = false;
  });
}
