import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tomevoice_document/tomevoice_document.dart' show LegacyEncodingException, countWords, decodeBytes;

import 'html_tree.dart';
import 'sources/net.dart' show Net, friendlyError;

/// A web page's article, made into a book of its own: an HTML document the
/// documents package reads like any HTML book, so notes, captions and the
/// way links and citations are spoken all work as they do in a book.
class Article {
  const Article({
    required this.title,
    required this.site,
    required this.url,
    required this.html,
    required this.text,
    this.byline,
    this.published,
  });

  final String title;

  /// Who wrote it ("Jane Doe"), when the page says.
  final String? byline;

  /// The site's own name ("The Guardian"), or its address ("example.com").
  final String site;

  /// The day it came out, as the page wrote it (2026-03-03).
  final ({int year, int month, int day})? published;

  /// The page it was read from, after any redirects.
  final Uri url;

  /// The whole document: the title as its heading, the byline, where and
  /// when (shown, not read), then the article's headings, paragraphs,
  /// lists, quotes and captioned figures.
  final String html;

  /// The article's words, a paragraph a line.
  final String text;

  int get words => countWords(text);

  /// "From The Guardian · 3 March 2026", and the address below it: what the
  /// book's page shows of where the article came from.
  String get description => '$dateline\n$url';

  /// "From The Guardian · 3 March 2026".
  String get dateline => _dateline(site, published);
}

/// Why a link could not be read, in words for the reader. With [browse],
/// the page is worth opening in the browser instead.
class ArticleProblem implements Exception {
  const ArticleProblem(this.message, {this.browse = false});

  final String message;
  final bool browse;

  @override
  String toString() => message;
}

const browserCheckMessage = 'This site wants a browser check; open it in your browser instead.';
const _empty = ArticleProblem('There is no article on that page to read.');
const _signIn = ArticleProblem(
  'That page asks you to sign in first, so there is nothing on it to read. Open it in your browser instead.',
  browse: true,
);

/// "3 March 2026".
String dateLabel(({int year, int month, int day}) d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Fewer words than this is not an article (a menu, a page drawn by script).
const _minWords = 30;

// --------------------------------------------------------------- extraction

/// The article in [page], the HTML of [url], picked out the way reader
/// views do: what is never the article goes (navigation, headers and
/// footers, sidebars, scripts, forms, comments, and blocks whose class or
/// id says share, related, subscribe, promo or cookie), the block with the
/// most paragraph text is the article, and its headings, paragraphs,
/// lists, quotes and figures with captions are kept. [fallbackTitle] (what
/// the share named it) is used when the page has no title of its own.
///
/// Throws [ArticleProblem] for a browser check, a sign-in wall and a page
/// with no article on it.
Article extractArticle(String page, {required Uri url, String? fallbackTitle}) {
  final doc = parseHtml(page);
  if (_isBrowserCheck(doc, page)) throw const ArticleProblem(browserCheckMessage, browse: true);
  final meta = _Meta.read(doc, url, fallbackTitle);
  final signIn = _signInPage(doc, url);
  final pageText = _visibleText(doc);

  _prune(doc, (e) => _never.contains(e.tag));
  // The block with the most paragraph text, found before anything else
  // goes: whatever holds it is kept, whatever it is called.
  final densest = _Scores(doc).best;
  _prune(doc, (e) => _isJunk(e) && (densest == null || !e.contains(densest)));
  final scores = _Scores(doc);
  final root = scores.content(doc);
  _tidy(root, meta, keep: scores.best);
  final text = _plainText(root);

  final words = countWords(text);
  if ((signIn.byAddress && words < 300) ||
      (signIn.byPassword && words < 60) ||
      (words < 150 && _paywall.hasMatch(pageText))) {
    throw _signIn;
  }
  if (words < _minWords) throw _empty;

  return Article(
    title: meta.title,
    byline: meta.byline,
    site: meta.site,
    published: meta.published,
    url: url,
    text: text,
    html: _document(meta.title, meta.byline, _dateline(meta.site, meta.published), _xhtml(root, url)),
  );
}

String _dateline(String site, ({int year, int month, int day})? published) =>
    ['From $site', if (published != null) dateLabel(published)].join(' · ');

/// Never part of an article: code, styles, forms' controls, media and
/// frames, and pictures (a book made from a page keeps its words only).
const _never = {
  'script', 'style', 'noscript', 'template', 'link', 'meta', 'head', 'title', 'base', 'iframe', 'frame',
  'frameset', 'object', 'embed', 'applet', 'param', 'canvas', 'svg', 'math', 'video', 'audio', 'source', 'track',
  'map', 'area', 'img', 'picture', 'button', 'input', 'select', 'option', 'optgroup', 'datalist', 'textarea',
  'label', 'output', 'progress', 'meter',
};

/// Never the article, whatever they hold (unless they hold the article).
const _junkTags = {'nav', 'header', 'footer', 'aside', 'form', 'menu', 'dialog'};

const _junkRoles = {
  'navigation', 'banner', 'contentinfo', 'complementary', 'search', 'dialog', 'alertdialog', 'menu', 'menubar',
  'toolbar', 'tablist',
};

/// Words in a class or an id that say a block is not the article.
const _junkWords = {
  'ad', 'ads', 'adslot', 'adunit', 'advert', 'adverts', 'advertisement', 'advertising', 'dfp', 'sponsor',
  'sponsored', 'banner', 'promo', 'promos', 'promoted', 'promotion', 'share', 'shares', 'sharing', 'social',
  'related', 'recommended', 'recommendations', 'recirc', 'trending', 'popular', 'outbrain', 'taboola',
  'subscribe', 'subscription', 'subscriptions', 'newsletter', 'newsletters', 'signup', 'cookie', 'cookies',
  'consent', 'gdpr', 'comment', 'comments', 'commentlist', 'disqus', 'respond', 'replies', 'nav', 'navbar',
  'navigation', 'navbox', 'menu', 'breadcrumb', 'breadcrumbs', 'pagination', 'pager', 'sidebar', 'masthead',
  'header', 'footer', 'toolbar', 'widget', 'widgets', 'popup', 'modal', 'skip', 'editsection',
};

/// The same, run together with another word ("sharebar", "relatedposts").
const _junkStarts = [
  'share', 'social', 'related', 'sponsor', 'advert', 'newsletter', 'subscri', 'cookie', 'breadcrumb', 'sidebar',
  'outbrain', 'taboola', 'recommend', 'promo',
];

/// Words that say a block is the article.
const _goodWords = {
  'article', 'articlebody', 'body', 'content', 'entry', 'main', 'post', 'story', 'text', 'prose', 'blog',
  'hentry', 'markdown', 'storycontent', 'postbody', 'richtext',
};

final _nameWordsCache = Expando<List<String>>();

/// The words of [e]'s class and id: "shareBar c-related-2" is share, bar,
/// c, related.
List<String> _nameWords(HtmlNode e) => _nameWordsCache[e] ??= () {
      final raw = '${e.attr('class') ?? ''} ${e.attr('id') ?? ''}';
      if (raw.trim().isEmpty) return const <String>[];
      final spaced = raw.replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
      return [
        for (final w in spaced.toLowerCase().split(RegExp('[^a-z]+')))
          if (w.isNotEmpty) w,
      ];
    }();

bool _isJunkWord(String w) => _junkWords.contains(w) || (w.length > 5 && _junkStarts.any(w.startsWith));

/// Tags whose class or id can rule them out: blocks, not words in a
/// sentence (a link called "related-link" inside a paragraph stays).
const _namedBlocks = {
  'div', 'section', 'aside', 'ul', 'ol', 'li', 'dl', 'footer', 'header', 'nav', 'form', 'table', 'p', 'figure',
  'article', 'center', 'details',
};

/// Words that rule an element out whatever it is: Wikipedia's "[edit]"
/// links and what it marks as not for print.
const _junkAnywhere = {'editsection', 'noprint'};

bool _isJunk(HtmlNode e) {
  if (e.tag == 'body' || e.tag == 'html') return false;
  if (_junkTags.contains(e.tag) || _hidden(e)) return true;
  final role = e.attr('role')?.trim().toLowerCase();
  if (role != null && _junkRoles.contains(role)) return true;
  final words = _nameWords(e);
  if (words.any(_junkAnywhere.contains)) return true;
  if (!_namedBlocks.contains(e.tag) && !e.tag.contains('-')) return false;
  return words.any(_isJunkWord);
}

final _hiddenStyle = RegExp(r'display\s*:\s*none|visibility\s*:\s*hidden', caseSensitive: false);

bool _hidden(HtmlNode e) =>
    e.attrs.containsKey('hidden') ||
    e.attr('aria-hidden')?.trim().toLowerCase() == 'true' ||
    _hiddenStyle.hasMatch(e.attr('style') ?? '');

/// Take out every element under [root] that [drop] says, with all it holds.
void _prune(HtmlNode root, bool Function(HtmlNode e) drop) {
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    for (final child in [...node.children]) {
      if (!child.isElement) continue;
      if (drop(child)) {
        child.remove();
      } else {
        stack.add(child);
      }
    }
  }
}

