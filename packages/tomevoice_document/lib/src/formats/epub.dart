import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../encoding.dart';
import '../image_size.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

Book parseEpub(Uint8List bytes, {required String id, String? filename, LegacyDecoder? legacy}) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } on Object {
    throw const ParseException('This EPUB is damaged: it cannot be opened as a zip archive.');
  }

  final names = {for (final f in archive.files) f.name.replaceAll('\\', '/')};

  final container = _read(archive, 'META-INF/container.xml');
  if (container == null) {
    throw const ParseException('This EPUB is damaged: it has no META-INF/container.xml.');
  }

  final opfPath = _opfPath(container);
  final opfDir = _dirOf(opfPath);
  final opfXml = _read(archive, opfPath);
  if (opfXml == null) {
    throw const ParseException('This EPUB is damaged: its package document is missing.');
  }

  late XmlDocument opf;
  try {
    opf = XmlDocument.parse(opfXml);
  } on XmlException {
    throw const ParseException('This EPUB is damaged: its package document cannot be read.');
  }

  final metadata = _metadata(opf, filename);
  final manifest = _manifest(opf, opfDir, names);
  _refuseDrm(archive, manifest);
  final spine = _spine(opf, manifest);
  final spineHrefs = [for (final s in spine) s.href];

  // The contents first: where it points inside a document is where a
  // chapter starts (a whole book in one file with a contents of anchors).
  final contents = _contents(archive, opf, manifest, names, legacy);
  final anchorsIn = <String, Set<String>>{};
  for (final e in contents) {
    if (e.path != null && e.fragment != null) (anchorsIn[e.path!] ??= {}).add(e.fragment!);
  }

  // Ids in later documents that marker links point at are notes (an
  // endnotes file at the back): gathered as the documents are read, in
  // spine order, so a link pointing back (a note's way home) never counts.
  final position = {for (var i = 0; i < spineHrefs.length; i++) spineHrefs[i]: i};
  final notes = <String, Set<String>>{};

  resetBlockIds();
  final parts = <_Part>[];
  final aside = <_Part>[];
  final anchorsOf = <String, Map<String, int>>{};
  for (var i = 0; i < spineHrefs.length; i++) {
    final href = spineHrefs[i];
    final html = _read(archive, href, legacy);
    if (html == null) continue;
    _noteTargets(html, i, spineHrefs, position, notes);
    final chapter = htmlChapter(
      html,
      language: metadata.language,
      href: href,
      notes: notes[href] ?? const {},
      hasFile: names.contains,
    );
    if (chapter.blocks.isEmpty) continue;
    anchorsOf[href] = chapter.anchors;
    final split = _split(href, chapter.blocks, chapter.anchors, anchorsIn[href]);
    // linear="no" (answers, notes, pop-ups) is not part of the reading
    // order: it goes to the end, where the contents can still reach it.
    // One with nothing to say (a cover picture) keeps its place.
    if (!spine[i].linear && chapter.blocks.any((b) => b.speakable)) {
      aside.addAll(split);
    } else {
      parts.addAll(split);
    }
  }
  parts.addAll(aside);

  if (parts.isEmpty) {
    throw const ParseException('EPUB has no readable text in its spine.');
  }

  final indexed = [
    for (var i = 0; i < parts.length; i++)
      Section(
        id: 's$i',
        index: i,
        href: parts[i].href,
        title: _firstHeading(parts[i].blocks) ?? _chapterLineTitle(parts[i].blocks),
        blocks: parts[i].blocks,
      ),
  ];

  final withImages = _measureImages(archive, indexed);
  final toc = _tocEntries(contents, parts, anchorsOf, withImages);
  // Many EPUBs never declare a cover, or declare one that is not in the
  // archive; their first picture is the cover.
  final declared = _coverPath(opf, manifest);
  final cover = declared != null && _entry(archive, declared) != null
      ? declared
      : withImages
          .take(8)
          .expand((s) => s.blocks)
          .where((b) => b.isImage && b.imageWidth != null)
          .firstOrNull
          ?.image;
  final book = Book(
    id: id,
    metadata: cover == null
        ? metadata
        : BookMetadata(
            title: metadata.title,
            authors: metadata.authors,
            language: metadata.language,
            publisher: metadata.publisher,
            identifier: metadata.identifier,
            cover: cover,
            description: metadata.description,
          ),
    sections: withImages,
    toc: toc,
    source: SourceKind.epub,
    sourceName: filename,
    wordCount: 0,
  );
  return Book(
    id: book.id,
    metadata: book.metadata,
    sections: book.sections,
    toc: book.toc,
    source: book.source,
    sourceName: book.sourceName,
    wordCount: wordCountOf(book),
  );
}

