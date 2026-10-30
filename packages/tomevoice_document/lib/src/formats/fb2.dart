import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../model.dart';
import '../segment.dart';

/// FictionBook 2 (.fb2, .fb2.zip).
///
/// Plain XML, but frequently declared as windows-1251, which `dart:convert`
/// has no codec for, so that one is decoded here.
Book parseFb2(Uint8List bytes, {required String id, String? filename}) {
  if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    final inner = archive.files
        .where((f) => f.isFile && f.name.toLowerCase().endsWith('.fb2'))
        .firstOrNull;
    final data = inner?.readBytes();
    if (data == null) throw const ParseException('No .fb2 inside this zip.');
    bytes = Uint8List.fromList(data);
  }

  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(_decodeXml(bytes));
  } on XmlException catch (e) {
    throw ParseException('Broken FB2: ${e.message}');
  }

  XmlElement? find(XmlNode root, String local) {
    for (final e in root.descendants.whereType<XmlElement>()) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  final info = find(doc, 'title-info');
  final title = info == null ? null : find(info, 'book-title')?.innerText;
  final authors = <String>[
    if (info != null)
      for (final a in info.children.whereType<XmlElement>())
        if (a.name.local == 'author')
          collapseWhitespace([
            for (final part in ['first-name', 'middle-name', 'last-name'])
              find(a, part)?.innerText ?? '',
          ].join(' ')),
  ]..removeWhere((a) => a.isEmpty);
  final lang = info == null ? null : find(info, 'lang')?.innerText.trim();

  resetBlockIds();
  final sections = <DraftSection>[];
  final bodies = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'body')
      .where((e) => e.getAttribute('name') != 'notes')
      .toList();

  void addSection(XmlElement section) {
    final hasChildSections = section.children
        .whereType<XmlElement>()
        .any((c) => c.name.local == 'section');
    final blocks = <Block>[];
    String? heading;
    for (final c in section.children.whereType<XmlElement>()) {
      switch (c.name.local) {
        case 'title':
          // "Chapter 1" and "The Arrival" are two lines of one title: two
          // headings on the page, "Chapter 1: The Arrival" in the contents.
          final lines = [
            for (final p in c.childElements)
              if (collapseWhitespace(_text(p)).isNotEmpty) collapseWhitespace(_text(p)),
          ];
          if (lines.isEmpty && collapseWhitespace(_text(c)).isNotEmpty) {
            lines.add(collapseWhitespace(_text(c)));
          }
          if (lines.isNotEmpty) heading ??= _joinTitle(lines);
          for (final t in lines) {
            blocks.add(makeBlock(role: BlockRole.heading, text: t));
          }
        case 'section':
          break;
        case 'subtitle':
          _add(blocks, c, BlockRole.heading);
        case 'image':
          break;
        case 'epigraph':
        case 'cite':
        case 'poem':
          for (final p in c.descendants.whereType<XmlElement>()) {
            if (p.name.local == 'p' || p.name.local == 'v' || p.name.local == 'text-author') {
              _add(blocks, p, BlockRole.quote);
            }
          }
        default:
          _add(blocks, c, BlockRole.paragraph);
      }
    }
    if (blocks.isNotEmpty) sections.add((title: heading, blocks: blocks));
    if (hasChildSections) {
      for (final c in section.children.whereType<XmlElement>()) {
        if (c.name.local == 'section') addSection(c);
      }
    }
  }

  for (final body in bodies) {
    final direct = body.children
        .whereType<XmlElement>()
        .where((c) => c.name.local == 'section')
        .toList();
    if (direct.isEmpty) {
      addSection(body);
    } else {
      for (final s in direct) {
        addSection(s);
      }
    }
  }

  return assembleBook(
    id: id,
    metadata: BookMetadata(
      title: collapseWhitespace(title ?? '').isNotEmpty
          ? collapseWhitespace(title!)
          : (titleFromFilename(filename) ?? 'Untitled'),
      authors: authors,
      language: lang,
    ),
    sections: sections,
    source: SourceKind.fb2,
    filename: filename,
  );
}

void _add(List<Block> blocks, XmlElement e, BlockRole role) {
  final t = collapseWhitespace(_text(e));
  if (t.isNotEmpty) blocks.add(makeBlock(role: role, text: t));
}

/// Lines of one title as a single name: "Chapter 1: The Arrival", or
/// "Chapter 2. The Return" when the first line has its own stop.
String _joinTitle(List<String> lines) {
  final out = StringBuffer(lines.first);
  for (final l in lines.skip(1)) {
    final prev = out.toString();
    out.write(RegExp(r'[.:;!?\-–—]$').hasMatch(prev) ? ' ' : ': ');
    out.write(l);
  }
  return out.toString();
}

/// Elements whose edges are word breaks: paragraphs, verse lines, cells.
const _breaking = {'p', 'v', 'subtitle', 'text-author', 'td', 'th', 'tr', 'empty-line', 'stanza'};

/// The text of [e] with a space wherever one paragraph, line or cell ends
/// and the next begins (`innerText` glued "Chapter 1" to "The Arrival").
String _text(XmlElement e) {
  final buf = StringBuffer();
  void walk(XmlNode n) {
    for (final c in n.children) {
      if (c is XmlText || c is XmlCDATA) {
        buf.write(c.value);
      } else if (c is XmlElement) {
        if (c.name.local == 'image') continue;
        final edge = _breaking.contains(c.name.local);
        if (edge) buf.write(' ');
        walk(c);
        if (edge) buf.write(' ');
      }
    }
  }

  walk(e);
  return buf.toString();
}

String _decodeXml(Uint8List bytes) {
  final end = bytes.length < 200 ? bytes.length : 200;
  final head = String.fromCharCodes(bytes.sublist(0, end)).toLowerCase();
  final enc = RegExp(r'''encoding\s*=\s*["']([\w-]+)["']''')
      .firstMatch(head)
      ?.group(1);
  if (enc == 'windows-1251' || enc == 'cp1251') return decodeCp1251(bytes);
  if (enc == 'iso-8859-1' || enc == 'latin1') return latin1.decode(bytes);
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

/// Windows-1251 (Cyrillic).
String decodeCp1251(List<int> bytes) {
  const high = [
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
  ];
  return String.fromCharCodes([
    for (final b in bytes)
      if (b < 0x80)
        b
      else if (b < 0xC0)
        high[b - 0x80]
      else
        0x0410 + (b - 0xC0),
  ]);
}
