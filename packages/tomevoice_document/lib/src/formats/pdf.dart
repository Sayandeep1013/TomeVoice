import 'dart:math' as math;

import '../build.dart';
import '../model.dart';
import '../segment.dart';
import 'text.dart';

/// Paragraph mark the platform extractor puts at the start of each paragraph
/// it detects (U+2029 PARAGRAPH SEPARATOR). Lines inside a paragraph are
/// separated by `\n`.
const pdfParagraphMark = '\u2029';

/// Bumped when reading PDFs improves enough that a stored PDF should be read
/// from its file again. Only the platform can extract a PDF's text, so the
/// app keeps a PDF as it was parsed at import unless it stores this number
/// with it and extracts again when it is older (2: running heads on nearby
/// pages, contents pages, nested bookmarks, hyphens in any script, footnotes
/// and columns from the line layout; 3: paragraphs set in by an indent,
/// which the extractor ran together, dialogue above all; 4: a title run
/// into its text, a short chapter's running head, title and contents pages
/// not read on opening; 5: a scan's bookmarks named after its pictures, or
/// one on every page, are not chapters; two speakers' lines set in one
/// after the other, and a line ending in a colon over one set in, are two
/// paragraphs; a note's mark set raised after a word is not said; 6: a
/// speech that fills its line still ends where the next one is set in, on
/// a page that sets first lines in and runs them on at the edge).
const pdfParserVersion = 6;

/// One outline (bookmark) entry: a title and the 0-based page it points at.
typedef PdfOutlineEntry = ({String title, int page});

/// A bookmark as the platform lists it: every level, in document order, with
/// its depth (0 at the top). The page is -1 when it points nowhere.
typedef PdfBookmark = ({String title, int page, int level});

/// The platform's bookmarks ("outline": maps of title, page and level) as the
/// chapter list [bookFromPdfText] takes. See [flattenPdfOutline].
List<PdfOutlineEntry> pdfOutlineFromPlatform(Object? raw) => flattenPdfOutline([
      if (raw is List)
        for (final o in raw)
          if (o is Map)
            (
              title: collapseWhitespace(o['title']?.toString() ?? ''),
              page: o['page'] is int ? o['page'] as int : -1,
              level: o['level'] is int ? o['level'] as int : 0,
            ),
    ]);

/// The runs the platform found set smaller and raised ("raised": one list of
/// numbers per page, three for each run: its line, start and length, see
/// PdfText.kt) as [bookFromPdfText] takes them; null when there are none, as
/// from an older extraction.
List<List<int>>? pdfRaisedFromPlatform(Object? raw) => pdfLayoutFromPlatform(raw);

/// The platform's line layout ("layout": one list of numbers per page, see
/// PdfText.kt) as [bookFromPdfText] takes it; null when there is none.
List<List<int>>? pdfLayoutFromPlatform(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final page in raw)
      page is List<int>
          ? page
          : [
              if (page is List)
                for (final v in page)
                  if (v is int) v,
            ],
  ];
}

/// Nested bookmarks as one list of chapters.
///
/// A lone bookmark at the top is the book's own title over everything, and
/// is unwrapped. A bookmark's children are listed after it when it groups
/// chapters (Part One, Book II, a volume) rather than being a chapter: a book
/// in Parts keeps its chapters, and a textbook's "Chapter 3" keeps its
/// sections to itself. When chapters in different groups share titles
/// ("Chapter 1" in every Part), each is named with its group's. A bookmark
/// named after a picture is no chapter (see [_bookmarkTitle]).
List<PdfOutlineEntry> flattenPdfOutline(List<PdfBookmark> bookmarks) {
  bookmarks = [
    for (final b in bookmarks)
      if (_bookmarkTitle(b.title) case final title?) (title: title, page: b.page, level: b.level),
  ];
  // A bookmark that points nowhere and holds nothing ("How to share this
  // eBook") is no chapter, and does not keep the book's own title from
  // being unwrapped.
  var list = [
    for (var i = 0; i < bookmarks.length; i++)
      if (bookmarks[i].page >= 0 || (i + 1 < bookmarks.length && bookmarks[i + 1].level > bookmarks[i].level))
        bookmarks[i],
  ];
  while (list.length > 1) {
    final top = list.map((b) => b.level).reduce(math.min);
    if (list.where((b) => b.level == top).length != 1) break;
    list = [
      for (final b in list)
        if (b.level != top) b,
    ];
  }

  final kept = <({PdfBookmark bookmark, String? group})>[];
  final path = <PdfBookmark>[];
  for (final b in list) {
    while (path.isNotEmpty && path.last.level >= b.level) {
      path.removeLast();
    }
    if (path.every((a) => !_chapterTitle.hasMatch(a.title))) {
      kept.add((bookmark: b, group: path.isEmpty ? null : path.last.title));
    }
    path.add(b);
  }

  // Named with their groups when one title comes up in two of them; a title
  // a publisher listed twice in one group is not told apart by it.
  final groupsOf = <String, Set<String>>{};
  for (final k in kept) {
    final group = k.group;
    if (group != null) (groupsOf[_words(k.bookmark.title)] ??= {}).add(group);
  }
  final repeated = groupsOf.values.any((groups) => groups.length > 1);
  return [
    for (final k in kept)
      if (k.bookmark.page >= 0 && k.bookmark.title.isNotEmpty)
        (
          title: repeated && (k.group ?? '').isNotEmpty
              ? '${k.group}: ${k.bookmark.title}'
              : k.bookmark.title,
          page: k.bookmark.page,
        ),
  ];
}

