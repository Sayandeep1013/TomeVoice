/// Contract A — the Document Model.
///
/// Every input format is normalised into one linear, addressable stream of
/// text. The reader renders it. The speech engine consumes it. Neither knows
/// what an EPUB is. See docs/02 §2.4.
library;

enum SourceKind {
  epub,
  text,
  markdown,
  html,
  pdf,
  docx,
  rtf,
  odt,
  fb2,
  mobi,

  /// A web novel, its chapters fetched from a site.
  web,
  unknown,
}

enum BlockRole {
  heading,
  paragraph,
  listItem,
  quote,
  caption,
  footnote,
  table,
  code,
  pageNumber,
  runningHeader,
  figure,
  math,
}

/// Roles the speech scheduler skips unless the user turns them back on.
const Set<BlockRole> defaultSkippedRoles = {
  BlockRole.footnote,
  BlockRole.pageNumber,
  BlockRole.runningHeader,
  BlockRole.caption,
  BlockRole.figure,
};

sealed class Anchor {
  const Anchor();

  Map<String, Object?> toJson();

  static Anchor fromJson(Map<String, Object?> json) {
    switch (json['kind'] as String?) {
      case 'epub':
        return EpubAnchor(json['cfi'] as String? ?? '');
      case 'offset':
        return OffsetAnchor(
          json['start'] as int? ?? 0,
          json['end'] as int? ?? 0,
        );
      case 'page':
        return PageAnchor(json['page'] as int? ?? 0);
      default:
        return OffsetAnchor(0, 0);
    }
  }
}

class EpubAnchor extends Anchor {
  const EpubAnchor(this.cfi);
  final String cfi;

  @override
  Map<String, Object?> toJson() => {'kind': 'epub', 'cfi': cfi};
}

/// A place in a PDF: the 0-based page a block starts on.
class PageAnchor extends Anchor {
  const PageAnchor(this.page);
  final int page;

  @override
  Map<String, Object?> toJson() => {'kind': 'page', 'page': page};
}

class OffsetAnchor extends Anchor {
  const OffsetAnchor(this.start, this.end);
  final int start;
  final int end;

  @override
  Map<String, Object?> toJson() => {
        'kind': 'offset',
        'start': start,
        'end': end,
      };
}

class WordSpan {
  const WordSpan(this.start, this.end);
  final int start;
  final int end;

  String of(String text) => text.substring(start, end);

  Map<String, Object?> toJson() => {'start': start, 'end': end};

  static WordSpan fromJson(Map<String, Object?> json) => WordSpan(
        json['start'] as int? ?? 0,
        json['end'] as int? ?? 0,
      );
}

/// A stretch of text as character offsets, end exclusive.
typedef TextStretch = ({int start, int end});

class Sentence {
  const Sentence({
    required this.startOffset,
    required this.endOffset,
    required this.words,
    this.silent = const [],
  });

  final int startOffset;
  final int endOffset;
  final List<WordSpan> words;

  /// Stretches of this sentence that are shown but not spoken: a footnote
  /// marker ("house.¹"). Offsets in the block's text, like [startOffset],
  /// in order. The voice treats each one as a pronunciation rule whose
  /// replacement is nothing (see `spokenText`).
  final List<TextStretch> silent;

  String of(String blockText) =>
      blockText.substring(startOffset, endOffset);

  bool get isEmpty => startOffset >= endOffset;

  Map<String, Object?> toJson() => {
        'start': startOffset,
        'end': endOffset,
        'words': [for (final w in words) w.toJson()],
        if (silent.isNotEmpty) 'silent': _flat(silent),
      };

  static Sentence fromJson(Map<String, Object?> json) => Sentence(
        startOffset: json['start'] as int? ?? 0,
        endOffset: json['end'] as int? ?? 0,
        words: [
          for (final w in (json['words'] as List? ?? const []))
            WordSpan.fromJson(Map<String, Object?>.from(w as Map)),
        ],
        silent: _stretches(json['silent']),
      );
}

/// [start, end, start, end, ...]: how stretches are stored.
List<int> _flat(Iterable<TextStretch> stretches) => [
      for (final r in stretches) ...[r.start, r.end],
    ];

/// Stretches from their stored form; anything else (absent, as in books
/// stored before there were any) is none.
List<TextStretch> _stretches(Object? flat) {
  if (flat is! List || flat.length < 2) return const [];
  return [
    for (var i = 0; i + 1 < flat.length; i += 2)
      if (flat[i] is int && flat[i + 1] is int) (start: flat[i] as int, end: flat[i + 1] as int),
  ];
}

class Block {
  const Block({
    required this.id,
    required this.role,
    required this.text,
    required this.sentences,
    required this.anchor,
    this.language,
    this.image,
    this.imageWidth,
    this.imageHeight,
  });

  final String id;
  final BlockRole role;
  final String text;
  final List<Sentence> sentences;
  final Anchor anchor;
  final String? language;

