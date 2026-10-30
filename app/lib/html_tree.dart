import 'package:tomevoice_document/tomevoice_document.dart' show decodeEntities;

/// A web page as a tree, read the forgiving way a browser reads it.
///
/// Pages on the web are rarely the XML the documents package parses:
/// paragraphs left open, `<br>` and `<img>` never closed, bare attributes,
/// end tags for elements that were never opened. This builds a plain tree
/// the way a browser would in the cases that matter for reading (the
/// implied ends of p, li, dt, dd, tr, td and option; void elements; script
/// and style kept raw) and no further: it is for finding an article in a
/// page, not for rendering one.
class HtmlNode {
  HtmlNode.element(this.tag, [Map<String, String>? attrs])
      : attrs = attrs ?? <String, String>{},
        text = '';

  HtmlNode.text(this.text)
      : tag = textTag,
        attrs = const {};

  HtmlNode.document()
      : tag = documentTag,
        attrs = const {},
        text = '';

  static const textTag = '#text';
  static const documentTag = '#document';

  /// The element's name in lower case; [textTag] for text.
  final String tag;
  final Map<String, String> attrs;

  /// A text node's text, entities decoded.
  String text;
  HtmlNode? parent;
  final children = <HtmlNode>[];

  bool get isText => tag == textTag;
  bool get isElement => tag != textTag && tag != documentTag;

  String? attr(String name) => attrs[name];

  void append(HtmlNode child) {
    child.parent = this;
    children.add(child);
  }

  /// Take this node (and all it holds) out of the tree.
  void remove() {
    parent?.children.remove(this);
    parent = null;
  }

  /// Every node below this one, in document order. Not recursive: a page
  /// of unclosed tags can nest thousands deep.
  Iterable<HtmlNode> get descendants sync* {
    final stack = <(HtmlNode, int)>[(this, 0)];
    while (stack.isNotEmpty) {
      final (node, i) = stack.removeLast();
      if (i >= node.children.length) continue;
      stack.add((node, i + 1));
      final child = node.children[i];
      yield child;
      if (child.children.isNotEmpty) stack.add((child, 0));
    }
  }

  /// The elements below this one, in document order.
  Iterable<HtmlNode> get elements => descendants.where((n) => n.isElement);

  /// All the text below this node, as written (spaces not collapsed).
  String get textContent {
    if (isText) return text;
    final out = StringBuffer();
    for (final n in descendants) {
      if (n.isText) out.write(n.text);
    }
    return out.toString();
  }

  /// Whether [other] is this node or below it.
  bool contains(HtmlNode other) {
    for (HtmlNode? n = other; n != null; n = n.parent) {
      if (identical(n, this)) return true;
    }
    return false;
  }

  @override
  String toString() => isText ? '"$text"' : '<$tag>';
}

/// Elements that never hold anything.
const voidTags = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr',
  'basefont', 'bgsound', 'frame', 'keygen',
};

/// Elements whose content is not markup: kept as one text, up to their end
/// tag. Only title and textarea decode entities in it.
const _rawTags = {'script', 'style', 'xmp', 'iframe', 'noembed', 'noframes', 'noscript', 'textarea', 'title'};

/// Start tags that end a paragraph left open.
const _closesP = {
  'address', 'article', 'aside', 'blockquote', 'center', 'details', 'dialog', 'dir', 'div', 'dl', 'fieldset',
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', 'li',
  'dd', 'dt', 'main', 'menu', 'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'ul', 'listing', 'plaintext',
};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// Where a search for an open element stops: past these it is not "in
/// scope" (an outer paragraph is not ended from inside a table cell).
const _scope = {'html', 'table', 'td', 'th', 'caption', 'marquee', 'object', 'template', 'applet', 'button'};
const _listScope = {..._scope, 'ol', 'ul'};
const _dlScope = {..._scope, 'dl'};
const _rowScope = {'tr', 'table', 'tbody', 'thead', 'tfoot', 'html', 'template'};
const _tableScope = {'table', 'html', 'template'};

/// Open elements deeper than this are not nested further (a page of a
/// thousand unclosed tags stays a tree that can be walked).
const _maxDepth = 400;

final _rawEnd = {
  for (final t in _rawTags) t: RegExp('</$t[\\s/>]', caseSensitive: false),
};
final _nameEnd = RegExp(r'[\s/>]');