/// A bookmark's title as a chapter's, or null for a picture's file name.
///
/// A scan made by an image-to-PDF tool has a bookmark on every page named
/// after its picture ("DSC01139.tif", "IMG_2041.JPG", "scan0001"): each was
/// a chapter, its name shown over the page and read aloud. A PDF joined from
/// documents has a bookmark for each, named after its file ("Chapter
/// 1.pdf"): that is a chapter, named without the extension, unless the name
/// is only a camera's or a scanner's ("scan0001.pdf", "0001.pdf").
String? _bookmarkTitle(String title) {
  final t = title.trim();
  if (_pictureFile.hasMatch(t)) return null;
  final document = _documentFile.firstMatch(t);
  final name = document == null ? t : t.substring(0, document.start).trim();
  if (_cameraName.hasMatch(name) || (document != null && !_letters.hasMatch(name))) return null;
  return name;
}

/// A picture's file name.
final _pictureFile = RegExp(
  r'\.(tiff?|jpe?g|jpe|jfif|jp2|j2k|png|gif|bmp|webp|heic|heif|avif|psd|pcx|pnm|pbm|pgm|ppm|cr2|nef|dng)$',
  caseSensitive: false,
);

/// A document's file name.
final _documentFile = RegExp(r'\.(pdf|djvu?|docx?|odt|rtf|txt|xps|epub)$', caseSensitive: false);

/// What a camera, a phone or a scanner names a picture: "DSC01139",
/// "IMG_2041", "IMG-20240501-WA0003", "PXL_20240501_101530", "scan0001",
/// "P1010001". Three digits at least: "Image 3" may be a chapter.
final _cameraName = RegExp(
  r'^(dsc[nf]?|img|imag|image|_mg|pxl|cimg|imgp|sam|sdc|scan|scanned|photo|pict?|p)[\s_-]?\d{3,}[\w-]*$',
  caseSensitive: false,
);

/// A bookmark that names a chapter or a numbered section ("Chapter 3",
/// "3 The Trial", "1.2 Methods"): anything under it is its own sections.
final _chapterTitle = RegExp(
  r'^(chapter|chap\.?|ch\.|глава|kapitel|chapitre|capítulo|capitolo|hoofdstuk|'
  r'rozdział|অধ্যায়|পরিচ্ছেদ|अध्याय)(?!\p{L})|^\p{Nd}',
  caseSensitive: false,
  unicode: true,
);

/// Letters and digits only, lower case: titles compared as words.
String _words(String s) => collapseWhitespace(s.toLowerCase().replaceAll(_notWords, ' '));

final _notWords = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Whether a paragraph is [title] printed as a heading: the same words, the
/// title with more after it on the line, or the first line of a title set
/// over two ("Chapter 3" for "Chapter 3: The Trial").
bool _isTitle(String text, String title) {
  if (text.length > 100) return false;
  final p = _words(text), t = _words(title);
  if (p.isEmpty || t.isEmpty) return false;
  return p == t || p.startsWith('$t ') || (p.length >= 4 && t.startsWith('$p '));
}

