import 'dart:convert';
import 'dart:typed_data';

/// A minimal KF8 (AZW3) book, laid out as calibre and kindlegen write one
/// (the MobileRead wiki's MOBI and KF8 pages; calibre's mobi reader and
/// writer8). The text records hold the HTML flow and then a CSS flow; the
/// FDST record says where each flow ends; the SKEL and FRAG indexes say how
/// each HTML part is rebuilt from its skeleton and fragments; the NCX index
/// names the chapters.
///
/// [parts] are the book's HTML files, each the fragments that go into its
/// body. [toc] names chapters by the fragment they start in. With [joint],
/// the KF8 book follows a MOBI 6 copy of [mobi6Html], as kindlegen's .mobi
/// files do, and EXTH 121 points at it. With [brokenSkeletons] the SKEL
/// index field points at a record that is no index.
Uint8List kf8Book({
  required List<List<String>> parts,
  List<({String title, int fragment})> toc = const [],
  String title = 'A Tale of the Coast',
  String css = 'p { margin: 0 } h1 { font-size: 2em } .note { color: red }',
  bool joint = false,
  bool brokenSkeletons = false,
  String mobi6Html = '<html><body><p>The old copy.</p></body></html>',
}) {
  final flow = BytesBuilder();
  final skeletons = <({int start, int length, int fragments})>[];
  final fragments = <({int insert, int file, int length, int inFile})>[];
  for (var f = 0; f < parts.length; f++) {
    final skeleton = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Part $f</title>'
      '<link href="kindle:flow:0001?mime=text/css" rel="stylesheet" type="text/css"/>'
      '</head><body aid="${f * 10}"></body></html>',
    );
    final bodyOpen = '<body aid="${f * 10}">';
    var insert = utf8.encode(utf8.decode(skeleton).split(bodyOpen).first + bodyOpen).length;
    final start = flow.length;
    flow.add(skeleton);
    var inFile = 0;
    for (final fragment in parts[f]) {
      final bytes = utf8.encode(fragment);
      fragments.add((insert: start + insert, file: f, length: bytes.length, inFile: inFile));
      flow.add(bytes);
      insert += bytes.length;
      inFile += bytes.length;
    }
    skeletons.add((start: start, length: skeleton.length, fragments: parts[f].length));
  }
  final html = flow.takeBytes();
  final style = utf8.encode(css);
  final text = Uint8List.fromList([...html, ...style]);

  // Text records of 4096 bytes, stored uncompressed.
  final textRecords = <Uint8List>[
    for (var i = 0; i < text.length; i += 4096)
      Uint8List.sublistView(text, i, i + 4096 < text.length ? i + 4096 : text.length),
  ];

  final fdst = BytesBuilder()
    ..add(ascii.encode('FDST'))
    ..add(_u32(12))
    ..add(_u32(2))
    ..add(_u32(0))
    ..add(_u32(html.length))
    ..add(_u32(html.length))
    ..add(_u32(text.length));

  final skelIndex = _index(
    tags: const [(1, 1, 3), (6, 2, 12)],
    entries: [
      // calibre writes each value twice ("Dont ask me why").
      for (var i = 0; i < skeletons.length; i++)
        (
          key: 'SKEL${i.toString().padLeft(10, '0')}',
          control: 0x0A,
          values: [
            skeletons[i].fragments,
            skeletons[i].fragments,
            skeletons[i].start,
            skeletons[i].length,
            skeletons[i].start,
            skeletons[i].length,
          ],
        ),
    ],
  );

  final fragNames = _Cncx();
  final fragIndex = _index(
    tags: const [(2, 1, 1), (3, 1, 2), (4, 1, 4), (6, 2, 8)],
    entries: [
      for (var i = 0; i < fragments.length; i++)
        (
          key: fragments[i].insert.toString().padLeft(10, '0'),
          control: 0x0F,
          values: [
            fragNames.add("P-//*[@aid='${fragments[i].file * 10}']"),
            fragments[i].file,
            i,
            fragments[i].inFile,
            fragments[i].length,
          ],
        ),
    ],
    cncx: fragNames,
  );

  final labels = _Cncx();
  final ncxIndex = _index(
    tags: const [(1, 1, 1), (2, 1, 2), (3, 1, 4), (4, 1, 8), (21, 1, 16), (22, 1, 32), (23, 1, 64), (6, 2, 128)],
    entries: [
      for (var i = 0; i < toc.length; i++)
        (
          key: i.toRadixString(16).toUpperCase().padLeft(2, '0'),
          control: 0x8F,
          values: [
            fragments[toc[i].fragment].insert,
            fragments[toc[i].fragment].length,
            labels.add(toc[i].title),
            0,
            toc[i].fragment,
            0,
          ],
        ),
    ],
    cncx: labels,
  );

  // Record numbers, counted from the KF8 header record.
  final fdstAt = 1 + textRecords.length;
  final skelAt = fdstAt + 1;
  final fragAt = skelAt + skelIndex.length;
  final ncxAt = fragAt + fragIndex.length;
  final kf8 = <Uint8List>[
    _header(
      version: 8,
      textLength: text.length,
      textRecords: textRecords.length,
      title: title,
      kf8: (fdst: fdstAt, skel: brokenSkeletons ? fdstAt : skelAt, frag: fragAt, ncx: toc.isEmpty ? null : ncxAt),
    ),
    ...textRecords,
    fdst.takeBytes(),
    ...skelIndex,
    ...fragIndex,
    if (toc.isNotEmpty) ...ncxIndex,
  ];
  if (!joint) return _palmDb(title, kf8);

  final old = utf8.encode(mobi6Html);
  const oldRecords = 1;
  final boundary = 1 + oldRecords;
  return _palmDb(title, [
    _header(version: 6, textLength: old.length, textRecords: oldRecords, title: title, kf8At: boundary + 1),
    Uint8List.fromList(old),
    Uint8List.fromList(ascii.encode('BOUNDARY')),
    ...kf8,
  ]);
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// A forward variable-width integer: seven bits a byte, high bit on the last.
List<int> _encint(int v) {
  final out = <int>[v & 0x7F];
  for (v >>= 7; v > 0; v >>= 7) {
    out.insert(0, v & 0x7F);
  }
  out[out.length - 1] |= 0x80;
  return out;
}

