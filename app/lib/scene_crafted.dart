part of 'scene.dart';

// Scenes whose controls are made of their own material, not their kin's:
// the buttons, the panels, the covers' frames, the edges of sheets, dialogs,
// menus and the drawer, and the slider's knob. Black rose: dark glass with
// chrome rims and silver filigree. Dragon slate: chiselled slate with a worn,
// chipped silver edge. Old tome: tooled leather, gilt rules and brass corners.

/// The scenes with controls of their own.
const craftedScenes = {Scene.blackRose, Scene.dragonSlate, Scene.oldTome};

/// Whether [scene] has controls of its own.
bool isCrafted(Scene? scene) => scene != null && craftedScenes.contains(scene);

const _chrome = [Color(0xFFF2F5FF), Color(0xFF6A7392), Color(0xFFE4E9F6), Color(0xFF3E445A)];
const _silverWorn = Color(0xFFC9C7C0);
const _gilt = Color(0xFFD2AA5C);
const _brass = [Color(0xFFE6C27A), Color(0xFFA87C34), Color(0xFF5E4018)];

// ---------------------------------------------------------------------------
// Buttons.

/// [rect] as a button of [scene] in [fill]; false when [scene] has none of
/// its own (its kin's is drawn).
bool _craftedButton(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  if (!isCrafted(scene) || rect.isEmpty) return false;
  final rr = radius.toRRect(rect);
  final path = Path()..addRRect(rr);
  final bright = fill.computeLuminance() > 0.12;
  if (scene == Scene.blackRose) {
    // Dark glass, lit from above, in a chrome rim.
    if (bright) c.drawRRect(rr, _glow(fill.withValues(alpha: 0.45), 6));
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.radial(Offset(rect.center.dx, rect.top + rect.height * 0.35), rect.longestSide * 0.75, [
          Color.lerp(fill, Colors.white, bright ? 0.16 : 0.08)!,
          Color.lerp(fill, Colors.black, bright ? 0.25 : 0.45)!,
          Color.lerp(fill, Colors.black, 0.8)!,
        ], const [
          0,
          0.6,
          1,
        ]),
    );
    c.save();
    c.clipRRect(rr);
    final sheen = Rect.fromLTRB(rect.left + rect.width * 0.12, rect.top + 1.5, rect.right - rect.width * 0.12, rect.top + rect.height * 0.48);
    c.drawOval(
      sheen,
      Paint()
        ..shader = ui.Gradient.linear(sheen.topCenter, sheen.bottomCenter,
            [Colors.white.withValues(alpha: bright ? 0.34 : 0.22), Colors.white.withValues(alpha: 0)]),
    );
    c.restore();
    c.drawRRect(
      rr.deflate(0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _chrome, const [0, 0.4, 0.62, 1]),
    );
    c.drawRRect(rr.deflate(2.2), _stroke(Colors.black.withValues(alpha: 0.55), 0.8));
    return true;
  }
  if (scene == Scene.dragonSlate) {
    // Slate, chiselled: lit along its top, sunk along its foot, a worn
    // silver edge chipped here and there.
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          Color.lerp(fill, Colors.white, bright ? 0.14 : 0.07)!,
          fill,
          Color.lerp(fill, Colors.black, bright ? 0.35 : 0.5)!,
        ], const [
          0,
          0.5,
          1,
        ]),
    );
    c.save();
    c.clipPath(path);
    final r = math.Random((rect.width * 11 + rect.height).round());
    for (var i = 0; i < (rect.width * rect.height / 120).clamp(4, 50); i++) {
      c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
          0.4 + r.nextDouble() * 0.9, _fill(Colors.black.withValues(alpha: bright ? 0.18 : 0.35)));
    }
    if (bright) {
      // An ember's heat inside.
      c.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(rect.center, rect.longestSide * 0.6,
              [const Color(0xFFFFB050).withValues(alpha: 0.35), const Color(0xFFFF7A1A).withValues(alpha: 0)]),
      );
    }
    c.drawPath(path.shift(const Offset(0, 1.2)), _stroke(Colors.white.withValues(alpha: bright ? 0.28 : 0.12), 1.1));
    c.drawPath(path.shift(const Offset(0, -1.4)), _stroke(Colors.black.withValues(alpha: 0.5), 1.4));
    c.restore();
    _chipped(c, path, _silverWorn.withValues(alpha: bright ? 0.7 : 0.5), 1.0, (rect.width + rect.height).round());
    return true;
  }
  // Old tome: leather (or gilt, when it is the accent), a tooled rule and
  // stitches round it.
  final leather = bright ? fill : Color.lerp(fill, const Color(0xFF3A2412), 0.6)!;
  c.drawRRect(
    rr,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
        Color.lerp(leather, Colors.white, bright ? 0.2 : 0.06)!,
        leather,
        Color.lerp(leather, Colors.black, 0.45)!,
      ], const [
        0,
        0.45,
        1,
      ]),
  );
  c.save();
  c.clipPath(path);
  final r = math.Random((rect.width * 13 + rect.height).round());
  for (var i = 0; i < (rect.width * rect.height / 60).clamp(6, 90); i++) {
    c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
        0.3 + r.nextDouble() * 0.6, _fill(Colors.black.withValues(alpha: bright ? 0.12 : 0.25)));
  }
  c.restore();
  if (rect.shortestSide > 14) {
    final inset = rr.deflate(math.min(3.0, rect.shortestSide * 0.1));
    c.drawRRect(inset, _stroke((bright ? const Color(0xFF5A3A10) : _gilt).withValues(alpha: 0.7), 0.9));
    if (rect.shortestSide > 26) {
      _dashed(c, Path()..addRRect(rr.deflate(math.min(5.5, rect.shortestSide * 0.18))),
          (bright ? const Color(0xFF5A3A10) : _gilt).withValues(alpha: 0.4), 0.7, 2.5, 2.5);
    }
  }
  c.drawRRect(rr, _stroke(Colors.black.withValues(alpha: 0.6), 1.2));
  return true;
}

