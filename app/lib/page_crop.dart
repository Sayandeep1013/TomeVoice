import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

// A PDF's real pages with their white margins cut away, so on a phone the
// print fills the width (Crop margins, in the reader's settings).
//
// Each page's print is found on a small drawing of it, on the phone
// (PdfPages.findPrint in Kotlin; findPrint here is the same, step for step,
// so the tests cover it). A book is cut by one CropPlan, made from a few of
// its pages, so its pages keep one scale as they turn.

/// The edge of a page the paper is found on, of its shorter side.
const _band = 0.04;

/// How deep in from an edge a shadow along it may reach, of the shorter side.
const _shadow = 0.06;

/// More colourful than the paper by this much: a mark, not a shadow.
const _tint = 40;

/// Where the print lies on a page drawn [width] by [height] ([argb]: its
/// pixels, a row at a time): the box around everything on it that is not
/// paper, in pixels, or null on a blank page.
///
/// The paper is the colour most of the page's edge has, and ink is what
/// differs from it by more than the paper's own grain. A speck (a mark no
/// bigger than a cell either way) is not print. Nor is a shadow: a thin band
/// in the paper's own colours, only darker, lying along an edge for a
/// quarter of it or more (a scanner's shadow, the dark past a scanned
/// page's edge); a line of print that only grazes an edge is still print.
/// A page whose edge is mostly not paper (a picture to its edges) is print
/// all over.
///
/// The same, step for step, as PdfPages.findPrint in Kotlin; change both.
Rect? findPrint(Uint32List argb, int width, int height) {
  final w = width, h = height;
  final whole = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  if (w < 8 || h < 8 || argb.length < w * h) return whole;

  // The paper: each channel's middle value around the page's edge.
  final band = math.max(1, (math.min(w, h) * _band).round());
  final reds = Int32List(256), greens = Int32List(256), blues = Int32List(256);
  var edge = 0;
  void paperAt(int c) {
    reds[(c >> 16) & 0xff]++;
    greens[(c >> 8) & 0xff]++;
    blues[c & 0xff]++;
    edge++;
  }

  _alongEdge(argb, w, h, band, paperAt);
  final pr = _middle(reds, edge), pg = _middle(greens, edge), pb = _middle(blues, edge);
  int off(int c) => math.max(
        (((c >> 16) & 0xff) - pr).abs(),
        math.max((((c >> 8) & 0xff) - pg).abs(), ((c & 0xff) - pb).abs()),
      );

  // Its grain: how far the edge strays from it, at the middle. Ink is what
  // strays further than a little more than that.
  final strays = Int32List(256);
  _alongEdge(argb, w, h, band, (c) => strays[off(c)]++);
  final ink = (24 + 2 * _middle(strays, edge)).clamp(24, 48);
  var paper = 0;
  for (var v = 0; v < ink; v++) {
    paper += strays[v];
  }
  if (paper * 2 < edge) return whole;

  // Ink counted in cells two pixels square, as the page is drawn to be
  // looked at; a mark is the cells it inks, with two pixels of ink at least
  // (one is grain). A small page number spans two cells or more.
  final cell = math.max(1, (math.min(w, h) / 250).round());
  final gw = (w + cell - 1) ~/ cell, gh = (h + cell - 1) ~/ cell;
  final inks = Int32List(gw * gh);
  final tinted = Uint8List(gw * gh);
  final paperTint = math.max(pr, math.max(pg, pb)) - math.min(pr, math.min(pg, pb));
  for (var y = 0; y < h; y++) {
    final row = y * w, cells = (y ~/ cell) * gw;
    for (var x = 0; x < w; x++) {
      final c = argb[row + x];
      if (off(c) < ink) continue;
      final i = cells + x ~/ cell;
      inks[i]++;
      final r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
      if (math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) - paperTint > _tint) tinted[i] = 1;
    }
  }
  final least = cell > 1 ? 2 : 1;

  // Each mark in turn (cells touching, corners too), and the box around
  // those that are print.
  final seen = Uint8List(gw * gh);
  final stack = Int32List(gw * gh);
  final deep = math.max(1, (math.min(gw, gh) * _shadow).ceil());
  var left = gw, top = gh, right = -1, bottom = -1;
  for (var start = 0; start < gw * gh; start++) {
    if (inks[start] < least || seen[start] != 0) continue;
    seen[start] = 1;
    stack[0] = start;
    var sp = 1;
    var x0 = gw, y0 = gh, x1 = -1, y1 = -1, far = 0, onEdge = 0;
    var coloured = false;
    while (sp > 0) {
      final i = stack[--sp];
      final x = i % gw, y = i ~/ gw;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      final depth = math.min(math.min(x, y), math.min(gw - 1 - x, gh - 1 - y));
      if (depth == 0) onEdge++;
      if (depth > far) far = depth;
      if (tinted[i] != 0) coloured = true;
      for (var ny = math.max(0, y - 1); ny <= math.min(gh - 1, y + 1); ny++) {
        for (var nx = math.max(0, x - 1); nx <= math.min(gw - 1, x + 1); nx++) {
          final n = ny * gw + nx;
          if (inks[n] >= least && seen[n] == 0) {
            seen[n] = 1;
            stack[sp++] = n;
          }
        }
      }
    }
    final spanX = x1 - x0 + 1, spanY = y1 - y0 + 1;
    if (spanX == 1 && spanY == 1) continue;
    final long = spanX * 4 >= gw || spanY * 4 >= gh;
    final hugs = onEdge * 2 >= math.max(spanX, spanY);
    if (long && hugs && far <= deep && !coloured) continue;
    if (x0 < left) left = x0;
    if (y0 < top) top = y0;
    if (x1 > right) right = x1;
    if (y1 > bottom) bottom = y1;
  }
  if (right < 0) return null;
  return Rect.fromLTRB(
    (left * cell).toDouble(),
    (top * cell).toDouble(),
    math.min(w, (right + 1) * cell).toDouble(),
    math.min(h, (bottom + 1) * cell).toDouble(),
  );
}

