part of 'scene.dart';

// ---------------------------------------------------------------------------
// Sketch: chalk on a dark slate. Nothing is ruled straight: every line is
// drawn twice by a slightly unsteady hand (a firm stroke and a fainter one
// beside it) with chalk dust along it, over a grainy board with the smudges
// of what was wiped off. Its own file, so scene.dart does not grow with it;
// a part of scene.dart, sharing its strokes and its grain.

/// Chalk, a little warm.
const _chalk = Color(0xFFEDE9E0);

/// A smooth wobble between -1 and 1 along [x] (value noise, eased), the same
/// for the same [seed]: a hand's unsteadiness, not a jitter.
double _wob(double x, int seed) {
  final i = x.floor();
  final f = x - i;
  double h(int n) {
    var v = (n * 374761393 + seed * 668265263) & 0x7fffffff;
    v = ((v ^ (v >> 13)) * 1274126177) & 0x7fffffff;
    return (v & 0xffff) / 0xffff * 2 - 1;
  }

  final u = f * f * (3 - 2 * f);
  return h(i) * (1 - u) + h(i + 1) * u;
}

/// [src] as a hand draws it, a point every [every] along it: pushed off its
/// line by up to [amp] in a slow wobble (with a little tremor on it), and a
/// closed shape not quite closed: the hand goes on a little past where it
/// began. Each contour is a list of points.
List<List<Offset>> _hand(Path src, int seed, {double amp = 2, double every = 7}) {
  final out = <List<Offset>>[];
  var k = 0;
  for (final m in src.computeMetrics()) {
    final over = m.isClosed ? math.min(m.length * 0.04, 14.0) : 0.0;
    final length = m.length + over;
    final steps = math.max(2, (length / every).ceil());
    final points = <Offset>[];
    for (var i = 0; i <= steps; i++) {
      final d = length * i / steps;
      final tg = m.getTangentForOffset(d % m.length == 0 && d > 0 ? m.length : d % m.length);
      if (tg == null) continue;
      final n = Offset(-tg.vector.dy, tg.vector.dx);
      // A slow bow, a smaller wander on it, and a tremor.
      final off = amp *
          (_wob(d / 140, seed + k * 31 + 9) * 0.7 + _wob(d / 50, seed + k * 31) * 0.6 + _wob(d / 8, seed + k * 31 + 5) * 0.18);
      points.add(tg.position + n * off);
    }
    out.add(points);
    k++;
  }
  return out;
}

/// [src] as a hand draws it (see [_hand]), as a path.
Path _wobbly(Path src, int seed, {double amp = 2, double every = 7}) {
  final out = Path();
  for (final points in _hand(src, seed, amp: amp, every: every)) {
    for (var i = 0; i < points.length; i++) {
      i == 0 ? out.moveTo(points[i].dx, points[i].dy) : out.lineTo(points[i].dx, points[i].dy);
    }
  }
  return out;
}

