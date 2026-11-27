part of 'scene.dart';

// The light scenes: places by day, not by night. Their backdrops are pale (a
// William Morris wallpaper, a Redouté rose on paper, Hokusai's Red Fuji on
// washi, veined marble drawn here), washed toward their paper so dark type
// reads over them, and their controls are of their own light materials:
//
// * Morris garden: block-printed linen, indigo and madder, willow sprigs.
// * Botanical: watercolour paper, a wash pooling at its edges, gold hairlines
//   and rosebuds.
// * Ukiyo-e: washi with its fibres, brush-ink borders, vermilion seals.
// * Marble and gold: veined white marble, gold leaf and polished gold.
//
// As with the dark scenes, textured pieces are drawn once for a size and kept
// (_keptPicture), and nothing here blurs (no MaskFilter): a soft shadow is
// layered strokes of falling alpha.

/// The light scenes.
const lightScenes = {Scene.morris, Scene.botanical, Scene.ukiyoe, Scene.marble};

/// What each light scene is made of.
class _Stuff {
  const _Stuff({
    required this.paper,
    required this.paperDeep,
    required this.ink,
    required this.line,
    required this.mark,
    this.second,
  });

  /// Its ground and its panels' face.
  final Color paper;

  /// The paper where it is shaded (a panel's foot, an edge's pooling).
  final Color paperDeep;

  /// Its drawn lines: brush ink, printed green, a gold hairline.
  final Color ink;

  /// Its fine rules.
  final Color line;

  /// Its own mark: indigo, rose, vermilion, gold.
  final Color mark;

  /// A second colour: madder, leaf green.
  final Color? second;
}

_Stuff _stuffOf(Scene scene) => switch (scene) {
      Scene.morris => const _Stuff(
          paper: Color(0xFFF6F0E2),
          paperDeep: Color(0xFFE6DCC6),
          ink: Color(0xFF3E5A3A),
          line: Color(0xFF6E8A5E),
          mark: Color(0xFF2F5277),
          second: Color(0xFFA9452F),
        ),
      Scene.botanical => const _Stuff(
          paper: Color(0xFFFBF6EE),
          paperDeep: Color(0xFFF0DCDC),
          ink: Color(0xFF5E7A4E),
          line: Color(0xFFC6A25A),
          mark: Color(0xFFB85068),
          second: Color(0xFF6F8F5A),
        ),
      Scene.ukiyoe => const _Stuff(
          paper: Color(0xFFF5EEDD),
          paperDeep: Color(0xFFE7DCC2),
          ink: Color(0xFF1F1B17),
          line: Color(0xFF3A332B),
          mark: Color(0xFFC8442E),
          second: Color(0xFF3A5F86),
        ),
      _ => const _Stuff(
          paper: Color(0xFFF7F5F1),
          paperDeep: Color(0xFFE4E0D8),
          ink: Color(0xFF8C8A84),
          line: Color(0xFFC09A4E),
          mark: Color(0xFFB08A3E),
        ),
    };

/// Gold, polished: its light, body, shadow and glint.
const _goldLeaf = [Color(0xFFF6E3A6), Color(0xFFC9A04E), Color(0xFF7E5A1E), Color(0xFFE9CF86)];

// ---------------------------------------------------------------------------
// Backdrops.

/// [art] over [size] for a light scene: cut to fit, a breath of its paper
/// over the top (the screen's title) and the foot (the player), so dark
/// type and its panels read over it. No darkening, no vignette.
void _paintLightArt(Canvas canvas, Size size, ui.Image art, Scene scene) {
  final rect = Offset.zero & size;
  final paper = _stuffOf(scene).paper;
  final src = Size(art.width.toDouble(), art.height.toDouble());
  final fitted = applyBoxFit(BoxFit.cover, src, size);
  final from = Alignment.center.inscribe(fitted.source, Offset.zero & src);
  canvas.drawRect(rect, _fill(paper));
  canvas.drawImageRect(art, from, rect, Paint()..filterQuality = FilterQuality.medium);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
        paper.withValues(alpha: 0.5),
        paper.withValues(alpha: 0.12),
        paper.withValues(alpha: 0.16),
        paper.withValues(alpha: 0.55),
      ], const [
        0,
        0.22,
        0.7,
        1,
      ]),
  );
}

/// A light scene drawn by hand: marble always; the others while their
/// painting loads (their paper, plain).
void _paintLightBackdrop(Canvas canvas, Size size, Scene scene) {
  final s = _stuffOf(scene);
  final rect = Offset.zero & size;
  if (scene != Scene.marble) {
    canvas.drawRect(rect, Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [s.paper, s.paperDeep]));
    return;
  }
  _marble(canvas, rect, seed: 7, veins: 1);
}

