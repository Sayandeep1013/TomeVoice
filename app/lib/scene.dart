import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Scene themes: a place, not a colour. Each draws its own backdrop behind
/// every screen (stone and torches, a forest, a starship's hull), frames the
/// covers in its material, and lays the player, the settings and the cards on
/// panels of it. The page that is read stays plain; text never sits on the
/// art itself, only on the dark of it or on a panel.
///
/// All of it is drawn by hand in code (no pictures, no package): a backdrop
/// is drawn once at the screen's size into an image and that image is what
/// every frame shows, so a list scrolls over it as over a plain colour.
enum Scene {
  dungeon('Dungeon', 'Torchlit stone, rust and bones'),
  forest('Enchanted forest', 'Vines, moss and fireflies'),
  starship('Starship', 'Hull plates and neon');

  const Scene(this.label, this.note);

  final String label;

  /// What it is made of, under its preview.
  final String note;

  /// Its corners: worn stone and wood are rounded, a starship's are sharp.
  double get radius => switch (this) {
        Scene.dungeon => 12,
        Scene.forest => 16,
        Scene.starship => 2,
      };

  /// How far a starship's panels and buttons are cut at two corners.
  static const cut = 10.0;

  /// A panel's corners: never rounder than the scene's own, so a pill-round
  /// bar becomes worn stone, not a pill.
  BorderRadius corners(BorderRadius? asked) {
    if (this == Scene.starship) return BorderRadius.circular(radius);
    if (asked == null) return BorderRadius.circular(radius);
    final r = math.min(asked.topLeft.x, radius + 6);
    return BorderRadius.circular(r);
  }
}

// ---------------------------------------------------------------------------
// The backdrop, drawn once per screen size.

/// Backdrops drawn so far, the newest last; a few are kept.
final _drawn = <String, ui.Image>{};

/// Whether backdrops are drawn into a kept image (off only where a test
/// runs without a GPU and asks for it).
@visibleForTesting
bool sceneImages = true;

/// The size a backdrop is drawn at for a box of [box]: the whole screen's
/// at least, so a body shrunk by the keyboard, or a sheet, shows part of
/// the same picture rather than having a new one drawn on every frame.
Size _canvasFor(Size box) {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final screen = view == null ? Size.zero : view.physicalSize / view.devicePixelRatio;
  return Size(math.max(box.width, screen.width), math.max(box.height, screen.height));
}

/// [scene]'s backdrop at [size] (logical) for a screen of [dpr], drawn once.
ui.Image? sceneBackdrop(Scene scene, Size size, double dpr) {
  final w = (size.width * dpr).round();
  final h = (size.height * dpr).round();
  if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return null;
  final key = '${scene.name}:$w:$h';
  final hit = _drawn.remove(key);
  if (hit != null) return _drawn[key] = hit;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(dpr);
  paintBackdrop(canvas, size, scene);
  final picture = recorder.endRecording();
  try {
    final image = picture.toImageSync(w, h);
    _drawn[key] = image;
    while (_drawn.length > 6) {
      _drawn.remove(_drawn.keys.first)!.dispose();
    }
    return image;
  } on Object {
    return null;
  } finally {
    picture.dispose();
  }
}

/// The ground of a screen in a scene: its backdrop, or [base] while there
/// is none to show.
class SceneGround extends Decoration {
  const SceneGround(this.scene, this.base);

  final Scene scene;
  final Gradient base;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _SceneGroundPainter(this);

  @override
  bool operator ==(Object other) => other is SceneGround && other.scene == scene && other.base == base;

  @override
  int get hashCode => Object.hash(scene, base);
}

class _SceneGroundPainter extends BoxPainter {
  _SceneGroundPainter(this.d);

  final SceneGround d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final dpr = configuration.devicePixelRatio ?? 1;
    final image = sceneImages ? sceneBackdrop(d.scene, _canvasFor(size), dpr) : null;
    if (image == null) {
      canvas.save();
      canvas.clipRect(rect);
      canvas.translate(offset.dx, offset.dy);
      paintBackdrop(canvas, size, d.scene);
      canvas.restore();
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
      rect,
      Paint()..filterQuality = FilterQuality.low,
    );
  }
}

/// [scene]'s backdrop on [canvas], at [size].
void paintBackdrop(Canvas canvas, Size size, Scene scene) => switch (scene) {
      Scene.dungeon => _Dungeon(canvas, size).paint(),
      Scene.forest => _Forest(canvas, size).paint(),
      Scene.starship => _Starship(canvas, size).paint(),
    };

// ---------------------------------------------------------------------------
// Shared strokes.

Paint _fill(Color c) => Paint()..color = c;

Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Paint _glow(Color c, double blur) => Paint()
  ..color = c
  ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);

/// A soft round light (or shadow) at [c], [r] across.
void _light(Canvas canvas, Offset c, double r, Color color, {double mid = 0.35}) => canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = ui.Gradient.radial(c, r, [color, color.withValues(alpha: color.a * 0.4), color.withValues(alpha: 0)],
            [0, mid, 1]),
    );

/// Grain over everything: fine dark and light specks, as on stone or film.
void _grain(Canvas canvas, Size size, math.Random r, {double dark = 0.22, double light = 0.05, int per = 16}) {
  final n = (size.width * size.height / per).round().clamp(0, 60000);
  Float32List points(int count) {
    final p = Float32List(count * 2);
    for (var i = 0; i < count; i++) {
      p[i * 2] = r.nextDouble() * size.width;
      p[i * 2 + 1] = r.nextDouble() * size.height;
    }
    return p;
  }

  canvas.drawRawPoints(ui.PointMode.points, points(n),
      Paint()
        ..color = Colors.black.withValues(alpha: dark)
        ..strokeWidth = 1.1);
  canvas.drawRawPoints(ui.PointMode.points, points(n ~/ 3),
      Paint()
        ..color = Colors.white.withValues(alpha: light)
        ..strokeWidth = 0.9);
}

/// The edges sunk into shadow, the middle left as it is.
void _vignette(Canvas canvas, Size size, {double edge = 0.82, Offset? centre}) {
  final rect = Offset.zero & size;
  final c = centre ?? Offset(size.width / 2, size.height * 0.45);
  final radius = math.sqrt(size.width * size.width + size.height * size.height) * 0.62;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.radial(c, radius, [
        Colors.black.withValues(alpha: 0),
        Colors.black.withValues(alpha: edge * 0.55),
        Colors.black.withValues(alpha: edge),
      ], [
        0.45,
        0.8,
        1,
      ]),
  );
}

/// A wobbling line from [a] to [b] in [steps], for cracks and scratches.
Path _jagged(math.Random r, Offset a, Offset b, {int steps = 7, double wobble = 4}) {
  final path = Path()..moveTo(a.dx, a.dy);
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final p = Offset.lerp(a, b, t)!;
    final j = i == steps ? Offset.zero : Offset((r.nextDouble() - 0.5) * wobble * 2, (r.nextDouble() - 0.5) * wobble * 2);
    path.lineTo(p.dx + j.dx, p.dy + j.dy);
  }
  return path;
}

// ---------------------------------------------------------------------------
// Dungeon.

const _mortar = Color(0xFF080504);

class _Dungeon {
  _Dungeon(this.c, this.s);

  final Canvas c;
  final Size s;
  final r = math.Random(7);

  double get w => s.width;
  double get h => s.height;

  /// Where the two torches burn.
  Offset get _leftTorch => Offset(16, h * 0.2);
  Offset get _rightTorch => Offset(w - 16, h * 0.46);

  void paint() {
    c.drawRect(Offset.zero & s, _fill(_mortar));
    _bricks();
    _cracks();
    _damp();
    // Soot above each torch, then the dark of a room lit only by them.
    for (final t in [_leftTorch, _rightTorch]) {
      c.save();
      c.translate(t.dx, t.dy - 70);
      c.scale(0.7, 1.6);
      _light(c, Offset.zero, 60, Colors.black.withValues(alpha: 0.75), mid: 0.5);
      c.restore();
    }
    _vignette(c, s, edge: 0.88, centre: Offset(w / 2, h * 0.42));
    for (final t in [_leftTorch, _rightTorch]) {
      _light(c, t + const Offset(0, -10), 190, const Color(0xFFFF7A1A).withValues(alpha: 0.20), mid: 0.25);
      _light(c, t + const Offset(0, -14), 70, const Color(0xFFFFB347).withValues(alpha: 0.16));
    }
    _cobweb(Offset.zero, 120, 1);
    _cobweb(Offset(w, 0), 84, -1);
    _chain(Offset(w - 24, h * 0.58), h * 0.16);
    _tally(Offset(w - 54, h * 0.73));
    _rubble();
    _bones(Offset(64, h - 30));
    skullAt(c, Offset(34, h - 44), 46, cracked: true);
    _rat(Offset(w - 70, h - 22));
    _torch(_leftTorch);
    _torch(_rightTorch);
    _grain(c, s, r, dark: 0.26, light: 0.045, per: 14);
  }

  void _bricks() {
    var y = -6.0;
    var row = 0;
    while (y < h) {
      final rh = 30 + r.nextDouble() * 9;
      var x = -r.nextDouble() * 70 - (row.isOdd ? 30 : 0);
      while (x < w) {
        final bw = 52 + r.nextDouble() * 48;
        _brick(Rect.fromLTWH(x, y, bw, rh));
        x += bw;
      }
      y += rh;
      row++;
    }
  }

