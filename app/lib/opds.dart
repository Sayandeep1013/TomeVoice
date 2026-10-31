import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

// OPDS 1.2 catalogues: Atom feeds of books (acquisition feeds) and of other
// feeds (navigation feeds), searched through OpenSearch. Project Gutenberg,
// Standard Ebooks and a Calibre content server all speak it. See
// https://specs.opds.io/opds-1.2.

/// A link in a feed or an entry, its address already made whole.
class OpdsLink {
  const OpdsLink({required this.href, this.rel = '', this.type = '', this.title, this.length});

  final Uri href;
  final String rel;
  final String type;
  final String? title;

  /// Bytes, when the feed says (an enclosure's length).
  final int? length;

  /// Another feed of the catalogue (OPDS's own type, or plain Atom).
  bool get isFeed => type.contains('application/atom+xml') || type.contains('opds-catalog');

  /// A book file to take: an acquisition that needs no payment or loan, or
  /// an Atom enclosure (Standard Ebooks' free feed), in a format TomeVoice
  /// opens.
  bool get isDownload =>
      formatOf(type, href) != null &&
      (rel == 'enclosure' || rel == _acquisition || rel == '$_acquisition/open-access');

  static const _acquisition = 'http://opds-spec.org/acquisition';
}

/// A format TomeVoice imports: its label, the extension its file gets, and
/// how much it is preferred (EPUB first).
typedef BookFormat = ({String label, String extension, int rank});

/// What [type] (or, for Kindle files, [href]) is as a book TomeVoice opens;
/// null for anything else (a web page, a comic, an audiobook).
BookFormat? formatOf(String type, Uri href) {
  final t = type.split(';').first.trim().toLowerCase();
  final path = href.path.toLowerCase();
  return switch (t) {
    'application/epub+zip' => (label: 'EPUB', extension: '.epub', rank: 0),
    'application/kepub+zip' => (label: 'Kobo EPUB', extension: '.epub', rank: 1),
    'application/x-fictionbook+xml' || 'application/fb2' || 'text/fb2+xml' =>
      (label: 'FB2', extension: '.fb2', rank: 2),
    'application/x-mobipocket-ebook' ||
    'application/x-mobi8-ebook' ||
    'application/vnd.amazon.ebook' ||
    'application/vnd.amazon.mobi8-ebook' =>
      path.endsWith('.azw3') || path.contains('.kf8') || t != 'application/x-mobipocket-ebook'
          ? (label: 'AZW3', extension: '.azw3', rank: 3)
          : (label: 'MOBI', extension: '.mobi', rank: 4),
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      (label: 'Word', extension: '.docx', rank: 5),
    'application/vnd.oasis.opendocument.text' => (label: 'ODT', extension: '.odt', rank: 6),
    'application/rtf' || 'text/rtf' => (label: 'RTF', extension: '.rtf', rank: 7),
    'text/plain' => (label: 'Text', extension: '.txt', rank: 8),
    'text/markdown' => (label: 'Markdown', extension: '.md', rank: 9),
    'application/pdf' => (label: 'PDF', extension: '.pdf', rank: 10),
    _ => null,
  };
}

/// An entry: a book with its files, or the way into another feed.
class OpdsEntry {
  const OpdsEntry({
    required this.id,
    required this.title,
    this.authors = const [],
    this.summary = '',
    this.content = '',
    this.links = const [],
    this.thumbnail,
    this.image,
  });

  final String id;
  final String title;
  final List<String> authors;

  /// Short description, as text.
  final String summary;

  /// The longer one, when there is one, as text.
  final String content;
  final List<OpdsLink> links;
  final Uri? thumbnail;
  final Uri? image;

  String get authorLine => authors.join(', ');

  /// What it says about itself: the longer description when there is one.
  String get description => content.length > summary.length ? content : summary;

  /// Its files, the preferred first (EPUB), in the feed's order otherwise.
  List<OpdsLink> get downloads {
    final out = [for (final l in links) if (l.isDownload) l];
    final order = {for (var i = 0; i < out.length; i++) out[i]: i};
    out.sort((a, b) {
      final ra = formatOf(a.type, a.href)!.rank, rb = formatOf(b.type, b.href)!.rank;
      return ra != rb ? ra.compareTo(rb) : order[a]!.compareTo(order[b]!);
    });
    return out;
  }

  bool get isBook => downloads.isNotEmpty;

  /// The feed it opens, when it is not a book: its subsection, or failing
  /// that the first feed it links to that is not a related one.
  OpdsLink? get feed {
    if (isBook) return null;
    final feeds = [for (final l in links) if (l.isFeed && l.rel != 'related' && l.rel != 'self' && l.rel != 'up') l];
    return feeds.where((l) => l.rel == 'subsection').firstOrNull ?? feeds.firstOrNull;
  }