/// White marble in [rect]: a soft cloud of greys, long veins of grey and a
/// few of gold. [veins] scales how many (a button has fewer).
void _marble(Canvas c, Rect rect, {required int seed, double veins = 1, bool gold = true}) {
  final r = math.Random(seed);
  c.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight,
          const [Color(0xFFFBFAF7), Color(0xFFF1EEE8), Color(0xFFF7F5F1), Color(0xFFE9E5DD)], const [0, 0.35, 0.7, 1]),
  );
  c.save();
  c.clipRect(rect);
  // Clouds: broad, faint, overlapping.
  for (var i = 0; i < (6 * veins).ceil(); i++) {
    final p = Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height);
    final rad = rect.longestSide * (0.15 + r.nextDouble() * 0.3);
    c.drawCircle(
      p,
      rad,
      Paint()
        ..shader = ui.Gradient.radial(p, rad,
            [const Color(0xFF9C978E).withValues(alpha: 0.07), const Color(0xFF9C978E).withValues(alpha: 0)]),
    );
  }
  // Veins: each a wandering line, a darker heart in a paler halo, forking.
  void vein(Offset a, double angle, double length, double width, Color color, int depth) {
    final path = Path()..moveTo(a.dx, a.dy);
    var p = a;
    var t = angle;
    const steps = 14;
    final forks = <(Offset, double)>[];
    for (var i = 0; i < steps; i++) {
      t += (r.nextDouble() - 0.5) * 0.7;
      final next = p + Offset(math.cos(t), math.sin(t)) * (length / steps);
      final mid = Offset((p.dx + next.dx) / 2 + (r.nextDouble() - 0.5) * 6, (p.dy + next.dy) / 2 + (r.nextDouble() - 0.5) * 6);
      path.quadraticBezierTo(mid.dx, mid.dy, next.dx, next.dy);
      if (depth > 0 && r.nextDouble() < 0.12) forks.add((next, t + (r.nextBool() ? 0.6 : -0.6)));
      p = next;
    }
    c.drawPath(path, _stroke(color.withValues(alpha: color.a * 0.25), width * 3.2)..strokeCap = StrokeCap.round);
    c.drawPath(path, _stroke(color, width)..strokeCap = StrokeCap.round);
    for (final (q, a2) in forks) {
      vein(q, a2, length * 0.4, width * 0.6, color, depth - 1);
    }
  }

  final n = (5 * veins).ceil();
  for (var i = 0; i < n; i++) {
    final start = Offset(rect.left - rect.width * 0.1, rect.top + r.nextDouble() * rect.height);
    vein(start, -0.5 + r.nextDouble() * 0.9, rect.width * (1.1 + r.nextDouble() * 0.6), 0.6 + r.nextDouble() * 1.1,
        const Color(0xFF8A857C).withValues(alpha: 0.32 + r.nextDouble() * 0.2), 2);
  }
  if (gold) {
    for (var i = 0; i < (2 * veins).ceil(); i++) {
      final start = Offset(rect.left + r.nextDouble() * rect.width * 0.3, rect.top + r.nextDouble() * rect.height);
      vein(start, -0.3 + r.nextDouble() * 0.6, rect.width * 0.9, 0.8 + r.nextDouble() * 0.6,
          const Color(0xFFC9A04E).withValues(alpha: 0.75), 1);
    }
  }
  c.restore();
}

// ---------------------------------------------------------------------------
// Panels and edges.

/// A soft shadow under [rr] without a blur: rings of falling alpha.
void _softShadow(Canvas c, RRect rr, {double depth = 6, double alpha = 0.10}) {
  for (var i = 4; i >= 1; i--) {
    final grow = i * depth / 4;
    c.drawRRect(rr.shift(Offset(0, grow * 0.6)).inflate(grow * 0.5), _fill(const Color(0xFF3A2E1E).withValues(alpha: alpha / (i + 1))));
  }
}

/// [rect] as a panel of the light [scene]: its paper (linen, watercolour
/// paper, washi, marble) and its edge, kept as a picture.
void _lightPanel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {required bool lit}) {
  if (rect.isEmpty) return;
  final key = 'lp:${scene.name}:${_sizeKey(rect)}:${corners.topLeft.x.round()}:${corners.bottomLeft.x.round()}:$lit';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) {
    _lightFace(c, r, scene, corners, lit: lit);
    _lightEdge(c, r, scene, corners, lit: lit);
  });
}

