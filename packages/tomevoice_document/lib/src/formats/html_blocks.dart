import 'package:xml/xml.dart';

import '../build.dart';
import 'epub.dart' show zipJoin;
import '../model.dart';
import '../segment.dart';
import 'text.dart' show sectionsFromPlainText;

/// Elements that are a block of text of their own (unless all they hold is
/// other blocks).
const _blockTags = {
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'blockquote',
  'figcaption',
  'pre',
  'table',
  'section',
  'article',
  'header',
  'footer',
  'aside',
  'nav',
  'dt',
  'dd',
  'th',
  'td',
  'tr',
  'caption',
  'hgroup',
};

/// Elements that only arrange other blocks: lists, tables, the page itself.
/// A run of text never continues across one.
const _structuralTags = {
  'html',
  'body',
  'main',
  'ul',
  'ol',
  'dl',
  'menu',
  'dir',
  'thead',
  'tbody',
  'tfoot',
  'colgroup',
  'figure',
  'center',
  'address',
  'details',
  'summary',
  'fieldset',
  'form',
  'legend',
  'hr',
};

const _skipTags = {'script', 'style', 'head', 'noscript'};

/// Roles whose blocks may be cut in two at a double line break: a `<p>` or
/// a `<div>` full of `<br/><br/>`-separated paragraphs, as Kindle HTML and
/// web novels write them. A heading or a list item stays whole.
const _splittable = {BlockRole.paragraph, BlockRole.quote, BlockRole.footnote};

/// Stand-in for `<br/>` while a run's text is gathered: a noncharacter, so
/// it can never be confused with text from the book.
final _lineBreak = String.fromCharCode(0xFDD2);
final _paragraphBreak = RegExp('$_lineBreak[\\s$_lineBreak]*$_lineBreak');
final _ownMarks = RegExp('[${String.fromCharCode(0xFDD0)}-${String.fromCharCode(0xFDD2)}]');
final _blankLine = RegExp(r'\n[ \t\r]*\n');

/// Walk XHTML/HTML into [Block]s. Joins inline runs inside a block so a drop
/// cap (`<span>O</span>nce`) does not become its own sentence.
///
/// Footnote markers are kept on the page but marked silent, and notes are
/// [BlockRole.footnote]. [notes] are the ids in this document that links in
/// earlier documents point at; [hasFile] says whether a path is a document
/// of the same book (so a link to `notes.xhtml#n1` is a link into it).
List<Block> blocksFromHtml(
  String html, {
  String? language,
  String? href,
  Set<String> notes = const {},
  bool Function(String path)? hasFile,
}) =>
    htmlChapter(html, language: language, href: href, notes: notes, hasFile: hasFile).blocks;

/// One XHTML/HTML document: its [blocksFromHtml], and the index of the first
/// block at or after each element id, so an EPUB can start chapters where
/// its contents points (`book.xhtml#chapter3`).
({List<Block> blocks, Map<String, int> anchors}) htmlChapter(
  String html, {
  String? language,
  String? href,
  Set<String> notes = const {},
  bool Function(String path)? hasFile,
}) {
  final doc = _parse(html);
  if (doc == null) return (blocks: lenientHtmlBlocks(html, language: language), anchors: const {});

  XmlElement body = doc.rootElement;
  if (doc.rootElement.localName.toLowerCase() == 'html') {
    final bodies = [
      for (final e in doc.rootElement.childElements)
        if (e.localName.toLowerCase() == 'body') e,
    ];
    if (bodies.isNotEmpty) body = bodies.first;
  }

  final walker = _Walker(href, hasFile);
  if (_isPlainText(body)) {
    walker.plainText(body, language);
  } else {
    walker.notes = {...notes, ..._forwardNotes(body, walker)};
    walker.walk(body, language, inherited: null);
  }
  return (blocks: joinDropCaps(_notesHeading(walker.out)), anchors: walker.anchors);
}

