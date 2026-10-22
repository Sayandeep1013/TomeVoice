import 'model.dart';
import 'segment.dart';

int _nextId = 0;

String _blockId() => 'b${_nextId++}';

void resetBlockIds() => _nextId = 0;

Block makeBlock({
  required BlockRole role,
  required String text,
  Anchor? anchor,
  String? language,
  String? id,
  String? image,
}) {
  final collapsed = collapseWhitespace(text);
  return Block(
    id: id ?? _blockId(),
    role: role,
    text: collapsed,
    sentences: segmentSentences(collapsed),
    anchor: anchor ?? OffsetAnchor(0, collapsed.length),
    language: language,
    image: image,
  );
}

List<Speakable> flattenSpeakable(
  Book book, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final out = <Speakable>[];
  for (final section in book.sections) {
    for (var bi = 0; bi < section.blocks.length; bi++) {
      final block = section.blocks[bi];
      if (skip.contains(block.role) || block.text.isEmpty) continue;
      for (var si = 0; si < block.sentences.length; si++) {
        final sentence = block.sentences[si];
        final text = sentence.of(block.text).trim();
        if (text.isEmpty) continue;
        out.add(Speakable(
          sectionIndex: section.index,
          blockIndex: bi,
          sentenceIndex: si,
          text: text,
          role: block.role,
          blockId: block.id,
        ));
      }
    }
  }
  return out;
}

int indexOfCursor(List<Speakable> units, ReadingCursor cursor) {
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u.sectionIndex == cursor.sectionIndex &&
        u.blockIndex == cursor.blockIndex &&
        u.sentenceIndex == cursor.sentenceIndex) {
      return i;
    }
    if (u.sectionIndex > cursor.sectionIndex) return i;
    if (u.sectionIndex == cursor.sectionIndex &&
        u.blockIndex > cursor.blockIndex) {
      return i;
    }
  }
  return units.isEmpty ? 0 : units.length - 1;
}

ReadingCursor cursorOf(Speakable u) => ReadingCursor(
      sectionIndex: u.sectionIndex,
      blockIndex: u.blockIndex,
      sentenceIndex: u.sentenceIndex,
    );

double progressFraction(List<Speakable> units, int index) {
  if (units.isEmpty) return 0;
  if (index < 0) return 0;
  return ((index + 1) / units.length).clamp(0.0, 1.0);
}

int wordCountOf(Book book) {
  var n = 0;
  for (final s in book.sections) {
    for (final b in s.blocks) {
      n += countWords(b.text);
    }
  }
  return n;
}

/// One chapter's worth of blocks, before indexing.
typedef DraftSection = ({String? title, List<Block> blocks});

/// The common tail of every parser: drop empty sections, index what is left,
/// derive a TOC from the titles and count words.
Book assembleBook({
  required String id,
  required BookMetadata metadata,
  required List<DraftSection> sections,
  required SourceKind source,
  String? filename,
}) {
  final kept = [
    for (final s in sections)
      if (s.blocks.any((b) => b.text.isNotEmpty)) s,
  ];
  final indexed = [
    for (var i = 0; i < kept.length; i++)
      Section(
        id: 's$i',
        index: i,
        title: kept[i].title,
        blocks: kept[i].blocks,
      ),
  ];
  final toc = [
    for (final s in indexed) TocEntry(title: s.displayTitle, sectionIndex: s.index),
  ];
  final book = Book(
    id: id,
    metadata: metadata,
    sections: indexed,
    toc: toc,
    source: source,
    sourceName: filename,
  );
  return book.copyWith(wordCount: wordCountOf(book));
}

/// "my_book-v2.final.txt" -> "my book v2.final". Null if nothing is left.
String? titleFromFilename(String? filename) {
  if (filename == null || filename.isEmpty) return null;
  final slash = filename.replaceAll(r'\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  final stem = dot > 0 ? slash.substring(0, dot) : slash;
  final cleaned = stem.replaceAll(RegExp(r'[_]+'), ' ').trim();
  return cleaned.isEmpty ? null : cleaned;
}

/// Lines that begin a chapter in plain text: "Chapter 12", "CHAPTER XII.",
/// "Part Two", "Prologue", and the Bengali / Hindi equivalents.
final chapterLine = RegExp(
  // A chapter keyword followed by its number ("Chapter 12", "CHAPTER XII.",
  // "Part Two", "অধ্যায় ৩"), or a standalone named section. The number is
  // required: "book of rules for shutting people up" is prose that happens
  // to start with "book".
  r'^(?:(?:chapter|chap\.|part|book|volume|অধ্যায়|পরিচ্ছেদ|পর্ব|अध्याय|भाग)'
  r'[\s.:\-–—]*'
  r'(?:\d+|[ivxlcdm]+|[০-৯]+|[०-९]+|one|two|three|four|five|six|seven|eight|'
  r'nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|'
  r'eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|'
  r'hundred|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|'
  r'last|final)'
  r'(?=$|[\s.:\-–—,])'
  r'|(?:prologue|epilogue|interlude|afterword|introduction|preface|foreword)'
  r'(?=$|[\s.:\-–—,]))'
  r'.{0,70}$',
  caseSensitive: false,
);

bool looksLikeChapterLine(String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > 90) return false;
  if (!chapterLine.hasMatch(t)) return false;
  // "Chapter one was the best part of the book." is prose, not a heading.
  return !RegExp(r'[.!?]\s*\S+\s+\S+\s+\S+').hasMatch(t) || t.length < 40;
}

/// "CHAPTER XII." -> "Chapter XII": all-capital headings in title case
/// (roman numerals kept), trailing full stop dropped.
String tidyHeading(String raw) {
  var t = collapseWhitespace(raw);
  if (t.endsWith('.') && !t.endsWith('...')) t = t.substring(0, t.length - 1);
  if (t != t.toUpperCase() || !RegExp('[A-Z]').hasMatch(t)) return t;
  return t.split(' ').map((w) {
    if (w.length <= 1 || RegExp(r'^[IVXLCDM]+[.:]?$').hasMatch(w)) return w;
    return w[0] + w.substring(1).toLowerCase();
  }).join(' ');
}