/// The face of a light panel.
void _lightFace(Canvas c, Rect rect, Scene scene, BorderRadius corners, {required bool lit}) {
  final s = _stuffOf(scene);
  final rr = corners.toRRect(rect);
  final r = math.Random((rect.width * 17 + rect.height).round());
  switch (scene) {
    case Scene.morris:
      c.drawRRect(rr, Paint()..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [const Color(0xF7FBF7EC), const Color(0xF5F3ECDC)]));
      c.save();
      c.clipRRect(rr);
      // The linen's weave: fine threads both ways.
      final thread = _stroke(const Color(0xFF8A7A5A).withValues(alpha: 0.05), 0.6)..strokeCap = StrokeCap.butt;
      for (var y = rect.top + 1.5; y < rect.bottom; y += 3) {
        c.drawLine(Offset(rect.left, y), Offset(rect.right, y), thread);
      }
      for (var x = rect.left + 1.5; x < rect.right; x += 3) {
        c.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), thread);
      }
      c.restore();
    case Scene.botanical:
      c.drawRRect(rr, _fill(const Color(0xF8FFFBF5)));
      c.save();
      c.clipRRect(rr);
      // The wash pooling toward the edges, faintly rose, as watercolour
      // dries darker where it stops.
      for (final (from, to) in [
        (rect.topCenter, rect.center),
        (rect.bottomCenter, rect.center),
        (rect.centerLeft, rect.center),
        (rect.centerRight, rect.center),
      ]) {
        final way = to - from;
        final reach = math.min(24.0, way.distance);
        if (reach < 1) continue;
        c.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(from, from + way / way.distance * reach,
                [s.paperDeep.withValues(alpha: 0.35), s.paperDeep.withValues(alpha: 0)]),
        );
      }
      // Paper grain.
      for (var i = 0; i < (rect.width * rect.height / 400).clamp(10, 200); i++) {
        c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height), 0.4 + r.nextDouble() * 0.5,
            _fill(const Color(0xFFB8A48A).withValues(alpha: 0.06)));
      }
      c.restore();
    case Scene.ukiyoe:
      c.drawRRect(rr, _fill(const Color(0xF6F8F2E4)));
      c.save();
      c.clipRRect(rr);
      // Washi: long pale fibres every way.
      for (var i = 0; i < (rect.width * rect.height / 900).clamp(6, 90); i++) {
        final a = Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height);
        final ang = r.nextDouble() * math.pi;
        final len = 8 + r.nextDouble() * 22;
        final b = a + Offset(math.cos(ang), math.sin(ang)) * len;
        final mid = Offset.lerp(a, b, 0.5)! + Offset((r.nextDouble() - 0.5) * 6, (r.nextDouble() - 0.5) * 6);
        c.drawPath(Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(mid.dx, mid.dy, b.dx, b.dy),
            _stroke(const Color(0xFFB59A6E).withValues(alpha: 0.12 + r.nextDouble() * 0.08), 0.5));
      }
      c.restore();
    case _:
      c.save();
      c.clipRRect(rr);
      _marble(c, rect, seed: (rect.width + rect.height * 3).round(), veins: (rect.width * rect.height / 90000).clamp(0.3, 1.2), gold: rect.height > 60);
      // Polished: a long soft reflection from the upper left.
      c.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight,
              [Colors.white.withValues(alpha: lit ? 0.32 : 0.22), Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0)], const [0, 0.45, 1]),
      );
      c.restore();
  }
}

/// The edge of something of the light [scene]'s at [rect]: a card, a
/// sheet, a dialog, a menu, the drawer, the player.
void _lightEdge(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (rect.width < 8 || rect.height < 8) return;
  final s = _stuffOf(scene);
  final rr = corners.toRRect(rect);
  final big = rect.shortestSide > 34;
  final inset = math.max(5.0, corners.topLeft.x * 0.5);
  switch (scene) {
    case Scene.morris:
      // A printed double rule in willow green, a sprig in two corners.
      c.drawRRect(rr.deflate(0.6), _stroke(s.ink.withValues(alpha: 0.55), 1.2));
      if (!big) return;
      c.drawRRect(rr.deflate(3.4), _stroke(s.line.withValues(alpha: 0.45), 0.6));
      final k = math.min(14.0, rect.shortestSide * 0.22);
      for (final (corner, sx, sy) in [
        (rect.topLeft + Offset(inset, inset), 1.0, 1.0),
        (rect.bottomRight + Offset(-inset, -inset), -1.0, -1.0),
      ]) {
        _willowSprig(c, corner, k, sx, sy, s);
      }
    case Scene.botanical:
      // A gold hairline inset, a rosebud with two leaves at the top corners.
      c.drawRRect(rr.deflate(0.5), _stroke(const Color(0xFFD9C3A8).withValues(alpha: 0.7), 0.8));
      if (!big) return;
      c.drawRRect(rr.deflate(4), _stroke(s.line.withValues(alpha: 0.8), 0.7));
      if (rect.width > 120) {
        for (final (p, side) in [(rect.topLeft + Offset(inset + 4, inset + 4), 1.0), (rect.topRight + Offset(-inset - 4, inset + 4), -1.0)]) {
          _rosebud(c, p, math.min(5.0, rect.shortestSide * 0.08), side, s);
        }
      }
    case Scene.ukiyoe:
      // A brush-ink border: heavier on two sides, as a brush lands; a red
      // seal in the lower corner of a big panel.
      _brushFrame(c, rr, s.ink.withValues(alpha: lit ? 0.85 : 0.75), seed: (rect.width * 7 + rect.height).round(), weight: big ? 1.0 : 0.6);
      if (big && rect.width > 140 && rect.height > 70) {
        final side = math.min(12.0, rect.shortestSide * 0.16);
        _seal(c, Rect.fromLTWH(rect.right - inset - side - 2, rect.bottom - inset - side - 2, side, side), s.mark, seed: rect.width.round());
      }
    case _:
      // Gold leaf: a polished rim with its bevel, an inner fine line.
      c.drawRRect(
        rr.deflate(0.9),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _goldLeaf, const [0, 0.4, 0.62, 1]),
      );
      if (big) {
        c.drawRRect(rr.deflate(4.2), _stroke(const Color(0xFFC9A04E).withValues(alpha: 0.5), 0.6));
        for (final p in [rect.topLeft + Offset(inset, inset), rect.topRight + Offset(-inset, inset), rect.bottomLeft + Offset(inset, -inset), rect.bottomRight + Offset(-inset, -inset)]) {
          _diamond(c, p, 2.6);
        }
      }
  }
}

