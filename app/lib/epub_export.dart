import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:tomevoice_document/tomevoice_document.dart' show BlockRole, Section;

import 'folders.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'secret_shelf.dart';
import 'theme.dart';
import 'ui.dart';

/// What goes into a web novel's EPUB: its details, and the chapters on the
/// phone in the novel's order, each its title and its downloaded file.
typedef EpubJob = ({
  String identifier,
  String title,
  List<String> authors,
  String language,
  String? description,
  String? publisher,
  String? site,
  String? cover,
  List<({String title, String file})> chapters,
  DateTime made,
});

/// [job] for web novel [entry]: its downloaded chapters, in order.
Future<EpubJob?> epubJobFor(LibraryStore store, LibraryEntry entry) async {
  final info = await store.webNovel(entry.id);
  if (info == null) return null;
  final dir = store.bookDir(entry.id);
  final have = store.downloadedChapters(entry.id);
  final cover = entry.shownCover;
  return (
    identifier: 'urn:tomevoice:${entry.id}',
    title: entry.title,
    authors: entry.authors,
    language: entry.language ?? languageCodeOf(info.plugin.lang) ?? 'und',
    description: info.novel.summary,
    publisher: info.plugin.name.isEmpty ? null : info.plugin.name,
    site: info.plugin.site.isEmpty ? null : info.plugin.site,
    cover: cover != null && File(cover).existsSync() ? cover : null,
    chapters: [
      for (var i = 0; i < info.chapters.length; i++)
        if (have.contains(i)) (title: info.chapters[i].name, file: '$dir/ch/$i.json'),
    ],
    made: DateTime.now(),
  );
}

/// Write [job] as an EPUB 3 at [out], off the UI thread. How many chapters
/// went in (one whose file cannot be read is left out). None: nothing is
/// left at [out], as a book with no chapter is no EPUB.
Future<int> writeEpub(EpubJob job, String out) => Isolate.run(() => writeEpubSync(job, out));

/// [writeEpub] on this thread: the zip streamed to [out] a file at a time,
/// `mimetype` first and stored as it is (as EPUB requires), then the
/// container, the package (OPF), the contents (nav, and an NCX for older
/// readers), the cover, and one XHTML page per chapter.
int writeEpubSync(EpubJob job, String out) {
  final pages = <({String title, String href})>[];
  final zip = ZipFileEncoder()..create(out, modified: job.made);
  try {
    final mime = ascii.encode('application/epub+zip');
    zip.addArchiveFile(ArchiveFile.noCompress('mimetype', mime.length, mime));
    zip.addArchiveFile(ArchiveFile.string('META-INF/container.xml', _container));
    zip.addArchiveFile(ArchiveFile.string('OEBPS/style.css', _style));
    final cover = job.cover;
    String? coverHref;
    if (cover != null) {
      try {
        final bytes = File(cover).readAsBytesSync();
        // A picture EPUB readers take, named and labelled as what it is,
        // whatever its file is called; anything else is left out.
        final ext = _imageExt(bytes);
        if (ext != null) {
          coverHref = 'cover$ext';
          zip.addArchiveFile(ArchiveFile.bytes('OEBPS/$coverHref', bytes));
        }
      } on FileSystemException {
        coverHref = null;
      }
    }
    for (final c in job.chapters) {
      Section section;
      try {
        section = Section.fromJson(Map<String, Object?>.from(jsonDecode(File(c.file).readAsStringSync()) as Map));
      } on Object {
        continue;
      }
      final href = 'text/c${(pages.length + 1).toString().padLeft(4, '0')}.xhtml';
      zip.addArchiveFile(ArchiveFile.string('OEBPS/$href', chapterXhtml(section, title: c.title, language: job.language)));
      pages.add((title: c.title, href: href));
    }
    zip.addArchiveFile(ArchiveFile.string('OEBPS/nav.xhtml', _nav(job, pages)));
    zip.addArchiveFile(ArchiveFile.string('OEBPS/toc.ncx', _ncx(job, pages)));
    zip.addArchiveFile(ArchiveFile.string('OEBPS/content.opf', _opf(job, pages, coverHref)));
  } finally {
    zip.closeSync();
  }
  if (pages.isEmpty) {
    // An empty spine, contents and NCX: not a book any reader opens.
    try {
      File(out).deleteSync();
    } on FileSystemException {
      // Never made.
    }
  }
  return pages.length;
}