/// Font obfuscation (IDPF's, and Adobe's older one): a publisher's way of
/// keeping an embedded font from being lifted, not DRM. The book itself
/// is readable, and TomeVoice does not use embedded fonts anyway.
const _fontObfuscation = {
  'http://www.idpf.org/2008/embedding',
  'http://ns.adobe.com/pdf/enc#RC',
};

final _algorithmAttr = RegExp(r'''Algorithm\s*=\s*["']([^"']*)["']''');
final _uriAttr = RegExp(r'''URI\s*=\s*["']([^"']*)["']''');

/// Throws [EncryptedDocumentException] when META-INF/encryption.xml says
/// anything but fonts is encrypted, or uses anything but font
/// obfuscation. A DRM-free book with obfuscated fonts used to be refused.
void _refuseDrm(Archive archive, Map<String, ({String href, String media, String properties})> manifest) {
  final xml = _read(archive, 'META-INF/encryption.xml');
  if (xml == null) return;
  final entries = <(String, String)>[];
  try {
    final doc = XmlDocument.parse(xml);
    for (final data in doc.descendants.whereType<XmlElement>().where((e) => e.localName == 'EncryptedData')) {
      String attr(String element, String name) =>
          data.descendants.whereType<XmlElement>().where((e) => e.localName == element).firstOrNull?.getAttribute(name) ??
          '';
      entries.add((attr('EncryptionMethod', 'Algorithm'), attr('CipherReference', 'URI')));
    }
  } on XmlException {
    // Read what can be read: each algorithm with the URI after it.
    final algorithms = [for (final m in _algorithmAttr.allMatches(xml)) m.group(1)!];
    final uris = [for (final m in _uriAttr.allMatches(xml)) m.group(1)!];
    for (var i = 0; i < algorithms.length; i++) {
      entries.add((algorithms[i], i < uris.length ? uris[i] : ''));
    }
  }
  final fonts = {
    for (final item in manifest.values)
      if (item.media.contains('font') || item.media.contains('opentype')) item.href,
  };
  for (final (algorithm, uri) in entries) {
    final path = zipJoin('', _decodeHref(uri.trim()));
    final font = fonts.contains(path) || RegExp(r'\.(ttf|otf|woff2?|eot)$', caseSensitive: false).hasMatch(path);
    if (!_fontObfuscation.contains(algorithm.trim()) || !font) {
      throw const EncryptedDocumentException(
        'This book is DRM-protected. TomeVoice cannot open encrypted files.',
      );
    }
  }
}

/// Adds to [out] (spine path -> note ids) the ids in later documents that
/// the marker links of document [i] ([html]) point at.
void _noteTargets(
  String html,
  int i,
  List<String> spine,
  Map<String, int> position,
  Map<String, Set<String>> out,
) {
  for (final link in markerLinks(html)) {
    final hash = link.indexOf('#');
    final path = link.substring(0, hash);
    if (path.isEmpty || path.contains(':')) continue;
    final target = zipJoin(_dirOf(spine[i]), _decodeHref(path));
    final at = position[target];
    if (at != null && at > i) (out[target] ??= {}).add(_decodeHref(link.substring(hash + 1)));
  }
}

String _decodeHref(String s) {
  try {
    return Uri.decodeComponent(s);
  } on Object {
    return s;
  }
}

/// The text of [path] in the EPUB, in the encoding it declares (XHTML in
/// ISO-8859-1 or windows-1252 came out full of U+FFFD as UTF-8).
String? _read(Archive archive, String path, [LegacyDecoder? legacy]) {
  final f = _entry(archive, path);
  if (f == null) return null;
  final data = _contentOf(f);
  if (data.isEmpty) return null;
  return decodeBytes(data, markup: true, legacy: legacy);
}