/// Elements that start a block of their own.
const _blockTags = {
  'p', 'div', 'section', 'article', 'aside', 'header', 'footer', 'nav', 'main', 'ul', 'ol', 'dl', 'li', 'dt', 'dd',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'caption', 'blockquote', 'pre', 'h1', 'h2', 'h3', 'h4',
  'h5', 'h6', 'figure', 'figcaption', 'form', 'fieldset', 'hr', 'address', 'details', 'summary', 'hgroup',
  'center', 'menu',
};

const _headingTags = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// Characters a reader sees in [s]: runs of spaces count once, and text that
/// is only spaces (between tags) not at all.
int _visible(String s) {
  var n = 0;
  var space = true;
  var any = false;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x0C || c == 0xA0) {
      if (!space) n++;
      space = true;
    } else {
      n++;
      space = false;
      any = true;
    }
  }
  return any ? n : 0;
}

/// How much text each element holds, how much of it is links, and whether
/// it holds blocks, counted once for the whole tree.
class _Stats {
  _Stats(HtmlNode root) {
    final order = <HtmlNode>[];
    final stack = [root];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      order.add(n);
      stack.addAll(n.children);
    }
    // Children come after their parents in [order]: backwards, every
    // child is counted before its parent.
    for (final n in order.reversed) {
      if (n.isText) {
        text[n] = _visible(n.text);
        continue;
      }
      var t = 0;
      var l = 0;
      var b = false;
      for (final c in n.children) {
        t += text[c] ?? 0;
        l += links[c] ?? 0;
        if (c.isElement && _blockTags.contains(c.tag)) b = true;
      }
      if (n.tag == 'a' && n.attrs.containsKey('href')) l = t;
      text[n] = t;
      links[n] = l;
      blocks[n] = b;
    }
  }

  final text = <HtmlNode, int>{};
  final links = <HtmlNode, int>{};
  final blocks = <HtmlNode, bool>{};

  double linkDensity(HtmlNode e) {
    final t = text[e] ?? 0;
    return t == 0 ? 0 : (links[e] ?? 0) / t;
  }

  /// [e] is about to go: what it held no longer counts for what holds it.
  void subtract(HtmlNode e) {
    final t = text[e] ?? 0;
    final l = links[e] ?? 0;
    for (var p = e.parent; p != null; p = p.parent) {
      text[p] = (text[p] ?? 0) - t;
      links[p] = (links[p] ?? 0) - l;
    }
  }

  /// A paragraph, or what a page uses as one: a block holding only text.
  bool isParagraph(HtmlNode e) =>
      e.tag == 'p' ||
      e.tag == 'pre' ||
      (const {'div', 'section', 'article', 'td', 'blockquote', 'center'}.contains(e.tag) && blocks[e] == false);
}

