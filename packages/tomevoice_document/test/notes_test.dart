import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// Shown text and the text a voice would be given, per sentence.
List<(String, String)> _said(List<Block> blocks) => [
      for (final b in blocks)
        if (b.speakable)
          for (final s in b.sentences) (s.of(b.text), spokenText(s.of(b.text), [
            for (final r in s.silent) (start: r.start - s.startOffset, end: r.end - s.startOffset),
          ]).text),
    ];

Uint8List _epub(Map<String, String> chapters, {List<String>? spine}) {
  final a = Archive();
  void text(String name, String body) => a.addFile(ArchiveFile.bytes(name, utf8.encode(body)));
  a.addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')));
  text('META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>');
  final names = spine ?? chapters.keys.toList();
  text('OEBPS/content.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Notes</dc:title><dc:language>en</dc:language></metadata>
  <manifest>${[for (final n in chapters.keys) '<item id="$n" href="$n" media-type="application/xhtml+xml"/>'].join()}</manifest>
  <spine>${[for (final n in names) '<itemref idref="$n"/>'].join()}</spine>
</package>''');
  for (final e in chapters.entries) {
    text('OEBPS/${e.key}', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>${e.value}</body></html>');
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  group('footnote markers', () {
    test('a bracketed link to a note in the same file is shown but not said', () {
      final blocks = blocksFromHtml('<html><body>'
          '<p>It was a house.<a id="r1" href="#id_C0001">[1]</a> The next day came.</p>'
          '<p>Then a second note<a id="r2" href="#id_C0002">[2]</a> followed it.</p>'
          '<ol><li id="id_C0001"><a href="#r1">[1]</a> A note about the house.</li>'
          '<li id="id_C0002"><a href="#r2">[2]</a> Another note.</li></ol>'
          '</body></html>');
      expect(_said(blocks), [
        ('It was a house.[1]', 'It was a house.'),
        ('The next day came.', 'The next day came.'),
        ('Then a second note[2] followed it.', 'Then a second note followed it.'),
      ]);
      expect(blocks.where((b) => b.role == BlockRole.footnote).map((b) => b.text),
          ['[1] A note about the house.', '[2] Another note.']);
    });

    test('a superscript number or symbol is a marker, an exponent is not', () {
      final blocks = blocksFromHtml('<p>The wall<sup>1</sup> fell, the king<sup>*</sup> wept, '
          'and 10<sup>6</sup> people saw it on the 2<sup>nd</sup>.</p>');
      expect(_said(blocks).single.$2, 'The wall fell, the king wept, and 106 people saw it on the 2nd.');
    });

    test('epub:type noteref and doc-noteref are markers whatever they say', () {
      final blocks = blocksFromHtml('<p>Here<a epub:type="noteref" href="#n">see note</a> and '
          'there<a role="doc-noteref" href="#m">†</a> it ends.</p>'
          '<aside epub:type="footnote" id="n"><p>The note.</p></aside>');
      expect(_said(blocks).single.$2, 'Here and there it ends.');
      expect(blocks.last.role, BlockRole.footnote);
    });

    test('a numbered link after "chapter" or "page" is still read', () {
      final blocks = blocksFromHtml('<p>See chapter <a href="#c2">2</a> and page <a href="#p9">9</a>.</p>'
          '<h2 id="c2">Two</h2><p id="p9">Text.</p>');
      expect(_said(blocks).first.$2, 'See chapter 2 and page 9.');
      expect(blocks.where((b) => b.role == BlockRole.footnote), isEmpty);
    });

    test('a contents list of numbered links never turns chapters into notes', () {
      final blocks = blocksFromHtml('<div><a href="#c1">1</a> <a href="#c2">2</a></div>'
          '<div id="c1"><h2>One</h2><p>Chapter one text.</p></div>'
          '<div id="c2"><p>Chapter two text, short and with no heading.</p></div>');
      expect(blocks.where((b) => b.role == BlockRole.footnote), isEmpty);
    });

    test('a backlink to the text never makes the text a note', () {
      final blocks = blocksFromHtml('<p id="para">Main text<a href="#fn1">1</a> goes on.</p>'
          '<p id="fn1"><a href="#para">1</a> The note itself.</p>');
      expect(blocks.first.role, BlockRole.paragraph);
      expect(blocks.last.role, BlockRole.footnote);
    });

    test('a note introduced by its anchor, and the heading over the notes', () {
      final blocks = blocksFromHtml('<p>Text<a href="#_ftn1" name="_ftnref1">[1]</a> here.</p>'
          '<h3>Notes</h3><p><a href="#_ftnref1" name="_ftn1">[1]</a> Word-style note.</p>');
      expect(blocks.map((b) => b.role), [BlockRole.paragraph, BlockRole.footnote, BlockRole.footnote]);
    });

    test('everything inside an endnotes section is a note, lists and headings too', () {
      final blocks = blocksFromHtml('<p>Story text.</p><section epub:type="endnotes">'
          '<h2>Notes</h2><ol><li id="e1"><p>First.</p></li></ol></section>');
      expect(blocks.map((b) => b.role), [BlockRole.paragraph, BlockRole.footnote, BlockRole.footnote]);
    });

    test('printed page breaks in the text are not read', () {
      final blocks = blocksFromHtml('<p>So she<span epub:type="pagebreak" id="p7">7</span> went on.</p>');
      expect(blocks.single.text, 'So she went on.');
    });
  });

  group('EPUB notes in their own file', () {
    test('notes after the chapter are footnotes; their links are silent', () {
      final book = ingestBytes(
        _epub({
          'ch1.xhtml': '<h1>One</h1><p>He came home.<a id="r1" href="notes.xhtml#n1"><sup>1</sup></a> '
              'It was late.</p>',
          'notes.xhtml': '<h1>Notes</h1><p id="n1"><a href="ch1.xhtml#r1">1</a>. A note.</p>',
        }),
        filename: 'n.epub',
      );
      final units = flattenSpeakable(book);
      expect(units.map((u) => u.text), ['One', 'He came home.1', 'It was late.']);
      expect(spokenText(units[1].text, units[1].silent).text, 'He came home.');
      final notes = book.sections.last.blocks;
      expect(notes.map((b) => b.role), everyElement(BlockRole.footnote));
    });
  });

  group('FB2 notes', () {
    test('note links are silent and the notes body is kept as footnotes', () {
      const xml = '<?xml version="1.0" encoding="utf-8"?>'
          '<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'
          '<book-title>N</book-title></title-info></description>'
          '<body><section><title><p>One</p></title>'
          '<p>A word<a l:href="#n1" type="note">[1]</a> here. And more.</p></section></body>'
          '<body name="notes"><title><p>Notes</p></title>'
          '<section id="n1"><title><p>1</p></title><p>The note.</p></section></body>'
          '</FictionBook>';
      final book = ingestBytes(Uint8List.fromList(utf8.encode(xml)), filename: 'n.fb2');
      final units = flattenSpeakable(book);
      expect(units.map((u) => u.text), ['One', 'A word[1] here.', 'And more.']);
      expect(spokenText(units[1].text, units[1].silent).text, 'A word here.');
      expect(book.sections.last.blocks.map((b) => b.role), everyElement(BlockRole.footnote));
      expect(book.sections.last.blocks.map((b) => b.text), contains('The note.'));
    });
  });
}
