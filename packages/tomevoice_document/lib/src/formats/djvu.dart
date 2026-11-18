import 'dart:convert';
import 'dart:typed_data';

import '../model.dart';
import '../segment.dart';
import 'bzz.dart';
import 'pdf.dart';

/// DjVu (.djvu, .djv): a scanned book, read by its hidden text layer.
///
/// A DjVu's pages are pictures, but most (archive.org's scans, Wikisource's,
/// books made with OCR) carry the words found on each page under them, with
/// where each line, paragraph and column sits. That text is what is read;
/// the pictures themselves are never decoded. The pages are then read as a
/// PDF's are (see [bookFromPdfText]): running heads and page numbers left
/// out, words broken at line ends mended, paragraphs run over a page joined,
/// and the book's bookmarks (its outline) made its chapters.
///
/// The file is an IFF container ("AT&TFORM"): one page (FORM:DJVU), or a
/// book bundled in one file (FORM:DJVM, its pages as FORM:DJVU inside,
/// listed by a DIRM directory). A book kept as one file per page (an
/// "indirect" DjVu) is refused, as one file cannot hold it.
Book parseDjvu(Uint8List bytes, {required String id, String? filename}) {
  final doc = readDjvuText(bytes);
  if (!doc.pages.any((p) => _letterOrDigit.hasMatch(p))) throw _noText;
  final Book book;
  try {
    book = bookFromPdfText(
      id: id,
      pages: doc.pages,
      layout: doc.layout,
      outline: flattenPdfOutline(doc.bookmarks),
      title: doc.title,
      author: doc.author,
      filename: filename,
      source: SourceKind.djvu,
    );
  } on UnsupportedDocumentException {
    // Read as a PDF, too few of its pages have text to be worth listening
    // to: a scan whose OCR found a title page and little else.
    throw _noText;
  }
  return book;
}

/// What a DjVu says, as [readDjvuText] finds it: each page's text, in the
/// shape the PDF reader takes (paragraphs started by [pdfParagraphMark],
/// lines split by a newline), where those lines sit on each page (as
/// [bookFromPdfText] takes a PDF's layout; empty for a page whose text layer
/// does not say), its bookmarks, and its title and author when its metadata
/// names them.
typedef DjvuText = ({
  List<String> pages,
  List<List<int>> layout,
  List<PdfBookmark> bookmarks,
  String? title,
  String? author,
});

/// The text layer of a DjVu file, without making a book of it.
///
/// Throws [UnsupportedDocumentException] for a DjVu TomeVoice cannot read
/// (one file per page, or a lone picture), and [ParseException] for one that
/// is damaged or cut short.
DjvuText readDjvuText(Uint8List bytes) {
  if (!isDjvu(bytes)) throw const ParseException('This is not a DjVu file.');
  final top = _chunksIn(bytes, 4, bytes.length);
  if (top.isEmpty) throw _damaged;
  final form = top.first;
  final List<_Component> components;
  List<PdfBookmark> bookmarks = const [];
  switch (form.id) {
    case 'FORM:DJVU':
      components = [_Component('', null, null, _page, _chunksIn(bytes, form.start, form.end))];
    case 'FORM:DJVM':
      final inner = _chunksIn(bytes, form.start, form.end);
      components = _components(bytes, inner);
      for (final c in inner) {
        if (c.id != 'NAVM') continue;
        try {
          bookmarks = _bookmarks(bzzDecode(bytes, start: c.start, end: c.end), components);
        } on FormatException {
          // A damaged outline: the book is read without chapters from it.
        }
        break;
      }
    case 'FORM:DJVI':
      throw _indirect;
    case 'FORM:BM44' || 'FORM:PM44':
      // A photograph in DjVu's wavelet coding: no text layer to have.
      throw _noText;
    default:
      throw _damaged;
  }

  final pages = [
    for (final c in components)
      if (c.type == _page) c,
  ];
  if (pages.isEmpty) throw _noText;
  final byId = {for (final c in components) c.id: c};
  final meta = _metadata(bytes, components, pages.first, byId);
  final texts = [for (final p in pages) _pageText(bytes, p, byId)];
  return (
    pages: [for (final t in texts) t.text],
    layout: [for (final t in texts) t.layout],
    bookmarks: bookmarks,
    title: meta.title,
    author: meta.author,
  );
}