  void _brick(Rect cell) {
    final gap = 2.6 + r.nextDouble() * 1.8;
    final rect = cell.deflate(gap / 2).translate((r.nextDouble() - 0.5) * 1.4, (r.nextDouble() - 0.5) * 1.4);
    if (r.nextDouble() < 0.03) {
      // A brick gone: a black hole in the wall.
      final hole = RRect.fromRectAndRadius(rect.deflate(2), const Radius.circular(3));
      c.drawRRect(hole, _fill(const Color(0xFF030202)));
      c.drawRRect(hole.deflate(1), _stroke(Colors.white.withValues(alpha: 0.035), 1));
      return;
    }
    const tones = [Color(0xFF2E2620), Color(0xFF362C24), Color(0xFF2A2420), Color(0xFF3A2C24), Color(0xFF302A26)];
    final base = Color.lerp(tones[r.nextInt(tones.length)], const Color(0xFF15100C), r.nextDouble() * 0.45)!;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(2 + r.nextDouble() * 4));
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          Color.lerp(base, Colors.white, 0.06)!,
          base,
          Color.lerp(base, Colors.black, 0.35)!,
        ], [
          0,
          0.45,
          1,
        ]),
    );
    // Its lit top edge and its shadowed foot.
    c.drawLine(rect.topLeft + const Offset(3, 1), rect.topRight + const Offset(-3, 1),
        _stroke(Colors.white.withValues(alpha: 0.05), 1));
    c.drawLine(rect.bottomLeft + const Offset(2, -0.5), rect.bottomRight + const Offset(-2, -0.5),
        _stroke(Colors.black.withValues(alpha: 0.5), 1.2));
    // Pits.
    for (var i = 0; i < 3; i++) {
      c.drawCircle(
        Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
        0.6 + r.nextDouble() * 1.3,
        _fill(Colors.black.withValues(alpha: 0.35)),
      );
    }
    // A chipped corner.
    if (r.nextDouble() < 0.32) {
      final k = 4 + r.nextDouble() * 9;
      final corner = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft][r.nextInt(4)];
      final sx = corner.dx == rect.left ? 1.0 : -1.0;
      final sy = corner.dy == rect.top ? 1.0 : -1.0;
      final bite = Path()
        ..moveTo(corner.dx - sx, corner.dy - sy)
        ..lineTo(corner.dx + sx * k, corner.dy - sy)
        ..lineTo(corner.dx + sx * k * 0.45, corner.dy + sy * k * 0.35)
        ..lineTo(corner.dx + sx * k * 0.2, corner.dy + sy * k * 0.8)
        ..lineTo(corner.dx - sx, corner.dy + sy * k)
        ..close();
      c.drawPath(bite, _fill(_mortar));
    }
    // A crack across it.
    if (r.nextDouble() < 0.14) {
      final a = Offset(rect.left + r.nextDouble() * rect.width, rect.top);
      final b = Offset(rect.left + r.nextDouble() * rect.width, rect.bottom);
      final crack = _jagged(r, a, b, steps: 5, wobble: 3);
      c.drawPath(crack.shift(const Offset(0.8, 0.8)), _stroke(Colors.white.withValues(alpha: 0.05), 1));
      c.drawPath(crack, _stroke(Colors.black.withValues(alpha: 0.8), 1.1));
    }
  }

  void _cracks() {
    for (var i = 0; i < 3; i++) {
      final a = Offset(r.nextDouble() * w, r.nextDouble() * h * 0.8);
      final b = a + Offset((r.nextDouble() - 0.5) * 160, 120 + r.nextDouble() * 160);
      final crack = _jagged(r, a, b, steps: 12, wobble: 7);
      c.drawPath(crack, _stroke(Colors.black.withValues(alpha: 0.85), 1.7));
      // A branch.
      final m = Offset.lerp(a, b, 0.5)!;
      c.drawPath(_jagged(r, m, m + Offset((r.nextDouble() - 0.5) * 80, 40 + r.nextDouble() * 40), steps: 5, wobble: 5),
          _stroke(Colors.black.withValues(alpha: 0.7), 1));
    }
  }

  void _damp() {
    for (var i = 0; i < 6; i++) {
      final x = r.nextDouble() * w;
      final top = r.nextDouble() * h * 0.5;
      final len = 140 + r.nextDouble() * 260;
      final width = 8 + r.nextDouble() * 20;
      final rect = Rect.fromLTWH(x, top, width, len);
      c.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(width / 2)),
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.32),
            const Color(0xFF14180C).withValues(alpha: 0.3),
            Colors.black.withValues(alpha: 0),
          ], [
            0,
            0.3,
            0.8,
            1,
          ]),
      );
      // A drip at its foot.
      c.drawOval(Rect.fromCenter(center: Offset(x + width / 2, top + len * 0.85), width: 3, height: 5),
          _fill(Colors.white.withValues(alpha: 0.07)));
    }
    // Moss in the joints, low on the wall.
    for (var i = 0; i < 70; i++) {
      final p = Offset(r.nextDouble() * w, h * (0.62 + r.nextDouble() * 0.38));
      c.drawOval(Rect.fromCenter(center: p, width: 3 + r.nextDouble() * 9, height: 1.6 + r.nextDouble() * 3),
          _fill(Color.lerp(const Color(0xFF2B3A1A), const Color(0xFF1C2410), r.nextDouble())!.withValues(alpha: 0.7)));
    }
  }

  void _cobweb(Offset corner, double size, double dir) {
    final web = _stroke(Colors.white.withValues(alpha: 0.15), 0.8);
    const strands = 7;
    final ends = <Offset>[];
    for (var i = 0; i < strands; i++) {
      final a = (i / (strands - 1)) * math.pi / 2;
      final end = corner + Offset(math.cos(a) * size * dir, math.sin(a) * size);
      ends.add(end);
      c.drawLine(corner, end, web);
    }
    for (var ring = 1; ring <= 6; ring++) {
      final t = ring / 6.5;
      final path = Path();
      for (var i = 0; i < strands; i++) {
        final p = Offset.lerp(corner, ends[i], t)!;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          final prev = Offset.lerp(corner, ends[i - 1], t)!;
          final sag = Offset.lerp(prev, p, 0.5)! + (Offset.lerp(prev, p, 0.5)! - corner) * -0.08;
          path.quadraticBezierTo(sag.dx, sag.dy, p.dx, p.dy);
        }
      }
      c.drawPath(path, web);
    }
    // A torn strand hanging loose.
    c.drawPath(
      Path()
        ..moveTo(ends[3].dx * 0.7 + corner.dx * 0.3, ends[3].dy * 0.7 + corner.dy * 0.3)
        ..quadraticBezierTo(corner.dx + size * 0.5 * dir, corner.dy + size * 1.1, corner.dx + size * 0.45 * dir,
            corner.dy + size * 1.35),
      _stroke(Colors.white.withValues(alpha: 0.1), 0.7),
    );
  }

  void _chain(Offset top, double length) {
    final link = Paint()
      ..shader = ui.Gradient.linear(top - const Offset(5, 0), top + const Offset(5, 0),
          const [Color(0xFF1E100A), Color(0xFF8A4A24), Color(0xFF1E100A)], const [0, 0.5, 1])
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6;
    var y = top.dy;
    var i = 0;
    while (y < top.dy + length) {
      final rect = i.isEven
          ? Rect.fromCenter(center: Offset(top.dx, y), width: 9, height: 15)
          : Rect.fromCenter(center: Offset(top.dx, y), width: 3, height: 15);
      c.drawOval(rect, link);
      y += 11;
      i++;
    }
    // The shackle at its end, open.
    final s = Offset(top.dx, y + 4);
    c.drawPath(
      Path()
        ..moveTo(s.dx - 11, s.dy)
        ..lineTo(s.dx - 11, s.dy + 16)
        ..arcToPoint(Offset(s.dx + 11, s.dy + 16), radius: const Radius.circular(11), clockwise: false)
        ..lineTo(s.dx + 11, s.dy + 4),
      Paint()
        ..color = const Color(0xFF5A2E16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2
        ..strokeCap = StrokeCap.round,
    );
    c.drawRect(Rect.fromLTWH(s.dx - 14, s.dy - 3, 28, 5), _fill(const Color(0xFF3A1D0E)));
  }

  void _tally(Offset at) {
    final scratch = _stroke(const Color(0xFFCFBFA0).withValues(alpha: 0.22), 1.2);
    for (var g = 0; g < 2; g++) {
      final o = at + Offset(g * 26.0, 0);
      for (var i = 0; i < 4; i++) {
        c.drawLine(o + Offset(i * 4.5, 0), o + Offset(i * 4.5 + 1, 20), scratch);
      }
      if (g == 0) c.drawLine(o + const Offset(-3, 15), o + const Offset(17, 4), scratch);
    }
  }

  void _rubble() {
    for (var i = 0; i < 26; i++) {
      final p = Offset(r.nextDouble() * w * (i < 16 ? 0.4 : 1), h - r.nextDouble() * 18);
      final k = 3 + r.nextDouble() * 9;
      final path = Path()..moveTo(p.dx - k, p.dy);
      for (var j = 0; j < 5; j++) {
        final a = math.pi + j * math.pi / 4;
        path.lineTo(p.dx + math.cos(a) * k * (0.6 + r.nextDouble() * 0.5), p.dy + math.sin(a) * k * (0.5 + r.nextDouble() * 0.5));
      }
      path.close();
      c.drawPath(path, _fill(Color.lerp(const Color(0xFF3A3029), const Color(0xFF1A1410), r.nextDouble())!));
    }
  }

  void _bones(Offset at) {
    void bone(Offset a, Offset b) {
      final paint = Paint()
        ..shader = ui.Gradient.linear(a, b, const [Color(0xFFBFAE88), Color(0xFF8F7D5C), Color(0xFF5A4C38)], const [0, 0.5, 1])
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round;
      c.drawLine(a, b, paint);
      for (final e in [a, b]) {
        final d = (b - a) / (b - a).distance;
        final n = Offset(-d.dy, d.dx) * 3;
        c.drawCircle(e + n, 3.2, _fill(const Color(0xFF9E8C68)));
        c.drawCircle(e - n, 3.2, _fill(const Color(0xFF8F7D5C)));
      }
    }

    bone(at + const Offset(-10, 4), at + const Offset(30, -8));
    bone(at + const Offset(0, -10), at + const Offset(26, 6));
  }

  void _rat(Offset at) {
    final body = _fill(const Color(0xFF0E0A08));
    c.drawPath(
      Path()
        ..moveTo(at.dx + 30, at.dy + 6)
        ..cubicTo(at.dx + 50, at.dy + 10, at.dx + 70, at.dy - 2, at.dx + 82, at.dy + 8),
      _stroke(const Color(0xFF1A1210), 1.6),
    );
    c.drawOval(Rect.fromCenter(center: at + const Offset(18, 0), width: 34, height: 18), body);
    c.drawPath(
      Path()
        ..moveTo(at.dx + 4, at.dy - 6)
        ..lineTo(at.dx - 12, at.dy + 2)
        ..lineTo(at.dx + 4, at.dy + 6)
        ..close(),
      body,
    );
    c.drawCircle(at + const Offset(4, -7), 4, _fill(const Color(0xFF1A1210)));
    _light(c, at + const Offset(-2, -1), 5, const Color(0xFFFF5A2A).withValues(alpha: 0.9));
    c.drawCircle(at + const Offset(-2, -1), 1, _fill(const Color(0xFFFFC08A)));
  }

  void _torch(Offset at) {
    final toCentre = at.dx < w / 2 ? 1.0 : -1.0;
    // The iron bracket on the wall.
    final plate = RRect.fromRectAndRadius(Rect.fromCenter(center: at + const Offset(0, 18), width: 12, height: 30),
        const Radius.circular(2));
    c.drawRRect(plate, _fill(const Color(0xFF1A100A)));
    c.drawRRect(plate, _stroke(const Color(0xFF6A3416).withValues(alpha: 0.8), 1));
    c.drawCircle(at + const Offset(0, 8), 1.6, _fill(const Color(0xFF8A4A24)));
    c.drawCircle(at + const Offset(0, 28), 1.6, _fill(const Color(0xFF8A4A24)));
    c.drawLine(at + const Offset(0, 20), at + Offset(10 * toCentre, 6), _stroke(const Color(0xFF2A160C), 3));
    // The stick, leaning out, and its cup.
    final cup = at + Offset(10 * toCentre, 4);
    c.save();
    c.translate(cup.dx, cup.dy);
    c.rotate(0.18 * toCentre);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-3.5, -4, 7, 40), const Radius.circular(2)),
        Paint()..shader = ui.Gradient.linear(const Offset(-4, 0), const Offset(4, 0), const [Color(0xFF2A160A), Color(0xFF5A341A), Color(0xFF24120A)], const [0, 0.5, 1]));
    c.drawPath(
      Path()
        ..moveTo(-8, -10)
        ..lineTo(8, -10)
        ..lineTo(5, 2)
        ..lineTo(-5, 2)
        ..close(),
      _fill(const Color(0xFF2A1A10)),
    );
    // The flame.
    c.drawCircle(const Offset(0, -24), 16, _glow(const Color(0xFFFF7A1A).withValues(alpha: 0.55), 10));
    final flame = Path()
      ..moveTo(0, -46)
      ..cubicTo(10, -30, 11, -18, 6, -10)
      ..quadraticBezierTo(0, -6, -6, -10)
      ..cubicTo(-11, -18, -6, -28, 0, -46)
      ..close();
    c.drawPath(
      flame,
      Paint()
        ..shader = ui.Gradient.linear(const Offset(0, -46), const Offset(0, -6),
            const [Color(0xFFFF4A10), Color(0xFFFF8A20), Color(0xFFFFD27A)], const [0, 0.55, 1]),
    );
    final core = Path()
      ..moveTo(0, -30)
      ..cubicTo(4, -22, 4, -15, 0, -12)
      ..cubicTo(-4, -15, -4, -22, 0, -30)
      ..close();
    c.drawPath(core, _fill(const Color(0xFFFFF2C4)));
    c.restore();
  }
}

