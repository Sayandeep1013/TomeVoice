import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

Book _md(String body) => ingestString(body, filename: 'book.md');

void main() {
  group('reading sections', () {
    test('skips a cover Image and TOC, opens on Chapter 1', () {
      resetBlockIds();
      final cover = Section(
        id: 's0',
        index: 0,
        title: 'Cover',
        blocks: [
          makeBlock(role: BlockRole.figure, text: 'Image'),
        ],
      );
      final toc = Section(
        id: 's1',
        index: 1,
        title: 'Section 5',
        blocks: [
          makeBlock(
            role: BlockRole.paragraph,
            text: 'Table of Contents FRONT COVER FULL COVER VOLUME 1',
          ),
        ],
      );
      final chapter = Section(
        id: 's2',
        index: 2,
        title: 'Chapter 1: Crimson',
        blocks: [
          makeBlock(
            role: BlockRole.heading,
            text: 'Chapter 1: Crimson',
          ),
          makeBlock(
            role: BlockRole.paragraph,
            text: 'Painful! How painful! My head hurts so badly! '
                'A gaudy and dazzling dreamworld filled with murmurs instantly shattered.',
          ),
        ],
      );
      final book = Book(
        id: 'lotm',
        metadata: const BookMetadata(title: 'Clown'),
        sections: [cover, toc, chapter],
        toc: [
          const TocEntry(title: 'Cover', sectionIndex: 0),
          const TocEntry(title: 'Contents', sectionIndex: 1),
          const TocEntry(title: 'Chapter 1: Crimson', sectionIndex: 2),
        ],
        source: SourceKind.epub,
        wordCount: 0,
      );
      final units = flattenSpeakable(book);

      expect(units.any((u) => u.text == 'Image'), isFalse);
      expect(isReadingSection(cover), isFalse);
      expect(isReadingSection(toc), isFalse);
      expect(isReadingSection(chapter), isTrue);
      expect(readingSectionIndexes(book, units), [2]);
      expect(units[firstReadingUnitIndex(units, book)].text, contains('Chapter 1'));
      expect(
        readingToc(book, units).map((t) => t.title),
        ['Chapter 1: Crimson'],
      );
    });

    test('skips a two-line title page and keeps Introduction', () {
      final book = _md(
        'CRIME AND PUNISHMENT\n\n'
        'translated by constance garnett\n\n'
        '# INTRODUCTION\n\n'
        'In 1848, a little group of young men, stirred by the revolutionary '
        'events in Western Europe, formed the habit of meeting at the house '
        'of one of their number in St. Petersburg, to read censored books.\n\n'
        '# I\n\n'
        'On an exceptionally hot evening early in July a young man came out '
        'of the garret in which he lodged in S. Place and walked slowly, as '
        'though in hesitation, towards K. bridge.',
      );
      final units = flattenSpeakable(book);
      final start = units[firstReadingUnitIndex(units, book)];
      expect(start.text.toLowerCase(), contains('introduction'));
      expect(
        readingToc(book, units).map((t) => t.title),
        containsAll(['INTRODUCTION', 'I']),
      );
    });

    test('a saved cursor inside a real chapter is kept', () {
      final book = _md(
        '# Chapter 1\n\nFirst sentence here is long enough. Second sentence follows.\n\n'
        '# Chapter 2\n\nOther chapter text is also long enough to count.',
      );
      final units = flattenSpeakable(book);
      final mid = units.firstWhere((u) => u.sectionIndex == 1);
      final i = readingIndexOfCursor(units, book, cursorOf(mid));
      expect(i, units.indexOf(mid));
    });

    test('a cursor on the cover snaps to the first chapter', () {
      final book = _md(
        'Title page only\n\n'
        '# Chapter 1: Start\n\n'
        'This opening paragraph is long enough that it counts as a chapter '
        'you would actually read, not a cover sheet.',
      );
      final units = flattenSpeakable(book);
      expect(
        units[readingIndexOfCursor(units, book, ReadingCursor.zero)].text,
        contains('Chapter 1'),
      );
    });
  });
}
