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
List<Block> blocksFromHtml(String html, {String? language, String? href}) {
  final doc = _parse(html);
  if (doc == null) return lenientHtmlBlocks(html, language: language);

  XmlElement body = doc.rootElement;
  if (doc.rootElement.localName.toLowerCase() == 'html') {
    final bodies = [
      for (final e in doc.rootElement.childElements)
        if (e.localName.toLowerCase() == 'body') e,
    ];
    if (bodies.isNotEmpty) body = bodies.first;
  }

  final walker = _Walker(href);
  if (_isPlainText(body)) {
    walker.plainText(body, language);
  } else {
    walker.walk(body, language, inherited: null);
  }
  return joinDropCaps(walker.out);
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
  _Walker(this.href);

  final String? href;
  final out = <Block>[];

  void walk(XmlNode node, String? language, {required BlockRole? inherited}) {
    if (node is! XmlElement) return;
    final name = node.localName.toLowerCase();
    if (_skipTags.contains(name) || _isApparatus(node)) return;

    if (name == 'img' || name == 'svg') {
      _images(node, out, language, href);
      return;
    }

    final role = _roleFor(node, name, inherited);
    if (_isLeaf(node, name)) {
      _emitText(_inlineText([node]), role, language, name);
      // <p><img/></p> is the usual way a picture sits in a chapter.
      _images(node, out, language, href);
      return;
    }
    _container(node, role ?? inherited, language);
  }

  /// The children of a block that holds other blocks. Text and inline
  /// elements between those blocks (`<h2>…</h2>text<br/>text`, or text
  /// straight in `<body>`) are paragraphs of their own, not dropped.
  void _container(XmlElement node, BlockRole? role, String? language) {
    final run = <XmlNode>[];
    void flush() {
      if (run.isEmpty) return;
      _emitText(_inlineText(run), role ?? BlockRole.paragraph, language, 'p');
      for (final n in run) {
        if (n is XmlElement) _images(n, out, language, href);
      }
      run.clear();
    }

    for (final child in node.children) {
      if (child is XmlElement && _breaksRun(child)) {
        flush();
        walk(child, language, inherited: role);
      } else {
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
      out.add(makeBlock(
        role: r,
        text: text,
        language: language,
        anchor: href != null ? EpubAnchor(_cfi(href, tag, out.length)) : OffsetAnchor(0, text.length),
      ));
    }
  }

  /// A body that is really plain text, read the way a .txt file is.
  void plainText(XmlElement body, String? language) {
    final text = _inlineText([body]).replaceAll(_lineBreak, '\n');
    for (final s in sectionsFromPlainText(text, fallbackTitle: '')) {
      for (final b in s.blocks) {
        out.add(language == null
            ? b
            : makeBlock(role: b.role, text: b.text, language: language, anchor: b.anchor, id: b.id));
      }
    }
  }
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
/// left out.
String _inlineText(List<XmlNode> nodes) {
  final buf = StringBuffer();
  void walk(XmlNode n) {
    if (n is XmlText || n is XmlCDATA) {
      buf.write(n.value!.replaceAll(_ownMarks, ''));
      return;
    }
    if (n is! XmlElement) return;
    final name = n.localName.toLowerCase();
    if (name == 'br') {
      buf.write(_lineBreak);
      return;
    }
    if (name == 'svg' ||
        name == 'rt' ||
        name == 'rp' ||
        _skipTags.contains(name) ||
        _isApparatus(n)) {
      return;
    }
    final edge = _isBlockLevel(name);
    if (edge) buf.write(' ');
    for (final c in n.children) {
      walk(c);
    }
    if (edge) buf.write(' ');
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

BlockRole? _roleFor(XmlElement node, String name, BlockRole? inherited) {
  final epubType = _attr(node, 'type').toLowerCase();
  final aria = (node.getAttribute('role') ?? '').toLowerCase();

  if (epubType.contains('footnote') ||
      epubType.contains('rearnote') ||
      epubType.contains('note') ||
      aria.contains('doc-footnote')) {
    return BlockRole.footnote;
  }
  if (epubType.contains('pagebreak') || aria.contains('doc-pagebreak')) {
    return BlockRole.pageNumber;
  }
  if (epubType.contains('caption') || name == 'figcaption' || name == 'caption') {
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

/// Figure blocks for every picture in [node] (itself included): `<img src>`
/// and `<svg><image href>`, which is how most EPUB covers are drawn. The path
/// is resolved against the chapter file so the importer can find the bytes.
void _images(XmlElement node, List<Block> out, String? language, String? href) {
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
        : zipJoin(_dirOfPath(href), _decode(src));
    if (path == null && alt.isEmpty) continue;
    out.add(makeBlock(
      role: BlockRole.figure,
      text: alt,
      language: language,
      image: path,
      anchor: EpubAnchor(_cfi(href, name, out.length)),
    ));
  }
}

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

/// Things in a book's markup that are not the book: Project Gutenberg's
/// header and licence, and printed page numbers ("[127]") that would
/// otherwise be read aloud mid-sentence.
bool _isApparatus(XmlElement e) {
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
