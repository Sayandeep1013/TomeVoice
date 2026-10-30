import 'dart:typed_data';

import 'build.dart';
import 'model.dart';
import 'navigate.dart';
import 'segment.dart';

/// Where a place saved in [before] (the units of the same book as an
/// earlier build parsed it) is in [after], as a unit index.
///
/// A place is section, block and sentence numbers, and a new parse can
/// renumber all three (a chapter split out of its file, notes taken out of
/// the flow) or cut a sentence differently ('"No. Why..."' is now two). So
/// the saved sentence is looked for by its words near where it sat
/// proportionally: the same text first; then a sentence it now starts, or
/// that starts it; then one opening with the same words; failing all, the
/// same share of the way through the book.
int relocateCursor(List<Speakable> before, ReadingCursor cursor, ReadingLayout after) {
  final units = after.units;
  if (units.isEmpty || before.isEmpty) return 0;
  final at = indexOfCursor(before, cursor);
  final text = before[at].text;
  final guess = (at * units.length / before.length).round().clamp(0, units.length - 1);

  int? nearest(bool Function(String other) same) {
    for (var d = 0; d <= 3000; d++) {
      for (final i in [guess - d, guess + d]) {
        if (i >= 0 && i < units.length && same(units[i].text)) return i;
      }
      if (guess - d < 0 && guess + d >= units.length) break;
    }
    return null;
  }

  final key = _words(text);
  final opening = key.split(' ').take(6).join(' ');
  // Sentence i, alone or joined to the ones after it, says what the saved
  // one said: its quotes or spacing changed, or it was cut in two.
  bool startsSplit(int i) {
    var joined = '';
    for (var j = i; j < units.length && j < i + 4; j++) {
      joined = joined.isEmpty ? _words(units[j].text) : '$joined ${_words(units[j].text)}';
      if (joined.isEmpty || !key.startsWith(joined)) return false;
      if (joined.length == key.length) return true;
    }
    return false;
  }

  int? nearestIndex(bool Function(int i) same) {
    for (var d = 0; d <= 3000; d++) {
      for (final i in [guess - d, guess + d]) {
        if (i >= 0 && i < units.length && same(i)) return i;
      }
      if (guess - d < 0 && guess + d >= units.length) break;
    }
    return null;
  }

  return nearest((t) => t == text) ??
      (key.isEmpty ? null : nearestIndex(startsSplit)) ??
      // Joined to the sentence before or after it.
      (key.length < 12 ? null : nearest((t) => _words(t).contains(key))) ??
      (opening.split(' ').length >= 3 ? nearest((t) => _words(t).startsWith(opening)) : null) ??
      guess;
}

final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// [text]'s words, lowercase, one space apart: what a sentence says,
/// whatever quotes and spacing an older parse gave it.
String _words(String text) => text.toLowerCase().replaceAll(_notWord, ' ').trim();

/// One row of the reading list: a chapter title, or one block of text with the
/// speakable units it contains.
class LayoutItem {
  const LayoutItem({
    required this.chapter,
    required this.section,
    this.block,
    this.title,
    this.firstUnit = 0,
    this.unitCount = 0,
    this.displayOnly = false,
  });

  /// Ordinal among reading chapters (0-based).
  final int chapter;
  final int section;
  final Block? block;

  /// Set for a synthetic chapter-title row, when the chapter's own text does
  /// not open with a heading.
  final String? title;

  /// For a block with units, its first; otherwise (a picture, a
  /// display-only block) the unit that comes after it, which may be
  /// `units.length` at the very end of the book.
  final int firstUnit;
  final int unitCount;

  /// A block shown but never spoken (a footnote, a caption, a picture's
  /// text): it has no units. Only in layouts built with displayOnly.
  final bool displayOnly;

  bool get isTitle => block == null;
  bool get isImage => block?.isImage ?? false;
  bool containsUnit(int u) => u >= firstUnit && u < firstUnit + unitCount;
}

/// Everything the reader needs, precomputed once (on a background isolate)
/// so that nothing on the UI thread ever walks the whole book.
///
/// The reader used to rebuild on every sentence and, in that rebuild, scan all
/// 34,000 units of a long EPUB three times to find the current chapter. That
/// was most of the lag between tapping and anything happening.
class ReadingLayout {
  ReadingLayout._({
    required this.book,
    required this.units,
    required this.items,
    required this.chapters,
    required this.toc,
    required this.unitItem,
    required this.unitChapter,
    required this.unitOffset,
    required this.wordsBefore,
    required this.chapterFirstUnit,
    required this.chapterFirstItem,
    required this.unitPage,
    required this.skipped,
  });

