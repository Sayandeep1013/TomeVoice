import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:tomevoice_document/tomevoice_document.dart';

import 'speech_service.dart';

/// Bumped when ingestion improves enough that stored books should be parsed
/// again from their source file (v2: multilingual sentences, compact JSON;
/// v3: pictures and covers from EPUBs, page numbers in PDFs; v4: toc nav
/// only, chapters named from first lines, drop caps, Gutenberg apparatus).
const _parsedVersion = 4;

/// On-device library: copied files, parsed books, reading positions.
///
/// JSON on disk rather than Drift. Everything heavy (parsing, JSON, building
/// the reading layout) runs on a background isolate: on the UI isolate it was
/// a 2.5 second freeze when opening a long EPUB.
class LibraryStore {
  LibraryStore(this.root);

  final Directory root;

  static const _svc = SpeechService();

  Directory get _booksDir => Directory('${root.path}/books');
  File get _indexFile => File('${root.path}/library.json');

  Future<void> ensure() async {
    await _booksDir.create(recursive: true);
  }

  Future<List<LibraryEntry>> list() async {
    await ensure();
    if (!await _indexFile.exists()) return const [];
    try {
      final raw = jsonDecode(await _indexFile.readAsString());
      if (raw is! Map) return const [];
      final books = raw['books'] as List? ?? const [];
      final entries = [
        for (final b in books)
          LibraryEntry.fromJson(Map<String, Object?>.from(b as Map)),
      ];
      entries.sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
      return entries;
    } on FormatException {
      return const [];
    }
  }

  Future<void> _write(List<LibraryEntry> entries) async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'books': [for (final e in entries) e.toJson()],
      }),
    );
    await tmp.rename(_indexFile.path);
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
        ? entry
        : entry.copyWith(
            cursor: previous.cursor,
            progress: previous.progress,
            openedAt: previous.openedAt,
            where: previous.where,
          );
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

ReadingLayout _loadLayoutSync(_LoadJob job) {
  final dir = '${job.booksDir}/${job.id}';
  final parsed = File('$dir/parsed.json');
  Book? book;
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
  return ReadingLayout.build(book);
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

  /// Cover picture on disk, when the book has one.
  final String? cover;

  DateTime get lastTouched => openedAt ?? addedAt;

  String get authorLine => authors.join(', ');

  /// "EPUB", "PDF", "DOCX"…
  String get formatLabel => switch (source) {
        SourceKind.text => 'TXT',
        SourceKind.markdown => 'MD',
        SourceKind.unknown => 'TEXT',
        _ => source.name.toUpperCase(),
      };

  LibraryEntry copyWith({
    ReadingCursor? cursor,
    double? progress,
    DateTime? openedAt,
    String? where,
    String? cover,
  }) =>
      LibraryEntry(
        id: id,
        title: title,
        authors: authors,
        source: source,
        wordCount: wordCount,
        sourcePath: sourcePath,
        addedAt: addedAt,
        openedAt: openedAt ?? this.openedAt,
        cursor: cursor ?? this.cursor,
        progress: progress ?? this.progress,
        where: where ?? this.where,
        language: language,
        cover: cover ?? this.cover,
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
      );
}

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