/// Each block scored by the paragraph text it holds: a paragraph counts in
/// full for the block it is in, half for the one around that, a quarter for
/// the next. Class and id names and links weigh in.
class _Scores {
  _Scores(HtmlNode root) : stats = _Stats(root) {
    for (final e in root.elements) {
      if (!stats.isParagraph(e)) continue;
      final len = stats.text[e] ?? 0;
      if (len < 25 || stats.linkDensity(e) > 0.5) continue;
      paragraphs.add(e);
      var node = e.parent;
      var w = 1.0;
      for (var d = 0; d < 3 && node != null && node.isElement; d++) {
        raw[node] = (raw[node] ?? 0) + w * len;
        w /= 2;
        node = node.parent;
      }
    }
    var top = 0.0;
    for (final MapEntry(key: e, value: s) in raw.entries) {
      final f = s * _nameFactor(e) * (1 - stats.linkDensity(e));
      if (f > top) {
        top = f;
        best = e;
      }
    }
  }

  final _Stats stats;
  final raw = <HtmlNode, double>{};
  final paragraphs = <HtmlNode>[];

  /// The block with the most paragraph text.
  HtmlNode? best;

  /// The article: [best], or a block above it when that gathers paragraphs
  /// from beside it too (an article split into several blocks, with
  /// headings between). The page's body when it has no paragraphs.
  HtmlNode content(HtmlNode doc) {
    final start = best;
    if (start == null) return doc.elements.where((e) => e.tag == 'body').firstOrNull ?? doc;
    var top = start;
    final mass = raw[start] ?? 0;
    while (true) {
      final up = top.parent;
      if (up == null || !up.isElement || up.tag == 'html') break;
      var other = 0.0;
      for (final p in paragraphs) {
        if (top.contains(p)) continue;
        final d = _depthBelow(up, p);
        if (d > 0 && d <= 3) other += (stats.text[p] ?? 0) / (1 << (d - 1));
      }
      if (other < mass / 4) break;
      top = up;
    }
    return top;
  }
}

/// How many levels below [ancestor] [node] is: 1 for a child, 0 when it is
/// not below it at all.
int _depthBelow(HtmlNode ancestor, HtmlNode node) {
  var d = 0;
  for (HtmlNode? n = node; n != null; n = n.parent) {
    if (identical(n, ancestor)) return d;
    d++;
  }
  return 0;
}

double _nameFactor(HtmlNode e) {
  var f = 1.0;
  if (_isJunk(e)) f *= 0.2;
  if (_nameWords(e).any(_goodWords.contains)) f *= 1.3;
  if (e.tag == 'article' || (e.attr('itemprop') ?? '').contains('articleBody')) f *= 1.3;
  if (e.tag == 'main' || e.attr('role') == 'main') f *= 1.1;
  return f;
}

/// Lines that are site furniture wherever they stand.
final _boilerplate = RegExp(
  r'^(advertisement|advert|sponsored|continue reading( below)?|story continues( below)?( advertisement)?|'
  r'read more|related( articles| stories| posts)?|share( this)?( article| story| post)?|'
  r'sign up( for)?.{0,40}newsletter.*|subscribe( now| today)?|follow us( on)?.{0,40}|'
  r'this article is more than \d+ (years?|months?) old)[.:!]?$',
  caseSensitive: false,
);

/// Words in a class or id that mark a line of who and when.
const _creditWords = {
  'byline', 'author', 'authors', 'dateline', 'date', 'time', 'timestamp', 'published', 'updated', 'pubdate',
  'meta', 'credit', 'credits', 'readtime', 'reading',
};

/// Inside the article: what was missed as junk, the title and the byline
/// again (they head the book), links and lists of links, lines of who and
/// when, furniture ("Advertisement"), bits too short to be text, figures
/// with no caption, and headings left with nothing under them. [keep] (the
/// block with the most paragraph text) and what holds it always stay.
void _tidy(HtmlNode root, _Meta meta, {HtmlNode? keep}) {
  bool kept(HtmlNode e) => keep != null && e.contains(keep);
  _prune(root, (e) => _isJunk(e) && !kept(e));

  // The title, as one of the first headings; or the page's own headline in
  // other words, an h1 before any paragraph.
  final title = _norm(meta.title);
  final opening = root.elements.where((e) => e.tag == 'h1' || e.tag == 'p').firstOrNull;
  if (opening != null && opening.tag == 'h1' && !kept(opening)) {
    opening.remove();
  } else {
    for (final h in root.elements.where((e) => _headingTags.contains(e.tag)).take(3).toList()) {
      final t = _norm(h.textContent);
      if (t.isEmpty || title.isEmpty) continue;
      final close = math.min(t.length, title.length) >= 0.6 * math.max(t.length, title.length);
      if (t == title || (close && (t.contains(title) || title.contains(t)))) {
        h.remove();
        break;
      }
    }
  }
  for (final b in meta.bylineNodes) {
    if (root.contains(b) && !identical(b, root) && !kept(b) && _visible(b.textContent) < 140) b.remove();
  }

  // From the innermost blocks out, so each is judged by what is left in it.
  final stats = _Stats(root);
  final byline = meta.byline == null ? null : _norm(meta.byline!);
  for (final e in root.elements.toList().reversed) {
    if (kept(e) || !_drop(e, stats, byline)) continue;
    stats.subtract(e);
    e.remove();
  }
  _dropBareHeadings(root);
}

/// Whether [e], inside the article, is not part of it (see [_tidy]).
bool _drop(HtmlNode e, _Stats stats, String? byline) {
  final len = stats.text[e] ?? 0;
  // Nothing to read or show (pictures are not kept).
  if (len == 0) return e.tag != 'br' && e.tag != 'hr';
  if (_headingTags.contains(e.tag)) return false;
  if (len < 200) {
    final raw = _clean(e.textContent);
    if (_boilerplate.hasMatch(raw)) return true;
    // A count or a symbol on its own ("1.2K", "·"): no word in it.
    if (len < 25 && (e.tag == 'p' || _wrappers.contains(e.tag)) && !_word.hasMatch(raw)) return true;
    if (len < 120 && (_isByline(raw) || (byline != null && _norm(raw) == byline))) return true;
    if (len < 120 && _nameWords(e).any(_creditWords.contains) && !_holdsProse(e)) return true;
  }
  if (stats.linkDensity(e) > 0.5 && _linkBlocks.contains(e.tag)) return true;
  if (e.tag == 'figure' && !e.elements.any((d) => d.tag == 'figcaption')) return true;
  // A table of data (an infobox) is not read; one laid out to hold the
  // page's text is read for its text.
  if (e.tag == 'table' && !_holdsText(e)) return true;
  return len < 25 && _wrappers.contains(e.tag) && !e.elements.any((d) => _textBlocks.contains(d.tag));
}

