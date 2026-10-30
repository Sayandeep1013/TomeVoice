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
