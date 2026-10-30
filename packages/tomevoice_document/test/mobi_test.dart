import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'kf8_fixture.dart';

List<String> _texts(Book b) => [
      for (final s in b.sections)
        for (final bl in s.blocks) bl.text,
    ];

void main() {
  final parts = [
    ['<div class="cover"><p>A Tale of the Coast</p></div>'],
    [
      '<h1>Chapter One</h1><p>The lamp was lit at dusk.</p>',
      '<p>It burned until the boats came home.</p>',
    ],
    ['<h1>Chapter Two</h1><p>The tide turned at <a href="kindle:pos:fid:0001:off:0000">noon</a>.</p>'],
  ];
  const toc = [(title: 'The Lamp', fragment: 1), (title: 'The Tide', fragment: 3)];

  group('KF8 (AZW3)', () {
    test('parts are rebuilt from skeleton and fragments, chapters named from the NCX', () {
      final book = ingestBytes(kf8Book(parts: parts, toc: toc), filename: 'tale.azw3');
      expect(book.source, SourceKind.mobi);
      expect(book.metadata.title, 'A Tale of the Coast');
      expect(_texts(book), [
        'A Tale of the Coast',
        'Chapter One',
        'The lamp was lit at dusk.',
        'It burned until the boats came home.',
        'Chapter Two',
        'The tide turned at noon.',
      ]);
      expect(book.sections.map((s) => s.title), [null, 'The Lamp', 'The Tide']);
      expect(book.sections[1].blocks.first.role, BlockRole.heading);
    });

    test('the stylesheet stored after the text is not read', () {
      final all = _texts(ingestBytes(kf8Book(parts: parts, toc: toc), filename: 'tale.azw3')).join(' ');
      expect(all, isNot(contains('margin')));
      expect(all, isNot(contains('font-size')));
    });

    test('chapters sharing a part are cut at their headings', () {
      final book = ingestBytes(
        kf8Book(
          parts: [
            [
              '<h1>Chapter One</h1><p>The lamp was lit at dusk.</p>',
              '<h1>Chapter Two</h1><p>The tide turned at noon.</p>',
            ],
          ],
          toc: const [(title: 'Chapter One', fragment: 0), (title: 'Chapter Two', fragment: 1)],
        ),
        filename: 'one.azw3',
      );
      expect(book.sections.map((s) => s.title), ['Chapter One', 'Chapter Two']);
      expect(book.sections[1].blocks.map((b) => b.text), ['Chapter Two', 'The tide turned at noon.']);
    });

    test("a story's numbered parts stay inside it, as in an EPUB's file", () {
      // calibre's contents for a story told in parts: the story, then its
      // parts I and II one level down, all in one file.
      final book = ingestBytes(
        kf8Book(
          parts: [
            [
              '<h1>A Scandal in Bohemia</h1><h2>I</h2><p>The lamp was lit at dusk.</p>',
              '<h2>II</h2><p>The tide turned at noon.</p>',
            ],
            ['<h1>The Red-Headed League</h1><p>A visitor came at last.</p>'],
            ['<h1>Chapter 3</h1><p>The road ran on.</p>', '<h2>Chapter 4</h2><p>It ended.</p>'],
          ],
          toc: const [
            (title: 'A Scandal in Bohemia', fragment: 0),
            (title: 'I', fragment: 0),
            (title: 'II', fragment: 1),
            (title: 'The Red-Headed League', fragment: 2),
            (title: 'Chapter 3', fragment: 3),
            (title: 'Chapter 4', fragment: 4),
          ],
          depths: const {1: 1, 2: 1, 5: 1},
        ),
        filename: 'holmes.azw3',
      );
      // A deeper entry still cuts when it is a chapter of its own.
      expect(book.sections.map((s) => s.title), [
        'A Scandal in Bohemia',
        'The Red-Headed League',
        'Chapter 3',
        'Chapter 4',
      ]);
    });

    test('without an NCX, parts are chapters named by their headings', () {
      final book = ingestBytes(kf8Book(parts: parts), filename: 'tale.azw3');
      expect(book.sections.map((s) => s.displayTitle).skip(1), ['Chapter One', 'Chapter Two']);
    });

    test('when its tables do not read, the text is still read, without the stylesheet', () {
      final book = ingestBytes(
        kf8Book(
          parts: [
            ['<h1>Chapter One</h1><p>The lamp was lit at dusk.</p>'],
            ['<p>Still the first chapter.</p><mbp:pagebreak/><h1>Chapter Two</h1>'],
            ['<p>The tide turned at noon.</p>'],
          ],
          brokenSkeletons: true,
        ),
        filename: 'tale.azw3',
      );
      final all = _texts(book).join(' ');
      expect(all, contains('The lamp was lit at dusk.'));
      expect(all, contains('The tide turned at noon.'));
      expect(all, isNot(contains('margin')));
      // Cut at page breaks, as a MOBI 6 book is.
      expect(book.sections.map((s) => s.displayTitle), ['Chapter One', 'Chapter Two']);
    });

    test("Project Gutenberg's header and licence are not read, though calibre renamed their class", () {
      // Gutenberg's Kindle files: Ebookmaker's header and footer keep their
      // ids, the licence runs on into a part of its own, and every class
      // is calibre's.
      final book = ingestBytes(
        kf8Book(parts: [
          [
            '<header id="pg-header" class="calibre1"><p class="calibre2">Title: A Tale of the Coast</p>'
                '<p class="calibre2">Credits: Produced by volunteers</p></header>',
            '<h1 class="calibre3">Chapter One</h1><p class="calibre4">The lamp was lit at dusk.</p>',
            '<footer id="pg-footer" class="calibre5"><div class="calibre6">Updated editions will replace the previous one.</div></footer>',
          ],
          [
            '<footer id="pg-footer" class="calibre5"><h2 class="calibre7">THE FULL LICENSE</h2>'
                '<p class="calibre6">PLEASE READ THIS BEFORE YOU DISTRIBUTE OR USE THIS WORK.</p></footer>',
          ],
        ]),
        filename: 'pg.azw3',
      );
      expect(_texts(book), ['Chapter One', 'The lamp was lit at dusk.']);
    });

    test('a joint MOBI 6 and KF8 file is read from its KF8 half', () {
      final book = ingestBytes(kf8Book(parts: parts, toc: toc, joint: true), filename: 'tale.mobi');
      expect(_texts(book), isNot(contains('The old copy.')));
      expect(book.sections.map((s) => s.title), [null, 'The Lamp', 'The Tide']);
    });
  });

  group('damaged Kindle files', () {
    test('a file cut short gives a plain message, wherever it is cut', () {
      final whole = kf8Book(parts: parts, toc: toc);
      for (var n = 0; n < whole.length; n += 7) {
        try {
          ingestBytes(Uint8List.sublistView(whole, 0, n), filename: 'cut.azw3');
        } on ParseException {
          // The plain message.
        } on UnsupportedDocumentException {
          // Too little left to be anything.
        }
      }
      expect(
        () => ingestBytes(Uint8List.sublistView(whole, 0, 120), filename: 'cut.azw3'),
        throwsA(isA<ParseException>().having((e) => e.message, 'message', isNot(contains('Range')))),
      );
    });
  });
}