void _willowSprig(Canvas c, Offset at, double k, double sx, double sy, _Stuff s) {
  final stem = Path()
    ..moveTo(at.dx, at.dy)
    ..quadraticBezierTo(at.dx + sx * k * 0.9, at.dy + sy * k * 0.1, at.dx + sx * k * 1.8, at.dy + sy * k * 0.7);
  c.drawPath(stem, _stroke(const Color(0xFF9A7A4A).withValues(alpha: 0.7), 0.8));
  final m = stem.computeMetrics().first;
  for (var i = 0; i < 4; i++) {
    final tg = m.getTangentForOffset(m.length * (0.2 + i * 0.22))!;
    final up = i.isEven ? -1.0 : 1.0;
    final dir = tg.vector;
    final normal = Offset(-dir.dy, dir.dx) * up;
    final tip = tg.position + (dir * 0.5 + normal) * k * 0.55;
    final leaf = Path()
      ..moveTo(tg.position.dx, tg.position.dy)
      ..quadraticBezierTo(tg.position.dx + normal.dx * k * 0.3 + dir.dx * k * 0.35, tg.position.dy + normal.dy * k * 0.3 + dir.dy * k * 0.35, tip.dx, tip.dy)
      ..quadraticBezierTo(tg.position.dx + dir.dx * k * 0.45, tg.position.dy + dir.dy * k * 0.45, tg.position.dx, tg.position.dy);
    c.drawPath(leaf, _fill(Color.lerp(s.line, s.ink, i / 4)!.withValues(alpha: 0.75)));
  }
}

void _rosebud(Canvas c, Offset p, double r, double side, _Stuff s) {
  for (final a in [-0.9, 0.9]) {
    final tip = p + Offset(math.cos(a + (side > 0 ? 0.6 : 2.5)), math.sin(a + 0.9)) * r * 2.2;
    c.drawPath(
      Path()
        ..moveTo(p.dx, p.dy)
        ..quadraticBezierTo((p.dx + tip.dx) / 2 + r * 0.6, (p.dy + tip.dy) / 2 - r * 0.4, tip.dx, tip.dy)
        ..quadraticBezierTo((p.dx + tip.dx) / 2 - r * 0.4, (p.dy + tip.dy) / 2 + r * 0.6, p.dx, p.dy),
      _fill(s.second!.withValues(alpha: 0.75)),
    );
  }
  c.drawCircle(p, r, Paint()..shader = ui.Gradient.radial(p - Offset(r * 0.3, r * 0.3), r * 1.2, [const Color(0xFFF4C3CC), s.mark, const Color(0xFF7E2A3C)], const [0, 0.6, 1]));
  c.drawArc(Rect.fromCircle(center: p, radius: r * 0.55), 0.4, 3.6, false, _stroke(const Color(0xFF7E2A3C).withValues(alpha: 0.6), 0.6));
}