  /// For a [BlockRole.figure]: the image's path inside the source file
  /// (e.g. `OEBPS/Images/map.jpg`), and its pixel size so the reader can
  /// reserve the right space before the picture loads.
  final String? image;
  final int? imageWidth;
  final int? imageHeight;

  bool get isImage => image != null;

  /// This block as a [role] (a first line that repeats its chapter's title
  /// becomes that chapter's heading).
  Block withRole(BlockRole role) => Block(
        id: id,
        role: role,
        text: text,
        sentences: sentences,
        anchor: anchor,
        language: language,
        image: image,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );

  bool get speakable =>
      text.isNotEmpty && !defaultSkippedRoles.contains(role);

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        // Flat [start, end, start, end, ...]. Word spans are not stored:
        // nothing reads them back, and they were most of a 15 MB file.
        'sb': [
          for (final s in sentences) ...[s.startOffset, s.endOffset],
        ],
        // Silent stretches of every sentence, in the same flat form; left
        // out when there are none, which is nearly every block.
        if (sentences.any((s) => s.silent.isNotEmpty))
          'sl': _flat(sentences.expand((s) => s.silent)),
        'anchor': anchor.toJson(),
        if (language != null) 'language': language,
        if (image != null) 'img': image,
        if (imageWidth != null) 'iw': imageWidth,
        if (imageHeight != null) 'ih': imageHeight,
      };

  static Block fromJson(Map<String, Object?> json) => Block(
        id: json['id'] as String? ?? '',
        role: BlockRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => BlockRole.paragraph,
        ),
        text: json['text'] as String? ?? '',
        sentences: _sentencesFromJson(json),
        anchor: Anchor.fromJson(
          Map<String, Object?>.from(json['anchor'] as Map? ?? const {}),
        ),
        language: json['language'] as String?,
        image: json['img'] as String?,
        imageWidth: json['iw'] as int?,
        imageHeight: json['ih'] as int?,
      );

  Block withImageSize(int width, int height) => Block(
        id: id,
        role: role,
        text: text,
        sentences: sentences,
        anchor: anchor,
        language: language,
        image: image,
        imageWidth: width,
        imageHeight: height,
      );
}

List<Sentence> _sentencesFromJson(Map<String, Object?> json) {
  final flat = json['sb'];
  if (flat is List) {
    final silent = _stretches(json['sl']);
    return [
      for (var i = 0; i + 1 < flat.length; i += 2)
        Sentence(
          startOffset: flat[i] as int,
          endOffset: flat[i + 1] as int,
          words: const [],
          silent: silent.isEmpty
              ? const []
              : [
                  for (final r in silent)
                    if (r.start >= (flat[i] as int) && r.end <= (flat[i + 1] as int)) r,
                ],
        ),
    ];
  }
  // Libraries written before the compact form.
  return [
    for (final s in (json['sentences'] as List? ?? const []))
      Sentence.fromJson(Map<String, Object?>.from(s as Map)),
  ];
}

class TocEntry {
  const TocEntry({
    required this.title,
    required this.sectionIndex,
    this.href,
  });

  final String title;
  final int sectionIndex;
  final String? href;

  Map<String, Object?> toJson() => {
        'title': title,
        'sectionIndex': sectionIndex,
        if (href != null) 'href': href,
      };

  static TocEntry fromJson(Map<String, Object?> json) => TocEntry(
        title: json['title'] as String? ?? '',
        sectionIndex: json['sectionIndex'] as int? ?? 0,
        href: json['href'] as String?,
      );
}

class Section {
  const Section({
    required this.id,
    required this.index,
    required this.blocks,
    this.title,
    this.href,
  });

  final String id;
  final int index;
  final String? title;
  final String? href;
  final List<Block> blocks;

  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) return title!;
    for (final b in blocks) {
      if (b.role == BlockRole.heading && b.text.isNotEmpty) return b.text;
    }
    return 'Section ${index + 1}';
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'index': index,
        if (title != null) 'title': title,
        if (href != null) 'href': href,
        'blocks': [for (final b in blocks) b.toJson()],
      };

  static Section fromJson(Map<String, Object?> json) => Section(
        id: json['id'] as String? ?? '',
        index: json['index'] as int? ?? 0,
        title: json['title'] as String?,
        href: json['href'] as String?,
        blocks: [
          for (final b in (json['blocks'] as List? ?? const []))
            Block.fromJson(Map<String, Object?>.from(b as Map)),
        ],
      );
}

class BookMetadata {
  const BookMetadata({
    required this.title,
    this.authors = const [],
    this.language,
    this.publisher,
    this.identifier,
    this.cover,
    this.description,
  });

  final String title;
  final List<String> authors;
  final String? language;
  final String? publisher;
  final String? identifier;

  /// Path of the cover image inside the source file, when it has one.
  final String? cover;

  /// The blurb: an EPUB's dc:description, a web novel's summary.
  final String? description;

  String get authorLine => authors.join(', ');

  BookMetadata copyWith({
    String? title,
    List<String>? authors,
    String? language,
  }) =>
      BookMetadata(
        title: title ?? this.title,
        authors: authors ?? this.authors,
        language: language ?? this.language,
        publisher: publisher,
        identifier: identifier,
        cover: cover,
        description: description,
      );

