part of 'scene.dart';

// What every scene makes its controls of, beyond its backdrop: the edges of
// sheets, dialogs, menus, cards and the drawer (each scene its own: vines,
// moon and stars, a hull's gold brackets, iron bands and rivets, chalk,
// silver filigree, engraved silver set with sapphires, gilt and brass), the
// slider's knob, and filled and outlined buttons. Black rose, Silver dragon
// and Old tome also have buttons and panels of their own material (glass and
// chrome, polished silver on black velvet, tooled leather), and Silver witch
// its own buttons (frosted moon-glass); the others keep their kin's.
//
// Textured pieces (buttons and panels, with their grain, pits and scuffs) are
// drawn once for a size and kept as a picture, so a list scrolling over
// many of them draws pictures, not hundreds of specks a frame.

/// The scenes with buttons and panels of their own material.
const craftedScenes = {Scene.blackRose, Scene.silverDragon, Scene.oldTome};

/// Whether [scene] has buttons and panels of its own.
bool isCrafted(Scene? scene) => scene != null && craftedScenes.contains(scene);

const _chrome = [Color(0xFFF2F5FF), Color(0xFF6A7392), Color(0xFFE4E9F6), Color(0xFF3E445A)];
const _moonSilver = [Color(0xFFF4F7FF), Color(0xFF8C9AB8), Color(0xFFDCE4F4), Color(0xFF56627E)];
const _gilt = Color(0xFFD2AA5C);
const _brass = [Color(0xFFE6C27A), Color(0xFFA87C34), Color(0xFF5E4018)];

// ---------------------------------------------------------------------------
// Kept pictures.

final _kept = <String, ui.Picture>{};

/// What [draw] draws in a box of [size] at the origin, recorded once for
/// [key] and kept (the newest 96), then drawn at [at].
void _keptPicture(Canvas c, String key, Offset at, Size size, void Function(Canvas c, Rect rect) draw) {
  var picture = _kept.remove(key);
  if (picture == null) {
    final recorder = ui.PictureRecorder();
    draw(Canvas(recorder), Offset.zero & size);
    picture = recorder.endRecording();
    while (_kept.length >= 96) {
      _kept.remove(_kept.keys.first)!.dispose();
    }
  }
  _kept[key] = picture;
  c.save();
  c.translate(at.dx, at.dy);
  c.drawPicture(picture);
  c.restore();
}

String _sizeKey(Rect r) => '${(r.width * 2).round()}x${(r.height * 2).round()}';

// ---------------------------------------------------------------------------
// Buttons.

/// [rect] as a button of [scene] in [fill]; false when [scene] has none of
/// its own (its kin's is drawn).
bool _craftedButton(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  if ((!isCrafted(scene) && scene != Scene.silverWitch) || rect.isEmpty) return false;
  final key = 'b:${scene.name}:${_sizeKey(rect)}:${fill.toARGB32()}:${radius.topLeft.x.round()}';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) => _button(c, r, scene, fill, radius));
  return true;
}

void _button(Canvas c, Rect rect, Scene scene, Color fill, BorderRadius radius) {
  final rr = radius.toRRect(rect);
  final path = Path()..addRRect(rr);
  final bright = fill.computeLuminance() > 0.12;
  switch (scene) {
    case Scene.blackRose:
      // Dark glass, lit from above, in a chrome rim.
      _glass(c, rect, rr, fill, bright, _chrome);
    case Scene.silverWitch:
      // Frosted moon-glass: cold, a frost of tiny stars in it, a silver rim.
      _glass(c, rect, rr, fill, bright, _moonSilver);
      c.save();
      c.clipRRect(rr);
      final r = math.Random((rect.width * 3 + rect.height).round());
      for (var i = 0; i < (rect.width * rect.height / 90).clamp(4, 40); i++) {
        c.drawCircle(Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height),
            0.3 + r.nextDouble() * 0.5, _fill(Colors.white.withValues(alpha: 0.12 + r.nextDouble() * 0.18)));
      }
      c.restore();
    case Scene.silverDragon:
      // Polished silver, engraved: bright along its top, a fine engraved
      // line inside its rim, a small sapphire set at its end when it is
      // large enough. The accent itself is silver, so a filled one shines.
      final silver = bright ? fill : Color.lerp(fill, const Color(0xFF2A2F38), 0.55)!;
      if (bright) c.drawRRect(rr, _glow(const Color(0xFFDCE6F6).withValues(alpha: 0.35), 5));
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            Color.lerp(silver, Colors.white, bright ? 0.5 : 0.18)!,
            silver,
            Color.lerp(silver, Colors.black, bright ? 0.35 : 0.55)!,
            Color.lerp(silver, Colors.white, bright ? 0.15 : 0.05)!,
          ], const [
            0,
            0.45,
            0.85,
            1,
          ]),
      );
      c.save();
      c.clipRRect(rr);
      // A sheen across its upper half.
      final sheen = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + rect.height * 0.45);
      c.drawRect(
        sheen,
        Paint()
          ..shader = ui.Gradient.linear(sheen.topLeft, sheen.bottomRight,
              [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: bright ? 0.35 : 0.12), Colors.white.withValues(alpha: 0)], const [0.2, 0.5, 0.8]),
      );
      c.restore();
      if (rect.shortestSide > 18) {
        c.drawRRect(rr.deflate(math.min(3.2, rect.shortestSide * 0.12)),
            _stroke((bright ? const Color(0xFF3A4250) : const Color(0xFFE6ECF6)).withValues(alpha: bright ? 0.45 : 0.3), 0.7));
      }
      if (rect.width > 90 && rect.height > 30) {
        _gem(c, Offset(rect.right - rect.height * 0.5, rect.center.dy), math.min(4.0, rect.height * 0.1));
      }
      c.drawRRect(
        rr.deflate(0.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _chrome, const [0, 0.4, 0.62, 1]),
      );

    case Scene.oldTome:
      // Leather (or gilt, when it is the accent), a tooled rule and
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
        final ink = bright ? const Color(0xFF5A3A10) : _gilt;
        c.drawRRect(rr.deflate(math.min(3.0, rect.shortestSide * 0.1)), _stroke(ink.withValues(alpha: 0.7), 0.9));
        if (rect.shortestSide > 26) {
          _dashed(c, Path()..addRRect(rr.deflate(math.min(5.5, rect.shortestSide * 0.18))), ink.withValues(alpha: 0.4), 0.7, 2.5, 2.5);
        }
      }
      c.drawRRect(rr, _stroke(Colors.black.withValues(alpha: 0.6), 1.2));
    case Scene.forest || Scene.solar || Scene.dungeon || Scene.sketch:
      // Not reached: these keep their kin's buttons.
      break;
  }
}

