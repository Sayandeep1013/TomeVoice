import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'scene.dart';
import 'theme.dart';

/// The TomeVoice mark: an open page whose spine is a line of light, and the
/// sound coming off it.
///
/// Drawn in the colours of the theme in use (its deepest ground for the
/// tile, its ink for the page and the sound, its accent for the spine), so
/// it changes with the theme; in a scene it is edged in the place's
/// material. In the Forest theme it is the app's icon as it always was.
/// Used in chrome only; never as the text being read.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = Skin.paletteOf(context);
    final dark = Skin.isDark(context);
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: BrandPainter(
            tile: dark ? p.nightSheet : Skin.dark,
            tileTop: dark ? p.night[0] : Skin.darkSoft,
            ink: dark ? p.nightInk : p.day[2],
            accent: p.accent,
            scene: p.scene,
          ),
        ),
      ),
    );
  }
}

/// The mark at any size, from its colours: [tile] its ground ([tileTop] at
/// the top), [ink] the page and the sound, [accent] the spine.
class BrandPainter extends CustomPainter {
  const BrandPainter({required this.tile, required this.tileTop, required this.ink, required this.accent, this.scene});

  final Color tile;
  final Color tileTop;
  final Color ink;
  final Color accent;
  final Scene? scene;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 512 square, as the icon was.
    final k = size.width / 512;
    canvas.save();
    canvas.scale(k);
    const box = Rect.fromLTWH(0, 0, 512, 512);
    final corner = scene?.kin == Scene.solar ? 40.0 : 112.0;
    final shape = scene?.kin == Scene.solar ? _cut(box, 92) : (Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(corner))));
    canvas.drawPath(
      shape,
      Paint()
        ..shader = ui.Gradient.linear(box.topCenter, box.bottomCenter, [
          Color.lerp(tileTop, tile, 0.35)!,
          tile,
        ]),
    );
    canvas.save();
    canvas.clipPath(shape);
    _edge(canvas, box, shape);

    // The page, its top and foot curling, and its lines.
    final page = Path()
      ..moveTo(92, 128)
      ..cubicTo(150, 122, 205, 128, 246, 146)
      ..lineTo(246, 384)
      ..cubicTo(205, 368, 150, 362, 92, 368)
      ..close();
    canvas.drawPath(page, Paint()..color = ink);
    final line = Paint()
      ..color = tile
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final y = 190.0 + i * 33;
      canvas.drawLine(Offset(128, y), Offset(i == 4 ? 168 : 216, y), line);
    }

    // The spine: the accent, with its own light round it.
    final spine = RRect.fromLTRBR(244, 138, 262, 386, const Radius.circular(9));
    canvas.drawRRect(
      spine.inflate(10),
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawRRect(spine, Paint()..color = accent);

    // The sound.
    final bar = Paint()
      ..color = ink
      ..strokeWidth = 19
      ..strokeCap = StrokeCap.round;
    for (final (x, top, foot) in const [
      (285.0, 160.0, 352.0),
      (318.0, 188.0, 328.0),
      (352.0, 154.0, 326.0),
      (385.0, 192.0, 282.0),
      (416.0, 176.0, 300.0),
    ]) {
      canvas.drawLine(Offset(x, top), Offset(x, foot), bar);
    }
    canvas.restore();
    canvas.restore();
  }

  /// The solar scene's tile, a hull plate: a square with two corners cut.
  static Path _cut(Rect r, double c) => Path()
    ..moveTo(r.left + c, r.top)
    ..lineTo(r.right, r.top)
    ..lineTo(r.right, r.bottom - c)
    ..lineTo(r.right - c, r.bottom)
    ..lineTo(r.left, r.bottom)
    ..lineTo(r.left, r.top + c)
    ..close();

  /// The scene's rim round the tile.
  void _edge(Canvas c, Rect box, Path shape) {
    switch (scene?.kin) {
      case null:
        return;
      case Scene.dungeon:
        // Rusted iron with four rivets.
        c.drawPath(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 30
            ..shader = ui.Gradient.linear(box.topLeft, box.bottomRight,
                [sceneInk(scene!, const Color(0xFF3A1D0E)), sceneInk(scene!, const Color(0xFF8A4A24)), sceneInk(scene!, const Color(0xFF4A2412)), sceneInk(scene!, const Color(0xFF7A3E1C))], const [0, 0.35, 0.65, 1]),
        );
        for (final p in const [Offset(58, 58), Offset(454, 58), Offset(58, 454), Offset(454, 454)]) {
          c.drawCircle(p, 14,
              Paint()..shader = ui.Gradient.radial(p - const Offset(4, 4), 16, [sceneInk(scene!, const Color(0xFFD08A4C)), sceneInk(scene!, const Color(0xFF6A3416)), sceneInk(scene!, const Color(0xFF140804))], const [0, 0.45, 1]));
        }
      case Scene.forest:
        // Bark and moss.
        c.drawPath(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 26
            ..shader = ui.Gradient.linear(box.topLeft, box.bottomRight,
                [sceneInk(scene!, const Color(0xFF5E3B1F)), sceneInk(scene!, const Color(0xFF2E5A2E)), sceneInk(scene!, const Color(0xFF3A2414)), sceneInk(scene!, const Color(0xFF3F8A42))], const [0, 0.4, 0.7, 1]),
        );
      default:
        // A neon line inside the hull.
        c.drawPath(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 22
            ..color = sceneInk(scene!, const Color(0xFF3FE0F0)).withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
        c.drawPath(
          shape,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..color = sceneInk(scene!, const Color(0xFF9FF6FF)),
        );
    }
  }

  @override
  bool shouldRepaint(BrandPainter old) =>
      old.tile != tile || old.tileTop != tileTop || old.ink != ink || old.accent != accent || old.scene != scene;
}

/// Mark plus the quiet wordmark. Shared by library and reader so the two
/// surfaces read as one product.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: compact ? 22 : 28),
        const SizedBox(width: 10),
        Text(
          'TomeVoice',
          style: Skin.heading(context, size: compact ? 16 : 20),
        ),
      ],
    );
  }
}
