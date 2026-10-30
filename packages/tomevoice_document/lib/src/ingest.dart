import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'detect.dart';
import 'encoding.dart';
import 'formats/epub.dart';
import 'formats/fb2.dart';
import 'formats/mobi.dart';
import 'formats/office.dart';
import 'formats/pdf.dart';
import 'formats/rtf.dart';
import 'formats/text.dart';
import 'language.dart';
import 'model.dart';

/// Turn file bytes into a [Book]. This is the only ingestion entry point the
/// app should call, except for PDFs, whose text the platform extracts first
/// (see [ingestPdfText]).
///
/// Text in an East Asian legacy encoding (GBK, Big5, Shift_JIS, EUC-JP/KR)
/// is decoded by [legacyDecoder]; without one such a book fails with a
/// [LegacyEncodingException]. A decoder that has to wait (a platform
/// channel) goes through [ingestBytesAsync] instead.
Book ingestBytes(
  Uint8List bytes, {
  String? filename,
  String? mime,
  String? id,
  LegacyDecoder? legacyDecoder,
}) {
  final kind = detectFormat(bytes, filename: filename, mime: mime);
  final bookId = id ?? bookIdOf(bytes);
  try {
    return _finish(_parse(kind, bytes, bookId, filename, legacyDecoder));
  } on EncryptedDocumentException {
    rethrow;
  } on UnsupportedDocumentException {
    rethrow;
  } on ParseException {
    rethrow;
  } catch (e, stack) {
    // A damaged file (a cut-off download, a broken zip) trips a parser in
    // ways nobody wrote a message for: "RangeError (byteOffset)" means
    // nothing to a reader. The stack stays with it for whoever debugs.
    Error.throwWithStackTrace(
      ParseException('This ${_kindName(kind)} file looks damaged and could not be read.'),
      stack,
    );
  }
}

String _kindName(SourceKind kind) => switch (kind) {
      SourceKind.epub => 'EPUB',
      SourceKind.mobi => 'Kindle',
      SourceKind.docx => 'Word',
      SourceKind.odt => 'OpenDocument',
      SourceKind.fb2 => 'FB2',
      SourceKind.rtf => 'RTF',
      SourceKind.html => 'HTML',
      SourceKind.markdown => 'Markdown',
      SourceKind.pdf => 'PDF',
      _ => 'text',
    };

Book _parse(SourceKind kind, Uint8List bytes, String bookId, String? filename, LegacyDecoder? legacy) {
  final Book book;
  switch (kind) {
    case SourceKind.epub:
      book = parseEpub(bytes, id: bookId, filename: filename, legacy: legacy);
    case SourceKind.docx:
      book = parseDocx(bytes, id: bookId, filename: filename);
    case SourceKind.odt:
      book = parseOdt(bytes, id: bookId, filename: filename);
    case SourceKind.fb2:
      book = parseFb2(bytes, id: bookId, filename: filename, legacy: legacy);
    case SourceKind.mobi:
      book = parseMobi(bytes, id: bookId, filename: filename);
    case SourceKind.rtf:
      book = parseRtf(bytes, id: bookId, filename: filename, legacy: legacy);
    case SourceKind.text:
    case SourceKind.markdown:
    case SourceKind.html:
      if (looksBinary(bytes)) throw _unknownFormat(filename);
      book = parseText(bytes, id: bookId, filename: filename, kind: kind, legacy: legacy);
    case SourceKind.pdf:
      throw const UnsupportedDocumentException(
        'PDF text has to be extracted on the device first; call ingestPdfText.',
      );
    case SourceKind.web:
    case SourceKind.unknown:
      throw _unknownFormat(filename);
  }
  return book;
}

