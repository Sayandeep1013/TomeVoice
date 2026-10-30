import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../build.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';
import 'text.dart';

/// Kindle MOBI / AZW / AZW3 / PRC without DRM.
///
/// A PalmDB container whose text records are PalmDOC-compressed HTML. Only
/// PalmDOC (and uncompressed) text is supported; HUFF/CDIC books and anything
/// encrypted get a clear message instead of garbage. A KF8 book (AZW3, or the
/// KF8 half of a joint .mobi) is rebuilt into its HTML parts and chapters.
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
  var version = 0;
  int? kf8Header;
  String? fullName;
  String? author;
  String? language;
  if (type == 'BOOKMOBI' && r0.length >= 24 && String.fromCharCodes(r0.sublist(16, 20)) == 'MOBI') {
    final headerLen = h.getUint32(20);
    utf = h.getUint32(28) == 65001;
    if (headerLen >= 0xE4 && r0.length >= 16 + 0xE4) {
      extraFlags = h.getUint16(0xF2);
    }
    if (r0.length >= 0x6C) version = h.getUint32(0x68);
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
        // The record that holds the KF8 header, in a joint MOBI 6 + KF8 file.
        if (t == 121 && len >= 12) kf8Header = h.getUint32(p + 8);
        p += len;
      }
    }
  }

  Book book(List<DraftSection> sections) => assembleBook(
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

  // KF8 (AZW3) keeps its chapters in index tables, not in page breaks, and
  // its stylesheets after the text. A standalone book says version 8 in its
  // own header; a joint file names its KF8 header record in EXTH 121, after
  // a BOUNDARY record, and its MOBI 6 copy is only the fallback.
  final kf8 = version == 8 && r0.length >= 0x108
      ? 0
      : kf8Header != null &&
              kf8Header > 0 &&
              kf8Header < count &&
              String.fromCharCodes(record(kf8Header - 1)) == 'BOUNDARY'
          ? kf8Header
          : null;
  if (kf8 != null) {
    final sections = _kf8Sections(record, count, kf8, language);
    if (sections != null && sections.isNotEmpty) return book(sections);
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
  return book(_pageBreakSections(_str(html.takeBytes(), utf), language));
}

/// A MOBI 6 book's chapters: Kindle marks chapter breaks with
/// <mbp:pagebreak/>.
List<DraftSection> _pageBreakSections(String text, String? language) {
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
  return sections;
}

/// "No such record" in a KF8 header's index fields.
const _none = 0xFFFFFFFF;

/// A KF8 index or table that does not read; the book is then read from its
/// text as stored.
class _Broken implements Exception {
  const _Broken();
}

/// A KF8 book's chapters, from the header at record [base] (0, or the KF8
/// half of a joint file); null when it cannot be read as KF8 at all.
///
/// The text records hold flows one after another: the book's HTML, then its
/// stylesheets (FDST says where each ends). The HTML flow stores each part
/// (one file of the original book) as a skeleton, its html, head and empty
/// body, followed by fragments of its body; the SKEL and FRAG indexes say
/// where each fragment goes back. The NCX index names the chapters.
List<DraftSection>? _kf8Sections(
  Uint8List Function(int) record,
  int count,
  int base,
  String? language,
) {
  final header = record(base);
  if (header.length < 0x108) return null;
  final h = ByteData.sublistView(header);
  final compression = h.getUint16(0);
  if ((compression != 1 && compression != 2) || h.getUint16(12) != 0) return null;
  final utf = h.getUint32(28) == 65001;
  final extraFlags = h.getUint32(20) >= 0xE4 ? h.getUint16(0xF2) : 0;

  final text = BytesBuilder(copy: false);
  for (var i = base + 1; i <= base + h.getUint16(8) && i < count; i++) {
    var data = record(i);
    final trail = _trailingSize(data, extraFlags);
    if (trail > 0 && trail < data.length) {
      data = Uint8List.sublistView(data, 0, data.length - trail);
    }
    text.add(compression == 2 ? palmDocDecompress(data) : data);
  }
  var flow = text.takeBytes();
  final fdst = h.getUint32(0xC0);
  if (fdst != _none && h.getUint32(0xC4) > 1 && base + fdst < count) {
    flow = _htmlFlow(flow, record(base + fdst));
  }

  var fragments = const <_Entry>[];
  List<_Part> parts;
  try {
    final skel = h.getUint32(0xFC), frag = h.getUint32(0xF8);
    if (skel == _none || frag == _none) throw const _Broken();
    fragments = _index(record, count, base + frag, utf).entries;
    parts = _parts(flow, _index(record, count, base + skel, utf).entries, fragments, utf);
  } on _Broken {
    // The HTML as stored, read like a MOBI 6 book's. An ancient PRC file
    // can claim version 8 too (calibre warns of it), and this is its text.
    return _pageBreakSections(_str(flow, utf), language);
  } on RangeError {
    // A table that points outside its own record: the same.
    return _pageBreakSections(_str(flow, utf), language);
  }

  var chapters = const <({String title, int part, int depth})>[];
  final ncx = h.getUint32(0xF4);
  if (ncx != _none) {
    try {
      chapters = _chapters(_index(record, count, base + ncx, utf), fragments, parts);
    } on _Broken {
      // Chapters are then named by their headings.
    } on RangeError {
      // The same.
    }
  }

  // The parts' links made links to ids, as in the EPUB the book was made
  // from, so that a note's marker is found pointing at its note: notes are
  // shown and not read, and their marks are not said. Ids in later parts
  // that markers point at are notes (endnotes at the back).
  final html = _linkedParts(parts, fragments, utf);
  final names = {for (var i = 0; i < parts.length; i++) _partName(i)};
  final notes = <String, Set<String>>{};
  for (var i = 0; i < html.length; i++) {
    for (final link in markerLinks(html[i])) {
      final hash = link.indexOf('#');
      final part = link.substring(0, hash);
      final target = int.tryParse(_partNumber.firstMatch(part)?.group(1) ?? '');
      if (target != null && target > i) (notes[part] ??= {}).add(link.substring(hash + 1));
    }
  }

  final sections = <DraftSection>[];
  for (var i = 0; i < parts.length; i++) {
    final blocks = htmlChapter(
      _cleanKindleHtml(html[i], links: true),
      language: language,
      href: _partName(i),
      notes: notes[_partName(i)] ?? const {},
      hasFile: names.contains,
    ).blocks;
    if (blocks.isEmpty) continue;
    final here = [
      for (final c in chapters)
        if (c.part == i) c,
    ];
    if (here.isEmpty) {
      sections.add((title: null, blocks: blocks));
      continue;
    }
    // A part can hold several chapters (a book that was one long file): each
    // later one starts at its heading. Only entries as high in the contents
    // as the part's first count, or deeper ones that are chapters ("Chapter
    // 4"): a story keeps its parts I and II, as an EPUB's file would.
    final top = here.map((c) => c.depth).reduce(math.min);
    final titles = [
      here.first.title,
      for (final c in here.skip(1))
        if (c.depth == top || looksLikeChapterLine(c.title)) c.title,
    ];
    var from = 0;
    var title = titles.first;
    for (final next in titles.skip(1)) {
      final at = blocks.indexWhere((b) => _sameTitle(b.text, next), from + 1);
      if (at < 0) continue;
      sections.add((title: title, blocks: blocks.sublist(from, at)));
      from = at;
      title = next;
    }
    sections.add((title: title, blocks: blocks.sublist(from)));
  }
  return sections;
}

/// The first flow, the book's HTML, per the FDST record.
Uint8List _htmlFlow(Uint8List text, Uint8List fdst) {
  if (fdst.length < 12 || String.fromCharCodes(fdst.sublist(0, 4)) != 'FDST') return text;
  final d = ByteData.sublistView(fdst);
  final table = d.getUint32(4);
  if (d.getUint32(8) < 1 || table + 8 > fdst.length) return text;
  final start = d.getUint32(table);
  final end = d.getUint32(table + 4);
  if (start >= text.length || end <= start) return text;
  return Uint8List.sublistView(text, start, math.min(end, text.length));
}

/// One HTML part of a KF8 book: where it was in the HTML flow, and its HTML
/// as stored (links count places in it by the byte).
typedef _Part = ({int start, int end, Uint8List bytes});

/// One entry of a KF8 index: its key, and its tags' values.
typedef _Entry = ({String key, Map<int, List<int>> tags});

/// The parts rebuilt as calibre's reader does: each skeleton with its
/// fragments put back in order, each at its insert position (counted in the
/// skeleton as it grows, from where the skeleton starts in the flow).
List<_Part> _parts(Uint8List flow, List<_Entry> skeletons, List<_Entry> fragments, bool utf) {
  final out = <_Part>[];
  var f = 0;
  for (final s in skeletons) {
    final n = s.tags[1]?.first ?? 0;
    final place = s.tags[6] ?? const <int>[];
    if (place.length < 2) throw const _Broken();
    final start = place[0], length = place[1];
    if (start + length > flow.length) throw const _Broken();
    final html = <int>[...Uint8List.sublistView(flow, start, start + length)];
    var next = start + length;
    for (var i = 0; i < n; i++, f++) {
      if (f >= fragments.length) throw const _Broken();
      final insert = (int.tryParse(fragments[f].key) ?? -1) - start;
      final size = fragments[f].tags[6] ?? const <int>[];
      if (size.length < 2 || insert < 0 || insert > html.length || next + size[1] > flow.length) {
        throw const _Broken();
      }
      html.insertAll(insert, Uint8List.sublistView(flow, next, next + size[1]));
      next += size[1];
    }
    out.add((start: start, end: next, bytes: Uint8List.fromList(html)));
  }
  return out;
}

/// What a KF8 part is called in links between parts.
String _partName(int i) => 'part$i.html';

final _partNumber = RegExp(r'^part(\d+)\.html$');

/// A KF8 link: a place in the HTML flow as a fragment and an offset into it,
/// both in base 32 ("kindle:pos:fid:0008:off:00000001TE").
final _kindlePos = RegExp(r'kindle:pos:fid:([0-9A-Va-v]{4}):off:([0-9A-Va-v]{10})');

/// The parts' HTML, each kindle:pos link made a link to the id of the
/// element that starts at its place ("part1.html#id_1"), as calibre's reader
/// makes them. An element there with no id of its own (only Amazon's aid)
/// is given one. A link to anywhere else is left as it is.
List<String> _linkedParts(List<_Part> parts, List<_Entry> fragments, bool utf) {
  // Each part a character a byte, for finding places in it by the byte.
  final bytes = [for (final p in parts) latin1.decode(p.bytes)];
  final targets = <String, String>{};
  final given = <int, Map<int, String>>{};
  for (final html in bytes) {
    for (final m in _kindlePos.allMatches(html)) {
      final link = m.group(0)!;
      if (targets.containsKey(link)) continue;
      final fid = int.parse(m.group(1)!, radix: 32);
      final insert = fid < fragments.length ? int.tryParse(fragments[fid].key) : null;
      if (insert == null) continue;
      final place = insert + int.parse(m.group(2)!, radix: 32);
      final part = parts.indexWhere((p) => place >= p.start && place < p.end);
      if (part < 0) continue;
      final at = place - parts[part].start;
      final tag = _startTagAt(bytes[part], at);
      if (tag == null) continue;
      final id = _idOf(tag, utf) ?? (given[part] ??= {}).putIfAbsent(at, () => 'kf8-$place');
      targets[link] = '${_partName(part)}#$id';
    }
  }
  return [
    for (var i = 0; i < parts.length; i++)
      _str(_withIds(parts[i].bytes, bytes[i], given[i] ?? const {}), utf)
          .replaceAllMapped(_kindlePos, (m) => targets[m.group(0)!] ?? m.group(0)!),
  ];
}

/// The start tag that begins at [at] in [html] ("<p class=x aid=UGL3>"), or
/// null when none does there.
String? _startTagAt(String html, int at) {
  if (at < 0 || at + 1 >= html.length || html.codeUnitAt(at) != 0x3C) return null;
  final next = html.codeUnitAt(at + 1);
  final letter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A);
  final end = html.indexOf('>', at);
  if (!letter || end < 0 || end - at > 4000) return null;
  return html.substring(at, end + 1);
}

