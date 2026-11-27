// Highlights from other reading apps: Kindle's My Clippings.txt and
// KOReader's notes beside a book, read, and placed in the library's books.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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

  group("Kobo's KoboReader.sqlite", () {
    test("highlights and notes with their book's title and author; dog-ears and hidden ones left out", () {
      final dir = Directory.systemTemp.createTempSync('tv_kobo');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/KoboReader.sqlite';
      final db = sqlite3.open(path);
      db.execute('CREATE TABLE content (ContentID TEXT, Title TEXT, Attribution TEXT)');
      db.execute('CREATE TABLE Bookmark (BookmarkID TEXT, VolumeID TEXT, ContentID TEXT, Text TEXT, Annotation TEXT, '
          'DateCreated TEXT, ChapterProgress REAL, Hidden TEXT, Type TEXT)');
      db.execute("INSERT INTO content VALUES ('uuid-1', 'The Hobbit', 'J. R. R. Tolkien')");
      final add = db.prepare('INSERT INTO Bookmark VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)');
      add.execute(['a', 'uuid-1', 'uuid-1!c1', 'In a hole in the ground there lived a hobbit.', 'First line', '2025-03-03T21:14:05.000', 0.1, 'false', 'note']);
      add.execute(['b', 'uuid-1', 'uuid-1!c1', null, null, '2025-03-03T21:20:00.000', 0.5, 'false', 'dogear']);
      add.execute(['c', 'uuid-1', 'uuid-1!c2', 'Hidden away.', null, '2025-03-04T10:00:00.000', 0.2, 'true', 'highlight']);
      add.execute(['d', 'file:///mnt/onboard/Herbert/Dune - Frank Herbert.epub', 'x', 'Fear is the mind-killer.', null, '2025-03-05T09:00:00.000', 0.3, 'false', 'highlight']);
      add.close();
      db.close();

      final h = readKoboDatabase(path);
      expect(h.map((e) => (e.title, e.author, e.text, e.note)), [
        ('Dune', '', 'Fear is the mind-killer.', null),
        ('The Hobbit', 'J. R. R. Tolkien', 'In a hole in the ground there lived a hobbit.', 'First line'),
      ]);
      expect(h.last.added, DateTime(2025, 3, 3, 21, 14, 5));
    });
  });

  group("Libby's reading journey", () {
    test('its highlights, notes and when, with the book; a note without words kept as a note', () {
      final raw = jsonEncode({
        'version': 1,
        'readingJourney': {
          'title': {'text': 'How to Take Smart Notes', 'titleId': '5796521'},
          'author': 'Sönke Ahrens',
        },
        'highlights': [
          {'timestamp': 1729898852000, 'chapter': '13       Share', 'percent': 0.82, 'color': '#FFB', 'quote': 'For every document I write.'},
          {'timestamp': 1729898900000, 'quote': 'Writing is thinking.', 'note': 'Yes.'},
          {'timestamp': 1729899000000, 'note': 'A thought of my own.'},
        ],
      });
      final h = parseLibbyJourney(raw);
      expect(h.map((e) => (e.title, e.author, e.text, e.note)), [
        ('How to Take Smart Notes', 'Sönke Ahrens', 'For every document I write.', null),
        ('How to Take Smart Notes', 'Sönke Ahrens', 'Writing is thinking.', 'Yes.'),
        ('How to Take Smart Notes', 'Sönke Ahrens', '', 'A thought of my own.'),
      ]);
      expect(h.first.added, DateTime.fromMillisecondsSinceEpoch(1729898852000));
      expect(parseLibbyJourney('not json'), isEmpty);
    });
  });

  group("Google Play Books' notes Doc", () {
    const md = '| ![Cover Image][image1] | *The Art of Thinking Clearly* Rolf Dobelli HarperCollins |\n'
        '| :---- | :---- |\n'
        '| This document is overwritten when you make changes in Play Books. |\n'
        '# Annotations by color\n'
        '## *Yellow*\n'
        "|  *![][image2] The unsuccessful don't write books.* Harsh reality April 27, 2021 [13](http://play.google.com/books/reader?id=x&pg=GBS.PA13) |\n"
        '| ----- |\n'
        '# All your annotations\n'
        '## *1: Survivorship Bias*\n'
        "|  *![][image2] The unsuccessful don't write books.* Harsh reality April 27, 2021 [13](http://play.google.com/books/reader?id=x&pg=GBS.PA13) |\n"
        '|  *![][image3] Costs 10\\\$ more.* May 2, 2021 [20](http://play.google.com/books/reader?id=x&pg=GBS.PA20) |\n'
        '|  May 3, 2021 [21](http://play.google.com/books/reader?id=x&pg=GBS.PA21) |\n';

    test('downloaded as Markdown: the title and author, each highlight once with its note; a bookmark left out', () {
      final h = parsePlayBooksNotes(utf8.encode(md), fileName: 'Notes from The Art of Thinking Clearly.md');
      expect(h.map((e) => (e.title, e.author, e.text, e.note)), [
        ('The Art of Thinking Clearly', 'Rolf Dobelli', "The unsuccessful don't write books.", 'Harsh reality'),
        ('The Art of Thinking Clearly', 'Rolf Dobelli', r'Costs 10$ more.', null),
      ]);
    });

    test('downloaded as Word: the same, from its table cells and italic runs', () {
      String run(String t, {bool italic = false}) =>
          '<w:r>${italic ? '<w:rPr><w:i/></w:rPr>' : ''}<w:t xml:space="preserve">$t</w:t></w:r>';
      String cell(String runs) => '<w:tc><w:p>$runs</w:p></w:tc>';
      final xml = '<w:document><w:body><w:tbl><w:tr>${cell('')}${cell(run('The Art of Thinking Clearly', italic: true) + run(' Rolf Dobelli'))}</w:tr></w:tbl>'
          '<w:tbl><w:tr>${cell('${run('The unsuccessful don&apos;t write books.', italic: true)}${run(' Harsh reality ')}${run('April 27, 2021 ')}<w:hyperlink>${run('13')}</w:hyperlink>')}</w:tr></w:tbl>'
          '</w:body></w:document>';
      final zip = Archive()..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(xml)));
      final h = parsePlayBooksNotes(ZipEncoder().encodeBytes(zip), fileName: 'Notes.docx');
      expect(h.map((e) => (e.title, e.author, e.text, e.note)), [
        ('The Art of Thinking Clearly', 'Rolf Dobelli', "The unsuccessful don't write books.", 'Harsh reality'),
      ]);
    });
  });
}
