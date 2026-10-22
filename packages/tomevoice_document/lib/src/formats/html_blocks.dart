import 'package:xml/xml.dart';

import '../build.dart';
import 'epub.dart' show zipJoin;
import '../model.dart';
import '../segment.dart';

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
  'caption',
  'hgroup',
};

const _skipTags = {'script', 'style', 'head', 'noscript'};

/// Walk XHTML/HTML into [Block]s. Joins inline runs inside a block so a drop
/// cap (`<span>O</span>nce`) does not become its own sentence.
List<Block> blocksFromHtml(String html, {String? language, String? href}) {
  final wrapped = _ensureRoot(html);
  late XmlDocument doc;
  try {
    doc = XmlDocument.parse(wrapped);
  } on XmlException {
    try {
      doc = XmlDocument.parse(_ensureRoot(_stripDoctype(html)));
    } on XmlException {
      return lenientHtmlBlocks(html, language: language);
    }
  }

  XmlNode body = doc.rootElement;
  if (doc.rootElement.localName.toLowerCase() == 'html') {
    final bodies = [
      for (final e in doc.rootElement.childElements)
        if (e.localName.toLowerCase() == 'body') e,
    ];
    if (bodies.isNotEmpty) body = bodies.first;
  }

  final out = <Block>[];
  _walk(body, out, language, href, inherited: null);
  return out;
}

void _walk(
  XmlNode node,
  List<Block> out,
  String? language,
  String? href, {
  required BlockRole? inherited,
}) {
  if (node is! XmlElement) return;
  final name = node.localName.toLowerCase();
  if (_skipTags.contains(name)) return;

  if (name == 'img' || name == 'svg') {
    _images(node, out, language, href);
    return;
  }

  final role = _roleFor(node, name, inherited);

  if (_blockTags.contains(name)) {
    if (_hasBlockChild(node)) {
      for (final child in node.children) {
        _walk(child, out, language, href, inherited: role);
      }
      return;
    }
    final text = collapseWhitespace(_textWithoutSvg(node));
    if (text.isNotEmpty) {
      out.add(makeBlock(
        role: role ?? BlockRole.paragraph,
        text: text,
        language: language,
        anchor: href != null
            ? EpubAnchor(_cfi(href, name, out.length))
            : OffsetAnchor(0, text.length),
      ));
    }
    // <p><img/></p> is the usual way a picture sits in a chapter.
    _images(node, out, language, href);
    return;
  }

  for (final child in node.children) {
    _walk(child, out, language, href, inherited: inherited);
  }
}

bool _hasBlockChild(XmlElement node) {
  for (final child in node.childElements) {
    final n = child.localName.toLowerCase();
    if (_blockTags.contains(n) && n != 'br') return true;
  }
  return false;
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
    .replaceAll(RegExp(r'<[^>]+>'), ' ');

final _boundary = RegExp(
  r'<(/?)(h[1-6]|p|div|li|blockquote|br|tr|dt|dd|section|article|title|hr)\b[^>]*>',
  caseSensitive: false,
);

/// Tag soup (Kindle HTML, hand-written pages) is not XML. Rather than reading
/// the whole thing as one paragraph, cut at block-level tags and keep going.
List<Block> lenientHtmlBlocks(String html, {String? language}) {
  final cleaned = html
      .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ');
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
    } else if (tag != 'br') {
      role = BlockRole.paragraph;
    }
  }
  emit(cleaned.length);
  return out;
}

const _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'mdash': '—', 'ndash': '–', 'hellip': '…',
  'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”',
  'copy': '©', 'shy': '',
};

String decodeEntities(String s) => s.replaceAllMapped(
      RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'),
      (m) {
        final e = m.group(1)!;
        if (e.startsWith('#x') || e.startsWith('#X')) {
          final v = int.tryParse(e.substring(2), radix: 16);
          return v == null ? m.group(0)! : String.fromCharCode(v);
        }
        if (e.startsWith('#')) {
          final v = int.tryParse(e.substring(1));
          return v == null ? m.group(0)! : String.fromCharCode(v);
        }
        return _named[e.toLowerCase()] ?? m.group(0)!;
      },
    );

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

String _textWithoutSvg(XmlElement node) {
  final buf = StringBuffer();
  void walk(XmlNode n) {
    for (final c in n.children) {
      if (c is XmlText) {
        buf.write(c.value);
      } else if (c is XmlElement) {
        final name = c.localName.toLowerCase();
        if (name == 'svg' || _skipTags.contains(name)) continue;
        walk(c);
      } else if (c is XmlCDATA) {
        buf.write(c.value);
      }
    }
  }

  walk(node);
  return buf.toString();
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
