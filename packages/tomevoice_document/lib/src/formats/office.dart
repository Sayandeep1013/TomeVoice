import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../model.dart';
import '../segment.dart';

/// Word (.docx). Paragraphs from `word/document.xml`; Heading 1 / Title
/// paragraphs start a new chapter when there are at least two of them.
Book parseDocx(Uint8List bytes, {required String id, String? filename}) {
  final archive = _unzip(bytes, 'Word document');
  final body = _xml(archive, 'word/document.xml');
  if (body == null) {
    throw const ParseException('This .docx has no word/document.xml.');
  }
  final styles = _docxStyleNames(_xml(archive, 'word/styles.xml'));
  final meta = _coreMetadata(_xml(archive, 'docProps/core.xml'), filename);

  resetBlockIds();
  final paras = <({String text, int level, bool list})>[];
  for (final p in body.descendants.whereType<XmlElement>()) {
    if (p.name.local != 'p') continue;
    // Paragraphs nested in a text box inside another paragraph are visited
    // on their own; only take the outermost text runs of this one.
    final text = collapseWhitespace(_docxText(p));
    if (text.isEmpty) continue;
    final ppr = _child(p, 'pPr');
    final styleId = _attr(_child(ppr, 'pStyle'), 'val') ?? '';
    final styleName = (styles[styleId] ?? styleId).toLowerCase();
    final outline = int.tryParse(_attr(_child(ppr, 'outlineLvl'), 'val') ?? '');
    var level = 0;
    final h = RegExp(r'heading\s*(\d)').firstMatch(styleName);
    if (styleName == 'title') {
      level = 1;
    } else if (h != null) {
      level = int.parse(h.group(1)!);
    } else if (outline != null && outline < 6) {
      level = outline + 1;
    }
    paras.add((text: text, level: level, list: _child(ppr, 'numPr') != null));
  }

  return assembleBook(
    id: id,
    metadata: meta,
    sections: _sectionsByHeading(
      [for (final p in paras) (text: p.text, level: p.level, list: p.list)],
      meta.title,
    ),
    source: SourceKind.docx,
    filename: filename,
  );
}

String _docxText(XmlElement p) {
  final buf = StringBuffer();
  void walk(XmlElement e) {
    for (final c in e.children.whereType<XmlElement>()) {
      switch (c.name.local) {
        case 't':
          buf.write(c.innerText);
        case 'tab':
        case 'br':
        case 'cr':
          buf.write(' ');
        case 'noBreakHyphen':
          buf.write('-');
        case 'delText':
        case 'instrText':
        case 'pPr':
        case 'rPr':
        case 'footnoteReference':
        case 'endnoteReference':
          break;
        case 'p':
          // A nested paragraph (text box) is its own block.
          break;
        default:
          walk(c);
      }
    }
  }

  walk(p);
  return buf.toString();
}

Map<String, String> _docxStyleNames(XmlDocument? styles) {
  if (styles == null) return const {};
  final out = <String, String>{};
  for (final s in styles.descendants.whereType<XmlElement>()) {
    if (s.name.local != 'style') continue;
    final id = _attr(s, 'styleId');
    final name = _attr(_child(s, 'name'), 'val');
    if (id != null && name != null) out[id] = name;
  }
  return out;
}

/// OpenDocument text (.odt) from LibreOffice and Google Docs exports.
Book parseOdt(Uint8List bytes, {required String id, String? filename}) {
  final archive = _unzip(bytes, 'OpenDocument file');
  final content = _xml(archive, 'content.xml');
  if (content == null) {
    throw const ParseException('This .odt has no content.xml.');
  }
  final meta = _coreMetadata(_xml(archive, 'meta.xml'), filename);

  resetBlockIds();
  final paras = <({String text, int level, bool list})>[];
  void visit(XmlElement e, {bool inList = false}) {
    for (final c in e.children.whereType<XmlElement>()) {
      switch (c.name.local) {
        case 'h':
          final text = collapseWhitespace(_odtText(c));
          if (text.isNotEmpty) {
            final level =
                int.tryParse(_attr(c, 'outline-level') ?? '') ?? 1;
            paras.add((text: text, level: level, list: false));
          }
        case 'p':
          final text = collapseWhitespace(_odtText(c));
          if (text.isNotEmpty) {
            paras.add((text: text, level: 0, list: inList));
          }
        case 'list':
        case 'list-item':
          visit(c, inList: true);
        case 'annotation':
        case 'tracked-changes':
        case 'sequence-decls':
          break;
        default:
          visit(c, inList: inList);
      }
    }
  }

  final body = content.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'text')
      .firstOrNull;
  if (body != null) visit(body);

  return assembleBook(
    id: id,
    metadata: meta,
    sections: _sectionsByHeading(paras, meta.title),
    source: SourceKind.odt,
    filename: filename,
  );
}