/// [f]'s bytes, decompressed without the archive keeping a copy: readBytes
/// caches every entry it is asked for, so a big book ended up held twice.
Uint8List _contentOf(ArchiveFile f) {
  final out = OutputMemoryStream(size: f.size > 0 ? f.size : null);
  f.decompress(out);
  return out.getBytes();
}

ArchiveFile? _entry(Archive archive, String path) {
  final normalised = path.replaceAll('\\', '/');
  final f = archive.findFile(normalised);
  if (f != null) return f.isFile ? f : null;
  // Zips written on Windows can name entries with backslashes.
  for (final f in archive.files) {
    if (f.isFile && f.name.replaceAll('\\', '/') == normalised) return f;
  }
  return null;
}

String _opfPath(String containerXml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(containerXml);
  } on XmlException {
    throw const ParseException('This EPUB is damaged: its container.xml cannot be read.');
  }
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() == 'rootfile') {
      final path = el.getAttribute('full-path');
      if (path != null && path.isNotEmpty) return path;
    }
  }
  throw const ParseException('This EPUB is damaged: its container.xml names no book inside.');
}

String _dirOf(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i <= 0 ? '' : path.substring(0, i);
}

String zipJoin(String dir, String href) {
  final cleaned = href.split('#').first.replaceAll('\\', '/');
  if (cleaned.startsWith('/')) return cleaned.substring(1);
  final parts = <String>[
    if (dir.isNotEmpty) ...dir.split('/'),
    ...cleaned.split('/'),
  ];
  final out = <String>[];
  for (final p in parts) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(p);
    }
  }
  return out.join('/');
}

BookMetadata _metadata(XmlDocument opf, String? filename) {
  String? first(String local) {
    for (final el in opf.descendants.whereType<XmlElement>()) {
      if (el.localName.toLowerCase() == local && el.innerText.trim().isNotEmpty) {
        return collapseWhitespace(el.innerText);
      }
    }
    return null;
  }

  final authors = <String>[];
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() == 'creator') {
      final t = collapseWhitespace(el.innerText);
      if (t.isNotEmpty) authors.add(t);
    }
  }

  return BookMetadata(
    title: first('title') ?? _fallbackTitle(filename),
    authors: authors,
    language: first('language'),
    publisher: first('publisher'),
    identifier: first('identifier'),
    description: _plainBlurb(first('description')),
  );
}

/// A description is often escaped HTML; keep only its words.
String? _plainBlurb(String? raw) {
  if (raw == null) return null;
  final text = collapseWhitespace(decodeEntities(raw.replaceAll(RegExp(r'<[^>]+>'), ' ')))
      // A removed tag leaves a space before punctuation: "cheese ." -> "cheese."
      .replaceAllMapped(RegExp(r' ([.,;:!?])'), (m) => m.group(1)!);
  return text.isEmpty ? null : text;
}

String _fallbackTitle(String? filename) {
  if (filename == null || filename.isEmpty) return 'Untitled';
  final slash = filename.replaceAll('\\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  return dot > 0 ? slash.substring(0, dot) : slash;
}

Map<String, ({String href, String media, String properties})> _manifest(
  XmlDocument opf,
  String opfDir,
  Set<String> names,
) {
  final out = <String, ({String href, String media, String properties})>{};
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'item') continue;
    final id = el.getAttribute('id');
    final href = el.getAttribute('href');
    if (id == null || href == null) continue;
    out[id] = (
      href: _resolvePath(opfDir, href, names),
      media: (el.getAttribute('media-type') ?? '').toLowerCase(),
      properties: (el.getAttribute('properties') ?? '').toLowerCase(),
    );
  }
  return out;
}

/// [href] (relative to [dir], %-escaped as a URL) as a path in the zip:
/// "Chapter%201.xhtml" is the entry "Chapter 1.xhtml". A zip that really
/// names its entry with the escape keeps it.
String _resolvePath(String dir, String href, Set<String> names) {
  final decoded = zipJoin(dir, _decodeHref(href.split('#').first));
  if (names.contains(decoded)) return decoded;
  final raw = zipJoin(dir, href);
  return names.contains(raw) ? raw : decoded;
}