/// A rectangle drawn with a brush: each side a tapering stroke that runs a
/// little past or short of the corner.
void _brushFrame(Canvas c, RRect rr, Color ink, {required int seed, double weight = 1}) {
  final r = math.Random(seed);
  final rect = rr.outerRect.deflate(1.2);
  final sides = [
    (rect.topLeft, rect.topRight, 1.6),
    (rect.topRight, rect.bottomRight, 1.0),
    (rect.bottomRight, rect.bottomLeft, 1.8),
    (rect.bottomLeft, rect.topLeft, 1.1),
  ];
  for (final (a, b, w) in sides) {
    final along = b - a;
    final len = along.distance;
    if (len < 4) continue;
    final dir = along / len;
    final normal = Offset(-dir.dy, dir.dx);
    final start = a - dir * (r.nextDouble() * 2);
    final end = b + dir * (r.nextDouble() * 3 - 1);
    final thick = w * weight * 1.4;
    // A thin-thick-thin ribbon: the brush pressed in the middle.
    final mid = Offset.lerp(start, end, 0.45)! + normal * ((r.nextDouble() - 0.5) * 1.2);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(mid.dx + normal.dx * thick, mid.dy + normal.dy * thick, end.dx, end.dy)
      ..quadraticBezierTo(mid.dx - normal.dx * thick, mid.dy - normal.dy * thick, start.dx, start.dy)
      ..close();
    c.drawPath(path, _fill(ink));
  }
}

/// A seal stamped in [color] in [rect]: a square of it, its edge rough, a
/// character's strokes left in the paper.
void _seal(Canvas c, Rect rect, Color color, {required int seed}) {
  final r = math.Random(seed);
  final path = _roughRect(rect, r, wobble: rect.shortestSide * 0.05);
  c.drawPath(path, _fill(color.withValues(alpha: 0.9)));
  final k = rect.width;
  final paper = _fill(const Color(0xFFF5EEDD).withValues(alpha: 0.9));
  // Two strokes of a character, cut in the stone.
  c.drawRect(Rect.fromLTWH(rect.left + k * 0.22, rect.top + k * 0.24, k * 0.56, k * 0.1), paper);
  c.drawRect(Rect.fromLTWH(rect.left + k * 0.45, rect.top + k * 0.24, k * 0.1, k * 0.54), paper);
  c.drawRect(Rect.fromLTWH(rect.left + k * 0.25, rect.top + k * 0.62, k * 0.5, k * 0.09), paper);
}

Path _roughRect(Rect rect, math.Random r, {required double wobble}) {
  final path = Path();
  final pts = <Offset>[];
  const per = 5;
  for (final (a, b) in [(rect.topLeft, rect.topRight), (rect.topRight, rect.bottomRight), (rect.bottomRight, rect.bottomLeft), (rect.bottomLeft, rect.topLeft)]) {
    for (var i = 0; i < per; i++) {
      final p = Offset.lerp(a, b, i / per)!;
      pts.add(p + Offset((r.nextDouble() - 0.5) * wobble * 2, (r.nextDouble() - 0.5) * wobble * 2));
    }
  }
  path.moveTo(pts.first.dx, pts.first.dy);
  for (final p in pts.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

void _diamond(Canvas c, Offset p, double r) {
  final path = Path()
    ..moveTo(p.dx, p.dy - r)
    ..lineTo(p.dx + r, p.dy)
    ..lineTo(p.dx, p.dy + r)
    ..lineTo(p.dx - r, p.dy)
    ..close();
  c.drawPath(path, Paint()..shader = ui.Gradient.linear(p - Offset(r, r), p + Offset(r, r), _goldLeaf, const [0, 0.4, 0.7, 1]));
}

// ---------------------------------------------------------------------------
// Buttons.

/// [rect] as a button of the light [scene] in [fill], kept as a picture.
void _lightButton(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  if (rect.isEmpty) return;
  final key = 'lb:${scene.name}:${_sizeKey(rect)}:${fill.toARGB32()}:${radius.topLeft.x.round()}';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) => _lightButtonFace(c, r, scene, fill, radius));
}

