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
  } catch (e) {
    throw ParseException('Not a readable EPUB (zip failed): $e');
  }

  final names = {for (final f in archive.files) f.name.replaceAll('\\', '/')};

  final container = _read(archive, 'META-INF/container.xml');
  if (container == null) {
    throw const ParseException('EPUB is missing META-INF/container.xml');
  }

  final opfPath = _opfPath(container);
  final opfDir = _dirOf(opfPath);
  final opfXml = _read(archive, opfPath);
  if (opfXml == null) {
    throw ParseException('EPUB package document not found: $opfPath');
  }

  late XmlDocument opf;
  try {
    opf = XmlDocument.parse(opfXml);
  } on XmlException catch (e) {
    throw ParseException('Broken package document: $e');
  }

  final metadata = _metadata(opf, filename);
  final manifest = _manifest(opf, opfDir, names);
  _refuseDrm(archive, manifest);
  final spine = _spine(opf, manifest);
  final spineHrefs = [for (final s in spine) s.href];

  // Each spine document's text, read once. Before any is parsed, their
  // marker links say which ids in later documents are notes (an endnotes
  // file at the back): a link that points back is a note's way home.
  final texts = <String?>[for (final h in spineHrefs) _read(archive, h, legacy)];
  final notes = _noteTargets(spineHrefs, texts);

  resetBlockIds();
  final sections = <Section>[];
  final aside = <Section>[];
  for (var i = 0; i < spineHrefs.length; i++) {
    final href = spineHrefs[i];
    final html = texts[i];
    texts[i] = null;
    if (html == null) continue;
    final blocks = blocksFromHtml(
      html,
      language: metadata.language,
      href: href,
      notes: notes[href] ?? const {},
      hasFile: names.contains,
    );
    if (blocks.isEmpty) continue;
    final section = Section(
      id: 's$i',
      index: sections.length,
      href: href,
      title: _firstHeading(blocks) ?? _chapterLineTitle(blocks),
      blocks: blocks,
    );
    // linear="no" (answers, notes, pop-ups) is not part of the reading
    // order: it goes to the end, where the contents can still reach it.
    // One with nothing to say (a cover picture) keeps its place.
    if (!spine[i].linear && blocks.any((b) => b.speakable)) {
      aside.add(section);
    } else {
      sections.add(section);
    }
  }
  sections.addAll(aside);

  if (sections.isEmpty) {
    throw const ParseException('EPUB has no readable text in its spine.');
  }

  // Re-index after dropped empty spine items.
  final indexed = [
    for (var i = 0; i < sections.length; i++)
      Section(
        id: 's$i',
        index: i,
        href: sections[i].href,
        title: sections[i].title,
        blocks: sections[i].blocks,
      ),
  ];

  final withImages = _measureImages(archive, indexed);
  final toc = _toc(archive, opf, opfDir, manifest, withImages);
  // Many EPUBs never declare a cover, or declare one that is not in the
  // archive; their first picture is the cover.
  final declared = _coverPath(opf, manifest);
  final cover = declared != null && _bytes(archive, declared) != null
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
void _refuseDrm(Archive archive, Map<String, ({String href, String media})> manifest) {
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

/// Spine path -> ids in it that marker links in earlier documents point at.
Map<String, Set<String>> _noteTargets(List<String> spine, List<String?> texts) {
  final position = {for (var i = 0; i < spine.length; i++) spine[i]: i};
  final out = <String, Set<String>>{};
  for (var i = 0; i < spine.length; i++) {
    final html = texts[i];
    if (html == null) continue;
    for (final link in markerLinks(html)) {
      final hash = link.indexOf('#');
      final path = link.substring(0, hash);
      if (path.isEmpty || path.contains(':')) continue;
      final target = zipJoin(_dirOf(spine[i]), _decodeHref(path));
      final at = position[target];
      if (at != null && at > i) (out[target] ??= {}).add(_decodeHref(link.substring(hash + 1)));
    }
  }
  return out;
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
  final data = f.readBytes();
  if (data == null || data.isEmpty) return null;
  return decodeBytes(data, markup: true, legacy: legacy);
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
  final doc = XmlDocument.parse(containerXml);
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() == 'rootfile') {
      final path = el.getAttribute('full-path');
      if (path != null && path.isNotEmpty) return path;
    }
  }
  throw const ParseException('container.xml has no rootfile');
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