/// A skull at [at] (its middle), [width] across: on the wall's floor, the
/// drawer's crest, and an empty screen.
void skullAt(Canvas c, Offset at, double width, {bool cracked = false}) {
  final k = width / 100;
  c.save();
  c.translate(at.dx - 50 * k, at.dy - 55 * k);
  c.scale(k);
  final bone = Paint()
    ..shader = ui.Gradient.radial(const Offset(40, 30), 90, const [Color(0xFFD6C7A2), Color(0xFF8F7D5C), Color(0xFF2F271C)],
        const [0, 0.55, 1]);
  c.drawOval(const Rect.fromLTWH(18, 92, 64, 14), _fill(Colors.black.withValues(alpha: 0.5)));
  // Cranium and cheeks.
  final head = Path()
    ..moveTo(50, 4)
    ..cubicTo(82, 4, 96, 28, 92, 54)
    ..cubicTo(90, 66, 82, 70, 78, 74)
    ..lineTo(76, 88)
    ..lineTo(24, 88)
    ..lineTo(22, 74)
    ..cubicTo(18, 70, 10, 66, 8, 54)
    ..cubicTo(4, 28, 18, 4, 50, 4)
    ..close();
  c.drawPath(head, bone);
  // Eye sockets, deep.
  for (final x in [32.0, 68.0]) {
    c.drawOval(Rect.fromCenter(center: Offset(x, 52), width: 24, height: 20), _fill(const Color(0xFF0A0705)));
    c.drawOval(Rect.fromCenter(center: Offset(x, 50), width: 24, height: 20), _stroke(Colors.black.withValues(alpha: 0.4), 2));
  }
  // Nose.
  c.drawPath(
    Path()
      ..moveTo(50, 60)
      ..lineTo(44, 72)
      ..lineTo(56, 72)
      ..close(),
    _fill(const Color(0xFF120C08)),
  );
  // Teeth, one missing.
  for (var i = 0; i < 7; i++) {
    if (i == 4) continue;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(28 + i * 6.5, 78, 5.5, 10), const Radius.circular(1.5)),
        _fill(const Color(0xFFC9B892)));
  }
  c.drawLine(const Offset(26, 83), const Offset(74, 83), _stroke(const Color(0xFF2A2016), 1.2));
  if (cracked) {
    c.drawPath(
      Path()
        ..moveTo(60, 6)
        ..lineTo(56, 18)
        ..lineTo(63, 26)
        ..lineTo(58, 38),
      _stroke(const Color(0xFF2A2016), 1.6),
    );
  }
  // Grime.
  c.drawOval(const Rect.fromLTWH(10, 20, 30, 26), _fill(const Color(0xFF3A2E1E).withValues(alpha: 0.35)));
  c.restore();
}

// ---------------------------------------------------------------------------
// Enchanted forest.

class _Forest {
  _Forest(this.c, this.s);

  final Canvas c;
  final Size s;
  final r = math.Random(11);

  double get w => s.width;
  double get h => s.height;

  void paint() {
    final rect = Offset.zero & s;
    c.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter,
            const [Color(0xFF0C2216), Color(0xFF0A1B11), Color(0xFF050D08)], const [0, 0.55, 1]),
    );
    _shafts();
    _trunks(far: true);
    _trunks(far: false);
    _vignette(c, s, edge: 0.8);
    _hanging();
    vineEdge(c, const Offset(10, 0), h, r, side: 1);
    vineEdge(c, Offset(w - 10, 0), h, r, side: -1);
    _floor();
    _mushrooms(Offset(34, h - 26), glow: false);
    _mushrooms(Offset(w - 46, h - 22), glow: true);
    _fireflies();
    _grain(c, s, r, dark: 0.2, light: 0.03, per: 18);
  }

  void _shafts() {
    for (var i = 0; i < 4; i++) {
      final x = w * (0.15 + r.nextDouble() * 0.7);
      final spread = 30 + r.nextDouble() * 50;
      final path = Path()
        ..moveTo(x - 12, 0)
        ..lineTo(x + 12, 0)
        ..lineTo(x + spread + 120, h * 0.8)
        ..lineTo(x + 120 - spread, h * 0.8)
        ..close();
      c.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.linear(Offset(x, 0), Offset(x + 120, h * 0.8), [
            const Color(0xFFD8F0A0).withValues(alpha: 0.07),
            const Color(0xFFD8F0A0).withValues(alpha: 0),
          ]),
      );
    }
  }

  void _trunks({required bool far}) {
    final n = far ? 7 : 2;
    for (var i = 0; i < n; i++) {
      final x = far ? w * (i + 0.3 + r.nextDouble() * 0.4) / n : (i == 0 ? -14.0 : w + 14);
      final width = far ? 14 + r.nextDouble() * 22 : 58.0;
      final color = far ? Color.lerp(const Color(0xFF0E2617), const Color(0xFF081A0F), r.nextDouble())! : const Color(0xFF07130B);
      final sway = (r.nextDouble() - 0.5) * 30;
      final path = Path()
        ..moveTo(x - width / 2, 0)
        ..cubicTo(x - width / 2 + sway, h * 0.35, x - width / 2 - sway, h * 0.7, x - width * 0.7, h)
        ..lineTo(x + width * 0.7, h)
        ..cubicTo(x + width / 2 - sway, h * 0.7, x + width / 2 + sway, h * 0.35, x + width / 2, 0)
        ..close();
      c.drawPath(path, _fill(color));
      // Bark.
      for (var j = 0; j < (far ? 4 : 10); j++) {
        final bx = x + (r.nextDouble() - 0.5) * width * 0.7;
        final by = r.nextDouble() * h;
        c.drawLine(Offset(bx, by), Offset(bx + (r.nextDouble() - 0.5) * 4, by + 30 + r.nextDouble() * 60),
            _stroke(Colors.black.withValues(alpha: 0.35), 1.2));
      }
      if (!far) {
        c.drawPath(path, _stroke(const Color(0xFF2A4A2A).withValues(alpha: 0.35), 1.4));
      }
    }
  }

  void _hanging() {
    for (var i = 0; i < 6; i++) {
      final x = w * (0.12 + r.nextDouble() * 0.76);
      final len = 70 + r.nextDouble() * 170;
      final path = Path()..moveTo(x, 0);
      final sway = (r.nextDouble() - 0.5) * 24;
      path.cubicTo(x + sway, len * 0.33, x - sway, len * 0.66, x + sway * 0.5, len);
      c.drawPath(path, _stroke(const Color(0xFF1E4626), 1.6));
      final metrics = path.computeMetrics().first;
      for (var d = 10.0; d < metrics.length; d += 13) {
        final t = metrics.getTangentForOffset(d)!;
        leafAt(c, t.position, 7 + r.nextDouble() * 3, (d ~/ 13).isEven ? 0.9 : -0.9, r);
      }
    }
  }

  void _floor() {
    final path = Path()..moveTo(0, h - 40);
    for (var x = 0.0; x <= w; x += 24) {
      path.quadraticBezierTo(x + 12, h - 48 - r.nextDouble() * 12, x + 24, h - 38 - r.nextDouble() * 8);
    }
    path
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    c.drawPath(path, _fill(const Color(0xFF0B1D10)));
    for (var i = 0; i < 90; i++) {
      final x = r.nextDouble() * w;
      final y = h - 30 + r.nextDouble() * 30;
      c.drawLine(Offset(x, y), Offset(x + (r.nextDouble() - 0.5) * 6, y - 8 - r.nextDouble() * 12),
          _stroke(Color.lerp(const Color(0xFF2A5A2A), const Color(0xFF173A1A), r.nextDouble())!, 1.1));
    }
  }

  void _mushrooms(Offset at, {required bool glow}) {
    for (var i = 0; i < 3; i++) {
      final p = at + Offset(i * 14.0 - 10, -i * 3.0);
      final k = 1.0 - i * 0.22;
      if (glow) _light(c, p + Offset(0, -12 * k), 34 * k, const Color(0xFF5AF0D0).withValues(alpha: 0.28));
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p + Offset(0, -6 * k), width: 5 * k, height: 14 * k), const Radius.circular(2)),
          _fill(const Color(0xFFCFC4A8)));
      final cap = Path()
        ..moveTo(p.dx - 12 * k, p.dy - 12 * k)
        ..quadraticBezierTo(p.dx, p.dy - 30 * k, p.dx + 12 * k, p.dy - 12 * k)
        ..close();
      c.drawPath(cap, _fill(glow ? const Color(0xFF2FB8A0) : const Color(0xFF8A2A1A)));
      for (var j = 0; j < 3; j++) {
        c.drawCircle(p + Offset((j - 1) * 5.0 * k, -17 * k + (j == 1 ? -3 : 0)), 1.4 * k,
            _fill(glow ? const Color(0xFFCFFFF4) : const Color(0xFFEFE2C8)));
      }
    }
  }

  void _fireflies() {
    for (var i = 0; i < 30; i++) {
      final edge = r.nextBool();
      final x = edge ? (r.nextBool() ? r.nextDouble() * w * 0.18 : w - r.nextDouble() * w * 0.18) : r.nextDouble() * w;
      final y = r.nextDouble() * h * 0.92;
      final p = Offset(x, y);
      _light(c, p, 7 + r.nextDouble() * 6, const Color(0xFFE6FF6A).withValues(alpha: 0.55));
      c.drawCircle(p, 1.2, _fill(const Color(0xFFFFF6B0)));
    }
  }
}