/// Glass of [fill] in [rect], lit from above, a sheen across its top and a
/// metal rim of [rim].
void _glass(Canvas c, Rect rect, RRect rr, Color fill, bool bright, List<Color> rim) {
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
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, rim, const [0, 0.4, 0.62, 1]),
  );
  c.drawRRect(rr.deflate(2.2), _stroke(Colors.black.withValues(alpha: 0.55), 0.8));
}

// ---------------------------------------------------------------------------
// Panels.

/// [rect] as a panel of [scene] (the player, a card, a bar); false when
/// [scene] has none of its own.
bool _craftedPanel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (!isCrafted(scene) || rect.isEmpty) return false;
  final key = 'p:${scene.name}:${_sizeKey(rect)}:${corners.topLeft.x.round()}:${corners.bottomLeft.x.round()}:$lit';
  _keptPicture(c, key, rect.topLeft, rect.size, (c, r) {
    _panel(c, r, scene, corners, lit: lit);
    paintSceneEdge(c, r, scene, corners, lit: lit);
  });
  return true;
}

void _panel(Canvas c, Rect rect, Scene scene, BorderRadius corners, {required bool lit}) {
  final rr = corners.toRRect(rect);
  switch (scene) {
    case Scene.blackRose:
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
      // Moonlight caught in the glass, from its upper right.
      c.drawCircle(
        Offset(rect.right - rect.width * 0.12, rect.top),
        math.min(rect.width, 160) * 0.6,
        Paint()
          ..shader = ui.Gradient.radial(Offset(rect.right - rect.width * 0.12, rect.top), math.min(rect.width, 160) * 0.6,
              [const Color(0xFFCFE0FF).withValues(alpha: 0.07), const Color(0xFFCFE0FF).withValues(alpha: 0)]),
      );
      c.restore();
    case Scene.silverDragon:
      // Black velvet, as in a jewel case: deep, soft, its nap catching a
      // little light along the top.
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter,
              [lit ? const Color(0xF21C1F27) : const Color(0xF2171A21), const Color(0xF40E1015), const Color(0xF6090A0E)], const [0, 0.5, 1]),
      );
      c.save();
      c.clipRRect(rr);
      final top = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + math.min(rect.height * 0.35, 50));
      c.drawRect(
        top,
        Paint()
          ..shader = ui.Gradient.linear(top.topCenter, top.bottomCenter,
              [const Color(0xFFB8C6DC).withValues(alpha: lit ? 0.09 : 0.05), const Color(0xFFB8C6DC).withValues(alpha: 0)]),
      );
      c.restore();

    case Scene.oldTome:
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
      // Scuffs, worn pale, and the candle's warmth from the upper left.
      for (var i = 0; i < (rect.width / 90).clamp(1, 5); i++) {
        final a = Offset(rect.left + r.nextDouble() * rect.width, rect.top + r.nextDouble() * rect.height);
        c.drawLine(a, a + Offset(8 + r.nextDouble() * 18, (r.nextDouble() - 0.5) * 6), _stroke(const Color(0xFFE8C9A0).withValues(alpha: 0.05), 1));
      }
      c.drawCircle(
        rect.topLeft,
        math.min(rect.width, 200) * 0.7,
        Paint()
          ..shader = ui.Gradient.radial(rect.topLeft, math.min(rect.width, 200) * 0.7,
              [const Color(0xFFFFB45A).withValues(alpha: 0.08), const Color(0xFFFFB45A).withValues(alpha: 0)]),
      );
      c.restore();
    case Scene.forest || Scene.silverWitch || Scene.solar || Scene.dungeon || Scene.sketch:
      break;
  }
}