/// Strings for an index's CNCX record: each its length, then its bytes.
class _Cncx {
  final bytes = BytesBuilder();

  /// Adds [s] and returns its offset.
  int add(String s) {
    final at = bytes.length;
    final raw = utf8.encode(s);
    bytes
      ..add(_encint(raw.length))
      ..add(raw);
    return at;
  }
}

/// An index as its records: the INDX header with the TAGX table, one record
/// of entries ending in its IDXT, then the CNCX record when there is one.
/// [tags] are (tag, values per entry, bit mask).
List<Uint8List> _index({
  required List<(int, int, int)> tags,
  required List<({String key, int control, List<int> values})> entries,
  _Cncx? cncx,
}) {
  ByteData indx({required int idxt, required int count, required int total, required int cncxCount}) {
    final h = ByteData(0xC0);
    for (var i = 0; i < 4; i++) {
      h.setUint8(i, 'INDX'.codeUnitAt(i));
    }
    h
      ..setUint32(4, 0xC0)
      ..setUint32(12, 1)
      ..setUint32(20, idxt)
      ..setUint32(24, count)
      ..setUint32(28, 65001)
      ..setUint32(32, 0xFFFFFFFF)
      ..setUint32(36, total)
      ..setUint32(52, cncxCount)
      ..setUint32(180, 0xC0);
    return h;
  }

  final tagx = BytesBuilder()
    ..add(ascii.encode('TAGX'))
    ..add(_u32(12 + 4 * (tags.length + 1)))
    ..add(_u32(1));
  for (final (tag, values, mask) in tags) {
    tagx.add([tag, values, mask, 0]);
  }
  tagx.add([0, 0, 0, 1]);
  final cncxBytes = cncx?.bytes.takeBytes();
  final primary = BytesBuilder()
    ..add(indx(idxt: 0, count: 1, total: entries.length, cncxCount: cncxBytes == null ? 0 : 1).buffer.asUint8List())
    ..add(tagx.takeBytes());

  final body = BytesBuilder();
  final starts = <int>[];
  for (final e in entries) {
    starts.add(0xC0 + body.length);
    final key = ascii.encode(e.key);
    body
      ..add([key.length, ...key, e.control])
      ..add([for (final v in e.values) ..._encint(v)]);
  }
  final idxt = 0xC0 + body.length;
  final data = BytesBuilder()
    ..add(indx(idxt: idxt, count: entries.length, total: entries.length, cncxCount: 0).buffer.asUint8List())
    ..add(body.takeBytes())
    ..add(ascii.encode('IDXT'));
  for (final s in starts) {
    data.add([s >> 8, s & 0xFF]);
  }
  return [
    primary.takeBytes(),
    data.takeBytes(),
    if (cncxBytes != null) cncxBytes,
  ];
}