/// Ids of notes in this document: what its marker links point forward to.
/// A note's link back to the text points backward, so the text it returns
/// to is never taken for a note.
Set<String> _forwardNotes(XmlElement body, _Walker walker) {
  final seen = <String>{};
  final out = <String>{};
  // The text just before each link, as the walker will see it.
  var tail = '';
  for (final n in body.descendants) {
    if (n is XmlText) {
      final t = tail + n.value;
      tail = t.length > 24 ? t.substring(t.length - 24) : t;
      continue;
    }
    if (n is! XmlElement) continue;
    if (n.localName.toLowerCase() == 'a') {
      final target = walker.sameDocument(_href(n));
      if (target != null && !seen.contains(target) && _isMarkerLink(n, walker, tail: tail)) {
        out.add(target);
      }
    }
    final id = _idOf(n);
    if (id != null) seen.add(id);
  }
  return out;
}

final _linkTag = RegExp(r'<a\b([^>]*)>([\s\S]{0,300}?)</a\s*>', caseSensitive: false);
final _anyTag = RegExp(r'<[^>]*>');
final _noterefAttr = RegExp(r'''(?:type|role)\s*=\s*["'][^"']*(?:noteref|doc-noteref)''', caseSensitive: false);
final _hrefAttr = RegExp(r'''\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')''', caseSensitive: false);

/// The links in [html] that look like footnote markers, as written. A
/// quick look at the raw text, so an EPUB knows which ids in its later
/// files are notes before it parses them. A contents page (mostly links)
/// has none.
List<String> markerLinks(String html) {
  final out = <String>[];
  var linkText = 0;
  for (final m in _linkTag.allMatches(html)) {
    final attrs = m.group(1)!;
    final inner = collapseWhitespace(decodeEntities(m.group(2)!.replaceAll(_anyTag, '')));
    linkText += inner.length;
    final h = _hrefAttr.firstMatch(attrs);
    final href = (h?.group(1) ?? h?.group(2) ?? '').trim();
    if (!href.contains('#')) continue;
    if (_noterefAttr.hasMatch(attrs)) {
      out.add(href);
      continue;
    }
    if (inner.isEmpty || !_markerLinkText.hasMatch(inner)) continue;
    if (_bareNumber.hasMatch(inner)) {
      // "chapter 2", "page 9": a reference to read, not a marker.
      final before = html.substring(m.start < 60 ? 0 : m.start - 60, m.start).replaceAll(_anyTag, '');
      if (_readNumberAfter.hasMatch(decodeEntities(before))) continue;
    }
    out.add(href);
  }
  if (out.isEmpty) return out;
  final all = collapseWhitespace(decodeEntities(html.replaceAll(_anyTag, ' '))).length;
  return all > 0 && linkText * 10 >= all * 6 ? const [] : out;
}

/// A heading that only introduces notes ("Notes", "Endnotes") is part of
/// them: nobody wants it read with nothing after it.
List<Block> _notesHeading(List<Block> blocks) {
  var changed = false;
  final out = [...blocks];
  for (var i = 0; i < out.length; i++) {
    if (out[i].role != BlockRole.heading) continue;
    var notes = 0;
    var other = 0;
    for (var j = i + 1; j < out.length && out[j].role != BlockRole.heading; j++) {
      if (out[j].role == BlockRole.footnote) {
        notes++;
      } else if (out[j].role != BlockRole.figure) {
        other++;
      }
    }
    if (notes > 0 && other == 0) {
      out[i] = out[i].withRole(BlockRole.footnote);
      changed = true;
    }
  }
  return changed ? out : blocks;
}

XmlDocument? _parse(String html) {
  try {
    return XmlDocument.parse(_ensureRoot(html), entityMapping: _entities);
  } on XmlException {
    try {
      return XmlDocument.parse(_ensureRoot(_stripDoctype(html)), entityMapping: _entities);
    } on XmlException {
      return null;
    }
  }
}

/// Every HTML5 named character reference, not just XML's five: XHTML in the
/// wild writes `&nbsp;` and `&mdash;` without declaring them.
const _entities = XmlDefaultEntityMapping.html5();

/// A body with text but no blocks at all is plain text dressed as HTML (a
/// PalmDOC book): its blank lines are its paragraphs.
bool _isPlainText(XmlElement body) =>
    !_hasBlockDescendant(body) && _blankLine.hasMatch(body.innerText);

class _Walker {
  _Walker(this.href, this.hasFile);

