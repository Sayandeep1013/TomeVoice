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

  bool get isEmpty => units.isEmpty;
  int get totalWords => wordsBefore.isEmpty ? 0 : wordsBefore.last;

  String chapterTitle(int chapter) {
    if (chapter < 0 || chapter >= chapters.length) return '';
    final s = chapters[chapter];
    for (final t in toc) {
      if (t.sectionIndex == s) return t.title;
    }
    return book.sections[s].displayTitle;
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
  int unitForCursor(ReadingCursor cursor) =>
      units.isEmpty ? 0 : readingIndexOfCursor(units, book, cursor);

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

    var u = 0;
    for (var c = 0; c < chapters.length; c++) {
      final sectionIndex = chapters[c];
      final section = book.sections[sectionIndex];
      chapterFirstUnit[c] = u;
      chapterFirstItem[c] = items.length;

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
    );
  }

  static String _titleFor(Book book, List<TocEntry> toc, int section) {
    for (final t in toc) {
      if (t.sectionIndex == section) return t.title;
    }
    return book.sections[section].displayTitle;
  }
}
