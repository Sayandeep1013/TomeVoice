import 'dart:math' as math;

import '../build.dart';
import '../model.dart';
import '../segment.dart';
import 'text.dart';

/// Paragraph mark the platform extractor puts at the start of each paragraph
/// it detects (U+2029 PARAGRAPH SEPARATOR). Lines inside a paragraph are
/// separated by `\n`.
const pdfParagraphMark = '\u2029';

/// One outline (bookmark) entry: a title and the 0-based page it points at.
typedef PdfOutlineEntry = ({String title, int page});

/// Build a [Book] from per-page text that the platform extracted.
///
/// The platform does the glyph work; this does the reading-order clean-up
/// that makes a PDF listenable: running headers/footers and page numbers are
/// dropped, hyphenated line breaks are mended, a paragraph split across a
/// page break is joined, and the PDF outline becomes the chapter list.
Book bookFromPdfText({
  required String id,
  required List<String> pages,
  List<PdfOutlineEntry> outline = const [],
  String? title,
  String? author,
  String? filename,
}) {
  final textChars = pages.fold<int>(0, (n, p) => n + p.trim().length);
  if (pages.isEmpty || textChars < 40 * pages.length.clamp(1, 20)) {
    throw const UnsupportedDocumentException(
      'This PDF has no selectable text — it looks like scanned page images. '
      'TomeVoice can only read PDFs that contain real text.',
    );
  }
  resetBlockIds();

  final lines = [for (final page in pages) _linesOf(page)];
  final furniture = _furniture(lines);
  for (var p = 0; p < lines.length; p++) {
    if (furniture[p].isEmpty) continue;
    lines[p] = [
      for (var i = 0; i < lines[p].length; i++)
        if (!furniture[p].contains(i)) lines[p][i],
    ];
  }

  // Reflow. The extractor's paragraph detection is unreliable: on a real
  // device many PDFs came out one line per paragraph, which made the voice
  // pause at every line break. A paragraph continues into the next one unless
  // it ends a sentence or is a heading. This also joins a paragraph that runs
  // over a page break; the joined text stays on the page where it started.
  final paras = <_Para>[];
  for (var p = 0; p < lines.length; p++) {
    // A printed table of contents is read line by line, and none of its
    // lines is a heading: they name chapters that come later.
    final contents = _isContentsPage(lines[p]);
    for (final text in _paragraphs(lines[p], lineByLine: contents)) {
      final last = paras.isEmpty ? null : paras.last;
      if (!contents && last != null && !last.fixed && _continues(last.text, text)) {
        paras[paras.length - 1] = _Para(last.page, joinWrappedLines([last.text, text]));
      } else {
        paras.add(contents ? _Para(p, text, role: BlockRole.paragraph, fixed: true) : _Para(p, text));
      }
    }
  }

  final usable = [
    for (final o in outline)
      if (o.page >= 0 && o.page < pages.length && o.title.trim().isNotEmpty) o,
  ]..sort((a, b) => a.page.compareTo(b.page));

  return assembleBook(
    id: id,
    metadata: BookMetadata(
      title: (title ?? '').trim().isNotEmpty
          ? title!.trim()
          : (titleFromFilename(filename) ?? 'Untitled PDF'),
      authors: (author ?? '').trim().isEmpty ? const [] : [author!.trim()],
    ),
    sections: usable.length >= 2
        ? _sectionsFromOutline(paras, usable, pages.length)
        : _sectionsFromHeadings(paras),
    source: SourceKind.pdf,
    filename: filename,
  );
}

/// One line of a page, and which of the extractor's paragraphs it is in.
class _Line {
  const _Line(this.text, this.para);
  final String text;
  final int para;
}

/// A paragraph of the reflowed text and the page it starts on.
class _Para {
  const _Para(this.page, this.text, {this.role, this.fixed = false});
  final int page;
  final String text;

  /// Set when the role is already known; otherwise a chapter line is a
  /// heading.
  final BlockRole? role;

  /// Never joined to the paragraphs around it.
  final bool fixed;
}