/// Spine items in order, with whether they are part of the reading order.
List<({String href, bool linear})> _spine(
  XmlDocument opf,
  Map<String, ({String href, String media, String properties})> manifest,
) {
  const readable = {
    'application/xhtml+xml',
    'text/html',
    'application/xml',
    'text/xml',
  };
  final out = <({String href, bool linear})>[];
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'itemref') continue;
    final idref = el.getAttribute('idref');
    if (idref == null) continue;
    final item = manifest[idref];
    if (item == null) continue;
    if (item.media.isNotEmpty && !readable.contains(item.media)) continue;
    out.add((href: item.href, linear: (el.getAttribute('linear') ?? '').trim().toLowerCase() != 'no'));
  }
  return out;
}

/// One entry of a book's contents: its title (with its part's, "Part I ·
/// I"), where it points, and how deep it sits.
class _Entry {
  _Entry(this.title, this.path, this.fragment, this.depth, this.parent);

  String title;
  final String? path;
  final String? fragment;
  final int depth;
  String? parent;
}

/// Part of a spine document that is a section: the whole document, or the
/// stretch from one contents anchor to the next.
class _Part {
  _Part(this.path, this.href, this.starts, this.blocks);

  final String path;
  final String href;

  /// Block indexes in the document where this part begins; more than one
  /// when an anchor with almost nothing after it joined the next.
  final Set<int> starts;
  final List<Block> blocks;
}

/// [blocks] of the document at [path], cut where the contents points into
/// it ([fragments]). A stretch with almost nothing to say (a "PART ONE"
/// line before the chapter's own anchor) joins the stretch after it, so it
/// is still read, with its chapter.
List<_Part> _split(String path, List<Block> blocks, Map<String, int> anchors, Set<String>? fragments) {
  final names = <int, String>{0: ''};
  for (final f in fragments ?? const <String>{}) {
    final at = anchors[f];
    if (at != null && at > 0 && at < blocks.length) names.putIfAbsent(at, () => f);
  }
  final starts = names.keys.toList()..sort();
  if (starts.length == 1) return [_Part(path, path, {0}, blocks)];
  final out = <_Part>[];
  _Part? carry;
  for (var k = 0; k < starts.length; k++) {
    final from = starts[k];
    final to = k + 1 < starts.length ? starts[k + 1] : blocks.length;
    final name = names[from]!;
    var part = _Part(path, name.isEmpty ? path : '$path#$name', {from}, blocks.sublist(from, to));
    if (carry != null) {
      part = _Part(path, part.href, {...carry.starts, from}, [...carry.blocks, ...part.blocks]);
      carry = null;
    }
    if (_spoken(part.blocks) < 80 && k + 1 < starts.length) {
      carry = part;
    } else {
      out.add(part);
    }
  }
  final last = out.last;
  if (out.length > 1 && _spoken(last.blocks) < 80) {
    final prev = out[out.length - 2];
    out[out.length - 2] = _Part(path, prev.href, prev.starts, [...prev.blocks, ...last.blocks]);
    out.removeLast();
  }
  return out;
}

int _spoken(List<Block> blocks) => blocks.where((b) => b.speakable).fold(0, (n, b) => n + b.text.length);

/// The book's contents, flattened in order: the EPUB 3 nav (the manifest
/// item with properties="nav"), else the NCX, each resolved from its own
/// folder (an NCX at the root says "OEBPS/ch1.xhtml"). Nested entries carry
/// their part's title; a flat list with "PART I", "PART II" between the
/// chapters is read as nested too.
List<_Entry> _contents(
  Archive archive,
  XmlDocument opf,
  Map<String, ({String href, String media, String properties})> manifest,
  Set<String> names,
  LegacyDecoder? legacy,
) {
  final navs = [
    for (final i in manifest.values)
      if (i.properties.split(' ').contains('nav')) i.href,
  ];
  // EPUB 2 names its NCX in the spine; otherwise any NCX will do.
  final tocId = opf.descendants
      .whereType<XmlElement>()
      .where((e) => e.localName.toLowerCase() == 'spine')
      .firstOrNull
      ?.getAttribute('toc');
  final ncxs = [
    if (tocId != null && manifest[tocId] != null) manifest[tocId]!.href,
    for (final i in manifest.values)
      if (i.media.contains('dtbncx') || i.href.toLowerCase().endsWith('.ncx')) i.href,
  ];
  for (final path in navs) {
    final html = _read(archive, path, legacy);
    final entries = html == null ? const <_Entry>[] : _fromNav(html, _dirOf(path), names);
    if (entries.isNotEmpty) return _withParts(entries);
  }
  for (final path in ncxs.toSet()) {
    final ncx = _read(archive, path, legacy);
    final entries = ncx == null ? const <_Entry>[] : _fromNcx(ncx, _dirOf(path), names);
    if (entries.isNotEmpty) return _withParts(entries);
  }
  // A book that declares neither: a document called nav or toc that has a
  // toc nav in it (reading every document to find one was most of the
  // memory a big book took).
  for (final i in manifest.values) {
    final file = i.href.split('/').last.toLowerCase();
    if (!i.media.contains('html') || !(file.contains('nav') || file.contains('toc'))) continue;
    final html = _read(archive, i.href, legacy);
    if (html == null || !html.contains('toc')) continue;
    final entries = _fromNav(html, _dirOf(i.href), names);
    if (entries.isNotEmpty) return _withParts(entries);
  }
  return const [];
}