// ---------------------------------------------------------------------------
// Edges.

/// The edge of something of [scene]'s at [rect]: a panel's, a card's, a
/// sheet's, a dialog's, a menu's, the drawer's, a cover's.
void paintSceneEdge(Canvas c, Rect rect, Scene scene, BorderRadius corners, {bool lit = false}) {
  if (rect.width < 8 || rect.height < 8) return;
  final rr = corners.toRRect(rect);
  final big = rect.shortestSide > 30;
  final wide = rect.width > 180;
  final inset = math.max(5.0, corners.topLeft.x * 0.45);
  final four = [
    (rect.topLeft + Offset(inset, inset), 1.0, 1.0),
    (rect.topRight + Offset(-inset, inset), -1.0, 1.0),
    (rect.bottomLeft + Offset(inset, -inset), 1.0, -1.0),
    (rect.bottomRight + Offset(-inset, -inset), -1.0, -1.0),
  ];
  switch (scene) {
    case Scene.blackRose:
      final silver = const Color(0xFFDDE4F4).withValues(alpha: lit ? 0.7 : 0.5);
      c.drawRRect(rr.deflate(0.6), _stroke(silver, 1));
      if (!big) return;
      c.drawRRect(rr.deflate(3.6), _stroke(silver.withValues(alpha: 0.2), 0.6));
      final k = math.min(14.0, rect.shortestSide * 0.22);
      for (final (p, dx, dy) in four) {
        _scroll(c, p, k, dx, dy, silver);
      }
      if (wide) {
        _jewel(c, Offset(rect.center.dx, rect.top + 0.6), silver, const Color(0xFF0E1120));
        // A rosebud on a thorned stem at the foot's left.
        final b = rect.bottomLeft + Offset(inset + k + 8, -1);
        c.drawLine(b, b + const Offset(16, 0), _stroke(silver.withValues(alpha: 0.35), 0.8));
        for (final x in [4.0, 10.0]) {
          c.drawPath(
            Path()
              ..moveTo(b.dx + x, b.dy)
              ..lineTo(b.dx + x + 1.5, b.dy - 2.5)
              ..lineTo(b.dx + x + 3, b.dy)
              ..close(),
            _fill(silver.withValues(alpha: 0.45)),
          );
        }
        c.drawCircle(b + const Offset(19, 0), 2.6, _fill(const Color(0xFF8E1F30)));
        c.drawCircle(b + const Offset(18.4, -0.8), 0.9, _fill(const Color(0xFFE88A9C).withValues(alpha: 0.7)));
      }
    case Scene.silverDragon:
      // A band of engraved silver: two fine rules, a row of scales
      // engraved between them along the top, a sapphire in each corner,
      // and a larger one at the top's middle in a silver setting.
      final silver = const Color(0xFFDCE6F6).withValues(alpha: lit ? 0.75 : 0.55);
      c.drawRRect(
        rr.deflate(0.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, _chrome, const [0, 0.4, 0.62, 1]),
      );
      if (!big) return;
      c.drawRRect(rr.deflate(4.2), _stroke(silver.withValues(alpha: 0.28), 0.6));
      if (wide) {
        // Scales along the top, between the corners.
        final y = rect.top + 2.4;
        for (var x = rect.left + inset + 18; x < rect.right - inset - 18; x += 7) {
          if ((x - rect.center.dx).abs() < 16) continue;
          c.drawArc(Rect.fromCenter(center: Offset(x, y), width: 6, height: 4), 0, math.pi, false, _stroke(silver.withValues(alpha: 0.32), 0.6));
        }
        final m = Offset(rect.center.dx, rect.top + 1);
        c.drawCircle(m, 6.2, _fill(const Color(0xFF0E1015)));
        c.drawCircle(m, 6.2, _stroke(silver, 1));
        _gem(c, m, 3.8);
      }
      for (final (p, _, _) in four) {
        _gem(c, p, 2.4);
      }

    case Scene.oldTome:
      c.drawRRect(rr.deflate(0.6), _stroke(Colors.black.withValues(alpha: 0.6), 1.2));
      if (rect.shortestSide > 20) c.drawRRect(rr.deflate(3), _stroke(_gilt.withValues(alpha: lit ? 0.8 : 0.62), 1));
      if (rect.shortestSide <= 34) return;
      c.drawRRect(rr.deflate(6), _stroke(_gilt.withValues(alpha: 0.32), 0.6));
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
        c.drawPath(tri, Paint()..shader = ui.Gradient.linear(o, o + Offset(k * dx, k * dy), _brass, const [0, 0.55, 1]));
        c.drawPath(tri, _stroke(Colors.black.withValues(alpha: 0.5), 0.7));
        c.drawCircle(o + Offset(k * 0.28 * dx, k * 0.28 * dy), 1.2, _fill(const Color(0xFFFFE6B0).withValues(alpha: 0.8)));
      }
      if (wide) {
        // A gilt fleuron tooled into the top's middle.
        final m = Offset(rect.center.dx, rect.top + 3);
        final g = _stroke(_gilt.withValues(alpha: 0.7), 0.8);
        c.drawPath(
          Path()
            ..moveTo(m.dx, m.dy - 2.5)
            ..lineTo(m.dx + 3, m.dy)
            ..lineTo(m.dx, m.dy + 2.5)
            ..lineTo(m.dx - 3, m.dy)
            ..close(),
          _fill(_gilt.withValues(alpha: 0.8)),
        );
        for (final s in [-1.0, 1.0]) {
          c.drawPath(
            Path()
              ..moveTo(m.dx + s * 4, m.dy)
              ..quadraticBezierTo(m.dx + s * 10, m.dy - 4, m.dx + s * 16, m.dy)
              ..quadraticBezierTo(m.dx + s * 10, m.dy + 2, m.dx + s * 6, m.dy),
            g,
          );
        }
      }
    case Scene.forest:
      // Bark-dark rim, a vine along it, a tendril and leaves in each corner,
      // a mushroom's glow at the top.
      c.drawRRect(rr.deflate(0.6), _stroke(_k(scene, const Color(0xFF0A1A0E)).withValues(alpha: 0.85), 1.4));
      c.drawRRect(rr.deflate(2.2), _stroke(const Color(0xFF3A6A34).withValues(alpha: lit ? 0.75 : 0.55), 0.9));
      if (!big) return;
      final k = math.min(13.0, rect.shortestSide * 0.2);
      final r = math.Random((rect.width + rect.height * 7).round());
      for (final (p, dx, dy) in four) {
        _scroll(c, p, k, dx, dy, const Color(0xFF5E9A4A).withValues(alpha: 0.8));
        leafAt(c, p + Offset(k * 0.9 * dx, k * 0.15 * dy), 5, math.atan2(dy, dx), r, scene: scene);
      }
      if (wide) {
        final m = Offset(rect.center.dx, rect.top + 1);
        _light(c, m, 16, const Color(0xFF6FD8B6).withValues(alpha: lit ? 0.35 : 0.22), mid: 0.2);
        c.drawCircle(m, 1.8, _fill(const Color(0xFFB8FFE6).withValues(alpha: 0.85)));
      }
    case Scene.silverWitch:
      // A thin silver rim, a star in each corner, a crescent moon at the
      // top between two strings of stars.
      final silver = const Color(0xFFC8D4E8).withValues(alpha: lit ? 0.7 : 0.48);
      c.drawRRect(rr.deflate(0.6), _stroke(silver, 0.9));
      if (!big) return;
      c.drawRRect(rr.deflate(3.2), _stroke(silver.withValues(alpha: 0.16), 0.6));
      for (final (p, _, _) in four) {
        _star4(c, p, 3.4, silver);
      }
      if (wide) {
        final m = Offset(rect.center.dx, rect.top + 0.6);
        c.drawCircle(m, 6, _fill(const Color(0xFF0A0F1B)));
        c.drawPath(_moonPath(m, 4.2), _fill(const Color(0xFFF0F4FF).withValues(alpha: 0.9)));
        _light(c, m, 14, const Color(0xFFDDE8FF).withValues(alpha: 0.18), mid: 0.2);
        for (final s in [-1.0, 1.0]) {
          for (var i = 1; i <= 3; i++) {
            c.drawCircle(m + Offset(s * (8 + i * 6), 0), 0.9 + (i == 2 ? 0.3 : 0), _fill(silver));
          }
        }
      }
    case Scene.solar:
      // A gold hairline, brackets at the corners as on a hull, rivets.
      final gold = const Color(0xFFFFCA70).withValues(alpha: lit ? 0.75 : 0.5);
      c.drawRRect(rr.deflate(0.6), _stroke(gold.withValues(alpha: 0.35), 0.8)..strokeJoin = StrokeJoin.miter);
      if (!big) return;
      final k = math.min(14.0, rect.shortestSide * 0.24);
      for (final (p, dx, dy) in [
        (rect.topLeft + const Offset(2, 2), 1.0, 1.0),
        (rect.topRight + const Offset(-2, 2), -1.0, 1.0),
        (rect.bottomLeft + const Offset(2, -2), 1.0, -1.0),
        (rect.bottomRight + const Offset(-2, -2), -1.0, -1.0),
      ]) {
        final b = Path()
          ..moveTo(p.dx + k * dx, p.dy)
          ..lineTo(p.dx, p.dy)
          ..lineTo(p.dx, p.dy + k * dy);
        c.drawPath(b, _stroke(gold.withValues(alpha: 0.18), 3.5)..strokeJoin = StrokeJoin.miter);
        c.drawPath(b, _stroke(gold, 1.3)..strokeJoin = StrokeJoin.miter);
        c.drawCircle(p + Offset(k * 0.55 * dx, k * 0.55 * dy), 1.1, _fill(gold.withValues(alpha: 0.6)));
      }
      if (wide) {
        final m = Offset(rect.center.dx, rect.top + 0.8);
        c.drawLine(m - const Offset(18, 0), m + const Offset(18, 0), _stroke(gold.withValues(alpha: 0.3), 4));
        c.drawLine(m - const Offset(14, 0), m + const Offset(14, 0), _stroke(const Color(0xFFFFF0C8), 1));
      }
    case Scene.dungeon:
      // An iron band, lit along its top, riveted at the corners.
      c.drawRRect(rr.deflate(1), _stroke(const Color(0xFF221D19).withValues(alpha: 0.9), 2.2));
      c.drawRRect(rr.deflate(1.6), _stroke(const Color(0xFF7A6656).withValues(alpha: lit ? 0.5 : 0.32), 0.7));
      if (!big) return;
      final rivets = [for (final (p, _, _) in four) p, if (wide) Offset(rect.center.dx, rect.top + inset)];
      for (final p in rivets) {
        c.drawCircle(p, 2.6, Paint()..shader = ui.Gradient.radial(p - const Offset(0.8, 0.8), 3, [const Color(0xFFC07A40), const Color(0xFF5A2A12), const Color(0xFF140804)], const [0, 0.5, 1]));
      }
    case Scene.sketch:
      // Drawn round in chalk, twice.
      paintChalk(c, Path()..addRRect(rr.deflate(1.5)), width: 1.3, alpha: lit ? 0.75 : 0.55, seed: (rect.width + rect.height).round(), amp: 1.6, dust: false);
  }
}

