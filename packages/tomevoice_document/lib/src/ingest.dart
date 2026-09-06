import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'detect.dart';
import 'formats/epub.dart';
import 'formats/text.dart';
import 'model.dart';

/// Turn file bytes into a [Book]. This is the only ingestion entry point the
/// app should call.
Book ingestBytes(
  Uint8List bytes, {
  String? filename,
  String? mime,
  String? id,
}) {
  final kind = detectFormat(bytes, filename: filename, mime: mime);
  final bookId = id ?? sha256.convert(bytes).toString().substring(0, 16);

  switch (kind) {
    case SourceKind.epub:
      return parseEpub(bytes, id: bookId, filename: filename);
    case SourceKind.text:
    case SourceKind.markdown:
    case SourceKind.html:
      return parseText(bytes, id: bookId, filename: filename, kind: kind);
    case SourceKind.pdf:
      throw const UnsupportedDocumentException(
        'This file is a PDF. TomeVoice does not speak PDFs yet — that is the next phase. EPUB, TXT, Markdown and HTML work now.',
      );
    case SourceKind.docx:
      throw const UnsupportedDocumentException(
        'DOCX support is not in this build yet. Use EPUB, TXT, Markdown or HTML.',
      );
    case SourceKind.rtf:
      throw const UnsupportedDocumentException(
        'RTF support is not in this build yet. Use EPUB, TXT, Markdown or HTML.',
      );
    case SourceKind.unknown:
      return parseText(
        bytes,
        id: bookId,
        filename: filename,
        kind: SourceKind.text,
      );
  }
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
  return Book(
    id: book.id,
    metadata: BookMetadata(
      title: title,
      authors: book.metadata.authors,
      language: book.metadata.language,
      publisher: book.metadata.publisher,
      identifier: book.metadata.identifier,
    ),
    sections: book.sections,
    toc: book.toc,
    source: book.source,
    sourceName: book.sourceName,
    wordCount: book.wordCount,
  );
}
