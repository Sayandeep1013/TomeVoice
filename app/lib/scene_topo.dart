part of 'scene.dart';

// Topography: the contour lines of a survey map, as on a desk mat, by day
// (warm paper, ink-brown lines) and by night (charcoal, pale lines), with one
// signal orange. The only scene that follows the phone's light and dark: its
// palette carries a day scene and a night scene (Palette.sceneFor).
//
// The lines are not a picture. A smooth height field (a few octaves of value
// noise) is traced at even heights by marching squares, every fifth line an
// index contour, heavier; the whole is drawn once at the screen's size and
// kept, like every backdrop. Controls are flat, cut from the same map: a
// hairline frame with registration ticks at its corners, buttons with their
// own contours pressed into them, a crosshair for the slider's knob, a scale
// bar for a divider, a compass rose on an empty screen, and a "you are here"
// marker that drifts slowly over the map.

/// The topography scenes.
const topoScenes = {Scene.topoDay, Scene.topoNight};

class _Topo {
  const _Topo({required this.ground, required this.groundDeep, required this.line, required this.panel, required this.ink, required this.signal});

  final Color ground;
  final Color groundDeep;

  /// The contour lines (index lines are this, stronger).
  final Color line;

  /// A panel's face.
  final Color panel;

  /// Frames and ticks.
  final Color ink;

  /// The one orange.
  final Color signal;
}

_Topo _topoOf(Scene scene) => scene == Scene.topoNight
    ? const _Topo(
        ground: Color(0xFF16181B),
        groundDeep: Color(0xFF101214),
        line: Color(0xFFC9CED6),
        panel: Color(0xF01C1F23),
        ink: Color(0xFFB8BEC7),
        signal: Color(0xFFFF7A45),
      )
    : const _Topo(
        ground: Color(0xFFF3F0E8),
        groundDeep: Color(0xFFE9E4D8),
        line: Color(0xFF6E6352),
        panel: Color(0xF2FBF9F4),
        ink: Color(0xFF4A453D),
        signal: Color(0xFFE8603C),
      );

// ---------------------------------------------------------------------------
// The map.

/// A smooth height at (x, y), 0 to 1: three octaves of value noise.
double _height(double x, double y, int seed) {
  double hash(int i, int j) {
    var h = (i * 374761393 + j * 668265263 + seed * 2147483647) & 0x7fffffff;
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff;
    return (h & 0xffff) / 0xffff;
  }

  double smooth(double t) => t * t * (3 - 2 * t);

  double noise(double x, double y) {
    final i = x.floor(), j = y.floor();
    final fx = smooth(x - i), fy = smooth(y - j);
    final a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1);
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
  }

  return noise(x, y) * 0.58 + noise(x * 2.1 + 17, y * 2.1 + 5) * 0.28 + noise(x * 4.3 + 3, y * 4.3 + 29) * 0.14;
}