/// Build a [Book] from per-page text that the platform extracted.
///
/// The platform does the glyph work; this does the reading-order clean-up
/// that makes a PDF listenable: running headers/footers and page numbers are
/// dropped, hyphenated line breaks are mended, a paragraph split across a
/// page break is joined, and the PDF outline becomes the chapter list.
///
/// [layout], one list per page from the platform, says where each line sits
/// (see [pdfLayoutFromPlatform]). With it, notes at a page's foot become
/// footnote blocks and two columns are read one after the other. Without it,
/// as from an older caller, the text is read as drawn. [raised] says which
/// runs of a line are set smaller and raised (see [pdfRaisedFromPlatform]):
/// a note's mark there is shown and not said.
Book bookFromPdfText({
  required String id,
  required List<String> pages,
  List<PdfOutlineEntry> outline = const [],
  List<List<int>>? layout,
  List<List<int>>? raised,
  String? title,
  String? author,
  String? filename,
}) {
  const scanned = UnsupportedDocumentException(
    'This PDF has no selectable text — it looks like scanned page images. '
    'TomeVoice can only read PDFs that contain real text.',
  );
  final textChars = pages.fold<int>(0, (n, p) => n + p.trim().length);
  if (pages.isEmpty || textChars == 0) throw scanned;

  final lines = [
    for (var p = 0; p < pages.length; p++)
      _readingOrder(_linesOf(
        pages[p],
        layout != null && p < layout.length ? layout[p] : null,
        raised != null && p < raised.length ? raised[p] : null,
      )),
  ];
  final body = _bodySize(lines);
  final furniture = _furniture(lines, body);
  final coverage = _coverage(lines, furniture, pages);
  // No page with words of its own, a scan whose few typed lines come to
  // less than a short paragraph, or too little text for its pages: nothing
  // worth listening to. A PDF each of whose pages has something to read
  // (see pdfPagesWithText) is never taken for a scan, however little that
  // is: OCR would find no page in it to read.
  if (coverage.pagesWithText == 0 ||
      (coverage.mostlyPictures && _letterCount(lines, furniture) < 400) ||
      (coverage.pagesWithText < coverage.pages && textChars < 40 * pages.length.clamp(1, 20))) {
    throw scanned;
  }
  resetBlockIds();
  final notes = <List<String>>[];
  for (var p = 0; p < lines.length; p++) {
    final foot = _footnotes([
      for (var i = 0; i < lines[p].length; i++)
        if (!furniture[p].contains(i)) lines[p][i],
    ], body);
    lines[p] = foot.text;
    notes.add(foot.notes);
  }

  final valid = [
    for (final o in outline)
      if (o.page >= 0 && o.page < pages.length && o.title.trim().isNotEmpty) o,
  ];
  // In page order; bookmarks sharing a page keep theirs.
  final order = [for (var i = 0; i < valid.length; i++) i]..sort((a, b) {
      final byPage = valid[a].page.compareTo(valid[b].page);
      return byPage != 0 ? byPage : a.compareTo(b);
    });
  final usable = [for (final i in order) valid[i]];
  final titlesOn = <int, List<String>>{};
  if (usable.length >= 2) {
    for (final o in usable) {
      (titlesOn[o.page] ??= []).add(o.title);
    }
  }

  // Reflow. The extractor's paragraph detection is unreliable: on a real
  // device many PDFs came out one line per paragraph, which made the voice
  // pause at every line break. A paragraph continues into the next one unless
  // it ends a sentence or is a heading. This also joins a paragraph that runs
  // over a page break; the joined text stays on the page where it started.
  // A paragraph keeps its lines and is joined once, when it ends: joined as
  // it grew, a long one was copied again for every page it ran over, and a
  // word broken by a soft hyphen at a page's foot lost the hyphen first.
  final paras = <_Para>[];
  _Open? open;
  // A page's footnotes follow the paragraph they hang from, which may run on
  // to the next page.
  var waiting = <_Para>[];
  void close() {
    if (open != null) paras.add(_Para(open!.page, joinWrappedLines(open!.marked)));
    open = null;
    paras.addAll(waiting);
    waiting = [];
  }

  // The front matter ends with a printed contents page, when there is one.
  var front = 0;
  for (var p = 0; p < lines.length; p++) {
    // A printed table of contents is read line by line, and none of its
    // lines is a heading: they name chapters that come later.
    final contents = _isContentsPage(lines[p]);
    if (contents && p < 20) front = p + 1;
    for (final group in _paragraphs(lines[p], lineByLine: contents)) {
      final text = joinWrappedLines([for (final l in group) l.text]);
      if (text.isEmpty) continue;
      // A bookmarked chapter's printed title starts a paragraph of its own.
      final opensChapter = titlesOn[p]?.any((t) => _isTitle(text, t)) ?? false;
      final current = open;
      if (!contents && !opensChapter && current != null && _continues(current, text)) {
        current.add(group);
        continue;
      }
      close();
      if (contents) {
        paras.add(_Para(p, joinWrappedLines([for (final l in group) l.marked]), role: BlockRole.paragraph));
      } else {
        open = _Open(p)..add(group);
      }
    }
    waiting.addAll([for (final n in notes[p]) _Para(p, n, role: BlockRole.footnote)]);
  }
  close();

  // The platform ends every page with a page break: the empty string after
  // the last one is not a page.
  final pageCount = pages.last.isEmpty ? pages.length - 1 : pages.length;
  final chapters = usable.length >= 2 && !_marksPages(usable, paras, pageCount) ? usable : const <PdfOutlineEntry>[];
  // A scan can be titled with its first picture's name, as its bookmarks
  // are; a PDF printed from a document, with the document's file name.
  final named = title == null ? null : _bookmarkTitle(collapseWhitespace(title));
  return assembleBook(
    id: id,
    metadata: BookMetadata(
      title: named != null && named.isNotEmpty ? named : (titleFromFilename(filename) ?? 'Untitled PDF'),
      authors: (author ?? '').trim().isEmpty ? const [] : [author!.trim()],
    ),
    sections: chapters.isNotEmpty
        ? _sectionsFromOutline(paras, chapters)
        : _sectionsFromHeadings(paras, front: front),
    source: SourceKind.pdf,
    filename: filename,
  );
}