/// A four-pointed star at [p], [r] across.
void _star4(Canvas c, Offset p, double r, Color color) {
  final s = Path()
    ..moveTo(p.dx, p.dy - r)
    ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
    ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
    ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
    ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
    ..close();
  c.drawPath(s, _fill(color));
}

/// A small jewel at [m], scrolls of [color] either side.
void _jewel(Canvas c, Offset m, Color color, Color inside) {
  final d = Path()
    ..moveTo(m.dx, m.dy - 3.5)
    ..lineTo(m.dx + 3.5, m.dy)
    ..lineTo(m.dx, m.dy + 3.5)
    ..lineTo(m.dx - 3.5, m.dy)
    ..close();
  c.drawPath(d, _fill(inside));
  c.drawPath(d, _stroke(color, 0.9));
  for (final side in [-1.0, 1.0]) {
    c.drawPath(
      Path()
        ..moveTo(m.dx + side * 5, m.dy)
        ..cubicTo(m.dx + side * 12, m.dy - 4, m.dx + side * 18, m.dy + 3, m.dx + side * 26, m.dy),
      _stroke(color, 0.8),
    );
  }
}

/// A scroll at [p], [k] long, curling in towards ([dx], [dy]).
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

/// [path] in dashes [on] long, [off] apart: stitches.
void _dashed(Canvas c, Path path, Color color, double width, double on, double off) {
  final paint = _stroke(color, width)..strokeCap = StrokeCap.butt;
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += on + off) {
      c.drawPath(m.extractPath(d, math.min(m.length, d + on)), paint);
    }
  }
}