/// [path] drawn in chalk: a firm stroke that the board's grain breaks (its
/// pieces lighter and heavier), a fainter second pass a little off it, and
/// dust along it. [seed] keeps the same hand for the same thing.
void paintChalk(Canvas c, Path path,
    {Color color = _chalk, double width = 1.6, double alpha = 0.85, int seed = 0, double amp = 2.6, bool dust = true}) {
  final r = math.Random(seed);
  // The firm stroke, in one piece, but for where the chalk skipped.
  final firm = Path();
  for (final points in _hand(path, seed, amp: amp)) {
    for (var i = 0; i < points.length; i++) {
      if (i == 0 || r.nextDouble() < 0.03) {
        firm.moveTo(points[i].dx, points[i].dy);
      } else {
        firm.lineTo(points[i].dx, points[i].dy);
      }
    }
  }
  c.drawPath(firm, _stroke(color.withValues(alpha: alpha), width));
  // The board's grain showing through it: chalk lies on the tops of the
  // slate's grain and misses the hollows.
  final holes = <double>[];
  for (final m in firm.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += 1.6) {
      final p = m.getTangentForOffset(d)?.position;
      if (p == null || r.nextDouble() < 0.45) continue;
      holes
        ..add(p.dx + (r.nextDouble() - 0.5) * width * 1.2)
        ..add(p.dy + (r.nextDouble() - 0.5) * width * 1.2);
    }
  }
  if (holes.isNotEmpty) {
    c.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(holes),
      Paint()
        ..color = const Color(0xFF17191C).withValues(alpha: 0.55)
        ..strokeWidth = math.max(0.7, width * 0.45)
        ..strokeCap = StrokeCap.round,
    );
  }
  // The second pass, a little off the first.
  c.save();
  c.translate(width * 0.7, -width * 0.5);
  c.drawPath(_wobbly(path, seed + 7, amp: amp * 1.3), _stroke(color.withValues(alpha: alpha * 0.35), width * 0.6));
  c.restore();
  if (!dust) return;
  final points = <double>[];
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += 4) {
      final p = m.getTangentForOffset(d)?.position;
      if (p == null) continue;
      points
        ..add(p.dx + (r.nextDouble() - 0.5) * (width + amp) * 2.5)
        ..add(p.dy + (r.nextDouble() - 0.5) * (width + amp) * 2.5);
    }
  }
  if (points.isEmpty) return;
  c.drawRawPoints(
    ui.PointMode.points,
    Float32List.fromList(points),
    Paint()
      ..color = color.withValues(alpha: alpha * 0.28)
      ..strokeWidth = math.max(0.8, width * 0.5)
      ..strokeCap = StrokeCap.round,
  );
}

/// A five-armed chalk star at [p], [r] across.
Path _starPath(Offset p, double r) {
  final path = Path();
  for (var i = 0; i < 5; i++) {
    final a = -math.pi / 2 + i * math.pi * 4 / 5;
    final q = p + Offset(math.cos(a), math.sin(a)) * r;
    i == 0 ? path.moveTo(q.dx, q.dy) : path.lineTo(q.dx, q.dy);
  }
  return path..close();
}

/// A crescent moon at [p], [r] across.
Path _moonPath(Offset p, double r) => Path()
  ..addArc(Rect.fromCircle(center: p, radius: r), math.pi * 0.35, math.pi * 1.3)
  ..arcTo(Rect.fromCircle(center: p + Offset(r * 0.45, 0), radius: r * 0.8), math.pi * 1.4, -math.pi * 0.8, false)
  ..close();

/// An open book at [p], [w] wide.
Path _bookPath(Offset p, double w) {
  final h = w * 0.36;
  final path = Path()
    ..moveTo(p.dx, p.dy + h * 0.2)
    ..quadraticBezierTo(p.dx - w * 0.25, p.dy - h * 0.25, p.dx - w / 2, p.dy)
    ..lineTo(p.dx - w / 2, p.dy + h)
    ..quadraticBezierTo(p.dx - w * 0.25, p.dy + h * 0.75, p.dx, p.dy + h * 1.2)
    ..quadraticBezierTo(p.dx + w * 0.25, p.dy + h * 0.75, p.dx + w / 2, p.dy + h)
    ..lineTo(p.dx + w / 2, p.dy)
    ..quadraticBezierTo(p.dx + w * 0.25, p.dy - h * 0.25, p.dx, p.dy + h * 0.2)
    ..lineTo(p.dx, p.dy + h * 1.2);
  // A few lines of writing on each page.
  for (var i = 0; i < 3; i++) {
    final y = p.dy + h * (0.3 + i * 0.22);
    path
      ..moveTo(p.dx - w * 0.42, y)
      ..lineTo(p.dx - w * 0.1, y + h * 0.05)
      ..moveTo(p.dx + w * 0.1, y + h * 0.05)
      ..lineTo(p.dx + w * (i == 2 ? 0.28 : 0.42), y);
  }
  return path;
}

/// A loose spiral at [p], [r] across.
Path _spiralPath(Offset p, double r) {
  final path = Path();
  for (var i = 0; i <= 60; i++) {
    final a = i / 60 * math.pi * 5;
    final q = p + Offset(math.cos(a), math.sin(a)) * (r * i / 60);
    i == 0 ? path.moveTo(q.dx, q.dy) : path.lineTo(q.dx, q.dy);
  }
  return path;
}

