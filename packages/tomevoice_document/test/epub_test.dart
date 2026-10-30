import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'epub_fixture.dart';

/// encryption.xml with one entry per (algorithm, uri).
String _encryption(List<(String, String)> entries) => '''<?xml version="1.0"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
${[for (final (alg, uri) in entries) '<enc:EncryptedData><enc:EncryptionMethod Algorithm="$alg"/><enc:CipherData><enc:CipherReference URI="$uri"/></enc:CipherData></enc:EncryptedData>'].join('\n')}
</encryption>''';

const _idpf = 'http://www.idpf.org/2008/embedding';
const _adobe = 'http://ns.adobe.com/pdf/enc#RC';
const _aes = 'http://www.w3.org/2001/04/xmlenc#aes128-cbc';

Map<String, Object> _fontBook(String encryption) => {
      'META-INF/encryption.xml': encryption,
      'OEBPS/content.opf': opfOf([
        ('c1', 'ch1.xhtml', 'application/xhtml+xml', null),
        ('f1', 'fonts/Old Style.ttf', 'application/vnd.ms-opentype', null),
        ('f2', 'fonts/b.woff', 'font/woff', null),
      ], ['c1']),
      'OEBPS/ch1.xhtml': xhtml('<h1>One</h1>${chapterText('Chapter one')}'),
      'OEBPS/fonts/Old Style.ttf': [0, 1, 2, 3],
      'OEBPS/fonts/b.woff': [4, 5, 6, 7],
    };

List<String> _chapterTitles(Book book) {
  final layout = ReadingLayout.build(book);
  return [for (var c = 0; c < layout.chapters.length; c++) layout.chapterTitle(c)];
}

