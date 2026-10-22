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

  // Join a paragraph that runs over a page break into the earlier page.
  for (var p = 0; p + 1 < perPage.length; p++) {
    final here = perPage[p];
    final next = perPage[p + 1];
    if (here.isEmpty || next.isEmpty) continue;
    final last = here.last;
    final first = next.first;
    final ends = RegExp(r'[.!?।"”’:)\]]$').hasMatch(last);
    final startsLower = RegExp(r'^[a-z]').hasMatch(first);
    if (!ends && (startsLower || !RegExp(r'^[A-Z"“‘(]').hasMatch(first))) {
      here[here.length - 1] = joinWrappedLines([last, first]);
      next.removeAt(0);
    }
  }

  Block block(String text) => makeBlock(
        role: text.length <= 80 &&
                !RegExp(r'[.!?,;:।]$').hasMatch(text) &&
                looksLikeChapterLine(text)
            ? BlockRole.heading
            : BlockRole.paragraph,
        text: text,
      );

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
          for (var p = 0; p < usable.first.page; p++) ...perPage[p].map(block),
        ],
      ));
    }
    for (var i = 0; i < usable.length; i++) {
      final from = usable[i].page;
      final to = i + 1 < usable.length ? usable[i + 1].page : pages.length;
      if (to <= from) continue;
      sections.add((
        title: collapseWhitespace(usable[i].title),
        blocks: [for (var p = from; p < to; p++) ...perPage[p].map(block)],
      ));
    }
  } else {
    // No outline: one section per page, so "Page 12" is a place you can go.
    for (var p = 0; p < perPage.length; p++) {
      sections.add((title: 'Page ${p + 1}', blocks: perPage[p].map(block).toList()));
    }
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

String _edgeKey(String line) =>
    collapseWhitespace(line).toLowerCase().replaceAll(RegExp(r'[0-9০-৯०-९]+'), '#');

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