/// Each pixel of the page's edge, [band] deep, to [pixel].
void _alongEdge(Uint32List argb, int w, int h, int band, void Function(int c) pixel) {
  for (var y = 0; y < h; y++) {
    final row = y * w;
    if (y < band || y >= h - band) {
      for (var x = 0; x < w; x++) {
        pixel(argb[row + x]);
      }
    } else {
      for (var x = 0; x < band; x++) {
        pixel(argb[row + x]);
        pixel(argb[row + w - 1 - x]);
      }
    }
  }
}

/// The middle value of [n] counted in [counts] (by value).
int _middle(Int32List counts, int n) {
  var seen = 0;
  for (var v = 0; v < counts.length; v++) {
    seen += counts[v];
    if (seen * 2 >= n) return v;
  }
  return counts.length - 1;
}

/// The pages a book's crop is found from: every page of a short book, else
/// six pairs (an even page and the odd one after it) spread through it.
List<int> cropSample(int pages) {
  if (pages <= 12) return [for (var i = 0; i < pages; i++) i];
  final evens = [for (var j = 0; j < 6; j++) ((j + 0.5) * pages / 6).floor() & ~1];
  return [for (final p in evens) ...[p, p + 1]];
}

/// How a book's pages are cut: one box for its even pages and one for its
/// odd (in fractions of the page), the same size. Each cut page then shows
/// at one scale, with its print in one place even where facing pages mirror
/// their margins.
class CropPlan {
  const CropPlan({required this.even, required this.odd, required this.aspect});

  final Rect even;
  final Rect odd;

  /// The shape of the pages it cuts, width over height. A page of another
  /// shape (a fold-out) is shown whole.
  final double aspect;

  /// The shape of a cut page.
  double get shownAspect => aspect * even.width / even.height;

  /// Whether a page of [pageAspect] is one this cuts.
  bool fits(double pageAspect) => (pageAspect - aspect).abs() <= aspect * 0.02;

