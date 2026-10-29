import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';

import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;

import 'library_store.dart';
import 'speech_service.dart' show PickedFile;
import 'sources/models.dart';
import 'sources/source_store.dart';

/// What an import brought across.
class ImportReport {
  const ImportReport({required this.novels, required this.chapters, required this.unmatched});

  final int novels;

  /// Chapters whose text came along, readable offline at once.
  final int chapters;

  /// Novels whose site has no source installed or listed: readable from the
  /// chapters that came along, but not updated.
  final List<String> unmatched;
}

/// A novel from a NovelDokusha backup, as its Kotlin reader wrote it.
class _NdBook {
  _NdBook(this.title, this.url, this.cover, this.description, this.lastRead, this.chapters);

  final String title;
  final String url;
  final String cover;
  final String description;
  final String? lastRead;
  final List<({String title, String url, bool read, String? body})> chapters;
}

/// Bring the web novels from a NovelDokusha backup's JSON (see
/// NovelDokushaImport.kt) into the library: details, chapter list, the
/// chapter text it had downloaded, and the place last read.
///
/// Each novel is matched to an installed (or listed) source by its website,
/// so updates keep working; one with no source is still imported and reads
/// from what came along.
Future<ImportReport> importNovelDokushaJson(
  LibraryStore store,
  SourceStore sources,
  String jsonPath, {
  void Function(String title, int done, int total)? onProgress,
}) async {
  final books = await Isolate.run(() => _parse(jsonPath));
  final candidates = [...await sources.installed(), ...await sources.available()];
  var chapters = 0;
  final unmatched = <String>[];
  for (var n = 0; n < books.length; n++) {
    final b = books[n];
    onProgress?.call(b.title, n, books.length);
    // A book NovelDokusha imported from a file: its text is all there is.
    // It comes back as the book it was (an EPUB), not a web novel.
    if (b.url.startsWith('local://')) {
      chapters += await _importLocalBook(store, b);
      continue;
    }
    final host = _bareHost(b.url);
    final plugin = candidates.where((p) => _bareHost(p.site) == host).firstOrNull ??
        PluginInfo(
          id: 'noveldokusha:$host',
          name: Uri.tryParse(b.url)?.host ?? host,
          site: 'https://${Uri.tryParse(b.url)?.host ?? host}/',
          lang: 'English',
          version: '0',
          url: '',
        );
    if (plugin.url.isEmpty) unmatched.add(b.title);
    String rel(String url) => _relative(url, plugin.site);
    final novel = SourceNovel(
      path: rel(b.url),
      name: b.title,
      cover: b.cover.isEmpty ? null : b.cover,
      summary: b.description.isEmpty ? null : b.description,
      chapters: [for (final c in b.chapters) ChapterItem(name: c.title, path: rel(c.url))],
    );
    final entry = await store.addWebNovel(plugin, novel);
    for (var i = 0; i < b.chapters.length; i++) {
      final body = b.chapters[i].body;
      if (body == null || body.trim().isEmpty || store.hasChapter(entry.id, i)) continue;
      await store.saveChapter(entry.id, i, b.chapters[i].title, _bodyToHtml(body));
      chapters++;
    }
    // The place: NovelDokusha's last chapter, else the first unread one.
    var at = b.lastRead == null ? -1 : b.chapters.indexWhere((c) => c.url == b.lastRead);
    if (at < 0) {
      final unread = b.chapters.indexWhere((c) => !c.read);
      at = unread <= 0 ? -1 : unread;
    }
    if (at >= 0 && b.chapters.isNotEmpty) {
      await store.saveCursor(entry.id, ReadingCursor(sectionIndex: at), at / b.chapters.length,
          where: b.chapters[at].title);
    }
  }
  try {
    await File(jsonPath).delete();
  } on FileSystemException {
    // In the cache folder; Android clears it eventually.
  }
  return ImportReport(novels: books.length, chapters: chapters, unmatched: unmatched);
}

List<_NdBook> _parse(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map;
  return [
    for (final b in raw['books'] as List? ?? const [])
      if (b is Map)
        _NdBook(
          b['title'] as String? ?? 'Untitled',
          b['url'] as String? ?? '',
          b['cover'] as String? ?? '',
          b['description'] as String? ?? '',
          b['lastReadChapter'] as String?,
          [
            for (final c in b['chapters'] as List? ?? const [])
              if (c is Map)
                (
                  title: c['title'] as String? ?? '',
                  url: c['url'] as String? ?? '',
                  read: c['read'] == true,
                  body: c['body'] as String?,
                ),
          ],
        ),
  ];
}