final _word = RegExp(r'\p{L}{2,}', unicode: true);

/// Blocks that are taken out when they are mostly links.
const _linkBlocks = {'ul', 'ol', 'dl', 'li', 'div', 'section', 'p', 'table', 'figure', 'nav'};

/// Blocks that only wrap: too little in one ("5 min read", "Share") is not
/// text.
const _wrappers = {'div', 'section', 'ul', 'ol', 'dl', 'details'};

/// "By Jane Doe", "Written by Jane Doe and John Roe": a byline, not a
/// sentence that starts with "By".
bool _isByline(String raw) {
  final m = RegExp(r'^(by|written by|posted by|words by|text by)\s+(\S)', caseSensitive: false).firstMatch(raw);
  if (m == null) return false;
  final first = m[2]!;
  if (first.toUpperCase() != first || first.toLowerCase() == first) return false;
  final words = countWords(raw);
  return words <= 5 || (words <= 12 && !RegExp(r'[.!?]$').hasMatch(raw));
}

/// Blocks that are text in their own right, even short.
const _textBlocks = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'pre', 'figcaption', 'dd', 'dt'};

/// Whether table [t] was laid out to hold text: paragraphs, or a long cell.
bool _holdsText(HtmlNode t) => t.elements.any(
      (d) => d.tag == 'p' || ((d.tag == 'td' || d.tag == 'th') && _visible(d.textContent) > 200),
    );

/// Whether [e] holds a sentence or two, not just a name and a date.
bool _holdsProse(HtmlNode e) => e.elements.any((d) => d.tag == 'p') || countWords(e.textContent) > 20;

/// Lower case, letters and digits only: for telling a line from the title.
String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// Headings with no text after them before the next heading as high (a
/// "Related" heading whose links went).
void _dropBareHeadings(HtmlNode root) {
  final items = <HtmlNode>[];
  for (final e in root.elements) {
    if (_headingTags.contains(e.tag)) {
      items.add(e);
    } else if (_hasOwnText(e)) {
      items.add(e);
    }
  }
  for (var i = 0; i < items.length; i++) {
    final h = items[i];
    if (!_headingTags.contains(h.tag)) continue;
    final level = int.parse(h.tag.substring(1));
    var said = false;
    for (var j = i + 1; j < items.length; j++) {
      final next = items[j];
      if (_headingTags.contains(next.tag)) {
        if (int.parse(next.tag.substring(1)) <= level) break;
        continue;
      }
      if (!h.contains(next)) {
        said = true;
        break;
      }
    }
    if (!said) h.remove();
  }
}

/// Whether [e] has words of its own, not only inside other blocks.
bool _hasOwnText(HtmlNode e) {
  if (_headingTags.contains(e.tag)) return false;
  for (final c in e.children) {
    if (c.isText && c.text.trim().isNotEmpty) return true;
    if (c.isElement && !_blockTags.contains(c.tag) && c.textContent.trim().isNotEmpty) return true;
  }
  return false;
}

// ------------------------------------------------------------------ details

/// The page's title, byline, site and date, from its head (Open Graph,
/// meta tags, schema.org data) and, failing that, its body.
class _Meta {
  _Meta._(this.title, this.byline, this.site, this.published, this.bylineNodes);

  final String title;
  final String? byline;
  final String site;
  final ({int year, int month, int day})? published;

  /// The elements the byline was found in, to leave out of the article.
  final List<HtmlNode> bylineNodes;

  static _Meta read(HtmlNode doc, Uri url, String? fallbackTitle) {
    final metas = <String, String>{};
    String? pageTitle;
    String? firstH1;
    final ld = <Map<String, Object?>>[];
    final bylineNodes = <HtmlNode>[];
    String? domByline;
    String? timeAttr;
    for (final e in doc.elements) {
      switch (e.tag) {
        case 'meta':
          final key = (e.attr('property') ?? e.attr('name') ?? e.attr('itemprop') ?? '').trim().toLowerCase();
          final content = e.attr('content')?.trim();
          if (key.isNotEmpty && content != null && content.isNotEmpty) metas.putIfAbsent(key, () => content);
        case 'title':
          pageTitle ??= _clean(e.textContent);
        case 'h1':
          firstH1 ??= _clean(e.textContent);
        case 'script':
          if ((e.attr('type') ?? '').toLowerCase().contains('ld+json')) ld.addAll(_linkedData(e.textContent));
        case 'time':
          timeAttr ??= e.attr('datetime');
      }
      // Who wrote it, from the body: a rel=author link, schema.org's
      // author, or a block called byline or author.
      if (domByline == null) {
        final rel = (e.attr('rel') ?? '').toLowerCase().split(' ').contains('author');
        final prop = (e.attr('itemprop') ?? '').toLowerCase().split(' ').contains('author');
        final named = const {'div', 'p', 'span', 'section', 'address'}.contains(e.tag) &&
            _nameWords(e).any((w) => w == 'byline' || w == 'author' || w == 'authors');
        if (rel || prop || named) {
          final t = _cleanByline(_clean(e.textContent));
          if (t != null) {
            domByline = t;
            // The line it stands in goes with it.
            var line = e;
            while (!_blockTags.contains(line.tag) && line.parent != null && line.parent!.isElement) {
              line = line.parent!;
            }
            bylineNodes.add(line);
          }
        }
      }
    }
    final article = ld.where((m) => _articleTypes.contains(_ldType(m))).firstOrNull ?? const <String, Object?>{};

    final host = url.host.toLowerCase().startsWith('www.') ? url.host.substring(4) : url.host;
    final site = _firstText([
      metas['og:site_name'],
      _ldName(article['publisher']),
      metas['application-name'],
    ]) ?? host;

    // The first that is more than the site's name (some sites give every
    // page their own name as og:title).
    var title = host;
    for (final option in [
      metas['og:title'],
      metas['twitter:title'],
      article['headline'] is String ? article['headline'] as String : null,
      pageTitle,
      firstH1,
      fallbackTitle,
    ]) {
      final t = _withoutSite(_clean(option ?? ''), site, host);
      if (t.isNotEmpty && _norm(t) != _norm(site) && _norm(t) != _norm(host)) {
        title = t;
        break;
      }
    }
    if (title.length > 200) title = '${title.substring(0, 199).trimRight()}…';

    final byline = _cleanByline(_ldAuthors(article['author'])) ??
        _cleanByline(_notAddress(metas['author'])) ??
        _cleanByline(_notAddress(metas['article:author'])) ??
        _cleanByline(metas['parsely-author'] ?? metas['sailthru.author']) ??
        _cleanByline(metas['byl']) ??
        domByline;

    final date = _dayOf(article['datePublished'] is String ? article['datePublished'] as String : null) ??
        _dayOf(metas['article:published_time']) ??
        _dayOf(metas['datepublished']) ??
        _dayOf(metas['date']) ??
        _dayOf(metas['dc.date']) ??
        _dayOf(metas['dc.date.issued']) ??
        _dayOf(metas['pubdate']) ??
        _dayOf(metas['publish-date']) ??
        _dayOf(metas['parsely-pub-date']) ??
        _dayOf(timeAttr);

    return _Meta._(
      title,
      byline == null || _norm(byline) == _norm(site) ? null : byline,
      site,
      date,
      bylineNodes,
    );
  }
}

