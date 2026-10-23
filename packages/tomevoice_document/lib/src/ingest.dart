import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'detect.dart';
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
Book ingestBytes(
  Uint8List bytes, {
  String? filename,
  String? mime,
  String? id,
}) {
  final kind = detectFormat(bytes, filename: filename, mime: mime);
  final bookId = id ?? bookIdOf(bytes);

  final Book book;
  switch (kind) {
    case SourceKind.epub:
      book = parseEpub(bytes, id: bookId, filename: filename);
    case SourceKind.docx:
      book = parseDocx(bytes, id: bookId, filename: filename);
    case SourceKind.odt:
      book = parseOdt(bytes, id: bookId, filename: filename);
    case SourceKind.fb2:
      book = parseFb2(bytes, id: bookId, filename: filename);
    case SourceKind.mobi:
      book = parseMobi(bytes, id: bookId, filename: filename);
    case SourceKind.rtf:
      book = parseRtf(bytes, id: bookId, filename: filename);
    case SourceKind.text:
    case SourceKind.markdown:
    case SourceKind.html:
      if (looksBinary(bytes)) throw _unknownFormat(filename);
      book = parseText(bytes, id: bookId, filename: filename, kind: kind);
    case SourceKind.pdf:
      throw const UnsupportedDocumentException(
        'PDF text has to be extracted on the device first; call ingestPdfText.',
      );
    case SourceKind.web:
    case SourceKind.unknown:
      throw _unknownFormat(filename);
  }
  return _finish(book);
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
  return withResolvedLanguage(book);
}

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
