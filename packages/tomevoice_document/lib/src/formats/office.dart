import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../encoding.dart';
import '../model.dart';
import '../segment.dart';

/// One paragraph of a word-processor document, before it is a block.
typedef _Para = ({String text, int level, bool list, bool note});

/// Word (.docx). Paragraphs from `word/document.xml`; Heading 1 / Title
/// paragraphs start a new chapter when there are at least two of them.
///
/// Not read: the table of contents Word generates (its field, its content
/// control, its TOC styles, with their page numbers), hidden text, and the
/// copy of a text box Word keeps for older versions. Footnotes come right
/// after the paragraph that points at them and endnotes at the end, as
/// notes (shown, not read in the flow); their marks are shown, not said.
Book parseDocx(Uint8List bytes, {required String id, String? filename}) {
  final archive = _unzip(bytes, 'Word document');
  final body = _xml(archive, 'word/document.xml');
  if (body == null) {
    throw const ParseException('This .docx has no word/document.xml.');
  }
  final styles = _docxStyleNames(_xml(archive, 'word/styles.xml'));
  final meta = _coreMetadata(_xml(archive, 'docProps/core.xml'), filename);
  final notes = _DocxNotes(
    _docxNotes(_xml(archive, 'word/footnotes.xml'), 'footnote'),
    _docxNotes(_xml(archive, 'word/endnotes.xml'), 'endnote'),
  );

  resetBlockIds();
  final paras = <_Para>[];
  // Instructions of the fields open at this point of the document; a TOC
  // field runs from the first contents line to the last.
  final fields = <StringBuffer>[];
  bool inToc() => fields.any((f) => _tocField.hasMatch(f.toString()));
  for (final p in body.descendants.whereType<XmlElement>()) {
    if (p.name.local != 'p') continue;
    // A contents line is short: a long paragraph while a TOC field seems
    // open means the field was never closed, and the book goes on.
    if (inToc() && p.innerText.length > 200) {
      fields.removeWhere((f) => _tocField.hasMatch(f.toString()));
    }
    final tocBefore = inToc();
    final tocHere = _scanFields(p, fields) || tocBefore || inToc();
    // A text box is stored twice, for new Word (mc:Choice) and old
    // (mc:Fallback): read once.
    if (_inside(p, 'Fallback') || tocHere || _inContentsControl(p)) continue;
    final ppr = _child(p, 'pPr');
    final styleId = _attr(_child(ppr, 'pStyle'), 'val') ?? '';
    final styleName = (styles[styleId] ?? styleId).toLowerCase();
    if (_tocStyle.hasMatch(styleName) || _tocStyle.hasMatch(styleId.toLowerCase())) continue;
    // Paragraphs nested in a text box inside another paragraph are visited
    // on their own; only take the outermost text runs of this one.
    final referenced = <String>[];
    final text = collapseWhitespace(_docxText(p, notes, referenced));
    if (text.isNotEmpty) {
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
      paras.add((text: text, level: level, list: _child(ppr, 'numPr') != null, note: false));
    }
    for (final ref in referenced) {
      paras.addAll(notes.footnoteParas(ref));
    }
  }
  paras.addAll(notes.endnoteParas());

  return assembleBook(
    id: id,
    metadata: meta,
    sections: _sectionsByHeading(paras, meta.title),
    source: SourceKind.docx,
    filename: filename,
  );
}

final _tocField = RegExp(r'^\s*TOC\b');
final _tocStyle = RegExp(r'^(toc\s*\d|toc\s*heading|tocheading|table of figures)$');

/// Updates [fields] with the field codes of [p] (fldChar begin / instrText
/// / end, and fldSimple); true when a contents (TOC) field shows up in it.
bool _scanFields(XmlElement p, List<StringBuffer> fields) {
  var toc = false;
  for (final e in p.descendants.whereType<XmlElement>()) {
    switch (e.name.local) {
      case 'fldChar':
        final type = _attr(e, 'fldCharType');
        if (type == 'begin') {
          fields.add(StringBuffer());
        } else if (type == 'end' && fields.isNotEmpty) {
          if (_tocField.hasMatch(fields.last.toString())) toc = true;
          fields.removeLast();
        }
      case 'instrText':
        if (fields.isNotEmpty) fields.last.write(e.innerText);
      case 'fldSimple':
        if (_tocField.hasMatch(_attr(e, 'instr') ?? '')) toc = true;
    }
  }
  return toc;
}

bool _inside(XmlElement e, String local) {
  for (var p = e.parentElement; p != null; p = p.parentElement) {
    if (p.name.local == local) return true;
  }
  return false;
}

/// Inside Word's "Table of Contents" content control.
bool _inContentsControl(XmlElement e) {
  for (var p = e.parentElement; p != null; p = p.parentElement) {
    if (p.name.local != 'sdt') continue;
    final gallery = _child(_child(_child(p, 'sdtPr'), 'docPartObj'), 'docPartGallery');
    if ((_attr(gallery, 'val') ?? '').toLowerCase().contains('table of contents')) return true;
  }
  return false;
}

