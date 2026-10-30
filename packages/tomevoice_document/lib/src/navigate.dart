import 'build.dart';
import 'model.dart';

final _chapterTitle = RegExp(
  r'^(chapter|ch\.?\s*\d|part\s+\d|book\s+\d|prologue|epilogue|'
  r'introduction|preface|afterword|appendix)\b',
  caseSensitive: false,
);

final _untitledSpine = RegExp(r'^section \d+$', caseSensitive: false);

/// A contents page: hidden whatever its length (a long book's is long).
const _contentsTitles = <String>{
  'landmarks',
  'table of contents',
  'contents',
  'toc',
};

/// Other front matter: hidden only when short. "Cover Story" is a story.
const _shortFrontTitles = <String>{
  'copyright',
  'copyright page',
  'title page',
  'cover',
  'front cover',
  'full cover',
  'image',
  'dedication',
  'colophon',
};

const _frontMatterTitles = {..._contentsTitles, ..._shortFrontTitles};

/// Longest text a cover, title page or dedication has.
const _shortFront = 1500;

/// Speakable characters in a section after role filters.
String speakableTextOf(
  Section section, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final buf = StringBuffer();
  for (final block in section.blocks) {
    if (skip.contains(block.role) || block.text.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(block.text);
  }
  return buf.toString();
}

/// Spine items that are a cover, TOC, part-divider, or image sheet — not a
/// chapter you sit down to read. Lithium, Apple Books and Moon+ all skip these
/// when opening a book; the TOC still lists real chapters.
///
/// Front matter is only looked for [nearEdge] (see [isNearEdge]): in the
/// middle of a book a story called "Cover Story", a chapter that opens "Image
/// after image..." or one about a publisher is a chapter.
bool isReadingSection(
  Section section, {
  Set<BlockRole> skip = defaultSkippedRoles,
  bool nearEdge = true,
}) {
  final text = speakableTextOf(section, skip: skip);
  if (text.isEmpty) return false;

  final title = section.displayTitle.trim();
  final lower = title.toLowerCase();
  if (_chapterTitle.hasMatch(lower)) return true;
  if (RegExp(r'^●+$').hasMatch(title)) return false;
  if (nearEdge) {
    if (_contentsTitles.contains(lower)) return false;
    if (_shortFrontTitles.contains(lower) && text.length < _shortFront) return false;
    if (_opensAsFrontMatter(text)) return false;
    if (_looksLikeCopyrightPage(text)) return false;
    // Project Gutenberg's notes about editions and transcription.
    if (text.length < 3000 &&
        text.substring(0, text.length < 400 ? text.length : 400).toLowerCase().contains('project gutenberg')) {
      return false;
    }
    // Untitled calibre/z-lib sheets: "Section 12" with a handful of glyphs.
    if (_untitledSpine.hasMatch(lower) && text.length < 800) return false;
  }

  return text.length >= 80;
}

/// Whether section [index] of [count] is near the start or the end of a
/// book, where covers, contents, title and copyright pages are: the first
/// tenth (at least 6, at most 20 sections) or the last twentieth (at least
/// 4, at most 10).
bool isNearEdge(int index, int count) {
  final front = (count / 10).ceil().clamp(6, 20);
  final back = (count / 20).ceil().clamp(4, 10);
  return index < front || index >= count - back;
}

/// Spine indexes that have speakable units *and* look like chapters.
/// Falls back to every spoken section if the heuristic would hide the book.
List<int> readingSectionIndexes(
  Book book,
  List<Speakable> units, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final spoken = <int>{
    for (final u in units) u.sectionIndex,
  };
  final count = book.sections.length;
  final kept = [
    for (final s in book.sections)
      if (spoken.contains(s.index) &&
          isReadingSection(s, skip: skip, nearEdge: isNearEdge(s.index, count)))
        s.index,
  ];
  if (kept.isNotEmpty) return kept;
  return spoken.toList()..sort();
}

/// First sentence of the first real chapter. Used when a book opens on a
/// cover, "Image" alt, or a two-line title page.
int firstReadingUnitIndex(
  List<Speakable> units,
  Book book, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  if (units.isEmpty) return 0;
  final chapters = readingSectionIndexes(book, units, skip: skip);
  if (chapters.isEmpty) return 0;
  final i = units.indexWhere((u) => u.sectionIndex == chapters.first);
  return i < 0 ? 0 : i;
}

/// Restore a saved cursor unless it landed on front matter — then snap to
/// the first chapter, the way other readers skip the cover.
int readingIndexOfCursor(
  List<Speakable> units,
  Book book,
  ReadingCursor cursor, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  if (units.isEmpty) return 0;
  final raw = indexOfCursor(units, cursor);
  final chapters = readingSectionIndexes(book, units, skip: skip);
  if (chapters.isEmpty) return raw;
  final section = units[raw].sectionIndex;
  if (chapters.contains(section)) return raw;
  return firstReadingUnitIndex(units, book, skip: skip);
}

/// TOC rows for the chapter list: real chapters only, one row per section,
/// in reading order. A chapter's row is the book's contents entry for it
/// when there is one, else its own title: a contents that forgot one
/// chapter used to lose every name it did have.
List<TocEntry> readingToc(
  Book book,
  List<Speakable> units, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final chapters = readingSectionIndexes(book, units, skip: skip);
  if (chapters.isEmpty) return const [];

  final named = <int, TocEntry>{};
  for (final t in book.toc) {
    named.putIfAbsent(t.sectionIndex, () => t);
  }
  return [
    for (final c in chapters)
      named[c] ??
          TocEntry(title: book.sections[c].displayTitle, sectionIndex: c, href: book.sections[c].href),
  ];
}

bool _opensAsFrontMatter(String text) {
  final end = text.length < 64 ? text.length : 64;
  final head = text.substring(0, end).toLowerCase().trim();
  for (final t in _frontMatterTitles) {
    if (head == t || head.startsWith('$t ')) {
      return _contentsTitles.contains(t) || text.length < _shortFront;
    }
  }
  return false;
}

final _copyrightMarkers = [
  RegExp(r'©|\(c\) ?\d{4}|copyright \d{4}', caseSensitive: false),
  RegExp(r'all rights reserved', caseSensitive: false),
  RegExp(r'\bisbn\b', caseSensitive: false),
  RegExp(r'work of fiction', caseSensitive: false),
  RegExp(r'library of congress', caseSensitive: false),
  RegExp(r'\bpublished (by|in)\b', caseSensitive: false),
  RegExp(r'\bprinted in\b', caseSensitive: false),
  RegExp(r'first (edition|published)', caseSensitive: false),
];

/// The copyright / legal page: untitled in many EPUBs and long enough to pass
/// for a chapter, but nobody sits down to listen to it.
bool _looksLikeCopyrightPage(String text) {
  if (text.length > 4000) return false;
  var hits = 0;
  for (final m in _copyrightMarkers) {
    if (m.hasMatch(text)) hits++;
    if (hits >= 2) return true;
  }
  return false;
}
