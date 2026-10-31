import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../encoding.dart';
import '../model.dart';
import '../segment.dart';

/// One paragraph of a word-processor document, before it is a block: a
/// heading's [level], or a list item, a note, or a [table]'s row.
typedef _Para = ({String text, int level, bool list, bool note, bool table});

/// The most a cell of a table of data holds: more, and the table is laid
/// out to hold text (see [_isDataTable]).
const _longestDataCell = 200;

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
  // A table of data is read a row at a time, its cells one block, as a row
  // of an HTML table is: a cell at a time, each was a sentence of its own
  // ("Fable", "Words", "The Lion And The Mouse", "133"). The row being read,
  // its cells' text and the notes they point at.
  final dataTables = {
    for (final t in body.descendants.whereType<XmlElement>())
      if (t.name.local == 'tbl' && _isDataTable(t, 'tc', (p) => _docxText(p, null, null))) t,
  };
  XmlElement? row;
  final cells = <String>[];
  final rowNotes = <String>[];
  void endRow() {
    final text = collapseWhitespace(cells.join(' '));
    if (text.isNotEmpty) paras.add((text: text, level: 0, list: false, note: false, table: true));
    for (final ref in rowNotes) {
      paras.addAll(notes.footnoteParas(ref));
    }
    row = null;
    cells.clear();
    rowNotes.clear();
  }

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
    final inRow = _rowOf(p, 'tr', 'tbl', dataTables);
    if (inRow != row && row != null) endRow();
    if (inRow != null) {
      row = inRow;
      if (text.isNotEmpty) cells.add(text);
      rowNotes.addAll(referenced);
      continue;
    }
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
      paras.add((text: text, level: level, list: _child(ppr, 'numPr') != null, note: false, table: false));
    }
    for (final ref in referenced) {
      paras.addAll(notes.footnoteParas(ref));
    }
  }
  if (row != null) endRow();
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
          (text: i == 0 ? '${silentMark(mark)} ${lines![i]}' : lines![i], level: 0, list: false, note: true, table: false),
      ];
}

/// Whether [table] holds data rather than text: no cell (a [cell] element)
/// with more than one paragraph in it, or more than [_longestDataCell]
/// characters, and no table inside it. A word processor lays text out in
/// tables too (two columns, a box round a passage), and that is read a
/// paragraph at a time.
bool _isDataTable(XmlElement table, String cell, String Function(XmlElement p) textOf) {
  for (final c in table.descendants.whereType<XmlElement>()) {
    if (c.name.local == table.name.local) return false;
    if (c.name.local != cell) continue;
    var paragraphs = 0, length = 0;
    for (final p in c.descendants.whereType<XmlElement>()) {
      if (p.name.local != 'p' && p.name.local != 'h') continue;
      final t = collapseWhitespace(textOf(p));
      if (t.isEmpty) continue;
      paragraphs++;
      length += t.length;
    }
    if (paragraphs > 1 || length > _longestDataCell) return false;
  }
  return true;
}

/// The row (a [row] element) of one of [tables] that paragraph [p] is in, or
/// null when it is in none.
XmlElement? _rowOf(XmlElement p, String row, String table, Set<XmlElement> tables) {
  for (var e = p.parentElement; e != null; e = e.parentElement) {
    if (e.name.local != row) continue;
    for (var t = e.parentElement; t != null; t = t.parentElement) {
      if (t.name.local == table) return tables.contains(t) ? e : null;
    }
    return null;
  }
  return null;
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
  // [c]'s text as one paragraph: a heading's, a list item's, or a table's
  // row's ([table]).
  void add(XmlElement c, int level, bool list, {bool table = false}) {
    final notes = <(String, String)>[];
    final text = table
        ? collapseWhitespace([
            for (final cell in c.children.whereType<XmlElement>())
              if (cell.name.local == 'table-cell') _odtText(cell, notes),
          ].join(' '))
        : collapseWhitespace(_odtText(c, notes));
    if (text.isNotEmpty) paras.add((text: text, level: level, list: list, note: false, table: table));
    // A note's body comes right after its paragraph, as a note.
    for (final (mark, body) in notes) {
      paras.add((text: '${silentMark(mark)} $body', level: 0, list: false, note: true, table: false));
    }
  }

  void visit(XmlElement e, {bool inList = false}) {
    for (final c in e.children.whereType<XmlElement>()) {
      switch (c.name.local) {
        case 'h':
          add(c, int.tryParse(_attr(c, 'outline-level') ?? '') ?? 1, false);
        case 'p':
          add(c, 0, inList);
        // A table of data, a row at a time (see parseDocx).
        case 'table' when _isDataTable(c, 'table-cell', _odtText):
          for (final r in c.descendants.whereType<XmlElement>()) {
            if (r.name.local == 'table-row') add(r, 0, false, table: true);
          }
        case 'list':
        case 'list-item':
          visit(c, inList: true);
        case 'annotation':
        case 'tracked-changes':
        case 'sequence-decls':
          break;
        // Indexes LibreOffice generates, a table of contents above all: page
        // numbers and titles that come later (Word's are not read either).
        case 'table-of-content':
        case 'illustration-index':
        case 'table-index':
        case 'object-index':
        case 'user-index':
        case 'alphabetical-index':
        case 'bibliography':
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

const _svg = 'urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0';

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
          // A picture's title and description (its alt text): words about
          // the picture, which ran into the sentence it sits in.
          case 'title':
          case 'desc':
            if (c.name.namespaceUri != _svg) walk(c);
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
          : p.table
              ? BlockRole.table
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