// ---------------------------------------------------------------------------
// Panels and edges.

/// [rect] as a panel of [scene] (the player, a card, a bar); false when
/// [scene] has none of its own.
bool _craftedPanel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (!isCrafted(scene) || rect.isEmpty) return false;
  final rr = corners.toRRect(rect);
  if (scene == Scene.blackRose) {
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter,
            [const Color(0xEB1A1F33), const Color(0xF00E1120), const Color(0xF2080A13)], const [0, 0.5, 1]),
    );
    c.save();
    c.clipRRect(rr);
    final top = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + math.min(rect.height * 0.4, 60));
    c.drawRect(
      top,
      Paint()
        ..shader = ui.Gradient.linear(top.topCenter, top.bottomCenter,
            [Colors.white.withValues(alpha: lit ? 0.09 : 0.06), Colors.white.withValues(alpha: 0)]),
    );
    c.restore();
  } else if (scene == Scene.dragonSlate) {
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter,
            [lit ? const Color(0xF2292A2E) : const Color(0xF2222326), const Color(0xF417181A), const Color(0xF6101113)], const [0, 0.5, 1]),
    );
    c.save();
    c.clipRRect(rr);
    final r = math.Random((rect.width * 17 + rect.height).round());
    for (var i = 0; i < (rect.width * rect.height / 700).clamp(5, 80); i++) {
      c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
          0.5 + r.nextDouble() * 1.1, _fill(Colors.black.withValues(alpha: 0.32)));
    }
    if (rect.height > 30) {
      final from = Offset(rect.left + rect.width * (0.55 + r.nextDouble() * 0.4), rect.top);
      c.drawPath(_jagged(r, from, from + Offset(-14 - r.nextDouble() * 24, math.min(rect.height * 0.6, 48)), steps: 6, wobble: 3),
          _stroke(Colors.black.withValues(alpha: 0.65), 1));
    }
    if (lit) {
      final foot = Rect.fromLTRB(rect.left, rect.bottom - math.min(rect.height * 0.5, 30), rect.right, rect.bottom);
      c.drawRect(
        foot,
        Paint()
          ..shader = ui.Gradient.linear(foot.topCenter, foot.bottomCenter,
              [const Color(0xFFFF7A1A).withValues(alpha: 0), const Color(0xFFFF7A1A).withValues(alpha: 0.12)]),
      );
    }
    c.drawLine(Offset(rect.left + 6, rect.top + 1.2), Offset(rect.right - 6, rect.top + 1.2),
        _stroke(Colors.white.withValues(alpha: 0.1), 1.2));
    c.restore();
  } else {
    c.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight,
            [lit ? const Color(0xF23A2412) : const Color(0xF2321F0F), const Color(0xF4241509), const Color(0xF6170D05)], const [0, 0.5, 1]),
    );
    c.save();
    c.clipRRect(rr);
    final r = math.Random((rect.width * 19 + rect.height).round());
    for (var i = 0; i < (rect.width * rect.height / 260).clamp(8, 160); i++) {
      c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
          0.35 + r.nextDouble() * 0.7, _fill(Colors.black.withValues(alpha: 0.28)));
    }
    // Scuffs, worn pale.
    for (var i = 0; i < (rect.width / 90).clamp(1, 5); i++) {
      final a = Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height);
      c.drawLine(a, a + Offset(8 + r.nextDouble() * 18, (r.nextDouble() - 0.5) * 6), _stroke(const Color(0xFFE8C9A0).withValues(alpha: 0.05), 1));
    }
    c.restore();
  }
  paintSceneEdge(c, rect, scene, corners, lit: lit);
  return true;
}

