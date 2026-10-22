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

  // Fonts without a proper Unicode map hand back control characters and
  // private-use glyphs (a page number came out as U+0018). They are never
  // readable text.
  pages = [for (final p in pages) p.replaceAll(_unreadable, '')];
  final repeated = _repeatedEdgeLines(pages);
  resetBlockIds();

  // Paragraphs per page, already cleaned.
  final perPage = <List<String>>[];
  for (final page in pages) {
    final paras = <String>[];
    for (final rawPara in page.split(pdfParagraphMark)) {
      final lines = [
        for (final l in rawPara.split('\n'))
          if (!_isNoiseLine(l, repeated)) l,
      ];
      final text = joinWrappedLines(lines);
      if (text.isNotEmpty) paras.add(text);
    }
    perPage.add(paras);
  }

  // Reflow. The extractor's paragraph detection is unreliable: on a real
  // device many PDFs came out one line per paragraph, which made the voice
  // pause at every line break. A paragraph continues into the next one unless
  // it ends a sentence or is a heading. This also joins a paragraph that runs
  // over a page break; the joined text stays on the page where it started.
  final merged = <({int page, String text})>[];
  for (var p = 0; p < perPage.length; p++) {
    for (final text in perPage[p]) {
      if (merged.isNotEmpty && _continues(merged.last.text, text)) {
        final last = merged.removeLast();
        merged.add((page: last.page, text: joinWrappedLines([last.text, text])));
      } else {
        merged.add((page: p, text: text));
      }
    }
  }
  for (final page in perPage) {
    page.clear();
  }
  for (final m in merged) {
    perPage[m.page].add(m.text);
  }

  // Blocks remember the page they start on, for the page view.
  var page = 0;
  Block block(String text) => makeBlock(
        role: text.length <= 80 &&
                !RegExp(r'[.!?,;:।]$').hasMatch(text) &&
                looksLikeChapterLine(text)
            ? BlockRole.heading
            : BlockRole.paragraph,
        text: text,
        anchor: PageAnchor(page),
      );
  List<Block> blocksOf(int p) {
    page = p;
    return perPage[p].map(block).toList();
  }

  final usable = [
    for (final o in outline)
      if (o.page >= 0 && o.page < pages.length && o.title.trim().isNotEmpty) o,
  ]..sort((a, b) => a.page.compareTo(b.page));

  final sections = <DraftSection>[];
  if (usable.length >= 2) {
    // Chapters from the outline. Pages before the first entry are front
    // matter and get their own section.
    if (usable.first.page > 0) {
      sections.add((
        title: 'Opening pages',
        blocks: [
          for (var p = 0; p < usable.first.page; p++) ...blocksOf(p),
        ],
      ));
    }
    for (var i = 0; i < usable.length; i++) {
      final from = usable[i].page;
      final to = i + 1 < usable.length ? usable[i + 1].page : pages.length;
      if (to <= from) continue;
      sections.add((
        title: collapseWhitespace(usable[i].title),
        blocks: [for (var p = from; p < to; p++) ...blocksOf(p)],
      ));
    }
  } else {
    sections.addAll(sectionsWithoutOutline([
      for (final m in merged) (page: m.page, text: m.text),
    ]));
  }

  return assembleBook(
    id: id,
    metadata: BookMetadata(
      title: (title ?? '').trim().isNotEmpty
          ? title!.trim()
          : (titleFromFilename(filename) ?? 'Untitled PDF'),
      authors: (author ?? '').trim().isEmpty ? const [] : [author!.trim()],
    ),
    sections: sections,
    source: SourceKind.pdf,
    filename: filename,
  );
}

final _pageNumber = RegExp(
  r'^\s*([-–—(\[]\s*)?(page\s+)?([0-9০-৯०-९]{1,4}|[ivxlcdm]{1,6})'
  r'(\s*(of|/)\s*[0-9]{1,4})?(\s*[-–—)\]])?\s*$',
  caseSensitive: false,
);

bool _isNoiseLine(String line, Set<String> repeated) {
  final t = line.trim();
  if (t.isEmpty) return true;
  if (_pageNumber.hasMatch(t)) return true;
  return repeated.contains(_edgeKey(t));
}

/// Running heads and feet compared by their letters only: page numbers,
/// punctuation and stray glyphs differ from page to page.
String _edgeKey(String line) => collapseWhitespace(
      line.toLowerCase().replaceAll(_notLetters, ' '),
    );

final _notLetters = RegExp(r'[^\p{L}\s]', unicode: true);

/// Lines that appear at the top or bottom of many pages: running headers,
/// footers, the book title on every page.
Set<String> _repeatedEdgeLines(List<String> pages) {
  if (pages.length < 4) return const {};
  final counts = <String, int>{};
  for (final page in pages) {
    final lines = [
      for (final l in page.replaceAll(pdfParagraphMark, '\n').split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    // A page that is nothing but its edges has no header to strip.
    if (lines.length < 4) continue;
    final edges = <String>{
      ...lines.take(2).map(_edgeKey),
      ...lines.reversed.take(2).map(_edgeKey),
    };
    for (final e in edges) {
      // Running heads are short; a long repeated line is probably prose.
      if (e.length > 60) continue;
      counts[e] = (counts[e] ?? 0) + 1;
    }
  }
  final threshold = (pages.length * 0.3).ceil().clamp(3, 1 << 30);
  return {
    for (final e in counts.entries)
      if (e.value >= threshold) e.key,
  };
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

Block _pdfBlock(int page, String text, {bool? heading}) => makeBlock(
      role: (heading ??
              (text.length <= 80 &&
                  !RegExp(r'[.!?,;:।]$').hasMatch(text) &&
                  looksLikeChapterLine(text)))
          ? BlockRole.heading
          : BlockRole.paragraph,
      text: text,
      anchor: PageAnchor(page),
    );

/// Chapters for a PDF without bookmarks. When the text has enough chapter
/// headings ("CHAPTER II", "Part Two"), those are the chapters, named with
/// the line after them when it is a short title. Otherwise ten pages per
/// entry. Every page with text is in one or the other: listing a "chapter"
/// per page and hiding the near-empty ones read as chapters being skipped.
List<DraftSection> sectionsWithoutOutline(List<({int page, String text})> paras) {
  final heads = [
    for (var i = 0; i < paras.length; i++)
      if (_isChapterHeading(paras[i].text)) i,
  ];
  if (heads.length >= 3) {
    final out = <DraftSection>[];
    if (heads.first > 0) {
      out.add((
        title: 'Opening pages',
        blocks: [for (final p in paras.sublist(0, heads.first)) _pdfBlock(p.page, p.text)],
      ));
    }
    for (var h = 0; h < heads.length; h++) {
      final start = heads[h];
      final end = h + 1 < heads.length ? heads[h + 1] : paras.length;
      var title = tidyHeading(paras[start].text);
      if (start + 1 < end) {
        final sub = paras[start + 1].text;
        if (sub.length <= 60 && !RegExp(r'[.!?,;]$').hasMatch(sub)) {
          title = '$title: ${tidyHeading(sub)}';
        }
      }
      out.add((
        title: title,
        blocks: [
          _pdfBlock(paras[start].page, paras[start].text, heading: true),
          for (final p in paras.sublist(start + 1, end)) _pdfBlock(p.page, p.text),
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
        if (p.page >= from && p.page <= to) _pdfBlock(p.page, p.text),
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