/// A leaf at [at], [size] long, leaning by [angle].
void leafAt(Canvas c, Offset at, double size, double angle, math.Random r) {
  c.save();
  c.translate(at.dx, at.dy);
  c.rotate(angle + (r.nextDouble() - 0.5) * 0.5);
  final leaf = Path()
    ..moveTo(0, 0)
    ..quadraticBezierTo(size * 0.55, -size * 0.45, size, 0)
    ..quadraticBezierTo(size * 0.55, size * 0.45, 0, 0)
    ..close();
  c.drawPath(
    leaf,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(size, 0), [
        Color.lerp(const Color(0xFF3F8A42), const Color(0xFF2A6A30), r.nextDouble())!,
        const Color(0xFF173F1E),
      ]),
  );
  c.drawLine(Offset.zero, Offset(size * 0.85, 0), _stroke(const Color(0xFF0E2A12).withValues(alpha: 0.8), 0.6));
  c.restore();
}

/// A vine climbing an edge at [top]'s x, down [length], with leaves and
/// curls: the forest's own edge, round the screen and round its panels.
void vineEdge(Canvas c, Offset top, double length, math.Random r, {required double side}) {
  final path = Path()..moveTo(top.dx, top.dy);
  for (var y = 0.0; y <= length; y += 8) {
    path.lineTo(top.dx + math.sin(y / 38) * 7 * side, top.dy + y);
  }
  c.drawPath(path, _stroke(const Color(0xFF16361C), 3.4));
  c.drawPath(path, _stroke(const Color(0xFF2E5A2E).withValues(alpha: 0.7), 1.2));
  for (var y = 14.0; y < length; y += 22 + r.nextDouble() * 10) {
    final p = Offset(top.dx + math.sin(y / 38) * 7 * side, top.dy + y);
    leafAt(c, p, 9 + r.nextDouble() * 5, side > 0 ? -0.3 + r.nextDouble() * 0.8 : math.pi + 0.3 - r.nextDouble() * 0.8, r);
    if (r.nextDouble() < 0.18) _curl(c, p, 6 + r.nextDouble() * 4, side);
  }
}

/// A tendril's spiral.
void _curl(Canvas c, Offset at, double size, double side) {
  final path = Path()..moveTo(at.dx, at.dy);
  for (var t = 0.0; t < math.pi * 3; t += 0.25) {
    final rad = size * (1 - t / (math.pi * 3.4));
    path.lineTo(at.dx + side * (size - math.cos(t) * rad), at.dy - math.sin(t) * rad);
  }
  c.drawPath(path, _stroke(const Color(0xFF2E5A2E), 1));
}

// ---------------------------------------------------------------------------
// Starship.

const _neon = Color(0xFF3FE0F0);

class _Starship {
  _Starship(this.c, this.s);

  final Canvas c;
  final Size s;
  final r = math.Random(5);

  double get w => s.width;
  double get h => s.height;

  void paint() {
    c.drawRect(Offset.zero & s, _fill(const Color(0xFF03060D)));
    _plates();
    _porthole(Offset(w + 4, h * 0.34), 74);
    _vignette(c, s, edge: 0.78);
    _strips();
    for (final (corner, dx, dy) in [
      (const Offset(8, 8), 1.0, 1.0),
      (Offset(w - 8, 8), -1.0, 1.0),
      (Offset(8, h - 8), 1.0, -1.0),
      (Offset(w - 8, h - 8), -1.0, -1.0),
    ]) {
      bracket(c, corner, 26, dx, dy, _neon);
    }
    _grain(c, s, r, dark: 0.18, light: 0.03, per: 22);
  }

  void _plates() {
    var y = 0.0;
    while (y < h) {
      final ph = 70 + r.nextDouble() * 80;
      var x = 0.0;
      while (x < w) {
        final pw = 64 + r.nextDouble() * 70;
        _plate(Rect.fromLTWH(x, y, math.min(pw, w - x + 1), ph));
        x += pw;
      }
      y += ph;
    }
  }

  void _plate(Rect rect) {
    final inner = rect.deflate(1);
    final base = Color.lerp(const Color(0xFF0B1424), const Color(0xFF070E1A), r.nextDouble())!;
    c.drawRect(
      inner,
      Paint()..shader = ui.Gradient.linear(inner.topLeft, inner.bottomRight, [Color.lerp(base, Colors.white, 0.04)!, base]),
    );
    c.drawLine(inner.topLeft, inner.topRight, _stroke(const Color(0xFF1C2C46).withValues(alpha: 0.7), 1)..strokeCap = StrokeCap.butt);
    c.drawLine(inner.topLeft, inner.bottomLeft, _stroke(const Color(0xFF1C2C46).withValues(alpha: 0.5), 1)..strokeCap = StrokeCap.butt);
    c.drawLine(inner.bottomLeft, inner.bottomRight, _stroke(Colors.black, 1.4)..strokeCap = StrokeCap.butt);
    for (final p in [inner.topLeft + const Offset(5, 5), inner.topRight + const Offset(-5, 5), inner.bottomLeft + const Offset(5, -5), inner.bottomRight + const Offset(-5, -5)]) {
      c.drawCircle(p, 1.3, _fill(const Color(0xFF24344E)));
    }
    final roll = r.nextDouble();
    if (roll < 0.18) {
      // Vent slats.
      for (var i = 0; i < 6; i++) {
        final yy = inner.top + 14 + i * 6.0;
        if (yy > inner.bottom - 10) break;
        c.drawLine(Offset(inner.left + 12, yy), Offset(inner.right - 12, yy), _stroke(Colors.black.withValues(alpha: 0.7), 2)..strokeCap = StrokeCap.butt);
      }
    } else if (roll < 0.3) {
      // A row of status lights.
      for (var i = 0; i < 4; i++) {
        final color = [const Color(0xFF39FF88), const Color(0xFFFFB13A), _neon, const Color(0xFFFF4A6A)][r.nextInt(4)];
        final p = Offset(inner.left + 12 + i * 9.0, inner.bottom - 12);
        _light(c, p, 6, color.withValues(alpha: 0.5));
        c.drawCircle(p, 1.4, _fill(color));
      }
    }
  }

  void _porthole(Offset centre, double radius) {
    c.drawCircle(centre, radius + 10, Paint()..shader = ui.Gradient.radial(centre, radius + 10, const [Color(0xFF2A3A52), Color(0xFF0C1422)], const [0.85, 1]));
    c.drawCircle(centre, radius + 10, _stroke(Colors.black, 2));
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: radius)));
    c.drawCircle(centre, radius, _fill(const Color(0xFF02030A)));
    for (var i = 0; i < 70; i++) {
      final p = centre + Offset((r.nextDouble() - 0.5) * radius * 2, (r.nextDouble() - 0.5) * radius * 2);
      c.drawCircle(p, r.nextDouble() * 0.9 + 0.2, _fill(Colors.white.withValues(alpha: 0.4 + r.nextDouble() * 0.6)));
    }
    final planet = centre + Offset(-radius * 0.35, radius * 0.3);
    c.drawCircle(planet, radius * 0.46,
        Paint()..shader = ui.Gradient.radial(planet - Offset(radius * 0.15, radius * 0.15), radius * 0.6, const [Color(0xFFFFCF8A), Color(0xFFD0622D), Color(0xFF3A1208)], const [0, 0.5, 1]));
    c.drawOval(Rect.fromCenter(center: planet, width: radius * 1.5, height: radius * 0.28), _stroke(const Color(0xFFFFD9A0).withValues(alpha: 0.5), 1.4));
    // The glass.
    c.drawArc(Rect.fromCircle(center: centre, radius: radius * 0.8), math.pi * 1.1, math.pi * 0.4, false,
        _stroke(Colors.white.withValues(alpha: 0.12), 3));
    c.restore();
    for (var i = 0; i < 12; i++) {
      final a = i / 12 * math.pi * 2;
      c.drawCircle(centre + Offset(math.cos(a), math.sin(a)) * (radius + 5), 1.6, _fill(const Color(0xFF4A5A74)));
    }
  }

  void _strips() {
    for (final x in [5.0, w - 5]) {
      final a = Offset(x, h * 0.14);
      final b = Offset(x, h * 0.86);
      c.drawLine(a, b, _glow(_neon.withValues(alpha: 0.55), 6)..strokeWidth = 5);
      c.drawLine(a, b, _stroke(const Color(0xFF9FF6FF), 1.4));
    }
    const magenta = Color(0xFFFF3FD0);
    for (var i = 0; i < 3; i++) {
      final a = Offset(w * (0.2 + i * 0.22), h - 26);
      final b = a + const Offset(40, 0);
      c.drawLine(a, b, _glow(magenta.withValues(alpha: 0.5), 5)..strokeWidth = 4);
      c.drawLine(a, b, _stroke(const Color(0xFFFFA8EC), 1.2));
    }
  }
}

/// A glowing L at [corner], arms [len] long, pointing along [dx] and [dy].
void bracket(Canvas c, Offset corner, double len, double dx, double dy, Color color, {double width = 2}) {
  final path = Path()
    ..moveTo(corner.dx + len * dx, corner.dy)
    ..lineTo(corner.dx, corner.dy)
    ..lineTo(corner.dx, corner.dy + len * dy);
  c.drawPath(path, _glow(color.withValues(alpha: 0.6), 4)
    ..style = PaintingStyle.stroke
    ..strokeWidth = width + 3);
  c.drawPath(path, _stroke(Color.lerp(color, Colors.white, 0.5)!, width)..strokeCap = StrokeCap.square);
}

// ---------------------------------------------------------------------------
// Frames, panels and ornaments.