/// The board's stars, where it draws them and its life twinkles them.
List<(Offset, double)> _stars(Size s) =>
    [(Offset(s.width - 100, 66), 9.0), (Offset(s.width - 22, 150), 6.0), (Offset(s.width - 132, 120), 5.0)];

/// The board, drawn once at the screen's size: slate, wiped-off smudges,
/// grain, and a few doodles kept to the edges, never under a list.
class _Sketch {
  _Sketch(this.c, this.s);

  final Canvas c;
  final Size s;

  void paint() {
    final rect = Offset.zero & s;
    c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(s.width * 0.3, s.height), const [
          Color(0xFF1C1F22),
          Color(0xFF16181B),
          Color(0xFF111315),
        ], const [
          0,
          0.55,
          1,
        ]),
    );
    final r = math.Random(41);
    // What was wiped off: wide soft swipes of white.
    for (var i = 0; i < 6; i++) {
      final at = Offset(r.nextDouble() * s.width, r.nextDouble() * s.height);
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate((r.nextDouble() - 0.5) * 0.8);
      final w = s.width * (0.5 + r.nextDouble() * 0.5);
      final h = 40 + r.nextDouble() * 60;
      c.drawOval(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, w / 2, [
            Colors.white.withValues(alpha: 0.035),
            Colors.white.withValues(alpha: 0),
          ]),
      );
      c.restore();
    }
    _grain(c, s, r, dark: 0.28, light: 0.08, per: 9);
    // The doodles, faint, at the corners and edges.
    const a = 0.3;
    paintChalk(c, _moonPath(Offset(s.width - 48, 92), 18), alpha: a, seed: 1, width: 1.6);
    for (final (p, k) in _stars(s)) {
      paintChalk(c, _starPath(p, k), alpha: a, seed: p.dx.round(), width: 1.1, dust: false);
    }
    paintChalk(c, _spiralPath(Offset(26, s.height * 0.42), 14), alpha: a * 0.8, seed: 3, width: 1.2);
    paintChalk(c, _bookPath(Offset(56, s.height - 132), 64), alpha: a, seed: 5, width: 1.4);
    final wave = Path()..moveTo(s.width * 0.55, s.height - 72);
    for (var x = s.width * 0.55; x <= s.width - 18; x += 8) {
      wave.lineTo(x, s.height - 72 + math.sin(x / 9) * 3);
    }
    paintChalk(c, wave, alpha: a * 0.9, seed: 9, width: 1.3);
    // Hatching, as a hand tries the chalk.
    for (var i = 0; i < 5; i++) {
      final x = s.width - 70 + i * 8.0;
      paintChalk(c, Path()
        ..moveTo(x, s.height - 118)
        ..lineTo(x + 10, s.height - 136), alpha: a * 0.7, seed: 20 + i, width: 1.1, dust: false);
    }
    _vignette(c, s, edge: 0.7);
  }
}

/// What moves on the board: its stars twinkle and boil (redrawn by the
/// hand about six times a second, as drawn animation does) and chalk dust
/// drifts down through the light.
void _sketchLife(Canvas c, Size s, double t) {
  final frame = (t * 6).floor();
  for (final (i, (p, k)) in _stars(s).indexed) {
    final glow = 0.5 + 0.5 * math.sin(t * 1.3 + i * 2.1);
    paintChalk(c, _starPath(p, k), alpha: 0.2 + glow * 0.35, seed: frame * 3 + i, width: 1.3, amp: 1.2, dust: false);
  }
  for (var d = 0; d < 14; d++) {
    final seed = d * 13.7;
    const life = 9.0;
    final age = ((t + seed) % life) / life;
    final x = (seed * 37) % s.width + math.sin(t * 0.6 + seed) * 12;
    final y = s.height * (0.1 + 0.8 * age);
    final a = math.sin(age * math.pi) * 0.22;
    c.drawCircle(Offset(x, y), 1.1, _fill(_chalk.withValues(alpha: a)));
  }
}

