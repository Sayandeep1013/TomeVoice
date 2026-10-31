// Crop margins: where the print lies on a drawn page (the same steps the
// phone takes, in PdfPages.kt), and how a book's pages are cut from a few of
// them so they keep one scale.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/page_crop.dart';

/// A page as the phone draws it to look for its print: A4 in about 400,000
/// pixels, so its cells are two pixels square.
class _Page {
  _Page({this.w = 531, this.h = 752, int paper = 0xffffffff}) : px = Uint32List(w * h)..fillRange(0, w * h, paper);

  final int w, h;
  final Uint32List px;

  void fill(int x0, int y0, int x1, int y1, int c) {
    for (var y = math.max(0, y0); y < math.min(h, y1); y++) {
      for (var x = math.max(0, x0); x < math.min(w, x1); x++) {
        px[y * w + x] = c;
      }
    }
  }

  /// Lines of words, 5 pixels tall every 9, across [x0]..[x1] from [y0]
  /// down to [y1]: a page of text as it looks this small.
  void text(int x0, int y0, int x1, int y1, {int ink = 0xff111111, int seed = 1}) {
    final r = math.Random(seed);
    for (var y = y0; y + 5 <= y1; y += 9) {
      var x = x0;
      while (x < x1) {
        final word = math.min(x1 - x, 8 + r.nextInt(30));
        fill(x, y, x + word, y + 5, ink);
        x += word + 4;
      }
    }
  }

  /// Every pixel strayed by up to [by] either way, as a scan's paper is.
  void grain(int by, {int seed = 7}) {
    final r = math.Random(seed);
    for (var i = 0; i < px.length; i++) {
      final c = px[i];
      int ch(int v) => (v + r.nextInt(by * 2 + 1) - by).clamp(0, 255);
      px[i] = 0xff000000 | ch((c >> 16) & 0xff) << 16 | ch((c >> 8) & 0xff) << 8 | ch(c & 0xff);
    }
  }

  Rect? get print => findPrint(px, w, h);
}

/// [box] matches [want] to within [by]: a cell or so (three pixels on this
/// page) by default.
Matcher near(Rect want, {double by = 3}) => predicate<Rect?>(
      (box) =>
          box != null &&
          (box.left - want.left).abs() <= by &&
          (box.top - want.top).abs() <= by &&
          (box.right - want.right).abs() <= by &&
          (box.bottom - want.bottom).abs() <= by,
      'within $by of $want',
    );

/// The same box, but for rounding.
Matcher same(Rect want) => near(want, by: 1e-9);