/// One chapter as an XHTML page: its heading (its own first line when that
/// is the heading, else its title), then its paragraphs as the reader shows
/// them.
String chapterXhtml(Section s, {required String title, required String language}) {
  final out = StringBuffer()..write(_head(_x(title), language, stylesheet: '../style.css'));
  out.write('<section epub:type="chapter">\n');
  final first = s.blocks.indexWhere((b) => b.text.trim().isNotEmpty);
  var headed = first < 0 || s.blocks[first].role != BlockRole.heading;
  if (headed) out.write('<h1>${_x(title)}</h1>\n');
  var list = false;
  for (final b in s.blocks) {
    final text = b.text.trim();
    if (text.isEmpty) continue;
    final body = _lines(text);
    if (b.role == BlockRole.listItem) {
      if (!list) out.write('<ul>\n');
      list = true;
      out.write('<li>$body</li>\n');
      continue;
    }
    if (list) out.write('</ul>\n');
    list = false;
    switch (b.role) {
      case BlockRole.heading:
        out.write(headed ? '<h2>$body</h2>\n' : '<h1>$body</h1>\n');
        headed = true;
      case BlockRole.quote:
        out.write('<blockquote><p>$body</p></blockquote>\n');
      case BlockRole.code:
        out.write('<pre>${_x(text)}</pre>\n');
      case BlockRole.footnote:
        out.write('<p class="note">$body</p>\n');
      case BlockRole.caption || BlockRole.figure:
        out.write('<p class="caption">$body</p>\n');
      case BlockRole.pageNumber || BlockRole.runningHeader:
        break;
      default:
        out.write('<p>$body</p>\n');
    }
  }
  if (list) out.write('</ul>\n');
  out.write('</section>\n</body>\n</html>\n');
  return out.toString();
}

/// "Shadow Slave.epub": no characters a folder refuses.
String epubFileName(String title) {
  final clean = String.fromCharCodes(title.runes.where((r) => r >= 0x20 && !'\\/:*?"<>|'.runes.contains(r)))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final short = clean.length > 80 ? clean.substring(0, 80).trim() : clean;
  return '${short.isEmpty ? 'Novel' : short}.epub';
}

/// What to say once it is saved: its name, unless the novel is on a secret
/// shelf that has shut meanwhile (the app was left while it was made).
String epubSaved({required String file, required String folder, required bool hidden}) =>
    hidden ? 'Saved the EPUB to $folder.' : 'Saved $file to $folder.';