  final String? href;
  final bool Function(String path)? hasFile;

  /// Ids of the notes in this document.
  Set<String> notes = const {};
  final out = <Block>[];

  /// Element id -> the first block at or after it; ids seen since the
  /// last block wait in [pending].
  final anchors = <String, int>{};
  final pending = <String>[];

  void _add(Block b) {
    for (final id in pending) {
      anchors.putIfAbsent(id, () => out.length);
    }
    pending.clear();
    out.add(b);
  }

  /// The id a link points at in this same document, or null.
  String? sameDocument(String link) {
    final hash = link.indexOf('#');
    if (hash < 0 || hash == link.length - 1) return null;
    final path = link.substring(0, hash);
    if (path.isNotEmpty && (href == null || _resolve(path) != href)) return null;
    return _decode(link.substring(hash + 1));
  }

  /// Whether a link points at a place inside this book.
  bool internal(String link) {
    final hash = link.indexOf('#');
    if (hash < 0 || hash == link.length - 1) return false;
    final path = link.substring(0, hash);
    if (path.isEmpty) return true;
    if (path.contains(':') || href == null) return false;
    final resolved = _resolve(path);
    return resolved == href || (hasFile?.call(resolved) ?? false);
  }

  String _resolve(String path) => zipJoin(_dirOfPath(href!), _decode(path));

