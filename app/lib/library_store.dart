import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:tomevoice_document/tomevoice_document.dart';

import 'sources/models.dart';
import 'sources/net.dart';
import 'speech_service.dart';

/// Bumped when ingestion improves enough that stored books should be parsed
/// again from their source file (v2: multilingual sentences, compact JSON;
/// v3: pictures and covers from EPUBs, page numbers in PDFs; v4: toc nav
/// only, chapters named from first lines, drop caps, Gutenberg apparatus;
/// v5: the book's description, shown on its page).
const _parsedVersion = 5;

/// On-device library: copied files, parsed books, reading positions.
///
/// JSON on disk rather than Drift. Everything heavy (parsing, JSON, building
/// the reading layout) runs on a background isolate: on the UI isolate it was
/// a 2.5 second freeze when opening a long EPUB.
class LibraryStore {
  LibraryStore(this.root);

  final Directory root;

  /// Bumped after every write to the index, so the shelf can refresh when a
  /// reader saves its place after the shelf has already re-read the list.
  final changes = ValueNotifier<int>(0);

  static const _svc = SpeechService();

  Directory get _booksDir => Directory('${root.path}/books');
  File get _indexFile => File('${root.path}/library.json');

  Future<void> ensure() async {
    await _booksDir.create(recursive: true);
  }

  // Categories as last read or written; every public method reads the index
  // first, so these are current whenever _write runs.
  List<Category> _categories = Category.defaults;
  String _defaultCategory = Category.defaults.first.id;

  /// Books, most recently opened first.
  Future<List<LibraryEntry>> list() async => (await index()).entries;

  /// Books plus the shelf's categories.
  Future<LibraryIndex> index() async {
    await ensure();
    var entries = <LibraryEntry>[];
    if (await _indexFile.exists()) {
      try {
        final raw = jsonDecode(await _indexFile.readAsString());
        if (raw is Map) {
          entries = [
            for (final b in raw['books'] as List? ?? const [])
              LibraryEntry.fromJson(Map<String, Object?>.from(b as Map)),
          ];
          final cats = [
            for (final c in raw['categories'] as List? ?? const [])
              if (c is Map) Category.fromJson(Map<String, Object?>.from(c)),
          ];
          _categories = cats.isEmpty ? Category.defaults : cats;
          final d = raw['defaultCategory'] as String?;
          _defaultCategory = _categories.any((c) => c.id == d) ? d! : _categories.first.id;
        }
      } on FormatException {
        entries = [];
      }
    }
    entries.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
    return LibraryIndex(
      entries: entries,
      categories: _categories,
      defaultCategory: _defaultCategory,
    );
  }

