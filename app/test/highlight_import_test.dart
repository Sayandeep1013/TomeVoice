// Highlights from other reading apps: Kindle's My Clippings.txt and
// KOReader's notes beside a book, read, and placed in the library's books.

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/highlight_import.dart';

const _clippings = '\uFEFFThe Hobbit (Tolkien, J. R. R.)\r\n'
    '- Your Highlight on page 12 | Location 170-172 | Added on Monday, 3 March 2025 21:14:05\r\n'
    '\r\n'
    'In a hole in the ground there lived a hobbit.\r\n'
    '==========\r\n'
    'The Hobbit (Tolkien, J. R. R.)\r\n'
    '- Your Note on page 12 | Location 172 | Added on Monday, 3 March 2025 21:15:00\r\n'
    '\r\n'
    'The first line!\r\n'
    '==========\r\n'
    'The Hobbit (Tolkien, J. R. R.)\r\n'
    '- Your Bookmark on page 30 | Location 400 | Added on Monday, 3 March 2025 21:20:00\r\n'
    '\r\n'
    '\r\n'
    '==========\r\n'
    'The Hobbit (Tolkien, J. R. R.)\r\n'
    '- Your Highlight on page 12 | Location 170-171 | Added on Monday, 3 March 2025 21:13:00\r\n'
    '\r\n'
    'In a hole in the ground\r\n'
    '==========\r\n'
    'Dune (Frank Herbert)\r\n'
    '- Your Highlight at location 1020-1021 | Added on Tuesday, March 4, 2025 9:14:05 PM\r\n'
    '\r\n'
    'Fear is the mind-killer.\r\n'
    '==========\r\n';

const _sidecar = '''-- we can read Lua syntax here!
return {
    ["annotations"] = {
        [1] = {
            ["chapter"] = "Chapter 1",
            ["datetime"] = "2025-03-03 21:14:05",
            ["drawer"] = "lighten",
            ["pos0"] = "/body/DocFragment[2]/body/p[1]/text().0",
            ["pos1"] = "/body/DocFragment[2]/body/p[1]/text().44",
            ["text"] = "In a hole in the ground there lived a hobbit.",
            ["note"] = "Says \\"hole\\" twice\\nwith a line break",
        },
        [2] = {
            ["datetime"] = "2025-03-03 21:20:00",
            ["page"] = "/body/DocFragment[3]/body/p[4]/text().0",
            ["text"] = "in. 30",
        },
    },
    ["doc_props"] = {
        ["authors"] = "J. R. R. Tolkien",
        ["title"] = "The Hobbit",
    },
    ["percent_finished"] = 0.25,
    summary = { status = "reading" },
}
''';

Speakable _s(int i, String text) =>
    Speakable(sectionIndex: 0, blockIndex: i, sentenceIndex: 0, text: text, role: BlockRole.paragraph, blockId: 'b$i');

void main() {
  group("Kindle's My Clippings.txt", () {
    test('highlights with their notes; bookmarks left out; a highlight made again kept once, its longest', () {
      final h = parseKindleClippings(_clippings);
      expect(h.map((e) => (e.title, e.author, e.text)), [
        ('The Hobbit', 'J. R. R. Tolkien', 'In a hole in the ground there lived a hobbit.'),
        ('Dune', 'Frank Herbert', 'Fear is the mind-killer.'),
      ]);
      expect(h.first.note, 'The first line!', reason: 'the note at the highlight\'s last location');
      expect(h.first.added, DateTime(2025, 3, 3));
      expect(h.last.added, DateTime(2025, 3, 4));
      expect(h.last.location, '1020-1021');
    });

    test('a file with nothing of the kind gives nothing', () {
      expect(parseKindleClippings('just some words\nand more'), isEmpty);
    });
  });

  group("KOReader's sidecar", () {
    test('highlights and their notes, its title and author; a bookmark left out', () {
      final h = parseKoreaderSidecar(_sidecar);
      expect(h, hasLength(1));
      expect(h.single.title, 'The Hobbit');
      expect(h.single.author, 'J. R. R. Tolkien');
      expect(h.single.text, 'In a hole in the ground there lived a hobbit.');
      expect(h.single.note, 'Says "hole" twice\nwith a line break');
      expect(h.single.added, DateTime(2025, 3, 3, 21, 14, 5));
    });

    test('the title from its folder when the sidecar has none', () {
      final h = parseKoreaderSidecar(
        'return { ["annotations"] = { { ["pos0"] = "a", ["text"] = "Words." } } }',
        fileName: '/sdcard/Books/Dune.sdr/metadata.epub.lua',
      );
      expect(h.single.title, 'Dune');
    });

    test('Lua tables: lists, nested tables, numbers, long strings', () {
      expect(LuaTable.parse('return { 1, 2.5, -3, 0x10, true, nil, [[long\nstring]] }'),
          [1, 2.5, -3, 16, true, null, 'long\nstring']);
      expect(LuaTable.parse('return { a = { ["b"] = "c" } }'), {
        'a': {'b': 'c'},
      });
      expect(LuaTable.parse('not lua at all {'), isNull);
    });
  });

  group('placing them', () {
    final units = [
      _s(0, 'Chapter One'),
      _s(1, 'In a hole in the ground there lived a hobbit.'),
      _s(2, 'Not a nasty, dirty, wet hole.'),
      _s(3, 'It was a hobbit-hole, and that means comfort.'),
    ];

    test('at the sentence its words start in, over as many as it runs', () {
      expect(placeIn(units, 'In a hole in the ground there lived a hobbit.'), (unit: 1, span: 1));
      expect(placeIn(units, 'Not a nasty, dirty, wet hole. It was a hobbit-hole'), (unit: 2, span: 2));
      // Curly quotes, dashes and line breaks do not matter.
      expect(placeIn(units, 'It was a hobbit\u2011hole,\nand that means comfort'), (unit: 3, span: 1));
    });

    test('words this edition does not have: nowhere', () {
      expect(placeIn(units, 'Fear is the mind-killer.'), isNull);
      expect(placeIn(units, '   '), isNull);
    });
  });
}