  /// Whether [e] (with an id) is the start of a note: small, no headings
  /// in it, and pointed at by a marker. A chapter a contents link points at
  /// is none of those.
  bool _isNote(XmlElement e) {
    final id = _idOf(e);
    if (id == null || !notes.contains(id)) return false;
    final name = e.localName.toLowerCase();
    if (const {'body', 'html', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(name)) return false;
    if (e.descendants.whereType<XmlElement>().any((d) => _headingTags.contains(d.localName.toLowerCase()))) {
      return false;
    }
    return e.innerText.length <= 3000;
  }

  /// Whether the text of [nodes] opens with a note's own anchor
  /// (`<p><a id="fn1" href="#ref1">1</a> The note.</p>`).
  bool _opensNote(List<XmlNode> nodes) {
    var found = false;
    var text = false;
    void walk(XmlNode n) {
      if (found || text) return;
      if (n is XmlText || n is XmlCDATA) {
        if (n.value!.trim().isNotEmpty) text = true;
        return;
      }
      if (n is! XmlElement) return;
      if (_isNote(n)) {
        found = true;
        return;
      }
      for (final c in n.children) {
        walk(c);
      }
    }

    for (final n in nodes) {
      walk(n);
    }
    return found;
  }

  void walk(XmlNode node, String? inheritedLanguage, {required BlockRole? inherited}) {
    if (node is! XmlElement) return;
    final name = node.localName.toLowerCase();
    if (_skipTags.contains(name) || _isApparatus(node)) return;
    final id = _idOf(node);
    if (id != null) pending.add(id);
    // A paragraph or passage marked in another language keeps it. The
    // page's own <html lang> is usually a template's default, not a claim.
    final language = name == 'html' || name == 'body' ? inheritedLanguage : _langOf(node) ?? inheritedLanguage;

    if (name == 'img' || name == 'svg') {
      _images(node, language);
      return;
    }

    final role = _isNote(node) ? BlockRole.footnote : _roleFor(node, name, inherited);
    if (_isLeaf(node, name)) {
      final text = _inlineText([node], this);
      // "Transcriber's note: the spelling of the original is kept."
      if (text.length < 3000 && _transcribersNote.hasMatch(collapseWhitespace(text.replaceAll(_ownMarks, ' ')))) {
        return;
      }
      _emitText(
        text,
        text.length <= 3000 && _opensNote(node.children) ? BlockRole.footnote : role,
        language,
        name,
      );
      // <p><img/></p> is the usual way a picture sits in a chapter.
      _images(node, language);
      return;
    }
    _container(node, role ?? inherited, language);
  }

  /// The children of a block that holds other blocks. Text and inline
  /// elements between those blocks (`<h2>…</h2>text<br/>text`, or text
  /// straight in `<body>`) are paragraphs of their own, not dropped.
  ///
  /// A transcriber's notes, under their title, are passed over: notes about
  /// the e-text ("New original cover art included with this eBook is
  /// granted to the public domain"), which Project Gutenberg's books have at
  /// their end, read aloud after the story. They run to the next heading as
  /// high as their title, or the end of what holds them.
  void _container(XmlElement node, BlockRole? role, String? language) {
    final run = <XmlNode>[];
    void flush() {
      if (run.isEmpty) return;
      final text = _inlineText(run, this);
      _emitText(
        text,
        text.length <= 3000 && _opensNote(run) ? BlockRole.footnote : role ?? BlockRole.paragraph,
        language,
        'p',
      );
      for (final n in run) {
        if (n is XmlElement) _images(n, language);
      }
      run.clear();
    }

    // While a transcriber's notes are passed over: the heading level that
    // ends them, and how much has gone.
    int? notesEnd;
    var passed = 0;
    for (final child in node.children) {
      if (child is XmlElement && _breaksRun(child)) {
        flush();
        if (notesEnd != null) {
          final level = _headingLevel(child);
          if ((level == null || level > notesEnd) && passed < _longestTranscribersNotes) {
            passed += child.innerText.length;
            continue;
          }
          notesEnd = null;
        }
        final notes = _transcribersNotesTitle(child);
        if (notes != null) {
          notesEnd = notes;
          passed = 0;
          continue;
        }
        walk(child, language, inherited: role);
      } else if (notesEnd == null) {
        run.add(child);
      }
    }
    flush();
  }

  void _emitText(String raw, BlockRole? role, String? language, String tag) {
    final r = role ?? BlockRole.paragraph;
    final pieces = _splittable.contains(r)
        ? raw.split(_paragraphBreak)
        : [raw];
    for (final piece in pieces) {
      final text = collapseWhitespace(piece.replaceAll(_lineBreak, ' '));
      if (text.isEmpty) continue;
      // Transcribers' notes about Gutenberg editions sit in the book's own
      // text.
      if (text.length < 600 && text.toLowerCase().contains('project gutenberg')) continue;
      _add(makeBlock(
        role: r,
        text: text,
        language: language,
        anchor: href != null ? EpubAnchor(_cfi(href, tag, out.length)) : OffsetAnchor(0, text.length),
      ));
    }
  }

  /// Figure blocks for every picture in [node] (itself included): `<img src>`
  /// and `<svg><image href>`, which is how most EPUB covers are drawn. The
  /// path is resolved against the chapter file so the importer can find the
  /// bytes.
  void _images(XmlElement node, String? language) {
    final found = <XmlElement>[
      if (_isPicture(node)) node,
      ...node.descendants.whereType<XmlElement>().where(_isPicture),
    ];
    for (final el in found) {
      final name = el.localName.toLowerCase();
      final src = name == 'img' ? el.getAttribute('src') ?? '' : _attr(el, 'href');
      final alt = collapseWhitespace(el.getAttribute('alt') ?? '');
      final path = href == null || src.isEmpty || src.startsWith('data:')
          ? null
          : zipJoin(_dirOfPath(href!), _decode(src));
      if (path == null && alt.isEmpty) continue;
      _add(makeBlock(
        role: BlockRole.figure,
        text: alt,
        language: language,
        image: path,
        anchor: EpubAnchor(_cfi(href, name, out.length)),
      ));
    }
  }

  /// A body that is really plain text, read the way a .txt file is.
  void plainText(XmlElement body, String? language) {
    final text = _inlineText([body], this).replaceAll(_lineBreak, '\n');
    for (final s in sectionsFromPlainText(text, fallbackTitle: '')) {
      for (final b in s.blocks) {
        out.add(language == null
            ? b
            : makeBlock(role: b.role, text: b.text, language: language, anchor: b.anchor, id: b.id));
      }
    }
  }
}

/// "Transcriber's Notes", "TRANSCRIBERS' NOTE:", "Note from the transcriber":
/// notes on how an e-text was made from its book.
final _transcribersNote = RegExp(
  r'''^(transcriber['’`]?s?['’`]?\s+notes?|notes?\s+(of|from|by)\s+the\s+transcriber)\b''',
  caseSensitive: false,
);

/// The most of a transcriber's notes passed over: past it, what follows a
/// title is taken for the book.
const _longestTranscribersNotes = 20000;

/// For a block that is only the title of a transcriber's notes ("<h2>
/// Transcriber's Notes</h2>", "<div><b>Transcriber’s Notes</b></div>"): the
/// heading level that ends them (7 for any heading, under a title that is
/// no heading). Null for any other block.
int? _transcribersNotesTitle(XmlElement e) {
  if (_firstText(e) case final first? when first.length < 60 && _transcribersNote.hasMatch(first)) {
    final text = collapseWhitespace(e.innerText);
    if (text.length < 60 && _transcribersNote.hasMatch(text) && !_textAfterStop.hasMatch(text)) {
      return _headingLevel(e) ?? 7;
    }
  }
  return null;
}

/// A title is only a title: "Transcriber's Note: the spelling..." is a note.
final _textAfterStop = RegExp(r'[:.]\s*\S');

/// The first words of [e]'s text, looked for without reading all of it.
String? _firstText(XmlElement e) {
  for (final n in e.descendants) {
    if (n is XmlText || n is XmlCDATA) {
      final t = n.value!.trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

/// 1 to 6 for a heading element, null for anything else.
int? _headingLevel(XmlElement e) {
  final name = e.localName.toLowerCase();
  return _headingTags.contains(name) ? int.parse(name.substring(1)) : null;
}

/// A block element that holds no other blocks: its text is one block.
bool _isLeaf(XmlElement node, String name) {
  if (!_blockTags.contains(name)) return false;
  if (name == 'tr') {
    // A table row is read cell by cell, unless a cell holds paragraphs.
    return !node.childElements.any((c) => _hasBlockChild(c));
  }
  return !_hasBlockChild(node);
}

bool _isBlockLevel(String name) => _blockTags.contains(name) || _structuralTags.contains(name);

bool _hasBlockChild(XmlElement node) {
  for (final child in node.childElements) {
    if (_isBlockLevel(child.localName.toLowerCase())) return true;
  }
  return false;
}

bool _hasBlockDescendant(XmlElement node) {
  for (final child in node.childElements) {
    if (_isBlockLevel(child.localName.toLowerCase()) || _hasBlockDescendant(child)) return true;
  }
  return false;
}

/// Whether [e] ends a run of inline text: a block, or an inline element
/// that (in bad markup) wraps blocks.
bool _breaksRun(XmlElement e) {
  final name = e.localName.toLowerCase();
  if (_isBlockLevel(name)) return true;
  if (name == 'img' || name == 'svg' || _skipTags.contains(name)) return false;
  return _hasBlockDescendant(e);
}

/// The text of [nodes] as one run: inline markup joined, a space at cells
/// and block edges, [_lineBreak] for `<br/>`, ruby readings and pictures
/// left out, and footnote markers marked silent.
String _inlineText(List<XmlNode> nodes, _Walker walker) {
  final buf = StringBuffer();
  // The last few characters written, for what a marker follows.
  var tail = '';
  void write(String s) {
    if (s.isEmpty) return;
    buf.write(s);
    final t = tail + s;
    tail = t.length > 24 ? t.substring(t.length - 24) : t;
  }

  void walk(XmlNode n) {
    if (n is XmlText || n is XmlCDATA) {
      write(n.value!.replaceAll(_ownMarks, ''));
      return;
    }
    if (n is! XmlElement) return;
    final name = n.localName.toLowerCase();
    if (name == 'br') {
      write(_lineBreak);
      return;
    }
    if (name == 'svg' ||
        name == 'rt' ||
        name == 'rp' ||
        _skipTags.contains(name) ||
        _isApparatus(n) ||
        _isPageBreak(n)) {
      return;
    }
    final id = _idOf(n);
    if (id != null) walker.pending.add(id);
    if ((name == 'a' || name == 'sup' || name == 'span') && _isMarker(n, walker, tail)) {
      write(silentMark(collapseWhitespace(n.innerText.replaceAll(_ownMarks, ''))));
      return;
    }
    final edge = _isBlockLevel(name);
    if (edge) write(' ');
    for (final c in n.children) {
      walk(c);
    }
    if (edge) write(' ');
  }

  for (final n in nodes) {
    if (n is XmlElement && _blockTags.contains(n.localName.toLowerCase())) {
      // The run is this one element: its own edges are not text.
      for (final c in n.children) {
        walk(c);
      }
    } else {
      walk(n);
    }
  }
  return buf.toString();
}

const _headingTags = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// epub:type values (any vocabulary prefix dropped) and ARIA roles of notes.
const _noteTypes = {'footnote', 'footnotes', 'endnote', 'endnotes', 'rearnote', 'rearnotes', 'note', 'notes'};
const _noteRoles = {'doc-footnote', 'doc-endnote', 'doc-endnotes'};

final _spaces = RegExp(r'\s+');

/// epub:type values; most elements have none, and are asked about often.
Set<String> _types(XmlElement e) {
  String? type;
  for (final a in e.attributes) {
    if (a.name.local == 'type') {
      type = a.value;
      break;
    }
  }
  if (type == null || type.isEmpty) return const {};
  return {
    for (final t in type.toLowerCase().split(_spaces))
      if (t.isNotEmpty) t.split(':').last,
  };
}

String _role(XmlElement e) {
  for (final a in e.attributes) {
    if (a.name.local == 'role') return a.value.toLowerCase().trim();
  }
  return '';
}

/// A printed page number inside the text (`<span epub:type="pagebreak">7`).
bool _isPageBreak(XmlElement e) => _types(e).contains('pagebreak') || _role(e) == 'doc-pagebreak';

String _href(XmlElement e) => _attr(e, 'href').trim();

/// `xml:lang` or `lang`, when set.
String? _langOf(XmlElement e) {
  for (final a in e.attributes) {
    if (a.name.local == 'lang' && a.value.trim().isNotEmpty) return a.value.trim();
  }
  return null;
}

String? _idOf(XmlElement e) {
  final id = e.getAttribute('id') ?? _attr(e, 'id');
  if (id.isNotEmpty) return id;
  if (e.localName.toLowerCase() == 'a') {
    final name = e.getAttribute('name') ?? '';
    if (name.isNotEmpty) return name;
  }
  return null;
}

/// "1", "[12]", "(3)", "*", "†", "a", "iv": what a footnote marker says.
final _markerLinkText = RegExp(
  r'^[\[({]?(\p{Nd}{1,4}[a-z]?|[*†‡§¶‖#]{1,3}|\p{L}|[ivxlcdm]{1,6}|[IVXLCDM]{1,6})[\])}]?[.,:;]?$',
  unicode: true,
);

/// In a `<sup>` only numbers and symbols, or a bracketed letter: "nd" in
/// 2<sup>nd</sup> and "r" in M<sup>r</sup> are part of the word.
final _markerSupText = RegExp(r'^[\[(]?(\p{Nd}{1,4}|[*†‡§¶‖#]{1,3})[\])]?$|^\[\p{L}\]$', unicode: true);

/// Words after which a number is a reference to read, not a marker:
/// "see chapter 2", "page 9", "note 3" (a marker is not set off by a space).
final _readNumberAfter = RegExp(
  r'(?:^|[^\p{L}])(?:chapters?|chap|ch|pages?|pp?|sections?|sect|sec|figures?|fig|tables?|tab|parts?|books?|'
  r'volumes?|vol|notes?|no|verses?|lines?|items?|steps?|appendix|psalms?|vs?)\.?\s+$',
  caseSensitive: false,
  unicode: true,
);
final _bareNumber = RegExp(r'^\p{Nd}+[a-z]?$', unicode: true);

/// Whether [e] is a footnote marker, given the text just before it.
bool _isMarker(XmlElement e, _Walker walker, String tail) {
  final name = e.localName.toLowerCase();
  final types = _types(e);
  final text = collapseWhitespace(e.innerText.replaceAll(_ownMarks, ''));
  if (text.isEmpty) return false;
  if (types.contains('noteref') || _role(e) == 'doc-noteref') return true;
  if (name == 'sup') {
    if (!_markerSupText.hasMatch(text)) return false;
    // 10<sup>6</sup> is a power, not a note.
    final before = tail.isEmpty ? 0 : tail.codeUnitAt(tail.length - 1);
    if (before >= 0x30 && before <= 0x39) return false;
    return !_inContents(e);
  }
  if (name == 'a') return _isMarkerLink(e, walker, tail: tail);
  return false;
}

/// A short link into the book that says "1", "[2]" or "*": a note marker.
bool _isMarkerLink(XmlElement a, _Walker walker, {required String tail}) {
  final types = _types(a);
  if (types.contains('noteref') || _role(a) == 'doc-noteref') return true;
  if (!walker.internal(_href(a))) return false;
  final text = collapseWhitespace(a.innerText.replaceAll(_ownMarks, ''));
  if (!_markerLinkText.hasMatch(text)) return false;
  if (_bareNumber.hasMatch(text) && _readNumberAfter.hasMatch(tail)) return false;
  return !_inContents(a);
}

/// Inside a table of contents: a nav, or a block that is mostly links
/// ("1 2 3 4" linking to the chapters).
bool _inContents(XmlElement e) {
  XmlElement? block;
  for (var p = e.parentElement; p != null; p = p.parentElement) {
    final name = p.localName.toLowerCase();
    if (name == 'nav' || _types(p).any((t) => t == 'toc' || t == 'landmarks' || t == 'page-list')) {
      return true;
    }
    if (block == null && _blockTags.contains(name)) block = p;
  }
  if (block == null) return false;
  final all = collapseWhitespace(block.innerText).length;
  final links = block.descendants
      .whereType<XmlElement>()
      .where((d) => d.localName.toLowerCase() == 'a')
      .fold<int>(0, (n, d) => n + collapseWhitespace(d.innerText).length);
  return all > 0 && links * 10 >= all * 6;
}

BlockRole? _roleFor(XmlElement node, String name, BlockRole? inherited) {
  // A note's paragraphs, lists and headings are all the note.
  if (inherited == BlockRole.footnote) return BlockRole.footnote;
  final types = _types(node);
  final aria = _role(node);

  if (types.any(_noteTypes.contains) || _noteRoles.contains(aria) || name == 'aside') {
    return BlockRole.footnote;
  }
  if (types.contains('pagebreak') || aria == 'doc-pagebreak') {
    return BlockRole.pageNumber;
  }
  if (types.contains('caption') || name == 'figcaption' || name == 'caption') {
    return BlockRole.caption;
  }

  switch (name) {
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return BlockRole.heading;
    case 'li':
    case 'dt':
    case 'dd':
      return BlockRole.listItem;
    case 'blockquote':
      return BlockRole.quote;
    case 'pre':
    case 'code':
      return BlockRole.code;
    case 'table':
    case 'tr':
    case 'th':
    case 'td':
      return BlockRole.table;
    case 'math':
      return BlockRole.math;
  }

  return inherited ?? BlockRole.paragraph;
}

String _attr(XmlElement node, String local) {
  for (final a in node.attributes) {
    if (a.name.local == local) return a.value;
  }
  return node.getAttribute(local) ?? '';
}

String _cfi(String? href, String tag, int index) =>
    'epubcfi(/6/${href ?? ''}[$tag$index])';

String _ensureRoot(String html) {
  final trimmed = html.trim();
  if (trimmed.contains('<html') || trimmed.contains('<HTML')) return trimmed;
  if (trimmed.contains('<body') || trimmed.contains('<BODY')) {
    return '<html xmlns="http://www.w3.org/1999/xhtml">$trimmed</html>';
  }
  return '<html xmlns="http://www.w3.org/1999/xhtml"><body>$trimmed</body></html>';
}

String _stripDoctype(String html) =>
    html.replaceFirst(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');

String _stripTags(String html) => html
    .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
    .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
    // Table cells and other block edges inside a run are word breaks.
    .replaceAll(RegExp(r'</?(td|th|li|dt|dd)\b[^>]*>', caseSensitive: false), ' ')
    .replaceAll(RegExp(r'<[^>]+>'), '');

final _boundary = RegExp(
  r'<(/?)(h[1-6]|p|div|li|blockquote|tr|dt|dd|section|article|title|hr)\b[^>]*>',
  caseSensitive: false,
);

/// Tag soup (Kindle HTML, hand-written pages) is not XML. Rather than reading
/// the whole thing as one paragraph, cut at block-level tags and keep going.
List<Block> lenientHtmlBlocks(String html, {String? language}) {
  final cleaned = html
      .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<(rt|rp)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false), '')
      // Two line breaks in a row end a paragraph; one is a space.
      .replaceAll(RegExp(r'(<br\b[^>]*>\s*){2,}', caseSensitive: false), '<p>')
      .replaceAll(RegExp(r'<br\b[^>]*>', caseSensitive: false), ' ');
  final out = <Block>[];
  var role = BlockRole.paragraph;
  var last = 0;
  void emit(int end) {
    final text = collapseWhitespace(decodeEntities(_stripTags(cleaned.substring(last, end))));
    if (text.isNotEmpty) {
      out.add(makeBlock(role: role, text: text, language: language));
    }
  }

  for (final m in _boundary.allMatches(cleaned)) {
    emit(m.start);
    last = m.end;
    final closing = m.group(1)!.isNotEmpty;
    final tag = m.group(2)!.toLowerCase();
    if (closing) {
      role = BlockRole.paragraph;
    } else if (tag.startsWith('h') && tag != 'hr') {
      role = BlockRole.heading;
    } else if (tag == 'li' || tag == 'dt' || tag == 'dd') {
      role = BlockRole.listItem;
    } else if (tag == 'blockquote') {
      role = BlockRole.quote;
    } else {
      role = BlockRole.paragraph;
    }
  }
  emit(cleaned.length);
  return out;
}

/// `&eacute;`, `&#233;` and `&#xE9;` as the characters they stand for: every
/// HTML5 name, not only the handful a hand-written table remembered.
String decodeEntities(String s) => _entities.decode(s);

bool _isPicture(XmlElement e) {
  final n = e.localName.toLowerCase();
  return n == 'img' || (n == 'image' && e.parentElement != null);
}

String _dirOfPath(String path) {
  final i = path.replaceAll(r'\', '/').lastIndexOf('/');
  return i <= 0 ? '' : path.substring(0, i);
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s.split('?').first);
  } on Object {
    return s;
  }
}

/// Things in a book's markup that are not the book: navigation, Project
/// Gutenberg's header and licence, and printed page numbers ("[127]") that
/// would otherwise be read aloud mid-sentence.
///
/// A nav is links: a contents list (pandoc puts one at the top of a page),
/// landmarks, a site's menu. Gutenberg's header and licence are known by
/// their class, or by the ids its Ebookmaker gives them: a Kindle book made
/// from the EPUB keeps the ids but not the class (calibre renames every
/// class), and read its whole licence aloud after the story.
bool _isApparatus(XmlElement e) {
  if (e.localName.toLowerCase() == 'nav') return true;
  final id = e.getAttribute('id');
  if (id == 'pg-header' || id == 'pg-footer') return true;
  final cls = (e.getAttribute('class') ?? '').toLowerCase();
  if (cls.isEmpty) return false;
  return cls.contains('pg-boilerplate') ||
      cls.contains('pagenum') ||
      cls.contains('pageno') ||
      cls.contains('page-number');
}

final _dropCap = RegExp(r'^[^\p{L}]{0,2}\p{Lu}$', unicode: true);
final _continuesWord = RegExp(r'^\p{Lu}', unicode: true);

/// A decorated initial is often a picture whose alt text is the letter
/// (`"Y`), followed by the rest of the word as text ("OU can't think").
/// Put the letter back so the voice says "YOU", and keep the picture.
List<Block> joinDropCaps(List<Block> blocks) {
  final out = <Block>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    out.add(b);
    if (b.role != BlockRole.figure || !_dropCap.hasMatch(b.text)) continue;
    if (i + 1 >= blocks.length) continue;
    final next = blocks[i + 1];
    if (next.role == BlockRole.figure || !_continuesWord.hasMatch(next.text)) continue;
    out.add(makeBlock(
      role: next.role,
      text: b.text + markedText(next),
      anchor: next.anchor,
      language: next.language,
      id: next.id,
    ));
    i++;
  }
  return out;
}