/// The page's lines as the extractor wrote them; a paragraph starts at each
/// paragraph mark.
List<_Line> _linesOf(String page) {
  final out = <_Line>[];
  final chunks = page.split(pdfParagraphMark);
  for (var c = 0; c < chunks.length; c++) {
    for (final raw in chunks[c].split('\n')) {
      // Fonts without a proper Unicode map hand back control characters and
      // private-use glyphs (a page number came out as U+0018). They are never
      // readable text.
      final t = raw.replaceAll(_unreadable, '').trim();
      if (t.isNotEmpty) out.add(_Line(t, c));
    }
  }
  return out;
}

/// The page's paragraphs: lines joined within each of the extractor's
/// paragraphs, or one paragraph per line when [lineByLine].
List<String> _paragraphs(List<_Line> lines, {required bool lineByLine}) {
  final out = <String>[];
  var group = <String>[];
  void flush() {
    final text = joinWrappedLines(group);
    if (text.isNotEmpty) out.add(text);
    group = [];
  }

  for (var i = 0; i < lines.length; i++) {
    if (i > 0 && (lineByLine || lines[i].para != lines[i - 1].para)) flush();
    group.add(lines[i].text);
  }
  flush();
  return out;
}

/// How many pages either side of a page to look for its running head again.
const _near = 4;

/// The furniture on each page, as line indexes: running heads and feet, and
/// printed page numbers. None of it is read, and none of it may end up in
/// the middle of a sentence that runs over the page ("over to the THE NOBLE
/// BACHELOR 51").
List<Set<int>> _furniture(List<List<_Line>> pages) {
  final edges = [for (final page in pages) _edges(page)];
  final out = [for (var p = 0; p < pages.length; p++) <int>{}];

  // Page numbers: a number alone on a line at the top or bottom of the page
  // that counts up with the pages. "1914" or "II" alone in the text is text.
  final numbers = [
    for (var p = 0; p < pages.length; p++)
      [
        for (final i in edges[p])
          if (_pageNumberOf(pages[p][i].text) case final n?)
            (line: i, value: n.value, roman: n.roman),
      ],
  ];
  for (var p = 0; p < pages.length; p++) {
    for (final n in numbers[p]) {
      if (_countsWithPages(numbers, p, n)) out[p].add(n.line);
    }
  }

  // Running heads and feet: the same words at the edge of many pages, or of
  // a few pages close together (a story's title over its own pages, too few
  // to count book-wide).
  final keys = [
    for (var p = 0; p < pages.length; p++)
      [
        for (final i in edges[p])
          (key: _edgeKey(pages[p][i].text), numbered: _numbered(pages[p][i].text)),
      ],
  ];
  final atEdges = [for (final k in keys) {for (final e in k) e.key}];
  final bare = <String, int>{};
  final numbered = <String, int>{};
  for (final k in keys) {
    for (final e in k) {
      final counts = e.numbered ? numbered : bare;
      counts[e.key] = (counts[e.key] ?? 0) + 1;
    }
  }
  final everywhere = _repeatedEdgeLines(pages, atEdges);
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    for (var i = 0; i < page.length; i++) {
      if (out[p].contains(i)) continue;
      final key = _edgeKey(page[i].text);
      // Running heads are short; a long repeated line is probably prose.
      if (key.isEmpty || key.length > 60) continue;
      final atEdge = edges[p].contains(i);
      if (!everywhere.contains(key) && !(atEdge && _pagesNearWith(atEdges, p, key) >= 2)) {
        continue;
      }
      // The chapter's title under its "Chapter N" line is a heading, though
      // the running heads repeat it.
      if (i > 0 && !out[p].contains(i - 1) && looksLikeChapterLine(page[i - 1].text)) continue;
      // So is the one copy without a number when every other copy has one:
      // the heading the running heads ("THE NOBLE BACHELOR 51") are taken from.
      if (atEdge && !_numbered(page[i].text) && bare[key] == 1 && (numbered[key] ?? 0) > 0) {
        continue;
      }
      out[p].add(i);
    }
  }
  return out;
}