  /// Other feeds about it ("By the same author", its subjects).
  List<OpdsLink> get related => [for (final l in links) if (l.isFeed && l.rel == 'related') l];
}

/// A feed: its entries, and where its next page and search are.
class OpdsFeed {
  const OpdsFeed({
    required this.url,
    required this.title,
    required this.entries,
    this.next,
    this.search,
    this.searchTemplate,
  });

  /// Where it was read from (after redirects): its links are made whole
  /// from here.
  final Uri url;
  final String title;
  final List<OpdsEntry> entries;
  final Uri? next;

  /// An OpenSearch description to read for the search address.
  final Uri? search;

  /// A search address with {searchTerms} in it, when the feed gives one.
  final String? searchTemplate;

  bool get searchable => search != null || searchTemplate != null;
}

/// Not a feed TomeVoice can read.
class OpdsFormatException implements Exception {
  const OpdsFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The catalogue wants a user name and password (or a different one).
class OpdsAuthException implements Exception {
  const OpdsAuthException();
  @override
  String toString() => 'This catalogue asks for a user name and password.';
}

const _imageRels = {'http://opds-spec.org/image', 'http://opds-spec.org/cover', 'x-stanza-cover-image'};
const _thumbRels = {
  'http://opds-spec.org/image/thumbnail',
  'http://opds-spec.org/thumbnail',
  'x-stanza-cover-image-thumbnail',
};

/// A byte-order mark some servers leave at the start of their text.
final _bom = String.fromCharCode(0xFEFF);

/// The OPDS (Atom) feed in [text], read from [url].
OpdsFeed parseOpdsFeed(String text, Uri url) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text.startsWith(_bom) ? text.substring(1) : text);
  } on XmlException {
    throw const OpdsFormatException('This catalogue sent something TomeVoice cannot read.');
  }
  final root = doc.rootElement;
  if (root.name.local != 'feed') {
    throw OpdsFormatException(root.name.local == 'html'
        ? 'That address is a web page, not a catalogue. Catalogues usually end in /opds.'
        : 'That address is not an OPDS catalogue.');
  }
  Uri? next, search;
  String? template;
  for (final e in _children(root, 'link')) {
    final rel = (e.getAttribute('rel') ?? '').trim();
    final raw = (e.getAttribute('href') ?? '').trim();
    if (rel == 'next') next ??= _link(e, url)?.href;
    if (rel != 'search' || raw.isEmpty) continue;
    if (raw.contains('{searchTerms}')) {
      // An address to fill in, its braces kept as written.
      template ??= _wholeTemplate(raw, url);
    } else if ((e.getAttribute('type') ?? '').contains('opensearchdescription')) {
      search ??= _link(e, url)?.href;
    }
  }
  return OpdsFeed(
    url: url,
    title: _text(_child(root, 'title')).trim(),
    entries: [for (final e in _children(root, 'entry')) _entry(e, url)],
    next: next,
    search: search,
    searchTemplate: template,
  );
}

OpdsEntry _entry(XmlElement e, Uri base) {
  final links = [
    for (final l in _children(e, 'link'))
      if (_link(l, base) case final link?) link,
  ];
  Uri? thumb, image;
  for (final l in links) {
    if (_thumbRels.contains(l.rel)) thumb ??= l.href;
    if (_imageRels.contains(l.rel)) image ??= l.href;
  }
  // Media RSS, as Standard Ebooks' free feed gives its covers.
  for (final m in e.childElements.where((c) => c.name.local == 'thumbnail')) {
    final u = m.getAttribute('url');
    if (u != null && u.isNotEmpty) thumb ??= base.resolve(u);
  }
  final authors = [
    for (final a in _children(e, 'author'))
      if (_text(_child(a, 'name')).trim() case final n when n.isNotEmpty) n,
  ];
  return OpdsEntry(
    id: _text(_child(e, 'id')).trim(),
    title: _collapse(_text(_child(e, 'title'))),
    authors: authors,
    summary: _plain(_child(e, 'summary')),
    content: _plain(_child(e, 'content')),
    links: links,
    thumbnail: thumb ?? image,
    image: image ?? thumb,
  );
}

OpdsLink? _link(XmlElement l, Uri base) {
  final href = l.getAttribute('href');
  if (href == null || href.trim().isEmpty) return null;
  final Uri whole;
  try {
    whole = base.resolve(href.trim());
  } on FormatException {
    return null;
  }
  return OpdsLink(
    href: whole,
    rel: (l.getAttribute('rel') ?? '').trim(),
    type: (l.getAttribute('type') ?? '').trim(),
    title: l.getAttribute('title'),
    length: int.tryParse(l.getAttribute('length') ?? ''),
  );
}

