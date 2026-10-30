import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

void main() {
  final book = ingestString(
    'Title sheet\n\n'
    '# Chapter 1: Alpha\n\n'
    'First chapter has enough text that it counts as a real chapter. It has two sentences.\n\n'
    'A second paragraph sits here, long enough to be read aloud properly.\n\n'
    '# Chapter 2: Beta\n\n'
    'Second chapter also has enough text that turning the page shows new sentences.',
    filename: 'novel.md',
  );
  final layout = ReadingLayout.build(book);

  test('front matter is not in the reading list', () {
    expect(layout.units.map((u) => u.text), isNot(contains('Title sheet')));
    expect(layout.chapters, hasLength(2));
  });

  test('every unit maps to the block that contains its text', () {
    for (var u = 0; u < layout.units.length; u++) {
      final item = layout.items[layout.unitItem[u]];
      expect(item.containsUnit(u), isTrue);
      expect(item.block!.text.startsWith(layout.units[u].text, layout.unitOffset[u]),
          isTrue);
    }
  });

  test('chapter ranges and titles', () {
    expect(layout.chapterTitle(0), 'Chapter 1: Alpha');
    final (first, count) = layout.chapterRange(1);
    expect(layout.units[first].text, 'Chapter 2: Beta');
    expect(first + count, layout.units.length);
    expect(layout.chapterOfUnit(first), 1);
  });

  test('word counts accumulate', () {
    expect(layout.wordsBefore.first, 0);
    expect(layout.totalWords, greaterThan(20));
  });

  test('a chapter without a heading gets a title row', () {
    final plain = ingestString(
      List.generate(3, (i) => 'Chapter ${i + 1}\n\nBody text number $i is long enough to count as reading.')
          .join('\n\n'),
      filename: 'plain.txt',
    );
    final l = ReadingLayout.build(plain);
    expect(l.items.first.isTitle || l.items.first.block!.role == BlockRole.heading, isTrue);
  });

  group('where a book opens', () {
    Book collection({required String firstTitle, required String firstBody}) => Book(
          id: 'c',
          metadata: const BookMetadata(title: 'The Lottery and Other Stories'),
          source: SourceKind.epub,
          toc: const [],
          sections: [
            Section(id: 'a', index: 0, title: firstTitle, blocks: [
              makeBlock(role: BlockRole.heading, text: firstTitle),
              makeBlock(role: BlockRole.paragraph, text: firstBody),
            ]),
            Section(id: 'b', index: 1, title: 'The Daemon Lover', blocks: [
              makeBlock(role: BlockRole.heading, text: 'The Daemon Lover'),
              makeBlock(role: BlockRole.paragraph, text: 'She had not slept well. ${'It went on. ' * 20}'),
            ]),
          ],
        );

    test("a collection's title story is where it opens", () {
      final layout = ReadingLayout.build(collection(
        firstTitle: 'The Lottery',
        firstBody: 'The morning of June 27th was clear and sunny. ${'The flowers were blossoming. ' * 30}',
      ));
      expect(layout.units[layout.unitForCursor(ReadingCursor.zero)].text, 'The Lottery');
    });

    test('a short title page named like the book is passed over on a first open', () {
      final layout = ReadingLayout.build(collection(
        firstTitle: 'The Lottery and Other Stories',
        firstBody: 'Shirley Jackson. A collection.',
      ));
      expect(layout.units[layout.unitForCursor(ReadingCursor.zero)].text, 'The Daemon Lover');
    });

    test('but a place saved there is where it reopens', () {
      final layout = ReadingLayout.build(collection(
        firstTitle: 'The Lottery and Other Stories',
        firstBody: 'Shirley Jackson. A collection.',
      ));
      final saved = cursorOf(layout.units.first);
      expect(layout.unitForCursor(saved, saved: true), 0);
    });
  });

  test('an untitled copyright page is not where the book opens', () {
    final legal = Section(id: 'a', index: 0, blocks: [
      makeBlock(
        role: BlockRole.paragraph,
        text: 'This is a work of fiction. Names and places are imagined. '
            'Copyright 2014 by the author. All rights reserved. ISBN 978-0-345-53978-6. '
            'Published in the United States by a publisher of books.',
      ),
    ]);
    final prologue = Section(id: 'b', index: 1, blocks: [
      makeBlock(
        role: BlockRole.paragraph,
        text: 'I would have lived in peace. But my enemies brought me war, '
            'and so the story begins here in the mines. ${'It goes on. ' * 70}',
      ),
    ]);
    final book = Book(
      id: 'x',
      metadata: const BookMetadata(title: 'Red'),
      sections: [legal, prologue],
      toc: const [],
      source: SourceKind.epub,
    );
    expect(ReadingLayout.build(book).units.first.text, startsWith('I would have lived'));
  });
}