/// The lines at a page's top and bottom edges: the first and last two as
/// drawn, or all of a short page's.
List<int> _edges(List<_Line> page) {
  final n = page.length;
  return n <= 4 ? [for (var i = 0; i < n; i++) i] : [0, 1, n - 2, n - 1];
}

final _digit = RegExp(r'\p{Nd}', unicode: true);

/// Whether a line carries a number of its own, such as a running head's page
/// number; a chapter line's number is part of its name.
bool _numbered(String line) {
  if (_leadingNumber.hasMatch(line)) return true;
  final chapter = looksLikeChapterLine(line) ? _chapterNumber.firstMatch(line) : null;
  return _digit.hasMatch(chapter == null ? line : line.substring(chapter.end));
}

/// How many pages near [p] have [key] at an edge.
int _pagesNearWith(List<Set<String>> atEdges, int p, String key) {
  var n = 0;
  final last = math.min(atEdges.length - 1, p + _near);
  for (var q = math.max(0, p - _near); q <= last; q++) {
    if (q != p && atEdges[q].contains(key)) n++;
  }
  return n;
}

final _pageNumber = RegExp(
  r'^\s*([-–—(\[]\s*)?(page\s+)?([0-9০-৯०-९]{1,4}|[ivxlcdm]{1,6})'
  r'(\s*(of|/)\s*[0-9]{1,4})?(\s*[-–—)\]])?\s*$',
  caseSensitive: false,
);

/// The value of a line that is only a page number ("12", "- 12 -", "Page 12
/// of 300", "xiv"); null for anything else.
({int value, bool roman})? _pageNumberOf(String line) {
  final number = _pageNumber.firstMatch(line)?.group(3);
  if (number == null) return null;
  final digits = _digitsValue(number);
  if (digits != null) return (value: digits, roman: false);
  final roman = _romanValue(number);
  return roman == null ? null : (value: roman, roman: true);
}

/// Western, Bengali and Devanagari digits.
int? _digitsValue(String s) {
  var v = 0;
  for (final c in s.codeUnits) {
    final d = c >= 0x30 && c <= 0x39
        ? c - 0x30
        : c >= 0x09E6 && c <= 0x09EF
            ? c - 0x09E6
            : c >= 0x0966 && c <= 0x096F
                ? c - 0x0966
                : -1;
    if (d < 0) return null;
    v = v * 10 + d;
  }
  return v;
}

/// A well-formed roman numeral's value ("xiv" is 14; "mid" is not one).
int? _romanValue(String s) {
  const values = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000};
  final u = s.toUpperCase();
  var total = 0;
  for (var i = 0; i < u.length; i++) {
    final v = values[u[i]];
    if (v == null) return null;
    final next = i + 1 < u.length ? values[u[i + 1]] ?? 0 : 0;
    total += v < next ? -v : v;
  }
  return total > 0 && _roman(total) == u ? total : null;
}

