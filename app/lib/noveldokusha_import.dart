import 'dart:convert';
import 'dart:io';

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

/// A novel from a NovelDokusha backup, as its Kotlin reader wrote it: its
/// details and chapter list; the chapters' text comes after it, one at a
/// time (see [importNovelDokushaJson]).
class _NdBook {
  _NdBook(this.title, this.url, this.cover, this.description, this.lastRead, this.chapters);

  final String title;
  final String url;
  final String cover;
  final String description;
  final String? lastRead;
  final List<({String title, String url, bool read})> chapters;

  static _NdBook fromJson(Map<Object?, Object?> b) => _NdBook(
        b['title'] as String? ?? 'Untitled',
        b['url'] as String? ?? '',
        b['cover'] as String? ?? '',
        b['description'] as String? ?? '',
        b['lastReadChapter'] as String?,
        [
          for (final c in b['chapters'] as List? ?? const [])
            if (c is Map) (title: c['title'] as String? ?? '', url: c['url'] as String? ?? '', read: c['read'] == true),
        ],
      );
}

/// Bring the web novels from a NovelDokusha backup (the file of JSON lines
/// NovelDokushaImport.kt writes) into the library: details, chapter list,
/// the chapter text it had downloaded, and the place last read. Read a line
/// at a time: one book's list and one chapter's text are held at once, never
/// the whole backup.
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
  final candidates = [...await sources.installed(), ...await sources.available()];
  var chapters = 0, novels = 0, total = 0;
  final unmatched = <String>[];
  _NdImport? current;

  Future<void> finish() async {
    final c = current;
    current = null;
    if (c != null) chapters += await c.finish(store);
  }

  final lines = File(jsonPath).openRead().transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final o = jsonDecode(line);
    if (o is! Map) continue;
    if (o['v'] != null) {
      total = o['books'] as int? ?? 0;
    } else if (o['book'] is Map) {
      await finish();
      final b = _NdBook.fromJson(o['book'] as Map);
      onProgress?.call(b.title, novels, total < novels + 1 ? novels + 1 : total);
      novels++;
      current = await _NdImport.start(store, b, candidates, unmatched);
    } else if (o['body'] is Map) {
      final body = o['body'] as Map;
      final i = body['i'], text = body['text'];
      if (i is int && text is String) chapters += await current?.add(store, i, text) ?? 0;
    }
  }
  await finish();
  try {
    await File(jsonPath).delete();
  } on FileSystemException {
    // In the cache folder; Android clears it eventually.
  }
  return ImportReport(novels: novels, chapters: chapters, unmatched: unmatched);
}

/// One book being imported, while its chapters' text arrives.
class _NdImport {
  _NdImport._(this.book, this.entry);

  final _NdBook book;

  /// The web novel it became; null for a local book (an EPUB, made once all
  /// its text is here).
  final LibraryEntry? entry;

  /// A local book's chapters' text, by place.
  final _local = <int, String>{};

  static Future<_NdImport> start(
    LibraryStore store,
    _NdBook b,
    List<PluginInfo> candidates,
    List<String> unmatched,
  ) async {
    // A book NovelDokusha imported from a file: its text is all there is.
    // It comes back as the book it was (an EPUB), not a web novel.
    if (b.url.startsWith('local://')) return _NdImport._(b, null);
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
    return _NdImport._(b, await store.addWebNovel(plugin, novel));
  }

  /// Chapter [i]'s [text]: saved (a web novel's), or kept for the EPUB (a
  /// local book's). How many chapters it adds to the count.
  Future<int> add(LibraryStore store, int i, String text) async {
    if (i < 0 || i >= book.chapters.length || text.trim().isEmpty) return 0;
    final e = entry;
    if (e == null) {
      _local[i] = text;
      return 0;
    }
    if (store.hasChapter(e.id, i)) return 0;
    await store.saveChapter(e.id, i, book.chapters[i].title, _bodyToHtml(text));
    return 1;
  }

  /// The book's text has all come: a local book is made, and the place set.
  Future<int> finish(LibraryStore store) async {
    final e = entry;
    if (e == null) return _importLocalBook(store, book, _local);
    final b = book;
    // The place: NovelDokusha's last chapter, else the first unread one.
    var at = b.lastRead == null ? -1 : b.chapters.indexWhere((c) => c.url == b.lastRead);
    if (at < 0) {
      final unread = b.chapters.indexWhere((c) => !c.read);
      at = unread <= 0 ? -1 : unread;
    }
    if (at >= 0 && b.chapters.isNotEmpty) {
      await store.saveCursor(e.id, ReadingCursor(sectionIndex: at), at / b.chapters.length, where: b.chapters[at].title);
    }
    return 0;
  }
}

/// One of NovelDokusha's local books, as an EPUB made from the chapters in
/// the backup ([texts], by place) and imported like any book: an EPUB on the
/// shelf, with its chapters and NovelDokusha's place. Returns the chapters
/// that had text.
Future<int> _importLocalBook(LibraryStore store, _NdBook b, Map<int, String> texts) async {
  final title = _tidyFileName(b.title);
  final withText = [
    for (var i = 0; i < b.chapters.length; i++)
      if (texts[i] case final body? when body.trim().isNotEmpty)
        (title: b.chapters[i].title, url: b.chapters[i].url, body: body),
  ];
  // An earlier import brought it in as a web novel: that copy goes, even
  // when there is no text to bring this time (it had none to read either).
  final old = LibraryStore.webId('noveldokusha:local', b.url);
  if ((await store.list(all: true)).any((e) => e.id == old)) await store.remove(old);
  if (withText.isEmpty) return 0;

  final dir = Directory('${store.root.path}/incoming')..createSync(recursive: true);
  final file = File('${dir.path}/${title.replaceAll(RegExp(r'[^\w .-]'), '')}.epub');
  file.writeAsBytesSync(_epub(title, [for (final c in withText) (title: c.title, html: _bodyToHtml(c.body))]));
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

/// [url] as the plugin for [site] writes its paths: what it adds to its
/// site to make the address (LNReader resolves a path as site + path), so
/// "https://x.com/" takes "novel/a" and "https://x.com" takes "/novel/a".
/// A path written another way is not found again on the next check, and
/// the novel's chapters would then be matched by title alone. Unchanged
/// when [url] is not on that site.
String _relative(String url, String site) {
  final u = Uri.tryParse(url);
  final s = Uri.tryParse(site);
  if (u == null || s == null || !u.hasAuthority || _bareHost(url) != _bareHost(site)) return url;
  final full = u.hasQuery ? '${u.path}?${u.query}' : u.path;
  final base = s.path;
  if (base.isEmpty) return full.startsWith('/') ? full : '/$full';
  return full.startsWith(base) ? full.substring(base.length) : url;
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
