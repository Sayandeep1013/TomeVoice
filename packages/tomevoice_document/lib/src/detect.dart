import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// Extension first, then magic bytes. Never trust the extension alone.
SourceKind detectFormat(Uint8List bytes, {String? filename, String? mime}) {
  final name = (filename ?? '').toLowerCase();
  final type = (mime ?? '').toLowerCase();

  if (bytes.length >= 5) {
    final head = String.fromCharCodes(bytes.sublist(0, 5));
    if (head.startsWith('%PDF-')) return SourceKind.pdf;
  }

  if (bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04) {
    final asString = _asciiHead(bytes, 1024);
    if (asString.contains('mimetype') &&
        _containsEpubMimetype(bytes)) {
      return SourceKind.epub;
    }
    if (asString.contains('word/document.xml')) return SourceKind.docx;
    // Some file managers hand over an EPUB as a nameless zip.
    if (name.endsWith('.epub') || type.contains('epub')) return SourceKind.epub;
  }

  if (name.endsWith('.epub') || type.contains('epub')) return SourceKind.epub;
  if (name.endsWith('.pdf') || type.contains('pdf')) return SourceKind.pdf;
  if (name.endsWith('.docx')) return SourceKind.docx;
  if (name.endsWith('.md') || name.endsWith('.markdown') || type.contains('markdown')) {
    return SourceKind.markdown;
  }
  if (name.endsWith('.html') ||
      name.endsWith('.htm') ||
      name.endsWith('.xhtml') ||
      type.contains('html')) {
    return SourceKind.html;
  }
  if (name.endsWith('.rtf') || type.contains('rtf')) return SourceKind.rtf;

  final sniff = _utf8Head(bytes, 200).trimLeft().toLowerCase();
  if (sniff.startsWith('<html') ||
      sniff.startsWith('<!doctype html') ||
      sniff.startsWith('<?xml')) {
    return SourceKind.html;
  }
  if (RegExp(r'^#{1,6}\s', multiLine: true).hasMatch(_utf8Head(bytes, 400))) {
    return SourceKind.markdown;
  }
  if (name.endsWith('.txt') || type.startsWith('text/')) return SourceKind.text;

  return SourceKind.text;
}

bool _containsEpubMimetype(Uint8List bytes) {
  final window = bytes.length < 256 ? bytes.length : 256;
  final head = String.fromCharCodes(bytes.sublist(0, window));
  return head.contains('application/epub+zip');
}

String _asciiHead(Uint8List bytes, int n) {
  final end = bytes.length < n ? bytes.length : n;
  final out = StringBuffer();
  for (var i = 0; i < end; i++) {
    final b = bytes[i];
    out.writeCharCode(b >= 32 && b < 127 ? b : 32);
  }
  return out.toString();
}

String _utf8Head(Uint8List bytes, int n) {
  final end = bytes.length < n ? bytes.length : n;
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}