/// Footnotes and endnotes by id, numbered in the order the text points at
/// them, as Word numbers them.
class _DocxNotes {
  _DocxNotes(this.footnotes, this.endnotes);

  final Map<String, List<String>> footnotes;
  final Map<String, List<String>> endnotes;
  final _footNumbers = <String, int>{};
  final _endNumbers = <String, int>{};

  String footMark(String id) => _superscript(_footNumbers.putIfAbsent(id, () => _footNumbers.length + 1));
  String endMark(String id) => _superscript(_endNumbers.putIfAbsent(id, () => _endNumbers.length + 1));

  List<_Para> footnoteParas(String id) => _paras(footnotes[id], footMark(id));

  List<_Para> endnoteParas() => [
        for (final e in _endNumbers.entries) ..._paras(endnotes[e.key], _superscript(e.value)),
      ];

  static List<_Para> _paras(List<String>? lines, String mark) => [
        for (var i = 0; i < (lines ?? const []).length; i++)
          (text: i == 0 ? '${silentMark(mark)} ${lines![i]}' : lines![i], level: 0, list: false, note: true),
      ];
}

/// The notes in footnotes.xml or endnotes.xml: id -> paragraph texts.
/// Word's separator "notes" are not notes.
Map<String, List<String>> _docxNotes(XmlDocument? doc, String tag) {
  if (doc == null) return const {};
  final out = <String, List<String>>{};
  for (final n in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == tag)) {
    final type = _attr(n, 'type') ?? 'normal';
    final id = _attr(n, 'id');
    if (id == null || type != 'normal') continue;
    out[id] = [
      for (final p in n.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p'))
        if (collapseWhitespace(_docxText(p, null, null)).isNotEmpty) collapseWhitespace(_docxText(p, null, null)),
    ];
  }
  return out;
}

/// 12 as "¹²", as Word shows a note's number.
String _superscript(int n) => superscriptNumber(n);

/// The text of paragraph [p]. Note references become their (silent) marks
/// and are listed in [referenced]; hidden runs are left out.
String _docxText(XmlElement p, _DocxNotes? notes, List<String>? referenced) {
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
        case 'r':
          if (!_hidden(c)) walk(c);
        case 'footnoteReference':
          final id = _attr(c, 'id');
          if (id != null && notes != null) {
            buf.write(silentMark(notes.footMark(id)));
            referenced?.add(id);
          }
        case 'endnoteReference':
          final id = _attr(c, 'id');
          if (id != null && notes != null) buf.write(silentMark(notes.endMark(id)));
        case 'delText':
        case 'instrText':
        case 'pPr':
        case 'rPr':
        case 'footnoteRef':
        case 'endnoteRef':
        case 'Fallback':
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

/// A run formatted as hidden text (w:vanish), not shown by Word.
bool _hidden(XmlElement run) {
  final vanish = _child(_child(run, 'rPr'), 'vanish');
  if (vanish == null) return false;
  final v = (_attr(vanish, 'val') ?? 'true').toLowerCase();
  return v != '0' && v != 'false' && v != 'off';
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
  final paras = <_Para>[];
  void add(XmlElement c, int level, bool list) {
    final notes = <(String, String)>[];
    final text = collapseWhitespace(_odtText(c, notes));
    if (text.isNotEmpty) paras.add((text: text, level: level, list: list, note: false));
    // A note's body comes right after its paragraph, as a note.
    for (final (mark, body) in notes) {
      paras.add((text: '${silentMark(mark)} $body', level: 0, list: false, note: true));
    }
  }

  void visit(XmlElement e, {bool inList = false}) {
    for (final c in e.children.whereType<XmlElement>()) {
      switch (c.name.local) {
        case 'h':
          add(c, int.tryParse(_attr(c, 'outline-level') ?? '') ?? 1, false);
        case 'p':
          add(c, 0, inList);
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

/// The text of [e]; each note in it adds its (mark, body) to [notes] and
/// leaves its mark, silent, in the text.
String _odtText(XmlElement e, [List<(String, String)>? notes]) {
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
          case 'note':
            final citation = collapseWhitespace(
              c.children.whereType<XmlElement>().where((x) => x.name.local == 'note-citation').firstOrNull?.innerText ??
                  '',
            );
            final noteBody = c.children.whereType<XmlElement>().where((x) => x.name.local == 'note-body').firstOrNull;
            final text = noteBody == null ? '' : collapseWhitespace(_odtText(noteBody));
            final mark = int.tryParse(citation) == null ? citation : _superscript(int.parse(citation));
            if (mark.isNotEmpty) buf.write(silentMark(mark));
            if (text.isNotEmpty) notes?.add((mark, text));
          case 'annotation':
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
List<DraftSection> _sectionsByHeading(List<_Para> paras, String fallbackTitle) {
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
      role: p.note
          ? BlockRole.footnote
          : p.level > 0
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
    return XmlDocument.parse(decodeBytes(Uint8List.fromList(data), markup: true));
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
