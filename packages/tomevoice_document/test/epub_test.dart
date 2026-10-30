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

void main() {
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
}