void _lightButtonFace(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  final s = _stuffOf(scene);
  final rr = radius.toRRect(rect);
  // A chosen or filled button is the scene's colour; a quiet one its paper.
  final strong = fill.computeLuminance() < 0.6;
  final r = math.Random((rect.width * 11 + rect.height).round());
  switch (scene) {
    case Scene.morris:
      // Block-printed linen: the colour pressed in flat, the weave showing
      // through, a darker printed edge.
      c.drawRRect(rr, _fill(strong ? fill : Color.lerp(const Color(0xFFFBF6EA), fill, 0.5)!));
      c.save();
      c.clipRRect(rr);
      final thread = _stroke((strong ? Colors.white : const Color(0xFF8A7A5A)).withValues(alpha: strong ? 0.07 : 0.06), 0.6)
        ..strokeCap = StrokeCap.butt;
      for (var y = rect.top + 1.5; y < rect.bottom; y += 2.6) {
        c.drawLine(Offset(rect.left, y), Offset(rect.right, y), thread);
      }
      for (var x = rect.left + 1.5; x < rect.right; x += 2.6) {
        c.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), thread);
      }
      // Where the block missed a little.
      for (var i = 0; i < (rect.width * rect.height / 120).clamp(3, 30); i++) {
        c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height), 0.4 + r.nextDouble() * 0.6,
            _fill(Colors.white.withValues(alpha: strong ? 0.08 : 0.0)));
      }
      c.restore();
      c.drawRRect(rr.deflate(0.6), _stroke(strong ? Color.lerp(fill, Colors.black, 0.35)! : s.ink.withValues(alpha: 0.6), 1.2));
      if (rect.shortestSide > 22) c.drawRRect(rr.deflate(3), _stroke((strong ? Colors.white : s.line).withValues(alpha: strong ? 0.28 : 0.4), 0.6));
    case Scene.botanical:
      // A watercolour wash: paler in its middle, pooled darker at its rim,
      // the gold hairline round it.
      final body = strong ? fill : Color.lerp(const Color(0xFFF7E6E6), fill, 0.5)!;
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.radial(rect.center, rect.longestSide * 0.62,
              [Color.lerp(body, Colors.white, strong ? 0.18 : 0.5)!, body, Color.lerp(body, Colors.black, strong ? 0.16 : 0.06)!], const [0, 0.7, 1]),
      );
      c.save();
      c.clipRRect(rr);
      for (var i = 0; i < 3; i++) {
        final p = Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height);
        c.drawCircle(p, rect.shortestSide * (0.3 + r.nextDouble() * 0.4),
            Paint()..shader = ui.Gradient.radial(p, rect.shortestSide * 0.6, [Colors.white.withValues(alpha: 0.12), Colors.white.withValues(alpha: 0)]));
      }
      c.restore();
      c.drawRRect(rr.deflate(0.6), _stroke(s.line.withValues(alpha: 0.95), 1.1));
    case Scene.ukiyoe:
      if (strong) {
        // A seal stamped in vermilion: its edge rough, specks where the ink
        // did not take.
        final path = _roughRect(rect.deflate(0.5), r, wobble: math.min(1.2, rect.shortestSide * 0.04));
        c.drawPath(path, _fill(fill));
        c.save();
        c.clipPath(path);
        for (var i = 0; i < (rect.width * rect.height / 70).clamp(4, 50); i++) {
          c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height), 0.3 + r.nextDouble() * 0.7,
              _fill(const Color(0xFFF5EEDD).withValues(alpha: 0.18 + r.nextDouble() * 0.18)));
        }
        c.restore();
      } else {
        c.drawRRect(rr, _fill(Color.lerp(const Color(0xFFF8F2E4), fill, 0.5)!));
        _brushFrame(c, rr, s.ink.withValues(alpha: 0.8), seed: (rect.width * 5).round(), weight: 0.55);
      }
    case _:
      if (strong) {
        // Polished gold: bright bands and dark, a glint across its top.
        _softShadow(c, rr, depth: 3, alpha: 0.12);
        c.drawRRect(
          rr,
          Paint()
            ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
              Color.lerp(fill, Colors.white, 0.55)!,
              Color.lerp(fill, Colors.white, 0.1)!,
              Color.lerp(fill, Colors.black, 0.28)!,
              Color.lerp(fill, Colors.white, 0.25)!,
            ], const [
              0,
              0.42,
              0.8,
              1,
            ]),
        );
        c.save();
        c.clipRRect(rr);
        final sheen = Rect.fromLTRB(rect.left + rect.width * 0.1, rect.top + 1, rect.right - rect.width * 0.1, rect.top + rect.height * 0.45);
        c.drawOval(sheen, Paint()..shader = ui.Gradient.linear(sheen.topCenter, sheen.bottomCenter, [Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0)]));
        c.restore();
        c.drawRRect(rr.deflate(0.6), _stroke(const Color(0xFF6E4E16).withValues(alpha: 0.6), 0.9));
      } else {
        c.save();
        c.clipRRect(rr);
        _marble(c, rect, seed: (rect.width * 3).round(), veins: 0.3, gold: false);
        // A chosen row's tint washed over the stone.
        c.drawRect(rect, _fill(fill.withValues(alpha: 0.35)));
        c.restore();
        c.drawRRect(
          rr.deflate(0.7),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _goldLeaf, const [0, 0.4, 0.62, 1]),
        );
      }
  }
}

// ---------------------------------------------------------------------------
// The slider's knob, a cover's frame, a divider.