/// A cover's frame in [scene], where it has buttons and panels of its own.
bool _craftedCoverFrame(Canvas c, Rect rect, Scene scene, double radius) {
  if (!isCrafted(scene)) return false;
  paintSceneEdge(c, rect, scene, BorderRadius.circular(radius));
  return true;
}

// ---------------------------------------------------------------------------
// The edges of sheets, dialogs, menus, cards and the drawer.

/// A rounded shape with [scene]'s edge drawn on it: what a sheet, a
/// dialog, a menu, a card or the drawer is cut to in a scene.
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

  // Drawn once for a size and kept: a sheet or a menu is drawn again on
  // every frame it moves.
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty) return;
    final corners = borderRadius.resolve(textDirection);
    _keptPicture(canvas, 'e:${scene.name}:${_sizeKey(rect)}:${corners.topLeft.x.round()}:${corners.topRight.x.round()}:${corners.bottomLeft.x.round()}',
        rect.topLeft, rect.size, (c, r) => paintSceneEdge(c, r, scene, corners));
  }

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

/// A slider's knob in [scene]: a glowing mushroom-light, a moon pearl, a
/// small sun, an iron ring round a flame, a chalk ring, a glass orb, a
/// sapphire in silver, a brass stud. It swells a little while held.
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
  }) =>
      paintKnob(context.canvas, center, radius + 2 * activationAnimation.value, scene, sliderTheme.thumbColor ?? Colors.white);
}