void main() {
  group('the print on a page', () {
    test('a page with margins: its box is the text', () {
      final page = _Page()..text(64, 80, 466, 672);
      expect(page.print, near(const Rect.fromLTRB(64, 80, 466, 672)));
    });

    test('specks of dust in the margins are passed over', () {
      final page = _Page()..text(64, 80, 466, 672);
      // A pixel, two side by side, and two by two (each in a cell): dust,
      // this small.
      page
        ..fill(12, 12, 13, 13, 0xff000000)
        ..fill(500, 30, 502, 31, 0xff202020)
        ..fill(20, 700, 22, 702, 0xff000000)
        ..fill(510, 738, 512, 740, 0xff303030)
        ..fill(30, 400, 31, 401, 0xff000000);
      expect(page.print, near(const Rect.fromLTRB(64, 80, 466, 672)));
    });

    test('a picture to the edges is print all over', () {
      final page = _Page();
      for (var y = 0; y < page.h; y++) {
        for (var x = 0; x < page.w; x++) {
          final r = (x * 255) ~/ page.w, g = (y * 255) ~/ page.h, b = ((x + y) * 7) & 0xff;
          page.px[y * page.w + x] = 0xff000000 | r << 16 | g << 8 | b;
        }
      }
      expect(page.print, Rect.fromLTWH(0, 0, page.w.toDouble(), page.h.toDouble()));
    });

    test('a picture with margins round it is cut to the picture, not into it', () {
      final page = _Page();
      for (var y = 120; y < 520; y++) {
        for (var x = 70; x < 460; x++) {
          page.px[y * page.w + x] = 0xff000000 | ((x * 3) & 0xff) << 16 | ((y * 5) & 0xff) << 8 | 0x80;
        }
      }
      page.text(70, 560, 460, 640);
      expect(page.print, near(const Rect.fromLTRB(70, 120, 460, 640)));
    });

    test('a page number and a running head are print', () {
      final page = _Page()
        ..text(64, 80, 466, 672)
        // The running head, small and grey, well above the text.
        ..fill(200, 40, 330, 45, 0xff888888)
        // A page number: one narrow digit, low in the margin.
        ..fill(264, 716, 266, 723, 0xff111111);
      expect(page.print, near(const Rect.fromLTRB(64, 40, 466, 723)));
    });

    test('a page number in small type is print too', () {
      // A six-point "1": a pixel wide, four tall.
      final page = _Page()
        ..text(64, 80, 466, 672)
        ..fill(265, 716, 266, 720, 0xff222222);
      expect(page.print, near(const Rect.fromLTRB(64, 80, 466, 720)));
    });

    test('a mark bigger than dust, alone in a margin, is print: nothing is cut on a guess', () {
      final page = _Page()
        ..text(64, 80, 466, 672)
        ..fill(500, 300, 504, 304, 0xff000000);
      expect(page.print, near(const Rect.fromLTRB(64, 80, 504, 672)));
    });

    test('a blank page has no print, even with dust on it', () {
      expect(_Page().print, isNull);
      final dusty = _Page()
        ..fill(100, 100, 101, 101, 0xff000000)
        ..fill(300, 600, 302, 602, 0xff000000);
      expect(dusty.print, isNull);
    });

    test("a scan's grey edge and the dark past its foot are passed over; its grain too", () {
      final page = _Page(paper: 0xffece6d8)
        ..text(70, 84, 460, 668, ink: 0xff2a2620)
        // The shadow down the binding: grey, 16 pixels wide, the whole height.
        ..fill(0, 0, 16, 752, 0xff8a857c)
        // Dark past the page's foot, across its width.
        ..fill(0, 740, 531, 752, 0xff2c2a28)
        ..grain(6);
      expect(page.print, near(const Rect.fromLTRB(70, 84, 460, 668)));
    });

    test('a dark border all round a scanned page is passed over', () {
      final page = _Page(paper: 0xfff4f1ea)..text(70, 84, 460, 668);
      const t = 8;
      page
        ..fill(0, 0, 531, t, 0xff181818)
        ..fill(0, 752 - t, 531, 752, 0xff181818)
        ..fill(0, 0, t, 752, 0xff181818)
        ..fill(531 - t, 0, 531, 752, 0xff181818);
      expect(page.print, near(const Rect.fromLTRB(70, 84, 460, 668)));
    });

    test('a line of print that only grazes an edge is still print', () {
      // A scan cut tight: its first line's tall letters touch the top, its
      // small ones run together, as small type does.
      final page = _Page()..fill(64, 3, 466, 8, 0xff111111);
      for (var x = 70; x < 460; x += 37) {
        page.fill(x, 0, x + 2, 3, 0xff111111);
      }
      page.text(64, 30, 466, 666, seed: 2);
      expect(page.print, near(const Rect.fromLTRB(64, 0, 466, 666)));
    });

    test('a coloured band along an edge is print, not a shadow', () {
      final page = _Page()
        ..text(64, 80, 466, 672)
        ..fill(0, 0, 14, 752, 0xffc0392b);
      expect(page.print, near(const Rect.fromLTRB(0, 0, 466, 752)));
    });

    test('a thin frame round the text is print', () {
      final page = _Page()..text(80, 90, 450, 660);
      page
        ..fill(40, 40, 491, 41, 0xff000000)
        ..fill(40, 711, 491, 712, 0xff000000)
        ..fill(40, 40, 41, 712, 0xff000000)
        ..fill(490, 40, 491, 712, 0xff000000);
      expect(page.print, near(const Rect.fromLTRB(40, 40, 491, 712)));
    });

    test('a tiny drawing still works: every pixel is a cell', () {
      final page = _Page(w: 60, h: 80)..fill(10, 12, 50, 70, 0xff000000);
      expect(page.print, const Rect.fromLTRB(10, 12, 50, 70));
    });
  });

  group("a book's crop", () {
    // Facing pages mirror their margins: the even pages' print sits right,
    // the odd pages' left (or the other way), heads and numbers on both.
    const evenPrint = Rect.fromLTRB(0.16, 0.06, 0.88, 0.94);
    const oddPrint = Rect.fromLTRB(0.12, 0.06, 0.84, 0.94);
    const a4 = 0.707;

    CropPlan? plan(Map<int, Rect?> prints, {int pages = 40, double aspect = a4}) {
      final sample = prints.keys.toList();
      return CropPlan.from(sample, [for (final p in sample) prints[p]], List.filled(pages, aspect));
    }

    Map<int, Rect?> book({Map<int, Rect?> except = const {}}) => {
          for (final p in cropSample(40)) p: except.containsKey(p) ? except[p] : (p.isEven ? evenPrint : oddPrint),
        };

    test('the sample: every page of a short book, else six pairs spread through it', () {
      expect(cropSample(5), [0, 1, 2, 3, 4]);
      final s = cropSample(300);
      expect(s, hasLength(12));
      for (var i = 0; i < 12; i += 2) {
        expect(s[i].isEven, isTrue);
        expect(s[i + 1], s[i] + 1);
      }
      expect(s.first, greaterThan(10), reason: 'not the cover');
      expect(s.last, lessThan(290));
      expect(cropSample(13).toSet(), hasLength(12));
    });

    test('each side is cut to its print with room round it, both the same size', () {
      final p = plan(book())!;
      const room = 0.02, roomY = 0.02 * a4;
      expect(p.even.left, closeTo(evenPrint.left - room, 1e-9));
      expect(p.even.right, closeTo(evenPrint.right + room, 1e-9));
      expect(p.odd.left, closeTo(oddPrint.left - room, 1e-9));
      expect(p.even.top, closeTo(evenPrint.top - roomY, 1e-9));
      expect(p.even.bottom, closeTo(evenPrint.bottom + roomY, 1e-9));
      expect(p.even.width, closeTo(p.odd.width, 1e-9));
      expect(p.even.height, closeTo(p.odd.height, 1e-9));
      expect(p.shownAspect, closeTo(a4 * p.even.width / p.even.height, 1e-9));
      // A page's own print fits its side's box as it is.
      expect(p.cropFor(10, evenPrint, a4), same(p.even));
      expect(p.cropFor(11, oddPrint, a4), same(p.odd));
    });

    test("one page's wide table does not widen the rest: that page moves its box, or shows whole", () {
      final sample = cropSample(40);
      final wide = sample.firstWhere((p) => p.isEven);
      final p = plan(book(except: {wide: const Rect.fromLTRB(0.04, 0.06, 0.96, 0.94)}))!;
      expect(p.even.left, closeTo(evenPrint.left - 0.02, 1e-9), reason: 'the rest are not widened');
      expect(p.cropFor(wide, const Rect.fromLTRB(0.04, 0.06, 0.96, 0.94), a4), isNull, reason: 'shown whole');
      // A page whose print sits a little to one side: its box moves to hold it.
      final moved = p.cropFor(wide, evenPrint.shift(const Offset(-0.03, 0)), a4)!;
      expect(moved.width, closeTo(p.even.width, 1e-9));
      expect(moved.height, closeTo(p.even.height, 1e-9));
      expect(moved.left, closeTo(evenPrint.left - 0.03 - 0.02, 1e-9));
      expect(moved.top, closeTo(p.even.top, 1e-9));
    });

    test('a blank page takes its side\'s box; a page of another shape shows whole', () {
      final p = plan(book())!;
      expect(p.cropFor(6, null, a4), p.even);
      expect(p.cropFor(7, null, a4), p.odd);
      expect(p.cropFor(6, evenPrint, 1.3), isNull);
      expect(p.fits(a4 * 1.01), isTrue);
      expect(p.fits(a4 * 1.05), isFalse);
    });

    test('a picture to the edges shows whole, and a book mostly of them is not cut', () {
      const full = Rect.fromLTRB(0, 0, 1, 1);
      final p = plan(book(except: {cropSample(40)[4]: full}))!;
      expect(p.cropFor(cropSample(40)[4], full, a4), isNull);
      expect(plan({for (final s in cropSample(40)) s: s % 3 == 0 ? evenPrint : full}), isNull);
    });

    test('little to cut, a strip of a page, nothing but blank pages, or no sample: not cut', () {
      expect(plan({for (final s in cropSample(40)) s: const Rect.fromLTRB(0.03, 0.03, 0.97, 0.97)}), isNull);
      expect(plan({for (final s in cropSample(40)) s: const Rect.fromLTRB(0.36, 0.02, 0.64, 0.98)}), isNull);
      expect(plan({for (final s in cropSample(40)) s: null}), isNull);
      expect(CropPlan.from(const [], const [], const [a4]), isNull);
    });

    test('pages of another shape are left out of the plan', () {
      final sample = cropSample(40);
      final aspects = List.filled(40, a4);
      aspects[sample[2]] = 1.4;
      final p = CropPlan.from(sample, [
        for (final s in sample) s == sample[2] ? const Rect.fromLTRB(0, 0, 1, 1) : (s.isEven ? evenPrint : oddPrint),
      ], aspects)!;
      expect(p.aspect, a4);
      expect(p.even.left, closeTo(evenPrint.left - 0.02, 1e-9));
    });
  });

  group('a page as shown', () {
    test('a point of the page lands where the cut part shows it, and back', () {
      const crop = Rect.fromLTRB(0.1, 0.05, 0.9, 0.95);
      const shown = ShownPage('p.jpg', crop: crop);
      const size = Size(400, 900);
      void lands(Offset got, Offset want) {
        expect(got.dx, closeTo(want.dx, 1e-9));
        expect(got.dy, closeTo(want.dy, 1e-9));
      }

      lands(shown.toShown(crop.topLeft, size), Offset.zero);
      lands(shown.toShown(crop.bottomRight, size), const Offset(400, 900));
      lands(shown.toShown(const Offset(0.5, 0.5), size), const Offset(200, 450));
      const point = Offset(0.3, 0.7);
      lands(shown.toPage(shown.toShown(point, size), size), point);
      lands(shown.toPage(const Offset(100, 450), size), const Offset(0.3, 0.5));
      // A page shown whole maps as it is.
      expect(const ShownPage('p.jpg').toShown(const Offset(0.25, 0.5), const Size(400, 600)), const Offset(100, 300));
    });
  });
}