void _lightKnob(Canvas c, Offset center, double r, Scene scene, Color colour) {
  final s = _stuffOf(scene);
  final disc = Rect.fromCircle(center: center, radius: r);
  _softShadow(c, RRect.fromRectAndRadius(disc, Radius.circular(r)), depth: 3, alpha: 0.16);
  switch (scene) {
    case Scene.morris:
      c.drawCircle(center, r, _fill(colour));
      c.drawCircle(center, r - 0.8, _stroke(Color.lerp(colour, Colors.black, 0.35)!, 1.4));
      c.drawCircle(center, r * 0.55, _stroke(const Color(0xFFF6F0E2).withValues(alpha: 0.8), 1));
      c.drawCircle(center, r * 0.18, _fill(const Color(0xFFF6F0E2)));
    case Scene.botanical:
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center - Offset(r * 0.3, r * 0.3), r * 1.3, [const Color(0xFFF7D0D7), colour, Color.lerp(colour, Colors.black, 0.3)!], const [0, 0.6, 1]));
      // A rose's swirl of petals.
      c.drawArc(Rect.fromCircle(center: center, radius: r * 0.6), 0.2, 4.2, false, _stroke(Colors.white.withValues(alpha: 0.6), 1));
      c.drawArc(Rect.fromCircle(center: center, radius: r * 0.32), 2.2, 3.8, false, _stroke(Colors.white.withValues(alpha: 0.6), 0.9));
      c.drawCircle(center, r - 0.5, _stroke(s.line, 1.1));
    case Scene.ukiyoe:
      // A rising sun: a vermilion disc on a white one, in ink.
      c.drawCircle(center, r, _fill(const Color(0xFFFAF6EC)));
      c.drawCircle(center, r * 0.62, _fill(colour));
      c.drawCircle(center, r - 0.7, _stroke(s.ink, 1.4));
    case _:
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.linear(disc.topLeft, disc.bottomRight, _goldLeaf, const [0, 0.4, 0.7, 1]));
      c.drawCircle(center, r * 0.62, Paint()..shader = ui.Gradient.linear(disc.bottomRight, disc.topLeft, _goldLeaf, const [0, 0.4, 0.7, 1]));
      c.drawCircle(center, r - 0.5, _stroke(const Color(0xFF6E4E16).withValues(alpha: 0.6), 0.8));
  }
}

void _lightCoverFrame(Canvas c, Rect rect, Scene scene, double radius) {
  final s = _stuffOf(scene);
  final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
  switch (scene) {
    case Scene.morris:
      c.drawRRect(rr.deflate(0.8), _stroke(const Color(0xFFF6F0E2), 1.6));
      c.drawRRect(rr.deflate(0.8), _stroke(s.ink.withValues(alpha: 0.65), 0.8));
    case Scene.botanical:
      c.drawRRect(rr.deflate(0.7), _stroke(s.line, 1.4));
      c.drawRRect(rr.deflate(2.6), _stroke(Colors.white.withValues(alpha: 0.55), 0.7));
    case Scene.ukiyoe:
      _brushFrame(c, rr, s.ink.withValues(alpha: 0.85), seed: rect.width.round(), weight: 0.7);
    case _:
      c.drawRRect(
        rr.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _goldLeaf, const [0, 0.4, 0.62, 1]),
      );
  }
}

void _lightDivider(Canvas c, Size s, Scene scene) {
  final st = _stuffOf(scene);
  final y = s.height / 2;
  final m = Offset(s.width / 2, y);
  switch (scene) {
    case Scene.morris:
      c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(st.line.withValues(alpha: 0.55), 0.8));
      _willowSprig(c, m - const Offset(10, 4), 9, 1, 1, st);
    case Scene.botanical:
      c.drawLine(Offset(0, y), Offset(s.width, y),
          Paint()
            ..strokeWidth = 0.8
            ..shader = ui.Gradient.linear(Offset(0, y), Offset(s.width, y), [st.line.withValues(alpha: 0), st.line, st.line.withValues(alpha: 0)], const [0, 0.5, 1]));
      _rosebud(c, m, 3.6, 1, st);
    case Scene.ukiyoe:
      final path = Path()
        ..moveTo(s.width * 0.1, y + 0.5)
        ..quadraticBezierTo(s.width * 0.5, y - 2.2, s.width * 0.9, y)
        ..quadraticBezierTo(s.width * 0.5, y + 1.2, s.width * 0.1, y + 0.5);
      c.drawPath(path, _fill(st.ink.withValues(alpha: 0.7)));
    case _:
      c.drawLine(Offset(0, y), Offset(s.width, y),
          Paint()
            ..strokeWidth = 1
            ..shader = ui.Gradient.linear(Offset(0, y), Offset(s.width, y), [_goldLeaf[1].withValues(alpha: 0), _goldLeaf[1], _goldLeaf[1].withValues(alpha: 0)], const [0, 0.5, 1]));
      _diamond(c, m, 4);
  }
}

/// An empty screen's picture for marble (the painted scenes show a cameo
/// of their painting): a gold medallion.
void _lightEmpty(Canvas c, Size s, Scene scene) {
  final m = Offset(s.width / 2, s.height / 2);
  final r = s.shortestSide * 0.32;
  final rect = Rect.fromCircle(center: m, radius: r);
  c.save();
  c.clipPath(Path()..addOval(rect));
  _marble(c, rect, seed: 3, veins: 0.4, gold: false);
  c.restore();
  c.drawCircle(m, r, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _goldLeaf, const [0, 0.4, 0.62, 1]));
  _diamond(c, m, r * 0.32);
}