/// [html] as a tree under a document node.
HtmlNode parseHtml(String html) {
  final doc = HtmlNode.document();
  final stack = <HtmlNode>[doc];
  final n = html.length;

  void addText(String raw, {bool decode = true}) {
    if (raw.isEmpty) return;
    final text = decode && raw.contains('&') ? decodeEntities(raw) : raw;
    final at = stack.last;
    final last = at.children.isEmpty ? null : at.children.last;
    if (last != null && last.isText) {
      last.text += text;
    } else {
      at.append(HtmlNode.text(text));
    }
  }

  /// Ends the open [tag] if it is in scope; false when it is not.
  bool closeOpen(String tag, Set<String> boundaries) {
    for (var j = stack.length - 1; j >= 1; j--) {
      final t = stack[j].tag;
      if (t == tag) {
        stack.removeRange(j, stack.length);
        return true;
      }
      if (boundaries.contains(t)) return false;
    }
    return false;
  }

  HtmlNode open(String name, Map<String, String> attrs, bool selfClosing) {
    if (_closesP.contains(name)) closeOpen('p', _scope);
    if (name == 'li') {
      closeOpen('li', _listScope);
    } else if (name == 'dt' || name == 'dd') {
      closeOpen('dd', _dlScope);
      closeOpen('dt', _dlScope);
    } else if (name == 'tr') {
      closeOpen('tr', _tableScope);
    } else if (name == 'td' || name == 'th') {
      closeOpen('td', _rowScope);
      closeOpen('th', _rowScope);
    } else if (name == 'option') {
      closeOpen('option', _scope);
    } else if (name == 'a') {
      // Links do not nest.
      closeOpen('a', _scope);
    } else if (_headings.contains(name) && _headings.contains(stack.last.tag)) {
      stack.removeLast();
    }
    final node = HtmlNode.element(name, attrs);
    stack.last.append(node);
    if (!voidTags.contains(name) && !selfClosing && stack.length < _maxDepth) stack.add(node);
    return node;
  }

  void close(String name) {
    if (name == 'br') {
      // "</br>" is read as a line break, as browsers do.
      open('br', {}, true);
      return;
    }
    // A page's own </body> and </html> often come early; what follows them
    // is still the page.
    if (name == 'body' || name == 'html' || voidTags.contains(name)) return;
    final Set<String> boundaries;
    if (name == 'td' || name == 'th' || name == 'tr' || name == 'tbody' || name == 'thead' || name == 'tfoot') {
      boundaries = _tableScope;
    } else if (name == 'table') {
      boundaries = const {'html', 'template'};
    } else if (name == 'li') {
      boundaries = _listScope;
    } else {
      boundaries = _scope;
    }
    closeOpen(name, boundaries);
  }

  var i = 0;
  while (i < n) {
    final lt = html.indexOf('<', i);
    if (lt < 0) {
      addText(html.substring(i));
      break;
    }
    if (lt > i) addText(html.substring(i, lt));
    i = lt;
    if (html.startsWith('<!--', i)) {
      final end = html.indexOf('-->', i + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    final next = i + 1 < n ? html.codeUnitAt(i + 1) : 0;
    if (next == 0x21 || next == 0x3F) {
      // <!DOCTYPE>, <![CDATA[...]]>, <?xml ...?>
      if (html.startsWith('<![CDATA[', i)) {
        final end = html.indexOf(']]>', i + 9);
        addText(html.substring(i + 9, end < 0 ? n : end), decode: false);
        i = end < 0 ? n : end + 3;
      } else {
        final end = html.indexOf('>', i + 2);
        i = end < 0 ? n : end + 1;
      }
      continue;
    }
    if (next == 0x2F) {
      // An end tag.
      final start = i + 2;
      final stop = _indexOf(html, _nameEnd, start);
      final name = html.substring(start, stop).toLowerCase();
      final end = html.indexOf('>', start);
      i = end < 0 ? n : end + 1;
      if (name.isNotEmpty && _isLetter(name.codeUnitAt(0))) close(name);
      continue;
    }
    if (!_isLetter(next)) {
      // A "<" that starts nothing: "a < b".
      addText('<');
      i++;
      continue;
    }
    // A start tag: its name, then attributes up to ">" or "/>".
    final nameStop = _indexOf(html, _nameEnd, i + 1);
    final name = html.substring(i + 1, nameStop).toLowerCase();
    final attrs = <String, String>{};
    var j = nameStop;
    var selfClosing = false;
    while (j < n) {
      final c = html.codeUnitAt(j);
      if (c == 0x3E) {
        j++;
        break;
      }
      if (c == 0x2F) {
        if (j + 1 < n && html.codeUnitAt(j + 1) == 0x3E) {
          selfClosing = true;
          j += 2;
          break;
        }
        j++;
        continue;
      }
      if (_isSpace(c)) {
        j++;
        continue;
      }
      // An attribute: its name, and maybe "=" and a value.
      final aStart = j;
      while (j < n) {
        final d = html.codeUnitAt(j);
        if (_isSpace(d) || d == 0x3D || d == 0x3E || (d == 0x2F && j > aStart)) break;
        j++;
      }
      final aName = html.substring(aStart, j).toLowerCase();
      while (j < n && _isSpace(html.codeUnitAt(j))) {
        j++;
      }
      var value = '';
      if (j < n && html.codeUnitAt(j) == 0x3D) {
        j++;
        while (j < n && _isSpace(html.codeUnitAt(j))) {
          j++;
        }
        if (j < n && (html.codeUnitAt(j) == 0x22 || html.codeUnitAt(j) == 0x27)) {
          final quote = html[j];
          final close = html.indexOf(quote, j + 1);
          final end = close < 0 ? n : close;
          value = html.substring(j + 1, end);
          j = close < 0 ? n : close + 1;
        } else {
          final vStart = j;
          while (j < n && !_isSpace(html.codeUnitAt(j)) && html.codeUnitAt(j) != 0x3E) {
            j++;
          }
          value = html.substring(vStart, j);
        }
      }
      // The first of two attributes with one name counts, as in browsers.
      if (aName.isNotEmpty) attrs.putIfAbsent(aName, () => value.contains('&') ? decodeEntities(value) : value);
    }
    i = j;
    final node = open(name, attrs, selfClosing);
    if (_rawTags.contains(name) && !selfClosing) {
      // Script, style and the like: their text runs to their end tag.
      final m = _rawEnd[name]!.allMatches(html, i).firstOrNull;
      final raw = html.substring(i, m?.start ?? n);
      final decode = (name == 'title' || name == 'textarea') && raw.contains('&');
      if (raw.isNotEmpty) node.append(HtmlNode.text(decode ? decodeEntities(raw) : raw));
      if (identical(stack.last, node)) stack.removeLast();
      if (m == null) {
        i = n;
      } else {
        final gt = html.indexOf('>', m.start);
        i = gt < 0 ? n : gt + 1;
      }
    }
  }
  return doc;
}

int _indexOf(String s, RegExp pattern, int start) {
  final m = pattern.allMatches(s, start).firstOrNull;
  return m?.start ?? s.length;
}

bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x0C;