/// Whether [bytes] start as a DjVu file does: "AT&TFORM".
bool isDjvu(Uint8List bytes) {
  const magic = 'AT&TFORM';
  if (bytes.length < 16) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

const _noText = UnsupportedDocumentException(
  'This DjVu has no text to read aloud: its pages are pictures only. TomeVoice reads text, not images.',
);

const _indirect = UnsupportedDocumentException(
  'This DjVu is kept as one file per page (an "indirect" DjVu), and TomeVoice opens one file at a time. '
  'Bundle it into a single .djvu file (DjVuLibre\'s djvmcvt does this) and import that.',
);

const _damaged = ParseException('This DjVu file looks damaged and could not be read.');

const _cutShort = ParseException('This DjVu file is cut short: it may not have finished downloading.');

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// A chunk of an IFF file: its id ("FORM:DJVU" for a form, with its type)
/// and where its data lies (for a form, what follows its type).
class _Chunk {
  const _Chunk(this.id, this.start, this.end);
  final String id;
  final int start;
  final int end;
}

/// The chunks between [start] and [end]. Each starts on an even byte.
List<_Chunk> _chunksIn(Uint8List b, int start, int end) {
  final out = <_Chunk>[];
  var pos = start;
  while (pos + 8 <= end) {
    final id = String.fromCharCodes(b, pos, pos + 4);
    final size = _u32(b, pos + 4);
    final dataStart = pos + 8;
    final dataEnd = dataStart + size;
    if (dataEnd > end) throw end == b.length ? _cutShort : _damaged;
    if (id == 'FORM') {
      if (size < 4) throw _damaged;
      out.add(_Chunk('FORM:${String.fromCharCodes(b, dataStart, dataStart + 4)}', dataStart + 4, dataEnd));
    } else {
      out.add(_Chunk(id, dataStart, dataEnd));
    }
    pos = dataEnd + (dataEnd & 1);
  }
  return out;
}

int _u32(Uint8List b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// What a DIRM directory says a file of a bundled book is.
const _include = 0, _page = 1, _sharedAnno = 3;

/// A file of a bundled book: a page, or what pages include (shared
/// annotations, shape dictionaries, sometimes text).
class _Component {
  const _Component(this.id, this.name, this.title, this.type, this.chunks);
  final String id;
  final String? name;
  final String? title;
  final int type;
  final List<_Chunk> chunks;
}

/// The files of a bundled book, in its directory's order (the pages' order).
/// A directory that does not decode is passed over, and the forms inside
/// taken as they come.
List<_Component> _components(Uint8List b, List<_Chunk> inner) {
  final dirm = inner.where((c) => c.id == 'DIRM').firstOrNull;
  if (dirm != null) {
    if (dirm.end > dirm.start && b[dirm.start] & 0x80 == 0) throw _indirect;
    try {
      return _directory(b, dirm);
    } on FormatException {
      // Read the forms in the order they come instead.
    }
  }
  return [
    for (final c in inner)
      if (c.id == 'FORM:DJVU' || c.id == 'FORM:DJVI')
        _Component('', null, null, c.id == 'FORM:DJVU' ? _page : _include, _chunksIn(b, c.start, c.end)),
  ];
}

/// The DIRM directory of a bundled book: where each file starts, then
/// (compressed) their sizes, their kinds and their names.
List<_Component> _directory(Uint8List b, _Chunk dirm) {
  final r = _Reader(b, dirm.start, dirm.end);
  final version = r.u8() & 0x7F;
  final count = r.u16();
  final offsets = <int>[];
  for (var i = 0; i < count; i++) {
    offsets.add(r.u32());
    if (version == 0) r.u24();
  }
  final rest = _Reader(bzzDecode(b, start: r.pos, end: dirm.end));
  if (version > 0) {
    for (var i = 0; i < count; i++) {
      rest.u24();
    }
  }
  final flags = [for (var i = 0; i < count; i++) rest.u8()];
  final out = <_Component>[];
  for (var i = 0; i < count; i++) {
    var f = flags[i];
    if (version == 0) {
      // The first version's flags: is a page, has a name, has a title.
      f = (f & 1 != 0 ? _page : _include) | (f & 2 != 0 ? 0x80 : 0) | (f & 4 != 0 ? 0x40 : 0);
    }
    final id = rest.cString();
    final name = f & 0x80 != 0 ? rest.cString() : null;
    final title = f & 0x40 != 0 ? rest.cString() : null;
    final at = offsets[i];
    if (at + 12 > b.length) throw _cutShort;
    if (String.fromCharCodes(b, at, at + 4) != 'FORM') throw const FormatException('DIRM points at no form');
    final size = _u32(b, at + 4);
    final end = at + 8 + size;
    if (end > b.length) throw _cutShort;
    out.add(_Component(id, name, title, f & 0x3F, _chunksIn(b, at + 12, end)));
  }
  return out;
}

/// The book's bookmarks, from its NAVM chunk: how many there are, then each
/// in order (a parent before its children), with how many children it has,
/// its title and where it points.
List<PdfBookmark> _bookmarks(Uint8List navm, List<_Component> components) {
  final r = _Reader(navm);
  final pages = [
    for (final c in components)
      if (c.type == _page) c,
  ];
  final total = r.u16();
  final out = <PdfBookmark>[];
  // Children still to come at each open level.
  final open = <int>[];
  for (var k = 0; k < total && !r.atEnd; k++) {
    // Two bytes of children (low first: DjVuLibre's later layout, which
    // reads an older file's single byte and a short title the same), the
    // title's length, the title, the link's length, the link.
    final low = r.u8();
    final children = (r.u8() << 8) | low;
    final title = r.text(r.u16());
    final url = r.text(r.u24());
    out.add((title: collapseWhitespace(title), page: _pageOf(url, pages), level: open.length));
    if (open.isNotEmpty) open[open.length - 1]--;
    if (children > 0) open.add(children);
    while (open.isNotEmpty && open.last <= 0) {
      open.removeLast();
    }
  }
  return out;
}

/// The 0-based page a bookmark's link points at, or -1: "#p0012.djvu" by a
/// page's file, "#12" by its number.
int _pageOf(String url, List<_Component> pages) {
  final hash = url.indexOf('#');
  var name = hash < 0 ? url : url.substring(hash + 1);
  try {
    name = Uri.decodeComponent(name);
  } on ArgumentError {
    // Not percent-encoded after all.
  }
  if (name.isEmpty) return -1;
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    if (p.id == name || p.name == name || p.title == name) return i;
  }
  final n = int.tryParse(name);
  return n != null && n >= 1 && n <= pages.length ? n - 1 : -1;
}

/// A page's text in the shape the PDF reader takes, and where its lines sit
/// in the numbers the platform gives for a PDF's (see pdfLayoutFromPlatform):
/// empty when the page does not say.
typedef _PageText = ({String text, List<int> layout});

const _PageText _blankPage = (text: '', layout: []);

/// A page's text, from its own text chunk or one in a file it includes.
_PageText _pageText(Uint8List b, _Component page, Map<String, _Component> byId) {
  final included = [
    for (final c in page.chunks)
      if (c.id == 'INCL') byId[utf8.decode(b.sublist(c.start, c.end), allowMalformed: true).trim()],
  ];
  for (final source in [page, ...included.whereType<_Component>()]) {
    for (final c in source.chunks) {
      if (c.id != 'TXTa' && c.id != 'TXTz') continue;
      try {
        final data = c.id == 'TXTz' ? bzzDecode(b, start: c.start, end: c.end) : Uint8List.sublistView(b, c.start, c.end);
        return _textLayer(data, _pageInfo(b, page));
      } on FormatException {
        // A damaged text layer: the page is read as having none.
        return _blankPage;
      }
    }
  }
  return _blankPage;
}

/// The page's height in pixels and its resolution, from its INFO chunk.
({int height, int dpi})? _pageInfo(Uint8List b, _Component page) {
  for (final c in page.chunks) {
    if (c.id != 'INFO' || c.end - c.start < 4) continue;
    final height = (b[c.start + 2] << 8) | b[c.start + 3];
    var dpi = c.end - c.start >= 8 && b[c.start + 7] != 0xFF ? (b[c.start + 7] << 8) | b[c.start + 6] : 300;
    if (dpi < 25 || dpi > 6000) dpi = 300;
    return (height: height, dpi: dpi);
  }
  return null;
}

/// A text layer (TXTa, or TXTz unpacked): the page's text in UTF-8, then
/// its zones, nested page, column, region, paragraph, line, word and
/// character, each saying which stretch of the text it holds and where on
/// the page it sits. The zones say where paragraphs and lines end; without
/// them, the separators in the text do.
_PageText _textLayer(Uint8List data, ({int height, int dpi})? info) {
  final r = _Reader(data);
  final text = r.bytes(r.u24());
  _Zone? root;
  if (!r.atEnd && r.u8() == 1) {
    try {
      root = _zone(r, text.length, null, null, 0);
    } on FormatException {
      // Zones that do not add up: the separators will do.
    }
  }
  final placed = root == null ? const <List<_PlacedLine>>[] : _zoneParagraphs(text, root);
  if (placed.isEmpty) {
    final paras = _separatedParagraphs(utf8.decode(text, allowMalformed: true));
    return (
      text: [
        for (final p in paras)
          if (p.isNotEmpty) p.join('\n'),
      ].join(pdfParagraphMark),
      layout: const [],
    );
  }
  final top = info?.height ?? root!.ymax;
  return (
    text: [for (final p in placed) p.map((l) => l.text).join('\n')].join(pdfParagraphMark),
    layout: _layout(placed, top, info?.dpi ?? 300),
  );
}

/// A zone of a page's text: its kind (1 page ... 7 character), the stretch
/// of the text's bytes it holds, where it sits (in pixels, from the page's
/// bottom left corner), and the zones inside it.
class _Zone {
  _Zone(this.type, this.start, this.length, this.xmin, this.ymin, this.xmax, this.ymax);
  final int type;
  final int start;
  final int length;
  final int xmin, ymin, xmax, ymax;
  final children = <_Zone>[];
}

const _paragraph = 4, _line = 5;

/// One zone and those inside it. Each zone's place and start count from the
/// zone before it, or from its parent for a first child.
_Zone _zone(_Reader r, int textLength, _Zone? parent, _Zone? prev, int depth) {
  final type = r.u8();
  if (type < 1 || type > 7 || depth > 8) throw const FormatException('Bad zone');
  var x = r.u16() - 0x8000;
  var y = r.u16() - 0x8000;
  final width = r.u16() - 0x8000;
  final height = r.u16() - 0x8000;
  var start = r.u16() - 0x8000;
  final length = r.u24();
  if (prev != null) {
    if (type == 1 || type == _paragraph || type == _line) {
      x += prev.xmin;
      y = prev.ymin - (y + height);
    } else {
      x += prev.xmax;
      y += prev.ymin;
    }
    start += prev.start + prev.length;
  } else if (parent != null) {
    x += parent.xmin;
    y = parent.ymax - (y + height);
    start += parent.start;
  }
  final count = r.u24();
  if (start < 0 || start + length > textLength || count * 17 > r.remaining) {
    throw const FormatException('Bad zone');
  }
  final zone = _Zone(type, start, length, x, y, x + width, y + height);
  _Zone? last;
  for (var i = 0; i < count; i++) {
    last = _zone(r, textLength, zone, last, depth + 1);
    zone.children.add(last);
  }
  return zone;
}

/// A line of a page and the zone it is (a line, or a word set straight in a
/// paragraph).
typedef _PlacedLine = ({String text, _Zone zone});

/// The page's paragraphs as lists of lines, by its zones: a line is a line
/// zone (or a word set straight in a paragraph), and a paragraph the lines
/// in one paragraph zone. Lines set straight in a region, a column or the
/// page, as some OCR leaves them, are told into paragraphs by where they
/// sit (see [_byGaps]). Empty when a zone has text but no lines: the
/// separators are read instead.
List<List<_PlacedLine>> _zoneParagraphs(Uint8List text, _Zone root) {
  final groups = <({_Zone holder, List<_PlacedLine> lines})>[];
  var lineless = false;
  void walk(_Zone z, _Zone holder) {
    if (z.type >= _line) {
      final line = _clean(utf8.decode(text.sublist(z.start, z.start + z.length), allowMalformed: true));
      if (line.isEmpty) return;
      if (groups.isEmpty || !identical(groups.last.holder, holder)) groups.add((holder: holder, lines: []));
      final lines = groups.last.lines;
      if (lines.isNotEmpty && _sameLine(lines.last.zone, z)) {
        lines.last = _joined(lines.last, (text: line, zone: z));
      } else {
        lines.add((text: line, zone: z));
      }
      return;
    }
    if (z.children.isEmpty) {
      if (_letterOrDigit.hasMatch(utf8.decode(text.sublist(z.start, z.start + z.length), allowMalformed: true))) {
        lineless = true;
      }
      return;
    }
    for (final c in z.children) {
      walk(c, z);
    }
  }

  walk(root, root);
  if (lineless) return const [];
  final paras = [
    for (final g in groups)
      if (g.holder.type == _paragraph) g.lines else ..._byGaps(g.lines),
  ];
  // A title set over its text with no more space than between lines ("I
  // Scope" over "This document defines..."), told apart by being short over
  // a full line. Run into the text, it was read as the start of its first
  // sentence, and its bookmark could not find it.
  final widths = [
    for (final p in paras)
      for (final l in p)
        if (l.text.length >= 25) l.zone.xmax - l.zone.xmin,
  ]..sort();
  if (widths.isEmpty) return paras;
  final full = widths[widths.length ~/ 2];
  int width(_PlacedLine l) => l.zone.xmax - l.zone.xmin;
  return [
    for (final p in paras)
      if (p.length >= 2 && width(p[0]) * 10 < full * 6 && width(p[1]) * 10 >= full * 8) ...[
        [p[0]],
        p.sublist(1),
      ] else
        p,
  ];
}

/// Whether [b] goes on the line [a] is on: level with it (sharing most of
/// its height) and after it. A text layer made from a typeset file rather
/// than by OCR can cut a line into pieces where the type was kerned or
/// spaced out ("D", "J", "V", "U" for a heading set "D J V U"), each a line
/// zone of its own.
bool _sameLine(_Zone a, _Zone b) {
  final overlap = (a.ymax < b.ymax ? a.ymax : b.ymax) - (a.ymin > b.ymin ? a.ymin : b.ymin);
  final shorter = (a.ymax - a.ymin) < (b.ymax - b.ymin) ? a.ymax - a.ymin : b.ymax - b.ymin;
  return shorter > 0 && overlap * 2 >= shorter && b.xmin >= a.xmax - shorter ~/ 2;
}

/// Two pieces of a line as one: with a space between them where the gap
/// between them is a space's width, and none where they touch.
_PlacedLine _joined(_PlacedLine a, _PlacedLine b) {
  final x = a.zone, y = b.zone;
  final height = (x.ymax - x.ymin) > (y.ymax - y.ymin) ? x.ymax - x.ymin : y.ymax - y.ymin;
  final gap = y.xmin - x.xmax;
  final space = gap * 5 > height;
  return (
    text: space ? '${a.text} ${b.text}' : '${a.text}${b.text}',
    zone: _Zone(
      _line,
      x.start,
      y.start + y.length - x.start,
      x.xmin < y.xmin ? x.xmin : y.xmin,
      x.ymin < y.ymin ? x.ymin : y.ymin,
      x.xmax > y.xmax ? x.xmax : y.xmax,
      x.ymax > y.ymax ? x.ymax : y.ymax,
    ),
  );
}

/// Lines with no paragraph zones over them, told into paragraphs as a
/// reader sees them: a paragraph starts after a gap well over the usual
/// distance from line to line, and where the lines go back up the page (the
/// top of the next column).
List<List<_PlacedLine>> _byGaps(List<_PlacedLine> lines) {
  final steps = [
    for (var i = 1; i < lines.length; i++)
      if (lines[i - 1].zone.ymin - lines[i].zone.ymin case final d when d > 0) d,
  ]..sort();
  final usual = steps.isEmpty ? 0 : steps[steps.length ~/ 2];
  final out = <List<_PlacedLine>>[];
  for (var i = 0; i < lines.length; i++) {
    final step = i == 0 ? 0 : lines[i - 1].zone.ymin - lines[i].zone.ymin;
    if (i == 0 || step <= 0 || (usual > 0 && step * 10 > usual * 16)) out.add([]);
    out.last.add(lines[i]);
  }
  return out;
}

/// Where each line sits, as the platform gives a PDF's lines (see
/// PdfText.kt): x, its foot's distance from the top of the page, width and
/// font size in tenths of a point, in points, and the length of its text.
/// [top] is the page's height in pixels.
///
/// OCR gives a line's box, not its type's size, and a box is as tall as the
/// letters in it: a line with no capitals or descenders is short. So every
/// line counts as the size of the page's usual line, unless it is plainly
/// taller (a heading) or, being long, plainly shorter (a note set small);
/// a short line takes the size of the line before it in its paragraph.
List<int> _layout(List<List<_PlacedLine>> paras, int top, int dpi) {
  int height(_PlacedLine l) => l.zone.ymax - l.zone.ymin;
  final all = [for (final p in paras) ...p];
  final long = [
    for (final l in all)
      if (l.text.length >= 25) height(l),
  ];
  final heights = (long.isNotEmpty ? long : [for (final l in all) height(l)])..sort();
  final usual = heights[heights.length ~/ 2];
  final points = 72 / dpi;
  final out = <int>[];
  for (final p in paras) {
    var size = usual;
    for (var i = 0; i < p.length; i++) {
      final l = p[i];
      final h = height(l);
      if (l.text.length >= 25 || i == 0) {
        size = h * 10 > usual * 14 || (l.text.length >= 25 && h * 100 < usual * 85) ? h : usual;
      }
      out
        ..add((l.zone.xmin * points).round())
        ..add(((top - l.zone.ymin) * points).round())
        ..add(((l.zone.xmax - l.zone.xmin) * points).round())
        // A line's box runs from its tallest letter to its lowest descender,
        // about 1.2 times its type's size.
        ..add((size * points * 10 / 1.2).round())
        ..add(l.text.length);
    }
  }
  return out;
}

/// Paragraphs and lines by the separators DjVu puts in a page's text: a
/// vertical tab after a column, GS after a region, US after a paragraph, a
/// newline after a line. A blank line ends a paragraph too, as in text
/// layers set without them.
List<List<String>> _separatedParagraphs(String text) => [
      for (final p in text.split(_paragraphEnd))
        [
          for (final l in p.split('\n'))
            if (_clean(l) case final line when line.isNotEmpty) line,
        ],
    ];

final _paragraphEnd = RegExp('[\\x0B\\x1D\\x1F]|\\n[ \\t]*\\n');

/// A line's text with no control characters (the separators) or marks the
/// PDF reader splits on, and single spaces.
String _clean(String s) => collapseWhitespace(s.replaceAll(_controls, ' '));

final _controls = RegExp('[\\x00-\\x1F\\x7F\\u2028\\u2029]');

/// The book's title and author from its metadata: a "(metadata (title
/// "...") (author "..."))" in its annotations (ANTa, ANTz), shared or on the
/// first page, or a METa/METz chunk.
({String? title, String? author}) _metadata(
  Uint8List b,
  List<_Component> components,
  _Component first,
  Map<String, _Component> byId,
) {
  String? title, author;
  final sources = <_Component>[
    for (final c in components)
      if (c.type == _sharedAnno) c,
    first,
    for (final c in first.chunks)
      if (c.id == 'INCL')
        if (byId[utf8.decode(b.sublist(c.start, c.end), allowMalformed: true).trim()] case final inc?) inc,
  ];
  for (final source in sources) {
    for (final c in source.chunks) {
      if (!const {'ANTa', 'ANTz', 'METa', 'METz'}.contains(c.id)) continue;
      String text;
      try {
        final data = c.id.endsWith('z') ? bzzDecode(b, start: c.start, end: c.end) : b.sublist(c.start, c.end);
        text = utf8.decode(data, allowMalformed: true);
      } on FormatException {
        continue;
      }
      title ??= _metaValue(text, 'title');
      author ??= _metaValue(text, 'author');
    }
    if (title != null && author != null) break;
  }
  return (title: title, author: author);
}

/// The value given for [key]: "(key "value")" as annotations write it, or
/// "key<tab>value" on a line of its own.
String? _metaValue(String text, String key) {
  final listed = RegExp('\\(\\s*$key\\s+"((?:[^"\\\\]|\\\\.)*)"\\s*\\)', caseSensitive: false).firstMatch(text);
  final raw = listed != null
      ? _unescape(listed.group(1)!)
      : RegExp('^\\s*$key\\s*[\\t:=]\\s*(.+)\$', caseSensitive: false, multiLine: true).firstMatch(text)?.group(1);
  if (raw == null) return null;
  final value = collapseWhitespace(raw);
  return value.isEmpty ? null : value;
}

/// A string as annotations quote it, C's way: backslash escapes, and octal
/// for bytes.
String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\([0-7]{1,3}|.)'), (m) {
      final e = m.group(1)!;
      if (RegExp(r'^[0-7]+$').hasMatch(e)) return String.fromCharCode(int.parse(e, radix: 8));
      return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => e,
      };
    });