/// Whether [outline] marks the pages rather than the chapters: a bookmark on
/// most of the [count] pages and hardly two on one, their titles not printed
/// on them ("Page 12", "Scan 3", a scanner's names for its pictures). A
/// chapter a page was a heading over every page, read aloud; the chapters
/// are found in the text instead. A poem or a slide a page has its title
/// printed over it, and keeps its bookmarks.
bool _marksPages(List<PdfOutlineEntry> outline, List<_Para> paras, int count) {
  if (count < 6) return false;
  final marked = {for (final o in outline) o.page};
  if (marked.length * 4 < count * 3 || outline.length * 4 > marked.length * 5) return false;
  final texts = <int, List<String>>{};
  for (final p in paras) {
    if (p.role == null) (texts[p.page] ??= []).add(p.text);
  }
  var printed = 0;
  for (final o in outline) {
    if (texts[o.page]?.any((t) => _isTitle(t, o.title)) ?? false) printed++;
  }
  return printed * 4 < outline.length;
}

/// How much of a PDF is text. A scan with a few typed pages (a publisher's
/// notice, an OCR'd title page) still imports, but its reader should hear why
/// the book is so short: when [mostlyPictures] is set, the app says "Most
/// pages of this PDF are pictures; only N pages have text."
typedef PdfTextCoverage = ({int pages, int pagesWithText, bool mostlyPictures});

/// How much of [pages], as the platform split its text, has something to
/// read. Running heads, page numbers and a scanner's stamp on every page
/// ("Digitized by Google") do not count.
PdfTextCoverage pdfTextCoverage(List<String> pages, {List<List<int>>? layout}) {
  final lines = _pageLines(pages, layout);
  return _coverage(lines, _furniture(lines, _bodySize(lines)), pages);
}

/// Which of [pages] have something to read, one answer a page, as
/// [pdfTextCoverage] counts them: the pages a scan's OCR can leave as they
/// are, and the ones it has to read. A PDF refused as a scan always has one
/// to read (see [bookFromPdfText]).
List<bool> pdfPagesWithText(List<String> pages, {List<List<int>>? layout}) {
  final lines = _pageLines(pages, layout);
  return _withText(lines, _furniture(lines, _bodySize(lines)), pages);
}

/// The lines of [pages] in reading order, as [bookFromPdfText] reads them.
List<List<_Line>> _pageLines(List<String> pages, List<List<int>>? layout) => [
      for (var p = 0; p < pages.length; p++)
        _readingOrder(_linesOf(pages[p], layout != null && p < layout.length ? layout[p] : null)),
    ];

PdfTextCoverage _coverage(List<List<_Line>> lines, List<Set<int>> furniture, List<String> pages) {
  final withText = _withText(lines, furniture, pages);
  final n = withText.where((t) => t).length;
  return (pages: withText.length, pagesWithText: n, mostlyPictures: n * 2 < withText.length);
}

List<bool> _withText(List<List<_Line>> lines, List<Set<int>> furniture, List<String> pages) {
  // The platform ends every page with a page break, so the empty string
  // after the last page is not a page.
  final count = pages.isNotEmpty && pages.last.isEmpty ? pages.length - 1 : pages.length;
  return [
    for (var p = 0; p < count; p++) _hasText(lines[p], furniture[p]),
  ];
}

bool _hasText(List<_Line> page, Set<int> furniture) {
  var letters = 0;
  for (var i = 0; i < page.length && letters < _pageOfText; i++) {
    if (furniture.contains(i)) continue;
    letters += _letters.allMatches(page[i].text).take(_pageOfText).length;
  }
  return letters >= _pageOfText;
}

/// Letters a page needs, besides its furniture, to have something to read: a
/// slide's one line does, the specks of OCR on a picture do not.
const _pageOfText = 20;

final _letters = RegExp(r'\p{L}', unicode: true);

/// Letters outside the furniture, in the whole book.
int _letterCount(List<List<_Line>> lines, List<Set<int>> furniture) {
  var n = 0;
  for (var p = 0; p < lines.length; p++) {
    for (var i = 0; i < lines[p].length; i++) {
      if (!furniture[p].contains(i)) n += _letters.allMatches(lines[p][i].text).length;
    }
  }
  return n;
}

/// Where a line sits on its page, in points: x, its baseline's y from the
/// top, its width and its font size.
typedef _Box = ({double x, double y, double w, double size});

/// One line of a page, which of the extractor's paragraphs it is in, and
/// where it sits when the platform said.
class _Line {
  const _Line(this.text, this.para, [this.box, String? marked]) : marked = marked ?? text;
  final String text;
  final int para;
  final _Box? box;

  /// [text] with the marks of notes in it set silent ("Michaelmas,¹"): what
  /// the paragraph is made of. Everything that looks at lines (running
  /// heads, page numbers, sentence ends) looks at [text].
  final String marked;
}

/// A paragraph of the reflowed text and the page it starts on.
class _Para {
  const _Para(this.page, this.text, {this.role});
  final int page;
  final String text;