/// The edge of something of [scene]'s at [rect]: a panel's, a sheet's, a
/// dialog's, a menu's, a cover's. Nothing for a scene without its own.
void paintSceneEdge(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (!isCrafted(scene) || rect.width < 8 || rect.height < 8) return;
  final rr = corners.toRRect(rect);
  if (scene == Scene.blackRose) {
    final silver = const Color(0xFFDDE4F4).withValues(alpha: lit ? 0.7 : 0.5);
    c.drawRRect(rr.deflate(0.6), _stroke(silver, 1));
    if (rect.shortestSide > 30) {
      c.drawRRect(rr.deflate(3.6), _stroke(silver.withValues(alpha: 0.2), 0.6));
      // Filigree in each corner: two scrolls and a bead.
      final k = math.min(14.0, rect.shortestSide * 0.22);
      final inset = math.max(5.0, corners.topLeft.x * 0.45);
      for (final (p, dx, dy) in [
        (rect.topLeft + Offset(inset, inset), 1.0, 1.0),
        (rect.topRight + Offset(-inset, inset), -1.0, 1.0),
        (rect.bottomLeft + Offset(inset, -inset), 1.0, -1.0),
        (rect.bottomRight + Offset(-inset, -inset), -1.0, -1.0),
      ]) {
        _scroll(c, p, k, dx, dy, silver);
      }
      if (rect.width > 180) {
        // A small jewel at the top's middle, scrolls either side.
        final m = Offset(rect.center.dx, rect.top + 0.6);
        final d = Path()
          ..moveTo(m.dx, m.dy - 3.5)
          ..lineTo(m.dx + 3.5, m.dy)
          ..lineTo(m.dx, m.dy + 3.5)
          ..lineTo(m.dx - 3.5, m.dy)
          ..close();
        c.drawPath(d, _fill(const Color(0xFF0E1120)));
        c.drawPath(d, _stroke(silver, 0.9));
        for (final side in [-1.0, 1.0]) {
          c.drawPath(
            Path()
              ..moveTo(m.dx + side * 5, m.dy)
              ..cubicTo(m.dx + side * 12, m.dy - 4, m.dx + side * 18, m.dy + 3, m.dx + side * 26, m.dy),
            _stroke(silver, 0.8),
          );
        }
      }
    }
  } else if (scene == Scene.dragonSlate) {
    _chipped(c, Path()..addRRect(rr.deflate(0.6)), _silverWorn.withValues(alpha: lit ? 0.6 : 0.42), 1.1,
        (rect.width * 3 + rect.height).round());
    if (rect.shortestSide > 30) {
      // Carved notches at the corners.
      final k = math.min(9.0, rect.shortestSide * 0.16);
      final inset = math.max(4.0, corners.topLeft.x * 0.4);
      for (final (p, dx, dy) in [
        (rect.topLeft + Offset(inset, inset), 1.0, 1.0),
        (rect.topRight + Offset(-inset, inset), -1.0, 1.0),
        (rect.bottomLeft + Offset(inset, -inset), 1.0, -1.0),
        (rect.bottomRight + Offset(-inset, -inset), -1.0, -1.0),
      ]) {
        c.drawLine(p, p + Offset(k * dx, 0), _stroke(_silverWorn.withValues(alpha: 0.35), 0.9));
        c.drawLine(p, p + Offset(0, k * dy), _stroke(_silverWorn.withValues(alpha: 0.35), 0.9));
      }
    }
  } else {
    c.drawRRect(rr.deflate(0.6), _stroke(Colors.black.withValues(alpha: 0.6), 1.2));
    if (rect.shortestSide > 20) {
      c.drawRRect(rr.deflate(3), _stroke(_gilt.withValues(alpha: lit ? 0.8 : 0.62), 1));
    }
    if (rect.shortestSide > 34) {
      c.drawRRect(rr.deflate(6), _stroke(_gilt.withValues(alpha: 0.32), 0.6));
      // Brass corners.
      final k = math.min(16.0, rect.shortestSide * 0.22);
      for (final (p, dx, dy) in [
        (rect.topLeft, 1.0, 1.0),
        (rect.topRight, -1.0, 1.0),
        (rect.bottomLeft, 1.0, -1.0),
        (rect.bottomRight, -1.0, -1.0),
      ]) {
        final o = p + Offset(dx * 1.5, dy * 1.5);
        final tri = Path()
          ..moveTo(o.dx, o.dy)
          ..lineTo(o.dx + k * dx, o.dy)
          ..quadraticBezierTo(o.dx + k * 0.45 * dx, o.dy + k * 0.45 * dy, o.dx, o.dy + k * dy)
          ..close();
        c.drawPath(
          tri,
          Paint()..shader = ui.Gradient.linear(o, o + Offset(k * dx, k * dy), _brass, const [0, 0.55, 1]),
        );
        c.drawPath(tri, _stroke(Colors.black.withValues(alpha: 0.5), 0.7));
        c.drawCircle(o + Offset(k * 0.28 * dx, k * 0.28 * dy), 1.2, _fill(const Color(0xFFFFE6B0).withValues(alpha: 0.8)));
      }
    }
  }
}