/// One of NovelDokusha's local books, as an EPUB made from the chapters in
/// the backup and imported like any book: an EPUB on the shelf, with its
/// chapters and NovelDokusha's place. Returns the chapters that had text.
Future<int> _importLocalBook(LibraryStore store, _NdBook b) async {
  final title = _tidyFileName(b.title);
  final withText = [
    for (final c in b.chapters)
      if (c.body != null && c.body!.trim().isNotEmpty) c,
  ];
  // An earlier import brought it in as a web novel: that copy goes, even
  // when there is no text to bring this time (it had none to read either).
  final old = LibraryStore.webId('noveldokusha:local', b.url);
  if ((await store.list(all: true)).any((e) => e.id == old)) await store.remove(old);
  if (withText.isEmpty) return 0;

  final dir = Directory('${store.root.path}/incoming')..createSync(recursive: true);
  final file = File('${dir.path}/${title.replaceAll(RegExp(r'[^\w .-]'), '')}.epub');
  file.writeAsBytesSync(_epub(title, [for (final c in withText) (title: c.title, html: _bodyToHtml(c.body!))]));
  final entry = await store.importFile(PickedFile(path: file.path, name: '$title.epub', mime: 'application/epub+zip'));

  // The place: NovelDokusha's last chapter, among those with text.
  final at = b.lastRead == null ? -1 : withText.indexWhere((c) => c.url == b.lastRead);
  if (at > 0) {
    await store.saveCursor(entry.id, ReadingCursor(sectionIndex: at), at / withText.length, where: withText[at].title);
  }
  return withText.length;
}

/// A plain EPUB 3: one XHTML file per chapter, in order, and its contents.
List<int> _epub(String title, List<({String title, String html})> chapters) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  String page(String t, String body) => '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>${esc(t)}</title></head>'
      '<body>$body</body></html>';
  final archive = Archive()
    ..add(ArchiveFile.string('mimetype', 'application/epub+zip')..compression = CompressionType.none)
    ..add(ArchiveFile.string(
        'META-INF/container.xml',
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>'));
  for (var i = 0; i < chapters.length; i++) {
    final c = chapters[i];
    archive.add(ArchiveFile.string('OEBPS/c$i.xhtml', page(c.title, '<h1>${esc(c.title)}</h1>${c.html}')));
  }
  archive.add(ArchiveFile.string(
      'OEBPS/nav.xhtml',
      '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
          'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>'
          '<nav epub:type="toc"><ol>'
          '${[for (var i = 0; i < chapters.length; i++) '<li><a href="c$i.xhtml">${esc(chapters[i].title)}</a></li>'].join()}'
          '</ol></nav></body></html>'));
  archive.add(ArchiveFile.string(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
          'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:identifier id="id">noveldokusha:${esc(title)}</dc:identifier><dc:title>${esc(title)}</dc:title>'
          '<dc:language>en</dc:language></metadata><manifest>'
          '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
          '${[for (var i = 0; i < chapters.length; i++) '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>'].join()}'
          '</manifest><spine>${[for (var i = 0; i < chapters.length; i++) '<itemref idref="c$i"/>'].join()}</spine>'
          '</package>'));
  return ZipEncoder().encodeBytes(archive);
}

/// "A_Game_of_Thrones_A_Song_of_Ice_and_Fire_1.epub" as a title.
String _tidyFileName(String name) {
  var t = name.replaceAll(RegExp(r'\.(epub|pdf|txt|mobi|azw3?)$', caseSensitive: false), '');
  t = t.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? name : t;
}

String _bareHost(String url) {
  final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return h.startsWith('www.') ? h.substring(4) : h;
}

/// [url] relative to [site] when it is on that site (as LNReader plugins
/// expect their paths), otherwise unchanged.
String _relative(String url, String site) {
  final u = Uri.tryParse(url);
  final s = Uri.tryParse(site);
  if (u == null || s == null || _bareHost(url) != _bareHost(site)) return url;
  var path = u.path;
  if (path.startsWith('/')) path = path.substring(1);
  return u.hasQuery ? '$path?${u.query}' : path;
}

/// NovelDokusha keeps chapter text as plain paragraphs separated by blank
/// lines, with pictures as `<img …>` markers; the reader wants HTML.
String _bodyToHtml(String body) {
  final out = StringBuffer();
  for (final para in body.split(RegExp(r'\n\s*\n|\r\n\s*\r\n'))) {
    final t = para.trim();
    if (t.isEmpty || t.startsWith('<img')) continue;
    out
      ..write('<p>')
      ..write(t.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\n', ' '))
      ..write('</p>');
  }
  return out.toString();
}