  Future<void> _write(List<LibraryEntry> entries) async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'categories': [for (final c in _categories) c.toJson()],
        'defaultCategory': _defaultCategory,
        'books': [for (final e in entries) e.toJson()],
      }),
    );
    await tmp.rename(_indexFile.path);
    changes.value++;
  }

  // ------------------------------------------------------------ categories

  /// Replace the category list (rename, reorder, add, delete). Books in a
  /// category that no longer exists move to the first one.
  Future<void> saveCategories(List<Category> categories, {String? defaultCategory}) async {
    if (categories.isEmpty) return;
    final entries = await list();
    _categories = List.unmodifiable(categories);
    final d = defaultCategory ?? _defaultCategory;
    _defaultCategory = categories.any((c) => c.id == d) ? d : categories.first.id;
    final ids = {for (final c in categories) c.id};
    await _write([
      for (final e in entries)
        e.category == null || ids.contains(e.category) ? e : e.copyWith(category: categories.first.id),
    ]);
  }

  /// A new category at the end of the list.
  Future<Category> addCategory(String name) async {
    final idx = await index();
    final cat = Category(Category.newId(name), name);
    await saveCategories([...idx.categories, cat]);
    return cat;
  }

  /// Put [ids] in [categoryId].
  Future<void> moveBooks(Set<String> ids, String categoryId) async {
    final entries = await list();
    await _write([
      for (final e in entries) ids.contains(e.id) ? e.copyWith(category: categoryId) : e,
    ]);
  }

  // ------------------------------------------------------------ web novels

  /// A web novel's id: stable for the same novel on the same source.
  static String webId(String pluginId, String path) =>
      'web-${bookIdOf(Uint8List.fromList(utf8.encode('$pluginId|$path')))}';

  /// Add a web novel from [plugin] (details and chapter list in [novel]).
  /// Its cover is fetched once; chapters are fetched as they are read.
  Future<LibraryEntry> addWebNovel(PluginInfo plugin, SourceNovel novel, {String? category}) async {
    await ensure();
    final id = webId(plugin.id, novel.path);
    final dir = Directory(bookDir(id))..createSync(recursive: true);
    final info = WebNovelInfo(plugin: plugin, novel: novel, chapters: novel.chapters, checkedAt: DateTime.now());
    await File('${dir.path}/novel.json').writeAsString(jsonEncode(info.toJson()));
    String? cover;
    final url = novel.cover;
    if (url != null && url.startsWith('http')) {
      try {
        final r = await Net.instance.request(url, headers: {'Referer': plugin.site});
        if (r.ok && r.bytes.length > 200) {
          final img = Directory('${dir.path}/img')..createSync(recursive: true);
          final f = File('${img.path}/cover${_imageExt(r.headers['content-type'], url)}');
          await f.writeAsBytes(r.bytes);
          cover = f.path;
        }
      } on Object {
        // A drawn cover will do.
      }
    }
    final existing = await list();
    final previous = existing.where((e) => e.id == id).firstOrNull;
    final entry = LibraryEntry(
      id: id,
      title: novel.name.isEmpty ? 'Untitled' : novel.name,
      authors: [if (novel.author != null) novel.author!],
      source: SourceKind.web,
      wordCount: 0,
      sourcePath: '',
      addedAt: previous?.addedAt ?? DateTime.now(),
      openedAt: previous?.openedAt,
      cursor: previous?.cursor ?? ReadingCursor.zero,
      progress: previous?.progress ?? 0,
      where: previous?.where,
      language: languageCodeOf(plugin.lang),
      cover: cover ?? previous?.cover,
      coverMode: previous?.coverMode ?? CoverMode.auto,
      customCover: previous?.customCover,
      category: previous?.category ?? category ?? _defaultCategory,
      plugin: plugin.id,
      novelPath: novel.path,
      chapterCount: novel.chapters.length,
    );
    await _write([entry, for (final e in existing) if (e.id != id) e]);
    return entry;
  }

  /// The stored details and chapter list of web novel [id].
  Future<WebNovelInfo?> webNovel(String id) async {
    final f = File('${bookDir(id)}/novel.json');
    if (!await f.exists()) return null;
    try {
      return WebNovelInfo.fromJson(Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map));
    } on Object {
      return null;
    }
  }

  /// Replace a web novel's chapter list (after checking for new chapters).
  Future<void> saveWebChapters(String id, List<ChapterItem> chapters) async {
    final info = await webNovel(id);
    if (info == null) return;
    final next = info.copyWith(chapters: chapters, checkedAt: DateTime.now());
    await File('${bookDir(id)}/novel.json').writeAsString(jsonEncode(next.toJson()));
    final entries = await list();
    await _write([for (final e in entries) e.id == id ? e.copyWith(chapterCount: chapters.length) : e]);
  }

  /// Whether chapter [index] of web novel [id] is on the phone.
  bool hasChapter(String id, int index) => File(_chapterFile(id, index)).existsSync();

  /// Chapter numbers of [id] already on the phone.
  Set<int> downloadedChapters(String id) {
    final dir = Directory('${bookDir(id)}/ch');
    if (!dir.existsSync()) return const {};
    return {
      for (final f in dir.listSync().whereType<File>())
        if (int.tryParse(f.uri.pathSegments.last.split('.').first) case final n?) n,
    };
  }

  /// Keep a fetched chapter, parsed, so it opens offline from now on.
  Future<void> saveChapter(String id, int index, String title, String html, {String? language}) async {
    final path = _chapterFile(id, index);
    await Isolate.run(() {
      final section = webChapterSection(index: index, title: title, html: html, language: language);
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(section.toJson()));
    });
  }

  String _chapterFile(String id, int index) => '${bookDir(id)}/ch/$index.json';

  /// Take [id] off the history (and the Continue card) without touching the
  /// place it is saved at.
  Future<void> forgetOpened(String id) async {
    final entries = await list();
    await _write([for (final e in entries) e.id == id ? e.copyWith(clearOpened: true) : e]);
  }

  /// Import [file]: parse it off the UI thread, store the source and the
  /// parsed book, and add it to the index. Re-importing a book keeps its
  /// reading position.
  Future<LibraryEntry> importFile(
    PickedFile file, {
    void Function(int done, int total)? onProgress,
  }) async {
    await ensure();
    final source = File(file.path);
    final head = await _head(source);
    final isPdf = head.startsWith('%PDF-') ||
        (file.name.toLowerCase().endsWith('.pdf') && !head.startsWith('PK'));

    Map<String, Object?>? pdf;
    if (isPdf) {
      final sub = SpeechService.events.listen((e) {
        if (e['type'] == 'importProgress') {
          onProgress?.call(e['done'] as int? ?? 0, e['total'] as int? ?? 0);
        }
      });
      try {
        pdf = await _svc.extractPdf(file.path);
      } finally {
        await sub.cancel();
      }
    }

    final job = (
      booksDir: _booksDir.path,
      sourcePath: file.path,
      name: file.name,
      mime: file.mime,
      pdf: pdf,
    );
    final entry = await _runImport(job);

    final existing = await list();
    final previous = existing.where((e) => e.id == entry.id).firstOrNull;
    final merged = previous == null
        ? entry.copyWith(category: _defaultCategory)
        : entry
            .copyWith(
              cursor: previous.cursor,
              progress: previous.progress,
              openedAt: previous.openedAt,
              where: previous.where,
              category: previous.category,
            )
            .withCover(previous.coverMode, previous.customCover);
    await _write([
      merged,
      for (final e in existing)
        if (e.id != entry.id) e,
    ]);

    // The picker's copy is now a duplicate of books/<id>/source.*.
    if (source.path.contains('/incoming/')) {
      try {
        await source.delete();
      } on FileSystemException {
        // Harmless; it is in our own folder.
      }
    }
    return merged;
  }

  /// The reading layout for [id], built on a background isolate.
  Future<ReadingLayout> loadLayout(String id) async {
    final entries = await list();
    final entry = entries.where((e) => e.id == id).firstOrNull;
    if (entry != null && entry.isWeb) {
      final dir = bookDir(id);
      return Isolate.run(() => _loadWebSync(dir, id));
    }
    final job = (
      booksDir: _booksDir.path,
      id: id,
      sourcePath: entry?.sourcePath,
    );
    final layout = await _runLoad(job);
    // Books imported before covers were stored get theirs on first open.
    final cover = coverFileOf(bookDir(id), layout.book);
    if (entry != null && entry.cover != cover && cover != null) {
      final now = await list();
      await _write([
        for (final e in now)
          if (e.id == id) e.copyWith(cover: cover) else e,
      ]);
    }
    return layout;
  }

  /// How a book's cover is chosen: [CoverMode.auto] (the book's own, or one
  /// made from the title), a picture of the user's, or a plain title cover.
  Future<LibraryEntry?> setCover(String id, CoverMode mode, {PickedFile? picture}) async {
    String? custom;
    if (picture != null) {
      final dir = Directory('${bookDir(id)}/img')..createSync(recursive: true);
      // A new name every time: the image cache keys on the path, so reusing
      // one would keep showing the previous picture.
      for (final old in dir.listSync().whereType<File>()) {
        if (old.uri.pathSegments.last.startsWith('custom_cover_')) old.deleteSync();
      }
      final dest = '${dir.path}/custom_cover_${DateTime.now().millisecondsSinceEpoch}${_ext(picture.name)}';
      await File(picture.path).copy(dest);
      try {
        await File(picture.path).delete();
      } on FileSystemException {
        // The picker's copy; harmless if it stays.
      }
      custom = dest;
    }
    final entries = await list();
    LibraryEntry? updated;
    await _write([
      for (final e in entries)
        if (e.id == id)
          updated = e.withCover(mode, custom ?? e.customCover)
        else
          e,
    ]);
    return updated;
  }

  /// Folder holding a book's source, parsed text and pictures.
  String bookDir(String id) => '${_booksDir.path}/$id';

  Future<ReadingCursor> cursorFor(String id) async {
    final file = File('${_booksDir.path}/$id/cursor.json');
    try {
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          return ReadingCursor.fromJson(
            Map<String, Object?>.from(raw['cursor'] as Map? ?? const {}),
          );
        }
      }
    } on FormatException {
      // Fall through to the index copy.
    }
    final entries = await list();
    for (final e in entries) {
      if (e.id == id) return e.cursor;
    }
    return ReadingCursor.zero;
  }

  Future<void> saveCursor(
    String id,
    ReadingCursor cursor,
    double progress, {
    String? where,
  }) async {
    await ensure();
    final dir = Directory('${_booksDir.path}/$id');
    await dir.create(recursive: true);
    await File('${dir.path}/cursor.json').writeAsString(
      jsonEncode({'cursor': cursor.toJson(), 'progress': progress}),
    );
    final entries = await list();
    if (entries.every((e) => e.id != id)) return;
    await _write([
      for (final e in entries)
        if (e.id == id)
          e.copyWith(
            cursor: cursor,
            progress: progress,
            openedAt: DateTime.now(),
            where: where,
          )
        else
          e,
    ]);
  }

  Future<void> remove(String id) async {
    final dir = Directory('${_booksDir.path}/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
    final entries = await list();
    await _write([for (final e in entries) if (e.id != id) e]);
  }

  static Future<String> _head(File f) async {
    try {
      final raf = await f.open();
      try {
        final bytes = await raf.read(5);
        return String.fromCharCodes(bytes);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return '';
    }
  }
}

// ------------------------------------------------------------------ isolate

// Top-level so the closure handed to Isolate.run captures only the job record.
// A closure created inside a method can share a context with other captured
// variables (callbacks holding widget state), which cannot be sent.
Future<LibraryEntry> _runImport(_ImportJob job) => Isolate.run(() => _importSync(job));

Future<ReadingLayout> _runLoad(_LoadJob job) => Isolate.run(() => _loadLayoutSync(job));

typedef _ImportJob = ({
  String booksDir,
  String sourcePath,
  String name,
  String? mime,
  Map<String, Object?>? pdf,
});

typedef _LoadJob = ({String booksDir, String id, String? sourcePath});

LibraryEntry _importSync(_ImportJob job) {
  final bytes = File(job.sourcePath).readAsBytesSync();
  final id = bookIdOf(bytes);
  final Book book;
  final pdf = job.pdf;
  if (pdf != null) {
    final text = pdf['text'] as String? ?? '';
    book = ingestPdfText(
      id: id,
      pages: text.split(String.fromCharCode(0x0C)),
      outline: [
        for (final o in (pdf['outline'] as List? ?? const []))
          if (o is Map)
            (title: o['title']?.toString() ?? '', page: o['page'] as int? ?? 0),
      ],
      title: pdf['title'] as String?,
      author: pdf['author'] as String?,
      filename: job.name,
    );
  } else {
    book = ingestBytes(bytes, filename: job.name, mime: job.mime, id: id);
  }

  final dir = Directory('${job.booksDir}/$id')..createSync(recursive: true);
  final dest = File('${dir.path}/source${_ext(job.name)}');
  dest.writeAsBytesSync(bytes, flush: true);
  _writeParsed(dir.path, book);
  _writeImages(dir.path, bytes, book);

  return LibraryEntry(
    id: id,
    title: book.metadata.title,
    authors: book.metadata.authors,
    source: book.source,
    wordCount: book.wordCount,
    sourcePath: dest.path,
    addedAt: DateTime.now(),
    language: book.metadata.language,
    cover: coverFileOf(dir.path, book),
  );
}

void _writeParsed(String dir, Book book) {
  File('$dir/parsed.json').writeAsStringSync(
    jsonEncode({'v': _parsedVersion, 'book': book.toJson()}),
  );
}

/// Store the pictures an EPUB uses under `<book>/img/`, so the reader shows
/// them without opening the archive again.
void _writeImages(String dir, Uint8List source, Book book) {
  if (book.source != SourceKind.epub) return;
  final wanted = imagesOf(book);
  if (wanted.isEmpty) return;
  final out = Directory('$dir/img')..createSync(recursive: true);
  for (final e in epubResources(source, wanted).entries) {
    File('${out.path}/${imageFileName(e.key)}').writeAsBytesSync(e.value);
  }
}

/// Where a picture from the source file is stored, by its path in the source.
String imageFileName(String path) =>
    path.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

String? coverFileOf(String dir, Book book) {
  final cover = book.metadata.cover;
  return cover == null ? null : '$dir/img/${imageFileName(cover)}';
}

/// A web novel as one book: every chapter in order, the fetched ones with
/// their text, the rest empty (and so skipped by the reader).
ReadingLayout _loadWebSync(String dir, String id) {
  final info = WebNovelInfo.fromJson(
    Map<String, Object?>.from(jsonDecode(File('$dir/novel.json').readAsStringSync()) as Map),
  );
  final sections = <Section>[];
  for (var i = 0; i < info.chapters.length; i++) {
    final title = info.chapters[i].name;
    final f = File('$dir/ch/$i.json');
    Section? s;
    if (f.existsSync()) {
      try {
        s = Section.fromJson(Map<String, Object?>.from(jsonDecode(f.readAsStringSync()) as Map));
      } on Object {
        s = null;
      }
    }
    sections.add(s ?? pendingWebChapter(index: i, title: title));
  }
  final cover = File('$dir/img').existsSync()
      ? Directory('$dir/img').listSync().whereType<File>().where((f) => f.path.contains('cover')).firstOrNull?.path
      : null;
  return ReadingLayout.build(webNovelBook(
    id: id,
    title: info.novel.name,
    authors: [if (info.novel.author != null) info.novel.author!],
    language: languageCodeOf(info.plugin.lang),
    cover: cover,
    description: info.novel.summary,
    sections: sections,
  ));
}

ReadingLayout _loadLayoutSync(_LoadJob job) {
  final dir = '${job.booksDir}/${job.id}';
  final parsed = File('$dir/parsed.json');
  Book? book;
  // The book as it was stored, when it is about to be re-parsed: the saved
  // place has to be carried across (see _carryCursor).
  Book? before;
  if (parsed.existsSync()) {
    final raw = jsonDecode(parsed.readAsStringSync());
    if (raw is Map && raw['v'] == _parsedVersion && raw['book'] is Map) {
      book = Book.fromJson(Map<String, Object?>.from(raw['book'] as Map));
    } else if (raw is Map) {
      // Written by an older build. Parse the source again so the book gets
      // today's sentence splitting, language detection and pictures; PDFs
      // need the platform for that, so they keep what they have.
      final inner = raw['book'];
      final legacy = Book.fromJson(
        Map<String, Object?>.from(inner is Map ? inner : raw),
      );
      before = legacy;
      final source = job.sourcePath == null ? null : File(job.sourcePath!);
      if (legacy.source != SourceKind.pdf && source != null && source.existsSync()) {
        try {
          final bytes = source.readAsBytesSync();
          book = ingestBytes(
            bytes,
            filename: legacy.sourceName ?? source.path,
            id: job.id,
          );
          _writeParsed(dir, book);
          _writeImages(dir, bytes, book);
        } on Object {
          book = withResolvedLanguage(legacy);
        }
      } else {
        book = withResolvedLanguage(legacy);
      }
    }
  }
  if (book == null) {
    final source = job.sourcePath == null ? null : File(job.sourcePath!);
    if (source == null || !source.existsSync()) {
      throw const ParseException('This book\'s files are missing. Import it again.');
    }
    final bytes = source.readAsBytesSync();
    book = ingestBytes(bytes, filename: source.path, id: job.id);
    _writeParsed(dir, book);
    _writeImages(dir, bytes, book);
  }
  // PDFs stored one section per page get real chapters from their own text.
  final resectioned = resectionPdf(book);
  if (!identical(resectioned, book)) {
    before ??= book;
    book = resectioned;
    _writeParsed(dir, book);
  }
  final layout = ReadingLayout.build(book);
  if (before != null && !identical(before, book)) _carryCursor(dir, before, layout);
  return layout;
}

/// A saved place is section/paragraph/sentence numbers. Re-parsing a book
/// can regroup those (a PDF going from pages to chapters), and the old
/// numbers then point somewhere else entirely: a book reopened at its last
/// chapter. Find the sentence the reader was on by its text and save that.
void _carryCursor(String dir, Book before, ReadingLayout after) {
  final file = File('$dir/cursor.json');
  if (!file.existsSync() || after.units.isEmpty) return;
  try {
    final raw = jsonDecode(file.readAsStringSync()) as Map;
    final cursor = ReadingCursor.fromJson(Map<String, Object?>.from(raw['cursor'] as Map? ?? const {}));
    final old = flattenSpeakable(before);
    if (old.isEmpty) return;
    final at = indexOfCursor(old, cursor);
    final text = old[at].text;
    // Nearest unit with the same text to where it sat proportionally.
    final guess = (at * after.units.length / old.length).round().clamp(0, after.units.length - 1);
    var best = -1;
    for (var d = 0; d < after.units.length; d++) {
      for (final i in [guess - d, guess + d]) {
        if (i >= 0 && i < after.units.length && after.units[i].text == text) {
          best = i;
          break;
        }
      }
      if (best >= 0 || d > 3000) break;
    }
    final target = best >= 0 ? best : guess;
    file.writeAsStringSync(jsonEncode({
      'cursor': cursorOf(after.units[target]).toJson(),
      'progress': raw['progress'],
    }));
  } on Object {
    // Losing the place is better than failing to open the book.
  }
}

// -------------------------------------------------------------------- entry

class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    required this.authors,
    required this.source,
    required this.wordCount,
    required this.sourcePath,
    required this.addedAt,
    this.openedAt,
    this.cursor = ReadingCursor.zero,
    this.progress = 0,
    this.where,
    this.language,
    this.cover,
    this.coverMode = CoverMode.auto,
    this.customCover,
    this.category,
    this.plugin,
    this.novelPath,
    this.chapterCount = 0,
  });

  final String id;
  final String title;
  final List<String> authors;
  final SourceKind source;
  final int wordCount;
  final String sourcePath;
  final DateTime addedAt;
  final DateTime? openedAt;
  final ReadingCursor cursor;
  final double progress;

  /// Where the reader left off, in words: "Chapter 12: The Fool".
  final String? where;
  final String? language;

  /// The book's own cover picture on disk, when it has one.
  final String? cover;

  /// Which cover the shelf shows; see [shownCover].
  final CoverMode coverMode;

  /// A picture the user chose, on disk.
  final String? customCover;

  /// The category id it sits in; null means the shelf's default.
  final String? category;

  /// For a web novel: the source plugin it comes from and its path there.
  final String? plugin;
  final String? novelPath;

  /// For a web novel: how many chapters the source lists.
  final int chapterCount;

  bool get isWeb => source == SourceKind.web;

  /// The picture to show, or null for a cover drawn from the title.
  String? get shownCover => switch (coverMode) {
        CoverMode.plain => null,
        CoverMode.custom => customCover ?? cover,
        CoverMode.auto => cover,
      };

  LibraryEntry withCover(CoverMode mode, String? custom) =>
      copyWith(coverMode: mode, customCover: custom, clearCustomCover: custom == null);

  DateTime get lastTouched => openedAt ?? addedAt;

  String get authorLine => authors.join(', ');

  bool get finished => progress >= 0.995;

  /// "EPUB", "PDF", "DOCX"…
  String get formatLabel => switch (source) {
        SourceKind.text => 'TXT',
        SourceKind.markdown => 'MD',
        SourceKind.unknown => 'TEXT',
        SourceKind.web => 'WEB',
        _ => source.name.toUpperCase(),
      };

  /// The category this book shows under, given the shelf's [categories].
  String categoryIn(List<Category> categories, String fallback) =>
      category != null && categories.any((c) => c.id == category) ? category! : fallback;

  LibraryEntry copyWith({
    ReadingCursor? cursor,
    double? progress,
    DateTime? openedAt,
    bool clearOpened = false,
    String? where,
    String? cover,
    CoverMode? coverMode,
    String? customCover,
    bool clearCustomCover = false,
    String? category,
    int? chapterCount,
  }) =>
      LibraryEntry(
        id: id,
        title: title,
        authors: authors,
        source: source,
        wordCount: wordCount,
        sourcePath: sourcePath,
        addedAt: addedAt,
        openedAt: clearOpened ? null : (openedAt ?? this.openedAt),
        cursor: cursor ?? this.cursor,
        progress: progress ?? this.progress,
        where: where ?? this.where,
        language: language,
        cover: cover ?? this.cover,
        coverMode: coverMode ?? this.coverMode,
        customCover: clearCustomCover ? null : (customCover ?? this.customCover),
        category: category ?? this.category,
        plugin: plugin,
        novelPath: novelPath,
        chapterCount: chapterCount ?? this.chapterCount,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'authors': authors,
        'source': source.name,
        'wordCount': wordCount,
        'sourcePath': sourcePath,
        'addedAt': addedAt.toIso8601String(),
        if (openedAt != null) 'openedAt': openedAt!.toIso8601String(),
        'cursor': cursor.toJson(),
        'progress': progress,
        if (where != null) 'where': where,
        if (language != null) 'language': language,
        if (cover != null) 'cover': cover,
        if (coverMode != CoverMode.auto) 'coverMode': coverMode.name,
        if (customCover != null) 'customCover': customCover,
        if (category != null) 'category': category,
        if (plugin != null) 'plugin': plugin,
        if (novelPath != null) 'novelPath': novelPath,
        if (chapterCount > 0) 'chapterCount': chapterCount,
      };

  static LibraryEntry fromJson(Map<String, Object?> json) => LibraryEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Untitled',
        authors: [
          for (final a in (json['authors'] as List? ?? const [])) a.toString(),
        ],
        source: SourceKind.values.firstWhere(
          (k) => k.name == json['source'],
          orElse: () => SourceKind.unknown,
        ),
        wordCount: json['wordCount'] as int? ?? 0,
        sourcePath: json['sourcePath'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        openedAt: DateTime.tryParse(json['openedAt'] as String? ?? ''),
        cursor: ReadingCursor.fromJson(
          Map<String, Object?>.from(json['cursor'] as Map? ?? const {}),
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        where: json['where'] as String?,
        language: json['language'] as String?,
        cover: json['cover'] as String?,
        coverMode: CoverMode.values.firstWhere(
          (m) => m.name == json['coverMode'],
          orElse: () => CoverMode.auto,
        ),
        customCover: json['customCover'] as String?,
        category: json['category'] as String?,
        plugin: json['plugin'] as String?,
        novelPath: json['novelPath'] as String?,
        chapterCount: json['chapterCount'] as int? ?? 0,
      );
}

