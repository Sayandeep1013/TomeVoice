import 'dart:convert';
import 'dart:typed_data';

import 'formats/office.dart';
import 'model.dart';

/// Magic bytes first, then the name, then the MIME type. Never trust the
/// extension alone: phones hand over EPUBs as `.zip`, `.bin` or no name.
SourceKind detectFormat(Uint8List bytes, {String? filename, String? mime}) {
  final name = (filename ?? '').toLowerCase();
  final type = (mime ?? '').toLowerCase();

  if (bytes.length >= 5) {
    final head = String.fromCharCodes(bytes.sublist(0, 5));
    if (head.startsWith('%PDF-')) return SourceKind.pdf;
    if (head.startsWith(r'{\rtf')) return SourceKind.rtf;
  }

  if (bytes.length >= 68) {
    final palm = String.fromCharCodes(bytes.sublist(60, 68));
    if (palm == 'BOOKMOBI' || palm == 'TEXtREAd') return SourceKind.mobi;
  }

  if (bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04) {
    final mimetype = zipMimetype(bytes);
    if (mimetype == 'application/epub+zip') return SourceKind.epub;
    if (mimetype == 'application/vnd.oasis.opendocument.text') {
      return SourceKind.odt;
    }
    final names = zipEntryNames(bytes);
    if (names.contains('META-INF/container.xml')) return SourceKind.epub;
    if (names.contains('word/document.xml')) return SourceKind.docx;
    if (names.contains('content.xml') && names.contains('meta.xml')) {
      return SourceKind.odt;
    }
    if (names.any((n) => n.toLowerCase().endsWith('.fb2'))) return SourceKind.fb2;
    // Some file managers hand over an EPUB as a nameless zip.
    if (name.endsWith('.epub') || type.contains('epub')) return SourceKind.epub;
  }

  final sniff = _utf8Head(bytes, 400).trimLeft();
  if (sniff.contains('<FictionBook')) return SourceKind.fb2;

  if (name.endsWith('.epub') || type.contains('epub')) return SourceKind.epub;
  if (name.endsWith('.pdf') || type.contains('pdf')) return SourceKind.pdf;
  if (name.endsWith('.docx')) return SourceKind.docx;
  if (name.endsWith('.odt')) return SourceKind.odt;
  if (name.endsWith('.fb2') || name.endsWith('.fb2.zip')) return SourceKind.fb2;
  if (RegExp(r'\.(mobi|azw3?|prc|pdb)$').hasMatch(name)) return SourceKind.mobi;
  if (name.endsWith('.md') ||
      name.endsWith('.markdown') ||
      type.contains('markdown')) {
    return SourceKind.markdown;
  }
  if (name.endsWith('.html') ||
      name.endsWith('.htm') ||
      name.endsWith('.xhtml') ||
      type.contains('html')) {
    return SourceKind.html;
  }
  if (name.endsWith('.rtf') || type.contains('rtf')) return SourceKind.rtf;
  if (name.endsWith('.doc')) return SourceKind.unknown;

  final lower = sniff.toLowerCase();
  if (lower.startsWith('<html') ||
      lower.startsWith('<!doctype html') ||
      (lower.startsWith('<?xml') && lower.contains('<html'))) {
    return SourceKind.html;
  }
  if (RegExp(r'^#{1,6}\s', multiLine: true).hasMatch(sniff)) {
    return SourceKind.markdown;
  }
  return SourceKind.text;
}

/// True when [bytes] look like a binary format we do not understand, so the
/// user gets a message instead of a book full of replacement characters.
bool looksBinary(Uint8List bytes) {
  final n = bytes.length < 4096 ? bytes.length : 4096;
  if (n == 0) return false;
  var control = 0;
  var zero = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) zero++;
    if (b < 9 || (b > 13 && b < 32)) control++;
  }
  // UTF-16 text has many zeros but almost no other control bytes.
  if (zero > n / 5 && control - zero < n / 50) return false;
  return control > n / 10;
}

String _utf8Head(Uint8List bytes, int n) {
  final end = bytes.length < n ? bytes.length : n;
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}
