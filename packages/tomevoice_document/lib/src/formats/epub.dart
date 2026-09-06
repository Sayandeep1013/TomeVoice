import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../build.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

Book parseEpub(Uint8List bytes, {required String id, String? filename}) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (e) {
    throw ParseException('Not a readable EPUB (zip failed): $e');
  }

  final names = {for (final f in archive.files) f.name.replaceAll('\\', '/')};

  if (names.contains('META-INF/encryption.xml')) {
    throw const EncryptedDocumentException(
      'This book is DRM-protected. TomeVoice cannot open encrypted files.',
    );
  }

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
  final manifest = _manifest(opf, opfDir);
  final spineHrefs = _spine(opf, manifest);

  resetBlockIds();
  final sections = <Section>[];
  for (var i = 0; i < spineHrefs.length; i++) {
    final href = spineHrefs[i];
    final html = _read(archive, href);
    if (html == null) continue;
    final blocks = blocksFromHtml(
      html,
      language: metadata.language,
      href: href,
    );
    if (blocks.isEmpty) continue;
    sections.add(Section(
      id: 's$i',
      index: sections.length,
      href: href,
      title: _firstHeading(blocks),
      blocks: blocks,
    ));
  }

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

  final toc = _toc(archive, opf, opfDir, manifest, indexed);
  final book = Book(
    id: id,
    metadata: metadata,
    sections: indexed,
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

String? _read(Archive archive, String path) {
  final normalised = path.replaceAll('\\', '/');
  for (final f in archive.files) {
    if (f.name.replaceAll('\\', '/') == normalised && f.isFile) {
      final data = f.readBytes();
      if (data == null || data.isEmpty) return null;
      return utf8.decode(data, allowMalformed: true);
    }
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
  );
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
) {
  final out = <String, ({String href, String media})>{};
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'item') continue;
    final id = el.getAttribute('id');
    final href = el.getAttribute('href');
    if (id == null || href == null) continue;
    out[id] = (
      href: zipJoin(opfDir, href),
      media: (el.getAttribute('media-type') ?? '').toLowerCase(),
    );
  }
  return out;
}

List<String> _spine(
  XmlDocument opf,
  Map<String, ({String href, String media})> manifest,
) {
  const readable = {
    'application/xhtml+xml',
    'text/html',
    'application/xml',
    'text/xml',
  };
  final hrefs = <String>[];
  for (final el in opf.descendants.whereType<XmlElement>()) {
    if (el.localName.toLowerCase() != 'itemref') continue;
    final idref = el.getAttribute('idref');
    if (idref == null) continue;
    final item = manifest[idref];
    if (item == null) continue;
    if (item.media.isNotEmpty && !readable.contains(item.media)) continue;
    hrefs.add(item.href);
  }
  return hrefs;
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
    final resolved = zipJoin(opfDir, href.split('#').first);
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
  final out = <TocEntry>[];
  for (final a in doc.descendants.whereType<XmlElement>()) {
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
