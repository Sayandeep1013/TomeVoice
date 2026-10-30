import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

const _w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
    'xmlns:v="urn:schemas-microsoft-com:vml"';

Uint8List _docx(String body, {String? footnotes, String? endnotes, String styles = ''}) {
  final a = Archive();
  void add(String name, String text) => a.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  add('[Content_Types].xml', '<Types/>');
  add('word/document.xml', '<w:document $_w><w:body>$body</w:body></w:document>');
  add('word/styles.xml', '<w:styles $_w>'
      '<w:style w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>'
      '<w:style w:styleId="TOC1"><w:name w:val="toc 1"/></w:style>'
      '<w:style w:styleId="TOCHeading"><w:name w:val="TOC Heading"/></w:style>$styles</w:styles>');
  if (footnotes != null) add('word/footnotes.xml', '<w:footnotes $_w>$footnotes</w:footnotes>');
  if (endnotes != null) add('word/endnotes.xml', '<w:endnotes $_w>$endnotes</w:endnotes>');
  return Uint8List.fromList(ZipEncoder().encode(a));
}

String _p(String text, {String? style}) =>
    '<w:p>${style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>'}<w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';

List<String> _texts(Book b) => [for (final s in b.sections) for (final bl in s.blocks) bl.text];

void main() {
  group('docx', () {
    test('a text box is read once, not once per way Word stores it', () {
      final box = '<w:p><w:r><w:t>Before the box.</w:t></w:r><w:r><mc:AlternateContent>'
          '<mc:Choice Requires="wps"><w:drawing><wps:txbx><w:txbxContent>${_p('Inside the box.')}'
          '</w:txbxContent></wps:txbx></w:drawing></mc:Choice>'
          '<mc:Fallback><w:pict><v:textbox><w:txbxContent>${_p('Inside the box.')}'
          '</w:txbxContent></v:textbox></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>';
      final book = ingestBytes(_docx(box + _p('After the box.')), filename: 'box.docx');
      expect(_texts(book).where((t) => t.contains('Inside the box.')), hasLength(1));
    });

    test('a table of contents is not read, field or style', () {
      final toc = '${_p('Contents', style: 'TOCHeading')}'
          '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Chapter One 1</w:t></w:r></w:p>'
          '${_p('Chapter Two 7', style: 'TOC1')}'
          '<w:p><w:r><w:t>Chapter Three 12</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
          '<w:sdt><w:sdtPr><w:docPartObj><w:docPartGallery w:val="Table of Contents"/></w:docPartObj></w:sdtPr>'
          '<w:sdtContent>${_p('Chapter Four 20')}</w:sdtContent></w:sdt>'
          '<w:p><w:fldSimple w:instr=" TOC \\o "><w:r><w:t>Chapter Five 25</w:t></w:r></w:fldSimple></w:p>';
      final book = ingestBytes(
        _docx('$toc${_p('Chapter One', style: 'Heading1')}${_p('It begins.')}'
            '${_p('Chapter Two', style: 'Heading1')}${_p('It goes on.')}'),
        filename: 'toc.docx',
      );
      expect(_texts(book), ['Chapter One', 'It begins.', 'Chapter Two', 'It goes on.']);
    });

    test('a contents field that never ends does not hide the book', () {
      final broken = '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText> TOC \\o "1-3" </w:instrText></w:r><w:r><w:t>Chapter One 1</w:t></w:r></w:p>'
          '${_p('Chapter One', style: 'Heading1')}'
          '${_p('It begins, and this first paragraph is far too long to be a line of a table of contents: '
              'it goes on and on about the morning, the rain, the long road into town and the people on it, '
              'the shops that were opening and the bells that were ringing for the first service of the day.')}';
      final texts = _texts(ingestBytes(_docx(broken), filename: 'broken.docx'));
      expect(texts.where((t) => t.startsWith('It begins')), hasLength(1));
    });

    test('hidden text is not read', () {
      final hidden = '<w:p><w:r><w:t xml:space="preserve">Shown </w:t></w:r>'
          '<w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden </w:t></w:r>'
          '<w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t>words.</w:t></w:r></w:p>';
      expect(_texts(ingestBytes(_docx(hidden), filename: 'h.docx')), ['Shown words.']);
    });

    test('footnotes and endnotes are kept as notes, their marks silent', () {
      final body = '<w:p><w:r><w:t>The house fell.</w:t></w:r>'
          '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="5"/></w:r>'
          '<w:r><w:t xml:space="preserve"> Then the rain came.</w:t></w:r>'
          '<w:r><w:endnoteReference w:id="2"/></w:r></w:p>${_p('The end of it.')}';
      final book = ingestBytes(
        _docx(
          body,
          footnotes: '<w:footnote w:type="separator" w:id="-1">${_p('')}</w:footnote>'
              '<w:footnote w:id="5"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> It was old.</w:t></w:r></w:p></w:footnote>',
          endnotes: '<w:endnote w:id="2">${_p('Rain is wet.')}</w:endnote>',
        ),
        filename: 'notes.docx',
      );
      final blocks = [for (final s in book.sections) ...s.blocks];
      final units = flattenSpeakable(book);
      expect(units.map((u) => spokenText(u.text, u.silent).text), ['The house fell.', 'Then the rain came.', 'The end of it.']);
      final notes = blocks.where((b) => b.role == BlockRole.footnote).map((b) => b.text).toList();
      expect(notes.any((t) => t.endsWith('It was old.')), isTrue);
      expect(notes.any((t) => t.endsWith('Rain is wet.')), isTrue);
      // The footnote sits right after the paragraph that points at it.
      final first = blocks.indexWhere((b) => b.text.startsWith('The house fell.'));
      expect(blocks[first + 1].role, BlockRole.footnote);
    });
  });

  group('odt', () {
    Uint8List odt(String body) {
      final a = Archive();
      void add(String name, String text) => a.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
      add('mimetype', 'application/vnd.oasis.opendocument.text');
      add('meta.xml', '<office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/"><office:meta><dc:title>Parables</dc:title></office:meta></office:document-meta>');
      add('content.xml', '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
          'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
          'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink">'
          '<office:body><office:text>$body</office:text></office:body></office:document-content>');
      return Uint8List.fromList(ZipEncoder().encode(a));
    }

    test("LibreOffice's table of contents and a picture's description are not read", () {
      final book = ingestBytes(
        odt('<text:p text:style-name="Title">Parables</text:p>'
            '<text:table-of-content text:name="Table of Contents1"><text:index-body>'
            '<text:index-title><text:p>Table of Contents</text:p></text:index-title>'
            '<text:p><text:a xlink:href="#__RefHeading___Toc1_1">The Scarecrow<text:tab/>2</text:a></text:p>'
            '</text:index-body></text:table-of-content>'
            '<text:h text:outline-level="1">The Scarecrow</text:h>'
            '<text:p><draw:frame draw:name="Image1"><draw:image xlink:href="Pictures/a.png"/>'
            '<svg:title>A scarecrow</svg:title><svg:desc>A scarecrow in a field.</svg:desc></draw:frame>'
            'Once I said to a scarecrow, “You must be tired.”</text:p>'
            '<text:h text:outline-level="1">The Fox</text:h><text:p>A fox looked at his shadow.</text:p>'),
        filename: 'p.odt',
      );
      expect(_texts(book), [
        'Parables',
        'The Scarecrow',
        'Once I said to a scarecrow, “You must be tired.”',
        'The Fox',
        'A fox looked at his shadow.',
      ]);
    });
  });

  group('markdown', () {
    test('front matter, tables and raw HTML are not read', () {
      final book = ingestString(
        '---\ntitle: My Notes\ntags: [a, b]\n---\n'
        '# Results\n\n'
        'Before the table.<br>Still before.\n\n'
        '| Name | Age |\n|------|----:|\n| Alice | 30 |\n| Bob | 25 |\n\n'
        '<div align="center">\n\nCentred words.\n\n</div>\n\n'
        '<!-- a comment\nover two lines -->\n'
        'After it all.',
        filename: 'notes.md',
      );
      expect(_texts(book), [
        'Results',
        'Before the table. Still before.',
        'Name Age',
        'Alice 30',
        'Bob 25',
        'Centred words.',
        'After it all.',
      ]);
    });

    test('headings underlined with = or - are headings, not read with their underline', () {
      final book = ingestString(
        'A Week on the Coast Path\n========================\n\nThe first notes.\n\n'
        'Day One\n-------\n\nWe left at nine.\n\n- an item\n---\n\nDay Two\n---\n\nWe walked on.',
        filename: 'walk.md',
      );
      expect(_texts(book), [
        'A Week on the Coast Path',
        'The first notes.',
        'Day One',
        'We left at nine.',
        'an item',
        'Day Two',
        'We walked on.',
      ]);
      expect(book.sections.map((s) => s.displayTitle), ['A Week on the Coast Path', 'Day One', 'Day Two']);
    });

    test('a footnote is shown and not read in the flow; its mark is not said', () {
      final book = ingestString(
        'We could see six small boats.[^tide] Then the rain came.\n\n'
        'The tide turned at noon.\n\n'
        '[^tide]: The tide tables were an hour out\nall week.',
        filename: 'walk.md',
      );
      final blocks = [for (final s in book.sections) ...s.blocks];
      final one = String.fromCharCode(0xB9);
      expect(blocks.map((b) => b.text), [
        'We could see six small boats.$one Then the rain came.',
        'The tide turned at noon.',
        '$one The tide tables were an hour out all week.',
      ]);
      expect(blocks.last.role, BlockRole.footnote);
      expect(flattenSpeakable(book).map((u) => spokenText(u.text, u.silent).text),
          ['We could see six small boats.', 'Then the rain came.', 'The tide turned at noon.']);
    });

    test("a picture's description is shown, not read in its sentence", () {
      final book = ingestString('He drew ![a star](star.png) on the wall.\n\n![A sketch map](map.png)\n',
          filename: 'p.md');
      final blocks = [for (final s in book.sections) ...s.blocks];
      expect(blocks.map((b) => (b.role, b.text)), [
        (BlockRole.paragraph, 'He drew on the wall.'),
        (BlockRole.figure, 'a star'),
        (BlockRole.figure, 'A sketch map'),
      ]);
    });
  });
}