/// A cover in chalk: a frame sketched twice round it, its corners ticked.
void _sketchCoverFrame(Canvas c, Rect rect, double radius) {
  final seed = (rect.width * 3 + rect.height).round();
  final w = (rect.width * 0.02).clamp(1.0, 2.0);
  paintChalk(c, Path()..addRRect(RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius))),
      alpha: 0.8, seed: seed, width: w, amp: math.min(2.4, rect.width * 0.03), dust: rect.width > 60);
  if (rect.width < 60) return;
  // Ticks past two corners, as a hand overshoots.
  paintChalk(c, Path()
    ..moveTo(rect.left - 4, rect.top + 3)
    ..lineTo(rect.left + 14, rect.top - 2), alpha: 0.45, seed: seed + 1, width: w * 0.8, dust: false);
  paintChalk(c, Path()
    ..moveTo(rect.right + 4, rect.bottom - 3)
    ..lineTo(rect.right - 14, rect.bottom + 2), alpha: 0.45, seed: seed + 2, width: w * 0.8, dust: false);
}

/// A panel on the board: a little lighter slate, its own grain, and a chalk
/// outline with an overshoot along its top.
void _sketchPanel(Canvas c, Rect rect, RRect rr, {required bool lit}) {
  c.drawRRect(
    rr,
    Paint()
      ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
        lit ? const Color(0xFF26292D) : const Color(0xFF212427),
        const Color(0xFF1A1C1F),
      ]),
  );
  final seed = (rect.width * 31 + rect.height).round();
  final r = math.Random(seed);
  c.save();
  c.clipRRect(rr);
  final n = (rect.width * rect.height / 120).clamp(10, 600).round();
  final specks = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    specks[i * 2] = rect.left + r.nextDouble() * rect.width;
    specks[i * 2 + 1] = rect.top + r.nextDouble() * rect.height;
  }
  c.drawRawPoints(ui.PointMode.points, specks, Paint()
    ..color = Colors.white.withValues(alpha: 0.05)
    ..strokeWidth = 1);
  c.restore();
  paintChalk(c, Path()..addRRect(rr.deflate(1)), alpha: 0.55, seed: seed, width: 1.4, amp: math.min(3.4, rect.shortestSide * 0.08), dust: rect.height > 30);
  if (rect.width > 80 && rect.height > 30) {
    paintChalk(c, Path()
      ..moveTo(rect.left + rr.tlRadiusX * 0.6, rect.top + 2.5)
      ..lineTo(rect.right - rr.trRadiusX * 0.2 + 5, rect.top + 1), alpha: 0.22, seed: seed + 3, width: 1, dust: false);
  }
}

/// Inside a button on the board, clipped to it: a chosen (bright) one
/// scribbled over with chalk, as a hand fills a shape in; a plain one grainy.
void _sketchButtonInside(Canvas c, Rect rect, {required bool bright}) {
  final seed = (rect.width * 7 + rect.height).round();
  if (bright) {
    for (var x = rect.left - rect.height; x < rect.right; x += 4.5) {
      c.drawPath(
        _wobbly(Path()
          ..moveTo(x, rect.bottom)
          ..lineTo(x + rect.height, rect.top), seed + x.round(), amp: 0.6, every: 6),
        _stroke(Colors.white.withValues(alpha: 0.1), 1),
      );
    }
  } else {
    final r = math.Random(seed);
    for (var i = 0; i < (rect.width * rect.height / 50).clamp(6, 80); i++) {
      c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height), 0.5,
          _fill(Colors.white.withValues(alpha: 0.07)));
    }
  }
}

/// A button's chalk ring.
void _sketchButtonEdge(Canvas c, Path path, Rect rect, Color fill, {required bool bright}) {
  final seed = (rect.width * 7 + rect.height).round();
  paintChalk(c, path, color: bright ? Color.lerp(fill, Colors.white, 0.55)! : _chalk, alpha: bright ? 0.8 : 0.6, seed: seed,
      width: 1.4, amp: math.min(1.1, rect.shortestSide * 0.04), dust: rect.shortestSide > 30);
}