String _odtText(XmlElement e) {
  final buf = StringBuffer();
  void walk(XmlNode n) {
    for (final c in n.children) {
      if (c is XmlText) {
        buf.write(c.value);
      } else if (c is XmlElement) {
        switch (c.name.local) {
          case 's':
            buf.write(' ' * (int.tryParse(_attr(c, 'c') ?? '') ?? 1));
          case 'tab':
          case 'line-break':
            buf.write(' ');
          case 'annotation':
          case 'note':
            break;
          default:
            walk(c);
        }
      }
    }
  }

  walk(e);
  return buf.toString();
}

/// Chapters start at the shallowest heading level that occurs at least twice.
List<DraftSection> _sectionsByHeading(
  List<({String text, int level, bool list})> paras,
  String fallbackTitle,
) {
  final counts = <int, int>{};
  for (final p in paras) {
    if (p.level > 0) counts[p.level] = (counts[p.level] ?? 0) + 1;
  }
  int? splitLevel;
  for (final l in counts.keys.toList()..sort()) {
    if (counts[l]! >= 2) {
      splitLevel = l;
      break;
    }
  }

  final sections = <DraftSection>[];
  String? title = fallbackTitle;
  var blocks = <Block>[];
  for (final p in paras) {
    if (splitLevel != null && p.level > 0 && p.level <= splitLevel) {
      if (blocks.isNotEmpty) sections.add((title: title, blocks: blocks));
      blocks = [];
      title = p.text;
    }
    blocks.add(makeBlock(
      role: p.level > 0
          ? BlockRole.heading
          : (p.list ? BlockRole.listItem : BlockRole.paragraph),
      text: p.text,
    ));
  }
  if (blocks.isNotEmpty) sections.add((title: title, blocks: blocks));
  return sections;
}

/// Dublin Core title / creator / language, shared by DOCX core.xml and ODT
/// meta.xml.
BookMetadata _coreMetadata(XmlDocument? doc, String? filename) {
  String? first(String local) {
    if (doc == null) return null;
    for (final e in doc.descendants.whereType<XmlElement>()) {
      if (e.name.local == local) {
        final t = collapseWhitespace(e.innerText);
        if (t.isNotEmpty) return t;
      }
    }
    return null;
  }

  final creator = first('creator') ?? first('initial-creator');
  return BookMetadata(
    title: first('title') ?? titleFromFilename(filename) ?? 'Untitled',
    authors: creator == null ? const [] : [creator],
    language: first('language'),
  );
}

Archive _unzip(Uint8List bytes, String what) {
  try {
    return ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (e) {
    throw ParseException('Not a readable $what (zip failed).');
  }
}

XmlDocument? _xml(Archive archive, String path) {
  final f = archive.findFile(path);
  if (f == null) return null;
  final data = f.readBytes();
  if (data == null || data.isEmpty) return null;
  try {
    return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
  } on XmlException {
    return null;
  }
}

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.children.whereType<XmlElement>()) {
    if (c.name.local == local) return c;
  }
  return null;
}

String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/// Names in a zip, without decompressing anything.
Set<String> zipEntryNames(Uint8List bytes) {
  try {
    final a = ZipDecoder().decodeBytes(bytes, verify: false);
    return {for (final f in a.files) f.name.replaceAll(r'\', '/')};
  } catch (_) {
    return const {};
  }
}

/// The stored `mimetype` entry of an OpenDocument / EPUB container.
String? zipMimetype(Uint8List bytes) {
  try {
    final a = ZipDecoder().decodeBytes(bytes, verify: false);
    final f = a.findFile('mimetype');
    final data = f?.readBytes();
    if (data == null) return null;
    return utf8.decode(data, allowMalformed: true).trim();
  } catch (_) {
    return null;
  }
}