const _articleTypes = {
  'article', 'newsarticle', 'blogposting', 'reportagenewsarticle', 'analysisnewsarticle', 'opinionnewsarticle',
  'backgroundnewsarticle', 'reviewnewsarticle', 'scholarlyarticle', 'techarticle', 'report', 'socialmediaposting',
  'liveblogposting', 'posting',
};

String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String? _firstText(List<String?> options) {
  for (final o in options) {
    final t = o == null ? '' : _clean(o);
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// "Why the sky is blue | The Science Site" without " | The Science Site".
String _withoutSite(String title, String site, String host) {
  final parts = title.split(RegExp(r'\s+[|\-–—·:•»]\s+'));
  if (parts.length < 2) return title;
  final names = {
    _norm(site),
    _norm(host),
    // "Wikipedia" for en.wikipedia.org, "Example" for example.com.
    for (final label in host.split('.'))
      if (label.length > 3) _norm(label),
  };
  bool isSite(String p) => names.contains(_norm(p));
  if (isSite(parts.last)) return title.substring(0, title.length - parts.last.length).replaceAll(RegExp(r'\s+[|\-–—·:•»]\s*$'), '').trim();
  if (isSite(parts.first)) return title.substring(parts.first.length).replaceFirst(RegExp(r'^\s*[|\-–—·:•»]\s+'), '').trim();
  return title;
}

String? _notAddress(String? s) => s == null || s.contains('://') || s.startsWith('www.') ? null : s;

/// "By Jane Doe | 3 March" as "Jane Doe"; null for what is no name.
String? _cleanByline(String? s) {
  if (s == null) return null;
  var t = _clean(s).replaceFirst(RegExp(r'^(by|written by|posted by|words by|text by|author:?)\s+', caseSensitive: false), '');
  t = t.split(RegExp(r'\s+[|·•—]\s+|\s+-\s+|\n')).first.trim();
  t = t.replaceAll(RegExp(r'[,;:]+$'), '').trim();
  if (t.isEmpty || t.length > 100 || t.contains('://') || !RegExp(r'\p{L}', unicode: true).hasMatch(t)) return null;
  return t;
}

/// The day at the start of an ISO 8601 date ("2026-03-03T10:00:00Z"), as
/// the site wrote it (not moved to another time zone).
({int year, int month, int day})? _dayOf(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^\s*(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m == null) return null;
  final year = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[3]!);
  if (year < 1900 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  return (year: year, month: month, day: day);
}

/// The objects in a JSON-LD block, its @graph opened out.
List<Map<String, Object?>> _linkedData(String json) {
  Object? data;
  try {
    data = jsonDecode(json.trim());
  } on FormatException {
    return const [];
  }
  final out = <Map<String, Object?>>[];
  void add(Object? v) {
    if (v is List) {
      for (final x in v) {
        add(x);
      }
    } else if (v is Map) {
      final m = Map<String, Object?>.from(v);
      out.add(m);
      if (m['@graph'] != null) add(m['@graph']);
    }
  }

  add(data);
  return out;
}

String _ldType(Map<String, Object?> m) {
  final t = m['@type'];
  final first = t is List ? (t.isEmpty ? null : t.first) : t;
  return first is String ? first.toLowerCase() : '';
}

String? _ldName(Object? v) {
  if (v is String) return v;
  if (v is Map) return v['name'] is String ? v['name'] as String : null;
  if (v is List && v.isNotEmpty) return _ldName(v.first);
  return null;
}

/// "Jane Doe", "Jane Doe and John Roe", "Jane Doe, John Roe and Ann Poe".
String? _ldAuthors(Object? v) {
  final names = [
    for (final a in v is List ? v : [v])
      if (_ldName(a) case final n? when _notAddress(n) != null && _clean(n).isNotEmpty) _clean(n),
  ].take(3).toList();
  if (names.isEmpty) return null;
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

// ------------------------------------------------------------ walls, checks

final _challengeMarks = RegExp(
  r'<title>\s*(just a moment|attention required|checking your browser|please wait|ddos-guard)|'
  r'cf-browser-verification|/cdn-cgi/challenge-platform/|_cf_chl_opt|cf-turnstile|captcha-delivery\.com|'
  r'px-captcha',
  caseSensitive: false,
);

/// A bot check (Cloudflare's "Just a moment…", DataDome, PerimeterX)
/// instead of the page.
bool _isBrowserCheck(HtmlNode doc, String page) =>
    _challengeMarks.hasMatch(page.length > 200000 ? page.substring(0, 200000) : page) &&
    countWords(_visibleText(doc)) < 300;

/// Whether a response is a bot check, by its status, headers and the start
/// of its body.
bool isBrowserCheckResponse(int status, Map<String, String> headers, String head) =>
    headers['cf-mitigated'] == 'challenge' || (const {403, 429, 503}.contains(status) && _challengeMarks.hasMatch(head));

final _paywall = RegExp(
  r'\b((sign|log) ?in|register) to (continue|keep reading|read|view|access)|'
  r'subscribe to (continue|keep reading|read)|already a (subscriber|member)\?|'
  r'create a (free )?account to (continue|read|keep reading)|'
  r'this (article|content|story|post) is (only )?(available|for) (to )?(subscribers|members|paid)',
  caseSensitive: false,
);

/// Whether the page is a sign-in page: by its address, or by a password
/// box on it.
({bool byAddress, bool byPassword}) _signInPage(HtmlNode doc, Uri url) {
  final path = url.path.toLowerCase();
  final host = url.host.toLowerCase();
  final byAddress =
      RegExp(r'(^|/)(log-?in|sign-?in|signin|auth|sso|session/new|accounts?/log-?in)(/|$|\.)').hasMatch(path) ||
          RegExp(r'^(login|accounts|auth|signin|sso)\.').hasMatch(host);
  final byPassword = doc.elements.any((e) => e.tag == 'input' && (e.attr('type') ?? '').toLowerCase() == 'password');
  return (byAddress: byAddress, byPassword: byPassword);
}

/// The page's words outside scripts and styles, spaces collapsed.
String _visibleText(HtmlNode doc) {
  final out = StringBuffer();
  final stack = [doc];
  while (stack.isNotEmpty) {
    final n = stack.removeLast();
    if (n.isText) {
      out
        ..write(n.text)
        ..write(' ');
      continue;
    }
    if (const {'script', 'style', 'noscript', 'template', 'head'}.contains(n.tag)) continue;
    stack.addAll(n.children.reversed);
  }
  return _clean(out.toString());
}

// ------------------------------------------------------------------ writing

/// Blocks kept as they are.
const _keptBlocks = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'blockquote', 'pre', 'figure',
  'figcaption', 'hr', 'div', 'br',
};

/// Words kept as they are.
const _keptInline = {
  'a', 'abbr', 'b', 'bdi', 'bdo', 'cite', 'code', 'dfn', 'em', 'i', 'kbd', 'mark', 'q', 's', 'samp', 'small',
  'span', 'strong', 'sub', 'sup', 'time', 'u', 'var', 'del', 'ins',
};

/// Kept under another name.
const _renamed = {
  'section': 'div', 'article': 'div', 'main': 'div', 'center': 'div', 'address': 'div', 'details': 'div',
  'summary': 'div', 'hgroup': 'div', 'header': 'div', 'footer': 'div', 'font': 'span', 'big': 'span',
  'tt': 'code', 'strike': 's', 'acronym': 'abbr', 'nobr': 'span',
};

/// [root]'s content as XHTML: only the elements kept above, ids and
/// languages kept (notes are found by them), links kept only within the
/// page (a note's marker), everything escaped so it parses as XML.
String _xhtml(HtmlNode root, Uri url) {
  final out = StringBuffer();
  final page = url.removeFragment();

  void walk(HtmlNode n) {
    if (n.isText) {
      out.write(_escape(n.text));
      return;
    }
    if (!n.isElement) {
      n.children.forEach(walk);
      return;
    }
    var tag = n.tag;
    if (tag == 'table') {
      // Only tables laid out to hold text are left (see _drop): each cell
      // is a block of its own.
      for (final d in n.elements.where((d) => d.tag == 'td' || d.tag == 'th').toList()) {
        if (d.elements.any((x) => x.tag == 'td' || x.tag == 'th')) continue;
        out.write('<div>');
        d.children.forEach(walk);
        out.write('</div>');
      }
      return;
    }
    if (const {'tr', 'td', 'th', 'thead', 'tbody', 'tfoot', 'caption', 'colgroup', 'col'}.contains(tag)) {
      n.children.forEach(walk);
      return;
    }
    tag = _renamed[tag] ?? tag;
    if (!_keptBlocks.contains(tag) && !_keptInline.contains(tag)) {
      // Anything else (custom elements, wrappers): its content stays.
      n.children.forEach(walk);
      return;
    }
    final attrs = StringBuffer();
    final id = n.attr('id') ?? (tag == 'a' ? n.attr('name') : null);
    if (id != null && id.trim().isNotEmpty) attrs.write(' id="${_escape(id.trim(), attr: true)}"');
    final lang = n.attr('lang') ?? n.attr('xml:lang');
    if (lang != null && RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$').hasMatch(lang.trim())) {
      attrs.write(' lang="${lang.trim()}"');
    }
    final role = n.attr('role')?.trim().toLowerCase();
    if (role != null && role.startsWith('doc-')) attrs.write(' role="${_escape(role, attr: true)}"');
    final start = tag == 'ol' ? int.tryParse(n.attr('start') ?? '') : null;
    if (start != null) attrs.write(' start="$start"');
    if (tag == 'a') {
      final href = _inPage(n.attr('href'), page);
      if (href != null) attrs.write(' href="${_escape(href, attr: true)}"');
      if (href == null && (id == null || id.trim().isEmpty)) {
        // A link elsewhere is read as its words.
        n.children.forEach(walk);
        return;
      }
    }
    if (tag == 'br' || tag == 'hr') {
      out.write('<$tag$attrs/>');
      return;
    }
    if (tag == 'span' && attrs.isEmpty) {
      n.children.forEach(walk);
      return;
    }
    out.write('<$tag$attrs>');
    n.children.forEach(walk);
    out.write('</$tag>');
  }

  for (final c in root.children) {
    walk(c);
  }
  return out.toString();
}

/// [href] as a link within the page ("#cite_note-1"), or null for one that
/// leads elsewhere.
String? _inPage(String? href, Uri page) {
  if (href == null) return null;
  final h = href.trim();
  if (h.startsWith('#')) return h.length > 1 ? h : null;
  final Uri to;
  try {
    to = page.resolve(h);
  } on FormatException {
    return null;
  }
  if (!to.hasFragment || to.fragment.isEmpty) return null;
  return to.removeFragment() == page ? '#${to.fragment}' : null;
}

/// What XML cannot hold (most control characters, U+FFFE and U+FFFF), and
/// the noncharacters the documents package marks its own text with.
final _notXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]|'
    '[${String.fromCharCode(0xFDD0)}-${String.fromCharCode(0xFDD2)}'
    '${String.fromCharCode(0xFFFE)}${String.fromCharCode(0xFFFF)}]');