/// An empty shelf on the board: an open book sketched, a star over it.
void _sketchEmpty(Canvas c, Size s) {
  final m = Offset(s.width / 2, s.height / 2);
  paintChalk(c, _bookPath(m + Offset(0, s.height * 0.02), s.width * 0.74), seed: 2, width: 1.8);
  paintChalk(c, _starPath(m + Offset(s.width * 0.26, -s.height * 0.3), s.width * 0.08), seed: 4, width: 1.4,
      color: const Color(0xFFF08A7E));
  paintChalk(c, _starPath(m + Offset(-s.width * 0.28, -s.height * 0.24), s.width * 0.05), seed: 6, width: 1.2, alpha: 0.6);
}

/// The drawer's crest (a moon among stars) or its foot (a stick of chalk on
/// a wavy line, its dust beside it).
void _sketchOrnament(Canvas c, Size s, {required bool foot}) {
  final m = Offset(s.width / 2, s.height / 2);
  if (!foot) {
    paintChalk(c, _moonPath(m, s.width * 0.22), seed: 11, width: 2);
    for (var i = 0; i < 5; i++) {
      final a = -math.pi * 0.9 + i * math.pi * 0.45;
      paintChalk(c, _starPath(m + Offset(math.cos(a), math.sin(a)) * s.width * 0.38, s.width * (i.isEven ? 0.05 : 0.035)),
          seed: 12 + i, width: 1.2, alpha: 0.7, dust: false);
    }
    return;
  }
  final y = s.height - 16;
  final wave = Path()..moveTo(s.width * 0.08, y);
  for (var x = s.width * 0.08; x <= s.width * 0.92; x += 6) {
    wave.lineTo(x, y + math.sin(x / 8) * 2.5);
  }
  paintChalk(c, wave, seed: 21, width: 1.6, alpha: 0.7);
  final stick = Rect.fromCenter(center: Offset(s.width * 0.62, y - 16), width: 34, height: 9);
  c.save();
  c.translate(stick.center.dx, stick.center.dy);
  c.rotate(-0.2);
  final rr = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: stick.width, height: stick.height), const Radius.circular(3));
  c.drawRRect(rr, _fill(_chalk.withValues(alpha: 0.85)));
  c.drawRRect(rr, _stroke(Colors.black.withValues(alpha: 0.25), 0.8));
  c.restore();
  final r = math.Random(22);
  for (var i = 0; i < 18; i++) {
    c.drawCircle(Offset(s.width * 0.62 - 30 + r.nextDouble() * 22, y - 4 - r.nextDouble() * 8), 0.6 + r.nextDouble() * 0.6,
        _fill(_chalk.withValues(alpha: 0.4)));
  }
}

/// A rule between groups: a chalk line, a little unsteady.
void _sketchDivider(Canvas c, Size s) {
  final y = s.height / 2;
  paintChalk(c, Path()
    ..moveTo(2, y)
    ..lineTo(s.width - 2, y), seed: s.width.round(), width: 1.2, alpha: 0.45, amp: 1.4, dust: false);
}

// ---------------------------------------------------------------------------
// The player's icons and its play button, drawn by hand on the board: not
// Material's icons roughened, but shapes of their own, a little uneven.

/// The icons the board has its own drawing of, in a 24-unit box.
Path? _sketchIconPath(IconData icon) {
  Path tri(Offset a, Offset b, Offset c) => Path()
    ..moveTo(a.dx, a.dy)
    ..lineTo(b.dx, b.dy)
    ..lineTo(c.dx, c.dy)
    ..close();
  Path bar(double x, double w) => Path()..addRRect(RRect.fromLTRBR(x, 5.5, x + w, 18.5, const Radius.circular(1.4)));
  if (icon == Icons.play_arrow_rounded) return tri(const Offset(7.5, 5), const Offset(19, 12.2), const Offset(7.2, 19));
  if (icon == Icons.pause_rounded) return bar(6.6, 3.8)..addPath(bar(13.8, 3.8), Offset.zero);
  if (icon == Icons.skip_previous_rounded) {
    return bar(5.5, 2.4)..addPath(tri(const Offset(18.5, 6), const Offset(9.2, 12.1), const Offset(18.3, 18)), Offset.zero);
  }
  if (icon == Icons.skip_next_rounded) {
    return bar(16.1, 2.4)..addPath(tri(const Offset(5.5, 6), const Offset(14.8, 12.1), const Offset(5.7, 18)), Offset.zero);
  }
  if (icon == Icons.fast_rewind_rounded) {
    return tri(const Offset(11.6, 6.4), const Offset(3.6, 12.1), const Offset(11.4, 17.8))
      ..addPath(tri(const Offset(20.4, 6.4), const Offset(12.4, 12), const Offset(20.2, 17.6)), Offset.zero);
  }
  if (icon == Icons.fast_forward_rounded) {
    return tri(const Offset(3.6, 6.4), const Offset(11.6, 12.1), const Offset(3.8, 17.8))
      ..addPath(tri(const Offset(12.4, 6.4), const Offset(20.4, 12), const Offset(12.6, 17.6)), Offset.zero);
  }
  return null;
}