/// A silver scroll at [p], [k] long, curling in towards ([dx], [dy]).
void _scroll(Canvas c, Offset p, double k, double dx, double dy, Color color) {
  final s = _stroke(color, 0.9);
  c.drawPath(
    Path()
      ..moveTo(p.dx + k * dx, p.dy)
      ..cubicTo(p.dx + k * 0.4 * dx, p.dy - k * 0.1 * dy, p.dx + k * 0.1 * dx, p.dy + k * 0.2 * dy, p.dx + k * 0.3 * dx, p.dy + k * 0.35 * dy),
    s,
  );
  c.drawPath(
    Path()
      ..moveTo(p.dx, p.dy + k * dy)
      ..cubicTo(p.dx - k * 0.1 * dx, p.dy + k * 0.4 * dy, p.dx + k * 0.2 * dx, p.dy + k * 0.1 * dy, p.dx + k * 0.35 * dx, p.dy + k * 0.3 * dy),
    s,
  );
  c.drawCircle(p + Offset(k * 0.33 * dx, k * 0.33 * dy), 1.1, _fill(color));
}

/// [path] stroked in short worn runs with chips between them.
void _chipped(Canvas c, Path path, Color color, double width, int seed) {
  final r = math.Random(seed);
  final paint = _stroke(color, width);
  for (final m in path.computeMetrics()) {
    var d = 0.0;
    while (d < m.length) {
      final run = 10 + r.nextDouble() * 34;
      c.drawPath(m.extractPath(d, math.min(m.length, d + run)), paint);
      d += run + 1 + r.nextDouble() * (r.nextDouble() < 0.2 ? 6 : 2);
    }
  }
}

/// [path] in dashes [on] long, [off] apart: stitches.
void _dashed(Canvas c, Path path, Color color, double width, double on, double off) {
  final paint = _stroke(color, width)..strokeCap = StrokeCap.butt;
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += on + off) {
      c.drawPath(m.extractPath(d, math.min(m.length, d + on)), paint);
    }
  }
}

/// A cover's frame in [scene]: its edge, at the cover's corners.
bool _craftedCoverFrame(Canvas c, Rect rect, Scene scene, double radius) {
  if (!isCrafted(scene)) return false;
  paintSceneEdge(c, rect, scene, BorderRadius.circular(radius));
  return true;
}

// ---------------------------------------------------------------------------
// The edges of sheets, dialogs, menus and the drawer.