/// Export web novel [entry]'s downloaded chapters as an EPUB, to a folder
/// the reader picks (remembered for next time, as quotes' Markdown is). A
/// novel on a shut secret shelf asks for the phone's lock first: the sheet
/// and the file are named after it.
Future<void> exportNovelEpub(BuildContext context, LibraryStore store, LibraryEntry entry) async {
  if (!await SecretShelf.mayShow(context, store, entry.id) || !context.mounted) return;
  final job = await epubJobFor(store, entry);
  if (!context.mounted || job == null) return;
  final count = job.chapters.length;
  final total = (await store.webNovel(entry.id))?.chapters.length ?? count;
  if (!context.mounted) return;
  if (count == 0) {
    showSnack(context, 'Download some chapters first: the EPUB holds the chapters on the phone.');
    return;
  }
  final prefs = ListeningPrefs.loaded ?? ListeningPrefs.memory;
  final known = prefs.exportFolder;
  final name = epubFileName(entry.title);
  final how = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            'Export as EPUB',
            subtitle: count != total
                ? '$count of $total chapters: those on the phone'
                : count == 1
                    ? 'Its one chapter'
                    : 'All $count chapters',
          ),
          SheetAction(
            icon: Icons.save_alt_rounded,
            label: known == null ? 'Save as a file' : 'Save to ${known.name}',
            detail: known == null ? 'In a folder on your phone or in Drive' : name,
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          if (known != null)
            SheetAction(
              icon: Icons.drive_folder_upload_outlined,
              label: 'Save to another folder',
              onTap: () => Navigator.pop(ctx, 'other'),
            ),
          const SizedBox(height: Gap.s),
        ],
      ),
    ),
  );
  if (how == null || !context.mounted) return;
  const folders = Folders();
  var folder = how == 'save' ? known : null;
  Directory? tmp;
  final navigator = Navigator.of(context, rootNavigator: true);
  // While it is made: its own route, taken away by itself (leaving the app
  // with a secret shelf open takes every page away first).
  final making = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: Gap.l),
            Expanded(child: Text('Making the EPUB…')),
          ],
        ),
      ),
    ),
  );
  void done() {
    if (making.isActive) navigator.removeRoute(making);
  }

  try {
    folder ??= await folders.pick();
    if (folder == null || !context.mounted) return;
    if (folder.uri != known?.uri) {
      prefs.exportFolder = folder;
      prefs.save();
    }
    unawaited(navigator.push(making));
    tmp = await Directory.systemTemp.createTemp('tv_epub');
    final file = '${tmp.path}/novel.epub';
    if (await writeEpub(job, file) == 0) {
      // Not one chapter on the phone could be read: no book to save.
      done();
      if (context.mounted) {
        showSnack(context, 'No EPUB was made: none of the chapters on the phone could be read. Download them again.',
            long: true);
      }
      return;
    }
    final saved = await folders.copyFile(folder, name, file, mime: 'application/epub+zip');
    done();
    if (context.mounted) {
      final hidden = store.isSecret(entry.id) && !LibraryStore.secretOpen.value;
      showSnack(context, epubSaved(file: saved, folder: folder.name, hidden: hidden));
    }
  } on PlatformException catch (e) {
    // The folder was taken away (or deleted): asked for again next time.
    if (e.code == 'FOLDER' && prefs.exportFolder?.uri == folder?.uri) {
      prefs.exportFolder = null;
      prefs.save();
    }
    done();
    if (context.mounted) showSnack(context, 'Could not save the EPUB: ${e.message ?? e.code}', long: true);
  } on Object catch (e) {
    done();
    if (context.mounted) showSnack(context, 'Could not make the EPUB: $e', long: true);
  } finally {
    done();
    try {
      await tmp?.delete(recursive: true);
    } on FileSystemException {
      // The cache is emptied by Android in time.
    }
  }
}

// ----------------------------------------------------------------- parts

