import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'epub_fixture.dart';

void main() {
  group('detectFormat', () {
    test('reads EPUB magic even when the extension is wrong', () {
      final bytes = minimalEpub();
      expect(detectFormat(bytes, filename: 'book.bin'), SourceKind.epub);
    });

    test('PDF magic wins over a .txt name', () {
      final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7 junk'));
      expect(detectFormat(bytes, filename: 'paper.txt'), SourceKind.pdf);
    });

    test('markdown from heading sniff', () {
      final bytes = Uint8List.fromList(utf8.encode('# Title\n\nHello.\n'));
      expect(detectFormat(bytes, filename: 'notes'), SourceKind.markdown);
    });
  });

  group('segmentSentences', () {
    test('splits on terminal punctuation', () {
      final s = segmentSentences(
        'The quick brown fox jumps over the lazy dog. Pack my box.',
      );
      expect(s, hasLength(2));
      expect(s.first.words, isNotEmpty);
    });

    test('does not split on Dr. or Mr.', () {
      final s = segmentSentences('Dr. Smith saw Mr. Jones today. Then they left.');
      expect(s, hasLength(2));
      expect(s.first.of('Dr. Smith saw Mr. Jones today. Then they left.'),
          contains('Mr. Jones'));
    });
  });

  group('ingest text', () {
    test('blank-line paragraphs become blocks', () {
      final book = ingestString(
        'CHAPTER ONE\n\nHello world. Another sentence.\n\nSecond paragraph.',
        filename: 'novel.txt',
      );
      expect(book.source, SourceKind.text);
      expect(book.sections, hasLength(1));
      expect(book.sections.first.blocks.length, greaterThanOrEqualTo(2));
      final spoken = flattenSpeakable(book);
      expect(spoken.first.text, contains('CHAPTER ONE'));
    });
  });

  group('ingest markdown', () {
    test('headings start sections', () {
      final book = ingestString(
        '# One\n\nFirst chapter text.\n\n# Two\n\nSecond chapter text.',
        filename: 'notes.md',
      );
      expect(book.source, SourceKind.markdown);
      expect(book.sections.length, greaterThanOrEqualTo(2));
    });
  });

  group('ingest epub', () {
    test('reads metadata, spine and skips footnotes by default', () {
      final book = ingestBytes(minimalEpub(), filename: 'fox.epub');
      expect(book.metadata.title, 'Fox Book');
      expect(book.metadata.authors, ['Aesop']);
      expect(book.sections, hasLength(2));
      expect(book.toc.map((t) => t.title), containsAll(['The fox', 'The jugs']));

      final spoken = flattenSpeakable(book);
      expect(spoken.any((s) => s.text.contains('quick brown fox')), isTrue);
      expect(spoken.any((s) => s.text.contains('footnote')), isFalse);
    });

    test('PDF is refused with a clear next-phase message', () {
      expect(
        () => ingestBytes(
          Uint8List.fromList(utf8.encode('%PDF-1.7')),
          filename: 'paper.pdf',
        ),
        throwsA(isA<UnsupportedDocumentException>()),
      );
    });

    test('refuses encrypted books', () {
      expect(
        () => ingestBytes(minimalEpub(encrypted: true), filename: 'locked.epub'),
        throwsA(isA<EncryptedDocumentException>()),
      );
    });

    test('round-trips through JSON', () {
      final book = ingestBytes(minimalEpub(), filename: 'fox.epub');
      final copy = Book.fromJson(book.toJson());
      expect(copy.metadata.title, book.metadata.title);
      expect(copy.sections.length, book.sections.length);
      expect(copy.sections, isNotEmpty);
      expect(copy.sections.first.blocks, isNotEmpty);
      expect(copy.sections.first.blocks.first.text,
          book.sections.first.blocks.first.text);
    });
  });

  group('cursor', () {
    test('indexOfCursor finds the spoken unit', () {
      final book = ingestBytes(minimalEpub(), filename: 'fox.epub');
      final units = flattenSpeakable(book);
      expect(units, isNotEmpty);
      final i = indexOfCursor(units, cursorOf(units.last));
      expect(i, units.length - 1);
    });
  });
}
