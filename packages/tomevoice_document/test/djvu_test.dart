import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/src/formats/bzz.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'djvu_fixture.dart';

// DjVu read by its text layer. The two files in test/fixtures are pages of
// a real scan (see test/fixtures/README.md); everything else is built here.

Uint8List _fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

List<String> _texts(Book b) => [
      for (final s in b.sections)
        for (final bl in s.blocks) bl.text,
    ];

/// A page of a built file: its INFO, and its text layer (packed, as TXTz,
/// unless [plain]).
List<int> _page(List<List<String>> paragraphs, {bool plain = false, bool paragraphZones = true, List<List<int>> more = const []}) {
  final layer = pageText(paragraphs, paragraphZones: paragraphZones);
  return form('DJVU', [
    info(),
    plain ? chunk('TXTa', layer) : chunk('TXTz', bzzEncode(layer)),
    ...more,
  ]);
}

/// A page with no text layer: its picture is all there is.
List<int> _picture() => form('DJVU', [info()]);

Part _part(String id, List<int> form, {int type = 1, String? title}) => (id: id, type: type, title: title, form: form);

/// Prose for page [p]: sentences that end, so no paragraph runs into the
/// next, and words that differ from page to page, so none is a running head.
List<List<String>> _prose(int p) => [
      ['The tide came up the estuary on day $p, filling the', 'channels one by one until the mud was gone.'],
      ['Nobody on the quay looked up from the nets that', 'morning, and the gulls had the harbour to themselves.'],
    ];

Matcher _refused(String why) =>
    throwsA(isA<UnsupportedDocumentException>().having((e) => e.message, 'message', contains(why)));