/// [ingestBytes] with a decoder that answers later, such as Android's
/// java.nio Charset behind a platform channel. The file is parsed to learn
/// which stretches need it, those are decoded, and it is parsed again with
/// the answers: twice the work (rarely three times), but only for such
/// books.
Future<Book> ingestBytesAsync(
  Uint8List bytes, {
  String? filename,
  String? mime,
  String? id,
  required Future<String> Function(Uint8List bytes, String charset) decodeLegacy,
}) async {
  final answers = _Answers();
  for (var pass = 0;; pass++) {
    final asked = <(Uint8List, String)>[];
    Book? book;
    Object? error;
    StackTrace? trace;
    try {
      book = ingestBytes(bytes, filename: filename, mime: mime, id: id, legacyDecoder: (b, charset) {
        final hit = answers.of(b, charset);
        if (hit != null) return hit;
        asked.add((Uint8List.fromList(b), charset));
        // A stand-in for now; this pass is only finding out what to ask.
        return '';
      });
    } on Object catch (e, s) {
      error = e;
      trace = s;
    }
    if (asked.isEmpty || pass >= 3) {
      if (error != null) Error.throwWithStackTrace(error, trace!);
      if (asked.isNotEmpty) throw LegacyEncodingException(asked.first.$2);
      return book!;
    }
    for (final (b, charset) in asked) {
      answers.add(b, charset, await decodeLegacy(b, charset));
    }
  }
}

/// Decoded stretches, found again by their bytes.
class _Answers {
  final _byKey = <(String, int, int), List<(Uint8List, String)>>{};

  (String, int, int) _key(Uint8List b, String charset) =>
      (charset, b.length, b.isEmpty ? 0 : Object.hash(b.first, b.last, b[b.length ~/ 2]));

  void add(Uint8List b, String charset, String text) =>
      (_byKey[_key(b, charset)] ??= []).add((b, text));

  String? of(Uint8List b, String charset) {
    for (final (bytes, text) in _byKey[_key(b, charset)] ?? const <(Uint8List, String)>[]) {
      var same = true;
      for (var i = 0; i < b.length && same; i++) {
        same = bytes[i] == b[i];
      }
      if (same) return text;
    }
    return null;
  }
}

/// A PDF, from the per-page text the platform extracted.
Book ingestPdfText({
  required String id,
  required List<String> pages,
  List<PdfOutlineEntry> outline = const [],
  String? title,
  String? author,
  String? filename,
}) =>
    _finish(bookFromPdfText(
      id: id,
      pages: pages,
      outline: outline,
      title: title,
      author: author,
      filename: filename,
    ));

String bookIdOf(Uint8List bytes) =>
    sha256.convert(bytes).toString().substring(0, 16);

Book _finish(Book book) {
  if (book.sections.isEmpty || book.isEmpty) {
    throw const ParseException('There is no readable text in this file.');
  }
  if (!_hasSomethingToSay(book)) {
    // Pages that are pictures (a comic, a scanned book) come with alt
    // text such as "Page 1", which is not a book to listen to.
    throw book.sections.any((s) => s.blocks.any((b) => b.isImage || b.role == BlockRole.figure))
        ? const UnsupportedDocumentException(
            'This book has no text to read aloud: its pages are pictures (a comic or a scanned book). '
            'TomeVoice reads text, not images.',
          )
        : const ParseException('There is no readable text in this file.');
  }
  return withResolvedLanguage(book);
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Whether any block the voice would read has a letter or a digit in it.
bool _hasSomethingToSay(Book book) =>
    book.sections.any((s) => s.blocks.any((b) => b.speakable && _letterOrDigit.hasMatch(b.text)));

UnsupportedDocumentException _unknownFormat(String? filename) {
  final name = (filename ?? '').toLowerCase();
  if (name.endsWith('.doc')) {
    return const UnsupportedDocumentException(
      'Old Word .doc files are not supported. Save it as .docx and import that.',
    );
  }
  if (RegExp(r'\.(cbz|cbr|djvu|jpg|jpeg|png|webp)$').hasMatch(name)) {
    return const UnsupportedDocumentException(
      'That is a picture-based file. TomeVoice reads text, not images.',
    );
  }
  if (RegExp(r'\.(mp3|m4a|m4b|ogg|wav|flac|opus)$').hasMatch(name)) {
    return const UnsupportedDocumentException(
      'That is already audio — TomeVoice turns text into speech.',
    );
  }
  return const UnsupportedDocumentException(
    'TomeVoice does not recognise this file. It reads EPUB, PDF, DOCX, ODT, '
    'MOBI/AZW, FB2, RTF, HTML, Markdown and plain text.',
  );
}

Book ingestString(
  String text, {
  String filename = 'untitled.txt',
  String? title,
}) {
  final book = ingestBytes(
    Uint8List.fromList(utf8.encode(text)),
    filename: filename,
  );
  if (title == null || title == book.metadata.title) return book;
  return book.copyWith(metadata: book.metadata.copyWith(title: title));
}