/// Path and fragment of [href] in a contents file in [dir].
(String?, String?) _target(String href, String dir, Set<String> names) {
  final h = href.trim();
  if (h.isEmpty || h.contains(':')) return (null, null);
  final hash = h.indexOf('#');
  final path = hash < 0 ? h : h.substring(0, hash);
  final fragment = hash < 0 || hash == h.length - 1 ? null : _decodeHref(h.substring(hash + 1));
  if (path.isEmpty) return (null, fragment);
  return (_resolvePath(dir, path, names), fragment);
}

List<_Entry> _fromNav(String html, String dir, Set<String> names) {
  late XmlDocument doc;
  try {
    doc = XmlDocument.parse(
      html.contains('<html') ? html : '<html>$html</html>',
      entityMapping: const XmlDefaultEntityMapping.html5(),
    );
  } on XmlException {
    return const [];
  }
  // A nav document also holds the page list (printed page numbers) and
  // landmarks. Only the toc nav is chapters; reading the page list gave
  // chapter titles like "[127]".
  String typeOf(XmlElement e) => [
        for (final a in e.attributes)
          if (a.name.local == 'type') a.value.toLowerCase(),
      ].join(' ');
  final navs = doc.descendants.whereType<XmlElement>().where((e) => e.localName.toLowerCase() == 'nav').toList();
  final toc = navs.where((n) => typeOf(n).contains('toc')).toList();
  final roots = toc.isNotEmpty
      ? toc
      : navs.where((n) => !typeOf(n).contains('page-list') && !typeOf(n).contains('landmarks')).toList();
  final out = <_Entry>[];

  void list(XmlElement ol, int depth, String? parent) {
    for (final li in ol.childElements.where((e) => e.localName.toLowerCase() == 'li')) {
      final label = li.childElements
          .where((e) => const {'a', 'span'}.contains(e.localName.toLowerCase()))
          .firstOrNull;
      final title = label == null ? '' : collapseWhitespace(label.innerText);
      if (title.isNotEmpty) {
        final href = label!.localName.toLowerCase() == 'a' ? label.getAttribute('href') ?? '' : '';
        final (path, fragment) = _target(href, dir, names);
        out.add(_Entry(title, path, fragment, depth, parent));
      }
      for (final sub in li.childElements.where((e) => const {'ol', 'ul'}.contains(e.localName.toLowerCase()))) {
        list(sub, depth + 1, title.isEmpty ? parent : title);
      }
    }
  }

  for (final root in roots.isEmpty ? [doc.rootElement] : roots) {
    final lists = root.localName.toLowerCase() == 'nav'
        ? root.childElements.where((e) => const {'ol', 'ul'}.contains(e.localName.toLowerCase()))
        : root.descendants.whereType<XmlElement>().where((e) => e.localName.toLowerCase() == 'ol').take(1);
    for (final ol in lists) {
      list(ol, 0, null);
    }
  }
  return out;
}

