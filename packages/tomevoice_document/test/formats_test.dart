import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    final data = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

List<String> _texts(Book b) => [
      for (final s in b.sections)
        for (final bl in s.blocks) bl.text,
    ];

void main() {
  group('segmentation beyond English', () {
    test('Bengali danda ends a sentence', () {
      const t = 'আমি বাড়ি যাই। তুমি কোথায় যাও? সে বলল, ভালো।';
      final s = segmentSentences(t);
      expect(s, hasLength(3));
      expect(s.first.of(t), 'আমি বাড়ি যাই।');
    });

    test('a period before a non-Latin word still splits', () {
      const t = 'Он пришёл. Она ушла.';
      expect(segmentSentences(t), hasLength(2));
    });

    test('lowercase after ! continues the sentence', () {
      const t = '“Help!” he cried. Nobody came.';
      final s = segmentSentences(t);
      expect(s, hasLength(2));
      expect(s.first.of(t), '“Help!” he cried.');
    });

    test('initials and decimals stay whole', () {
      const t = 'A. C. Doyle paid 3.50 for it. Then left.';
      expect(segmentSentences(t), hasLength(2));
    });

    test('very long sentences are split at a clause boundary', () {
      final t = List.filled(30, 'this clause goes on and on,').join(' ');
      final s = segmentSentences(t);
      expect(s.length, greaterThan(1));
      for (final x in s) {
        expect(x.endOffset - x.startOffset, lessThanOrEqualTo(maxSentenceChars));
      }
      expect(s.first.of(t).endsWith(','), isTrue);
    });
  });

  group('language', () {
    test('script beats metadata', () {
      expect(detectScriptLanguage('আমি বাংলায় গান গাই'), 'bn');
      expect(detectScriptLanguage('यह हिंदी है'), 'hi');
      expect(detectScriptLanguage('Plain English text.'), isNull);
      expect(detectScriptLanguage('ひらがなと漢字'), 'ja');
    });

    test('a Bengali text file gets bn', () {
      final book = ingestString('আমি বাড়ি যাই। তুমি কোথায় যাও?\n\nআবার দেখা হবে।',
          filename: 'golpo.txt');
      expect(book.metadata.language, 'bn');
    });

    test('English text defaults to en', () {
      expect(ingestString('Hello there.').metadata.language, 'en');
    });
  });

  group('plain text shapes', () {
    test('one paragraph per line, no blank lines', () {
      final lines = [for (var i = 0; i < 20; i++) 'Line $i is a paragraph.'];
      final book = ingestString(lines.join('\n'), filename: 'dump.txt');
      expect(_texts(book), hasLength(20));
    });

    test('hard-wrapped paragraphs are joined and hyphens mended', () {
      const raw = 'The quick brown fox was an exam-\nple of speed and\ngrace.\n\n'
          'Second paragraph here.\n\nThird one.\n\nFourth.';
      final book = ingestString(raw, filename: 'gut.txt');
      expect(_texts(book).first,
          'The quick brown fox was an example of speed and grace.');
    });

    test('hard-wrapped paragraphs longer than six lines are still joined', () {
      // A Gutenberg story's paragraphs run to twenty lines and more: blank
      // lines are few, and the file was once read a line to a sentence.
      String wrap(String text) {
        final lines = <String>[];
        var line = '';
        for (final word in text.split(' ')) {
          if (line.isNotEmpty && line.length + word.length > 60) {
            lines.add(line);
            line = word;
          } else {
            line = line.isEmpty ? word : '$line $word';
          }
        }
        return [...lines, line].join('\n');
      }

      const first = 'During the whole of a dull, dark, and soundless day in the autumn of the year, '
          'when the clouds hung oppressively low in the heavens, I had been passing alone, on '
          'horseback, through a singularly dreary tract of country; and at length found myself, '
          'as the shades of the evening drew on, within view of the melancholy House of Usher. '
          'I know not how it was; but, with the first glimpse of the building, a sense of '
          'insufferable gloom pervaded my spirit.';
      const second = 'Nevertheless, in this mansion of gloom I now proposed to myself a sojourn of '
          'some weeks. Its proprietor, Roderick Usher, had been one of my boon companions in '
          'boyhood; but many years had elapsed since our last meeting. A letter, however, had '
          'lately reached me in a distant part of the country, a letter from him, which, in its '
          'wildly importunate nature, had admitted of no other than a personal reply.';
      final book = ingestString('${wrap(first)}\n\n${wrap(second)}\n', filename: 'usher.txt');
      expect(_texts(book), [first, second]);
    });

    test("Project Gutenberg's header and licence around a text file are not read", () {
      const book = 'The Raven\n\nOnce upon a midnight dreary, while I pondered, weak and weary.\n';
      const raw = 'The Project Gutenberg eBook of The Raven\n\n'
          'This eBook is for the use of anyone anywhere in the United States.\n\n'
          'Title: The Raven\n\nAuthor: Edgar Allan Poe\n\n'
          '*** START OF THE PROJECT GUTENBERG EBOOK THE RAVEN ***\n\n\n$book\n\n'
          '*** END OF THE PROJECT GUTENBERG EBOOK THE RAVEN ***\n\n'
          'Updated editions will replace the previous one.\n\n'
          'START: FULL LICENSE\n\nPLEASE READ THIS BEFORE YOU DISTRIBUTE OR USE THIS WORK\n';
      expect(_texts(ingestString(raw, filename: 'pg1065.txt')),
          ['The Raven', 'Once upon a midnight dreary, while I pondered, weak and weary.']);
      // Older files say THIS, and some leave out the spaces.
      expect(_texts(ingestString('Header.\n\n***START OF THIS PROJECT GUTENBERG EBOOK RAVEN***\n\n$book', filename: 'r.txt')),
          ['The Raven', 'Once upon a midnight dreary, while I pondered, weak and weary.']);
    });

    test("a Gutenberg text is named by its header's title and author, not its file's number", () {
      const book = 'The Raven\n\nOnce upon a midnight dreary, while I pondered, weak and weary.\n';
      String gutenberg(String header) =>
          'The Project Gutenberg eBook of The Raven\n\n$header\n\n'
          '*** START OF THE PROJECT GUTENBERG EBOOK THE RAVEN ***\n\n$book\n'
          '*** END OF THE PROJECT GUTENBERG EBOOK THE RAVEN ***\n';
      final raven = ingestString(gutenberg('Title: The Raven\n\nAuthor: Edgar Allan Poe\n\nRelease date: 1997'),
          filename: 'pg1065.txt');
      expect(raven.metadata.title, 'The Raven');
      expect(raven.metadata.authors, ['Edgar Allan Poe']);
      // A title over two lines, the second set in: a subtitle.
      final douglass = ingestString(
        gutenberg('Title: Narrative of the Life of Frederick Douglass, an American Slave\n'
            '       Written by Himself\n\nAuthor: Frederick Douglass'),
        filename: 'pg23.txt',
      );
      expect(douglass.metadata.title, 'Narrative of the Life of Frederick Douglass, an American Slave: Written by Himself');
      // No header, or a "Title:" in the book itself: the file's name, as before.
      expect(ingestString('Title: a list\n\nAuthor: me\n\n$book', filename: 'notes.txt').metadata.title, 'notes');
      expect(ingestString(gutenberg('Release date: 1997'), filename: 'raven.txt').metadata.title, 'raven');
    });

    test('chapter lines become sections', () {
      const raw = 'Preface text that comes first.\n\n'
          'Chapter 1\n\nIt began.\n\n'
          'Chapter 2\n\nIt went on.\n\n'
          'Chapter 3\n\nIt ended.';
      final book = ingestString(raw, filename: 'novel.txt');
      expect(book.sections.map((s) => s.displayTitle),
          containsAll(['Chapter 1', 'Chapter 2', 'Chapter 3']));
    });

    test('UTF-16 with BOM decodes', () {
      final units = 'Hello there. Again.'.codeUnits;
      final bytes = Uint8List.fromList([
        0xFF, 0xFE,
        for (final u in units) ...[u & 0xFF, u >> 8],
      ]);
      final book = ingestBytes(bytes, filename: 'w.txt');
      expect(_texts(book).first, 'Hello there. Again.');
    });

    test('binary junk is refused, not read as text', () {
      final bytes = Uint8List.fromList(List.generate(2000, (i) => i % 7));
      expect(() => ingestBytes(bytes, filename: 'x.bin'),
          throwsA(isA<UnsupportedDocumentException>()));
    });
  });

  group('docx', () {
    Uint8List docx() => _zip({
          '[Content_Types].xml': '<Types/>',
          'word/document.xml': '''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>One</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:t>world.</w:t></w:r></w:p>
<w:p><w:r><w:delText>gone</w:delText><w:t>Kept.</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Two</w:t></w:r></w:p>
<w:p><w:r><w:t>Second chapter text.</w:t></w:r></w:p>
</w:body></w:document>''',
          'word/styles.xml': '''
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:style w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
</w:styles>''',
          'docProps/core.xml': '''
<cp:coreProperties xmlns:cp="x" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>My Doc</dc:title><dc:creator>Ann</dc:creator></cp:coreProperties>''',
        });

    test('detected even though [Content_Types].xml comes first', () {
      expect(detectFormat(docx(), filename: 'a.zip'), SourceKind.docx);
    });

    test('headings split chapters, runs join, deletions dropped', () {
      final book = ingestBytes(docx(), filename: 'a.docx');
      expect(book.metadata.title, 'My Doc');
      expect(book.metadata.authors, ['Ann']);
      expect(book.sections, hasLength(2));
      expect(_texts(book), contains('Hello world.'));
      expect(_texts(book), contains('Kept.'));
      expect(_texts(book).join(' '), isNot(contains('gone')));
    });
  });

  test('odt', () {
    final bytes = _zip({
      'mimetype': 'application/vnd.oasis.opendocument.text',
      'meta.xml': '<office:document-meta xmlns:office="o" xmlns:dc="http://purl.org/dc/elements/1.1/"><office:meta><dc:title>Odt Book</dc:title></office:meta></office:document-meta>',
      'content.xml': '''
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
<office:body><office:text>
<text:h text:outline-level="1">First</text:h>
<text:p>Some<text:s/>words here.</text:p>
<text:h text:outline-level="1">Second</text:h>
<text:list><text:list-item><text:p>An item.</text:p></text:list-item></text:list>
</office:text></office:body></office:document-content>''',
    });
    expect(detectFormat(bytes), SourceKind.odt);
    final book = ingestBytes(bytes, filename: 'x.odt');
    expect(book.metadata.title, 'Odt Book');
    expect(book.sections, hasLength(2));
    expect(_texts(book), contains('Some words here.'));
  });

  test('fb2 in windows-1251', () {
    const xml = '<?xml version="1.0" encoding="windows-1251"?>'
        '<FictionBook><description><title-info><book-title>Kniga</book-title>'
        '<lang>ru</lang></title-info></description><body>'
        '<section><title><p>One</p></title><p>@@</p></section>'
        '<section><title><p>Two</p></title><p>Text two.</p></section>'
        '</body></FictionBook>';
    // "Привет." in cp1251 replaces the @@ placeholder.
    final bytes = <int>[];
    final parts = xml.split('@@');
    bytes.addAll(parts[0].codeUnits);
    bytes.addAll([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x2E]);
    bytes.addAll(parts[1].codeUnits);
    final book = ingestBytes(Uint8List.fromList(bytes), filename: 'k.fb2');
    expect(book.metadata.title, 'Kniga');
    expect(book.metadata.language, 'ru');
    expect(_texts(book), contains('Привет.'));
    expect(book.sections, hasLength(2));
  });

  test("an FB2 book's own title and epigraph, before its first chapter, are kept", () {
    const xml = '<?xml version="1.0" encoding="utf-8"?>'
        '<FictionBook><description><title-info><book-title>The Lighthouse</book-title></title-info></description>'
        '<body><title><p>The Lighthouse</p></title>'
        '<epigraph><poem><stanza><v>A fire burns above the water,</v><v>and someone waits.</v></stanza></poem>'
        '<text-author>A keepers’ song</text-author></epigraph>'
        '<section><title><p>Chapter One</p></title><p>The keeper came in the spring.</p></section>'
        '<section><title><p>Chapter Two</p></title><p>The storm came in November.</p></section>'
        '</body></FictionBook>';
    final book = ingestBytes(Uint8List.fromList(utf8.encode(xml)), filename: 'l.fb2');
    expect(_texts(book), [
      'The Lighthouse',
      'A fire burns above the water,',
      'and someone waits.',
      'A keepers’ song',
      'Chapter One',
      'The keeper came in the spring.',
      'Chapter Two',
      'The storm came in November.',
    ]);
    expect(book.sections.map((s) => s.displayTitle), ['The Lighthouse', 'Chapter One', 'Chapter Two']);
  });

  test('rtf', () {
    const rtf = r'''{\rtf1\ansi{\fonttbl{\f0 Times;}}{\*\generator Word;}\f0 Caf\'e9 is open.\par Second \u8212? line.\par}''';
    final bytes = Uint8List.fromList(rtf.codeUnits);
    expect(detectFormat(bytes), SourceKind.rtf);
    final book = ingestBytes(bytes, filename: 'a.rtf');
    expect(_texts(book), ['Café is open.', 'Second — line.']);
  });

  group('mobi', () {
    Uint8List mobi(String html, {int compression = 1}) {
      final text = utf8.encode(html);
      final body = compression == 2 ? _palmCompressLiteral(text) : text;
      final r0 = ByteData(16 + 0xE8);
      r0.setUint16(0, compression);
      r0.setUint32(4, text.length);
      r0.setUint16(8, 1); // one text record
      r0.setUint16(10, 4096);
      r0.setUint16(12, 0);
      final r0b = r0.buffer.asUint8List();
      r0b.setRange(16, 20, 'MOBI'.codeUnits);
      r0.setUint32(20, 0xE8);
      r0.setUint32(28, 65001);
      r0.setUint32(84, 0);
      r0.setUint32(88, 0);
      final header = ByteData(78 + 2 * 8 + 2);
      final hb = header.buffer.asUint8List();
      hb.setRange(60, 68, 'BOOKMOBI'.codeUnits);
      header.setUint16(76, 2);
      final start0 = 78 + 16 + 2;
      header.setUint32(78, start0);
      header.setUint32(86, start0 + r0b.length);
      return Uint8List.fromList([...hb, ...r0b, ...body]);
    }

    const html = '<html><body><h1>Chapter 1</h1><p>First page.</p>'
        '<mbp:pagebreak/><h1>Chapter 2</h1><p>Second page.</p></body></html>';

    test('uncompressed', () {
      final bytes = mobi(html);
      expect(detectFormat(bytes), SourceKind.mobi);
      final book = ingestBytes(bytes, filename: 'b.mobi');
      expect(book.sections, hasLength(2));
      expect(_texts(book), contains('Second page.'));
    });

    test('PalmDOC literal runs', () {
      final book = ingestBytes(mobi(html, compression: 2), filename: 'b.azw');
      expect(_texts(book), contains('First page.'));
    });

    test('PalmDOC back-references', () {
      // "abcabcabc": literals a,b,c then distance 3 length 6.
      final pair = (3 << 3) | (6 - 3);
      final out = palmDocDecompress(Uint8List.fromList(
          [0x61, 0x62, 0x63, 0x80 | (pair >> 8), pair & 0xFF]));
      expect(String.fromCharCodes(out), 'abcabcabc');
    });
  });

  group('pdf text', () {
    test('drops running headers and page numbers, joins across pages', () {
      const words = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot'];
      final pages = [
        for (var p = 1; p <= 6; p++)
          'The Book Title\n${pdfParagraphMark}Paragraph on page ${words[p - 1]} begins here and'
              '\ncontinues on the next line.$pdfParagraphMark'
              'A sentence that runs over the\n${p < 6 ? 'gate ${words[p - 1]}' : 'end.'}\n$p',
      ];
      pages[1] = pages[1].replaceFirst('Paragraph', 'paragraph');
      final book = ingestPdfText(id: 'x', pages: pages, filename: 'b.pdf');
      final all = _texts(book).join('\n');
      expect(all, isNot(contains('The Book Title')));
      expect(all, contains('continues on the next line.'));
      expect(RegExp(r'^\d+$', multiLine: true).hasMatch(all), isFalse);
      // "...over the page" + "paragraph on page 2..." joined into one.
      expect(all, contains('runs over the gate alpha paragraph on page bravo'));
      // No bookmarks and no chapter headings: ten pages per entry, none dropped.
      expect(book.sections.first.displayTitle, 'Pages 1–6');
    });

    test('one line per paragraph is reflowed into real paragraphs', () {
      final mark = pdfParagraphMark;
      final page = '${mark}Chapter One$mark'
          'The storm came in from the west just after$mark'
          'dusk, and the keeper climbed the long stair to light the$mark'
          'lamp. He had done it for thirty years.$mark'
          'Every night the same ninety-six steps.';
      final book = ingestPdfText(id: 'x', pages: [page], filename: 'l.pdf');
      final texts = [for (final b in book.sections.first.blocks) b.text];
      expect(texts, [
        'Chapter One',
        'The storm came in from the west just after dusk, and the keeper '
            'climbed the long stair to light the lamp. He had done it for '
            'thirty years.',
        'Every night the same ninety-six steps.',
      ]);
      expect(book.sections.first.blocks.first.role, BlockRole.heading);
    });

    test('without an outline, chapter headings in the text become chapters', () {
      const m = pdfParagraphMark;
      final pages = [
        'Title page of the book, printed long ago in a city far away from here.',
        // The extractor marks paragraphs; a heading is its own paragraph.
        '${m}CHAPTER I${m}DOWN THE HOLE${m}Alice was beginning to get very tired of sitting by her sister.',
        'More of the first chapter goes on here for a while, as chapters do, at length.',
        '${m}CHAPTER II${m}THE POOL${m}Curiouser and curiouser, cried Alice, much surprised.',
        '${m}CHAPTER III${m}A RACE${m}They were indeed a queer-looking party that assembled.',
        'A book of rules for shutting people up like telescopes was not to be found.',
      ];
      final book = ingestPdfText(id: 'x', pages: pages);
      expect(book.sections.map((s) => s.displayTitle), [
        'Opening pages',
        'Chapter I: Down The Hole',
        'Chapter II: The Pool',
        'Chapter III: A Race',
      ]);
    });

    test('a stored one-section-per-page PDF is re-sectioned', () {
      final old = Book(
        id: 'o',
        metadata: const BookMetadata(title: 'Old'),
        source: SourceKind.pdf,
        toc: const [],
        sections: [
          for (var p = 0; p < 12; p++)
            Section(id: 's$p', index: p, title: 'Page ${p + 1}', blocks: [
              makeBlock(role: BlockRole.paragraph, text: 'Text of page ${p + 1} goes on for a while.', anchor: PageAnchor(p)),
            ]),
        ],
      );
      final fixed = resectionPdf(old);
      expect(fixed.sections.map((s) => s.displayTitle), ['Pages 1–10', 'Pages 11–12']);
      expect(identical(resectionPdf(fixed), fixed), isTrue);
    });

    test('outline becomes chapters', () {
      final pages = [for (var p = 0; p < 4; p++) 'Text on page $p is long enough to count as real text for the reader.'];
      final book = ingestPdfText(
        id: 'x',
        pages: pages,
        outline: const [(title: 'Intro', page: 0), (title: 'Part Two', page: 2)],
      );
      expect(book.sections.map((s) => s.displayTitle), ['Intro', 'Part Two']);
    });

    test('scanned PDFs are refused with a reason', () {
      expect(
        () => ingestPdfText(id: 'x', pages: List.filled(10, '')),
        throwsA(isA<UnsupportedDocumentException>()),
      );
    });
  });
}

/// PalmDOC with only literal runs (type 1-8 records), enough to round-trip.
List<int> _palmCompressLiteral(List<int> data) {
  final out = <int>[];
  for (var i = 0; i < data.length; i += 8) {
    final end = (i + 8).clamp(0, data.length);
    out.add(end - i);
    out.addAll(data.sublist(i, end));
  }
  return out;
}