/// The contour lines over [rect] at [levels] heights, traced by marching
/// squares on a grid of [cell]: the plain lines and the index lines (every
/// fifth), each one path.
(Path, Path) _contours(Rect rect, {required int seed, double cell = 7, int levels = 22, double scale = 210}) {
  final cols = (rect.width / cell).ceil() + 1;
  final rows = (rect.height / cell).ceil() + 1;
  final h = List.generate(rows, (r) => List.generate(cols, (c) => _height((rect.left + c * cell) / scale, (rect.top + r * cell) / scale, seed)));
  final thin = Path(), bold = Path();
  for (var k = 1; k < levels; k++) {
    final v = 0.15 + 0.7 * k / levels;
    final path = k % 5 == 0 ? bold : thin;
    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < cols - 1; c++) {
        final a = h[r][c], b = h[r][c + 1], cc = h[r + 1][c + 1], d = h[r + 1][c];
        final idx = (a > v ? 8 : 0) | (b > v ? 4 : 0) | (cc > v ? 2 : 0) | (d > v ? 1 : 0);
        if (idx == 0 || idx == 15) continue;
        final x = rect.left + c * cell, y = rect.top + r * cell;
        Offset top() => Offset(x + cell * (v - a) / (b - a), y);
        Offset right() => Offset(x + cell, y + cell * (v - b) / (cc - b));
        Offset bottom() => Offset(x + cell * (v - d) / (cc - d), y + cell);
        Offset left() => Offset(x, y + cell * (v - a) / (d - a));
        void seg(Offset p, Offset q) => path
          ..moveTo(p.dx, p.dy)
          ..lineTo(q.dx, q.dy);
        switch (idx) {
          case 1 || 14:
            seg(left(), bottom());
          case 2 || 13:
            seg(bottom(), right());
          case 3 || 12:
            seg(left(), right());
          case 4 || 11:
            seg(top(), right());
          case 5:
            seg(left(), top());
            seg(bottom(), right());
          case 6 || 9:
            seg(top(), bottom());
          case 7 || 8:
            seg(left(), top());
          case 10:
            seg(left(), bottom());
            seg(top(), right());
        }
      }
    }
  }
  return (thin, bold);
}

void _paintTopoBackdrop(Canvas canvas, Size size, Scene scene) {
  final t = _topoOf(scene);
  final rect = Offset.zero & size;
  canvas.drawRect(rect, Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [t.ground, t.groundDeep]));
  final (thin, bold) = _contours(rect, seed: 11);
  final night = scene == Scene.topoNight;
  canvas.drawPath(thin, _stroke(t.line.withValues(alpha: night ? 0.16 : 0.22), 0.8)..strokeCap = StrokeCap.round);
  canvas.drawPath(bold, _stroke(t.line.withValues(alpha: night ? 0.3 : 0.38), 1.3)..strokeCap = StrokeCap.round);
  // The survey grid: a faint cross every so often, and the map's ticks
  // down its edges.
  final grid = _stroke(t.ink.withValues(alpha: night ? 0.18 : 0.2), 0.8);
  const step = 120.0;
  for (var x = step; x < size.width; x += step) {
    for (var y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), grid);
      canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), grid);
    }
  }
  final tick = _stroke(t.ink.withValues(alpha: night ? 0.3 : 0.32), 0.8);
  for (var y = 24.0; y < size.height; y += 24) {
    final long = (y / 24).round() % 5 == 0;
    canvas.drawLine(Offset(0, y), Offset(long ? 9 : 5, y), tick);
    canvas.drawLine(Offset(size.width, y), Offset(size.width - (long ? 9 : 5), y), tick);
  }
}

// ---------------------------------------------------------------------------
// Frames, panels, buttons.

void _topoEdge(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (rect.width < 8 || rect.height < 8) return;
  final t = _topoOf(scene);
  final rr = corners.toRRect(rect);
  // A hairline, as a map's frame; no corner marks (the owner found the
  // orange right angles on menus and sheets too much).
  c.drawRRect(rr.deflate(0.5), _stroke(t.ink.withValues(alpha: lit ? 0.5 : 0.36), 0.9));
}

void _topoPanel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {required bool lit}) {
  if (rect.isEmpty) return;
  final key = 'tp:${scene.name}:${_sizeKey(rect)}:${corners.topLeft.x.round()}:${corners.bottomLeft.x.round()}:$lit';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) {
    final t = _topoOf(scene);
    final rr = corners.toRRect(r);
    c.drawRRect(rr, _fill(t.panel));
    // A corner of the map showing through, faintly, where a big panel has
    // room for it: one patch of contours made once and kept, laid into each
    // panel (made anew for each panel's size, they cost a scroll 50-150 ms
    // frames as new rows came in).
    if (r.width > 160 && r.height > 80) {
      c.save();
      c.clipRRect(rr);
      final patch = _contourPatch(scene);
      final w = math.min(r.width * 0.45, _patchSize.width);
      // Its right edge (where the lines are strongest) at the panel's.
      c.translate(r.right - _patchSize.width, r.top);
      c.clipRect(Rect.fromLTWH(_patchSize.width - w, 0, w, math.min(r.height, _patchSize.height)));
      c.drawImageRect(patch, Offset.zero & Size(patch.width.toDouble(), patch.height.toDouble()), Offset.zero & _patchSize,
          Paint()..filterQuality = FilterQuality.medium);
      c.restore();
    }
    _topoEdge(c, r, scene, corners, lit: lit);
  });
}