  /// Set when the role is already known (a footnote, a line of a contents
  /// page); otherwise a chapter line is a heading.
  final BlockRole? role;
}

/// Numbers per line in the platform's layout (see PdfText.kt): x, baseline y
/// from the top, width, font size in tenths of a point, and the length of the
/// line's text.
const _perLine = 5;

/// The page's lines as the extractor wrote them; a paragraph starts at each
/// paragraph mark. [layout], when given, says where each line sits, and
/// [raised] which of their runs are set smaller and raised.
List<_Line> _linesOf(String page, List<int>? layout, [List<int>? raised]) {
  final raw = <({String text, int para})>[];
  final chunks = page.split(pdfParagraphMark);
  for (var c = 0; c < chunks.length; c++) {
    for (final l in chunks[c].split('\n')) {
      if (l.isNotEmpty) raw.add((text: l, para: c));
    }
  }
  // The layout lists the same lines in the same order, each with its
  // length. Where the two disagree, the page is read without it.
  final at = layout ?? const <int>[];
  var placed = at.length == raw.length * _perLine && raw.isNotEmpty;
  for (var i = 0; placed && i < raw.length; i++) {
    placed = at[i * _perLine + 4] == raw[i].text.length;
  }
  // The raised runs count lines as the layout does: of no use without it.
  final runs = <int, List<({int start, int end})>>{};
  if (placed && raised != null) {
    for (var k = 0; k + 2 < raised.length; k += 3) {
      (runs[raised[k]] ??= []).add((start: raised[k + 1], end: raised[k + 1] + raised[k + 2]));
    }
  }
  final out = <_Line>[];
  for (var i = 0; i < raw.length; i++) {
    final t = _readable(raw[i].text);
    if (t.isEmpty) continue;
    final k = i * _perLine;
    final marks = runs[i];
    out.add(_Line(
      t,
      raw[i].para,
      placed
          ? (
              x: at[k].toDouble(),
              y: at[k + 1].toDouble(),
              w: at[k + 2].toDouble(),
              size: at[k + 3] / 10,
            )
          : null,
      marks == null ? null : _readable(_withSilentMarks(raw[i].text, marks)),
    ));
  }
  return out;
}

/// [line] without what is never text. Fonts without a proper Unicode map
/// hand back control characters and private-use glyphs (a page number came
/// out as U+0018).
String _readable(String line) => line.replaceAll(_unreadable, '').trim();

/// [line] with the [runs] set raised in it that are notes' marks shown and
/// not said ("before Michaelmas,¹ and"): a number or a symbol right after a
/// word or a stop. One after a digit is a power ("10⁶"); one after a space,
/// or at the line's start, is not a mark on the word before.
String _withSilentMarks(String line, List<({int start, int end})> runs) {
  final out = StringBuffer();
  var at = 0;
  for (final r in [...runs]..sort((a, b) => a.start.compareTo(b.start))) {
    if (r.start <= 0 || r.start < at || r.end > line.length || r.end <= r.start) continue;
    final mark = line.substring(r.start, r.end);
    if (!_raisedMark.hasMatch(mark) || _spaceOrDigit.hasMatch(line[r.start - 1])) continue;
    out
      ..write(line.substring(at, r.start))
      ..write(silentMark(mark));
    at = r.end;
  }
  out.write(line.substring(at));
  return out.toString();
}

/// What a note's mark says: "1", "12", "*", "†".
final _raisedMark = RegExp(r'^(\p{Nd}{1,3}|[*†‡§¶]{1,3})$', unicode: true);
final _spaceOrDigit = RegExp(r'[\s\p{Nd}]', unicode: true);

/// The text's font size: the one most of the book's characters are set in.
/// 0 when nothing says.
double _bodySize(List<List<_Line>> pages) {
  final chars = <int, int>{};
  for (final page in pages) {
    for (final l in page) {
      final size = l.box?.size ?? 0;
      if (size <= 0) continue;
      final halves = (size * 2).round();
      chars[halves] = (chars[halves] ?? 0) + l.text.length;
    }
  }
  if (chars.isEmpty) return 0;
  return chars.entries.reduce((a, b) => b.value > a.value ? b : a).key / 2;
}

/// Line indexes top to bottom; lines level with each other as drawn.
List<int> _topToBottom(List<_Line> page) => [for (var i = 0; i < page.length; i++) i]
  ..sort((a, b) {
    final byY = page[a].box!.y.compareTo(page[b].box!.y);
    return byY != 0 ? byY : a.compareTo(b);
  });