List<_Entry> _fromNcx(String ncx, String dir, Set<String> names) {
  late XmlDocument doc;
  try {
    doc = XmlDocument.parse(ncx, entityMapping: const XmlDefaultEntityMapping.html5());
  } on XmlException {
    return const [];
  }
  final out = <_Entry>[];
  void points(XmlElement parent, int depth, String? parentTitle) {
    for (final point in parent.childElements.where((e) => e.localName.toLowerCase() == 'navpoint')) {
      var title = '';
      var src = '';
      for (final child in point.childElements) {
        final name = child.localName.toLowerCase();
        if (name == 'navlabel') title = collapseWhitespace(child.innerText);
        if (name == 'content') src = child.getAttribute('src') ?? '';
      }
      if (title.isNotEmpty) {
        final (path, fragment) = _target(src, dir, names);
        out.add(_Entry(title, path, fragment, depth, parentTitle));
      }
      points(point, depth + 1, title.isEmpty ? parentTitle : title);
    }
  }

  final map = doc.descendants.whereType<XmlElement>().where((e) => e.localName.toLowerCase() == 'navmap').firstOrNull;
  if (map != null) points(map, 0, null);
  return out;
}

/// "PART I", "Part Two", "Book 3: The Return": a part, the whole title (a
/// chapter called "Volume 1 Chapter 4" is a chapter).
final _partTitle = RegExp(
  r'^(?:part|book|volume|vol\.|livre|partie|teil|buch|parte|libro|deel|boek|tom|część|часть|книга|том)\s+'
  r'(?:[ivxlcdm]+|\d+|one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|fourth|fifth|'
  r'sixth|seventh|eighth|ninth|tenth|last)\b\.?(?:\s*[:.\-–—]\s*.*)?$',
  caseSensitive: false,
);

/// Sections that stand alone, never one part's chapter.
final _standalone = RegExp(
  r'^(?:prologue|epilogue|afterword|appendix|notes?|endnotes|glossary|acknowledge?ments|about the author|'
  r'introduction|preface|foreword|contents|bibliography|index|also by|copyright|dedication|epigraph)\b',
  caseSensitive: false,
);

/// Entries with their part's title before theirs. In a flat contents that
/// lists "PART I" before its chapters (and "PART II" before the next ones,
/// as Crime and Punishment's does), each part is the parent of the
/// chapters after it.
List<_Entry> _withParts(List<_Entry> entries) {
  final flat = entries.every((e) => e.depth == 0);
  if (flat && entries.where((e) => _partTitle.hasMatch(e.title)).length >= 2) {
    String? part;
    for (final e in entries) {
      if (_partTitle.hasMatch(e.title)) {
        part = e.title;
      } else if (_standalone.hasMatch(e.title)) {
        part = null;
      } else {
        e.parent ??= part;
      }
    }
  }
  for (final e in entries) {
    final p = e.parent;
    if (p != null && !e.title.toLowerCase().contains(p.toLowerCase())) e.title = '$p · ${e.title}';
  }
  return entries;
}

/// One contents row per section that an entry starts: the most specific
/// entry there ("PART II · CHAPTER I", not "PART II", when both point at
/// the same file). A section the contents forgot, between chapters of a
/// part, is still that part's: "PART II · V".
List<TocEntry> _tocEntries(
  List<_Entry> contents,
  List<_Part> parts,
  Map<String, Map<String, int>> anchorsOf,
  List<Section> sections,
) {
  if (contents.isEmpty) {
    return [
      for (final s in sections) TocEntry(title: s.displayTitle, sectionIndex: s.index, href: s.href),
    ];
  }
  final byPath = <String, List<int>>{};
  for (var i = 0; i < parts.length; i++) {
    (byPath[parts[i].path] ??= []).add(i);
  }
  final best = <int, _Entry>{};
  for (final e in contents) {
    final indexes = e.path == null ? null : byPath[e.path!];
    if (indexes == null) continue;
    final at = e.fragment == null ? 0 : anchorsOf[e.path!]?[e.fragment!];
    if (at == null) continue;
    final i = indexes.where((p) => parts[p].starts.contains(at)).firstOrNull;
    if (i == null) continue;
    final had = best[i];
    if (had == null || e.depth >= had.depth) best[i] = e;
  }
  final out = <TocEntry>[];
  String? part;
  for (var i = 0; i < sections.length; i++) {
    final e = best[i];
    if (e != null) {
      part = e.parent;
      out.add(TocEntry(title: e.title, sectionIndex: i, href: sections[i].href));
    } else if (part != null && sections[i].blocks.any((b) => b.speakable)) {
      out.add(TocEntry(title: '$part · ${sections[i].displayTitle}', sectionIndex: i, href: sections[i].href));
    }
  }
  return out;
}