String _roman(int n) {
  const table = [
    (1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'), (100, 'C'), (90, 'XC'), //
    (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I'),
  ];
  final out = StringBuffer();
  for (final (value, letters) in table) {
    while (n >= value) {
      out.write(letters);
      n -= value;
    }
  }
  return out.toString();
}

/// Whether a number at page [p]'s edge counts with the pages: another page
/// near it has a number that is as far on as the page is (or twice as far,
/// for two book pages printed on one), or it is simply the page's place in
/// the file.
bool _countsWithPages(
  List<List<({int line, int value, bool roman})>> numbers,
  int p,
  ({int line, int value, bool roman}) n,
) {
  if (!n.roman && n.value == p + 1) return true;
  final last = math.min(numbers.length - 1, p + _near);
  for (var q = math.max(0, p - _near); q <= last; q++) {
    if (q == p) continue;
    for (final o in numbers[q]) {
      if (o.roman != n.roman) continue;
      final ahead = o.value - n.value;
      if (ahead == q - p || ahead == 2 * (q - p)) return true;
    }
  }
  return false;
}

/// Running heads and feet compared by their letters only: page numbers,
/// punctuation and stray glyphs differ from page to page. A chapter line
/// keeps its number, so "Chapter 12" and "Chapter 13" are two headings
/// rather than one running head.
String _edgeKey(String line) {
  final letters = collapseWhitespace(line.toLowerCase().replaceAll(_notLetters, ' '));
  final t = line.replaceFirst(_leadingNumber, '');
  if (!looksLikeChapterLine(t)) return letters;
  final number = _chapterNumber.firstMatch(t)?.group(1);
  return number == null ? letters : '$letters #${number.toLowerCase()}';
}

final _notLetters = RegExp(r'[^\p{L}\s]', unicode: true);
final _leadingNumber = RegExp(r'^\s*\d{1,4}\s+');
final _chapterNumber = RegExp(r'^\s*\S+[\s.:\-–—]*([\p{L}\p{N}]+)', unicode: true);

/// Lines that appear at the top or bottom of many pages: running headers,
/// footers, the book title on every page.
Set<String> _repeatedEdgeLines(List<List<_Line>> pages, List<Set<String>> atEdges) {
  if (pages.length < 4) return const {};
  final counts = <String, int>{};
  for (var p = 0; p < pages.length; p++) {
    // A page that is nothing but its edges has no header to strip.
    if (pages[p].length < 4) continue;
    for (final e in atEdges[p]) {
      if (e.isEmpty || e.length > 60) continue;
      counts[e] = (counts[e] ?? 0) + 1;
    }
  }
  final threshold = math.max(3, (pages.length * 0.3).ceil());
  return {
    for (final e in counts.entries)
      if (e.value >= threshold) e.key,
  };
}

final _contentsHeading = RegExp(
  r'^(table of )?contents$|^inhalt(sverzeichnis)?$|^table des matières$|'
  r'^sommaire$|^índice$|^indice$|^содержание$|^оглавление$',
);

/// A line ending in a page reference: "The Salt Road 31", "Preface .... ix".
final _pageRef = RegExp(r'(\s|\.{2,}|…)(\d{1,4}|[ivxlc]{1,7})$');

/// A printed table of contents: a "Contents" heading over page references,
/// or a page that is mostly lines ending in page numbers, or naming chapters.
bool _isContentsPage(List<_Line> page) {
  if (page.length < 3) return false;
  var refs = 0, chapters = 0;
  for (final l in page) {
    if (_pageRef.hasMatch(l.text)) refs++;
    if (looksLikeChapterLine(l.text)) chapters++;
  }
  final titled = page.take(3).any(
        (l) => _contentsHeading.hasMatch(
          collapseWhitespace(l.text.toLowerCase().replaceAll(_notLetters, ' ')),
        ),
      );
  return (titled && refs >= 2) ||
      (refs >= 4 && refs * 2 >= page.length) ||
      (chapters >= 4 && chapters * 2 >= page.length);
}

/// Does [next] carry on the paragraph that [prev] started?
bool _continues(String prev, String next) {
  if (RegExp(r'[.!?।…"”’:;)\]]$').hasMatch(prev)) return false;
  if (looksLikeChapterLine(prev) || looksLikeChapterLine(next)) return false;
  if (RegExp(r'^[a-z]').hasMatch(next)) return true;
  // A short line before a capital is a title, or a line of verse.
  return prev.length >= 40;
}

/// C0 controls (except newline and the paragraph mark), the replacement
/// character and the private-use area.
final _unreadable = RegExp('[\x00-\x09\x0B-\x1F\uFFFD\uE000-\uF8FF]');

bool _isChapterHeading(String t) => t.length <= 60 && looksLikeChapterLine(t);

bool _looksLikeHeading(String text) =>
    text.length <= 80 && !RegExp(r'[.!?,;:।]$').hasMatch(text) && looksLikeChapterLine(text);

/// Blocks remember the page they start on, for the page view.
Block _block(_Para p, {bool heading = false}) => makeBlock(
      role: heading
          ? BlockRole.heading
          : p.role ?? (_looksLikeHeading(p.text) ? BlockRole.heading : BlockRole.paragraph),
      text: p.text,
      anchor: PageAnchor(p.page),
    );

/// Chapters from the outline. Pages before the first entry are front matter
/// and get their own section.
List<DraftSection> _sectionsFromOutline(
  List<_Para> paras,
  List<PdfOutlineEntry> outline,
  int pageCount,
) {
  List<Block> blocksOn(int from, int to) => [
        for (final p in paras)
          if (p.page >= from && p.page < to) _block(p),
      ];
  final out = <DraftSection>[];
  if (outline.first.page > 0) {
    out.add((title: 'Opening pages', blocks: blocksOn(0, outline.first.page)));
  }
  for (var i = 0; i < outline.length; i++) {
    final from = outline[i].page;
    final to = i + 1 < outline.length ? outline[i + 1].page : pageCount;
    if (to <= from) continue;
    out.add((title: collapseWhitespace(outline[i].title), blocks: blocksOn(from, to)));
  }
  return out;
}

/// Chapters for a PDF without bookmarks. When the text has enough chapter
/// headings ("CHAPTER II", "Part Two"), those are the chapters, named with
/// the line after them when it is a short title. Otherwise ten pages per
/// entry. Every page with text is in one or the other: listing a "chapter"
/// per page and hiding the near-empty ones read as chapters being skipped.
List<DraftSection> sectionsWithoutOutline(List<({int page, String text})> paras) =>
    _sectionsFromHeadings([for (final p in paras) _Para(p.page, p.text)]);

List<DraftSection> _sectionsFromHeadings(List<_Para> paras) {
  final heads = [
    for (var i = 0; i < paras.length; i++)
      if (paras[i].role == null && _isChapterHeading(paras[i].text)) i,
  ];
  if (heads.length >= 3) {
    final out = <DraftSection>[];
    if (heads.first > 0) {
      out.add((
        title: 'Opening pages',
        blocks: [for (final p in paras.sublist(0, heads.first)) _block(p)],
      ));
    }
    for (var h = 0; h < heads.length; h++) {
      final start = heads[h];
      final end = h + 1 < heads.length ? heads[h + 1] : paras.length;
      var title = tidyHeading(paras[start].text);
      if (start + 1 < end && paras[start + 1].role == null) {
        final sub = paras[start + 1].text;
        if (sub.length <= 60 && !RegExp(r'[.!?,;]$').hasMatch(sub)) {
          title = '$title: ${tidyHeading(sub)}';
        }
      }
      out.add((
        title: title,
        blocks: [
          _block(paras[start], heading: true),
          for (final p in paras.sublist(start + 1, end)) _block(p),
        ],
      ));
    }
    return out;
  }

  final out = <DraftSection>[];
  if (paras.isEmpty) return out;
  final last = paras.map((p) => p.page).reduce((a, b) => a > b ? a : b);
  for (var from = 0; from <= last; from += 10) {
    final to = from + 9 < last ? from + 9 : last;
    final blocks = [
      for (final p in paras)
        if (p.page >= from && p.page <= to) _block(p),
    ];
    if (blocks.isEmpty) continue;
    out.add((title: from == to ? 'Page ${from + 1}' : 'Pages ${from + 1}–${to + 1}', blocks: blocks));
  }
  return out;
}

final _pageTitle = RegExp(r'^Page (\d+)$');

/// A PDF stored by an earlier build with one section per page gets real
/// chapters (or ten-page groups) from its stored text, without re-reading
/// the file. Anything else is returned unchanged.
Book resectionPdf(Book book) {
  if (book.source != SourceKind.pdf || book.sections.length < 2) return book;
  if (!book.sections.every((s) => _pageTitle.hasMatch(s.title ?? ''))) return book;
  final paras = <({int page, String text})>[];
  for (final s in book.sections) {
    final fallback = int.parse(_pageTitle.firstMatch(s.title!)!.group(1)!) - 1;
    for (final b in s.blocks) {
      final a = b.anchor;
      paras.add((page: a is PageAnchor ? a.page : fallback, text: b.text));
    }
  }
  resetBlockIds();
  final sections = sectionsWithoutOutline(paras);
  if (sections.isEmpty) return book;
  final rebuilt = assembleBook(
    id: book.id,
    metadata: book.metadata,
    sections: sections,
    source: SourceKind.pdf,
    filename: book.sourceName,
  );
  return rebuilt;
}
