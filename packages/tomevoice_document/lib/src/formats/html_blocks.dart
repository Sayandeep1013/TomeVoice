import 'package:xml/xml.dart';

import '../build.dart';
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

const _skipTags = {'script', 'style', 'svg', 'head', 'noscript'};

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
      final text = collapseWhitespace(_stripTags(html));
      if (text.isEmpty) return const [];
      return [
        makeBlock(
          role: BlockRole.paragraph,
          text: text,
          language: language,
          anchor: OffsetAnchor(0, text.length),
        ),
      ];
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

  if (name == 'img') {
    final alt = (node.getAttribute('alt') ?? '').trim();
    if (alt.isNotEmpty) {
      out.add(makeBlock(
        role: BlockRole.figure,
        text: alt,
        language: language,
        anchor: EpubAnchor(_cfi(href, name, out.length)),
      ));
    }
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
    final text = collapseWhitespace(node.innerText);
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
