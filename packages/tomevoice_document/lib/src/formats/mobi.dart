import 'dart:convert';
import 'dart:typed_data';

import '../build.dart';
import '../model.dart';
import 'html_blocks.dart';
import 'text.dart';

/// Kindle MOBI / AZW / AZW3 / PRC without DRM.
///
/// A PalmDB container whose text records are PalmDOC-compressed HTML. Only
/// PalmDOC (and uncompressed) text is supported; HUFF/CDIC books and anything
/// encrypted get a clear message instead of garbage.
Book parseMobi(Uint8List bytes, {required String id, String? filename}) {
  try {
    return _parseMobi(bytes, id: id, filename: filename);
  } on RangeError {
    // A header or table that points past the end of what is there.
    throw _cutShort;
  }
}

const _cutShort = ParseException(
  'This Kindle book is incomplete or damaged: the file ends too soon.',
);

Book _parseMobi(Uint8List bytes, {required String id, String? filename}) {
  if (bytes.length < 86) throw const ParseException('File is too short to be a MOBI.');
  final bd = ByteData.sublistView(bytes);
  final type = String.fromCharCodes(bytes.sublist(60, 68));
  if (type != 'BOOKMOBI' && type != 'TEXtREAd') {
    throw const ParseException('Not a MOBI/AZW file.');
  }
  final count = bd.getUint16(76);
  if (count == 0 || 78 + count * 8 > bytes.length) throw _cutShort;
  final offsets = [
    for (var i = 0; i < count; i++) bd.getUint32(78 + i * 8),
  ];
  Uint8List record(int i) {
    if (i < 0 || i >= count || offsets[i] > bytes.length) throw _cutShort;
    final start = offsets[i];
    final end = i + 1 < count ? offsets[i + 1] : bytes.length;
    return Uint8List.sublistView(bytes, start, end.clamp(start, bytes.length));
  }

  final r0 = record(0);
  final h = ByteData.sublistView(r0);
  final compression = h.getUint16(0);
  final textRecords = h.getUint16(8);
  final encryption = h.getUint16(12);
  if (encryption != 0) {
    throw const EncryptedDocumentException(
      'This Kindle book is DRM-protected. TomeVoice cannot open encrypted files.',
    );
  }
  if (compression != 1 && compression != 2) {
    throw const UnsupportedDocumentException(
      'This Kindle book uses HUFF/CDIC compression, which TomeVoice cannot '
      'read yet. Convert it to EPUB (e.g. with Calibre) and import that.',
    );
  }

  var utf = false;
  var extraFlags = 0;
  String? fullName;
  String? author;
  String? language;
  if (type == 'BOOKMOBI' && r0.length >= 24 && String.fromCharCodes(r0.sublist(16, 20)) == 'MOBI') {
    final headerLen = h.getUint32(20);
    utf = h.getUint32(28) == 65001;
    if (headerLen >= 0xE4 && r0.length >= 16 + 0xE4) {
      extraFlags = h.getUint16(0xF2);
    }
    final nameOff = h.getUint32(84);
    final nameLen = h.getUint32(88);
    if (nameOff + nameLen <= r0.length) {
      fullName = _str(r0.sublist(nameOff, nameOff + nameLen), utf);
    }
    final hasExth = (h.getUint32(128) & 0x40) != 0;
    final exthAt = 16 + headerLen;
    if (hasExth && exthAt + 12 <= r0.length &&
        String.fromCharCodes(r0.sublist(exthAt, exthAt + 4)) == 'EXTH') {
      final n = h.getUint32(exthAt + 8);
      var p = exthAt + 12;
      for (var i = 0; i < n && p + 8 <= r0.length; i++) {
        final t = h.getUint32(p);
        final len = h.getUint32(p + 4);
        if (len < 8 || p + len > r0.length) break;
        final v = _str(r0.sublist(p + 8, p + len), utf);
        if (t == 100) author ??= v;
        if (t == 503) fullName = v;
        if (t == 524) language ??= v;
        p += len;
      }
    }
  }

  final html = BytesBuilder(copy: false);
  for (var i = 1; i <= textRecords && i < count; i++) {
    var data = record(i);
    final trail = _trailingSize(data, extraFlags);
    if (trail > 0 && trail < data.length) {
      data = Uint8List.sublistView(data, 0, data.length - trail);
    }
    html.add(compression == 2 ? palmDocDecompress(data) : data);
  }
  final text = _str(html.takeBytes(), utf);

  // Kindle marks chapter breaks with <mbp:pagebreak/>.
  final chunks = text
      .split(RegExp(r'<mbp:pagebreak[^>]*>', caseSensitive: false))
      .where((c) => c.trim().isNotEmpty)
      .toList();
  final sections = <DraftSection>[];
  for (final chunk in chunks) {
    final blocks = blocksFromHtml(_cleanKindleHtml(chunk), language: language);
    if (blocks.isEmpty) continue;
    sections.add((title: null, blocks: blocks));
  }

  return assembleBook(
    id: id,
    metadata: BookMetadata(
      title: (fullName ?? '').trim().isNotEmpty
          ? fullName!.trim()
          : (titleFromFilename(filename) ?? 'Untitled'),
      authors: author == null ? const [] : [author.trim()],
      language: language,
    ),
    sections: sections,
    source: SourceKind.mobi,
    filename: filename,
  );
}

String _cleanKindleHtml(String s) => s
    .replaceAll(RegExp(r'</?mbp:[^>]*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<(img|a)\b[^>]*/?>', caseSensitive: false), '')
    .replaceAll(RegExp(r'</a>', caseSensitive: false), '');

String _str(List<int> b, bool utf) =>
    utf ? utf8.decode(b, allowMalformed: true) : decodeCp1252(b);

/// PalmDOC LZ77 as documented by MobileRead.
Uint8List palmDocDecompress(Uint8List data) {
  final out = BytesBuilder(copy: false);
  final buf = <int>[];
  var i = 0;
  while (i < data.length) {
    final c = data[i++];
    if (c >= 1 && c <= 8) {
      for (var k = 0; k < c && i < data.length; k++) {
        buf.add(data[i++]);
      }
    } else if (c < 0x80) {
      buf.add(c);
    } else if (c >= 0xC0) {
      buf
        ..add(0x20)
        ..add(c ^ 0x80);
    } else {
      if (i >= data.length) break;
      final pair = (c << 8) | data[i++];
      final dist = (pair >> 3) & 0x7FF;
      final len = (pair & 7) + 3;
      if (dist == 0 || dist > buf.length) continue;
      final from = buf.length - dist;
      for (var k = 0; k < len; k++) {
        buf.add(buf[from + k]);
      }
    }
  }
  out.add(buf);
  return out.takeBytes();
}

/// Bytes of trailing entries (TBS indexing, multibyte overlap) at the end of
/// a text record, per the extra-data flags in the MOBI header.
int _trailingSize(Uint8List data, int flags) {
  int entry(int size) {
    var bitpos = 0, result = 0;
    if (size <= 0) return 0;
    while (true) {
      final v = data[size - 1];
      result |= (v & 0x7F) << bitpos;
      bitpos += 7;
      size -= 1;
      if ((v & 0x80) != 0 || bitpos >= 28 || size == 0) return result;
    }
  }

  var num = 0;
  var test = flags >> 1;
  while (test != 0) {
    if (test & 1 != 0) num += entry(data.length - num);
    test >>= 1;
  }
  if (flags & 1 != 0 && data.length - num - 1 >= 0) {
    num += (data[data.length - num - 1] & 0x3) + 1;
  }
  return num;
}