String _escape(String s, {bool attr = false}) {
  var t = s.replaceAll(_notXml, '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  if (attr) t = t.replaceAll('"', '&quot;');
  return t;
}

/// The article's words, a block a line.
String _plainText(HtmlNode root) {
  final out = StringBuffer();
  void walk(HtmlNode n) {
    if (n.isText) {
      out.write(n.text);
      return;
    }
    final block = _blockTags.contains(n.tag) || n.tag == 'br';
    if (block) out.write('\n');
    n.children.forEach(walk);
    if (block) out.write('\n');
  }

  walk(root);
  return [
    for (final line in out.toString().split('\n'))
      if (_clean(line).isNotEmpty) _clean(line),
  ].join('\n');
}

/// The book's file: the title as its heading, the byline (read), where
/// and when (a caption: shown on the page, not read), then the article.
String _document(String title, String? byline, String dateline, String body) {
  final out = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>\n')
    ..write('<html xmlns="http://www.w3.org/1999/xhtml">\n<head>\n<meta charset="utf-8"/>\n')
    ..write('<title>${_escape(title)}</title>\n</head>\n<body>\n')
    ..write('<h1>${_escape(title)}</h1>\n');
  if (byline != null) out.write('<p>By ${_escape(byline)}</p>\n');
  out
    ..write('<figcaption>${_escape(dateline)}</figcaption>\n')
    ..write(body)
    ..write('\n</body>\n</html>\n');
  return out.toString();
}

// ------------------------------------------------------------------ fetching

/// What a link led to.
sealed class Fetched {
  const Fetched();
}

/// A web page, as text in its own encoding.
class FetchedPage extends Fetched {
  const FetchedPage({required this.url, required this.html});

  /// Where it was, after any redirects.
  final Uri url;
  final String html;
}

/// A book file (an EPUB, a PDF…), saved in a folder of its own under the
/// incoming folder for the usual import.
class FetchedFile extends Fetched {
  const FetchedFile({required this.path, required this.name, this.mime});

  final String path;
  final String name;
  final String? mime;
}

/// Text in an East Asian legacy encoding, decoded by the platform.
typedef CharsetDecoder = Future<String> Function(Uint8List bytes, String charset);

/// Pages larger than this are not read (a page is rarely over 2 MB).
const _pageLimit = 15 * 1024 * 1024;

/// Book files larger than this are not downloaded.
const _fileLimit = 200 * 1024 * 1024;

/// Files TomeVoice imports, by extension.
const _bookExtensions = {
  'epub', 'pdf', 'mobi', 'azw', 'azw3', 'kf8', 'prc', 'pdb', 'fb2', 'docx', 'odt', 'rtf', 'txt', 'md', 'markdown',
};

/// Files TomeVoice imports, by type.
const _bookTypes = {
  'application/pdf': 'pdf',
  'application/epub+zip': 'epub',
  'application/x-mobipocket-ebook': 'mobi',
  'application/vnd.amazon.ebook': 'azw3',
  'application/x-fictionbook+xml': 'fb2',
  'application/x-fictionbook': 'fb2',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.oasis.opendocument.text': 'odt',
  'application/rtf': 'rtf',
  'text/rtf': 'rtf',
  'text/markdown': 'md',
  'text/x-markdown': 'md',
  'text/plain': 'txt',
};

/// Types a server gives any download; the file's name then says what it is.
const _anyFile = {
  'application/octet-stream', 'binary/octet-stream', 'application/zip', 'application/x-zip-compressed',
  'application/download', 'application/force-download', 'application/x-download',
};

/// Fetch [url] as the app's sources do (the phone browser's User-Agent,
/// redirects followed one by one with the cookies set along the way), and
/// say what came back: a page, or a book file saved under [incoming] (a
/// link to an EPUB or a PDF imports that book, it is not read as a page).
/// Cookies are not kept afterwards. [legacy] decodes a page in an East
/// Asian legacy encoding.
///
/// Throws [ArticleProblem] in words for the reader.
Future<Fetched> fetchLink(
  Uri url, {
  required Directory incoming,
  CharsetDecoder? legacy,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = true;
  // Cookies set along the redirects, by host: a site that sets one and
  // sends the reader on expects it back.
  final jar = <String, Map<String, String>>{};
  try {
    var uri = url.removeFragment();
    for (var hop = 0; hop < 10; hop++) {
      final req = await client.getUrl(uri).timeout(timeout);
      req.followRedirects = false;
      req.headers
        ..set(HttpHeaders.userAgentHeader, Net.userAgent)
        ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
        ..set(HttpHeaders.acceptLanguageHeader, _acceptLanguage());
      final cookie = [
        for (final MapEntry(key: host, value: values) in jar.entries)
          if (uri.host == host || uri.host.endsWith('.$host'))
            for (final MapEntry(key: k, value: v) in values.entries) '$k=$v',
      ].join('; ');
      if (cookie.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, cookie);
      final res = await req.close().timeout(timeout);
      try {
        for (final c in res.cookies) {
          final domain = (c.domain ?? uri.host).replaceFirst(RegExp(r'^\.'), '');
          (jar[domain] ??= {})[c.name] = c.value;
        }
      } on Object {
        // A cookie Dart cannot parse is one fewer to send back.
      }
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (res.isRedirect && location != null) {
        await res.drain<void>();
        uri = uri.resolve(location).removeFragment();
        continue;
      }
      return await _take(res, uri, incoming: incoming, legacy: legacy, timeout: timeout);
    }
    throw const ArticleProblem('That link went round in circles (too many redirects).');
  } on ArticleProblem {
    rethrow;
  } on Object catch (e) {
    throw ArticleProblem(friendlyError(e));
  } finally {
    client.close(force: true);
  }
}

/// The phone's language first, then English: a site in several languages
/// answers in the reader's. (Sources ask for English; an article is read
/// in whatever language it is.)
String _acceptLanguage() {
  final tag = Platform.localeName.split('.').first.replaceAll('_', '-');
  if (!RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(tag)) return 'en-US,en;q=0.9';
  final lang = tag.split('-').first.toLowerCase();
  if (lang == 'en') return 'en-US,en;q=0.9';
  return '$tag,$lang;q=0.9,en;q=0.8';
}

Future<Fetched> _take(
  HttpClientResponse res,
  Uri url, {
  required Directory incoming,
  required CharsetDecoder? legacy,
  required Duration timeout,
}) async {
  final status = res.statusCode;
  final headers = <String, String>{};
  res.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
  final type = (res.headers.contentType?.mimeType ?? '').toLowerCase();

  if (status >= 400 || headers['cf-mitigated'] == 'challenge') {
    final head = await _read(res, 64 * 1024, timeout, cut: true);
    if (isBrowserCheckResponse(status, headers, utf8.decode(head, allowMalformed: true))) {
      throw const ArticleProblem(browserCheckMessage, browse: true);
    }
    throw switch (status) {
      404 || 410 => ArticleProblem('That page was not found (error $status).'),
      401 || 403 => ArticleProblem('That site would not let TomeVoice in (error $status). Open it in your browser instead.', browse: true),
      429 => const ArticleProblem('That site is busy. Try again in a minute.'),
      _ when status >= 500 => ArticleProblem('That site had a problem (error $status). Try again later.'),
      _ => ArticleProblem('The site answered with an error ($status).'),
    };
  }
  if (status < 200 || status >= 300) {
    await res.drain<void>();
    throw ArticleProblem('The site answered with something TomeVoice cannot read ($status).');
  }

  final name = _fileName(headers['content-disposition'], url, type);
  final ext = _extension(name);
  final attachment = (headers['content-disposition'] ?? '').toLowerCase().startsWith('attachment');
  final isPage = type == 'text/html' || type == 'application/xhtml+xml';
  if (_bookTypes.containsKey(type) ||
      (_anyFile.contains(type) && _bookExtensions.contains(ext)) ||
      (!isPage && type.isEmpty && _bookExtensions.contains(ext)) ||
      (attachment && _bookExtensions.contains(ext))) {
    return _saveFile(res, incoming, name, type, timeout);
  }
  if (type.startsWith('image/')) throw const ArticleProblem('That link is a picture, not a page to read.');
  if (type.startsWith('video/')) throw const ArticleProblem('That link is a video, not a page to read.');
  if (type.startsWith('audio/')) throw const ArticleProblem('That link is a recording, not a page to read.');
  if (!isPage && type.isNotEmpty && !type.endsWith('xml')) {
    throw const ArticleProblem('That link is not a web page TomeVoice can read.');
  }
  final bytes = await _read(res, _pageLimit, timeout);
  final html = await _decode(bytes, headers['content-type'], legacy);
  return FetchedPage(url: url, html: html);
}

/// The body, up to [limit] bytes: past it the page is refused, or with
/// [cut] the rest is left unread.
Future<Uint8List> _read(HttpClientResponse res, int limit, Duration timeout, {bool cut = false}) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in res.timeout(timeout)) {
    if (out.length + chunk.length > limit) {
      if (!cut) throw const ArticleProblem('That page is too big to read.');
      out.add(chunk.sublist(0, limit - out.length));
      break;
    }
    out.add(chunk);
  }
  return out.takeBytes();
}