/// Two columns, read left then right.
///
/// Lines come in the order the PDF drew them, which is reading order for most
/// books, but some PDFs draw across both columns, or the right one first. It
/// takes a clear gutter with plenty of text on each side, so an indented
/// quotation, a poem's line numbers or a note in the margin never reorders a
/// page. Lines across the gutter (a title, a running head, a wide picture's
/// caption) cut the page into bands, each read column by column.
List<_Line> _readingOrder(List<_Line> lines) {
  if (lines.length < 6 || lines.any((l) => l.box == null)) return lines;
  var left = double.infinity, right = double.negativeInfinity;
  for (final l in lines) {
    left = math.min(left, l.box!.x);
    right = math.max(right, l.box!.x + l.box!.w);
  }
  final width = right - left;
  if (width < 100) return lines;

  // The gutter: the middle of the stretch, in the middle of the page, that
  // the fewest lines cross.
  final start = left + width * 0.3;
  final steps = (width * 0.4 / 2).floor();
  var fewest = lines.length + 1, first = 0, last = 0;
  for (var s = 0; s <= steps; s++) {
    final x = start + s * 2;
    final n = lines.where((l) => l.box!.x < x - 1 && l.box!.x + l.box!.w > x + 1).length;
    if (n < fewest) {
      fewest = n;
      first = last = s;
    } else if (n == fewest && s == last + 1) {
      last = s;
    }
  }
  // Steps are 2 points apart; the gutter is the middle one of that stretch.
  final gutter = start + 2 * ((first + last) / 2);
  bool onLeft(_Line l) => l.box!.x + l.box!.w <= gutter + 1;
  bool onRight(_Line l) => !onLeft(l) && l.box!.x >= gutter - 1;

  final lefts = lines.where(onLeft).toList();
  final rights = lines.where(onRight).toList();
  if (lefts.length < 3 || rights.length < 3) return lines;
  int chars(Iterable<_Line> ls) => ls.fold(0, (n, l) => n + l.text.length);
  final all = chars(lines);
  if (chars(lefts) * 5 < all || chars(rights) * 5 < all) return lines;
  double span(List<_Line> ls, double Function(_Line) from, double Function(_Line) to) =>
      ls.map(to).reduce(math.max) - ls.map(from).reduce(math.min);
  if (span(lefts, (l) => l.box!.x, (l) => l.box!.x + l.box!.w) < width * 0.25 ||
      span(rights, (l) => l.box!.x, (l) => l.box!.x + l.box!.w) < width * 0.25) {
    return lines;
  }
  // Side by side, not one under the other.
  double top(List<_Line> ls) => ls.map((l) => l.box!.y).reduce(math.min);
  double bottom(List<_Line> ls) => ls.map((l) => l.box!.y).reduce(math.max);
  final shared = math.min(bottom(lefts), bottom(rights)) - math.max(top(lefts), top(rights));
  final shorter = math.min(bottom(lefts) - top(lefts), bottom(rights) - top(rights));
  if (shared < shorter * 0.5) return lines;

  final out = <_Line>[];
  final band = (left: <int>[], right: <int>[]);
  void flush() {
    for (final side in [band.left..sort(), band.right..sort()]) {
      out.addAll(side.map((i) => lines[i]));
      side.clear();
    }
  }

  for (final i in _topToBottom(lines)) {
    if (onLeft(lines[i])) {
      band.left.add(i);
    } else if (onRight(lines[i])) {
      band.right.add(i);
    } else {
      flush();
      out.add(lines[i]);
    }
  }
  flush();
  return out;
}

/// A footnote's mark: "1", "12.", "(3)", "[3]", "*", "†".
final _noteMark = RegExp(
  r'^(\d{1,3}|\(\d{1,3}\)|\[\d{1,3}\]|[*†‡§¶]{1,3})(?=[\s.)\]]|\p{L})',
  unicode: true,
);

/// Notes at the foot of a page: its lowest lines, set smaller than the text,
/// the first starting with its mark ("1 See the minutes…"). They leave the
/// flow, so a sentence that runs on to the next page is not broken by them
/// ("had come to an 1 See the minutes…"), and become footnote blocks. Small
/// print with no mark stays where it is. Without the layout nothing moves.
({List<_Line> text, List<String> notes}) _footnotes(List<_Line> page, double body) {
  final none = (text: page, notes: const <String>[]);
  if (body <= 0 || page.length < 2 || page.any((l) => l.box == null)) return none;
  bool small(_Line l) => l.box!.size > 0 && l.box!.size < body * 0.92;
  final down = _topToBottom(page);
  final foot = <int>[];
  for (final i in down.reversed) {
    if (!small(page[i])) break;
    foot.insert(0, i);
  }
  if (foot.isEmpty || foot.length == page.length || !_noteMark.hasMatch(page[foot.first].text)) {
    return none;
  }
  final notes = <String>[];
  var note = <String>[];
  for (final i in foot) {
    if (note.isNotEmpty && _noteMark.hasMatch(page[i].text)) {
      notes.add(joinWrappedLines(note));
      note = [];
    }
    note.add(page[i].text);
  }
  notes.add(joinWrappedLines(note));
  final moved = foot.toSet();
  return (
    text: [
      for (var i = 0; i < page.length; i++)
        if (!moved.contains(i)) page[i],
    ],
    notes: notes,
  );
}

