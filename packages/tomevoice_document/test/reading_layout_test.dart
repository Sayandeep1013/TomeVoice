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

  group('display-only blocks', () {
    Book notes() => Book(
          id: 'n',
          metadata: const BookMetadata(title: 'Notes'),
          source: SourceKind.epub,
          toc: const [],
          sections: [
            Section(id: 'a', index: 0, title: 'One', blocks: [
              makeBlock(role: BlockRole.heading, text: 'One'),
              makeBlock(role: BlockRole.paragraph, text: 'The house fell.${silentMark('1')} It was old. Nobody minded.'),
              makeBlock(role: BlockRole.footnote, text: '1 A note about the house.'),
              makeBlock(role: BlockRole.caption, text: 'Figure 1: the house.'),
              makeBlock(role: BlockRole.paragraph, text: 'Then the rain came, and it went on for days and days.'),
              makeBlock(role: BlockRole.pageNumber, text: '17'),
            ]),
            Section(id: 'b', index: 1, title: 'Two', blocks: [
              makeBlock(role: BlockRole.heading, text: 'Two'),
              makeBlock(role: BlockRole.paragraph, text: 'A second chapter begins here and goes on for long enough to be a chapter of its own.'),
              makeBlock(role: BlockRole.figure, text: 'A map of the town'),
              makeBlock(role: BlockRole.footnote, text: '2 The last note.'),
            ]),
          ],
        );

    test('off by default: the reader is as it was', () {
      final plain = ReadingLayout.build(notes());
      expect(plain.items.where((i) => i.displayOnly), isEmpty);
      expect(plain.items.map((i) => i.block?.text).whereType<String>(), isNot(contains('1 A note about the house.')));
    });

    test('on: notes, captions and figure text are shown, never spoken', () {
      final plain = ReadingLayout.build(notes());
      final shown = ReadingLayout.build(notes(), displayOnly: true);

      // The spoken units are exactly the same.
      expect(shown.units.map((u) => u.text), plain.units.map((u) => u.text));
      expect(shown.wordsBefore, plain.wordsBefore);
      expect(shown.chapterFirstUnit, plain.chapterFirstUnit);

      final only = shown.items.where((i) => i.displayOnly).toList();
      expect(only.map((i) => i.block!.text),
          ['1 A note about the house.', 'Figure 1: the house.', 'A map of the town', '2 The last note.']);
      for (final i in only) {
        expect(i.unitCount, 0);
        expect(i.containsUnit(i.firstUnit), isFalse);
      }
      // A note at the very end points past the last unit, as a picture there does.
      expect(only.last.firstUnit, shown.units.length);

      // Every unit maps to the item that holds its text.
      for (var u = 0; u < shown.units.length; u++) {
        final item = shown.items[shown.unitItem[u]];
        expect(item.containsUnit(u), isTrue);
        expect(item.displayOnly, isFalse);
        expect(item.block!.text.startsWith(shown.units[u].text, shown.unitOffset[u]), isTrue);
      }
      expect(shown.items[shown.unitItem.first].block!.text, 'One');
      expect(shown.units.last.text, 'A second chapter begins here and goes on for long enough to be a chapter of its own.');

      // Chapter tables still point at each chapter's first item and unit.
      for (var c = 0; c < shown.chapters.length; c++) {
        final first = shown.chapterFirstItem[c];
        final end = c + 1 < shown.chapters.length ? shown.chapterFirstItem[c + 1] : shown.items.length;
        expect(shown.items.sublist(first, end).every((i) => i.chapter == c), isTrue);
        expect(shown.unitChapter[shown.chapterFirstUnit[c]], c);
      }
      // Items keep the book's order: the note sits between the paragraphs.
      final texts = shown.items.map((i) => i.block?.text ?? i.title).toList();
      expect(texts.indexOf('1 A note about the house.'), texts.indexOf('Figure 1: the house.') - 1);
    });
  });

  group('a saved place after a re-parse', () {
    // The same book as an earlier build parsed it: one section, and the
    // answer and the question below kept as one sentence.
    Block oneSentence(String text) =>
        Block(id: 'x', role: BlockRole.paragraph, text: text, sentences: [Sentence(startOffset: 0, endOffset: text.length, words: const [])], anchor: const OffsetAnchor(0, 0));
    const filler = 'The road went on through the hills, and the light was going.';
    final chapters = [
      for (var c = 1; c <= 4; c++) ['Chapter $c', filler, '“No. Why should we trouble you?” she asked in chapter $c.', filler],
    ];
    final before = Book(
      id: 'b',
      metadata: const BookMetadata(title: 'Book'),
      source: SourceKind.epub,
      toc: const [],
      sections: [
        Section(id: 's0', index: 0, blocks: [
          for (final ch in chapters)
            for (final t in ch) t.startsWith('Chapter') ? makeBlock(role: BlockRole.heading, text: t) : oneSentence(t),
        ]),
      ],
    );
    // Today: a section per chapter, and the sentence split after "No."
    final after = ReadingLayout.build(Book(
      id: 'b',
      metadata: const BookMetadata(title: 'Book'),
      source: SourceKind.epub,
      toc: const [],
      sections: [
        for (var c = 0; c < chapters.length; c++)
          Section(id: 's$c', index: c, blocks: [
            for (final t in chapters[c]) makeBlock(role: t.startsWith('Chapter') ? BlockRole.heading : BlockRole.paragraph, text: t),
          ]),
      ],
    ));

    test('a sentence found again in another section', () {
      final old = flattenSpeakable(before);
      final at = old.indexWhere((u) => u.text == 'Chapter 3');
      final u = relocateCursor(old, cursorOf(old[at]), after);
      expect(after.units[u].text, 'Chapter 3');
      expect(after.units[u].sectionIndex, 2);
    });

    test('a sentence now split in two: its first part', () {
      final old = flattenSpeakable(before);
      final at = old.indexWhere((u) => u.text.contains('chapter 3.'));
      final u = relocateCursor(old, cursorOf(old[at]), after);
      expect(after.units[u].text, '“No.');
      expect(after.units[u].sectionIndex, 2, reason: 'the "No." of chapter 3, not of chapter 1');
    });
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