/// A search template made whole against [base], its braces kept.
String _wholeTemplate(String raw, Uri base) {
  const marker = 'TOMEVOICESEARCHTERMS';
  final cleaned = raw.replaceAll(RegExp(r'\{[^}]*\?\}'), '').replaceAll('{searchTerms}', marker);
  try {
    return base.resolve(cleaned).toString().replaceAll(marker, '{searchTerms}');
  } on FormatException {
    return raw;
  }
}

/// The search address in the OpenSearch description [text], read from
/// [url]: the one for Atom results, else the first.
String? parseOpenSearch(String text, Uri url) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text.startsWith(_bom) ? text.substring(1) : text);
  } on XmlException {
    return null;
  }
  final urls = doc.rootElement.childElements.where((e) => e.name.local == 'Url').toList();
  final atom = urls.where((u) => (u.getAttribute('type') ?? '').contains('atom')).firstOrNull ?? urls.firstOrNull;
  final template = atom?.getAttribute('template');
  return template == null ? null : _wholeTemplate(template, url);
}

/// [template] with the words searched for in it.
Uri searchUrl(String template, String query) =>
    Uri.parse(template.replaceAll('{searchTerms}', Uri.encodeQueryComponent(query.trim())));

Iterable<XmlElement> _children(XmlElement e, String local) => e.childElements.where((c) => c.name.local == local);

XmlElement? _child(XmlElement e, String local) => _children(e, local).firstOrNull;

String _text(XmlElement? e) => e?.innerText ?? '';

String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A summary or content element as plain text: XHTML's own text, or the
/// tags taken out of escaped HTML, paragraphs kept apart.
String _plain(XmlElement? e) {
  if (e == null) return '';
  final type = (e.getAttribute('type') ?? 'text').toLowerCase();
  if (type == 'xhtml') return _paragraphs(e.innerXml);
  if (type == 'html' || type.contains('html')) return _paragraphs(e.innerText);
  return e.innerText.trim();
}

final _breaks = RegExp(r'<\s*(br|/p|/div|/li|/h[1-6])[^>]*>', caseSensitive: false);
final _tags = RegExp(r'<[^>]*>');

String _paragraphs(String html) {
  final text = _entities(html.replaceAll(_breaks, '\n').replaceAll(_tags, ''));
  return text.split('\n').map(_collapse).where((l) => l.isNotEmpty).join('\n\n');
}

String _entities(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#x') || e.startsWith('#X')) return _char(int.tryParse(e.substring(2), radix: 16));
      if (e.startsWith('#')) return _char(int.tryParse(e.substring(1)));
      return switch (e) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        'nbsp' => ' ',
        'mdash' => String.fromCharCode(0x2014),
        'ndash' => String.fromCharCode(0x2013),
        'hellip' => String.fromCharCode(0x2026),
        'rsquo' => String.fromCharCode(0x2019),
        'lsquo' => String.fromCharCode(0x2018),
        'rdquo' => String.fromCharCode(0x201D),
        'ldquo' => String.fromCharCode(0x201C),
        _ => m[0]!,
      };
    });

/// The character a reference's [code] stands for; U+FFFD for one that
/// stands for none (past U+10FFFF, or too long to read, a lone surrogate,
/// NUL): one bad reference in a summary does not fail the catalogue's page.
String _char(int? code) => code == null || code <= 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)
    ? String.fromCharCode(0xFFFD)
    : String.fromCharCode(code);

/// A file fetched from a catalogue, and what the server said it is.
typedef Fetched = ({Uint8List bytes, String type, Uri url});

/// Talks to one catalogue: feeds, searches, covers and book files, signed
/// in with [user] and [password] when the catalogue asks (Basic or Digest,
/// as Calibre's own server prefers). The password is given to the
/// catalogue's own host only, never to one it redirects to.
class OpdsClient {
  OpdsClient(this.root, {this.user, this.password}) {
    _http
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'TomeVoice (OPDS reader; Android)'
      ..authenticate = _signIn;
  }

  final Uri root;
  final String? user;
  final String? password;
  final _http = HttpClient();

  static const _feedAccept =
      'application/atom+xml;profile=opds-catalog, application/atom+xml;q=0.9, application/xml;q=0.8, */*;q=0.5';
  static const _timeout = Duration(seconds: 40);

  /// Sign-ins already answered: asked again, what was given was refused.
  final _given = <String>{};

