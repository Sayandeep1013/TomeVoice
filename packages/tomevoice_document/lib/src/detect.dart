import 'dart:convert';
import 'dart:typed_data';

import 'formats/office.dart';
import 'model.dart';

/// Sound or pictures: files that are not books, whatever they are called.
enum MediaKind { audio, picture }

/// Brands of MP4-family files that hold pictures (HEIC, AVIF); the rest
/// of the family (M4A, M4B, isom, mp42...) is sound, or a film.
const _pictureBrands = {'heic', 'heix', 'heim', 'heis', 'mif1', 'msf1', 'avif', 'avis'};

/// Audio or pictures, known by their first bytes ("magic"), whatever the
/// extension: an MP3 named song.txt is still a song. Null for anything else.
MediaKind? mediaKindOf(Uint8List b) {
  bool at(int offset, String sig) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig.codeUnitAt(i)) return false;
    }
    return true;
  }

  // ID3v2: "ID3", a version 2-4, and a size of four 7-bit bytes ("ID3 tags
  // explained" is text).
  if (b.length >= 10 &&
      at(0, 'ID3') &&
      b[3] >= 2 &&
      b[3] <= 4 &&
      b[4] < 0x10 &&
      b[6] < 0x80 &&
      b[7] < 0x80 &&
      b[8] < 0x80 &&
      b[9] < 0x80) {
    return MediaKind.audio;
  }
  if (at(0, 'fLaC') || at(0, 'OggS') || (at(0, 'RIFF') && at(8, 'WAVE'))) return MediaKind.audio;
  // An MPEG audio frame (MP3, MP2) or AAC in ADTS, with no tag before it.
  if (b.length >= 4 && b[0] == 0xFF && const {0xFB, 0xFA, 0xF3, 0xF2, 0xF1, 0xF9}.contains(b[1])) {
    return MediaKind.audio;
  }
  if (at(4, 'ftyp') && b.length >= 12) {
    final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
    return _pictureBrands.contains(brand) ? MediaKind.picture : MediaKind.audio;
  }

  if (at(0, String.fromCharCodes(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))) return MediaKind.picture;
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return MediaKind.picture;
  if (at(0, 'GIF87a') || at(0, 'GIF89a') || (at(0, 'RIFF') && at(8, 'WEBP')) || at(0, 'AT&TFORM')) {
    return MediaKind.picture;
  }
  // TIFF, in either byte order.
  if ((at(0, 'II*') && b.length >= 4 && b[3] == 0) || (at(0, 'MM') && b.length >= 4 && b[2] == 0 && b[3] == 0x2A)) {
    return MediaKind.picture;
  }
  // BMP: "BM", the file size, then four reserved bytes that are zero
  // ("BMW makes cars" is text).
  if (b.length >= 26 && at(0, 'BM') && b[6] == 0 && b[7] == 0 && b[8] == 0 && b[9] == 0) return MediaKind.picture;
  return null;
}

/// Magic bytes first, then the name, then the MIME type. Never trust the
/// extension alone: phones hand over EPUBs as `.zip`, `.bin` or no name.
/// Sound and pictures ([mediaKindOf]) are [SourceKind.unknown].
SourceKind detectFormat(Uint8List bytes, {String? filename, String? mime}) {
  final name = (filename ?? '').toLowerCase();
  final type = (mime ?? '').toLowerCase();

  if (mediaKindOf(bytes) != null) return SourceKind.unknown;

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
///
/// Text has no NUL bytes, except UTF-16 and UTF-32, where they fall in
/// step (every other byte, in Latin text); and almost no control
/// characters besides tab, line and page breaks, and ESC (which
/// ISO-2022-JP switches with). A header followed by zeros (an MP3's ID3
/// tag) used to pass for UTF-16.
bool looksBinary(Uint8List bytes) {
  final n = bytes.length < 4096 ? bytes.length : 4096;
  if (n == 0) return false;
  if (n >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) return false;
  if (n >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF) return false;
  var control = 0;
  var zeroOdd = 0, zeroEven = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) {
      if (i.isOdd) {
        zeroOdd++;
      } else {
        zeroEven++;
      }
    } else if (b < 0x20 && !_textControls.contains(b)) {
      control++;
    }
  }
  final zero = zeroOdd + zeroEven;
  // UTF-16 without a mark: zeros on one side only, nothing else odd.
  final utf16 = (zeroOdd > n / 5 && zeroEven < n / 50) || (zeroEven > n / 5 && zeroOdd < n / 50);
  if (utf16 && control < n / 50) return false;
  if (zero > 1) return true;
  return control > n / 50;
}

/// Tab, line feed, vertical tab, form feed, carriage return, DOS's end of
/// file and ESC: control characters that text does contain.
const _textControls = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1A, 0x1B};

String _utf8Head(Uint8List bytes, int n) {
  final end = bytes.length < n ? bytes.length : n;
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}