/// A rounded shape with [scene]'s edge drawn on it: what a sheet, a
/// dialog, a menu or the drawer is cut to in a scene with its own controls.
class SceneEdge extends OutlinedBorder {
  const SceneEdge(this.scene, {this.borderRadius = BorderRadius.zero, super.side});

  final Scene scene;
  final BorderRadiusGeometry borderRadius;

  RoundedRectangleBorder get _base => RoundedRectangleBorder(borderRadius: borderRadius, side: side);

  @override
  EdgeInsetsGeometry get dimensions => _base.dimensions;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _base.getInnerPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _base.getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      paintSceneEdge(canvas, rect, scene, borderRadius.resolve(textDirection));

  @override
  SceneEdge copyWith({BorderSide? side}) => SceneEdge(scene, borderRadius: borderRadius, side: side ?? this.side);

  @override
  ShapeBorder scale(double t) => SceneEdge(scene, borderRadius: borderRadius * t, side: side.scale(t));

  @override
  bool operator ==(Object other) =>
      other is SceneEdge && other.scene == scene && other.borderRadius == borderRadius && other.side == side;

  @override
  int get hashCode => Object.hash(scene, borderRadius, side);
}

// ---------------------------------------------------------------------------
// The slider's knob.

/// A slider's knob in [scene]: a glass orb in a chrome rim, a slate disc
/// with an ember at its heart, a brass stud. It swells a little while held.
class SceneKnobShape extends SliderComponentShape {
  const SceneKnobShape(this.scene, {this.radius = 10});

  final Scene scene;
  final double radius;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius + 4);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final c = context.canvas;
    final r = radius + 2 * activationAnimation.value;
    final colour = sliderTheme.thumbColor ?? Colors.white;
    c.drawCircle(center + const Offset(0, 1.5), r, _glow(Colors.black.withValues(alpha: 0.5), 3));
    final disc = Rect.fromCircle(center: center, radius: r);
    if (scene == Scene.blackRose) {
      c.drawCircle(center, r + 3, _glow(colour.withValues(alpha: 0.35), 5));
      c.drawCircle(
        center,
        r,
        Paint()
          ..shader = ui.Gradient.radial(center - Offset(0, r * 0.35), r * 1.2,
              [Colors.white.withValues(alpha: 0.9), Color.lerp(colour, Colors.black, 0.2)!, Color.lerp(colour, Colors.black, 0.75)!], const [0, 0.45, 1]),
      );
      c.drawCircle(
        center,
        r - 0.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..shader = ui.Gradient.linear(disc.topLeft, disc.bottomRight, _chrome, const [0, 0.4, 0.62, 1]),
      );
    } else if (scene == Scene.dragonSlate) {
      c.drawCircle(
        center,
        r,
        Paint()..shader = ui.Gradient.linear(disc.topCenter, disc.bottomCenter, [const Color(0xFF3A3B3F), const Color(0xFF17181A)]),
      );
      c.drawCircle(center, r * 0.42, _glow(colour.withValues(alpha: 0.9), 2.5));
      c.drawCircle(center, r * 0.22, _fill(Color.lerp(colour, Colors.white, 0.5)!));
      _chipped(c, Path()..addOval(disc.deflate(0.6)), _silverWorn.withValues(alpha: 0.7), 1.1, 7);
    } else {
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center - Offset(r * 0.3, r * 0.35), r * 1.3, _brass, const [0, 0.55, 1]));
      c.drawCircle(center, r - 0.6, _stroke(Colors.black.withValues(alpha: 0.55), 1));
      c.drawCircle(center, r * 0.55, _stroke(const Color(0xFFFFE6B0).withValues(alpha: 0.45), 0.8));
      c.drawCircle(center - Offset(r * 0.3, r * 0.35), r * 0.18, _fill(Colors.white.withValues(alpha: 0.55)));
    }
  }
}

/// A filled button's ground in a scene: drawn as the scene's buttons are.
class SceneFillPainter extends CustomPainter {
  const SceneFillPainter(this.scene, this.fill);

  final Scene scene;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) =>
      paintButton(canvas, Offset.zero & size, scene, fill, BorderRadius.circular(size.height / 2));

  @override
  bool shouldRepaint(SceneFillPainter old) => old.scene != scene || old.fill != fill;
}