  Future<bool> _signIn(Uri url, String scheme, String? realm) async {
    final u = user;
    if (u == null || u.isEmpty || url.host != root.host || url.port != root.port) return false;
    if (!_given.add('$scheme ${realm ?? ''}')) return false;
    // For the whole site, so its covers and files are asked for signed in.
    _http.addCredentials(
      Uri(scheme: url.scheme, host: url.host, port: url.port, path: '/'),
      realm ?? '',
      scheme.toLowerCase() == 'digest'
          ? HttpClientDigestCredentials(u, password ?? '')
          : HttpClientBasicCredentials(u, password ?? ''),
    );
    return true;
  }

  void close() => _http.close(force: true);

  Future<HttpClientResponse> _open(Uri url, String accept) async {
    final req = await _http.getUrl(url).timeout(_timeout);
    req.headers.set(HttpHeaders.acceptHeader, accept);
    final res = await req.close().timeout(_timeout);
    if (res.statusCode == HttpStatus.unauthorized || res.statusCode == HttpStatus.forbidden) {
      await res.drain<void>();
      throw const OpdsAuthException();
    }
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw HttpException('The catalogue answered with an error (HTTP ${res.statusCode}).', uri: url);
    }
    return res;
  }

  /// Where [res] (asked for at [url]) came from after redirects.
  static Uri _final(Uri url, HttpClientResponse res) {
    var at = url;
    for (final r in res.redirects) {
      at = at.resolveUri(r.location);
    }
    return at;
  }

  /// [url], all of it, with the type the server gave it.
  Future<Fetched> fetch(Uri url, {String accept = '*/*', int limit = 32 << 20}) async {
    if (url.scheme == 'data') {
      final data = UriData.fromUri(url);
      return (bytes: data.contentAsBytes(), type: data.mimeType, url: url);
    }
    final res = await _open(url, accept);
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(_timeout)) {
      out.add(chunk);
      if (out.length > limit) throw const OpdsFormatException('That answer is too large.');
    }
    return (bytes: out.takeBytes(), type: res.headers.contentType?.mimeType ?? '', url: _final(url, res));
  }

  /// The feed at [url].
  Future<OpdsFeed> feed(Uri url) async {
    final f = await fetch(url, accept: _feedAccept);
    if (f.type.contains('json')) {
      throw const OpdsFormatException('This catalogue speaks OPDS 2, which TomeVoice does not read yet.');
    }
    return parseOpdsFeed(utf8.decode(f.bytes, allowMalformed: true), f.url);
  }

  /// The results for [query] in [feed]'s catalogue.
  Future<OpdsFeed> search(OpdsFeed feed, String query) async {
    var template = feed.searchTemplate;
    final description = feed.search;
    if (template == null && description != null) {
      final f = await fetch(description, accept: 'application/opensearchdescription+xml, application/xml;q=0.9, */*;q=0.5');
      template = parseOpenSearch(utf8.decode(f.bytes, allowMalformed: true), f.url);
    }
    if (template == null) throw const OpdsFormatException('This catalogue cannot be searched.');
    return this.feed(searchUrl(template, query));
  }

  /// Save [url] as [into], telling [onProgress] the bytes so far and the
  /// whole (-1 when the server does not say). The server's own name for
  /// the file, when it gives one.
  Future<({String? name, String type})> download(
    Uri url,
    File into, {
    void Function(int done, int total)? onProgress,
  }) async {
    final res = await _open(url, '*/*');
    final total = res.contentLength;
    var done = 0;
    await into.parent.create(recursive: true);
    final sink = into.openWrite();
    try {
      await for (final chunk in res.timeout(_timeout)) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total >= 0 && done < total) {
      throw const HttpException('The download stopped part way. Try again.');
    }
    return (name: _dispositionName(res.headers.value('content-disposition')), type: res.headers.contentType?.mimeType ?? '');
  }

  static String? _dispositionName(String? header) {
    if (header == null) return null;
    final star = RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)").firstMatch(header);
    if (star != null) {
      try {
        return Uri.decodeComponent(star[1]!.trim());
      } on FormatException {
        // The plain one below.
      }
    }
    final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?').firstMatch(header);
    return plain?[1]?.trim();
  }
}

/// A file name for [entry]'s [link]: the server's own name when it is a
/// book file's, else the title, with the extension its format takes.
String downloadName(OpdsEntry entry, OpdsLink link, {String? serverName}) {
  final format = formatOf(link.type, link.href);
  final ext = format?.extension ?? '';
  String clean(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final server = serverName == null ? '' : clean(serverName);
  if (server.isNotEmpty && ext.isNotEmpty && server.toLowerCase().endsWith(ext)) return server;
  final title = clean(entry.title);
  final base = title.isEmpty ? 'Book' : (title.length > 80 ? title.substring(0, 80).trim() : title);
  return '$base$ext';
}