  /// The plan for a book from where the print lies on a few of its [pages]
  /// ([prints], null for a blank page; each page's shape in [aspects]). Null
  /// when there is little to cut, or most of them are pictures to the edges.
  ///
  /// Each side's box holds all its pages' print but the farthest out on
  /// each side, past four pages: a wide table on one page does not shrink
  /// every page; that page moves its box, or shows whole.
  static CropPlan? from(List<int> pages, List<Rect?> prints, List<double> aspects) {
    if (pages.isEmpty || pages.length != prints.length) return null;
    final shapes = [for (final p in pages) aspects[p]]..sort();
    final aspect = shapes[shapes.length ~/ 2];
    final sides = [<Rect>[], <Rect>[]];
    var marked = 0, bleeds = 0;
    for (var i = 0; i < pages.length; i++) {
      final print = prints[i];
      if (print == null || (aspects[pages[i]] - aspect).abs() > aspect * 0.02) continue;
      marked++;
      final box = _padded(print, aspect);
      if (box.width >= 0.97 && box.height >= 0.97) {
        bleeds++;
      } else {
        sides[pages[i] % 2].add(box);
      }
    }
    if (marked == 0 || bleeds * 2 > marked) return null;
    final even = _around(sides[0].isEmpty ? sides[1] : sides[0]);
    final odd = _around(sides[1].isEmpty ? sides[0] : sides[1]);
    final w = math.max(even.width, odd.width), h = math.max(even.height, odd.height);
    // Little to gain; or a sliver, or a strip of a page (never drawn more
    // than four times as tall as wide: see PdfPages.render).
    final shape = aspect * w / h;
    if ((w >= 0.95 && h >= 0.95) || w < 0.25 || h < 0.25 || shape < 0.3 || shape > 3.3) return null;
    return CropPlan(even: _sized(even, w, h), odd: _sized(odd, w, h), aspect: aspect);
  }

  /// The part of [page] to show, given where its print lies ([print], null
  /// on a blank page): its side's box, moved as little as it takes to hold
  /// all of the print with room around it. Null shows the page whole: its
  /// print wider or taller than the box (a picture to the edges), or a page
  /// of another shape.
  Rect? cropFor(int page, Rect? print, double pageAspect) {
    if (!fits(pageAspect)) return null;
    final box = page.isEven ? even : odd;
    if (print == null) return box;
    final p = _padded(print, aspect);
    const slack = 0.002;
    if (p.width > box.width + slack || p.height > box.height + slack) return null;
    double by(double lo, double hi, double boxLo, double boxHi) =>
        lo < boxLo ? lo - boxLo : (hi > boxHi ? hi - boxHi : 0.0);
    return box.shift(Offset(by(p.left, p.right, box.left, box.right), by(p.top, p.bottom, box.top, box.bottom)));
  }

  @override
  bool operator ==(Object other) =>
      other is CropPlan && other.even == even && other.odd == odd && other.aspect == aspect;

  @override
  int get hashCode => Object.hash(even, odd, aspect);
}

/// [box] (of a page of [aspect]) with room around it: a fiftieth of the
/// page's width each way, within the page.
Rect _padded(Rect box, double aspect) {
  const x = 0.02;
  final y = x * aspect;
  return Rect.fromLTRB(
    math.max(0.0, box.left - x),
    math.max(0.0, box.top - y),
    math.min(1.0, box.right + x),
    math.min(1.0, box.bottom + y),
  );
}

/// The box around [boxes], but for the one farthest out on each side for
/// every four past the first.
Rect _around(List<Rect> boxes) {
  final drop = (boxes.length - 1) ~/ 4;
  List<double> sorted(double Function(Rect b) side) => [for (final b in boxes) side(b)]..sort();
  final last = boxes.length - 1 - drop;
  return Rect.fromLTRB(
    sorted((b) => b.left)[drop],
    sorted((b) => b.top)[drop],
    sorted((b) => b.right)[last],
    sorted((b) => b.bottom)[last],
  );
}

/// A box [w] by [h] on the middle of [box], moved within the page.
Rect _sized(Rect box, double w, double h) => Rect.fromLTWH(
      (box.center.dx - w / 2).clamp(0.0, 1 - w),
      (box.center.dy - h / 2).clamp(0.0, 1 - h),
      w,
      h,
    );

/// A page as drawn: its picture's file, and the part of the page in it
/// ([crop], in fractions of the page; null when it is whole). Anything
/// placed on a page by where it is on the page (a line being read, a word
/// under a finger) goes through [toShown] and [toPage], so it lands on the
/// print where the print is shown.
class ShownPage {
  const ShownPage(this.file, {this.crop});

  final String file;
  final Rect? crop;

  Rect get _part => crop ?? const Rect.fromLTRB(0, 0, 1, 1);

  /// Where the point [onPage] (in fractions of the page) is in the picture
  /// shown at [size].
  Offset toShown(Offset onPage, Size size) => Offset(
        (onPage.dx - _part.left) / _part.width * size.width,
        (onPage.dy - _part.top) / _part.height * size.height,
      );

  /// The point of the page (in fractions of it) at [onShown] in the picture
  /// shown at [size].
  Offset toPage(Offset onShown, Size size) => Offset(
        _part.left + onShown.dx / size.width * _part.width,
        _part.top + onShown.dy / size.height * _part.height,
      );
}
