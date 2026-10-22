import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// A 3x2 PNG header followed by junk; only the header matters.
Uint8List _png(int w, int h) {
  final b = ByteData(33);
  final bytes = b.buffer.asUint8List();
  bytes.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.setUint32(8, 13);
  bytes.setAll(12, 'IHDR'.codeUnits);
  b.setUint32(16, w);
  b.setUint32(20, h);
  return bytes;
}

/// Minimal baseline JPEG header with an SOF0 segment.
Uint8List _jpeg(int w, int h) => Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, length 4
      0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, precision 8
      h >> 8, h & 0xFF, w >> 8, w & 0xFF,
      0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);

Uint8List _epub() {
  final a = Archive();
  void add(String name, List<int> data) => a.addFile(ArchiveFile.bytes(name, data));
  void text(String name, String body) => add(name, utf8.encode(body));
  a.addFile(ArchiveFile.noCompress('mimetype', 20, utf8.encode('application/epub+zip')));
  text('META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>');
  text('OEBPS/content.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Pictures</dc:title><dc:language>en</dc:language>
    <meta name="cover" content="cov"/>
  </metadata>
  <manifest>
    <item id="cov" href="Images/cover.jpg" media-type="image/jpeg"/>
    <item id="c" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="m" href="Text/map.xhtml" media-type="application/xhtml+xml"/>
    <item id="1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c"/><itemref idref="m"/><itemref idref="1"/></spine>
</package>''');
  text('OEBPS/Text/cover.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:xlink="http://www.w3.org/1999/xlink"><body>
<svg><image xlink:href="../Images/cover.jpg"/></svg></body></html>''');
  text('OEBPS/Text/map.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<p>The Seven Kingdoms</p><p><img src="../Images/map%20one.png" alt=""/></p></body></html>''');
  text('OEBPS/Text/ch1.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>Chapter One</h1>
<p>The first paragraph of the chapter has enough words to be read aloud as a chapter.</p>
<p class="center"><img src="../Images/ornament.png"/></p>
<p>After the ornament the story carries on for a while longer, as stories do.</p>
<p><img src="../Images/missing.png"/></p>
</body></html>''');
  add('OEBPS/Images/cover.jpg', _jpeg(600, 900));
  add('OEBPS/Images/map one.png', _png(1200, 800));
  add('OEBPS/Images/ornament.png', _png(120, 40));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  test('image sizes from headers', () {
    expect(imageSize(_png(3, 2)), (width: 3, height: 2));
    expect(imageSize(_jpeg(640, 480)), (width: 640, height: 480));
    expect(imageSize(Uint8List(40)), isNull);
  });

  group('EPUB pictures', () {
    final bytes = _epub();
    final book = ingestBytes(bytes, filename: 'pictures.epub');
    final images = [
      for (final s in book.sections)
        for (final b in s.blocks)
          if (b.isImage) b,
    ];

    test('figures resolve their paths and sizes; missing files are dropped', () {
      expect(images.map((b) => b.image), [
        'OEBPS/Images/cover.jpg',
        'OEBPS/Images/map one.png',
        'OEBPS/Images/ornament.png',
      ]);
      expect(images[1].imageWidth, 1200);
      expect(images[1].imageHeight, 800);
    });

    test('the cover is found from the package metadata', () {
      expect(book.metadata.cover, 'OEBPS/Images/cover.jpg');
    });

    test('the importer can pull the bytes out', () {
      final res = epubResources(bytes, imagesOf(book));
      expect(res.keys, containsAll(['OEBPS/Images/cover.jpg', 'OEBPS/Images/ornament.png']));
      expect(imageSize(res['OEBPS/Images/map one.png']!), (width: 1200, height: 800));
    });

    test('pictures are shown in the reading list but never spoken', () {
      final layout = ReadingLayout.build(book);
      expect(layout.units.map((u) => u.text).join(' '), isNot(contains('png')));
      final shown = [
        for (final i in layout.items)
          if (i.isImage) i.block!.image,
      ];
      // Cover and map pages have no story text, so they lead into chapter 1.
      expect(shown, [
        'OEBPS/Images/cover.jpg',
        'OEBPS/Images/map one.png',
        'OEBPS/Images/ornament.png',
      ]);
      expect(layout.units.first.text, 'Chapter One');
    });

    test('survives a JSON round trip', () {
      final back = Book.fromJson(jsonDecode(jsonEncode(book.toJson())) as Map<String, Object?>);
      expect(back.metadata.cover, book.metadata.cover);
      final b = back.sections.expand((s) => s.blocks).firstWhere((b) => b.isImage);
      expect(b.imageWidth, isNotNull);
    });
  });

  group('PDF pages', () {
    test('blocks remember their page', () {
      final pages = [
        'First page text is long enough to be a real page of a book, honestly.',
        'Second page text is also long enough to count as a page of a book.',
      ];
      final book = ingestPdfText(id: 'p', pages: pages);
      final layout = ReadingLayout.build(book);
      expect(layout.hasPages, isTrue);
      expect(layout.unitPage.toList(), [0, 1]);
      expect(layout.unitForPage(1), 1);
    });

    test('a running head with a mangled page number is still removed', () {
      final pages = [
        for (var p = 0; p < 6; p++)
          'Pride and Prejudice${String.fromCharCode(0x18)}${p == 2 ? '10' : ''}\n'
              'Body of page $p goes here and is long enough to read aloud.\n'
              'It has a second line that carries the paragraph further on\n'
              'into a third line and then a fourth line of the same page,\n'
              'which ends the paragraph properly.',
      ];
      final book = ingestPdfText(id: 'x', pages: pages);
      final all = book.sections.expand((s) => s.blocks).map((b) => b.text).join('\n');
      expect(all, isNot(contains('Pride and Prejudice')));
      expect(all.codeUnits.any((c) => c < 0x20 && c != 0x0A), isFalse);
    });
  });

  group('book apparatus', () {
    test('a drop-cap picture gives its letter back to the text', () {
      final blocks = blocksFromHtml(
        '<html><body><div class="figleft"><img alt="&quot;Y" src="y.png"/></div>'
        "<div>OU can't think how glad I am to see you.</div></body></html>",
        href: 'OEBPS/ch.xhtml',
      );
      expect(blocks.map((b) => b.text), contains('"YOU can${"'"}t think how glad I am to see you.'));
      expect(blocks.where((b) => b.isImage), hasLength(1));
    });

    test('printed page numbers and Gutenberg boilerplate are not read', () {
      final blocks = blocksFromHtml(
        '<html><body><header class="pg-boilerplate pgheader"><h2>The Project Gutenberg eBook of X</h2></header>'
        '<p>So she said<span class="pagenum">[127]</span> nothing more.</p></body></html>',
        href: 'OEBPS/ch.xhtml',
      );
      expect(blocks.map((b) => b.text), ['So she said nothing more.']);
    });
  });
}