/// The size of the kept patch of contours panels show a corner of.
const _patchSize = Size(220, 420);

final _patches = <Scene, ui.Image>{};

/// A patch of contour lines, fading out toward its left, made once as an
/// image (2.5 pixels to a point): kept as a picture, its thousands of line
/// pieces were drawn again in every panel on every frame of a scroll.
ui.Image _contourPatch(Scene scene) => _patches[scene] ??= () {
      final t = _topoOf(scene);
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder)..scale(2.5);
      final rect = Offset.zero & _patchSize;
      final (thin, bold) = _contours(rect, seed: 23, cell: 6, levels: 18, scale: 120);
      final shader = ui.Gradient.linear(rect.centerRight, rect.centerLeft, [t.line.withValues(alpha: 0.14), t.line.withValues(alpha: 0)]);
      c.drawPath(thin, Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7);
      c.drawPath(bold, Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1);
      final picture = recorder.endRecording();
      try {
        return picture.toImageSync((_patchSize.width * 2.5).round(), (_patchSize.height * 2.5).round());
      } finally {
        picture.dispose();
      }
    }();

void _topoButton(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  if (rect.isEmpty) return;
  final key = 'tb:${scene.name}:${_sizeKey(rect)}:${fill.toARGB32()}:${radius.topLeft.x.round()}';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) {
    final t = _topoOf(scene);
    final rr = radius.toRRect(r);
    final night = scene == Scene.topoNight;
    // Filled: the colour itself. Quiet: the panel, tinted by what it is.
    final strong = night ? fill.computeLuminance() > 0.18 : fill.computeLuminance() < 0.6;
    final face = strong ? fill : Color.lerp(t.panel.withValues(alpha: 1), fill, 0.35)!;
    c.drawRRect(rr, _fill(face));
    // Its own contours pressed in: rings following its shape.
    c.save();
    c.clipRRect(rr);
    final ring = _stroke((strong ? Colors.white : t.line).withValues(alpha: strong ? 0.16 : 0.12), 0.7);
    for (var i = 1; i <= 4; i++) {
      final d = math.min(4.0, r.shortestSide * 0.09) * i;
      if (d * 2 >= r.shortestSide) break;
      c.drawRRect(rr.deflate(d).shift(Offset(d * 0.35, d * 0.2)), ring);
    }
    c.restore();
    c.drawRRect(rr.deflate(0.5), _stroke(strong ? Color.lerp(fill, Colors.black, 0.3)! : t.ink.withValues(alpha: 0.45), 1));
  });
}

void _topoKnob(Canvas c, Offset center, double r, Scene scene, Color colour) {
  final t = _topoOf(scene);
  // A crosshair on a disc.
  c.drawCircle(center, r, _fill(t.panel.withValues(alpha: 1)));
  c.drawCircle(center, r - 0.6, _stroke(colour, 1.6));
  final cross = _stroke(colour, 1.1);
  c.drawLine(center - Offset(r + 3, 0), center - Offset(r * 0.35, 0), cross);
  c.drawLine(center + Offset(r * 0.35, 0), center + Offset(r + 3, 0), cross);
  c.drawLine(center - Offset(0, r + 3), center - Offset(0, r * 0.35), cross);
  c.drawLine(center + Offset(0, r * 0.35), center + Offset(0, r + 3), cross);
  c.drawCircle(center, 1.6, _fill(t.signal));
}