/// [scene]'s knob at [center], [r] across, in [colour].
void paintKnob(Canvas c, Offset center, double r, Scene scene, Color colour) {
  c.drawCircle(center + const Offset(0, 1.5), r, _glow(Colors.black.withValues(alpha: 0.5), 3));
  final disc = Rect.fromCircle(center: center, radius: r);
  switch (scene) {
    case Scene.blackRose:
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
    case Scene.silverDragon:
      // A faceted sapphire in a silver bezel.
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.linear(disc.topLeft, disc.bottomRight, _chrome, const [0, 0.4, 0.62, 1]));
      _gem(c, center, r * 0.62);

    case Scene.oldTome:
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center - Offset(r * 0.3, r * 0.35), r * 1.3, _brass, const [0, 0.55, 1]));
      c.drawCircle(center, r - 0.6, _stroke(Colors.black.withValues(alpha: 0.55), 1));
      c.drawCircle(center, r * 0.55, _stroke(const Color(0xFFFFE6B0).withValues(alpha: 0.45), 0.8));
      c.drawCircle(center - Offset(r * 0.3, r * 0.35), r * 0.18, _fill(Colors.white.withValues(alpha: 0.55)));
    case Scene.forest:
      c.drawCircle(center, r + 3, _glow(colour.withValues(alpha: 0.4), 5));
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center - Offset(0, r * 0.3), r * 1.2, [const Color(0xFFD8FFF0), colour, Color.lerp(colour, Colors.black, 0.6)!], const [0, 0.45, 1]));
      c.drawCircle(center, r - 0.6, _stroke(const Color(0xFF0A1A0E).withValues(alpha: 0.8), 1.2));
      leafAt(c, center + Offset(r * 0.6, -r * 0.8), 5, -0.6, math.Random(3), scene: scene);
    case Scene.silverWitch:
      c.drawCircle(center, r + 3, _glow(const Color(0xFFDDE8FF).withValues(alpha: 0.35), 5));
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center - Offset(r * 0.3, r * 0.3), r * 1.3, const [Color(0xFFFFFFFF), Color(0xFFC8D4E8), Color(0xFF6A7A9A)], const [0, 0.5, 1]));
      // The dark of a crescent on the pearl.
      c.drawCircle(center + Offset(r * 0.38, -r * 0.1), r * 0.72, _fill(const Color(0xFF1A2238).withValues(alpha: 0.55)));
      c.drawCircle(center, r - 0.5, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = ui.Gradient.linear(disc.topLeft, disc.bottomRight, _moonSilver, const [0, 0.4, 0.62, 1]));
    case Scene.solar:
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        c.drawLine(center + Offset(math.cos(a), math.sin(a)) * (r + 1), center + Offset(math.cos(a), math.sin(a)) * (r + 4.5),
            _stroke(colour.withValues(alpha: 0.75), 1.4));
      }
      c.drawCircle(center, r + 2, _glow(colour.withValues(alpha: 0.5), 5));
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.radial(center, r, [const Color(0xFFFFF4D0), colour, Color.lerp(colour, const Color(0xFF7A3A00), 0.5)!], const [0, 0.55, 1]));
    case Scene.dungeon:
      c.drawCircle(center, r, Paint()..shader = ui.Gradient.linear(disc.topCenter, disc.bottomCenter, [const Color(0xFF5A4E44), const Color(0xFF1E1916)]));
      c.drawCircle(center, r * 0.5, _glow(colour.withValues(alpha: 0.9), 3));
      c.drawCircle(center, r * 0.25, _fill(const Color(0xFFFFE0A0)));
      c.drawCircle(center, r - 0.8, _stroke(const Color(0xFF0E0B09), 1.6));
      c.drawCircle(center, r - 1.6, _stroke(const Color(0xFF9A8470).withValues(alpha: 0.45), 0.7));
    case Scene.sketch:
      c.drawCircle(center, r, _fill(const Color(0xFF1C1F22)));
      paintChalk(c, Path()..addOval(disc.deflate(1)), width: 1.6, alpha: 0.9, seed: 5, amp: 1.2, dust: false);
      c.drawCircle(center, r * 0.35, _fill(colour.withValues(alpha: 0.9)));
  }
}

/// A filled button's ground in a scene: drawn as the scene's buttons are.
class SceneFillPainter extends CustomPainter {
  const SceneFillPainter(this.scene, this.fill);

  final Scene scene;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) => paintButton(canvas, Offset.zero & size, scene, fill, BorderRadius.circular(size.height / 2));

  @override
  bool shouldRepaint(SceneFillPainter old) => old.scene != scene || old.fill != fill;
}

// ---------------------------------------------------------------------------
// Dividers.