/// Whether the board draws [icon] itself.
bool sketchDraws(IconData icon) => _sketchIconPath(icon) != null;

/// [icon] painted in chalk, at the size and colour the icon theme gives
/// (an IconButton's, its disabled colour too).
class SketchIcon extends StatelessWidget {
  const SketchIcon(this.icon, {super.key, this.size, this.color});

  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    return SizedBox(
      width: s,
      height: s,
      child: CustomPaint(painter: _SketchIconPainter(icon, color ?? theme.color ?? _chalk)),
    );
  }
}

class _SketchIconPainter extends CustomPainter {
  const _SketchIconPainter(this.icon, this.color);

  final IconData icon;
  final Color color;

  @override
  void paint(Canvas c, Size s) {
    final path = _sketchIconPath(icon);
    if (path == null) return;
    c.save();
    c.scale(s.width / 24);
    final seed = icon.codePoint;
    // Painted in, unevenly, then gone round once more.
    c.drawPath(_wobbly(path, seed, amp: 0.45, every: 2.5), _fill(color.withValues(alpha: color.a * 0.9)));
    final r = math.Random(seed);
    final holes = Float32List(60);
    final b = path.getBounds();
    for (var i = 0; i < 30; i++) {
      holes[i * 2] = b.left + r.nextDouble() * b.width;
      holes[i * 2 + 1] = b.top + r.nextDouble() * b.height;
    }
    c.save();
    c.clipPath(path);
    c.drawRawPoints(ui.PointMode.points, holes, Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round);
    c.restore();
    c.drawPath(_wobbly(path, seed + 3, amp: 0.55, every: 2.5), _stroke(color.withValues(alpha: color.a * 0.75), 1.1));
    c.restore();
  }

  @override
  bool shouldRepaint(_SketchIconPainter old) => old.icon != icon || old.color != color;
}

/// The play button's disc on the board: its fill's grain and an uneven chalk
/// rim a little past its edge, as a hand paints a round button.
class SketchDiscPainter extends CustomPainter {
  const SketchDiscPainter(this.fill);

  final Color fill;

  @override
  void paint(Canvas c, Size s) {
    final m = Offset(s.width / 2, s.height / 2);
    final rad = s.shortestSide / 2;
    final r = math.Random(5);
    final specks = Float32List(140);
    for (var i = 0; i < 70; i++) {
      final a = r.nextDouble() * math.pi * 2;
      final d = math.sqrt(r.nextDouble()) * rad * 0.95;
      specks[i * 2] = m.dx + math.cos(a) * d;
      specks[i * 2 + 1] = m.dy + math.sin(a) * d;
    }
    c.drawRawPoints(ui.PointMode.points, specks, Paint()
      ..color = Colors.black.withValues(alpha: 0.16)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round);
    paintChalk(c, Path()..addOval(Rect.fromCircle(center: m, radius: rad + 0.5)),
        color: Color.lerp(fill, Colors.white, 0.5)!, width: 1.6, alpha: 0.75, seed: 8, amp: 1.6, dust: false);
  }

  @override
  bool shouldRepaint(SketchDiscPainter old) => old.fill != fill;
}

/// [icon] as the board draws it, at [size], in [color] (for tests and
/// previews: on screen it is [SketchIcon]).
@visibleForTesting
void paintSketchIcon(Canvas c, IconData icon, Size size, {Color color = _chalk}) =>
    _SketchIconPainter(icon, color).paint(c, size);