/// A screen's ornament in a light scene: at its head the scene's sign (a
/// willow sprig, a rosebud, a seal, a gold diamond), at its foot a rule.
void _lightOrnament(Canvas c, Size s, Scene scene, {required bool foot}) {
  if (foot) {
    _lightDivider(c, s, scene);
    return;
  }
  final st = _stuffOf(scene);
  final m = Offset(s.width / 2, s.height / 2);
  final k = s.shortestSide;
  switch (scene) {
    case Scene.morris:
      _willowSprig(c, m + Offset(-k * 0.42, k * 0.1), k * 0.42, 1, -1, st);
      _willowSprig(c, m + Offset(k * 0.42, k * 0.1), k * 0.42, -1, -1, st);
    case Scene.botanical:
      _rosebud(c, m, k * 0.16, 1, st);
    case Scene.ukiyoe:
      _seal(c, Rect.fromCenter(center: m, width: k * 0.5, height: k * 0.5), st.mark, seed: 4);
    case _:
      _diamond(c, m, k * 0.22);
  }
}

// ---------------------------------------------------------------------------
// What moves: little, slowly, cheaply (about 30 frames a second, a few
// shapes each).

void _lightLife(Canvas c, Size s, double t, Scene scene) {
  switch (scene) {
    case Scene.morris:
      // Willow leaves drifting down and across.
      final st = _stuffOf(scene);
      for (var i = 0; i < 6; i++) {
        final speed = 0.018 + (i % 3) * 0.006;
        final phase = (t * speed + i * 0.17) % 1;
        final x = s.width * ((i * 0.23 + phase * 0.35) % 1);
        final y = s.height * phase;
        final a = t * 0.5 + i;
        c.save();
        c.translate(x + math.sin(t * 0.7 + i) * 14, y);
        c.rotate(a);
        c.drawPath(
          Path()
            ..moveTo(-7, 0)
            ..quadraticBezierTo(0, -3.2, 7, 0)
            ..quadraticBezierTo(0, 3.2, -7, 0),
          _fill(Color.lerp(st.line, st.ink, (i % 3) / 3)!.withValues(alpha: 0.35)),
        );
        c.restore();
      }
    case Scene.botanical:
      // Rose petals falling, turning.
      for (var i = 0; i < 7; i++) {
        final speed = 0.022 + (i % 4) * 0.005;
        final phase = (t * speed + i * 0.143) % 1;
        final x = s.width * ((i * 0.31) % 1) + math.sin(t * 0.6 + i * 1.7) * 22;
        final y = s.height * phase;
        c.save();
        c.translate(x, y);
        c.rotate(t * 0.4 + i);
        c.scale(1, 0.55 + 0.45 * math.cos(t * 0.9 + i).abs());
        c.drawOval(Rect.fromCenter(center: Offset.zero, width: 10, height: 8),
            _fill(const Color(0xFFE59AAA).withValues(alpha: 0.42)));
        c.restore();
      }
    case Scene.ukiyoe:
      // Bands of cloud drifting, as on a print, and a pair of birds.
      for (var i = 0; i < 4; i++) {
        final y = s.height * (0.08 + i * 0.09);
        final w = s.width * (0.35 + (i % 2) * 0.2);
        final x = ((t * (6 + i * 2) + i * 140) % (s.width + w)) - w;
        final band = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, 5), const Radius.circular(2.5));
        c.drawRRect(band, _fill(Colors.white.withValues(alpha: 0.45)));
      }
      final bx = (t * 14) % (s.width + 60) - 30;
      for (final dx in [0.0, 18.0]) {
        final p = Offset(bx + dx, s.height * 0.2 + dx * 0.4 + math.sin(t * 2 + dx) * 3);
        final flap = math.sin(t * 6 + dx) * 2.5;
        c.drawPath(
          Path()
            ..moveTo(p.dx - 6, p.dy - flap)
            ..quadraticBezierTo(p.dx - 2, p.dy - 2, p.dx, p.dy)
            ..quadraticBezierTo(p.dx + 2, p.dy - 2, p.dx + 6, p.dy - flap),
          _stroke(const Color(0xFF1F1B17).withValues(alpha: 0.55), 1.2),
        );
      }
    case _:
      // A glint of light passing over the polished stone now and then.
      final cycle = (t % 9) / 9;
      if (cycle > 0.35) return;
      final f = cycle / 0.35;
      final x = -s.width * 0.4 + f * s.width * 1.8;
      c.save();
      c.translate(x, 0);
      c.skew(-0.35, 0);
      c.drawRect(
        Rect.fromLTWH(0, 0, s.width * 0.18, s.height),
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(s.width * 0.18, 0),
              [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)], const [0, 0.5, 1]),
      );
      c.restore();
  }
}