/// A divider of [scene]'s own across [s] (a group's rule in the drawer and
/// in lists), matching its edges; false where its kin's is drawn.
bool paintOwnDivider(Canvas c, Size s, Scene scene) {
  final y = s.height / 2;
  final m = Offset(s.width / 2, y);
  switch (scene) {
    case Scene.blackRose:
      final silver = const Color(0xFFDDE4F4).withValues(alpha: 0.42);
      c.drawLine(Offset(0, y), Offset(s.width, y),
          Paint()
            ..strokeWidth = 0.8
            ..shader = ui.Gradient.linear(Offset(0, y), Offset(s.width, y),
                [silver.withValues(alpha: 0), silver, silver, silver.withValues(alpha: 0)], const [0, 0.3, 0.7, 1]));
      _jewel(c, m, silver.withValues(alpha: 0.7), const Color(0xFF0E1120));
      return true;
    case Scene.oldTome:
      final g = _gilt.withValues(alpha: 0.5);
      for (final dy in [-1.6, 1.6]) {
        c.drawLine(Offset(4, y + dy), Offset(s.width - 4, y + dy), _stroke(g, dy < 0 ? 0.9 : 0.5));
      }
      c.drawCircle(m, 4.5, _fill(const Color(0xFF1C1108)));
      c.drawPath(
        Path()
          ..moveTo(m.dx, m.dy - 3)
          ..lineTo(m.dx + 3, m.dy)
          ..lineTo(m.dx, m.dy + 3)
          ..lineTo(m.dx - 3, m.dy)
          ..close(),
        _fill(_gilt.withValues(alpha: 0.85)),
      );
      return true;
    case Scene.silverDragon:
      // A fine silver chain, a sapphire at its middle.
      final silver = const Color(0xFFDCE6F6).withValues(alpha: 0.45);
      for (var x = 6.0; x < s.width - 6; x += 7) {
        if ((x - m.dx).abs() < 9) continue;
        c.drawOval(Rect.fromCenter(center: Offset(x, y), width: 6, height: 3.2), _stroke(silver, 0.7));
      }
      _gem(c, m, 3.4);
      return true;

    case Scene.silverWitch:
      final silver = const Color(0xFFC8D4E8).withValues(alpha: 0.4);
      c.drawLine(Offset(0, y), Offset(s.width, y),
          Paint()
            ..strokeWidth = 0.7
            ..shader = ui.Gradient.linear(Offset(0, y), Offset(s.width, y),
                [silver.withValues(alpha: 0), silver, silver, silver.withValues(alpha: 0)], const [0, 0.3, 0.7, 1]));
      c.drawCircle(m, 5, _fill(const Color(0xFF0A0F1B)));
      c.drawPath(_moonPath(m, 3.6), _fill(const Color(0xFFF0F4FF).withValues(alpha: 0.85)));
      for (final sx in [-1.0, 1.0]) {
        _star4(c, m + Offset(sx * 14, 0), 2.2, silver.withValues(alpha: 0.8));
      }
      return true;
    case Scene.forest || Scene.solar || Scene.dungeon || Scene.sketch:
      return false;
  }
}

/// A cut sapphire at [p], [r] across: deep blue, a lighter table, a glint.
void _gem(Canvas c, Offset p, double r) {
  final facets = Path();
  for (var i = 0; i < 8; i++) {
    final a = i * math.pi / 4 + math.pi / 8;
    final q = p + Offset(math.cos(a), math.sin(a)) * r;
    i == 0 ? facets.moveTo(q.dx, q.dy) : facets.lineTo(q.dx, q.dy);
  }
  facets.close();
  c.drawPath(facets, Paint()..shader = ui.Gradient.radial(p - Offset(r * 0.3, r * 0.35), r * 1.3,
      const [Color(0xFF9CC4FF), Color(0xFF2856C8), Color(0xFF0A1A4E)], const [0, 0.5, 1]));
  c.drawPath(facets, _stroke(const Color(0xFFE6ECF6).withValues(alpha: 0.8), math.max(0.5, r * 0.14)));
  c.drawCircle(p - Offset(r * 0.32, r * 0.32), math.max(0.6, r * 0.2), _fill(Colors.white.withValues(alpha: 0.9)));
}

// ---------------------------------------------------------------------------
// The logo's rim.

/// The app's logo tile ([shape] in [box], drawn at 512) rimmed in [scene]'s
/// own material; false where its kin's rim is drawn.
bool paintBrandRim(Canvas c, Rect box, Path shape, Scene scene) {
  final List<Color> metal;
  switch (scene) {
    case Scene.blackRose:
      metal = _chrome;
    case Scene.silverWitch:
      metal = _moonSilver;
    case Scene.silverDragon:
      metal = _chrome;
    case Scene.oldTome:
      metal = _brass;
    case Scene.forest || Scene.solar || Scene.dungeon || Scene.sketch:
      return false;
  }
  final stops = metal.length == 3 ? const [0.0, 0.55, 1.0] : const [0.0, 0.4, 0.62, 1.0];
  c.drawPath(
    shape,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26
      ..shader = ui.Gradient.linear(box.topLeft, box.bottomRight, metal, stops),
  );
  c.drawPath(shape, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..color = Colors.black.withValues(alpha: 0.5));
  switch (scene) {
    case Scene.oldTome:
      // Gilt stitches inside the brass.
      _dashed(c, shape, _gilt.withValues(alpha: 0.7), 4, 14, 12);
    case Scene.silverDragon:
      for (final p in const [Offset(58, 58), Offset(454, 58), Offset(58, 454), Offset(454, 454)]) {
        _gem(c, p, 14);
      }
    case Scene.blackRose || Scene.silverWitch || Scene.forest || Scene.solar || Scene.dungeon || Scene.sketch:
      break;
  }
  return true;
}

// ---------------------------------------------------------------------------
// An empty screen's picture.