/// Big-endian numbers and strings from a stretch of bytes; reading past its
/// end is a [FormatException], as damaged data is.
class _Reader {
  _Reader(this._b, [this.pos = 0, int? end]) : _end = end ?? _b.length;
  final Uint8List _b;
  int pos;
  final int _end;

  bool get atEnd => pos >= _end;
  int get remaining => _end - pos;

  void _need(int n) {
    if (pos + n > _end) throw const FormatException('Data ends too soon');
  }

  int u8() {
    _need(1);
    return _b[pos++];
  }

  int u16() {
    _need(2);
    final v = (_b[pos] << 8) | _b[pos + 1];
    pos += 2;
    return v;
  }

  int u24() {
    _need(3);
    final v = (_b[pos] << 16) | (_b[pos + 1] << 8) | _b[pos + 2];
    pos += 3;
    return v;
  }

  int u32() {
    _need(4);
    final v = _u32(_b, pos);
    pos += 4;
    return v;
  }

  void skip(int n) {
    _need(n);
    pos += n;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(_b, pos, pos + n);
    pos += n;
    return v;
  }

  String text(int n) => utf8.decode(bytes(n), allowMalformed: true);

  /// A string ended by a zero byte (or the end).
  String cString() {
    final start = pos;
    while (pos < _end && _b[pos] != 0) {
      pos++;
    }
    final s = utf8.decode(Uint8List.sublistView(_b, start, pos), allowMalformed: true);
    if (pos < _end) pos++;
    return s;
  }
}