/// [scene]'s frame round a cover filling [rect], its corners [radius].
void paintCoverFrame(Canvas c, Rect rect, Scene scene, double radius) {
  final t = (rect.width * 0.06).clamp(2.5, 9.0);
  switch (scene) {
    case Scene.dungeon:
      final rr = RRect.fromRectAndRadius(rect.deflate(t / 2), Radius.circular(math.max(radius, t)));
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight,
              const [Color(0xFF3A1D0E), Color(0xFF8A4A24), Color(0xFF4A2412), Color(0xFF7A3E1C), Color(0xFF24120A)], const [0, 0.3, 0.55, 0.8, 1])
          ..style = PaintingStyle.stroke
          ..strokeWidth = t,
      );
      c.drawRRect(rr.deflate(t / 2), _stroke(Colors.black.withValues(alpha: 0.7), 1));
      c.drawRRect(rr.inflate(t / 2), _stroke(Colors.black.withValues(alpha: 0.8), 1));
      // Pitting.
      final r = math.Random(rect.width.round());
      for (var i = 0; i < (rect.width / 6).round(); i++) {
        final along = r.nextDouble();
        final top = r.nextBool();
        final p = top
            ? Offset(rect.left + along * rect.width, r.nextBool() ? rect.top + t / 2 : rect.bottom - t / 2)
            : Offset(r.nextBool() ? rect.left + t / 2 : rect.right - t / 2, rect.top + along * rect.height);
        c.drawCircle(p, 0.5 + r.nextDouble() * 0.9, _fill(const Color(0xFF140804).withValues(alpha: 0.8)));
      }
      final rivet = t * 0.42;
      for (final p in [
        rect.topLeft + Offset(t * 1.1, t * 1.1),
        rect.topRight + Offset(-t * 1.1, t * 1.1),
        rect.bottomLeft + Offset(t * 1.1, -t * 1.1),
        rect.bottomRight + Offset(-t * 1.1, -t * 1.1),
      ]) {
        c.drawCircle(p, rivet + 0.6, _fill(Colors.black.withValues(alpha: 0.6)));
        c.drawCircle(p, rivet,
            Paint()..shader = ui.Gradient.radial(p - Offset(rivet * 0.3, rivet * 0.3), rivet * 1.2, const [Color(0xFFD08A4C), Color(0xFF6A3416), Color(0xFF140804)], const [0, 0.45, 1]));
      }
    case Scene.forest:
      final rr = RRect.fromRectAndRadius(rect.deflate(t / 2), Radius.circular(math.max(radius, t)));
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, const [Color(0xFF5E3B1F), Color(0xFF3A2414), Color(0xFF6A4424), Color(0xFF2E1C10)], const [0, 0.35, 0.65, 1])
          ..style = PaintingStyle.stroke
          ..strokeWidth = t,
      );
      c.drawRRect(rr.deflate(t / 2), _stroke(Colors.black.withValues(alpha: 0.6), 1));
      final r = math.Random(rect.height.round());
      // Vine round two corners.
      final k = rect.width * 0.11;
      for (final (corner, sx, sy) in [(rect.topLeft, 1.0, 1.0), (rect.bottomRight, -1.0, -1.0)]) {
        final path = Path()
          ..moveTo(corner.dx + sx * k * 2.6, corner.dy + sy * t * 0.5)
          ..quadraticBezierTo(corner.dx + sx * t * 0.3, corner.dy + sy * t * 0.3, corner.dx + sx * t * 0.5, corner.dy + sy * k * 2.6);
        c.drawPath(path, _stroke(const Color(0xFF1E4626), math.max(1.2, t * 0.35)));
        for (var i = 0; i < 4; i++) {
          final m = path.computeMetrics().first;
          final tg = m.getTangentForOffset(m.length * (0.15 + i * 0.22))!;
          leafAt(c, tg.position, math.max(4, k * 0.9), (i.isEven ? -0.6 : 0.6) + (sx > 0 ? 0 : math.pi), r);
        }
      }
    case Scene.starship:
      final sharp = rect.deflate(0.5);
      c.drawRect(sharp, _stroke(_neon.withValues(alpha: 0.4), 1)..strokeCap = StrokeCap.butt);
      final len = rect.width * 0.2;
      for (final (corner, dx, dy) in [
        (sharp.topLeft, 1.0, 1.0),
        (sharp.topRight, -1.0, 1.0),
        (sharp.bottomLeft, 1.0, -1.0),
        (sharp.bottomRight, -1.0, -1.0),
      ]) {
        bracket(c, corner, len, dx, dy, _neon, width: math.max(1.2, t * 0.35));
      }
  }
}

/// A frame drawn over a cover (or a tile) in [scene].
class CoverFramePainter extends CustomPainter {
  const CoverFramePainter(this.scene, this.radius);

  final Scene scene;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) => paintCoverFrame(canvas, Offset.zero & size, scene, radius);

  @override
  bool shouldRepaint(CoverFramePainter old) => old.scene != scene || old.radius != radius;
}

/// A panel of [scene]'s material: settings groups, the player, the dock,
/// cards. [fill] is the colour the plain theme would give it, kept as its
/// tint so a lit (chosen) panel still reads as chosen.
class ScenePanel extends Decoration {
  const ScenePanel(this.scene, {this.radius, this.shadow, this.lit = false});

  final Scene scene;
  final BorderRadius? radius;
  final List<BoxShadow>? shadow;

  /// The player and the dock: a touch more of the scene's light on them.
  final bool lit;

  @override
  EdgeInsetsGeometry get padding => EdgeInsets.zero;

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) => panelPath(rect, scene, scene.corners(radius));

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      panelPath(Offset.zero & size, scene, scene.corners(radius)).contains(position);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _ScenePanelPainter(this);

  @override
  bool operator ==(Object other) =>
      other is ScenePanel && other.scene == scene && other.radius == radius && other.lit == lit && listEquals(other.shadow, shadow);

  @override
  int get hashCode => Object.hash(scene, radius, lit, shadow == null ? null : Object.hashAll(shadow!));
}

class _ScenePanelPainter extends BoxPainter {
  _ScenePanelPainter(this.d);

  final ScenePanel d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    paintPanel(canvas, offset & size, d.scene, d.scene.corners(d.radius), lit: d.lit, shadow: d.shadow);
  }
}

/// The outline of a panel at [rect]: [corners] rounded, but a starship's
/// cut off at its top left and bottom right, as a ship's hatches are.
Path panelPath(Rect rect, Scene scene, BorderRadius corners) {
  if (scene != Scene.starship) return Path()..addRRect(corners.toRRect(rect));
  return cutPath(rect, math.min(Scene.cut, math.min(rect.width, rect.height) * 0.3));
}

/// [r] with its top left and bottom right corners cut by [k].
Path cutPath(Rect r, double k) => Path()
  ..moveTo(r.left + k, r.top)
  ..lineTo(r.right, r.top)
  ..lineTo(r.right, r.bottom - k)
  ..lineTo(r.right - k, r.bottom)
  ..lineTo(r.left, r.bottom)
  ..lineTo(r.left, r.top + k)
  ..close();

/// A panel of [scene]'s material at [rect].
void paintPanel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false, List<BoxShadow>? shadow}) {
  final rr = corners.toRRect(rect);
  for (final s in shadow ?? const <BoxShadow>[]) {
    if (scene == Scene.starship) {
      c.drawPath(panelPath(rect.shift(s.offset).inflate(s.spreadRadius), scene, corners), s.toPaint());
    } else {
      c.drawRRect(rr.shift(s.offset).inflate(s.spreadRadius), s.toPaint());
    }
  }
  final r = math.Random((rect.width * 31 + rect.height).round());
  switch (scene) {
    case Scene.dungeon:
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            lit ? const Color(0xFF2A211B) : const Color(0xFF221B16),
            const Color(0xFF17120F),
            const Color(0xFF110D0B),
          ], const [
            0,
            0.5,
            1,
          ]),
      );
      // Stone texture: a few pits and a crack from an edge.
      for (var i = 0; i < (rect.width * rect.height / 900).clamp(4, 60); i++) {
        c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
            0.6 + r.nextDouble() * 1.2, _fill(Colors.black.withValues(alpha: 0.35)));
      }
      c.save();
      c.clipRRect(rr);
      final from = Offset(rect.left + rect.width * (0.6 + r.nextDouble() * 0.35), rect.top);
      c.drawPath(_jagged(r, from, from + Offset(-18 - r.nextDouble() * 20, math.min(rect.height * 0.5, 40)), steps: 6, wobble: 3),
          _stroke(Colors.black.withValues(alpha: 0.6), 1));
      // Rusted bands along its top and foot.
      final band = Paint()
        ..color = const Color(0xFF6A3416).withValues(alpha: 0.55)
        ..strokeWidth = 1.4;
      c.drawLine(Offset(rect.left, rect.top + 3.5), Offset(rect.right, rect.top + 3.5), band);
      c.drawLine(Offset(rect.left, rect.bottom - 3.5), Offset(rect.right, rect.bottom - 3.5), band);
      // Carved: lit along its top edge, sunk along its foot.
      c.drawLine(Offset(rect.left + 6, rect.top + 1.2), Offset(rect.right - 6, rect.top + 1.2),
          _stroke(Colors.white.withValues(alpha: 0.09), 1.4));
      c.drawLine(Offset(rect.left + 4, rect.bottom - 1.2), Offset(rect.right - 4, rect.bottom - 1.2),
          _stroke(Colors.black.withValues(alpha: 0.6), 2));
      // Damp creeping up from the foot, moss in a corner.
      c.drawRect(
        Rect.fromLTRB(rect.left, rect.bottom - math.min(26.0, rect.height * 0.35), rect.right, rect.bottom),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, rect.bottom - math.min(26.0, rect.height * 0.35)), Offset(0, rect.bottom),
              [const Color(0xFF14180C).withValues(alpha: 0), const Color(0xFF1A2010).withValues(alpha: 0.45)]),
      );
      if (rect.height > 50) {
        for (var i = 0; i < 9; i++) {
          final p = Offset(rect.left + 4 + r.nextDouble() * 34, rect.bottom - 2 - r.nextDouble() * 9);
          c.drawOval(Rect.fromCenter(center: p, width: 3 + r.nextDouble() * 6, height: 1.6 + r.nextDouble() * 2.4),
              _fill(Color.lerp(const Color(0xFF3A4A20), const Color(0xFF243014), r.nextDouble())!.withValues(alpha: 0.8)));
        }
      }
      c.restore();
      c.drawRRect(rr, _stroke(const Color(0xFF3E2E22), 1.2));
      c.drawRRect(rr.deflate(1.2), _stroke(Colors.white.withValues(alpha: 0.04), 1));
      if (rect.height > 36 && rect.width > 60) {
        for (final p in [
          rect.topLeft + const Offset(9, 9),
          rect.topRight + const Offset(-9, 9),
          rect.bottomLeft + const Offset(9, -9),
          rect.bottomRight + const Offset(-9, -9),
        ]) {
          c.drawCircle(p, 2.4,
              Paint()..shader = ui.Gradient.radial(p - const Offset(0.8, 0.8), 3, const [Color(0xFFC07A40), Color(0xFF5A2A12), Color(0xFF140804)], const [0, 0.5, 1]));
        }
      }
    case Scene.forest:
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            lit ? const Color(0xFF173222) : const Color(0xFF12281A),
            const Color(0xFF0C1C12),
          ]),
      );
      c.drawRRect(rr, _stroke(const Color(0xFF3A6A34).withValues(alpha: 0.7), 1.3));
      c.drawRRect(rr.deflate(2.5), _stroke(const Color(0xFF5A3A1E).withValues(alpha: 0.5), 1));
      // A vine curling over two corners.
      if (rect.height > 30 && rect.width > 60) {
        for (final (corner, sx, sy) in [(rect.topLeft, 1.0, 1.0), (rect.bottomRight, -1.0, -1.0)]) {
          final k = math.min(36.0, rect.height * 0.7);
          final path = Path()
            ..moveTo(corner.dx + sx * k * 1.6, corner.dy + sy * 1)
            ..quadraticBezierTo(corner.dx + sx * 2, corner.dy + sy * 2, corner.dx + sx * 1, corner.dy + sy * k);
          c.drawPath(path, _stroke(const Color(0xFF1E4626), 1.8));
          final m = path.computeMetrics().first;
          for (var i = 0; i < 3; i++) {
            final tg = m.getTangentForOffset(m.length * (0.2 + i * 0.3))!;
            leafAt(c, tg.position, 7, (i.isEven ? -0.7 : 0.7) + (sx > 0 ? 0 : math.pi), r);
          }
          _curl(c, corner + Offset(sx * k * 1.6, sy * 1), 4, sx);
        }
      }
    case Scene.starship:
      final hull = panelPath(rect, scene, corners);
      c.drawPath(
        hull,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
            lit ? const Color(0xFF0C1A2C) : const Color(0xFF0A1424),
            const Color(0xFF060C17),
          ]),
      );
      // Faint scan lines across it, as on a screen.
      if (rect.height > 30) {
        c.save();
        c.clipPath(hull);
        final scan = _stroke(_neon.withValues(alpha: 0.035), 1)..strokeCap = StrokeCap.butt;
        for (var y = rect.top + 3; y < rect.bottom; y += 4) {
          c.drawLine(Offset(rect.left, y), Offset(rect.right, y), scan);
        }
        c.restore();
      }
      c.drawPath(hull, _stroke(const Color(0xFF1F4A66), 1)..strokeJoin = StrokeJoin.miter);
      // Neon along the two cut corners, brackets at the other two.
      final k = math.min(Scene.cut, math.min(rect.width, rect.height) * 0.3);
      for (final edge in [
        Path()
          ..moveTo(rect.left, rect.top + k + 14)
          ..lineTo(rect.left, rect.top + k)
          ..lineTo(rect.left + k, rect.top)
          ..lineTo(rect.left + k + 14, rect.top),
        Path()
          ..moveTo(rect.right, rect.bottom - k - 14)
          ..lineTo(rect.right, rect.bottom - k)
          ..lineTo(rect.right - k, rect.bottom)
          ..lineTo(rect.right - k - 14, rect.bottom),
      ]) {
        c.drawPath(edge, _glow(_neon.withValues(alpha: 0.5), 3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.4);
        c.drawPath(edge, _stroke(const Color(0xFF9FF6FF), 1.3)..strokeJoin = StrokeJoin.miter);
      }
      final len = math.min(14.0, math.min(rect.width, rect.height) * 0.3);
      for (final (corner, dx, dy) in [
        (rect.topRight, -1.0, 1.0),
        (rect.bottomLeft, 1.0, -1.0),
      ]) {
        bracket(c, corner + Offset(dx * 1, dy * 1), len, dx, dy, _neon, width: 1.4);
      }
  }
}