/// Where in each painting an empty screen's cameo looks: the moon at the
/// window, the cover's fleuron, the dragon's head, the forest's glade.
Offset? _cameoAt(Scene scene) => switch (scene) {
      Scene.blackRose => const Offset(0.84, 0.2),
      Scene.oldTome => const Offset(0.5, 0.1),
      Scene.silverDragon => const Offset(0.6, 0.25),
      Scene.forest => const Offset(0.45, 0.55),
      Scene.silverWitch => const Offset(0.4, 0.25),
      Scene.solar => const Offset(0.22, 0.38),
      Scene.dungeon => const Offset(0.5, 0.45),
      Scene.sketch => null,
    };

/// An empty screen's picture in [scene]: a round cameo of its own painting,
/// undimmed, in a rim of its material (rather than a small drawing); false
/// where there is none (the chalk scene, or its painting not loaded).
bool paintOwnEmpty(Canvas c, Size s, Scene scene) {
  final at = _cameoAt(scene);
  final art = _art[scene];
  if (at == null || art == null) return false;
  final r = s.shortestSide / 2 - 3;
  final m = Offset(s.width / 2, s.height / 2);
  // A square of the painting about [at], a fifth of its width across.
  final side = art.width * 0.32;
  final centre = Offset(art.width * at.dx, art.height * at.dy);
  final src = Rect.fromCenter(center: centre, width: side, height: side)
      .shift(Offset(
        (side / 2 - centre.dx).clamp(0.0, double.infinity) - (centre.dx + side / 2 - art.width).clamp(0.0, double.infinity),
        (side / 2 - centre.dy).clamp(0.0, double.infinity) - (centre.dy + side / 2 - art.height).clamp(0.0, double.infinity),
      ));
  final circle = Rect.fromCircle(center: m, radius: r);
  c.save();
  c.clipPath(Path()..addOval(circle));
  c.drawImageRect(art, src, circle, Paint()..filterQuality = FilterQuality.medium);
  c.drawRect(circle, Paint()..shader = ui.Gradient.radial(m, r, [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.45)], const [0.6, 1]));
  c.restore();
  paintSceneEdge(c, circle, scene, BorderRadius.circular(r));
  return true;
}

// ---------------------------------------------------------------------------
// The chosen row of a menu.

/// The row you are on in the drawer, in [scene]: a bar of its material
/// (its button, in a dark tint of [accent]) with its emblem at the end.
class SceneSelectionPainter extends CustomPainter {
  const SceneSelectionPainter(this.scene, this.accent);

  final Scene scene;
  final Color accent;

  @override
  void paint(Canvas c, Size size) {
    final rect = Offset.zero & size;
    paintButton(c, rect, scene, Color.lerp(const Color(0xFF14161C), accent, 0.26)!, BorderRadius.circular(size.height / 2));
    final p = Offset(size.width - size.height * 0.62, size.height / 2);
    switch (scene) {
      case Scene.blackRose:
        c.drawCircle(p, 4.2, _fill(const Color(0xFF8E1F30)));
        c.drawCircle(p + const Offset(-1, -1.2), 1.5, _fill(const Color(0xFFE88A9C).withValues(alpha: 0.8)));
        c.drawLine(p + const Offset(-4, 4), p + const Offset(-10, 9), _stroke(const Color(0xFFDDE4F4).withValues(alpha: 0.5), 0.9));
      case Scene.silverDragon:
        _gem(c, p, 4.4);
      case Scene.oldTome:
        c.drawPath(
          Path()
            ..moveTo(p.dx, p.dy - 4.5)
            ..lineTo(p.dx + 4.5, p.dy)
            ..lineTo(p.dx, p.dy + 4.5)
            ..lineTo(p.dx - 4.5, p.dy)
            ..close(),
          _fill(_gilt),
        );
      case Scene.silverWitch:
        c.drawPath(_moonPath(p, 4.6), _fill(const Color(0xFFF0F4FF).withValues(alpha: 0.9)));
      case Scene.forest:
        leafAt(c, p, 7, -0.8, math.Random(2), scene: scene);
      case Scene.solar:
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          c.drawLine(p + Offset(math.cos(a), math.sin(a)) * 5, p + Offset(math.cos(a), math.sin(a)) * 7.5, _stroke(accent.withValues(alpha: 0.8), 1.1));
        }
        c.drawCircle(p, 3.8, _fill(accent));
      case Scene.dungeon:
        c.drawCircle(p, 3.2, Paint()..shader = ui.Gradient.radial(p - const Offset(1, 1), 4, [const Color(0xFFC07A40), const Color(0xFF5A2A12), const Color(0xFF140804)], const [0, 0.5, 1]));
      case Scene.sketch:
        paintChalk(c, Path()
          ..moveTo(p.dx - 5, p.dy)
          ..lineTo(p.dx - 1.5, p.dy + 4)
          ..lineTo(p.dx + 5, p.dy - 5), width: 1.6, alpha: 0.9, seed: 4, amp: 0.8, dust: false);
    }
  }

  @override
  bool shouldRepaint(SceneSelectionPainter old) => old.scene != scene || old.accent != accent;
}