void _topoCoverFrame(Canvas c, Rect rect, Scene scene, double radius) {
  final t = _topoOf(scene);
  c.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)).deflate(0.6), _stroke(t.ink.withValues(alpha: 0.5), 1));
}

/// A scale bar: a rule with ticks, its first span filled.
void _topoDivider(Canvas c, Size s, Scene scene) {
  final t = _topoOf(scene);
  final y = s.height / 2;
  final w = math.min(s.width * 0.5, 180.0);
  final x0 = (s.width - w) / 2;
  c.drawLine(Offset(0, y), Offset(x0 - 8, y), _stroke(t.ink.withValues(alpha: 0.25), 0.7));
  c.drawLine(Offset(x0 + w + 8, y), Offset(s.width, y), _stroke(t.ink.withValues(alpha: 0.25), 0.7));
  final span = w / 4;
  for (var i = 0; i < 4; i++) {
    final r = Rect.fromLTWH(x0 + i * span, y - 2, span, 4);
    c.drawRect(r, i.isEven ? _fill(t.ink.withValues(alpha: 0.7)) : _stroke(t.ink.withValues(alpha: 0.7), 0.8));
  }
  c.drawRect(Rect.fromLTWH(x0, y - 2, span, 4), _fill(t.signal));
}

/// A compass rose: on an empty screen, and at a screen's head.
void _topoCompass(Canvas c, Size s, Scene scene) {
  final t = _topoOf(scene);
  final m = Offset(s.width / 2, s.height / 2);
  final r = s.shortestSide * 0.36;
  c.drawCircle(m, r, _stroke(t.ink.withValues(alpha: 0.5), 1));
  c.drawCircle(m, r * 0.82, _stroke(t.ink.withValues(alpha: 0.3), 0.7));
  for (var i = 0; i < 36; i++) {
    final a = i * math.pi / 18;
    final long = i % 9 == 0;
    c.drawLine(m + Offset(math.cos(a), math.sin(a)) * r * (long ? 0.74 : 0.86), m + Offset(math.cos(a), math.sin(a)) * r,
        _stroke(t.ink.withValues(alpha: long ? 0.7 : 0.35), long ? 1.2 : 0.7));
  }
  Path point(double a, double len, double width) {
    final tip = m + Offset(math.cos(a), math.sin(a)) * len;
    final side = Offset(math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)) * width;
    return Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(m.dx + side.dx, m.dy + side.dy)
      ..lineTo(m.dx - side.dx, m.dy - side.dy)
      ..close();
  }

  c.drawPath(point(-math.pi / 2, r * 0.72, r * 0.12), _fill(t.signal));
  c.drawPath(point(math.pi / 2, r * 0.72, r * 0.12), _fill(t.ink.withValues(alpha: 0.6)));
  c.drawPath(point(0, r * 0.5, r * 0.08), _fill(t.ink.withValues(alpha: 0.4)));
  c.drawPath(point(math.pi, r * 0.5, r * 0.08), _fill(t.ink.withValues(alpha: 0.4)));
  c.drawCircle(m, r * 0.05, _fill(t.ground));
}

void _topoOrnament(Canvas c, Size s, Scene scene, {required bool foot}) => foot ? _topoDivider(c, s, scene) : _topoCompass(c, s, scene);

/// What moves: a "you are here" marker drifting slowly over the map, its
/// ring opening and fading.
void _topoLife(Canvas c, Size s, double t, Scene scene) {
  final k = _topoOf(scene);
  final p = Offset(
    s.width * (0.5 + 0.32 * math.sin(t * 0.045)),
    s.height * (0.45 + 0.3 * math.sin(t * 0.031 + 1.3)),
  );
  final phase = (t % 2.6) / 2.6;
  c.drawCircle(p, 4 + phase * 22, _stroke(k.signal.withValues(alpha: 0.55 * (1 - phase)), 1.4));
  c.drawCircle(p, 4, _fill(k.signal.withValues(alpha: 0.9)));
  c.drawCircle(p, 1.6, _fill(k.ground));
}
