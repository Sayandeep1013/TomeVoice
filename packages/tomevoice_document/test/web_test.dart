import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

void main() {
  group('web chapters', () {
    test('site furniture is not read aloud; the story is', () {
      final s = webChapterSection(index: 0, title: 'Chapter 1', html: '''
<div>
<p>Translator: Nyx</p>
<p>Chapter 1: Nightmare Begins</p>
<p>A frail-looking young man was sitting on a rusty bench.</p>
<p>* * *</p>
<p>He said he would read the letter at noon.</p>
<p>Read the latest chapters at novelbin.com</p>
<p>Previous Chapter | Next Chapter</p>
</div>''');
      expect(s.blocks.map((b) => b.text), [
        'Chapter 1: Nightmare Begins',
        'A frail-looking young man was sitting on a rusty bench.',
        'He said he would read the letter at noon.',
      ]);
    });

    test('a novel is one book whose unread chapters are skipped, with stable places', () {
      Section chapter(int i) => webChapterSection(
            index: i,
            title: 'Chapter ${i + 1}',
            html: '<p>Chapter ${i + 1}</p><p>Text of chapter number ${i + 1} goes on long enough to be read.</p>',
          );
      final book = webNovelBook(
        id: 'web-1',
        title: 'Shadow',
        language: 'en',
        sections: [
          chapter(0),
          pendingWebChapter(index: 1, title: 'Chapter 2'),
          chapter(2),
        ],
      );
      final layout = ReadingLayout.build(book);
      expect(layout.chapters, hasLength(2), reason: 'the chapter not fetched yet is not shown');
      final third = layout.chapterFirstUnit[1];
      final cursor = cursorOf(layout.units[third]);
      expect(cursor.sectionIndex, 2, reason: 'a place is the chapter number');

      // Once chapter 2 arrives, the saved place still points at chapter 3.
      final fuller = webNovelBook(id: 'web-1', title: 'Shadow', sections: [chapter(0), chapter(1), chapter(2)]);
      final after = ReadingLayout.build(fuller);
      expect(after.units[after.unitForCursor(cursor)].text, 'Chapter 3');
    });

    test('a first line that repeats the title becomes the heading', () {
      final s = webChapterSection(index: 0, title: '44. A Show of Trust', html: '''
<p>Chapter 044 A Show of Trust</p>
<p>The idea that someone might connect all the dots was not a foreign idea.</p>''');
      expect(s.blocks.first.role, BlockRole.heading);
      expect(s.blocks.first.text, 'Chapter 044 A Show of Trust', reason: 'still heard once');
      final layout = ReadingLayout.build(webNovelBook(id: 'w', title: 'M', sections: [s]));
      expect(layout.items.where((i) => i.title != null), isEmpty, reason: 'no second title row');
    });

    test('titles match on words and numbers, not on a mere mention', () {
      expect(sameChapterTitle('Chapter 1', 'Chapter 1'), isTrue);
      expect(sameChapterTitle('CHAPTER 12: The Fool', '12. The Fool'), isTrue);
      expect(sameChapterTitle('Chapter 2', 'Chapter 3'), isFalse);
      expect(sameChapterTitle('Chapter 1: Nightmare Begins', 'Chapter 1'), isFalse);
      expect(sameChapterTitle('The Fool', 'Chapter 12: The Fool'), isTrue);
      expect(sameChapterTitle('He went to see the fool.', 'The Fool'), isFalse);
    });

    test('lines the reader chose to skip are dropped, already-downloaded ones too', () {
      final s = webChapterSection(index: 0, title: 'One', html: '''
<p>Thanks to our patrons on Patreon!</p>
<p>The story begins here.</p>''');
      final cleaned = cleanWebChapter(s, skip: ['patreon']);
      expect(cleaned.blocks.map((b) => b.text), ['The story begins here.']);
      expect(identical(cleanWebChapter(cleaned), cleaned), isTrue, reason: 'nothing to do, nothing copied');
    });

    test('dividers and empty lines are junk, ordinary sentences are not', () {
      expect(isWebJunk('-----'), isTrue);
      expect(isWebJunk('═══'), isTrue);
      expect(isWebJunk('Editor: Somebody'), isTrue);
      expect(isWebJunk('She read the chapter at dawn.'), isFalse);
      expect(isWebJunk('Next'), isTrue);
      expect(isWebJunk('The next day came.'), isFalse);
    });
  });
}
