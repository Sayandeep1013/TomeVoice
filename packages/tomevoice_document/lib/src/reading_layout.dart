import 'dart:typed_data';

import 'build.dart';
import 'model.dart';
import 'navigate.dart';
import 'segment.dart';

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
  });

  /// Ordinal among reading chapters (0-based).
  final int chapter;
  final int section;
  final Block? block;

  /// Set for a synthetic chapter-title row, when the chapter's own text does
  /// not open with a heading.
  final String? title;
  final int firstUnit;
  final int unitCount;

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
  });

  final Book book;

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

  /// Index of the unit a saved cursor points at, skipping front matter.
  int unitForCursor(ReadingCursor cursor) {
    if (units.isEmpty) return 0;
    // A new book whose first "chapter" is its title page starts at the next.
    final fresh = cursor.sectionIndex == 0 && cursor.blockIndex == 0 && cursor.sentenceIndex == 0;
    if (fresh && chapters.length > 1 && _same(chapterTitle(0), book.metadata.title)) {
      return chapterFirstUnit[1];
    }
    return readingIndexOfCursor(units, book, cursor);
  }

  static bool _same(String a, String b) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final x = norm(a), y = norm(b);
    return x.isNotEmpty && (x == y || y.startsWith(x) || x.startsWith(y));
  }

  static ReadingLayout build(Book book) {
    final raw = flattenSpeakable(book);
    final chapters = raw.isEmpty
        ? <int>[]
        : readingSectionIndexes(book, raw);
    final keep = chapters.toSet();
    final units = [
      for (final u in raw)
        if (keep.contains(u.sectionIndex)) u,
    ];
    final toc = units.isEmpty ? <TocEntry>[] : readingToc(book, units);

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
        if (previous >= 0 && speakableTextOf(book.sections[s]).length > 300) continue;
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
              .where((b) => b.text.isNotEmpty && !defaultSkippedRoles.contains(b.role))
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
    );
  }

  static String _titleFor(Book book, List<TocEntry> toc, int section) {
    for (final t in toc) {
      if (t.sectionIndex == section) return t.title;
    }
    return book.sections[section].displayTitle;
  }
}