final _idAttr = RegExp(r'''\s(?:id|ID)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _nameAttr = RegExp(r'''^<a\s(?:[^>]*\s)?(?:name|NAME)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

/// The id a start [tag] gives its element (an a's name will do), in the
/// part's own encoding; null for none.
String? _idOf(String tag, bool utf) {
  final m = _idAttr.firstMatch(tag) ?? _nameAttr.firstMatch(tag);
  final value = m == null ? null : m.group(1) ?? m.group(2);
  return value == null || value.trim().isEmpty ? null : _str(value.trim().codeUnits, utf);
}

/// [bytes] (seen a character a byte as [html]) with each start tag at a
/// place in [ids] given that id.
Uint8List _withIds(Uint8List bytes, String html, Map<int, String> ids) {
  if (ids.isEmpty) return bytes;
  final out = BytesBuilder(copy: false);
  var from = 0;
  for (final at in ids.keys.toList()..sort()) {
    // After the tag's name.
    var name = at + 1;
    while (name < html.length && _tagNameChar.hasMatch(html[name])) {
      name++;
    }
    out
      ..add(Uint8List.sublistView(bytes, from, name))
      ..add(ascii.encode(' id="${ids[at]}"'));
    from = name;
  }
  out.add(Uint8List.sublistView(bytes, from));
  return out.takeBytes();
}

final _tagNameChar = RegExp('[A-Za-z0-9:_-]');

/// The NCX's chapters in order: each title, the part it starts in, and its
/// depth in the contents. A chapter's place is a fragment and an offset into
/// it, or (in older books) a place in the HTML flow.
List<({String title, int part, int depth})> _chapters(
  ({List<_Entry> entries, Map<int, String> strings}) ncx,
  List<_Entry> fragments,
  List<_Part> parts,
) {
  final out = <({String title, int part, int depth})>[];
  for (final e in ncx.entries) {
    final title = collapseWhitespace(ncx.strings[e.tags[3]?.first] ?? '');
    if (title.isEmpty) continue;
    int? at;
    final fid = e.tags[6];
    if (fid != null && fid.length >= 2 && fid[0] < fragments.length) {
      final insert = int.tryParse(fragments[fid[0]].key);
      if (insert != null) at = insert + fid[1];
    }
    at ??= e.tags[1]?.first;
    if (at == null) continue;
    final place = at;
    final part = parts.indexWhere((p) => place >= p.start && place < p.end);
    if (part >= 0) out.add((title: title, part: part, depth: e.tags[4]?.first ?? 0));
  }
  return out;
}

/// A KF8 index (SKEL, FRAG, NCX): its INDX record with the TAGX table that
/// says how entries are coded, then the records of entries, then the CNCX
/// records of the strings entries point at (calibre's read_index).
({List<_Entry> entries, Map<int, String> strings}) _index(
  Uint8List Function(int) record,
  int count,
  int at,
  bool utf,
) {
  if (at < 0 || at >= count) throw const _Broken();
  final head = record(at);
  if (head.length < 0xC0 || String.fromCharCodes(head.sublist(0, 4)) != 'INDX') {
    throw const _Broken();
  }
  final h = ByteData.sublistView(head);
  final records = h.getUint32(24);
  final cncx = h.getUint32(52);
  if (at + records + cncx >= count) throw const _Broken();
  bool isTagx(int i) => i + 12 <= head.length && String.fromCharCodes(head.sublist(i, i + 4)) == 'TAGX';
  var tagx = h.getUint32(180);
  if (!isTagx(tagx)) tagx = h.getUint32(4);
  if (!isTagx(tagx)) throw const _Broken();
  final tagxEnd = math.min(head.length, tagx + h.getUint32(tagx + 4));
  final controlBytes = h.getUint32(tagx + 8);
  final tags = [
    for (var i = tagx + 12; i + 4 <= tagxEnd; i += 4)
      (tag: head[i], values: head[i + 1], mask: head[i + 2], end: head[i + 3] == 1),
  ];

  final strings = <int, String>{};
  for (var c = 0; c < cncx; c++) {
    final raw = record(at + records + 1 + c);
    var pos = 0;
    while (pos < raw.length) {
      final length = _forwardInt(raw, pos);
      if (length.size == 0) break;
      if (length.value > 0) {
        final from = pos + length.size;
        strings[c * 0x10000 + pos] = _str(raw.sublist(from, math.min(raw.length, from + length.value)), utf);
      }
      pos += length.size + length.value;
    }
  }

  final entries = <_Entry>[];
  for (var r = 1; r <= records; r++) {
    final data = record(at + r);
    if (data.length < 28 || String.fromCharCodes(data.sublist(0, 4)) != 'INDX') throw const _Broken();
    final d = ByteData.sublistView(data);
    final idxt = d.getUint32(20);
    final n = d.getUint32(24);
    if (idxt + 4 + 2 * n > data.length) throw const _Broken();
    final starts = [
      for (var j = 0; j < n; j++) d.getUint16(idxt + 4 + 2 * j),
      idxt,
    ];
    for (var j = 0; j < n; j++) {
      final from = starts[j], to = starts[j + 1];
      if (from >= to || to > data.length || from + 1 + data[from] > to) throw const _Broken();
      final keyEnd = from + 1 + data[from];
      entries.add((
        key: _str(data.sublist(from + 1, keyEnd), utf),
        tags: _tagValues(data, keyEnd, to, controlBytes, tags),
      ));
    }
  }
  return (entries: entries, strings: strings);
}

/// An index entry's tags and their values, as calibre's get_tag_map reads
/// them: the control bytes say which tags are there and how many values
/// each has, and the values follow as forward variable-width integers.
Map<int, List<int>> _tagValues(
  Uint8List data,
  int at,
  int end,
  int controlBytes,
  List<({int tag, int values, int mask, bool end})> tags,
) {
  var pos = at + controlBytes;
  if (pos > end) throw const _Broken();
  var control = at;
  final present = <({int tag, int? count, int? bytes, int per})>[];
  for (final t in tags) {
    if (t.end) {
      control++;
      continue;
    }
    if (control >= at + controlBytes) break;
    var value = data[control] & t.mask;
    if (value == 0) continue;
    if (value == t.mask && _bits(t.mask) > 1) {
      // A wide mask all set: a count of bytes of values follows.
      final bytes = _forwardInt(data, pos);
      pos += bytes.size;
      present.add((tag: t.tag, count: null, bytes: bytes.value, per: t.values));
    } else {
      var mask = t.mask;
      while (mask & 1 == 0) {
        mask >>= 1;
        value >>= 1;
      }
      present.add((tag: t.tag, count: value, bytes: null, per: t.values));
    }
  }

  final out = <int, List<int>>{};
  for (final p in present) {
    final values = <int>[];
    var used = 0;
    while (p.count != null ? values.length < p.count! * p.per : used < p.bytes!) {
      final v = _forwardInt(data, pos);
      if (v.size == 0 || pos + v.size > end) throw const _Broken();
      pos += v.size;
      used += v.size;
      values.add(v.value);
    }
    out[p.tag] = values;
  }
  return out;
}

int _bits(int mask) {
  var n = 0;
  for (var m = mask; m != 0; m >>= 1) {
    n += m & 1;
  }
  return n;
}

/// A forward variable-width integer: seven bits a byte, the last byte marked
/// by its high bit.
({int value, int size}) _forwardInt(Uint8List b, int at) {
  var value = 0, size = 0;
  while (at + size < b.length && size < 5) {
    final byte = b[at + size++];
    value = (value << 7) | (byte & 0x7F);
    if (byte & 0x80 != 0) break;
  }
  return (value: value, size: size);
}

/// Whether a block is [title] as a heading: the same words, the title with
/// more after it, or the first line of a title set over two.
bool _sameTitle(String text, String title) {
  if (text.length > 100) return false;
  String words(String s) =>
      collapseWhitespace(s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' '));
  final b = words(text), t = words(title);
  if (b.isEmpty || t.isEmpty) return false;
  return b == t || b.startsWith('$t ') || (b.length >= 4 && t.startsWith('$b '));
}

/// Kindle HTML without its own tags and its pictures (not read; the bytes
/// of a picture are not where an EPUB's are). Links go too, unless [links]:
/// a MOBI 6 book's point at file positions (`<a filepos=0001234>`), and are
/// not XML; a KF8 book's are made links to ids first (see [_linkedParts]).
String _cleanKindleHtml(String s, {bool links = false}) {
  final out = s.replaceAll(_kindleTag, '').replaceAll(_picture, '');
  return links ? out : out.replaceAll(_link, '');
}

final _kindleTag = RegExp(r'</?mbp:[^>]*>', caseSensitive: false);
final _picture = RegExp(r'<img\b[^>]*/?>', caseSensitive: false);
final _link = RegExp(r'</?a\b[^>]*>', caseSensitive: false);

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