void main() {
  group('BZZ', () {
    test('unpacks a text layer as archive.org packed it', () {
      // Page 2 of the scan in test/fixtures, its TXTz chunk as it was made:
      // the OCR's few words, then the zones that place them.
      const packed = [
        0xff, 0xff, 0x3c, 0x87, 0x97, 0x5a, 0x29, 0x18, 0x8a, 0x41, 0x39, 0xcc, 0x3c, 0xb4, 0x27, 0x4f, //
        0x34, 0x40, 0xb9, 0x84, 0x99, 0xc9, 0x1a, 0x23, 0x74, 0x8c, 0x2f, 0xab, 0x17, 0xdd, 0xa2, 0x77,
        0x27, 0x92, 0xeb, 0x1f, 0x1b, 0xfc, 0x43, 0xf6, 0x11, 0xde, 0x8a, 0xcf, 0x13, 0xed, 0x61, 0xb2,
        0xff, 0xdd, 0xd2, 0x87, 0x38, 0xc2, 0x55, 0x63, 0xb7, 0xc5, 0xc4, 0x60, 0x00, 0x39, 0x54, 0x28,
        0x05, 0xad, 0x1d, 0xa8, 0x62, 0x37, 0x3d, 0x70, 0x59, 0x13, 0x4a, 0x3d, 0x40, 0x43, 0xa1, 0xf1,
        0x29, 0xf8, 0xbd, 0x8c, 0xb0, 0x3a, 0x7d, 0x27, 0x26, 0x19, 0x4b, 0xe6, 0x86, 0xc6, 0xe4, 0x84,
        0x1c, 0xb8, 0x34, 0x9c, 0x1d, 0xb2, 0x09, 0x14, 0x3e, 0xcf, 0xee, 0x0f,
      ];
      final out = bzzDecode(Uint8List.fromList(packed));
      expect(out.length, 194);
      // 20 bytes of text (its separators and a closing zero among them),
      // then the zones' version.
      expect(out.sublist(0, 3), [0, 0, 20]);
      expect(latin1.decode(out.sublist(3, 23)), '35*5 \n\x1FSSI** 3 \n\x1F\x1D\x0B\x00');
      expect(out[23], 1);
      expect(sha256.convert(out).toString(), '3a53e2c703760f337726708be718e6712bb836bf4166d6dfc3f0329e03b9ad6c');
    });

    test('unpacks what it is given packed, in one block or many', () {
      final random = Random(7);
      final cases = <String, List<int>>{
        'empty': [],
        'one byte': [65],
        'banana': ascii.encode('banana'),
        'every byte': [for (var r = 0; r < 3; r++) ...List.generate(256, (i) => i)],
        'one byte over and over': List.filled(5000, 0x61),
        'noise': List.generate(6000, (_) => random.nextInt(256)),
        'text': utf8.encode('Ça va? Ελληνικά, русский, বাংলা. ' * 40),
      };
      for (final e in cases.entries) {
        expect(bzzDecode(bzzEncode(e.value)), e.value, reason: e.key);
        expect(bzzDecode(bzzEncode(e.value, blockSize: 700)), e.value, reason: '${e.key}, in blocks');
      }
    });

    test('data cut short is an error or what DjVuLibre makes of it, never a hang', () {
      final data = utf8.encode('The tide came up the estuary, filling the channels one by one. ' * 30);
      final packed = bzzEncode(data);
      var failed = 0;
      for (var cut = 0; cut < packed.length; cut++) {
        try {
          // What is missing is read as 0xFF bytes, as DjVuLibre reads it, up
          // to 25 of them: the last bytes of padding gone, the whole still
          // reads; nearly everything gone, a block can be made up of them.
          // A file cut short is caught before this, by its chunks' sizes.
          final out = bzzDecode(Uint8List.sublistView(packed, 0, cut));
          if (cut > packed.length - 4) expect(out, data, reason: 'cut at $cut');
        } on FormatException {
          failed++;
        }
      }
      expect(failed, greaterThan(packed.length * 3 ~/ 4));
    });

    test('noise comes out as an error or as bytes, and does not run away', () {
      final random = Random(11);
      for (var i = 0; i < 300; i++) {
        final noise = Uint8List.fromList(List.generate(20 + random.nextInt(200), (_) => random.nextInt(256)));
        try {
          expect(bzzDecode(noise, maxLength: 1 << 16).length, lessThanOrEqualTo(1 << 16));
        } on FormatException {
          // As it should, mostly.
        }
      }
    });
  });

  group('DjVu is known', () {
    test('by its first bytes, its name or its type, and is not taken for a picture', () {
      final bytes = djvuFile(_page(_prose(0)));
      expect(mediaKindOf(bytes), isNull);
      expect(detectFormat(bytes), SourceKind.djvu);
      expect(detectFormat(bytes, filename: 'scan.pdf'), SourceKind.djvu);
      final unknown = Uint8List.fromList(utf8.encode('not a DjVu at all'));
      expect(detectFormat(unknown, filename: 'Scan.DJVU'), SourceKind.djvu);
      expect(detectFormat(unknown, filename: 'scan.djv'), SourceKind.djvu);
      expect(detectFormat(unknown, mime: 'image/vnd.djvu'), SourceKind.djvu);
      expect(detectFormat(unknown, mime: 'image/x-djvu'), SourceKind.djvu);
      expect(() => ingestBytes(unknown, filename: 'scan.djvu'), throwsA(isA<ParseException>()));
    });
  });

  group('a real scan', () {
    test('one page, as archive.org made it: its dialogue a paragraph a speech', () {
      final book = ingestBytes(_fixture('game-of-comedy-p8.djvu'), filename: 'game-of-comedy-p8.djvu');
      expect(book.source, SourceKind.djvu);
      expect(book.metadata.title, 'game-of-comedy-p8');
      final texts = _texts(book);
      expect(texts, contains('Pierre. Ah, now I recollect your face.'));
      expect(texts, contains('Marie. Yes, monsieur. If I can act.'));
      expect(
        texts,
        contains('Pierre. He will speak to me, at any rate. I can hear him. " Pierre, show this person out."'),
      );
      for (final s in book.sections) {
        for (final b in s.blocks) {
          expect(b.anchor, isA<PageAnchor>().having((a) => a.page, 'page', 0));
        }
      }
    });

    test('twenty pages bundled: read in order, running heads left out, words and paragraphs mended over lines and pages', () {
      final bytes = _fixture('game-of-comedy.djvu');
      final text = readDjvuText(bytes);
      expect(text.pages, hasLength(20));
      expect(text.bookmarks, isEmpty);
      expect(text.pages[8], startsWith('A GAME OF COMEDY. 5'));

      final book = ingestBytes(bytes, filename: 'A Game of Comedy.djvu');
      expect(book.metadata.title, 'A Game of Comedy');
      final texts = _texts(book);
      final all = texts.join('\n');
      // The running heads: "4 A GAME OF COMEDY.", "A GAME OF COMEDY. 5".
      expect(all, isNot(contains('A GAME OF COMEDY. 5')));
      expect(all, isNot(contains('4 A GAME OF COMEDY.')));
      // "wood-bas-" over "ket at fireplace".
      expect(all, contains('wood-basket at fireplace'));
      expect(texts, contains('Pierre. Goodness ! A woman !'));
      // Fromont's speech runs from page 8 over to page 9.
      final speech = texts.firstWhere((t) => t.startsWith('Fromont. But my engagement ?'));
      expect(speech, contains('greeted with smirking satisfaction'));
      // Blocks keep the page they start on, in order.
      final pages = [
        for (final s in book.sections)
          for (final b in s.blocks) (b.anchor as PageAnchor).page,
      ];
      expect(pages, orderedEquals([...pages]..sort()));
      expect(pages.last, 19);
    });

    test('cut short anywhere, or damaged, it fails with a message', () {
      final bytes = _fixture('game-of-comedy.djvu');
      for (final keep in [20, 100, bytes.length ~/ 3, bytes.length ~/ 2, bytes.length - 5]) {
        expect(
          () => ingestBytes(Uint8List.sublistView(bytes, 0, keep), filename: 'cut.djvu'),
          throwsA(isA<ParseException>()),
          reason: 'kept $keep bytes',
        );
      }
      final page = _fixture('game-of-comedy-p8.djvu');
      final random = Random(3);
      for (var i = 0; i < 150; i++) {
        final damaged = Uint8List.fromList(page);
        for (var k = 0; k < 4; k++) {
          damaged[16 + random.nextInt(damaged.length - 16)] = random.nextInt(256);
        }
        try {
          ingestBytes(damaged, filename: 'damaged.djvu');
        } on ParseException {
          // Damaged.
        } on UnsupportedDocumentException {
          // Its text layer was the part damaged.
        }
      }
    });
  });

  group('a built DjVu', () {
    test('a bundled book: its outline its chapters, its metadata its title and author', () {
      final pages = [
        _page([
          ['Chapter 1'],
          ..._prose(1),
        ]),
        _page(_prose(2)),
        _page([
          ['Chapter 2'],
          ..._prose(3),
        ]),
        _page(_prose(4)),
      ];
      final shared = form('DJVI', [
        chunk('ANTz', bzzEncode(utf8.encode('(metadata (title "The Harbour \\"Log\\"") (author "Mary Quay") (year "1901"))'))),
      ]);
      final bytes = bundle(
        [
          _part('shared_anno.iff', shared, type: 3),
          for (var i = 0; i < pages.length; i++) _part('p000${i + 1}.djvu', pages[i]),
        ],
        extra: [
          chunk('NAVM', navm([
            const Bookmark('The Harbour', '#1', [
              Bookmark('Chapter 1', '#1'),
              Bookmark('Chapter 2', '#p0003.djvu'),
            ]),
          ])),
        ],
      );
      final text = readDjvuText(bytes);
      expect(text.pages, hasLength(4));
      expect([for (final b in text.bookmarks) (b.title, b.page, b.level)], [
        ('The Harbour', 0, 0),
        ('Chapter 1', 0, 1),
        ('Chapter 2', 2, 1),
      ]);
      final book = ingestBytes(bytes, filename: 'harbour.djvu');
      expect(book.metadata.title, 'The Harbour "Log"');
      expect(book.metadata.authors, ['Mary Quay']);
      expect([for (final s in book.sections) s.displayTitle], ['Chapter 1', 'Chapter 2']);
      final second = book.sections[1].blocks;
      expect(second.first.text, 'Chapter 2');
      expect((second.first.anchor as PageAnchor).page, 2);
    });

    test('plain text layers (TXTa), and a page whose text is in a file it includes', () {
      final included = form('DJVI', [chunk('TXTz', bzzEncode(pageText(_prose(2))))]);
      final bytes = bundle([
        _part('p0001.djvu', _page(_prose(1), plain: true)),
        _part('text2.djvi', included, type: 0),
        _part('p0002.djvu', form('DJVU', [info(), chunk('INCL', utf8.encode('text2.djvi'))])),
      ]);
      final text = readDjvuText(bytes);
      expect(text.pages, hasLength(2));
      expect(text.pages[0], contains('on day 1'));
      expect(text.pages[1], contains('on day 2'));
      expect(_texts(ingestBytes(bytes)), contains(startsWith('The tide came up the estuary on day 2')));
    });

    test('one page, no directory', () {
      final book = ingestBytes(djvuFile(_page(_prose(5))), filename: 'one.djvu');
      expect(_texts(book), [
        'The tide came up the estuary on day 5, filling the channels one by one until the mud was gone.',
        'Nobody on the quay looked up from the nets that morning, and the gulls had the harbour to themselves.',
      ]);
    });

    test('lines with no paragraphs over them are told into paragraphs by the space between', () {
      final page = _page(_prose(6), paragraphZones: false);
      final text = readDjvuText(djvuFile(page)).pages.single;
      expect(text.split(pdfParagraphMark), hasLength(2));
    });

    test('a word broken at a line end is mended', () {
      final book = ingestBytes(djvuFile(_page([
        ['The ice melted and the rivers carried yel-', 'low clay over the plain to the sea.'],
      ])));
      expect(_texts(book), ['The ice melted and the rivers carried yellow clay over the plain to the sea.']);
    });

    test('with no zones, the separators in the text say where paragraphs end', () {
      final layer = textLayer('The first paragraph runs over\ntwo lines of the page.\n\x1FThe second has one.\n\x1F');
      final book = ingestBytes(djvuFile(form('DJVU', [info(), chunk('TXTa', layer)])));
      expect(_texts(book), ['The first paragraph runs over two lines of the page.', 'The second has one.']);
    });

    test('pictures only: a clear refusal', () {
      expect(
        () => ingestBytes(bundle([for (var i = 0; i < 3; i++) _part('p$i.djvu', _picture())]), filename: 'scan.djvu'),
        _refused('This DjVu has no text to read aloud: its pages are pictures only'),
      );
      expect(() => ingestBytes(djvuFile(_picture())), _refused('no text to read aloud'));
      // A text layer with nothing in it is no better.
      expect(
        () => ingestBytes(djvuFile(form('DJVU', [info(), chunk('TXTa', textLayer('  \n'))]))),
        _refused('no text to read aloud'),
      );
    });

    test('one file per page (indirect) is refused, saying why', () {
      final indirect = bundle([_part('p1.djvu', _page(_prose(1))), _part('p2.djvu', _page(_prose(2)))], bundled: false);
      expect(() => ingestBytes(indirect, filename: 'index.djvu'), _refused('indirect'));
      expect(() => ingestBytes(djvuFile(form('DJVI', [chunk('Djbz', [1, 2, 3])]))), _refused('indirect'));
    });

    test('a damaged outline or text layer costs only itself', () {
      final bytes = bundle(
        [
          _part('p1.djvu', _page(_prose(1))),
          _part('p2.djvu', form('DJVU', [info(), chunk('TXTz', [1, 2, 3, 4, 5, 6, 7, 8])])),
          _part('p3.djvu', _page(_prose(3))),
        ],
        extra: [
          chunk('NAVM', [9, 9, 9, 9]),
        ],
      );
      final text = readDjvuText(bytes);
      expect(text.bookmarks, isEmpty);
      expect(text.pages[1], isEmpty);
      expect(text.pages[2], contains('on day 3'));
    });
  });
}
