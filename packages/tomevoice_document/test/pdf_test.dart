import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

const _m = pdfParagraphMark;

/// A page as the extractor writes it: each paragraph starts with the
/// paragraph mark, lines within it end with a newline.
String _page(List<List<String>> paragraphs) =>
    paragraphs.map((p) => _m + p.join('\n')).join('\n');

/// Words that differ from page to page, so no body line repeats like a
/// running head would.
const _words = [
  'amber', 'birch', 'cedar', 'dune', 'ember', 'fern', 'gorse', 'heath', //
  'iris', 'juniper', 'kelp', 'larch', 'moss', 'nettle', 'oak', 'pine',
  'quartz', 'reed', 'sorrel', 'thyme', 'umber', 'vetch', 'willow', 'yarrow',
];

/// A paragraph of ordinary prose for page [p], three lines long.
List<String> _prose(int p) => [
      'The ${_words[p % _words.length]} path ran down to the water, where',
      'the boats lay drawn up on the shingle in a long and patient row,',
      'and nobody was about but the gulls and the ${_words[(p + 7) % _words.length]} sellers.',
    ];

List<String> _texts(Book b) => [
      for (final s in b.sections)
        for (final bl in s.blocks) bl.text,
    ];

List<String> _titles(Book b) => [for (final s in b.sections) s.displayTitle];

/// A line and where it sits: x, the baseline's y from the top, width and
/// font size, in points; [para] when a paragraph starts with it.
typedef _At = ({String text, num x, num y, num w, num size, bool para});

_At _at(String text, num x, num y, {num w = 400, num size = 10, bool para = false}) =>
    (text: text, x: x, y: y, w: w, size: size, para: para);

/// A page's text and line layout, as PdfText sends them.
({String text, List<int> layout}) _laid(List<_At> lines) {
  final text = StringBuffer();
  final layout = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (i > 0) text.write('\n');
    if (l.para) text.write(_m);
    text.write(l.text);
    layout.addAll([l.x.round(), l.y.round(), l.w.round(), (l.size * 10).round(), l.text.length]);
  }
  return (text: text.toString(), layout: layout);
}

Book _laidBook(List<List<_At>> pages) {
  final laid = [for (final p in pages) _laid(p)];
  return ingestPdfText(
    id: 'x',
    pages: [for (final p in laid) p.text],
    layout: [for (final p in laid) p.layout],
  );
}

