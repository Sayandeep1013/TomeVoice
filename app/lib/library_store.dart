import 'dart:convert';
import 'dart:io';

import 'package:tomevoice_document/tomevoice_document.dart';

/// On-device library: copied files, parsed books, reading positions.
///
/// JSON on disk rather than Drift. The schema in docs/11 is the destination;
/// this store is the speakable-document slice so a book survives process death
/// without pulling Flutter SQL into a spike that still has no local Flutter SDK.
class LibraryStore {
  LibraryStore(this.root);

  final Directory root;

  Directory get _booksDir => Directory('${root.path}/books');
  File get _indexFile => File('${root.path}/library.json');

  Future<void> ensure() async {
    await _booksDir.create(recursive: true);
  }

  Future<List<LibraryEntry>> list() async {
    await ensure();
    if (!await _indexFile.exists()) return const [];
    final raw = jsonDecode(await _indexFile.readAsString());
    if (raw is! Map) return const [];
    final books = raw['books'] as List? ?? const [];
    return [
      for (final b in books)
        LibraryEntry.fromJson(Map<String, Object?>.from(b as Map)),
    ];
  }

  Future<void> _write(List<LibraryEntry> entries) async {
    await _indexFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'books': [for (final e in entries) e.toJson()],
      }),
    );
  }

  Future<LibraryEntry> importFile({
    required File source,
    String? displayName,
    String? mime,
  }) async {
    await ensure();
    final bytes = await source.readAsBytes();
    final book = ingestBytes(
      bytes,
      filename: displayName ?? source.uri.pathSegments.last,
      mime: mime,
    );

    final dir = Directory('${_booksDir.path}/${book.id}');
    await dir.create(recursive: true);
    final ext = _ext(displayName ?? source.path);
    final dest = File('${dir.path}/source$ext');
    await dest.writeAsBytes(bytes, flush: true);
    await File('${dir.path}/parsed.json').writeAsString(
      jsonEncode(book.toJson()),
    );

    final entry = LibraryEntry(
      id: book.id,
      title: book.metadata.title,
      authors: book.metadata.authors,
      source: book.source,
      wordCount: book.wordCount,
      sourcePath: dest.path,
      addedAt: DateTime.now(),
    );

    final existing = await list();
    final next = [
      entry,
      for (final e in existing)
        if (e.id != entry.id) e,
    ];
    await _write(next);
    return entry;
  }

  Future<Book> loadBook(String id) async {
    final parsed = File('${_booksDir.path}/$id/parsed.json');
    if (await parsed.exists()) {
      return Book.fromJson(
        Map<String, Object?>.from(
          jsonDecode(await parsed.readAsString()) as Map,
        ),
      );
    }
    final entries = await list();
    final entry = entries.firstWhere((e) => e.id == id);
    final bytes = await File(entry.sourcePath).readAsBytes();
    return ingestBytes(
      bytes,
      filename: entry.sourcePath,
      id: id,
    );
  }

  Future<ReadingCursor> cursorFor(String id) async {
    final entries = await list();
    for (final e in entries) {
      if (e.id == id) return e.cursor;
    }
    return ReadingCursor.zero;
  }

  Future<void> saveCursor(String id, ReadingCursor cursor, double progress) async {
    final entries = await list();
    final next = [
      for (final e in entries)
        if (e.id == id)
          e.copyWith(cursor: cursor, progress: progress, openedAt: DateTime.now())
        else
          e,
    ];
    await _write(next);
  }

  Future<void> remove(String id) async {
    final dir = Directory('${_booksDir.path}/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
    final entries = await list();
    await _write([for (final e in entries) if (e.id != id) e]);
  }
}

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

  String get authorLine =>
      authors.isEmpty ? source.name.toUpperCase() : authors.join(', ');

  LibraryEntry copyWith({
    ReadingCursor? cursor,
    double? progress,
    DateTime? openedAt,
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
      );
}

String _ext(String path) {
  final slash = path.replaceAll('\\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  if (dot <= 0) return '';
  return slash.substring(dot).toLowerCase();
}

/// The built-in demonstration book. Always available, never imported.
Book specimenBook() => ingestString(
      'The quick brown fox jumps over the lazy dog. '
      'Pack my box with five dozen liquor jugs.\n\n'
      'TomeVoice reads a document you already own, on the device, with '
      'control over the voice that a normal reader does not give you. '
      'Word gap, comma pauses, sentence pauses, and speed all land on '
      'the audio you hear.\n\n'
      'Open the library and import an EPUB, a text file, or Markdown. '
      'Playback walks sentence by sentence so a chapter is not one giant '
      'utterance. The arrows move one sentence. The list opens sections. '
      'Play starts from where you left off.',
      filename: 'specimen.txt',
      title: 'Specimen',
    );