/// A shelf in the library: "Reading", "Later", or one the user made.
class Category {
  const Category(this.id, this.name);

  final String id;
  final String name;

  /// The two the library starts with. Both can be renamed or deleted.
  static const defaults = [Category('reading', 'Reading'), Category('later', 'Later')];

  static String newId(String name) {
    final slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '${slug.isEmpty ? 'shelf' : slug}-$stamp';
  }

  Category renamed(String to) => Category(id, to);

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static Category fromJson(Map<String, Object?> json) =>
      Category(json['id'] as String? ?? newId('shelf'), json['name'] as String? ?? 'Shelf');

  @override
  bool operator ==(Object other) => other is Category && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// What the library index holds.
class LibraryIndex {
  const LibraryIndex({
    required this.entries,
    required this.categories,
    required this.defaultCategory,
  });

  final List<LibraryEntry> entries;
  final List<Category> categories;
  final String defaultCategory;

  /// Books in [categoryId].
  List<LibraryEntry> inCategory(String categoryId) => [
        for (final e in entries)
          if (e.categoryIn(categories, defaultCategory) == categoryId) e,
      ];
}

enum CoverMode { auto, custom, plain }

String _ext(String path) {
  final slash = path.replaceAll(r'\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  if (dot <= 0) return '';
  return slash.substring(dot).toLowerCase();
}

/// A small built-in book, used as a fixture by the widget tests.
Book specimenBook() => ingestString(
      'The quick brown fox jumps over the lazy dog. '
      'Pack my box with five dozen liquor jugs.\n\n'
      'TomeVoice reads a document you already own, on the device, with '
      'control over the voice that a normal reader does not give you. '
      'Word gap, comma pauses, sentence pauses, and speed all land on '
      'the audio you hear.\n\n'
      'Open the library and import an EPUB, a PDF, a Word file or plain '
      'text. Playback walks sentence by sentence so a chapter is not one '
      'giant utterance. Tap any sentence to start reading from there.',
      filename: 'specimen.txt',
      title: 'Specimen',
    );

/// What TomeVoice keeps about a web novel: where it comes from, its details,
/// and the chapter list as the source last gave it.
class WebNovelInfo {
  const WebNovelInfo({required this.plugin, required this.novel, required this.chapters, this.checkedAt});

  final PluginInfo plugin;

  /// Details only (name, cover, author, summary, status, genres); the
  /// chapters are in [chapters].
  final SourceNovel novel;
  final List<ChapterItem> chapters;

  /// When the chapter list was last fetched.
  final DateTime? checkedAt;

  WebNovelInfo copyWith({List<ChapterItem>? chapters, DateTime? checkedAt}) => WebNovelInfo(
        plugin: plugin,
        novel: novel,
        chapters: chapters ?? this.chapters,
        checkedAt: checkedAt ?? this.checkedAt,
      );

  Map<String, Object?> toJson() => {
        'plugin': plugin.toJson(),
        'novel': {
          'path': novel.path,
          'name': novel.name,
          if (novel.cover != null) 'cover': novel.cover,
          if (novel.author != null) 'author': novel.author,
          if (novel.summary != null) 'summary': novel.summary,
          if (novel.status != null) 'status': novel.status,
          'genres': novel.genres.join(', '),
        },
        'chapters': [for (final c in chapters) c.toJson()],
        if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
      };

  static WebNovelInfo fromJson(Map<String, Object?> j) {
    final n = Map<String, Object?>.from(j['novel'] as Map? ?? const {});
    return WebNovelInfo(
      plugin: PluginInfo.fromJson(Map<String, Object?>.from(j['plugin'] as Map? ?? const {})) ??
          const PluginInfo(id: '', name: '', site: '', lang: 'English', version: '0', url: ''),
      novel: SourceNovel.fromJs(n, path: n['path'] as String? ?? ''),
      chapters: [
        for (final c in (j['chapters'] as List? ?? const []))
          ChapterItem.fromJson(Map<String, Object?>.from(c as Map)),
      ],
      checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? ''),
    );
  }
}

/// A source's language name ("English", "Русский") as a language code.
String languageCodeOf(String name) {
  final n = name.replaceAll(String.fromCharCode(0x200E), '').trim().toLowerCase();
  const names = {
    'english': 'en', 'русский': 'ru', 'russian': 'ru', 'español': 'es', 'spanish': 'es',
    'français': 'fr', 'french': 'fr', 'português': 'pt', 'portuguese': 'pt', 'türkçe': 'tr',
    'turkish': 'tr', 'indonesia': 'id', 'indonesian': 'id', 'bahasa indonesia': 'id',
    '中文': 'zh', 'chinese': 'zh', '日本語': 'ja', 'japanese': 'ja', '한국어': 'ko', 'korean': 'ko',
    'tiếng việt': 'vi', 'vietnamese': 'vi', 'ไทย': 'th', 'thai': 'th', 'українська': 'uk',
    'ukrainian': 'uk', 'polski': 'pl', 'polish': 'pl', 'العربية': 'ar', 'arabic': 'ar',
    'deutsch': 'de', 'german': 'de', 'italiano': 'it', 'italian': 'it',
  };
  return names[n] ?? 'en';
}

String _imageExt(String? contentType, String url) {
  final t = (contentType ?? '').toLowerCase();
  if (t.contains('png')) return '.png';
  if (t.contains('webp')) return '.webp';
  if (t.contains('gif')) return '.gif';
  final u = url.toLowerCase().split('?').first;
  for (final e in const ['.png', '.webp', '.gif', '.jpeg']) {
    if (u.endsWith(e)) return e;
  }
  return '.jpg';
}