void main() {
  group('running heads and page numbers', () {
    test('a head naming the story is dropped, though it tops few pages', () {
      const stories = ['THE LANTERN KEEPER', 'THE SALT ROAD', 'THE GREY HARBOUR'];
      final pages = <String>[];
      for (var p = 0; p < 18; p++) {
        final story = stories[p ~/ 6];
        pages.add(_page([
          // The story's title opens it; after that the left pages carry the
          // book's title and the right pages the story's, each with its page
          // number, as a printed collection does.
          if (p % 6 == 0) [story] else if (p.isOdd) ['TALES OF THE COAST ${p + 1}'] else ['$story ${p + 1}'],
          if (p == 2) ['next leaf of the log, which was blank.'],
          _prose(p),
          if (p == 1) ['At last the keeper turned it over to the'],
        ]));
      }
      final book = ingestPdfText(id: 'x', pages: pages);
      final all = _texts(book).join('\n');
      expect(all, contains('turned it over to the next leaf of the log'));
      expect(all, isNot(contains('KEEPER 3')));
      expect(all, isNot(contains('TALES OF THE COAST')));
      // Its one copy without a page number is the story's own heading.
      expect(_texts(book).where((t) => t == 'THE LANTERN KEEPER'), hasLength(1));
      expect(_texts(book).where((t) => t == 'THE SALT ROAD'), hasLength(1));
    });

    test('short chapters keep their "Chapter N" headings', () {
      // A chapter every page or two: "Chapter N" tops most pages, which
      // once read as one running head ("Chapter" with the number ignored).
      const starts = {0: 1, 1: 2, 3: 3, 4: 4, 6: 5, 7: 6};
      final pages = [
        for (var p = 0; p < 9; p++)
          _page([
            if (starts[p] case final n?) ['Chapter $n'],
            _prose(p),
          ]),
      ];
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(_titles(book), [for (var n = 1; n <= 6; n++) 'Chapter $n']);
    });

    test('running heads that carry the chapter still go; the heading stays', () {
      // "CHAPTER 2 6" over every page of chapter two after its first.
      final pages = <String>[];
      const names = ['The Crossing', 'The Watch', 'The Return'];
      for (var p = 0; p < 12; p++) {
        final n = p ~/ 4 + 1;
        pages.add(_page([
          if (p % 4 == 0) ...[
            ['CHAPTER $n'],
            [names[n - 1]],
          ] else
            ['CHAPTER $n ${p + 1}'],
          _prose(p),
        ]));
      }
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(_titles(book), [
        'Chapter 1: The Crossing',
        'Chapter 2: The Watch',
        'Chapter 3: The Return',
      ]);
      expect(_texts(book).join('\n'), isNot(contains('CHAPTER 2 6')));
    });

    test('a printed contents page is not a list of chapters', () {
      const names = ['The Lantern', 'The Salt Road', 'The Grey Harbour', 'Low Water'];
      final pages = [
        _page([
          ['Contents'],
          for (var i = 0; i < names.length; i++) ['Chapter ${i + 1} ${names[i]} ${i + 2}'],
        ]),
        for (var i = 0; i < names.length; i++)
          _page([
            ['CHAPTER ${i + 1}'],
            [names[i]],
            _prose(i),
          ]),
      ];
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(_titles(book), [
        'Opening pages',
        for (var i = 0; i < names.length; i++) 'Chapter ${i + 1}: ${names[i]}',
      ]);
      // The book opens on chapter one, not on the contents.
      final units = flattenSpeakable(book);
      expect(units[firstReadingUnitIndex(units, book)].text, 'CHAPTER 1');
    });

    test('a title page and a contents page are not read when the book opens', () {
      final pages = [
        _page([
          ['PRIDE AND PREJUDICE:'],
          ['A NOVEL. IN THREE VOLUMES.'],
          ['VOL. I.'],
          ['London: Printed for T. Egerton, Military Library, Whitehall. 1813.'],
        ]),
        _page([
          ['CONTENTS'],
          for (final (i, n) in ['I', 'II', 'III'].indexed) ['Chapter $n . . . . . . . ${i * 3 + 1}'],
        ]),
        for (var p = 2; p < 11; p++)
          _page([
            if (p % 3 == 2) ['CHAPTER ${['I', 'II', 'III'][(p - 2) ~/ 3]}.'],
            _prose(p),
          ]),
      ];
      final layout = ReadingLayout.build(ingestPdfText(id: 'x', pages: pages));
      expect([for (var c = 0; c < layout.chapters.length; c++) layout.chapterTitle(c)],
          ['Chapter I', 'Chapter II', 'Chapter III']);
      expect(layout.units[layout.unitForCursor(ReadingCursor.zero)].text, 'CHAPTER I.');
    });

    test("a short chapter's one running head, set small, is not another chapter", () {
      // Chapters two pages long: the second page's head names the chapter
      // and carries the page's number ("CHAPTER II. 4"), once a chapter.
      const roman = ['I', 'II', 'III', 'IV'];
      final pages = <List<_At>>[];
      for (var c = 0; c < 4; c++) {
        for (var k = 0; k < 2; k++) {
          final folio = c * 2 + k + 1;
          final top = k == 0 ? 210 : 90;
          pages.add([
            if (k == 0)
              _at('CHAPTER ${roman[c]}.', 160, 170, w: 100, size: 14, para: true)
            else
              _at('CHAPTER ${roman[c]}. $folio', 250, 50, w: 90, size: 9, para: true),
            for (final (i, l) in _prose(folio).indexed) _at(l, 72, top + i * 13, size: 10.5, para: i == 0),
            if (k == 0) _at('$folio', 205, 575, w: 6, size: 9, para: true),
          ]);
        }
      }
      final book = _laidBook(pages);
      expect(_titles(book), ['Chapter I', 'Chapter II', 'Chapter III', 'Chapter IV']);
      expect(_texts(book).join('\n'), isNot(contains('CHAPTER II. 4')));
    });

    test('without chapter headings, the book opens after its contents page', () {
      // Stories with plain titles: no "Chapter N" to make chapters of, so
      // the book goes ten pages to an entry. The contents page heads the
      // first ten, which once made all ten front matter, skipped on opening.
      const stories = ['The Lantern', 'The Salt Road', 'The Grey Harbour'];
      final pages = [
        _page([
          ['A Book of the Coast'],
        ]),
        _page([
          ['CONTENTS'],
          for (var i = 0; i < stories.length; i++) ['${stories[i]} ${3 + i * 8}'],
        ]),
        for (var p = 2; p < 26; p++)
          _page([
            if (p % 8 == 2) [stories[(p - 2) ~/ 8].toUpperCase()],
            _prose(p),
          ]),
      ];
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(_titles(book), ['Opening pages', 'Pages 3–12', 'Pages 13–22', 'Pages 23–26']);
      final units = flattenSpeakable(book);
      expect(units[firstReadingUnitIndex(units, book)].text, 'THE LANTERN');
    });

    test('prose whose lines end in numbers is not a contents page', () {
      final book = ingestPdfText(id: 'x', pages: [
        _page([
          [
            'The tide that morning stood at 12',
            'feet, then fell to 3',
            'by noon and rose again to 11',
            'before the boats went out at 6',
            'with the light still on the water.',
          ],
        ]),
      ]);
      expect(_texts(book), [
        'The tide that morning stood at 12 feet, then fell to 3 by noon and rose again '
            'to 11 before the boats went out at 6 with the light still on the water.',
      ]);
    });

    test('"1914" or "II" alone on a line is text, not a page number', () {
      final pages = [
        for (var p = 0; p < 6; p++)
          _page([
            _prose(p),
            if (p == 2) ['II'],
            if (p == 3) ['1914'],
            _prose(p + 1),
            // The printed page number, at the foot.
            ['${p + 1}'],
          ]),
      ];
      final texts = _texts(ingestPdfText(id: 'x', pages: pages));
      expect(texts, containsAll(['II', '1914']));
      expect(texts.where((t) => RegExp(r'^[1-6]$').hasMatch(t)), isEmpty);
    });

    test('page numbers at the top, starting after an unnumbered page, still go', () {
      // A title page, then "1", "2"... at the head of each page: the printed
      // number is one less than the page's place in the file. Front matter in
      // roman numerals counts too.
      final pages = [
        _page([
          ['A Book of the Coast'],
        ]),
        for (var p = 1; p < 4; p++)
          _page([
            [_roman[p - 1]],
            _prose(p),
          ]),
        for (var p = 4; p < 9; p++)
          _page([
            ['${p - 3}'],
            _prose(p),
          ]),
      ];
      final texts = _texts(ingestPdfText(id: 'x', pages: pages));
      expect(texts.where((t) => RegExp(r'^(\d+|[ivx]+)$').hasMatch(t)), isEmpty);
    });
  });

  group('bookmarks', () {
    List<String> titles(List<PdfOutlineEntry> o) => [for (final e in o) e.title];

    test('chapters inside Parts are kept', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Part One', 'page': 1, 'level': 0},
        {'title': 'The Arrival', 'page': 2, 'level': 1},
        {'title': 'The Storm', 'page': 9, 'level': 1},
        {'title': 'Part Two', 'page': 15, 'level': 0},
        {'title': 'The Return', 'page': 16, 'level': 1},
      ]);
      expect(titles(outline), ['Part One', 'The Arrival', 'The Storm', 'Part Two', 'The Return']);
      expect([for (final e in outline) e.page], [1, 2, 9, 15, 16]);
    });

    test('a lone top bookmark, the book itself, is unwrapped', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Moby-Dick', 'page': 0, 'level': 0},
        {'title': 'Loomings', 'page': 2, 'level': 1},
        {'title': 'The Carpet-Bag', 'page': 6, 'level': 1},
      ]);
      expect(titles(outline), ['Loomings', 'The Carpet-Bag']);
    });

    test('titles repeated in each Part are named with their Part', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Part I', 'page': -1, 'level': 0},
        {'title': 'Chapter 1', 'page': 1, 'level': 1},
        {'title': 'Chapter 2', 'page': 5, 'level': 1},
        {'title': 'Part II', 'page': 9, 'level': 0},
        {'title': 'Chapter 1', 'page': 10, 'level': 1},
      ]);
      expect(titles(outline), [
        'Part I: Chapter 1',
        'Part I: Chapter 2',
        'Part II',
        'Part II: Chapter 1',
      ]);
    });

    test('the book over its chapters is unwrapped beside bookmarks to nowhere', () {
      // Pride and Prejudice from Planet eBook: two bookmarks that point
      // nowhere at the top, and Chapters 19 and 20 listed twice.
      final outline = pdfOutlineFromPlatform([
        {'title': 'Pride and Prejudice', 'page': 0, 'level': 0},
        {'title': 'Chapter 1', 'page': 1, 'level': 1},
        {'title': 'Chapter 19', 'page': 120, 'level': 1},
        {'title': 'Chapter 19', 'page': 127, 'level': 1},
        {'title': 'Chapter 2', 'page': 5, 'level': 1},
        {'title': 'How to share this eBook', 'page': -1, 'level': 0},
        {'title': 'Free eBooks at Planet eBook', 'page': -1, 'level': 0},
      ]);
      expect(titles(outline), ['Chapter 1', 'Chapter 19', 'Chapter 19', 'Chapter 2']);
    });

    test('a title listed twice in one group is not named with it', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Volume One', 'page': 0, 'level': 0},
        {'title': 'Chapter 1', 'page': 1, 'level': 1},
        {'title': 'Chapter 1', 'page': 4, 'level': 1},
        {'title': 'Volume Two', 'page': 9, 'level': 0},
        {'title': 'Chapter 2', 'page': 10, 'level': 1},
      ]);
      expect(titles(outline), ['Volume One', 'Chapter 1', 'Chapter 1', 'Volume Two', 'Chapter 2']);
    });

    test("a chapter's own sections are not chapters", () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Chapter 1 Cells', 'page': 0, 'level': 0},
        {'title': '1.1 Membranes', 'page': 2, 'level': 1},
        {'title': '1.2 Organelles', 'page': 5, 'level': 1},
        {'title': '2 Tissues', 'page': 9, 'level': 0},
        {'title': '2.1 Epithelium', 'page': 10, 'level': 1},
      ]);
      expect(titles(outline), ['Chapter 1 Cells', '2 Tissues']);
    });

    test("a scan's bookmarks named after its pictures are not chapters", () {
      // An image-to-PDF tool's bookmark on every page, named after the page's
      // picture: each was a chapter, its name over the page and read aloud.
      final outline = pdfOutlineFromPlatform([
        for (var p = 0; p < 4; p++) {'title': 'DSC0${1139 + p}.tif', 'page': p, 'level': 0},
        {'title': 'IMG_2041.JPG', 'page': 4, 'level': 0},
        {'title': 'IMG-20240501-WA0003', 'page': 5, 'level': 0},
        {'title': 'PXL_20240501_101530123', 'page': 6, 'level': 0},
        {'title': 'scan0001.pdf', 'page': 7, 'level': 0},
        {'title': '0009.pdf', 'page': 8, 'level': 0},
        {'title': 'page_010.png', 'page': 9, 'level': 0},
      ]);
      expect(outline, isEmpty);
    });

    test('a PDF joined from files keeps a chapter for each, named without the extension', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Chapter 1.pdf', 'page': 0, 'level': 0},
        {'title': 'The Storm.PDF', 'page': 9, 'level': 0},
        {'title': 'Image 3', 'page': 12, 'level': 0},
        {'title': '1914', 'page': 15, 'level': 0},
      ]);
      expect(titles(outline), ['Chapter 1', 'The Storm', 'Image 3', '1914']);
    });

    test("a scan titled with its first picture's name is named by its file", () {
      final pages = [_page([_prose(0), _prose(1)])];
      String titled(String? title) =>
          ingestPdfText(id: 'x', pages: pages, title: title, filename: 'Sonar Tori.pdf').metadata.title;
      expect(titled('DSC01139.tif'), 'Sonar Tori');
      expect(titled('IMG_2041'), 'Sonar Tori');
      expect(titled('  '), 'Sonar Tori');
      expect(titled('The Harbour Book.docx'), 'The Harbour Book');
      expect(titled('The Harbour Book'), 'The Harbour Book');
    });

    test('a bookmark on every page, its title not printed there, marks the page, not a chapter', () {
      // A scanned book with "Page 1" to "Page 12" in its bookmarks, and its
      // chapters printed in its text.
      final pages = [
        for (var p = 0; p < 12; p++)
          _page([
            if (p % 4 == 0) ['CHAPTER ${['I', 'II', 'III'][p ~/ 4]}.'],
            _prose(p),
            _prose(p + 12),
          ]),
      ];
      final book = ingestPdfText(id: 'x', pages: pages, outline: [
        for (var p = 0; p < 12; p++) (title: 'Page ${p + 1}', page: p),
      ]);
      expect(_titles(book), ['Chapter I', 'Chapter II', 'Chapter III']);
    });

    test('a poem a page, its title printed over it, keeps its bookmarks', () {
      const poems = ['The Lantern', 'Low Water', 'The Salt Road', 'Gulls', 'The Ford', 'Night Boats', 'Driftwood'];
      final pages = [
        for (var p = 0; p < poems.length; p++)
          _page([
            [poems[p]],
            _prose(p),
          ]),
      ];
      final book = ingestPdfText(id: 'x', pages: pages, outline: [
        for (var p = 0; p < poems.length; p++) (title: poems[p], page: p),
      ]);
      expect(_titles(book), poems);
    });

    test('bookmarks without levels, from an older extractor, read as before', () {
      final outline = pdfOutlineFromPlatform([
        {'title': 'Intro', 'page': 0},
        {'title': 'Part Two', 'page': 2},
      ]);
      expect(outline, [(title: 'Intro', page: 0), (title: 'Part Two', page: 2)]);
    });

    test('chapters sharing a page each start at their printed title', () {
      final pages = [
        _page([
          ['A Book of Small Things'],
          _prose(0),
        ]),
        _page([
          ['First Thing'],
          _prose(1),
          ['Second Thing'],
          _prose(2),
          // Runs on: the next page's first line is the next chapter's title.
          ['and then the long and patient wait was over, as all things'],
        ]),
        _page([
          ['Third Thing'],
          _prose(3),
          ['Fourth Thing'],
          _prose(4),
        ]),
        _page([_prose(5)]),
      ];
      final book = ingestPdfText(
        id: 'x',
        pages: pages,
        outline: const [
          (title: 'First Thing', page: 1),
          (title: 'Second Thing', page: 1),
          (title: 'Third Thing', page: 2),
          (title: 'Fourth Thing', page: 2),
        ],
      );
      expect(_titles(book), ['Opening pages', 'First Thing', 'Second Thing', 'Third Thing', 'Fourth Thing']);
      for (final s in book.sections.skip(1)) {
        expect(s.blocks.first.text, s.title);
      }
    });

    test('a chapter whose title is not printed starts at the top of its page', () {
      final pages = [
        for (var p = 0; p < 4; p++)
          _page([
            _prose(p),
            _prose(p + 10),
          ]),
      ];
      final book = ingestPdfText(
        id: 'x',
        pages: pages,
        outline: const [(title: 'One', page: 0), (title: 'Two', page: 2)],
      );
      expect(_titles(book), ['One', 'Two']);
      expect(book.sections[1].blocks.first.anchor, isA<PageAnchor>().having((a) => a.page, 'page', 2));
    });
  });

  group('words broken over a line', () {
    final soft = String.fromCharCode(0xAD);

    test('Cyrillic and accented Latin are mended like English', () {
      expect(joinWrappedLines(['Это было приме-', 'чательно.']), 'Это было примечательно.');
      expect(joinWrappedLines(['Było to wy-', 'łącznie jego.']), 'Było to wyłącznie jego.');
      expect(joinWrappedLines(['an exam-', 'ple']), 'an example');
    });

    test('a soft hyphen at a line end joins; one inside a word goes', () {
      expect(joinWrappedLines(['an exam$soft', 'ple of it']), 'an example of it');
      expect(joinWrappedLines(['Donau$soft', 'dampfschiff']), 'Donaudampfschiff');
      expect(joinWrappedLines(['hy${soft}phen and dash']), 'hyphen and dash');
    });

    test('a hyphen before a capital or a number is not a broken word', () {
      expect(joinWrappedLines(['Jean-', 'Paul came']), 'Jean- Paul came');
      expect(joinWrappedLines(['in 1914-', '1918']), 'in 1914- 1918');
      expect(joinWrappedLines(['a dash --', 'then more']), 'a dash -- then more');
    });

    test('a word broken by a soft hyphen at the foot of a page is mended', () {
      final book = ingestPdfText(id: 'x', pages: [
        _page([
          ['The keeper had kept the lamp for thirty years, and all that time the exam$soft'],
        ]),
        _page([
          ['ple he set was followed by every keeper who came after him.'],
        ]),
      ]);
      expect(_texts(book), [
        'The keeper had kept the lamp for thirty years, and all that time the example '
            'he set was followed by every keeper who came after him.',
      ]);
    });

    test('a PDF paragraph broken before a lower-case Cyrillic word runs on', () {
      final book = ingestPdfText(id: 'x', pages: [
        '$_mОн смотрел на море и думал, что\n'
            '$_mзавтра снова будет шторм, и лодки не выйдут.\n'
            '$_mЭто было приме-\n$_mчательно, как всегда в это время года.',
      ]);
      expect(_texts(book), [
        'Он смотрел на море и думал, что завтра снова будет шторм, и лодки не выйдут.',
        'Это было примечательно, как всегда в это время года.',
      ]);
    });
  });

  group('line layout', () {
    test('a note at the foot of a page leaves the sentence that runs over it', () {
      final book = _laidBook([
        [
          _at('The meeting went on into the night, and by the time', 72, 100, para: true),
          _at('the lamps were lit the business of it all had come to an', 72, 114),
          _at('1 See the minutes of the meeting held in March.', 72, 700, size: 8, para: true),
          _at('2 The vote was taken twice.', 72, 710, size: 8, para: true),
          _at('1', 300, 740, w: 6, para: true),
        ],
        [
          _at('end, and nobody spoke of it again for many years.', 72, 100, para: true),
          _at('2', 300, 740, w: 6, para: true),
        ],
      ]);
      final blocks = book.sections.expand((s) => s.blocks).toList();
      expect(blocks.map((b) => b.text), [
        'The meeting went on into the night, and by the time the lamps were lit the '
            'business of it all had come to an end, and nobody spoke of it again for many years.',
        '1 See the minutes of the meeting held in March.',
        '2 The vote was taken twice.',
      ]);
      expect(blocks.skip(1).map((b) => b.role), everyElement(BlockRole.footnote));
      expect(blocks.last.anchor, isA<PageAnchor>().having((a) => a.page, 'page', 0));
    });

    test('two columns are read left, then right', () {
      // Drawn across the page: each left line, then the right one beside it.
      final lines = [_at('A TITLE ACROSS THE PAGE', 72, 60, w: 468, size: 14, para: true)];
      for (var i = 0; i < 6; i++) {
        lines
          ..add(_at('the left column goes on with ${_words[i]}', 72, 100 + i * 14, w: 220, para: i == 0))
          ..add(_at('the right column goes on with ${_words[i]}', 320, 100 + i * 14, w: 220, para: i == 0));
      }
      final all = _texts(_laidBook([lines])).join(' ');
      final order = [
        for (var i = 0; i < 6; i++) all.indexOf('left column goes on with ${_words[i]}'),
        for (var i = 0; i < 6; i++) all.indexOf('right column goes on with ${_words[i]}'),
      ];
      expect(order, everyElement(greaterThan(0)));
      expect([...order]..sort(), order);
    });

    test('one column stays as drawn, quotes and small print included', () {
      final book = _laidBook([
        [
          _at('He read the letter aloud to the room, slowly, as if every', 72, 100, para: true),
          _at('word of it might change its meaning on the second reading:', 72, 114),
          // An indented quotation, and small print at the foot with no
          // note mark: neither is a column or a footnote.
          _at('Come home before the tide turns, and bring the', 120, 140, w: 300, para: true),
          _at('lantern with you, for the road is dark at night.', 120, 154, w: 300),
          _at('Then he folded it, and put it in his coat, and said nothing.', 72, 180, para: true),
          _at('Then he went out into the street and did not come back.', 72, 194),
          _at('Printed by the harbour press, in a small edition.', 72, 700, size: 7, para: true),
        ],
      ]);
      final texts = _texts(book);
      expect(texts.first, startsWith('He read the letter'));
      expect(texts.last, 'Printed by the harbour press, in a small edition.');
      expect(book.sections.expand((s) => s.blocks).map((b) => b.role), isNot(contains(BlockRole.footnote)));
    });

    test('a heading set large is kept, though running heads repeat it', () {
      // No page numbers on the heads, so only the size tells them apart.
      final pages = <List<_At>>[];
      for (var p = 0; p < 6; p++) {
        pages.add([
          if (p == 0)
            _at('THE LANTERN KEEPER', 72, 80, w: 300, size: 18, para: true)
          else
            _at('THE LANTERN KEEPER', 72, 40, w: 200, size: 9, para: true),
          for (final (i, l) in _prose(p).indexed) _at(l, 72, 100 + i * 14, para: i == 0),
        ]);
      }
      final texts = _texts(_laidBook(pages));
      expect(texts.where((t) => t == 'THE LANTERN KEEPER'), hasLength(1));
      expect(texts.where((t) => t.contains('LANTERN KEEPER')), hasLength(1));
    });

    test('dialogue the extractor ran together is split where each line is set in', () {
      // As Pride and Prejudice came out: one extractor paragraph for a
      // whole exchange, each speaker's first line indented an em.
      final book = _laidBook([
        [
          _at('‘My dear Mr. Bennet,’ said his lady to him one day, ‘have', 82, 100, w: 390, para: true),
          _at('you heard that Netherfield Park is let at last?’', 72, 114, w: 260),
          _at('Mr. Bennet replied that he had not.', 82, 128, w: 180),
          _at('‘But it is,’ returned she; ‘for Mrs. Long has just been here,', 82, 142, w: 390),
          _at('and she told me all about it.’', 72, 156, w: 170),
          _at('Mr. Bennet made no answer.', 82, 170, w: 150),
          _at('‘Do you not want to know who has taken it?’ cried his wife', 82, 184, w: 390),
          _at('impatiently. A full line of the same paragraph ends a sentence.', 72, 198),
          _at('and goes on at the edge, where it belongs, to its end.', 72, 212, w: 300),
        ],
      ]);
      expect(_texts(book), [
        '‘My dear Mr. Bennet,’ said his lady to him one day, ‘have you heard that Netherfield Park is let at last?’',
        'Mr. Bennet replied that he had not.',
        '‘But it is,’ returned she; ‘for Mrs. Long has just been here, and she told me all about it.’',
        'Mr. Bennet made no answer.',
        '‘Do you not want to know who has taken it?’ cried his wife impatiently. '
            'A full line of the same paragraph ends a sentence. and goes on at the edge, where it belongs, to its end.',
      ]);
    });

    test("two speakers' lines set in, one after the other, are two paragraphs however the extractor marked them", () {
      // Pride and Prejudice as PDFBox marks paragraphs when it sees indents:
      // at a line set in after one that did not start a paragraph, and at a
      // line back at the edge after one set in that did not. A one-line
      // speech and the next speaker's first line, both set in, share one
      // extractor paragraph with no line at the edge, and were read as one
      // ("How so? ... them?' 'My dear Mr. Bennet,' replied his wife").
      // Measured on the page: the text at x 31.5, a speaker's first line set
      // in to 41.9, an em at 10 points.
      final book = _laidBook([
        [
          _at('‘What is his name?’', 41.9, 80, w: 94, para: true),
          _at('‘Bingley.’', 41.9, 93, w: 49),
          _at('‘Is he married or single?’', 41.9, 106, w: 128),
          _at('‘Oh! single, my dear, to be sure! A single man of large', 41.9, 119, w: 309.6),
          _at('fortune; four or five thousand a year. What a fine thing for our', 31.5, 132, w: 320, para: true),
          _at('girls!’', 31.5, 145, w: 35),
          _at('‘How so? how can it affect them?’', 41.9, 158, w: 163, para: true),
          _at('‘My dear Mr. Bennet,’ replied his wife, ‘how can you be so', 41.9, 171, w: 309.6),
          _at('tiresome! You must know that I am thinking of his marrying one', 31.5, 184, w: 320, para: true),
          _at('of them.’', 31.5, 197, w: 44),
          _at('‘Is that his design in settling here?’', 41.9, 210, w: 188, para: true),
          _at('‘Design! nonsense, how can you talk so! But it is very likely', 41.9, 223, w: 309.6),
          _at('that he may fall in love with one of them, and therefore you', 31.5, 236, w: 320, para: true),
          _at('must visit him as soon as he comes.’', 31.5, 249, w: 178),
        ],
      ]);
      expect(_texts(book), [
        '‘What is his name?’',
        '‘Bingley.’',
        '‘Is he married or single?’',
        '‘Oh! single, my dear, to be sure! A single man of large fortune; four or five thousand a year. '
            'What a fine thing for our girls!’',
        '‘How so? how can it affect them?’',
        '‘My dear Mr. Bennet,’ replied his wife, ‘how can you be so tiresome! You must know that I am '
            'thinking of his marrying one of them.’',
        '‘Is that his design in settling here?’',
        '‘Design! nonsense, how can you talk so! But it is very likely that he may fall in love with one '
            'of them, and therefore you must visit him as soon as he comes.’',
      ]);
    });

    test('a title set larger than the text under it is a paragraph of its own', () {
      // Two fables on a page, each title a little above its text: the
      // extractor ran each title into its text, so the title was read as the
      // start of the first sentence and the bookmarks could not find it.
      final laid = _laid([
        _at('The Fox and the Crow', 72, 100, w: 150, size: 12, para: true),
        _at('A CROW having stolen a bit of meat, perched in a tree and held', 72, 116),
        _at('it in her beak. A Fox, seeing this, longed to possess the meat.', 72, 128, w: 380),
        _at('The Crow and the Pitcher', 72, 160, w: 170, size: 12, para: true),
        _at('A CROW perishing with thirst saw a pitcher, and hoping to find', 72, 176),
        _at('water, flew to it with delight. Necessity is the mother of invention.', 72, 188, w: 390),
      ]);
      final book = ingestPdfText(
        id: 'x',
        pages: [laid.text],
        layout: [laid.layout],
        outline: const [(title: 'The Fox and the Crow', page: 0), (title: 'The Crow and the Pitcher', page: 0)],
      );
      expect(_titles(book), ['The Fox and the Crow', 'The Crow and the Pitcher']);
      expect(_texts(book), [
        'The Fox and the Crow',
        'A CROW having stolen a bit of meat, perched in a tree and held it in her beak. '
            'A Fox, seeing this, longed to possess the meat.',
        'The Crow and the Pitcher',
        'A CROW perishing with thirst saw a pitcher, and hoping to find water, flew to it with delight. '
            'Necessity is the mother of invention.',
      ]);
    });

    test('a quotation set in as a whole stays one paragraph', () {
      final book = _laidBook([
        [
          _at('He read the letter aloud to the room, slowly, as if every', 72, 100, para: true),
          _at('word of it might change its meaning on the second reading:', 72, 114),
          _at('Come home before the tide turns. Bring the lantern, and', 120, 140, w: 300, para: true),
          _at('the key to the gate. The road is dark at night.', 120, 154, w: 300),
          _at('Mind the ford. It rises fast after the rain.', 120, 168, w: 260),
        ],
      ]);
      expect(_texts(book).last, 'Come home before the tide turns. Bring the lantern, and the key to the gate. '
          'The road is dark at night. Mind the ford. It rises fast after the rain.');
    });

    test('a layout that does not match the text is ignored', () {
      final good = _laid([
        _at('He read the letter aloud to the room, slowly, as if every', 72, 100, para: true),
        _at('word of it might change its meaning on the second reading.', 72, 114),
      ]);
      final wrong = [...good.layout]..[4] += 1;
      final book = ingestPdfText(id: 'x', pages: [good.text], layout: [wrong]);
      expect(_texts(book), [
        'He read the letter aloud to the room, slowly, as if every word of it might '
            'change its meaning on the second reading.',
      ]);
    });

    test('a scan with a few typed pages imports, and says it is mostly pictures', () {
      // 300 pages, of which only 3 have a text layer, about 300 words; the
      // platform's text ends with a page break, so the split leaves an empty
      // string last.
      final pages = [
        for (var p = 0; p < 300; p++)
          p == 0 || p == 1 || p == 150 ? _page([_prose(p), _prose(p + 1), _prose(p + 2)]) : '',
        '',
      ];
      expect(pdfTextCoverage(pages), (pages: 300, pagesWithText: 3, mostlyPictures: true));
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(_texts(book).join(' '), contains('The amber path'));
    });

    test('a scan whose only text is a stamp, or a line, is refused', () {
      final stamped = [for (var p = 0; p < 300; p++) 'Digitized by Google'];
      expect(pdfTextCoverage(stamped).pagesWithText, 0);
      expect(
        () => ingestPdfText(id: 'x', pages: stamped),
        throwsA(isA<UnsupportedDocumentException>()),
      );
      // OCR specks on every scanned page, and one typed title page.
      final titled = [
        'THE HISTORY OF THE HARBOUR AND ITS LIGHTHOUSE, WITH MAPS AND PLATES, VOLUME ONE',
        for (var p = 1; p < 300; p++) ". , ' ~ .",
      ];
      expect(
        () => ingestPdfText(id: 'x', pages: titled),
        throwsA(isA<UnsupportedDocumentException>()),
      );
    });

    test('slides with one short line each are text; a stamp on every page is not', () {
      final slides = [
        for (var p = 0; p < 30; p++)
          _page([
            ['Slide about the ${_words[p % 24]} harbour'],
          ]),
      ];
      expect(pdfTextCoverage(slides), (pages: 30, pagesWithText: 30, mostlyPictures: false));
      expect(_texts(ingestPdfText(id: 'x', pages: slides)), hasLength(30));

      // More letters than the slides have, but the same on every page.
      final stamped = [
        for (var p = 0; p < 30; p++)
          _page([
            ['Digitized by the Internet Archive'],
          ]),
      ];
      expect(pdfTextCoverage(stamped).pagesWithText, 0);
      expect(
        () => ingestPdfText(id: 'x', pages: stamped),
        throwsA(isA<UnsupportedDocumentException>()),
      );
    });

    test('a book with blank and picture pages here and there is not a scan', () {
      final pages = [
        for (var p = 0; p < 40; p++) p % 8 == 0 ? '' : _page([_prose(p), _prose(p + 1)]),
      ];
      expect(pdfTextCoverage(pages), (pages: 40, pagesWithText: 35, mostlyPictures: false));
    });

    test('the pages with text are told apart, for OCR to read the others', () {
      // A scan's few typed pages, a stamp on every page, and the empty string
      // after the last page break.
      final pages = [
        for (var p = 0; p < 12; p++)
          p == 0 || p == 7 ? _page([_prose(p), _prose(p + 1)]) : _page([['Digitized by Google']]),
        '',
      ];
      final withText = pdfPagesWithText(pages);
      expect(withText, hasLength(12));
      expect([for (var p = 0; p < withText.length; p++) if (withText[p]) p], [0, 7]);
      expect(pdfTextCoverage(pages), (pages: 12, pagesWithText: 2, mostlyPictures: true));
    });

    test('the layout from the platform is read as lists of numbers', () {
      expect(pdfLayoutFromPlatform(null), isNull);
      expect(pdfLayoutFromPlatform([
        [1, 2, 3, 4, 5],
        'junk',
      ]), [
        [1, 2, 3, 4, 5],
        <int>[],
      ]);
    });
  });
}

const _roman = ['i', 'ii', 'iii'];
