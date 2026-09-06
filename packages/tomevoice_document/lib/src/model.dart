/// Contract A — the Document Model.
///
/// Every input format is normalised into one linear, addressable stream of
/// text. The reader renders it. The speech engine consumes it. Neither knows
/// what an EPUB is. See docs/02 §2.4.
library;

enum SourceKind { epub, text, markdown, html, pdf, docx, rtf, unknown }

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

class Sentence {
  const Sentence({
    required this.startOffset,
    required this.endOffset,
    required this.words,
  });

  final int startOffset;
  final int endOffset;
  final List<WordSpan> words;

  String of(String blockText) =>
      blockText.substring(startOffset, endOffset);

  bool get isEmpty => startOffset >= endOffset;

  Map<String, Object?> toJson() => {
        'start': startOffset,
        'end': endOffset,
        'words': [for (final w in words) w.toJson()],
      };

  static Sentence fromJson(Map<String, Object?> json) => Sentence(
        startOffset: json['start'] as int? ?? 0,
        endOffset: json['end'] as int? ?? 0,
        words: [
          for (final w in (json['words'] as List? ?? const []))
            WordSpan.fromJson(Map<String, Object?>.from(w as Map)),
        ],
      );
}

class Block {
  const Block({
    required this.id,
    required this.role,
    required this.text,
    required this.sentences,
    required this.anchor,
    this.language,
  });

  final String id;
  final BlockRole role;
  final String text;
  final List<Sentence> sentences;
  final Anchor anchor;
  final String? language;

  bool get speakable =>
      text.isNotEmpty && !defaultSkippedRoles.contains(role);

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'sentences': [for (final s in sentences) s.toJson()],
        'anchor': anchor.toJson(),
        if (language != null) 'language': language,
      };

  static Block fromJson(Map<String, Object?> json) => Block(
        id: json['id'] as String? ?? '',
        role: BlockRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => BlockRole.paragraph,
        ),
        text: json['text'] as String? ?? '',
        sentences: [
          for (final s in (json['sentences'] as List? ?? const []))
            Sentence.fromJson(Map<String, Object?>.from(s as Map)),
        ],
        anchor: Anchor.fromJson(
          Map<String, Object?>.from(json['anchor'] as Map? ?? const {}),
        ),
        language: json['language'] as String?,
      );
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
  });

  final String title;
  final List<String> authors;
  final String? language;
  final String? publisher;
  final String? identifier;

  String get authorLine => authors.join(', ');

  Map<String, Object?> toJson() => {
        'title': title,
        'authors': authors,
        if (language != null) 'language': language,
        if (publisher != null) 'publisher': publisher,
        if (identifier != null) 'identifier': identifier,
      };

  static BookMetadata fromJson(Map<String, Object?> json) => BookMetadata(
        title: json['title'] as String? ?? 'Untitled',
        authors: [
          for (final a in (json['authors'] as List? ?? const [])) a.toString(),
        ],
        language: json['language'] as String?,
        publisher: json['publisher'] as String?,
        identifier: json['identifier'] as String?,
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
  });

  final int sectionIndex;
  final int blockIndex;
  final int sentenceIndex;
  final String text;
  final BlockRole role;
  final String blockId;

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