Map<String, ({String href, String media})> _manifest(
  XmlDocument opf,
  String opfDir,
  Set<String> names,
) {
  final out = <String, ({String href, String media})>{};
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'item') continue;
    final id = el.getAttribute('id');
    final href = el.getAttribute('href');
    if (id == null || href == null) continue;
    out[id] = (
      href: _resolvePath(opfDir, href, names),
      media: (el.getAttribute('media-type') ?? '').toLowerCase(),
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
  Map<String, ({String href, String media})> manifest,
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

List<TocEntry> _toc(
  Archive archive,
  XmlDocument opf,
  String opfDir,
  Map<String, ({String href, String media})> manifest,
  List<Section> sections,
) {
  final byHref = <String, int>{
    for (final s in sections)
      if (s.href != null) s.href!: s.index,
  };

  int? sectionFor(String href) {
    final resolved = zipJoin(opfDir, _decodeHref(href.split('#').first));
    if (byHref.containsKey(resolved)) return byHref[resolved];
    for (final e in byHref.entries) {
      if (e.key.endsWith('/$resolved') || e.key.endsWith(resolved)) {
        return e.value;
      }
    }
    return null;
  }

  final navItem = manifest.values.where((i) =>
      i.media.contains('xhtml') &&
      (_read(archive, i.href)?.contains('epub:type="toc"') ?? false));
  for (final nav in navItem) {
    final html = _read(archive, nav.href);
    if (html == null) continue;
    final entries = _tocFromNav(html, sectionFor);
    if (entries.isNotEmpty) return entries;
  }

  for (final item in manifest.values) {
    if (!item.media.contains('dtbncx') && !item.href.endsWith('.ncx')) continue;
    final ncx = _read(archive, item.href);
    if (ncx == null) continue;
    final entries = _tocFromNcx(ncx, sectionFor);
    if (entries.isNotEmpty) return entries;
  }

  return [
    for (final s in sections)
      TocEntry(title: s.displayTitle, sectionIndex: s.index, href: s.href),
  ];
}

List<TocEntry> _tocFromNcx(String ncx, int? Function(String href) sectionFor) {
  late XmlDocument doc;
  try {
    doc = XmlDocument.parse(ncx);
  } on XmlException {
    return const [];
  }
  final out = <TocEntry>[];
  for (final point in doc.descendants.whereType<XmlElement>()) {
    if (point.localName.toLowerCase() != 'navpoint') continue;
    String title = '';
    String href = '';
    for (final child in point.childElements) {
      if (child.localName.toLowerCase() == 'navlabel') {
        title = collapseWhitespace(child.innerText);
      }
      if (child.localName.toLowerCase() == 'content') {
        href = child.getAttribute('src') ?? '';
      }
    }
    if (title.isEmpty) continue;
    out.add(TocEntry(
      title: title,
      sectionIndex: sectionFor(href) ?? (out.isEmpty ? 0 : out.last.sectionIndex),
      href: href,
    ));
  }
  return out;
}

List<TocEntry> _tocFromNav(String html, int? Function(String href) sectionFor) {
  late XmlDocument doc;
  try {
    doc = XmlDocument.parse(
      html.contains('<html') ? html : '<html>$html</html>',
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
  final navs = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.localName.toLowerCase() == 'nav')
      .toList();
  final toc = navs.where((n) => typeOf(n).contains('toc')).toList();
  final roots = toc.isNotEmpty
      ? toc
      : navs.where((n) => !typeOf(n).contains('page-list') && !typeOf(n).contains('landmarks')).toList();
  final links = roots.isNotEmpty
      ? roots.expand((n) => n.descendants.whereType<XmlElement>())
      : doc.descendants.whereType<XmlElement>();
  final out = <TocEntry>[];
  for (final a in links) {
    if (a.localName.toLowerCase() != 'a') continue;
    final href = a.getAttribute('href') ?? '';
    final title = collapseWhitespace(a.innerText);
    if (title.isEmpty || href.isEmpty) continue;
    out.add(TocEntry(
      title: title,
      sectionIndex: sectionFor(href) ?? (out.isEmpty ? 0 : out.last.sectionIndex),
      href: href,
    ));
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
  Map<String, ({String href, String media})> manifest,
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
  final f = archive.findFile(path);
  final data = f?.readBytes();
  return data == null ? null : Uint8List.fromList(data);
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
