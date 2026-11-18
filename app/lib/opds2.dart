part of 'opds.dart';

// OPDS 2 catalogues: the same feeds as OPDS 1, written as JSON. A feed has
// navigation (links to other feeds), publications (books, each with its
// metadata, links and images) and groups of either, and links of its own:
// the next page, and a search address written as a URI template. Project
// Gutenberg's catalogue at https://www.gutenberg.org/opds/ is one. They are
// read into the same OpdsFeed and OpdsEntry as Atom feeds, so the screens
// show both alike. See https://specs.opds.io/opds-2.0.

/// Whether [text] reads as JSON rather than XML: it starts with a brace,
/// past a byte-order mark and white space.
bool looksLikeJson(String text) {
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == _bom || c.trim().isEmpty) continue;
    return c == '{';
  }
  return false;
}

/// The OPDS 2 feed in [text], read from [url].
OpdsFeed parseOpds2Feed(String text, Uri url) {
  final Object? json;
  try {
    json = jsonDecode(text.startsWith(_bom) ? text.substring(1) : text);
  } on FormatException {
    throw const OpdsFormatException('This catalogue sent something TomeVoice cannot read.');
  }
  if (json is! Map) throw const OpdsFormatException('That address is not an OPDS catalogue.');
  final metadata = json['metadata'];
  final title = _collapse(_name(metadata is Map ? metadata['title'] : null));
  final hasCollections = json['navigation'] is List || json['publications'] is List || json['groups'] is List;
  if (!hasCollections) {
    // A single publication (application/opds-publication+json): one book.
    if (metadata is! Map || json['links'] is! List) {
      throw const OpdsFormatException('That address is not an OPDS catalogue.');
    }
    return OpdsFeed(url: url, title: title, entries: [_publication(json, url)]);
  }
  Uri? next, search;
  String? template;
  for (final l in json['links'] is List ? json['links'] as List : const []) {
    if (l is! Map) continue;
    final rels = _rels(l['rel']);
    final raw = l['href'] is String ? (l['href'] as String).trim() : '';
    if (raw.isEmpty) continue;
    if (rels.contains('next')) next ??= _resolve(raw, url);
    if (!rels.contains('search')) continue;
    if (l['templated'] == true || raw.contains('{')) {
      template ??= _searchTemplate(raw, url);
    } else if ('${l['type'] ?? ''}'.contains('opensearchdescription')) {
      search ??= _resolve(raw, url);
    }
  }
  return OpdsFeed(
    url: url,
    title: title,
    entries: [
      ..._navigation(json['navigation'], url),
      ..._publications(json['publications'], url),
      for (final g in json['groups'] is List ? json['groups'] as List : const [])
        if (g is Map) ..._group(g, url),
    ],
    next: next,
    search: search,
    searchTemplate: template,
  );
}

/// A group: its navigation as entries; its publications as one entry that
/// opens the group's own feed when it has one (as Gutenberg's front page has
/// Recently Added and Most Popular), else as entries of their own.
List<OpdsEntry> _group(Map g, Uri base) {
  final out = _navigation(g['navigation'], base);
  final books = _publications(g['publications'], base);
  if (books.isEmpty) return out;
  final metadata = g['metadata'];
  final title = _collapse(_name(metadata is Map ? metadata['title'] : null));
  final own = _jsonLinks(g['links'], base).where((l) => l.isFeed).firstOrNull;
  if (own == null || title.isEmpty) return [...out, ...books];
  return [
    ...out,
    OpdsEntry(
      id: own.href.toString(),
      title: title,
      // The group's link is its "self"; here it is the way in.
      links: [OpdsLink(href: own.href, rel: 'subsection', type: own.type, title: own.title)],
    ),
  ];
}

/// Navigation links as entries, each the way into another feed.
List<OpdsEntry> _navigation(Object? list, Uri base) => [
      for (final n in list is List ? list : const [])
        if (n is Map)
          if (_jsonLink(n, base) case final link?)
            OpdsEntry(
              id: link.href.toString(),
              title: switch (_collapse(_name(n['title']))) { '' => link.href.toString(), final t => t },
              links: [
                OpdsLink(
                  href: link.href,
                  // Navigation always leads to another feed, whatever it is called.
                  rel: link.rel.isEmpty ? 'subsection' : link.rel,
                  type: link.type.isEmpty ? 'application/opds+json' : link.type,
                  title: link.title,
                ),
              ],
            ),
    ];

List<OpdsEntry> _publications(Object? list, Uri base) => [
      for (final p in list is List ? list : const [])
        if (p is Map && p['metadata'] is Map) _publication(p, base),
    ];