/// The page's paragraphs as groups of lines: the lines of each of the
/// extractor's paragraphs, or one line each when [lineByLine].
List<List<_Line>> _paragraphs(List<_Line> lines, {required bool lineByLine}) {
  final out = <List<_Line>>[];
  for (var i = 0; i < lines.length; i++) {
    if (i == 0 ||
        lineByLine ||
        lines[i].para != lines[i - 1].para ||
        _indentedStart(lines, i) ||
        _sizeChanges(lines, i)) {
      out.add([]);
    }
    out.last.add(lines[i]);
  }
  return out;
}

/// Whether line [i] is set in another size than the line before it: a
/// title over its text, which the extractor ran into it when the space
/// under the title was small. Run together, the title was read as the start
/// of the first sentence, and a bookmark could not find it.
bool _sizeChanges(List<_Line> lines, int i) {
  final a = lines[i - 1].box?.size ?? 0, b = lines[i].box?.size ?? 0;
  if (a <= 0 || b <= 0) return false;
  return a >= b * 1.1 || b >= a * 1.1;
}

/// Whether line [i] starts a paragraph the extractor ran into the one
/// before: the line before ends a sentence, and this one is set in from the
/// column's edge, by more than the line before it was or after a line that
/// stopped short. Novels set dialogue so ("'Is he married or single?'" over
/// "'Oh! Single, my dear...'"), and Pride and Prejudice came out with a
/// whole conversation in one paragraph.
bool _indentedStart(List<_Line> lines, int i) {
  final line = lines[i].box, prev = lines[i - 1].box;
  if (line == null || prev == null || line.size <= 0) return false;
  if (!_endsSentence.hasMatch(lines[i - 1].text)) return false;
  final em = line.size;
  // The column's edge: the line furthest left within a few ems of this one.
  var margin = line.x;
  for (final l in lines) {
    final b = l.box;
    if (b != null && b.x < margin && line.x - b.x <= 6 * em) margin = b.x;
  }
  final indent = line.x - margin;
  if (indent < 0.8 * em || indent > 6 * em) return false;
  if (line.x - prev.x >= 0.8 * em) {
    // Set in further than the line before: lines at the edge carry the
    // extractor's paragraph on, and one set in starts the next. A
    // paragraph set in as a whole (a quotation, verse) has none at the
    // edge, and stays as it is.
    final para = lines[i].para;
    return lines.any((l) => l.para == para && l.box != null && (l.box!.x - margin).abs() < 0.5 * em);
  }
  // Set in as far as the line before, a paragraph of one line: it stops well
  // short of the full lines that start where it does, as a full line of a
  // justified paragraph does not ("'How so? how can it affect them?'" over
  // "'My dear Mr. Bennet,' replied his wife..."). Those are looked for on the
  // whole page: the extractor starts a paragraph at a line back at the edge
  // after one set in, so two speakers' lines set in one after the other
  // were a paragraph of their own, with no line at the edge.
  var full = prev.x + prev.w;
  for (final l in lines) {
    final b = l.box;
    if (b != null && (b.x - prev.x).abs() < 0.5 * em) full = math.max(full, b.x + b.w);
  }
  if (prev.x + prev.w < full - 2 * em) return true;
  // Or the page sets each paragraph's first line in and runs it on at the
  // edge: a line set in where this one is, not ending a sentence, has the
  // next line at the edge. Then a line set in after one that ends a sentence
  // starts a paragraph, however full the line before it ("'Yes—but as it
  // happens, they are all of them very clever.'" over "'This is the only
  // point, I flatter myself..."). A quotation set in as a whole runs on set
  // in, and stays as it is.
  for (var k = 0; k + 1 < lines.length; k++) {
    final a = lines[k].box, b = lines[k + 1].box;
    if (a == null || b == null || b.y <= a.y) continue;
    if ((a.x - line.x).abs() < 0.5 * em &&
        (b.x - margin).abs() < 0.5 * em &&
        !_endsSentence.hasMatch(lines[k].text)) {
      return true;
    }
  }
  return false;
}

/// A line that ends a sentence, closing quotes and brackets included, or a
/// clause that what is set in under it follows from ("addressed her with:"
/// over "'I hope Mr. Bingley will like it, Lizzy.'"), as a paragraph that
/// runs on to the next page is ended (see [_continues]).
final _endsSentence = RegExp('[.!?…।:;"”’\')\\]]\$');

/// The paragraph being reflowed: the page it starts on, and its lines so far,
/// as they read and with notes' marks set silent (see [_Line.marked]).
class _Open {
  _Open(this.page);
  final int page;
  final lines = <String>[];
  final marked = <String>[];
  var _length = -1;

  void add(List<_Line> group) {
    for (final l in group) {
      lines.add(l.text);
      marked.add(l.marked);
      _length += l.text.length + 1;
    }
  }

  /// The length of its text: exact while it is short enough to matter.
  int get length => _length < 120 ? joinWrappedLines(lines).length : _length;
}

/// How many pages either side of a page to look for its running head again.
const _near = 4;

