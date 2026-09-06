import 'build.dart';
import 'model.dart';

final _chapterTitle = RegExp(
  r'^(chapter|ch\.?\s*\d|part\s+\d|book\s+\d|prologue|epilogue|'
  r'introduction|preface|afterword|appendix)\b',
  caseSensitive: false,
);

final _untitledSpine = RegExp(r'^section \d+$', caseSensitive: false);

final _frontMatterTitles = <String>{
  'landmarks',
  'table of contents',
  'contents',
  'toc',
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
bool isReadingSection(
  Section section, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final text = speakableTextOf(section, skip: skip);
  if (text.isEmpty) return false;

  final title = section.displayTitle.trim();
  final lower = title.toLowerCase();
  if (_chapterTitle.hasMatch(lower)) return true;
  if (_frontMatterTitles.contains(lower)) return false;
  if (RegExp(r'^●+$').hasMatch(title)) return false;
  if (_opensAsFrontMatter(text)) return false;

  // Untitled calibre/z-lib sheets: "Section 12" with a handful of glyphs.
  if (_untitledSpine.hasMatch(lower) && text.length < 800) return false;

  return text.length >= 80;
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
  final kept = [
    for (final s in book.sections)
      if (spoken.contains(s.index) && isReadingSection(s, skip: skip)) s.index,
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

/// TOC rows for the chapter list: real chapters only, one row per section.
List<TocEntry> readingToc(
  Book book,
  List<Speakable> units, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final chapters = readingSectionIndexes(book, units, skip: skip).toSet();
  if (chapters.isEmpty) return const [];

  final seen = <int>{};
  final fromNav = [
    for (final t in book.toc)
      if (chapters.contains(t.sectionIndex) && seen.add(t.sectionIndex)) t,
  ];
  if (fromNav.length >= chapters.length) return fromNav;

  return [
    for (final s in book.sections)
      if (chapters.contains(s.index))
        TocEntry(title: s.displayTitle, sectionIndex: s.index, href: s.href),
  ];
}

bool _opensAsFrontMatter(String text) {
  final end = text.length < 64 ? text.length : 64;
  final head = text.substring(0, end).toLowerCase().trim();
  for (final t in _frontMatterTitles) {
    if (head == t || head.startsWith('$t ')) return true;
  }
  return false;
}