/// Record 0: the PalmDOC header, the MOBI header (264 bytes, as kindlegen
/// 2.9 writes it), EXTH when [kf8At] names the KF8 half, and the full name.
Uint8List _header({
  required int version,
  required int textLength,
  required int textRecords,
  required String title,
  ({int fdst, int skel, int frag, int? ncx})? kf8,
  int? kf8At,
}) {
  const none = 0xFFFFFFFF;
  const mobiLength = 264;
  final exth = BytesBuilder();
  if (kf8At != null) {
    exth
      ..add(ascii.encode('EXTH'))
      ..add(_u32(12 + 12))
      ..add(_u32(1))
      ..add(_u32(121))
      ..add(_u32(12))
      ..add(_u32(kf8At));
  }
  final exthBytes = exth.takeBytes();
  final name = utf8.encode(title);
  final h = ByteData(16 + mobiLength + exthBytes.length + name.length + 2);
  h
    ..setUint16(0, 1) // no compression
    ..setUint32(4, textLength)
    ..setUint16(8, textRecords)
    ..setUint16(10, 4096);
  for (var i = 0; i < 4; i++) {
    h.setUint8(16 + i, 'MOBI'.codeUnitAt(i));
  }
  h
    ..setUint32(20, mobiLength)
    ..setUint32(24, 2)
    ..setUint32(28, 65001)
    ..setUint32(36, version);
  for (var o = 40; o < 80; o += 4) {
    h.setUint32(o, none);
  }
  h
    ..setUint32(80, 1 + textRecords)
    ..setUint32(84, 16 + mobiLength + exthBytes.length)
    ..setUint32(88, name.length)
    ..setUint32(0x68, version)
    ..setUint32(0x6C, none)
    ..setUint32(0x80, kf8At != null ? 0x50 : 0)
    ..setUint32(164, none)
    ..setUint32(168, none)
    ..setUint32(0xC0, kf8?.fdst ?? none)
    ..setUint32(0xC4, kf8 == null ? 0 : 2)
    ..setUint32(0xE0, none)
    ..setUint32(0xE8, none)
    ..setUint32(0xEC, none)
    ..setUint32(0xF4, kf8?.ncx ?? none)
    ..setUint32(0xF8, kf8?.frag ?? none)
    ..setUint32(0xFC, kf8?.skel ?? none)
    ..setUint32(0x100, none)
    ..setUint32(0x104, none);
  final out = h.buffer.asUint8List();
  out.setRange(16 + mobiLength, 16 + mobiLength + exthBytes.length, exthBytes);
  out.setRange(16 + mobiLength + exthBytes.length, 16 + mobiLength + exthBytes.length + name.length, name);
  return out;
}

/// The PalmDB container: a 78-byte header, the record list, two bytes of
/// padding, then the records.
Uint8List _palmDb(String title, List<Uint8List> records) {
  final head = ByteData(78 + records.length * 8 + 2);
  final name = ascii.encode(title.length > 31 ? title.substring(0, 31) : title);
  for (var i = 0; i < name.length; i++) {
    head.setUint8(i, name[i]);
  }
  for (var i = 0; i < 8; i++) {
    head.setUint8(60 + i, 'BOOKMOBI'.codeUnitAt(i));
  }
  head.setUint16(76, records.length);
  var at = head.lengthInBytes;
  for (var i = 0; i < records.length; i++) {
    head
      ..setUint32(78 + i * 8, at)
      ..setUint32(78 + i * 8 + 4, i * 2);
    at += records[i].length;
  }
  return Uint8List.fromList([
    ...head.buffer.asUint8List(),
    for (final r in records) ...r,
  ]);
}