/// A button or a pill in [scene]: [fill] (the colour the plain theme gives
/// it, an accent for a chosen one) worked into the place's material.
class SceneButton extends Decoration {
  const SceneButton(this.scene, this.fill, this.radius);

  final Scene scene;
  final Color fill;
  final BorderRadius radius;

  /// The shape a button takes in [scene] at [radius]: a starship's is cut.
  static ShapeBorder shape(Scene scene, BorderRadius radius) => scene == Scene.starship
      ? const BeveledRectangleBorder(borderRadius: BorderRadius.only(topLeft: Radius.circular(8), bottomRight: Radius.circular(8)))
      : RoundedRectangleBorder(borderRadius: radius);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _SceneButtonPainter(this);

  @override
  bool operator ==(Object other) => other is SceneButton && other.scene == scene && other.fill == fill && other.radius == radius;

  @override
  int get hashCode => Object.hash(scene, fill, radius);
}

class _SceneButtonPainter extends BoxPainter {
  _SceneButtonPainter(this.d);

  final SceneButton d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    paintButton(canvas, offset & size, d.scene, d.fill, d.radius);
  }
}

/// A button of [scene]'s material at [rect].
void paintButton(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  final path = scene == Scene.starship
      ? cutPath(rect, math.min(8.0, rect.shortestSide * 0.3))
      : (Path()..addRRect(radius.toRRect(rect)));
  final bright = fill.computeLuminance() > 0.12;
  c.drawPath(
    path,
    Paint()
      ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
        Color.lerp(fill, Colors.white, bright ? 0.18 : 0.07)!,
        fill,
        Color.lerp(fill, Colors.black, bright ? 0.3 : 0.4)!,
      ], const [
        0,
        0.45,
        1,
      ]),
  );
  c.save();
  c.clipPath(path);
  switch (scene) {
    case Scene.dungeon:
      // Pitted stone (or glowing coal, lit), lit along the top.
      final r = math.Random((rect.width * 7 + rect.height).round());
      for (var i = 0; i < (rect.width * rect.height / 140).clamp(4, 40); i++) {
        c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
            0.5 + r.nextDouble() * 1.0, _fill(Colors.black.withValues(alpha: bright ? 0.22 : 0.4)));
      }
      c.drawPath(path.shift(const Offset(0, 1.2)), _stroke(Colors.white.withValues(alpha: bright ? 0.25 : 0.08), 1.2));
    case Scene.forest:
      // Grain, as in polished wood.
      final r = math.Random((rect.width * 5 + rect.height).round());
      for (var i = 0; i < 4; i++) {
        final y = rect.top + rect.height * (0.2 + i * 0.2) + (r.nextDouble() - 0.5) * 3;
        c.drawPath(
          Path()
            ..moveTo(rect.left, y)
            ..quadraticBezierTo(rect.center.dx, y + (r.nextDouble() - 0.5) * 6, rect.right, y + (r.nextDouble() - 0.5) * 3),
          _stroke(Colors.black.withValues(alpha: bright ? 0.1 : 0.22), 0.8),
        );
      }
      c.drawPath(path.shift(const Offset(0, 1)), _stroke(Colors.white.withValues(alpha: bright ? 0.2 : 0.07), 1));
    case Scene.starship:
      for (var y = rect.top + 2; y < rect.bottom; y += 3.5) {
        c.drawLine(Offset(rect.left, y), Offset(rect.right, y), _stroke(Colors.white.withValues(alpha: 0.03), 1)..strokeCap = StrokeCap.butt);
      }
  }
  c.restore();
  switch (scene) {
    case Scene.dungeon:
      c.drawPath(path, _stroke(Colors.black.withValues(alpha: 0.75), 1.4));
      c.drawPath(path, _stroke((bright ? const Color(0xFFFFC08A) : const Color(0xFF6A3416)).withValues(alpha: bright ? 0.35 : 0.75), 0.9));
    case Scene.forest:
      c.drawPath(path, _stroke(const Color(0xFF0A1A0E).withValues(alpha: 0.8), 1.4));
      c.drawPath(path, _stroke((bright ? const Color(0xFFCFFFF0) : const Color(0xFF3A6A34)).withValues(alpha: bright ? 0.35 : 0.8), 0.9));
    case Scene.starship:
      if (bright) {
        c.drawPath(path, _glow(fill.withValues(alpha: 0.6), 4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
      }
      c.drawPath(path, _stroke(bright ? const Color(0xFFCFFBFF) : _neon.withValues(alpha: 0.55), 1)..strokeJoin = StrokeJoin.miter);
  }
}

// ---------------------------------------------------------------------------
// Life: what moves in a scene, over its still backdrop.

/// What moves in [scene]: torches that flicker and throw up embers, dust in
/// their light; fireflies that drift and glow, a leaf falling; neon pulsing
/// along the hull, a scan going down, stars that twinkle. Drawn on its own
/// layer about 30 times a second (the screen over it is not drawn again),
/// only while it shows, and not at all when the phone is set to remove
/// animations.
class SceneLife extends StatefulWidget {
  const SceneLife(this.scene, {super.key});

  final Scene scene;

  @override
  State<SceneLife> createState() => _SceneLifeState();
}

/// Whether a scene's life moves: not under `flutter test`, where a screen
/// that never stops moving would never settle (its painter is tested on its
/// own).
@visibleForTesting
bool sceneLifeMoves = !Platform.environment.containsKey('FLUTTER_TEST');

class _SceneLifeState extends State<SceneLife> with SingleTickerProviderStateMixin {
  final _time = ValueNotifier<double>(0);
  late final _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  void _tick(Duration t) {
    // About 30 a second is smooth for flames and fireflies, and half the work.
    if (t - _last < const Duration(milliseconds: 33)) return;
    _last = t;
    _time.value = t.inMicroseconds / 1e6;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = !sceneLifeMoves || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(painter: LifePainter(widget.scene, _time), size: Size.infinite),
        ),
      ),
    );
  }
}

/// [scene]'s life at the time [time] holds (seconds), over a backdrop drawn
/// for a box of this size.
class LifePainter extends CustomPainter {
  LifePainter(this.scene, this.time) : super(repaint: time);

  final Scene scene;
  final ValueListenable<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Placed as the backdrop places its things: on the whole screen's size.
    final s = _canvasFor(size);
    final t = time.value;
    switch (scene) {
      case Scene.dungeon:
        _dungeonLife(canvas, s, t);
      case Scene.forest:
        _forestLife(canvas, s, t);
      case Scene.starship:
        _starshipLife(canvas, s, t);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LifePainter old) => old.scene != scene || old.time != time;
}

/// A soft wobble between 0 and 1 for flames: three sines out of step.
double _flicker(double t, double seed) =>
    0.5 + 0.22 * math.sin(t * 9.1 + seed) + 0.16 * math.sin(t * 15.7 + seed * 2.3) + 0.12 * math.sin(t * 4.3 + seed * 0.7);

