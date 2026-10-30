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