  Map<String, Object?> toJson() => {
        'title': title,
        'authors': authors,
        if (language != null) 'language': language,
        if (publisher != null) 'publisher': publisher,
        if (identifier != null) 'identifier': identifier,
        if (cover != null) 'cover': cover,
        if (description != null) 'description': description,
      };

  static BookMetadata fromJson(Map<String, Object?> json) => BookMetadata(
        title: json['title'] as String? ?? 'Untitled',
        authors: [
          for (final a in (json['authors'] as List? ?? const [])) a.toString(),
        ],
        language: json['language'] as String?,
        publisher: json['publisher'] as String?,
        identifier: json['identifier'] as String?,
        cover: json['cover'] as String?,
        description: json['description'] as String?,
      );
}

class Book {
  const Book({
    required this.id,
    required this.metadata,
    required this.sections,
    required this.toc,
    required this.source,
    this.sourceName,
    this.wordCount = 0,
  });

  final String id;
  final BookMetadata metadata;
  final List<Section> sections;
  final List<TocEntry> toc;
  final SourceKind source;
  final String? sourceName;
  final int wordCount;

  bool get isEmpty =>
      sections.every((s) => s.blocks.every((b) => b.text.isEmpty));

  Book copyWith({
    BookMetadata? metadata,
    List<Section>? sections,
    List<TocEntry>? toc,
    int? wordCount,
  }) =>
      Book(
        id: id,
        metadata: metadata ?? this.metadata,
        sections: sections ?? this.sections,
        toc: toc ?? this.toc,
        source: source,
        sourceName: sourceName,
        wordCount: wordCount ?? this.wordCount,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'metadata': metadata.toJson(),
        'sections': [for (final s in sections) s.toJson()],
        'toc': [for (final t in toc) t.toJson()],
        'source': source.name,
        if (sourceName != null) 'sourceName': sourceName,
        'wordCount': wordCount,
      };

  static Book fromJson(Map<String, Object?> json) => Book(
        id: json['id'] as String? ?? '',
        metadata: BookMetadata.fromJson(
          Map<String, Object?>.from(json['metadata'] as Map? ?? const {}),
        ),
        sections: [
          for (final s in (json['sections'] as List? ?? const []))
            Section.fromJson(Map<String, Object?>.from(s as Map)),
        ],
        toc: [
          for (final t in (json['toc'] as List? ?? const []))
            TocEntry.fromJson(Map<String, Object?>.from(t as Map)),
        ],
        source: SourceKind.values.firstWhere(
          (k) => k.name == json['source'],
          orElse: () => SourceKind.unknown,
        ),
        sourceName: json['sourceName'] as String?,
        wordCount: json['wordCount'] as int? ?? 0,
      );
}

/// One sentence the scheduler can speak, with enough address to resume.
class Speakable {
  const Speakable({
    required this.sectionIndex,
    required this.blockIndex,
    required this.sentenceIndex,
    required this.text,
    required this.role,
    required this.blockId,
    this.silent = const [],
  });

  final int sectionIndex;
  final int blockIndex;
  final int sentenceIndex;
  final String text;
  final BlockRole role;
  final String blockId;

  /// Stretches of [text] that are shown but not spoken, as offsets in
  /// [text] itself. `spokenText(text, silent)` is what the voice is given.
  final List<TextStretch> silent;

  int get linearIndex =>
      (sectionIndex * 1000000) + (blockIndex * 1000) + sentenceIndex;
}

class ReadingCursor {
  const ReadingCursor({
    this.sectionIndex = 0,
    this.blockIndex = 0,
    this.sentenceIndex = 0,
  });

  final int sectionIndex;
  final int blockIndex;
  final int sentenceIndex;

  static const zero = ReadingCursor();

  Map<String, Object?> toJson() => {
        'sectionIndex': sectionIndex,
        'blockIndex': blockIndex,
        'sentenceIndex': sentenceIndex,
      };

  static ReadingCursor fromJson(Map<String, Object?> json) => ReadingCursor(
        sectionIndex: json['sectionIndex'] as int? ?? 0,
        blockIndex: json['blockIndex'] as int? ?? 0,
        sentenceIndex: json['sentenceIndex'] as int? ?? 0,
      );

  ReadingCursor copyWith({
    int? sectionIndex,
    int? blockIndex,
    int? sentenceIndex,
  }) =>
      ReadingCursor(
        sectionIndex: sectionIndex ?? this.sectionIndex,
        blockIndex: blockIndex ?? this.blockIndex,
        sentenceIndex: sentenceIndex ?? this.sentenceIndex,
      );
}

/// Thrown when the file is encrypted. DRM is permanently out of scope.
class EncryptedDocumentException implements Exception {
  const EncryptedDocumentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UnsupportedDocumentException implements Exception {
  const UnsupportedDocumentException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ParseException implements Exception {
  const ParseException(this.message);
  final String message;
  @override
  String toString() => message;
}