void _dungeonLife(Canvas c, Size s, double t) {
  final torches = [Offset(16, s.height * 0.2), Offset(s.width - 16, s.height * 0.46)];
  for (var i = 0; i < torches.length; i++) {
    final at = torches[i];
    final f = _flicker(t, i * 3.1).clamp(0.0, 1.0);
    final toCentre = at.dx < s.width / 2 ? 1.0 : -1.0;
    final cup = at + Offset(10 * toCentre, 4);
    // The light on the wall breathing with the flame.
    _light(c, cup + const Offset(0, -24), 120 + f * 40, const Color(0xFFFF8A2A).withValues(alpha: 0.07 + f * 0.09), mid: 0.3);
    // The flame itself, a little taller and leaning as it burns.
    c.save();
    c.translate(cup.dx, cup.dy);
    c.rotate(0.18 * toCentre + math.sin(t * 3.3 + i) * 0.08);
    final tall = 1.08 + f * 0.3;
    final sway = math.sin(t * 6.1 + i * 2) * 4;
    _light(c, Offset(0, -24 * tall), 18 + f * 6, const Color(0xFFFF9A3A).withValues(alpha: 0.5));
    final flame = Path()
      ..moveTo(sway, -48 * tall)
      ..cubicTo(11, -32 * tall, 12, -18, 6.5, -9)
      ..quadraticBezierTo(0, -5, -6.5, -9)
      ..cubicTo(-12, -18, -6 + sway * 0.4, -30 * tall, sway, -48 * tall)
      ..close();
    c.drawPath(
      flame,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, -48 * tall), const Offset(0, -6),
            const [Color(0xFFFF4A10), Color(0xFFFF8A20), Color(0xFFFFD27A)], const [0, 0.55, 1]),
    );
    final core = Path()
      ..moveTo(sway * 0.5, -30 * tall)
      ..cubicTo(4.5, -22, 4, -15, 0, -11)
      ..cubicTo(-4, -15, -4.5, -22, sway * 0.5, -30 * tall)
      ..close();
    c.drawPath(core, _fill(const Color(0xFFFFF2C4)));
    c.restore();
    // Embers rising off it, drifting, dying.
    for (var e = 0; e < 9; e++) {
      final seed = i * 17 + e * 7.3;
      const life = 2.6;
      final age = ((t + seed * 0.37) % life) / life;
      final rise = age * 150;
      final drift = math.sin(t * 1.7 + seed) * 10 * age + toCentre * age * 26;
      final p = cup + Offset(drift + (seed % 5 - 2) * 2, -40 - rise);
      final a = (1 - age) * (age < 0.1 ? age * 10 : 1);
      _light(c, p, 4.5, const Color(0xFFFF7A1A).withValues(alpha: 0.55 * a));
      c.drawCircle(p, 0.9, _fill(const Color(0xFFFFD08A).withValues(alpha: 0.9 * a)));
    }
  }
  // Dust turning slowly in the dark, catching what light there is.
  for (var d = 0; d < 18; d++) {
    final x = (d * 97.0 + t * (4 + d % 3)) % (s.width + 40) - 20;
    final y = (d * 151.0 % s.height) + math.sin(t * 0.6 + d) * 14;
    final a = 0.10 + 0.08 * math.sin(t * 0.9 + d * 1.3);
    c.drawCircle(Offset(x, y), 0.9 + (d % 3) * 0.35, _fill(const Color(0xFFFFE6C0).withValues(alpha: a)));
  }
}

void _forestLife(Canvas c, Size s, double t) {
  // Fireflies on slow loops, each glowing in its own time.
  for (var i = 0; i < 22; i++) {
    final edge = i % 3 != 0;
    final bx = edge ? (i.isEven ? 0.06 + (i * 0.037 % 0.12) : 0.82 + (i * 0.029 % 0.12)) : (i * 0.137 % 1);
    final by = (i * 0.071 + 0.05) % 0.92;
    final p = Offset(
      s.width * bx + math.sin(t * (0.25 + i % 4 * 0.06) + i) * 22,
      s.height * by + math.cos(t * (0.2 + i % 5 * 0.05) + i * 1.7) * 18,
    );
    final glow = 0.5 + 0.5 * math.sin(t * (1.1 + i % 3 * 0.35) + i * 2.1);
    final a = 0.15 + 0.75 * glow * glow;
    _light(c, p, 7 + glow * 7, const Color(0xFFE6FF6A).withValues(alpha: 0.5 * a));
    c.drawCircle(p, 1.2, _fill(const Color(0xFFFFF6B0).withValues(alpha: a)));
  }
  // The glowing mushrooms breathing.
  final m = Offset(s.width - 46, s.height - 34);
  _light(c, m, 40 + 8 * math.sin(t * 1.3), const Color(0xFF5AF0D0).withValues(alpha: 0.10 + 0.06 * math.sin(t * 1.3)));
  // Two leaves falling, turning as they go.
  for (var i = 0; i < 2; i++) {
    const fall = 14.0;
    final age = ((t + i * 7) % fall) / fall;
    final x = s.width * (0.3 + i * 0.4) + math.sin(t * 0.9 + i) * 34;
    final y = -20 + age * (s.height + 40);
    c.save();
    c.translate(x, y);
    c.scale(1, 0.55 + 0.45 * math.cos(t * 1.6 + i).abs());
    leafAt(c, Offset.zero, 13, t * 0.8 + i, math.Random(i + 3));
    c.restore();
  }
}

void _starshipLife(Canvas c, Size s, double t) {
  // Light running along the neon strips at the sides.
  for (var i = 0; i < 2; i++) {
    final x = i == 0 ? 5.0 : s.width - 5;
    final top = s.height * 0.14;
    final len = s.height * 0.72;
    final at = ((t * 0.22 + i * 0.5) % 1) * len + top;
    c.drawLine(Offset(x, math.max(top, at - 60)), Offset(x, at),
        Paint()
          ..shader = ui.Gradient.linear(Offset(x, at - 60), Offset(x, at), [_neon.withValues(alpha: 0), Colors.white.withValues(alpha: 0.9)])
          ..strokeWidth = 2.4);
    _light(c, Offset(x, at), 14, _neon.withValues(alpha: 0.6));
  }
  // A scan going down the screen now and then.
  final scan = (t % 9) / 9;
  if (scan < 0.6) {
    final y = scan / 0.6 * s.height;
    c.drawRect(
      Rect.fromLTRB(0, y - 40, s.width, y),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, y - 40), Offset(0, y), [_neon.withValues(alpha: 0), _neon.withValues(alpha: 0.06)]),
    );
    c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_neon.withValues(alpha: 0.18), 1)..strokeCap = StrokeCap.butt);
  }
  // The magenta strips at the foot breathing.
  const magenta = Color(0xFFFF3FD0);
  for (var i = 0; i < 3; i++) {
    final a = Offset(s.width * (0.2 + i * 0.22) + 20, s.height - 26);
    _light(c, a, 30, magenta.withValues(alpha: 0.12 + 0.1 * math.sin(t * 1.4 + i * 1.9)));
  }
  // Stars twinkling in the porthole.
  final centre = Offset(s.width + 4, s.height * 0.34);
  c.save();
  c.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: 74)));
  for (var i = 0; i < 9; i++) {
    final p = centre + Offset(-70 + (i * 37 % 60), -60 + (i * 53 % 120));
    final a = 0.5 + 0.5 * math.sin(t * (1.5 + i % 3) + i * 2.4);
    _light(c, p, 4, Colors.white.withValues(alpha: 0.6 * a));
  }
  c.restore();
  // Status lights blinking on a panel low on the left.
  for (var i = 0; i < 4; i++) {
    final on = math.sin(t * (2 + i * 0.7) + i * 1.3) > 0.2;
    if (!on) continue;
    final color = [const Color(0xFF39FF88), const Color(0xFFFFB13A), _neon, const Color(0xFFFF4A6A)][i];
    final p = Offset(22 + i * 9.0, s.height * 0.9);
    _light(c, p, 6, color.withValues(alpha: 0.6));
    c.drawCircle(p, 1.4, _fill(color));
  }
}

/// What an empty screen shows in [scene], [size] across.
class SceneEmptyArt extends StatelessWidget {
  const SceneEmptyArt(this.scene, {super.key, this.size = 92});

  final Scene scene;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(width: size, height: size, child: CustomPaint(painter: _EmptyPainter(scene))),
      );
}

class _EmptyPainter extends CustomPainter {
  const _EmptyPainter(this.scene);

  final Scene scene;

  @override
  void paint(Canvas c, Size s) {
    final m = Offset(s.width / 2, s.height / 2);
    switch (scene) {
      case Scene.dungeon:
        // A candle stub burning on a skull.
        _light(c, m + Offset(0, -s.height * 0.3), s.width * 0.6, const Color(0xFFFF8A2A).withValues(alpha: 0.35));
        skullAt(c, m + Offset(0, s.height * 0.18), s.width * 0.62);
        final top = m + Offset(0, -s.height * 0.08);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: top + const Offset(0, -6), width: 10, height: 18), const Radius.circular(2)),
            _fill(const Color(0xFFE6D8B8)));
        c.drawPath(
          Path()
            ..moveTo(top.dx - 5, top.dy + 1)
            ..quadraticBezierTo(top.dx - 9, top.dy + 8, top.dx - 4, top.dy + 10),
          _stroke(const Color(0xFFE6D8B8), 2.4),
        );
        final f = top + const Offset(0, -16);
        c.drawCircle(f + const Offset(0, -4), 8, _glow(const Color(0xFFFF8A20).withValues(alpha: 0.6), 6));
        c.drawPath(
          Path()
            ..moveTo(f.dx, f.dy - 14)
            ..quadraticBezierTo(f.dx + 6, f.dy - 4, f.dx, f.dy + 1)
            ..quadraticBezierTo(f.dx - 6, f.dy - 4, f.dx, f.dy - 14)
            ..close(),
          Paint()..shader = ui.Gradient.linear(Offset(f.dx, f.dy - 14), Offset(f.dx, f.dy), const [Color(0xFFFF6A10), Color(0xFFFFE6A0)]),
        );
      case Scene.forest:
        final r = math.Random(3);
        _light(c, m, s.width * 0.55, const Color(0xFF5AF0D0).withValues(alpha: 0.25));
        for (var i = 0; i < 3; i++) {
          final p = m + Offset((i - 1) * s.width * 0.2, s.height * 0.25 - (i == 1 ? 8 : 0));
          final k = s.width / 90 * (i == 1 ? 1.25 : 0.9);
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p + Offset(0, -8 * k), width: 7 * k, height: 18 * k), const Radius.circular(3)),
              _fill(const Color(0xFFCFC4A8)));
          c.drawPath(
            Path()
              ..moveTo(p.dx - 16 * k, p.dy - 16 * k)
              ..quadraticBezierTo(p.dx, p.dy - 42 * k, p.dx + 16 * k, p.dy - 16 * k)
              ..close(),
            _fill(const Color(0xFF2FB8A0)),
          );
        }
        for (var i = 0; i < 6; i++) {
          final p = Offset(r.nextDouble() * s.width, r.nextDouble() * s.height * 0.6);
          _light(c, p, 6, const Color(0xFFE6FF6A).withValues(alpha: 0.6));
          c.drawCircle(p, 1.2, _fill(const Color(0xFFFFF6B0)));
        }
      case Scene.starship:
        final r = math.Random(9);
        for (var i = 0; i < 30; i++) {
          c.drawCircle(Offset(r.nextDouble() * s.width, r.nextDouble() * s.height), r.nextDouble() * 0.9 + 0.3,
              _fill(Colors.white.withValues(alpha: 0.3 + r.nextDouble() * 0.5)));
        }
        final p = m + Offset(0, s.height * 0.05);
        c.drawCircle(p, s.width * 0.26,
            Paint()..shader = ui.Gradient.radial(p - Offset(s.width * 0.08, s.width * 0.08), s.width * 0.34, const [Color(0xFFFFCF8A), Color(0xFFD0622D), Color(0xFF3A1208)], const [0, 0.5, 1]));
        c.drawOval(Rect.fromCenter(center: p, width: s.width * 0.9, height: s.width * 0.16), _stroke(_neon.withValues(alpha: 0.8), 1.6));
    }
  }

  @override
  bool shouldRepaint(_EmptyPainter old) => old.scene != scene;
}

/// The drawer's crest (top) or foot ornament in [scene].
class SceneOrnament extends StatelessWidget {
  const SceneOrnament(this.scene, {super.key, required this.foot, this.width = 120, this.height = 120});

