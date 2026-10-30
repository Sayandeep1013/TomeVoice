import 'model.dart';
import 'segment.dart';

int _nextId = 0;

String _blockId() => 'b${_nextId++}';

void resetBlockIds() => _nextId = 0;

// Noncharacters around text that is shown but not spoken, from a parser to
// [makeBlock]. Unicode promises they never stand for anything in a book.
const _silentOpen = 0xFDD0;
const _silentClose = 0xFDD1;

final _openMark = String.fromCharCode(_silentOpen);
final _closeMark = String.fromCharCode(_silentClose);

/// [text] marked as shown but not spoken (a footnote marker), for a parser
/// to put in the text it hands to [makeBlock].
String silentMark(String text) => text.isEmpty ? '' : '$_openMark$text$_closeMark';

/// [block]'s text with its silent stretches marked again, to build a new
/// block from it (a drop cap joined to its word).
String markedText(Block block) {
  final silent = block.sentences.expand((s) => s.silent).toList();
  if (silent.isEmpty) return block.text;
  final out = StringBuffer();
  var at = 0;
  for (final r in silent) {
    if (r.start < at || r.end > block.text.length) continue;
    out
      ..write(block.text.substring(at, r.start))
      ..write(silentMark(block.text.substring(r.start, r.end)));
    at = r.end;
  }
  out.write(block.text.substring(at));
  return out.toString();
}

Block makeBlock({
  required BlockRole role,
  required String text,
  Anchor? anchor,
  String? language,
  String? id,
  String? image,
}) {
  final (:clean, :silent) = _takeSilent(collapseWhitespace(text));
  return Block(
    id: id ?? _blockId(),
    role: role,
    text: clean,
    sentences: segmentSentences(clean, silent: silent),
    anchor: anchor ?? OffsetAnchor(0, clean.length),
    language: language,
    image: image,
  );
}

/// [text] without its silent marks, and where the marked stretches are.
/// Spaces are collapsed again across a mark, so offsets are final.
({String clean, List<TextStretch> silent}) _takeSilent(String text) {
  if (!text.contains(_openMark) && !text.contains(_closeMark)) {
    return (clean: text, silent: const []);
  }
  final out = StringBuffer();
  final silent = <TextStretch>[];
  var open = -1;
  var lastSpace = true;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == _silentOpen) {
      if (open < 0) open = out.length;
      continue;
    }
    if (c == _silentClose) {
      if (open >= 0 && out.length > open) silent.add((start: open, end: out.length));
      open = -1;
      continue;
    }
    final space = c == 0x20;
    if (space && lastSpace) continue;
    out.writeCharCode(c);
    lastSpace = space;
  }
  var clean = out.toString();
  if (clean.endsWith(' ')) clean = clean.substring(0, clean.length - 1);
  final kept = <TextStretch>[];
  for (final r in silent) {
    if (r.start >= clean.length) continue;
    final end = r.end > clean.length ? clean.length : r.end;
    var start = r.start;
    // "fantasy [1]?" says "fantasy?": the space before a marker goes with
    // it when a stop, a space or nothing comes after.
    if (start > 0 &&
        clean.codeUnitAt(start - 1) == 0x20 &&
        (kept.isEmpty || kept.last.end < start - 1) &&
        (end == clean.length || _closesUp(clean.codeUnitAt(end)))) {
      start--;
    }
    kept.add((start: start, end: end));
  }
  return (clean: clean, silent: kept);
}

bool _closesUp(int c) =>
    c == 0x20 || // space
    c == 0x2E || // .
    c == 0x2C || // ,
    c == 0x3B || // ;
    c == 0x3A || // :
    c == 0x21 || // !
    c == 0x3F || // ?
    c == 0x29 || // )
    c == 0x5D || // ]
    c == 0x22 || // "
    c == 0x201D || // ”
    c == 0x2019 || // ’
    c == 0xBB || // »
    c == 0x2026; // …

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
        final raw = sentence.of(block.text);
        final text = raw.trim();
        if (text.isEmpty) continue;
        out.add(Speakable(
          sectionIndex: section.index,
          blockIndex: bi,
          sentenceIndex: si,
          text: text,
          role: block.role,
          blockId: block.id,
          silent: _relative(sentence, raw.length - raw.trimLeft().length, text.length),
        ));
      }
    }
  }
  return out;
}

/// [sentence]'s silent stretches as offsets in its trimmed text, which
/// starts [lead] characters into it and is [length] long.
List<TextStretch> _relative(Sentence sentence, int lead, int length) {
  if (sentence.silent.isEmpty) return const [];
  final base = sentence.startOffset + lead;
  return [
    for (final r in sentence.silent)
      if (r.end - base > 0 && r.start - base < length)
        (
          start: r.start - base < 0 ? 0 : r.start - base,
          end: r.end - base > length ? length : r.end - base,
        ),
  ];
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