  final Book book;

  /// The roles this layout does not speak: [defaultSkippedRoles] less the
  /// ones it was built to speak (see [build]).
  final Set<BlockRole> skipped;

  /// Units that will be spoken, in order (front matter removed).
  final List<Speakable> units;
  final List<LayoutItem> items;

  /// Section index of each reading chapter.
  final List<int> chapters;
  final List<TocEntry> toc;

  /// unit -> index into [items].
  final Int32List unitItem;

  /// unit -> chapter ordinal.
  final Int32List unitChapter;

  /// unit -> character offset of its text within its block's text.
  final Int32List unitOffset;

  /// unit -> words in all units before it (length units + 1).
  final Int32List wordsBefore;

  /// chapter -> first unit / first item.
  final Int32List chapterFirstUnit;
  final Int32List chapterFirstItem;

  /// unit -> 0-based PDF page it starts on, or -1 when the source has no
  /// pages (or was parsed before pages were recorded).
  final Int32List unitPage;

  bool get hasPages => unitPage.isNotEmpty && unitPage.first >= 0;

  /// First unit on or after PDF [page].
  int unitForPage(int page) {
    if (!hasPages) return 0;
    var lo = 0, hi = units.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (unitPage[mid] < page) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  bool get isEmpty => units.isEmpty;
  int get totalWords => wordsBefore.isEmpty ? 0 : wordsBefore.last;

  String chapterTitle(int chapter) {
    if (chapter < 0 || chapter >= chapters.length) return '';
    final s = chapters[chapter];
    for (final t in toc) {
      if (t.sectionIndex == s) return _short(t.title);
    }
    return _short(book.sections[s].displayTitle);
  }

  /// A heading that is really a paragraph makes a poor chapter name.
  static String _short(String t) {
    if (t.length <= 64) return t;
    final cut = t.lastIndexOf(' ', 60);
    return '${t.substring(0, cut > 20 ? cut : 60)}…';
  }

  int chapterOfUnit(int u) =>
      units.isEmpty ? 0 : unitChapter[u.clamp(0, units.length - 1)];

  /// Units in [chapter]: (first, count).
  (int, int) chapterRange(int chapter) {
    final first = chapterFirstUnit[chapter];
    final end = chapter + 1 < chapters.length
        ? chapterFirstUnit[chapter + 1]
        : units.length;
    return (first, end - first);
  }

  /// Index of the unit a cursor points at, skipping front matter.
  ///
  /// A new book whose first "chapter" is only its title page (short, and
  /// named like the book) starts at the next one. Not a collection whose
  /// first story gives the book its name ("The Lottery" in "The Lottery and
  /// Other Stories"), and never a place the reader [saved], even one on
  /// the very first sentence.
  int unitForCursor(ReadingCursor cursor, {bool saved = false}) {
    if (units.isEmpty) return 0;
    final fresh = cursor.sectionIndex == 0 && cursor.blockIndex == 0 && cursor.sentenceIndex == 0;
    if (fresh && !saved && chapters.length > 1 && _isTitlePage(0)) return chapterFirstUnit[1];
    return readingIndexOfCursor(units, book, cursor, skip: skipped);
  }

  /// Chapter [c] is a title page: a few short lines named like the book.
  bool _isTitlePage(int c) {
    final (first, count) = chapterRange(c);
    final words = wordsBefore[first + count] - wordsBefore[first];
    return count <= 12 && words < 60 && _same(chapterTitle(c), book.metadata.title);
  }

  static bool _same(String a, String b) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final x = norm(a), y = norm(b);
    return x.isNotEmpty && (x == y || y.startsWith(x) || x.startsWith(y));
  }

  /// Roles whose text [build] can show without speaking: notes, captions,
  /// a picture's words.
  static const displayOnlyRoles = {BlockRole.footnote, BlockRole.caption, BlockRole.figure};