/// The furniture on each page, as line indexes: running heads and feet, and
/// printed page numbers. None of it is read, and none of it may end up in
/// the middle of a sentence that runs over the page ("over to the THE NOBLE
/// BACHELOR 51"). [body] is the text's font size, 0 when unknown.
List<Set<int>> _furniture(List<List<_Line>> pages, double body) {
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
      // A head that names the chapter and carries the page's number
      // ("CHAPTER II. 5"), set smaller than the text: a chapter two or three
      // pages long has one, too few to be seen repeating, and it was taken
      // for the start of another chapter.
      final size = page[i].box?.size ?? 0;
      if (atEdge && body > 0 && size > 0 && size < body * 0.95 && _numbered(page[i].text) && looksLikeChapterLine(page[i].text)) {
        out[p].add(i);
        continue;
      }
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
      // And so is a line set larger than the text.
      if (body > 0 && (page[i].box?.size ?? 0) >= body * 1.2) continue;
      out[p].add(i);
    }
  }
  return out;
}

/// The lines at a page's top and bottom edges: the two highest and two
/// lowest when the layout says where lines sit, else the first and last two
/// as drawn; all of a short page's.
List<int> _edges(List<_Line> page) {
  final n = page.length;
  if (n <= 4) return [for (var i = 0; i < n; i++) i];
  if (page.any((l) => l.box == null)) return [0, 1, n - 2, n - 1];
  final down = _topToBottom(page);
  return [down[0], down[1], down[n - 2], down[n - 1]];
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
  var refs = 0, chapters = 0, last = 0;
  // A contents page's numbers go up; prose that happens to end its lines in
  // numbers ("stood at 12 / feet, then fell to 3") is no contents page.
  var rising = true;
  for (final l in page) {
    final ref = _pageRef.firstMatch(l.text);
    if (ref != null) {
      refs++;
      final value = _digitsValue(ref.group(2)!);
      if (value != null) {
        if (value < last) rising = false;
        last = value;
      }
    }
    if (looksLikeChapterLine(l.text)) chapters++;
  }
  final titled = page.take(3).any(
        (l) => _contentsHeading.hasMatch(
          collapseWhitespace(l.text.toLowerCase().replaceAll(_notLetters, ' ')),
        ),
      );
  return (titled && refs >= 2) ||
      (rising && refs >= 4 && refs * 2 >= page.length) ||
      (chapters >= 4 && chapters * 2 >= page.length);
}

/// Does [next] carry on the paragraph that [prev] started?
bool _continues(_Open prev, String next) {
  if (RegExp(r'[.!?।…"”’:;)\]]$').hasMatch(prev.lines.last)) return false;
  final length = prev.length;
  // A chapter line is never longer than 90 characters.
  if (looksLikeChapterLine(next) ||
      (length <= 90 && looksLikeChapterLine(joinWrappedLines(prev.lines)))) {
    return false;
  }
  if (_lowerFirst.hasMatch(next)) return true;
  // A short line before a capital is a title, or a line of verse.
  return length >= 40;
}

/// Lower case in any script that has it: "word" and "слово" both run on.
final _lowerFirst = RegExp(r'^\p{Ll}', unicode: true);

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

/// Chapters from the outline. A chapter starts at its title when the title is
/// printed on its page, so several chapters can share a page and one can
/// begin halfway down; otherwise at the top of its page. Pages before the
/// first entry are front matter and get their own section.
List<DraftSection> _sectionsFromOutline(List<_Para> paras, List<PdfOutlineEntry> outline) {
  final starts = <int>[];
  var from = 0;
  for (final o in outline) {
    var start = from;
    while (start < paras.length && paras[start].page < o.page) {
      start++;
    }
    for (var i = start; i < paras.length && paras[i].page == o.page; i++) {
      if (paras[i].role == null && _isTitle(paras[i].text, o.title)) {
        start = i;
        break;
      }
    }
    starts.add(start);
    from = start;
  }

  List<Block> blocks(int from, int to) => [for (final p in paras.sublist(from, to)) _block(p)];
  final out = <DraftSection>[];
  if (starts.first > 0) out.add((title: 'Opening pages', blocks: blocks(0, starts.first)));
  for (var i = 0; i < outline.length; i++) {
    final end = i + 1 < outline.length ? starts[i + 1] : paras.length;
    // Its place taken by the next bookmark on the same page.
    if (end <= starts[i]) continue;
    out.add((title: collapseWhitespace(outline[i].title), blocks: blocks(starts[i], end)));
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

/// [front] is the number of pages of front matter, up to and including a
/// printed contents page: they make their own section before the first ten
/// pages. Ten pages that begin with the contents read as front matter, and
/// were skipped when the book was opened, first chapter and all.
List<DraftSection> _sectionsFromHeadings(List<_Para> paras, {int front = 0}) {
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
  if (front > 0) {
    out.add((
      title: 'Opening pages',
      blocks: [
        for (final p in paras)
          if (p.page < front) _block(p),
      ],
    ));
  }
  final last = paras.map((p) => p.page).reduce((a, b) => a > b ? a : b);
  for (var from = front; from <= last; from += 10) {
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
