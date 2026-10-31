import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

List<String> _texts(List<Block> blocks) => [for (final b in blocks) b.text];

/// A PalmDOC (TEXtREAd) book: plain text in uncompressed records.
Uint8List _palmDoc(String text) {
  final body = latin1.encode(text);
  final r0 = ByteData(16)
    ..setUint16(0, 1) // no compression
    ..setUint32(4, body.length)
    ..setUint16(8, 1) // one text record
    ..setUint16(10, 4096);
  final header = ByteData(78 + 2 * 8 + 2);
  final hb = header.buffer.asUint8List();
  hb.setRange(60, 68, 'TEXtREAd'.codeUnits);
  header.setUint16(76, 2);
  const start0 = 78 + 16 + 2;
  header.setUint32(78, start0);
  header.setUint32(86, start0 + 16);
  return Uint8List.fromList([...hb, ...r0.buffer.asUint8List(), ...body]);
}

void main() {
  group('text outside block tags', () {
    test('text beside a heading is kept, split at a double line break', () {
      final blocks = blocksFromHtml(
        '<html><body><h2>One</h2>First line.<br/>Same paragraph.<br/> <br/>'
        'Second paragraph.<p>Real paragraph.</p>Tail text.</body></html>',
      );
      expect(_texts(blocks), [
        'One',
        'First line. Same paragraph.',
        'Second paragraph.',
        'Real paragraph.',
        'Tail text.',
      ]);
      expect(blocks.map((b) => b.role), [
        BlockRole.heading,
        BlockRole.paragraph,
        BlockRole.paragraph,
        BlockRole.paragraph,
        BlockRole.paragraph,
      ]);
    });

    test('loose text keeps the role of what holds it', () {
      final blocks = blocksFromHtml(
        '<html><body><blockquote>Said once.<p>Said twice.</p></blockquote>'
        '<ul><li>Item one<ul><li>Inner item</li></ul></li></ul></body></html>',
      );
      expect(_texts(blocks), ['Said once.', 'Said twice.', 'Item one', 'Inner item']);
      expect(blocks.map((b) => b.role), [
        BlockRole.quote,
        BlockRole.quote,
        BlockRole.listItem,
        BlockRole.listItem,
      ]);
    });

    test('an inline picture stays out of the sentence it sits in', () {
      final blocks = blocksFromHtml(
        '<html><body><h1>T</h1>He drew <img src="star.png" alt="a star"/> on the wall.</body></html>',
        href: 'OEBPS/ch.xhtml',
      );
      expect(_texts(blocks), ['T', 'He drew on the wall.', 'a star']);
      expect(blocks.last.role, BlockRole.figure);
    });

    test('a body of plain text becomes paragraphs', () {
      final blocks = blocksFromHtml(
        'It was a dark and stormy night.\n\nThe rain fell in torrents.\n\nNobody came.',
      );
      expect(_texts(blocks), [
        'It was a dark and stormy night.',
        'The rain fell in torrents.',
        'Nobody came.',
      ]);
    });

    test('a PalmDOC book has text to read', () {
      final book = ingestBytes(
        _palmDoc('Chapter 1\n\nThe first chapter begins here and goes on.\n\n'
            'Chapter 2\n\nThe second chapter follows it.\n'),
        filename: 'old.pdb',
      );
      expect(_texts(book.sections.expand((s) => s.blocks).toList()),
          contains('The second chapter follows it.'));
    });
  });

  group('navigation', () {
    test("a page's own contents list is not read before its text", () {
      // pandoc --toc: a nav of links to the headings, at the top.
      final blocks = blocksFromHtml('<html><body><h1 class="title">Four Parables</h1>'
          '<nav id="TOC" role="doc-toc"><ul><li><a href="#the-fox">The Fox</a></li>'
          '<li><a href="#war">War</a></li></ul></nav>'
          '<h2 id="the-fox">The Fox</h2><p>A fox looked at his shadow at sunrise.</p>'
          '<h2 id="war">War</h2><p>One night a feast was held in the palace.</p></body></html>');
      expect(_texts(blocks), [
        'Four Parables',
        'The Fox',
        'A fox looked at his shadow at sunrise.',
        'War',
        'One night a feast was held in the palace.',
      ]);
    });
  });

  group('flattening', () {
    test('a line break is a space, not glue', () {
      expect(_texts(blocksFromHtml('<p>Roses are red,<br/>Violets are blue.</p>')),
          ['Roses are red, Violets are blue.']);
    });

    test('a double line break inside a paragraph makes two', () {
      expect(_texts(blocksFromHtml('<div>First part.<br/><br/>Second part.</div>')),
          ['First part.', 'Second part.']);
    });

    test('a zero-width no-break space before a dash is not a space', () {
      // Standard Ebooks join every em dash to the word before it so.
      final joiner = String.fromCharCode(0xFEFF);
      final dash = String.fromCharCode(0x2014);
      expect(_texts(blocksFromHtml('<p>my masks were stolen$joiner${dash}the seven masks</p>')),
          ['my masks were stolen${dash}the seven masks']);
    });

    test('a heading with a line break stays one heading', () {
      final blocks = blocksFromHtml('<h1>Chapter 1<br/><br/>The Arrival</h1>');
      expect(_texts(blocks), ['Chapter 1 The Arrival']);
    });

    test('table rows are read cell by cell', () {
      final blocks = blocksFromHtml(
        '<table><tbody><tr><th>Name</th><th>Age</th></tr>'
        '<tr><td>Alice</td><td>30</td></tr><tr><td>Bob</td><td>25</td></tr></tbody></table>',
      );
      expect(_texts(blocks), ['Name Age', 'Alice 30', 'Bob 25']);
      expect(blocks.every((b) => b.role == BlockRole.table), isTrue);
    });

    test('ruby readings are not read twice', () {
      final kan = String.fromCharCode(0x6F22);
      final ji = String.fromCharCode(0x5B57);
      final blocks = blocksFromHtml(
        '<p><ruby>$kan<rp>(</rp><rt>kan</rt><rp>)</rp>$ji<rt>ji</rt></ruby> is a word.</p>',
      );
      expect(_texts(blocks), ['$kan$ji is a word.']);
    });

    test('named entities in XHTML are decoded', () {
      final blocks = blocksFromHtml(
        '<html><body><p>caf&eacute;&nbsp;au&mdash;lait &hellip; it&rsquo;s</p></body></html>',
      );
      expect(blocks.single.text,
          'caf${String.fromCharCode(0xE9)} au${String.fromCharCode(0x2014)}lait '
          '${String.fromCharCode(0x2026)} it${String.fromCharCode(0x2019)}s');
    });

    test('the tag-soup fallback decodes HTML4 and HTML5 entities', () {
      final blocks = lenientHtmlBlocks(
        '<p>caf&eacute; &sect;3 &frac12; &euro;5 &check;<br>next line<p>Roses<br><br>Violets',
      );
      expect(_texts(blocks), [
        'caf${String.fromCharCode(0xE9)} ${String.fromCharCode(0xA7)}3 '
            '${String.fromCharCode(0xBD)} ${String.fromCharCode(0x20AC)}5 '
            '${String.fromCharCode(0x2713)} next line',
        'Roses',
        'Violets',
      ]);
    });

    test('FB2 titles and table cells keep their word breaks', () {
      const xml = '<?xml version="1.0" encoding="utf-8"?>'
          '<FictionBook><description><title-info><book-title>Trip</book-title>'
          '</title-info></description><body>'
          '<section><title><p>Chapter 1</p><p>The Arrival</p></title>'
          '<p>They came by night.</p>'
          '<table><tr><td>Alice</td><td>30</td></tr></table></section>'
          '<section><title><p>Chapter 2.</p><p>The Return</p></title><p>They left.</p></section>'
          '</body></FictionBook>';
      final book = ingestBytes(Uint8List.fromList(utf8.encode(xml)), filename: 't.fb2');
      expect(book.sections.map((s) => s.displayTitle), ['Chapter 1: The Arrival', 'Chapter 2. The Return']);
      expect(_texts(book.sections.first.blocks), ['Chapter 1', 'The Arrival', 'They came by night.', 'Alice 30']);
      expect(book.sections.first.blocks.take(2).map((b) => b.role), [BlockRole.heading, BlockRole.heading]);
    });

    test('decodeEntities knows more than a handful of names', () {
      expect(decodeEntities('&Agrave;&thorn;&alpha;&larr;&amp;'),
          String.fromCharCodes([0xC0, 0xFE, 0x3B1, 0x2190, 0x26]));
    });
  });

  group("a transcriber's notes", () {
    test("Project Gutenberg's box at the end is not read, nor in a Kindle copy with its classes renamed", () {
      for (final cls in ['', ' class="calibre24"']) {
        final blocks = blocksFromHtml(
          '<html><body><div><p>And the tarn closed over the House of Usher.</p></div>'
          '<div$cls style="margin-top: 5%; border: 1px solid;">'
          '<div style="font-size: large; text-align: center;"><b>Transcriber’s Notes</b></div>'
          '<ul><li>New original cover art included with this eBook is granted to the public domain.</li></ul>'
          '</div><div style="text-align:center"/></body></html>',
        );
        expect(_texts(blocks), ['And the tarn closed over the House of Usher.']);
      }
    });

    test('notes under a heading go as far as the next heading, of any level', () {
      // Changed on purpose: they ran to the next heading as high as their
      // title, and a chapter set a level lower went with them.
      final blocks = blocksFromHtml(
        '<html><body><h2>TRANSCRIBER’S NOTES</h2>'
        '<p>Obvious printing errors have been corrected.</p><h2>Chapter One</h2><p>The lamp was lit at dusk.</p>'
        '<p>The transcriber’s notes were lost in the fire, the keeper said.</p></body></html>',
      );
      expect(_texts(blocks), [
        'Chapter One',
        'The lamp was lit at dusk.',
        'The transcriber’s notes were lost in the fire, the keeper said.',
      ]);
    });

    test('a chapter a level below their title is read', () {
      final blocks = blocksFromHtml(
        '<html><body><h2>Transcriber’s Note</h2><p>The spelling of the original is kept.</p>'
        '<h3>I.</h3><p>The Time Traveller (for so it will be convenient to speak of him) was expounding a '
        'recondite matter to us.</p><p>His grey eyes shone and twinkled.</p></body></html>',
      );
      expect(_texts(blocks), [
        'I.',
        'The Time Traveller (for so it will be convenient to speak of him) was expounding a recondite matter to us.',
        'His grey eyes shone and twinkled.',
      ]);
    });

    test('a section of its own, or a rule across the page, ends them', () {
      final section = blocksFromHtml(
        '<html><body><p><b>Transcriber’s Notes</b></p><p>Hyphenation has been made consistent.</p>'
        '<section><p>The road ran down to the harbour.</p></section></body></html>',
      );
      expect(_texts(section), ['The road ran down to the harbour.']);
      final rule = blocksFromHtml(
        '<html><body><p><b>Transcriber’s Notes</b></p><p>Hyphenation has been made consistent.</p>'
        '<hr/><p>The road ran down to the harbour.</p></body></html>',
      );
      expect(_texts(rule), ['The road ran down to the harbour.']);
    });

    test('no further than notes run: text past that is kept, between blocks too', () {
      final page = 'The road ran down to the harbour, where the boats lay drawn up in a row. ' * 60;
      final blocks = blocksFromHtml(
        '<html><body><div><b>Transcriber’s Notes</b></div><p>Hyphenation has been made consistent.</p>'
        '<p>$page</p><p>The lamp was lit at dusk.</p></body></html>',
      );
      expect(_texts(blocks), [page.trim(), 'The lamp was lit at dusk.']);
      // The book as text straight in the page, after the title: once
      // dropped whole, uncounted.
      final loose = blocksFromHtml(
        '<html><body><h2>Transcriber’s Notes</h2>Hyphenation has been made consistent.<br/><br/>'
        '$page<p>The lamp was lit at dusk.</p></body></html>',
      );
      expect(_texts(loose).join(' '), contains('The road ran down to the harbour'));
      expect(_texts(loose).last, 'The lamp was lit at dusk.');
    });

    test('a paragraph that is a transcriber’s note is not read; the chapter it opens is', () {
      final blocks = blocksFromHtml(
        '<html><body><div class="chapter"><p class="tn">Transcriber\'s Note: The spelling of the original '
        'is kept.</p><h2>Chapter One</h2><p>The lamp was lit at dusk.</p></div></body></html>',
      );
      expect(_texts(blocks), ['Chapter One', 'The lamp was lit at dusk.']);
    });
  });
}