Future<FetchedFile> _saveFile(HttpClientResponse res, Directory incoming, String name, String type, Duration timeout) async {
  // A folder of its own, as a picked file gets (see MainActivity.copyIn).
  final slot = Directory('${incoming.path}/${_slotName()}')..createSync(recursive: true);
  final file = File('${slot.path}/$name');
  final sink = file.openWrite();
  var total = 0;
  try {
    await for (final chunk in res.timeout(timeout)) {
      total += chunk.length;
      if (total > _fileLimit) throw const ArticleProblem('That book is too big to download here.');
      sink.add(chunk);
    }
    await sink.close();
  } on Object {
    try {
      await sink.close();
    } on Object {
      // Closing a broken file changes nothing.
    }
    if (slot.existsSync()) slot.deleteSync(recursive: true);
    rethrow;
  }
  return FetchedFile(path: file.path, name: name, mime: type.isEmpty ? null : type);
}

String _slotName() {
  final r = math.Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(16).toRadixString(16)].join();
}

/// The file's name: from the server's Content-Disposition, else the
/// address, with the extension its type says when it has none.
String _fileName(String? disposition, Uri url, String type) {
  String? name;
  if (disposition != null) {
    final star = RegExp(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)", caseSensitive: false).firstMatch(disposition);
    final plain = RegExp(r'filename\s*=\s*("([^"]*)"|[^;]+)', caseSensitive: false).firstMatch(disposition);
    try {
      name = star != null ? Uri.decodeComponent(star[2]!.trim()) : (plain?[2] ?? plain?[1])?.trim();
    } on ArgumentError {
      name = plain?[2] ?? plain?[1];
    }
  }
  if (name == null || name.isEmpty) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty);
    name = segments.isEmpty ? url.host : segments.last;
  }
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (name.isEmpty) name = 'document';
  if (name.length > 120) name = name.substring(name.length - 120);
  final wanted = _bookTypes[type];
  if (wanted != null && _extension(name) != wanted && !(wanted == 'azw3' && _extension(name).startsWith('azw'))) {
    name = '$name.$wanted';
  }
  return name;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// The page's text in its own encoding: a byte order mark, then the one the
/// server names, then the page's own meta charset, then what the bytes
/// look like (see decodeBytes).
Future<String> _decode(Uint8List bytes, String? contentType, CharsetDecoder? legacy) async {
  final declared = contentType == null
      ? null
      : RegExp(r'charset\s*=\s*"?([^";\s]+)', caseSensitive: false).firstMatch(contentType)?.group(1);
  try {
    return decodeBytes(bytes, declared: declared, markup: true);
  } on LegacyEncodingException catch (e) {
    if (legacy == null) throw ArticleProblem(e.message);
    try {
      return await legacy(bytes, e.charset);
    } on Object {
      throw ArticleProblem(e.message);
    }
  }
}