String? _firstHeading(List<Block> blocks) {
  for (final b in blocks) {
    if (b.role == BlockRole.heading && b.text.isNotEmpty) return b.text;
  }
  return null;
}

/// Give every figure its pixel size, and drop references to images that are
/// not in the archive (or not a format we can show).
List<Section> _measureImages(Archive archive, List<Section> sections) {
  final sizes = <String, ({int width, int height})?>{};
  return [
    for (final s in sections)
      Section(
        id: s.id,
        index: s.index,
        href: s.href,
        title: s.title,
        blocks: [
          for (final b in s.blocks)
            if (b.image == null)
              b
            else ...() {
              final size = sizes.putIfAbsent(b.image!, () {
                final data = _bytes(archive, b.image!);
                return data == null ? null : imageSize(data);
              });
              if (size != null) return [b.withImageSize(size.width, size.height)];
              // Keep the caption if the picture itself is unusable.
              if (b.text.isNotEmpty) {
                return [
                  Block(
                    id: b.id,
                    role: b.role,
                    text: b.text,
                    sentences: b.sentences,
                    anchor: b.anchor,
                    language: b.language,
                  ),
                ];
              }
              return const <Block>[];
            }(),
        ],
      ),
  ];
}

/// EPUB 3 `properties="cover-image"`, else EPUB 2 `<meta name="cover">`.
String? _coverPath(
  XmlDocument opf,
  Map<String, ({String href, String media, String properties})> manifest,
) {
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() == 'item' &&
        (el.getAttribute('properties') ?? '').contains('cover-image')) {
      final id = el.getAttribute('id');
      if (id != null && manifest[id] != null) return manifest[id]!.href;
    }
  }
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() == 'meta' && el.getAttribute('name') == 'cover') {
      final id = el.getAttribute('content');
      final item = id == null ? null : manifest[id];
      if (item != null && item.media.startsWith('image/')) return item.href;
    }
  }
  return null;
}

Uint8List? _bytes(Archive archive, String path) {
  final f = _entry(archive, path);
  return f == null ? null : _contentOf(f);
}

/// The bytes of [paths] inside an EPUB, for the importer to store next to
/// the parsed book. Missing paths are left out.
Map<String, Uint8List> epubResources(Uint8List epub, Iterable<String> paths) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(epub, verify: false);
  } on Object {
    return const {};
  }
  return {
    for (final p in paths.toSet())
      if (_bytes(archive, p) case final data?) p: data,
  };
}

/// Every image a [book] refers to: figures and the cover.
Set<String> imagesOf(Book book) => {
      if (book.metadata.cover != null) book.metadata.cover!,
      for (final s in book.sections)
        for (final b in s.blocks)
          if (b.image != null) b.image!,
    };

/// "CHAPTER IX" in a plain div, then "The Mock Turtle's Story" as a
/// sidenote: books that never mark chapters as headings still name them in
/// their first lines. Returns "Chapter IX: The Mock Turtle's Story".
String? _chapterLineTitle(List<Block> blocks) {
  final lead = blocks.where((b) => !b.isImage && b.text.isNotEmpty).take(3).toList();
  for (var i = 0; i < lead.length; i++) {
    final t = lead[i].text;
    if (t.length > 40 || !looksLikeChapterLine(t)) continue;
    var title = t == t.toUpperCase() ? _titleCase(t) : t;
    if (i + 1 < lead.length) {
      final sub = lead[i + 1].text;
      if (sub.length <= 60 && !RegExp(r'[.!?,;]$').hasMatch(sub)) title = '$title: $sub';
    }
    return title;
  }
  return null;
}

/// "CHAPTER IX" -> "Chapter IX": roman numerals stay capitals.
String _titleCase(String s) => s.split(' ').map((w) {
      if (RegExp(r'^[IVXLCDM]+[.:]?$').hasMatch(w) || w.length <= 1) return w;
      return w[0] + w.substring(1).toLowerCase();
    }).join(' ');