  /// The layout of [book]. With [displayOnly], blocks of [displayOnlyRoles]
  /// that the voice skips are items too, with no units, where they stand
  /// in their chapter; the units, chapters and word counts are the same
  /// either way. Off by default: the reader shows what it always did.
  ///
  /// [spoken]: roles the voice skips by default ([defaultSkippedRoles]) to
  /// read aloud in this layout, as footnotes for a reader who wants them.
  /// Their blocks become units and items like any paragraph (a section of
  /// notes alone becomes a chapter). The markers that point at them stay
  /// silent: those are stretches of the sentence they sit in.
  static ReadingLayout build(Book book, {bool displayOnly = false, Set<BlockRole> spoken = const {}}) {
    final skip = spoken.isEmpty ? defaultSkippedRoles : defaultSkippedRoles.difference(spoken);
    final raw = flattenSpeakable(book, skip: skip);
    final chapters = raw.isEmpty
        ? <int>[]
        : readingSectionIndexes(book, raw, skip: skip);
    final keep = chapters.toSet();
    final units = [
      for (final u in raw)
        if (keep.contains(u.sectionIndex)) u,
    ];
    final toc = units.isEmpty ? <TocEntry>[] : readingToc(book, units, skip: skip);

    final items = <LayoutItem>[];
    final unitItem = Int32List(units.length);
    final unitChapter = Int32List(units.length);
    final unitOffset = Int32List(units.length);
    final wordsBefore = Int32List(units.length + 1);
    final chapterFirstUnit = Int32List(chapters.length);
    final chapterFirstItem = Int32List(chapters.length);
    final unitPage = Int32List(units.length);

    // Sections that are only pictures (maps, the cover, plates) have nothing
    // to speak, so they are not chapters. Show their pictures at the start of
    // the next chapter instead of dropping them.
    var previous = -1;
    List<Block> picturesBefore(int section) {
      final out = <Block>[];
      for (var s = previous + 1; s < section && s < book.sections.length; s++) {
        if (keep.contains(s)) continue;
        final blocks = book.sections[s].blocks;
        // A map page often carries a caption ("The Seven Kingdoms"); a
        // copyright page with a publisher logo does not need showing. Before
        // the first chapter, though, every picture is front matter worth
        // seeing: cover, frontispiece, title page.
        if (previous >= 0 && speakableTextOf(book.sections[s], skip: skip).length > 300) continue;
        out.addAll(blocks.where((b) => b.isImage && b.imageWidth != null));
      }
      previous = section;
      return out;
    }

    var u = 0;
    for (var c = 0; c < chapters.length; c++) {
      final sectionIndex = chapters[c];
      final section = book.sections[sectionIndex];
      chapterFirstUnit[c] = u;
      chapterFirstItem[c] = items.length;
      for (final picture in picturesBefore(sectionIndex)) {
        items.add(LayoutItem(chapter: c, section: sectionIndex, block: picture, firstUnit: u));
      }

      final opensWithHeading = section.blocks
              .where((b) => b.text.isNotEmpty && !skip.contains(b.role))
              .firstOrNull
              ?.role ==
          BlockRole.heading;
      if (!opensWithHeading) {
        items.add(LayoutItem(
          chapter: c,
          section: sectionIndex,
          title: _titleFor(book, toc, sectionIndex),
          firstUnit: u,
        ));
      }

      for (var bi = 0; bi < section.blocks.length; bi++) {
        final block = section.blocks[bi];
        if (block.isImage && block.imageWidth != null) {
          items.add(LayoutItem(chapter: c, section: sectionIndex, block: block, firstUnit: u));
          continue;
        }
        if (displayOnly &&
            block.text.isNotEmpty &&
            displayOnlyRoles.contains(block.role) &&
            skip.contains(block.role)) {
          items.add(LayoutItem(chapter: c, section: sectionIndex, block: block, firstUnit: u, displayOnly: true));
          continue;
        }
        final first = u;
        while (u < units.length &&
            units[u].sectionIndex == sectionIndex &&
            units[u].blockIndex == bi) {
          final unit = units[u];
          final s = block.sentences[unit.sentenceIndex];
          final rawText = block.text.substring(s.startOffset, s.endOffset);
          unitOffset[u] = s.startOffset + (rawText.length - rawText.trimLeft().length);
          unitItem[u] = items.length;
          unitChapter[u] = c;
          final anchor = block.anchor;
          unitPage[u] = anchor is PageAnchor ? anchor.page : -1;
          wordsBefore[u + 1] = wordsBefore[u] + countWords(unit.text);
          u++;
        }
        if (u == first) continue;
        items.add(LayoutItem(
          chapter: c,
          section: sectionIndex,
          block: block,
          firstUnit: first,
          unitCount: u - first,
        ));
      }
    }

    return ReadingLayout._(
      book: book,
      units: units,
      items: items,
      chapters: chapters,
      toc: toc,
      unitItem: unitItem,
      unitChapter: unitChapter,
      unitOffset: unitOffset,
      wordsBefore: wordsBefore,
      chapterFirstUnit: chapterFirstUnit,
      chapterFirstItem: chapterFirstItem,
      unitPage: unitPage,
      skipped: skip,
    );
  }

  static String _titleFor(Book book, List<TocEntry> toc, int section) {
    for (final t in toc) {
      if (t.sectionIndex == section) return t.title;
    }
    return book.sections[section].displayTitle;
  }
}