  final Scene scene;
  final bool foot;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: SizedBox(width: width, height: height, child: CustomPaint(painter: _OrnamentPainter(scene, foot))),
        ),
      );
}

class _OrnamentPainter extends CustomPainter {
  const _OrnamentPainter(this.scene, this.foot);

  final Scene scene;
  final bool foot;

  @override
  void paint(Canvas c, Size s) {
    final r = math.Random(foot ? 2 : 1);
    switch ((scene, foot)) {
      case (Scene.dungeon, false):
        // Crossed bones behind a skull.
        final m = Offset(s.width / 2, s.height / 2);
        for (final (a, b) in [
          (m + Offset(-s.width * 0.36, -s.height * 0.3), m + Offset(s.width * 0.36, s.height * 0.3)),
          (m + Offset(s.width * 0.36, -s.height * 0.3), m + Offset(-s.width * 0.36, s.height * 0.3)),
        ]) {
          c.drawLine(a, b, _stroke(const Color(0xFF8F7D5C), 5));
          for (final e in [a, b]) {
            c.drawCircle(e + const Offset(2.5, 2.5), 3.6, _fill(const Color(0xFF9E8C68)));
            c.drawCircle(e - const Offset(2.5, 2.5), 3.6, _fill(const Color(0xFF8F7D5C)));
          }
        }
        skullAt(c, m, s.width * 0.55, cracked: true);
      case (Scene.dungeon, true):
        // A rotting hand reaching up from the rubble, by a candle stub.
        final base = Offset(s.width * 0.42, s.height);
        final hand = Paint()
          ..shader = ui.Gradient.linear(base, base - Offset(0, s.height * 0.8), const [Color(0xFF2A3420), Color(0xFF5A6A40), Color(0xFF7A8058)], const [0, 0.5, 1]);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(base.dx - 9, base.dy - s.height * 0.45, 18, s.height * 0.45), const Radius.circular(6)), hand);
        final palm = base - Offset(0, s.height * 0.5);
        c.drawOval(Rect.fromCenter(center: palm, width: 30, height: 26), hand);
        for (var i = 0; i < 4; i++) {
          final a = -math.pi / 2 + (i - 1.5) * 0.32;
          final len = s.height * (i == 1 || i == 2 ? 0.3 : 0.24);
          final tip = palm + Offset(math.cos(a), math.sin(a)) * len;
          c.drawLine(palm + Offset((i - 1.5) * 6, -6), tip, _stroke(const Color(0xFF66704A), 5.2));
          c.drawCircle(tip, 2, _fill(const Color(0xFF2A2018)));
        }
        c.drawLine(palm + const Offset(-12, 4), palm + const Offset(-26, -10), _stroke(const Color(0xFF66704A), 5.2));
        // Rot and a torn sleeve.
        c.drawCircle(palm + const Offset(4, 4), 3, _fill(const Color(0xFF2A2214)));
        c.drawPath(
          Path()
            ..moveTo(base.dx - 13, base.dy - s.height * 0.2)
            ..lineTo(base.dx + 13, base.dy - s.height * 0.24)
            ..lineTo(base.dx + 13, base.dy)
            ..lineTo(base.dx - 13, base.dy)
            ..close(),
          _fill(const Color(0xFF241A14)),
        );
        // The candle.
        final cnd = Offset(s.width * 0.82, s.height);
        c.drawRect(Rect.fromLTWH(cnd.dx - 5, cnd.dy - 26, 10, 26), _fill(const Color(0xFFE6D8B8)));
        _light(c, cnd - const Offset(0, 34), 36, const Color(0xFFFF8A2A).withValues(alpha: 0.3));
        c.drawPath(
          Path()
            ..moveTo(cnd.dx, cnd.dy - 42)
            ..quadraticBezierTo(cnd.dx + 5, cnd.dy - 33, cnd.dx, cnd.dy - 28)
            ..quadraticBezierTo(cnd.dx - 5, cnd.dy - 33, cnd.dx, cnd.dy - 42)
            ..close(),
          _fill(const Color(0xFFFFC060)),
        );
      case (Scene.forest, false):
        final m = Offset(s.width / 2, s.height / 2);
        for (var i = 0; i < 14; i++) {
          final a = i / 14 * math.pi * 2;
          leafAt(c, m + Offset(math.cos(a), math.sin(a)) * s.width * 0.3, s.width * 0.16, a + math.pi / 2, r);
        }
        _light(c, m, s.width * 0.2, const Color(0xFFE6FF6A).withValues(alpha: 0.6));
        c.drawCircle(m, 2.4, _fill(const Color(0xFFFFF6B0)));
      case (Scene.forest, true):
        final rr = math.Random(4);
        final base = Offset(s.width * 0.3, s.height);
        for (var i = 0; i < 3; i++) {
          final p = base + Offset(i * 22.0, -i * 2.0);
          _light(c, p - const Offset(0, 16), 26, const Color(0xFF5AF0D0).withValues(alpha: 0.3));
          c.drawRect(Rect.fromLTWH(p.dx - 3, p.dy - 16, 6, 16), _fill(const Color(0xFFCFC4A8)));
          c.drawPath(
            Path()
              ..moveTo(p.dx - 14, p.dy - 14)
              ..quadraticBezierTo(p.dx, p.dy - 38, p.dx + 14, p.dy - 14)
              ..close(),
            _fill(const Color(0xFF2FB8A0)),
          );
        }
        for (var i = 0; i < 5; i++) {
          final p = Offset(rr.nextDouble() * s.width, rr.nextDouble() * s.height * 0.6);
          _light(c, p, 6, const Color(0xFFE6FF6A).withValues(alpha: 0.6));
        }
      case (Scene.starship, false):
        final m = Offset(s.width / 2, s.height / 2);
        final hex = Path();
        for (var i = 0; i < 6; i++) {
          final a = i / 6 * math.pi * 2 - math.pi / 2;
          final p = m + Offset(math.cos(a), math.sin(a)) * s.width * 0.34;
          i == 0 ? hex.moveTo(p.dx, p.dy) : hex.lineTo(p.dx, p.dy);
        }
        hex.close();
        c.drawPath(hex, _glow(_neon.withValues(alpha: 0.5), 5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4);
        c.drawPath(hex, _stroke(const Color(0xFF9FF6FF), 1.6)..strokeJoin = StrokeJoin.miter);
        c.drawCircle(m, s.width * 0.1, _fill(_neon.withValues(alpha: 0.8)));
      case (Scene.starship, true):
        for (var i = 0; i < 8; i++) {
          final color = [const Color(0xFF39FF88), const Color(0xFFFFB13A), _neon, const Color(0xFFFF4A6A)][r.nextInt(4)];
          final p = Offset(s.width * (0.1 + i * 0.11), s.height - 14);
          _light(c, p, 8, color.withValues(alpha: 0.5));
          c.drawRect(Rect.fromCenter(center: p, width: 5, height: 3), _fill(color));
        }
        c.drawLine(Offset(0, s.height - 30), Offset(s.width, s.height - 30), _glow(const Color(0xFFFF3FD0).withValues(alpha: 0.5), 4)..strokeWidth = 3);
        c.drawLine(Offset(0, s.height - 30), Offset(s.width, s.height - 30), _stroke(const Color(0xFFFFA8EC), 1));
    }
  }

  @override
  bool shouldRepaint(_OrnamentPainter old) => old.scene != scene || old.foot != foot;
}

/// A rule between groups: a line of runes in the dungeon, a vine in the
/// forest, a neon rule on the starship.
class SceneDivider extends StatelessWidget {
  const SceneDivider(this.scene, {super.key});

  final Scene scene;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(height: 12, width: double.infinity, child: CustomPaint(painter: _DividerPainter(scene))),
      );
}

class _DividerPainter extends CustomPainter {
  const _DividerPainter(this.scene);

  final Scene scene;

  @override
  void paint(Canvas c, Size s) {
    final y = s.height / 2;
    switch (scene) {
      case Scene.dungeon:
        final rune = _stroke(const Color(0xFF8A6A4A).withValues(alpha: 0.55), 1.1);
        c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(const Color(0xFF3E2E22), 1));
        final r = math.Random(12);
        for (var x = 10.0; x < s.width - 10; x += 26) {
          c.drawRect(Rect.fromCenter(center: Offset(x, y), width: 9, height: 10), _fill(const Color(0xFF15100C)));
          final kind = r.nextInt(4);
          final p = Offset(x, y);
          switch (kind) {
            case 0:
              c.drawLine(p + const Offset(0, -4), p + const Offset(0, 4), rune);
              c.drawLine(p + const Offset(0, -4), p + const Offset(3, -1), rune);
            case 1:
              c.drawLine(p + const Offset(-3, 4), p + const Offset(0, -4), rune);
              c.drawLine(p + const Offset(0, -4), p + const Offset(3, 4), rune);
            case 2:
              c.drawLine(p + const Offset(-3, -4), p + const Offset(3, 4), rune);
              c.drawLine(p + const Offset(3, -4), p + const Offset(-3, 4), rune);
            default:
              c.drawLine(p + const Offset(0, -4), p + const Offset(0, 4), rune);
              c.drawLine(p + const Offset(-3, 0), p + const Offset(3, -3), rune);
          }
        }
      case Scene.forest:
        final r = math.Random(8);
        final path = Path()..moveTo(0, y);
        for (var x = 0.0; x <= s.width; x += 6) {
          path.lineTo(x, y + math.sin(x / 14) * 2);
        }
        c.drawPath(path, _stroke(const Color(0xFF2E5A2E), 1.4));
        for (var x = 16.0; x < s.width; x += 34) {
          leafAt(c, Offset(x, y + math.sin(x / 14) * 2), 7, (x ~/ 34).isEven ? -0.6 : 0.6, r);
        }
      case Scene.starship:
        c.drawLine(Offset(0, y), Offset(s.width, y), _glow(_neon.withValues(alpha: 0.35), 3)..strokeWidth = 2);
        c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_neon.withValues(alpha: 0.6), 0.8)..strokeCap = StrokeCap.butt);
    }
  }

  @override
  bool shouldRepaint(_DividerPainter old) => old.scene != scene;
}

/// A small picture of [scene]'s backdrop, for its preview in Settings.
class ScenePreview extends StatelessWidget {
  const ScenePreview(this.scene, {super.key});

  final Scene scene;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          // The whole phone screen's art, drawn small.
          const phone = Size(412, 915);
          final image = sceneImages ? sceneBackdrop(scene, phone, math.min(dpr, 1.0) * 0.6) : null;
          return image == null
              ? CustomPaint(
                  painter: _PreviewPainter(scene),
                  size: Size(box.maxWidth, box.maxHeight.isFinite ? box.maxHeight : 150),
                )
              : RawImage(image: image, fit: BoxFit.cover, alignment: Alignment.topCenter);
        },
      );
}

class _PreviewPainter extends CustomPainter {
  const _PreviewPainter(this.scene);

  final Scene scene;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final k = size.width / 412;
    canvas.scale(k);
    paintBackdrop(canvas, Size(412, size.height / k), scene);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.scene != scene;
}