/// A publication as an entry: its title, authors and description, its links
/// (the acquisitions among them its files), and its cover.
OpdsEntry _publication(Map p, Uri base) {
  final m = p['metadata'] as Map;
  final links = _jsonLinks(p['links'], base);
  final images = _jsonLinks(p['images'], base, sized: true);
  Uri? thumb, image;
  for (final l in [...images, ...links]) {
    if (_thumbRels.contains(l.rel)) thumb ??= l.href;
    if (_imageRels.contains(l.rel)) image ??= l.href;
  }
  // Images without a rel: the smallest is the thumbnail, the largest the
  // cover. They are listed smallest first when their sizes are not given.
  final plain = [for (final l in images) if (l.rel.isEmpty) l];
  if (plain.isNotEmpty) {
    if (plain.every((l) => l.length != null)) plain.sort((a, b) => a.length!.compareTo(b.length!));
    thumb ??= plain.first.href;
    image ??= plain.last.href;
  }
  final self = links.where((l) => l.rel == 'self').firstOrNull;
  final title = _collapse(_name(m['title']));
  final identifier = _name(m['identifier']).trim();
  return OpdsEntry(
    id: identifier.isNotEmpty ? identifier : (self?.href.toString() ?? title),
    title: title,
    authors: _contributors(m['author']),
    summary: _description(m['description']),
    links: [for (final l in links) if (!_imageRels.contains(l.rel) && !_thumbRels.contains(l.rel)) l],
    thumbnail: thumb ?? image,
    image: image ?? thumb,
  );
}

/// The links in [list], made whole; with [sized], an image's width is kept
/// as its length, to tell the smallest from the largest.
List<OpdsLink> _jsonLinks(Object? list, Uri base, {bool sized = false}) => [
      for (final l in list is List ? list : const [])
        if (l is Map)
          if (_jsonLink(l, base, sized: sized) case final link?) link,
    ];

OpdsLink? _jsonLink(Map l, Uri base, {bool sized = false}) {
  final href = l['href'];
  if (href is! String || href.trim().isEmpty) return null;
  final whole = _resolve(href.trim(), base);
  if (whole == null) return null;
  final title = l['title'];
  final number = sized ? l['width'] ?? l['height'] : l['length'];
  return OpdsLink(
    href: whole,
    rel: _rel(_rels(l['rel'])),
    type: l['type'] is String ? (l['type'] as String).trim() : '',
    title: title is String ? title : null,
    length: number is num ? number.toInt() : null,
  );
}

Uri? _resolve(String href, Uri base) {
  try {
    return base.resolve(href);
  } on FormatException {
    return null;
  }
}

/// A link's rels: one, or a list of them.
List<String> _rels(Object? rel) => switch (rel) {
      final String s => [s.trim()],
      final List l => [for (final r in l) if (r is String) r.trim()],
      _ => const [],
    };

/// Of several rels, the one that says most about what the link is for: an
/// acquisition first, as that makes it a file to take.
String _rel(List<String> rels) {
  final acquisition = rels.where((r) => r.startsWith(OpdsLink._acquisition)).firstOrNull;
  if (acquisition != null) return acquisition;
  bool known(String r) =>
      _imageRels.contains(r) ||
      _thumbRels.contains(r) ||
      const {'next', 'search', 'subsection', 'related', 'self', 'up'}.contains(r);
  return rels.where(known).firstOrNull ?? rels.firstOrNull ?? '';
}

/// A name, title or identifier: a string, or the same in several languages
/// (the English, else the first), or an object with a name.
String _name(Object? v) => switch (v) {
      final String s => s,
      final Map m when m['name'] != null => _name(m['name']),
      final Map m => _name(m['en'] ?? m.values.whereType<String>().firstOrNull),
      _ => '',
    };

/// The people named in [v]: one, or a list; each a string or an object.
List<String> _contributors(Object? v) => [
      for (final c in v is List ? v : [v])
        if (_collapse(_name(c)) case final n when n.isNotEmpty) n,
    ];

/// A description as plain text, paragraphs kept apart, whether it is
/// written as HTML or as text.
String _description(Object? v) {
  final s = _name(v);
  if (s.contains(_tags)) return _paragraphs(s);
  return s.split(RegExp(r'\n\s*\n')).map(_collapse).where((l) => l.isNotEmpty).join('\n\n');
}

/// [raw], an RFC 6570 search template such as `/search{?query,title}`, as
/// an address with {searchTerms} where the words go, made whole against
/// [base]. The words go in the `query` variable (OPDS 2's own), else the
/// first one; the other variables are left out.
String _searchTemplate(String raw, Uri base) {
  final expression = RegExp(r'\{([?&]?)([^}]*)\}');
  String bare(String v) => v.trim().replaceAll(RegExp(r'(:\d+|\*)$'), '');
  final names = [
    for (final m in expression.allMatches(raw))
      for (final v in m[2]!.split(',')) bare(v),
  ];
  if (names.contains('searchTerms')) return _wholeTemplate(raw, base);
  final words = names.contains('query') ? 'query' : names.firstOrNull;
  var queried = false;
  final filled = raw.replaceAllMapped(expression, (m) {
    final vars = [for (final v in m[2]!.split(',')) bare(v)];
    if (words == null || !vars.contains(words)) return '';
    if (m[1]!.isEmpty) return '{searchTerms}';
    final joint = queried || m[1] == '&' && raw.substring(0, m.start).contains('?') ? '&' : '?';
    queried = true;
    return '$joint$words={searchTerms}';
  });
  return _wholeTemplate(filled, base);
}