void main() {
  group('chapters that disappeared', () {
    test('hrefs with %-escapes are decoded', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('c1', 'Text/Chapter%201.xhtml', 'application/xhtml+xml', null),
            ('c2', 'Text/Chapter%202.xhtml', 'application/xhtml+xml', null),
          ], ['c1', 'c2']),
          'OEBPS/Text/Chapter 1.xhtml': xhtml('<h1>One</h1>${chapterText('Chapter one')}'),
          'OEBPS/Text/Chapter 2.xhtml': xhtml('<h1>Two</h1>${chapterText('Chapter two')}'),
        }),
        filename: 'spaces.epub',
      );
      expect(book.sections.map((s) => s.title), ['One', 'Two']);
    });

    test('"Cover Story" in a collection is a story, not a cover', () {
      // One near the front (long, as stories are), one in the middle.
      final stories = [
        for (var i = 1; i <= 12; i++)
          i == 1
              ? 'Cover Girl'
              : i == 7
                  ? 'Cover Story'
                  : 'Story number $i',
      ];
      String body(int i) => i == 0 ? chapterText(stories[i]) * 12 : chapterText(stories[i]);
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('cover', 'cover.xhtml', 'application/xhtml+xml', null),
            ('toc', 'toc.xhtml', 'application/xhtml+xml', null),
            for (var i = 0; i < stories.length; i++) ('s$i', 's$i.xhtml', 'application/xhtml+xml', null),
            ('legal', 'legal.xhtml', 'application/xhtml+xml', null),
          ], ['cover', 'toc', for (var i = 0; i < stories.length; i++) 's$i', 'legal']),
          'OEBPS/cover.xhtml': xhtml('<p>Cover</p>'),
          'OEBPS/toc.xhtml': xhtml('<h1>Contents</h1>${[for (final s in stories) '<p>$s</p>'].join()}'),
          for (var i = 0; i < stories.length; i++) 'OEBPS/s$i.xhtml': xhtml('<h2>${stories[i]}</h2>${body(i)}'),
          'OEBPS/legal.xhtml': xhtml('<p>Copyright 2001 by the author. All rights reserved. ISBN 0-00-000000-0.</p>'),
        }),
        filename: 'collection.epub',
      );
      final titles = _chapterTitles(book);
      expect(titles, containsAll(['Cover Girl', 'Cover Story']));
      expect(titles, hasLength(12), reason: 'cover, contents and copyright are still hidden');
    });

    test('linear="no" items leave the reading order but stay in the book', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('c1', 'c1.xhtml', 'application/xhtml+xml', null),
            ('answers', 'answers.xhtml', 'application/xhtml+xml', null),
            ('c2', 'c2.xhtml', 'application/xhtml+xml', null),
          ], ['c1', 'answers|no', 'c2']),
          'OEBPS/c1.xhtml': xhtml('<h1>One</h1>${chapterText('Chapter one')}'),
          'OEBPS/answers.xhtml': xhtml('<h1>Answers</h1>${chapterText('The answers')}'),
          'OEBPS/c2.xhtml': xhtml('<h1>Two</h1>${chapterText('Chapter two')}'),
        }),
        filename: 'quiz.epub',
      );
      expect(book.sections.map((s) => s.title), ['One', 'Two', 'Answers']);
      expect(_chapterTitles(book), ['One', 'Two', 'Answers']);
    });
  });

  group('chapters follow the contents', () {
    String nav(String items) => xhtml('<nav epub:type="toc"><ol>$items</ol></nav>');
    const x = 'application/xhtml+xml';

    test('one file with five anchors is five chapters', () {
      final body = [
        for (var i = 1; i <= 5; i++) '<h2 id="ch$i">Chapter $i</h2>${chapterText('Chapter $i')}',
      ].join();
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([('nav', 'nav.xhtml', x, 'nav'), ('all', 'all.xhtml', x, null)], ['all']),
          'OEBPS/nav.xhtml': nav([for (var i = 1; i <= 5; i++) '<li><a href="all.xhtml#ch$i">Chapter $i</a></li>'].join()),
          'OEBPS/all.xhtml': xhtml(body),
        }),
        filename: 'one-file.epub',
      );
      expect(_chapterTitles(book), ['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4', 'Chapter 5']);
      expect(book.sections.map((s) => s.blocks.first.text), ['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4', 'Chapter 5']);
    });

    test('a nested contents names chapters with their part', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('nav', 'nav.xhtml', x, 'nav'),
            for (final f in ['p1', 'a1', 'a2', 'p2', 'b1', 'b2']) (f, '$f.xhtml', x, null),
          ], ['p1', 'a1', 'a2', 'p2', 'b1', 'b2']),
          'OEBPS/nav.xhtml': nav('<li><a href="p1.xhtml">Part I</a><ol>'
              '<li><a href="a1.xhtml">I</a></li><li><a href="a2.xhtml">II</a></li></ol></li>'
              '<li><span>Part II</span><ol>'
              '<li><a href="b1.xhtml">I</a></li><li><a href="b2.xhtml">II</a></li></ol></li>'),
          'OEBPS/p1.xhtml': xhtml('<h1>Part I</h1>'),
          'OEBPS/a1.xhtml': xhtml('<h2>I</h2>${chapterText('Part one, first')}'),
          'OEBPS/a2.xhtml': xhtml('<h2>II</h2>${chapterText('Part one, second')}'),
          'OEBPS/p2.xhtml': xhtml('<h1>Part II</h1>'),
          'OEBPS/b1.xhtml': xhtml('<h2>I</h2>${chapterText('Part two, first')}'),
          'OEBPS/b2.xhtml': xhtml('<h2>II</h2>${chapterText('Part two, second')}'),
        }),
        filename: 'parts.epub',
      );
      expect(_chapterTitles(book), ['Part I · I', 'Part I · II', 'Part II · I', 'Part II · II']);
    });

    test('a flat contents with parts, and a chapter it forgot (Crime and Punishment)', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('nav', 'nav.xhtml', x, 'nav'),
            for (final f in ['d1', 'c1', 'c2', 'c3', 'c4', 'c5', 'end']) (f, '$f.xhtml', x, null),
          ], ['d1', 'c1', 'c2', 'c3', 'c4', 'c5', 'end']),
          'OEBPS/nav.xhtml': nav('<li><a href="d1.xhtml">PART I</a></li>'
              '<li><a href="c1.xhtml">CHAPTER I</a></li><li><a href="c2.xhtml">CHAPTER II</a></li>'
              '<li><a href="c3.xhtml">PART II</a></li><li><a href="c3.xhtml">CHAPTER I</a></li>'
              '<li><a href="c5.xhtml">CHAPTER III</a></li><li><a href="end.xhtml">EPILOGUE</a></li>'),
          'OEBPS/d1.xhtml': xhtml('<h1>●</h1>'),
          for (final (f, h) in [('c1', 'I'), ('c2', 'II'), ('c3', 'I'), ('c4', 'II'), ('c5', 'III'), ('end', 'EPILOGUE')])
            'OEBPS/$f.xhtml': xhtml('<h2>$h</h2>${chapterText('Chapter $f')}'),
        }),
        filename: 'crime.epub',
      );
      expect(_chapterTitles(book), [
        'PART I · CHAPTER I',
        'PART I · CHAPTER II',
        'PART II · CHAPTER I',
        'PART II · II',
        'PART II · CHAPTER III',
        'EPILOGUE',
      ]);
    });

    test('an NCX outside the package folder resolves from its own folder', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('ncx', '../toc.ncx', 'application/x-dtbncx+xml', null),
            ('c1', 'c1.xhtml', x, null),
            ('c2', 'c2.xhtml', x, null),
          ], ['c1', 'c2'], toc: 'ncx'),
          'toc.ncx': '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
              '<navPoint id="a"><navLabel><text>The Start</text></navLabel><content src="OEBPS/c1.xhtml"/></navPoint>'
              '<navPoint id="b"><navLabel><text>The End</text></navLabel><content src="OEBPS/c2.xhtml"/></navPoint>'
              '</navMap></ncx>',
          'OEBPS/c1.xhtml': xhtml('<h2>1</h2>${chapterText('Chapter one')}'),
          'OEBPS/c2.xhtml': xhtml('<h2>2</h2>${chapterText('Chapter two')}'),
        }),
        filename: 'ncx.epub',
      );
      expect(_chapterTitles(book), ['The Start', 'The End']);
    });

    test('a nested NCX', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('ncx', 'toc.ncx', 'application/x-dtbncx+xml', null),
            ('c1', 'c1.xhtml', x, null),
            ('c2', 'c2.xhtml', x, null),
          ], ['c1', 'c2'], toc: 'ncx'),
          'OEBPS/toc.ncx': '<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
              '<navPoint id="p"><navLabel><text>Book One</text></navLabel><content src="c1.xhtml"/>'
              '<navPoint id="a"><navLabel><text>Chapter 1</text></navLabel><content src="c1.xhtml"/></navPoint>'
              '<navPoint id="b"><navLabel><text>Chapter 2</text></navLabel><content src="c2.xhtml"/></navPoint>'
              '</navPoint></navMap></ncx>',
          'OEBPS/c1.xhtml': xhtml('<h2>1</h2>${chapterText('Chapter one')}'),
          'OEBPS/c2.xhtml': xhtml('<h2>2</h2>${chapterText('Chapter two')}'),
        }),
        filename: 'ncx.epub',
      );
      expect(_chapterTitles(book), ['Book One · Chapter 1', 'Book One · Chapter 2']);
    });

    test('a part line before a chapter\'s anchor is read with the chapter, not lost', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([('nav', 'nav.xhtml', x, 'nav'), ('all', 'all.xhtml', x, null)], ['all']),
          'OEBPS/nav.xhtml': nav('<li><a href="all.xhtml#c1">Chapter 1</a></li><li><a href="all.xhtml#c2">Chapter 2</a></li>'),
          'OEBPS/all.xhtml': xhtml('<h1>PART ONE</h1><h2 id="c1">Chapter 1</h2>${chapterText('One')}'
              '<h2 id="c2">Chapter 2</h2>${chapterText('Two')}'),
        }),
        filename: 'part-line.epub',
      );
      final units = ReadingLayout.build(book).units;
      expect(units.first.text, 'PART ONE');
      expect(_chapterTitles(book), ['Chapter 1', 'Chapter 2']);
    });

    test('chapter titles that merely start with "Volume 1" are not parts', () {
      final book = ingestBytes(
        epubOf({
          'OEBPS/content.opf': opfOf([
            ('nav', 'nav.xhtml', x, 'nav'),
            for (var i = 1; i <= 3; i++) ('c$i', 'c$i.xhtml', x, null),
          ], ['c1', 'c2', 'c3']),
          'OEBPS/nav.xhtml': nav([for (var i = 1; i <= 3; i++) '<li><a href="c$i.xhtml">Volume 1 Chapter $i: Name</a></li>'].join()),
          for (var i = 1; i <= 3; i++) 'OEBPS/c$i.xhtml': xhtml('<h2>V1C$i</h2>${chapterText('Chapter $i')}'),
        }),
        filename: 'web.epub',
      );
      expect(_chapterTitles(book), [for (var i = 1; i <= 3; i++) 'Volume 1 Chapter $i: Name']);
    });
  });

  group('books that cannot be read', () {
    test('an EPUB of pictures only is refused, as a scanned PDF is', () {
      expect(
        () => ingestBytes(
          epubOf({
            'OEBPS/content.opf': opfOf([
              ('p1', 'p1.xhtml', 'application/xhtml+xml', null),
              ('p2', 'p2.xhtml', 'application/xhtml+xml', null),
            ], ['p1', 'p2']),
            'OEBPS/p1.xhtml': xhtml('<div><img src="1.jpg" alt="Page 1"/></div>'),
            'OEBPS/p2.xhtml': xhtml('<div><img src="2.jpg" alt="Page 2"/></div>'),
          }),
          filename: 'comic.epub',
        ),
        throwsA(isA<UnsupportedDocumentException>().having((e) => e.message, 'message', contains('pictures'))),
      );
    });

    test('a broken container.xml is a plain message, not a parser error', () {
      // The rootfile path's quote closes early: container.xml is not XML.
      final broken = epubOf({'OEBPS/content.opf': opfOf([], [])}, opfPath: 'OEBPS/content.opf" <<<');
      expect(
        () => ingestBytes(broken, filename: 'broken.epub'),
        throwsA(isA<ParseException>()
            .having((e) => e.message, 'message', contains('damaged'))
            .having((e) => e.message, 'message', isNot(contains('Xml')))),
      );
    });

    test('a zip that is not a zip says so plainly', () {
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...List.filled(40, 7)]);
      expect(
        () => ingestBytes(bytes, filename: 'cut.epub'),
        throwsA(isA<ParseException>().having((e) => e.message, 'message', isNot(contains('Exception')))),
      );
    });

    test('a cut-off Kindle book gives a message, not a RangeError', () {
      final bytes = Uint8List(100);
      bytes.setRange(60, 68, 'BOOKMOBI'.codeUnits);
      bytes[76] = 0x00;
      bytes[77] = 0x05; // five records, but the file ends first
      expect(
        () => ingestBytes(bytes, filename: 'cut.mobi'),
        throwsA(isA<ParseException>().having((e) => e.message, 'message', contains('damaged'))),
      );
    });
  });

  group('encryption.xml', () {
    test('obfuscated fonts are not DRM: the book opens', () {
      final book = ingestBytes(
        epubOf(_fontBook(_encryption([(_idpf, 'OEBPS/fonts/Old%20Style.ttf'), (_adobe, 'OEBPS/fonts/b.woff')]))),
        filename: 'fonts.epub',
      );
      expect(book.sections.first.blocks.first.text, 'One');
    });

    test('an encrypted chapter is DRM', () {
      expect(
        () => ingestBytes(epubOf(_fontBook(_encryption([(_aes, 'OEBPS/ch1.xhtml')]))), filename: 'drm.epub'),
        throwsA(isA<EncryptedDocumentException>()),
      );
    });

    test('font obfuscation applied to a chapter is still refused', () {
      expect(
        () => ingestBytes(epubOf(_fontBook(_encryption([(_idpf, 'OEBPS/ch1.xhtml')]))), filename: 'odd.epub'),
        throwsA(isA<EncryptedDocumentException>()),
      );
    });

    test('an unknown algorithm on a font is refused', () {
      expect(
        () => ingestBytes(epubOf(_fontBook(_encryption([(_aes, 'OEBPS/fonts/b.woff')]))), filename: 'odd.epub'),
        throwsA(isA<EncryptedDocumentException>()),
      );
    });

    test('an empty encryption.xml encrypts nothing', () {
      final book = ingestBytes(epubOf(_fontBook('<encryption/>')), filename: 'empty.epub');
      expect(book.sections, isNotEmpty);
    });
  });

  group('the series a book says it is in', () {
    BookMetadata metadataWith(String meta) => ingestBytes(
          epubOf({
            'OEBPS/content.opf': opfOf([('c1', 'ch1.xhtml', 'application/xhtml+xml', null)], ['c1'], meta: meta),
            'OEBPS/ch1.xhtml': xhtml('<h1>One</h1>${chapterText('Chapter one')}'),
          }),
          filename: 'series.epub',
        ).metadata;

    test("calibre's series, with its number", () {
      final m = metadataWith('<meta name="calibre:series" content="A Song of Ice and Fire"/>'
          '<meta name="calibre:series_index" content="3.0"/>');
      expect((m.series, m.seriesIndex), ('A Song of Ice and Fire', 3.0));
    });

    test("EPUB 3's collection, when it is a series and not a set", () {
      final m = metadataWith('<meta property="belongs-to-collection" id="c01">The Expanse</meta>'
          '<meta refines="#c01" property="collection-type">series</meta>'
          '<meta refines="#c01" property="group-position">1.5</meta>');
      expect((m.series, m.seriesIndex), ('The Expanse', 1.5));
      final set = metadataWith('<meta property="belongs-to-collection" id="c02">Penguin Classics</meta>'
          '<meta refines="#c02" property="collection-type">set</meta>');
      expect(set.series, isNull);
    });

    test('a book in no series has none, and one stored keeps its series', () {
      expect(metadataWith('').series, isNull);
      final m = metadataWith('<meta name="calibre:series" content="Discworld"/>');
      expect((m.series, m.seriesIndex), ('Discworld', null));
      final stored = BookMetadata.fromJson(
        Map<String, Object?>.from(m.copyWith(title: 'Mort').toJson()),
      );
      expect((stored.title, stored.series), ('Mort', 'Discworld'));
    });
  });
}