/// [s] safe in XML: its characters escaped, and those XML does not allow
/// (control characters, lone surrogates) left out.
String _x(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x26) {
      out.write('&amp;');
    } else if (r == 0x3C) {
      out.write('&lt;');
    } else if (r == 0x3E) {
      out.write('&gt;');
    } else if (r == 0x22) {
      out.write('&quot;');
    } else if (r == 0x9 || r == 0xA || r == 0xD || (r >= 0x20 && r <= 0xD7FF) || (r >= 0xE000 && r <= 0xFFFD) || r >= 0x10000) {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

/// A paragraph's lines, each kept: line breaks inside it as `<br/>`.
String _lines(String text) => text.split('\n').map((l) => _x(l.trim())).where((l) => l.isNotEmpty).join('<br/>');

String _head(String title, String language, {String? stylesheet}) => '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE html>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" '
    'lang="${_x(language)}" xml:lang="${_x(language)}">\n'
    '<head>\n<meta charset="UTF-8"/>\n<title>$title</title>\n'
    '${stylesheet == null ? '' : '<link rel="stylesheet" type="text/css" href="$stylesheet"/>\n'}'
    '</head>\n<body>\n';

const _container = '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '<rootfiles>\n<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
    '</rootfiles>\n</container>\n';

const _style = 'body { margin: 0 5%; line-height: 1.5; }\n'
    'h1 { font-size: 1.4em; margin: 1.5em 0 1em; }\n'
    'h2 { font-size: 1.15em; }\n'
    'p { margin: 0 0 0.8em; }\n'
    'blockquote { margin: 0 0 0.8em 1.5em; }\n'
    'p.note, p.caption { font-size: 0.85em; }\n'
    'pre { white-space: pre-wrap; }\n';

String _nav(EpubJob job, List<({String title, String href})> pages) {
  final out = StringBuffer()..write(_head(_x(job.title), job.language, stylesheet: 'style.css'));
  out.write('<nav epub:type="toc" id="toc">\n<h1>Contents</h1>\n<ol>\n');
  for (final p in pages) {
    out.write('<li><a href="${p.href}">${_x(p.title)}</a></li>\n');
  }
  out.write('</ol>\n</nav>\n</body>\n</html>\n');
  return out.toString();
}

String _ncx(EpubJob job, List<({String title, String href})> pages) {
  final out = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        '<head>\n<meta name="dtb:uid" content="${_x(job.identifier)}"/>\n</head>\n'
        '<docTitle><text>${_x(job.title)}</text></docTitle>\n<navMap>\n');
  for (var i = 0; i < pages.length; i++) {
    out.write('<navPoint id="n${i + 1}" playOrder="${i + 1}"><navLabel><text>${_x(pages[i].title)}</text></navLabel>'
        '<content src="${pages[i].href}"/></navPoint>\n');
  }
  out.write('</navMap>\n</ncx>\n');
  return out.toString();
}

String _opf(EpubJob job, List<({String title, String href})> pages, String? cover) {
  final t = job.made.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final modified = '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
  final out = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" '
        'xml:lang="${_x(job.language)}">\n'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '<dc:identifier id="book-id">${_x(job.identifier)}</dc:identifier>\n'
        '<dc:title>${_x(job.title)}</dc:title>\n'
        '<dc:language>${_x(job.language)}</dc:language>\n');
  for (final a in job.authors) {
    if (a.trim().isNotEmpty) out.write('<dc:creator>${_x(a.trim())}</dc:creator>\n');
  }
  if (job.publisher case final p?) out.write('<dc:publisher>${_x(p)}</dc:publisher>\n');
  if (job.site case final s?) out.write('<dc:source>${_x(s)}</dc:source>\n');
  if (job.description case final d? when d.trim().isNotEmpty) out.write('<dc:description>${_x(d.trim())}</dc:description>\n');
  out.write('<meta property="dcterms:modified">$modified</meta>\n');
  if (cover != null) out.write('<meta name="cover" content="cover-image"/>\n');
  out.write('</metadata>\n<manifest>\n'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
      '<item id="style" href="style.css" media-type="text/css"/>\n');
  if (cover != null) {
    out.write('<item id="cover-image" href="$cover" media-type="${_imageType(cover)}" properties="cover-image"/>\n');
  }
  for (var i = 0; i < pages.length; i++) {
    out.write('<item id="c${i + 1}" href="${pages[i].href}" media-type="application/xhtml+xml"/>\n');
  }
  out.write('</manifest>\n<spine toc="ncx">\n');
  for (var i = 0; i < pages.length; i++) {
    out.write('<itemref idref="c${i + 1}"/>\n');
  }
  out.write('</spine>\n</package>\n');
  return out.toString();
}

/// The extension of a picture EPUB readers take (JPEG, PNG, GIF or WebP),
/// by what [bytes] begin with; null for anything else (an HTML error page
/// saved as the cover, an AVIF, an SVG).
String? _imageExt(List<int> bytes) {
  bool at(int offset, List<int> magic) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return '.jpg';
  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return '.png';
  if (at(0, ascii.encode('GIF87a')) || at(0, ascii.encode('GIF89a'))) return '.gif';
  if (at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WEBP'))) return '.webp';
  return null;
}

String _imageType(String href) => switch (href.substring(href.lastIndexOf('.'))) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      _ => 'image/jpeg',
    };
