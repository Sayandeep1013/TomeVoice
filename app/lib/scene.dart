import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'speech_service.dart';

part 'scene_sketch.dart';

/// Scene themes: a place, not a colour. Each draws its own backdrop behind
/// every screen (stone and torches, a forest, the sun), frames the
/// covers in its material, and lays the player, the settings and the cards on
/// panels of it. The page that is read stays plain; text never sits on the
/// art itself, only on the dark of it or on a panel.
///
/// All of it is drawn by hand in code (no pictures, no package): a backdrop
/// is drawn once at the screen's size into an image and that image is what
/// every frame shows, so a list scrolls over it as over a plain colour.
enum Scene {
  forest('Enchanted forest', 'Vines, moss and fireflies'),
  // Made of another scene (its [kin]: its panels, buttons and frames), in
  // colours of its own ([hue]), over a painting of its own.
  silverWitch('Silver witch', 'Moonlight, mist and silver', kin: Scene.forest, hue: 215, saturation: 0.32),
  // Its own panels (a hull's plates, cut at two corners), turned to gold.
  solar('Space · solar', 'The sun, gold and the dark', hue: 38, saturation: 1.1),
  dungeon('Dungeon', 'Torchlit stone, rust and bones'),
  // Drawn by hand, in chalk (scene_sketch.dart): no painting.
  sketch('Sketch · chalk', 'Hand-drawn chalk on a grainy slate'),
  // The forest's vines and curls in moonlit silver, over a painting of
  // black roses at a cathedral window; dark-red petals fall.
  blackRose('Black rose', 'Moonlit roses, thorns and silver', kin: Scene.forest, hue: 228, saturation: 0.26),
  // The dungeon's worn stone gone cold and grey, over cracked slate with a
  // dragon worn into it; embers rise.
  dragonSlate('Dragon slate', 'Cracked slate, a worn dragon and embers', kin: Scene.dungeon, hue: 215, saturation: 0.1),
  // The forest's vines and curls turned to gilt tooling, over the worn
  // leather of an old book's cover; dust drifts in candlelight.
  oldTome('Old tome', 'Worn leather, gilt and candlelight', kin: Scene.forest, hue: 36, saturation: 0.55);

  const Scene(this.label, this.note, {Scene? kin, this.hue, this.saturation = 1}) : _kin = kin;

  final String label;

  /// What it is made of, under its preview.
  final String note;

  final Scene? _kin;

  /// Whose panels, buttons and frames it has: the forest's, the dungeon's or
  /// the solar scene's own hull.
  Scene get kin => _kin ?? this;

  /// The hue its kin's colours are turned to (null: its kin's own), and
  /// how much of their colour stays.
  final double? hue;
  final double saturation;

  /// Its corners: worn stone and wood are rounded, a hull's (the solar scene's) are sharp.
  double get radius => switch (kin) {
        Scene.dungeon => 12,
        Scene.forest => 16,
        Scene.sketch => 14,
        Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome => 2,
      };

  /// How far a hull's panels and buttons are cut at two corners.
  static const cut = 10.0;

  /// A panel's corners: never rounder than the scene's own, so a pill-round
  /// bar becomes worn stone, not a pill.
  BorderRadius corners(BorderRadius? asked) {
    if (kin == Scene.solar) return BorderRadius.circular(radius);
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

// ---------------------------------------------------------------------------
// Painted backdrops: a scene drawn from a real painting (made by
// tools/scene_art.py into assets/scenes), where it has one. Drawn by hand,
// the forest's trees and vines looked stiff up close; a painting does not.

/// Scenes with a painted backdrop.
const _withArt = {Scene.forest, Scene.silverWitch, Scene.solar, Scene.dungeon, Scene.blackRose, Scene.dragonSlate, Scene.oldTome};

/// Whether painted backdrops are loaded (off under `flutter test`, which
/// keeps to the drawn ones).
@visibleForTesting
bool sceneArt = !Platform.environment.containsKey('FLUTTER_TEST');

final _art = <Scene, ui.Image>{};
final _artLoading = <Scene>{};
final _artFailed = <Scene>{};

/// Bumped each time a scene's painting is ready: what shows it draws again.
final sceneArtReady = ValueNotifier<int>(0);

/// Whether [scene] has a painting not loaded yet.
bool _artPending(Scene scene) =>
    sceneArt && _withArt.contains(scene) && !_art.containsKey(scene) && !_artFailed.contains(scene);

/// [scene]'s painting decoded once, at the screen's width (a phone never
/// holds more of it than it shows), then kept.
void _loadArt(Scene scene) {
  if (!_artPending(scene) || !_artLoading.add(scene)) return;
  unawaited(() async {
    try {
      final data = await rootBundle.load('assets/scenes/${scene.name}.webp');
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      final width = view == null ? null : math.min(1440, view.physicalSize.shortestSide.round());
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: width);
      final frame = await codec.getNextFrame();
      codec.dispose();
      _art[scene] = frame.image;
      // Backdrops drawn before it came are drawn again with it.
      for (final k in [..._drawn.keys.where((k) => k.startsWith('${scene.name}:'))]) {
        _drawn.remove(k)!.dispose();
      }
      sceneArtReady.value++;
    } on Object {
      // Drawn by hand, as before.
      _artFailed.add(scene);
      sceneArtReady.value++;
    } finally {
      _artLoading.remove(scene);
    }
  }());
}

/// [art] over the whole of [size], cut to fit, sunk into shadow at the top
/// (the screen's title and buttons), at the foot (the player) and at the
/// edges, so the lists' panels and the moving light read over it.
void _paintArt(Canvas canvas, Size size, ui.Image art) {
  final rect = Offset.zero & size;
  final src = Size(art.width.toDouble(), art.height.toDouble());
  final fitted = applyBoxFit(BoxFit.cover, src, size);
  final from = Alignment.center.inscribe(fitted.source, Offset.zero & src);
  canvas.drawRect(rect, _fill(const Color(0xFF050805)));
  canvas.drawImageRect(art, from, rect, Paint()..filterQuality = FilterQuality.medium);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
        Colors.black.withValues(alpha: 0.62),
        Colors.black.withValues(alpha: 0.18),
        Colors.black.withValues(alpha: 0.22),
        Colors.black.withValues(alpha: 0.66),
      ], [
        0,
        0.24,
        0.66,
        1,
      ]),
  );
  _vignette(canvas, size, edge: 0.72);
}

/// The ground of a screen in a scene: its backdrop, or [base] while there
/// is none to show (its painting still loading, the first time).
class SceneGround extends Decoration {
  const SceneGround(this.scene, this.base);

  final Scene scene;
  final Gradient base;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _SceneGroundPainter(this, onChanged);

  @override
  bool operator ==(Object other) => other is SceneGround && other.scene == scene && other.base == base;

  @override
  int get hashCode => Object.hash(scene, base);
}

class _SceneGroundPainter extends BoxPainter {
  _SceneGroundPainter(this.d, VoidCallback? onChanged) : super(onChanged) {
    if (onChanged != null) sceneArtReady.addListener(onChanged);
  }

  final SceneGround d;

  @override
  void dispose() {
    if (onChanged != null) sceneArtReady.removeListener(onChanged!);
    super.dispose();
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    paintSceneGround(canvas, offset & size, d, configuration.devicePixelRatio ?? 1);
  }
}

/// [ground] laid over [rect] on [canvas], at [opacity] and with [blend]
/// (over a screen going, or in behind a shelf's foot): one draw, its
/// opacity and blend in the paint, so the GPU draws nothing offscreen for
/// it. With [only], just that part of it (no clip, no fill of the rest).
void paintSceneGround(Canvas canvas, Rect rect, SceneGround ground, double dpr,
    {double opacity = 1, BlendMode blend = BlendMode.srcOver, Rect? only}) {
  final size = rect.size;
  final area = only == null ? rect : rect.intersect(only);
  if (area.isEmpty) return;
  final paint = Paint()
    ..color = Color.fromRGBO(0, 0, 0, opacity)
    ..blendMode = blend;
  // Its painting on its way: the plain ground meanwhile, a moment, once.
  if (_artPending(ground.scene)) {
    _loadArt(ground.scene);
    canvas.drawRect(area, paint..shader = ground.base.createShader(rect));
    return;
  }
  final image = sceneImages ? sceneBackdrop(ground.scene, _canvasFor(size), dpr) : null;
  if (image == null) {
    // Drawn by hand, in many strokes (only where no image can be kept):
    // gathered first when they must be faded or blended as one.
    final plain = opacity >= 1 && blend == BlendMode.srcOver;
    if (plain) {
      canvas.save();
    } else {
      canvas.saveLayer(area, paint);
    }
    canvas.clipRect(area);
    canvas.translate(rect.left, rect.top);
    paintBackdrop(canvas, size, ground.scene);
    canvas.restore();
    return;
  }
  // The backdrop is drawn at the ground's size from the image's top left.
  final from = (area.topLeft - rect.topLeft) * dpr;
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(from.dx, from.dy, area.width * dpr, area.height * dpr),
    area,
    paint..filterQuality = FilterQuality.low,
  );
}

/// [scene]'s backdrop on [canvas], at [size]: its painting, where it has
/// one and it has loaded; else drawn by hand.
void paintBackdrop(Canvas canvas, Size size, Scene scene) {
  final art = _art[scene];
  if (art != null) {
    _paintArt(canvas, size, art);
    return;
  }
  switch (scene) {
    case Scene.dungeon:
      _Dungeon(canvas, size).paint();
    case Scene.forest:
      _Forest(canvas, size).paint();
    case Scene.sketch:
      _Sketch(canvas, size).paint();
    case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
      // A scene made from a painting, while it loads: its dark, in shadow.
      canvas.drawRect(Offset.zero & size, _fill(_k(scene, const Color(0xFF0A1424))));
      _vignette(canvas, size);
  }
}

/// [c], one of [scene]'s kin's colours, turned to [scene]'s own hue (greys,
/// black and white left as they are). Worked out once per colour.
Color _k(Scene scene, Color c) {
  final hue = scene.hue;
  if (hue == null) return c;
  final cache = _recoloured[scene] ??= {};
  return cache[c.toARGB32()] ??= () {
    final h = HSLColor.fromColor(c);
    if (h.saturation < 0.06) return c;
    return h.withHue(hue).withSaturation((h.saturation * scene.saturation).clamp(0.0, 1.0)).toColor();
  }();
}

final _recoloured = <Scene, Map<int, Color>>{};

/// [c], one of [scene]'s kin's colours, in [scene]'s own hue.
Color sceneInk(Scene scene, Color c) => _k(scene, c);

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
void leafAt(Canvas c, Offset at, double size, double angle, math.Random r, {Scene? scene}) {
  Color k(Color x) => scene == null ? x : _k(scene, x);
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
        k(Color.lerp(const Color(0xFF3F8A42), const Color(0xFF2A6A30), r.nextDouble())!),
        k(const Color(0xFF173F1E)),
      ]),
  );
  c.drawLine(Offset.zero, Offset(size * 0.85, 0), _stroke(k(const Color(0xFF0E2A12)).withValues(alpha: 0.8), 0.6));
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
void _curl(Canvas c, Offset at, double size, double side, {Scene? scene}) {
  final path = Path()..moveTo(at.dx, at.dy);
  for (var t = 0.0; t < math.pi * 3; t += 0.25) {
    final rad = size * (1 - t / (math.pi * 3.4));
    path.lineTo(at.dx + side * (size - math.cos(t) * rad), at.dy - math.sin(t) * rad);
  }
  c.drawPath(path, _stroke(scene == null ? const Color(0xFF2E5A2E) : _k(scene, const Color(0xFF2E5A2E)), 1));
}

// ---------------------------------------------------------------------------
// A ship's hull (the solar scene's panels and frames).

const _neon = Color(0xFF3FE0F0);


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
  switch (scene.kin) {
    case Scene.dungeon:
      final rr = RRect.fromRectAndRadius(rect.deflate(t / 2), Radius.circular(math.max(radius, t)));
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight,
              [_k(scene, const Color(0xFF3A1D0E)), _k(scene, const Color(0xFF8A4A24)), _k(scene, const Color(0xFF4A2412)), _k(scene, const Color(0xFF7A3E1C)), _k(scene, const Color(0xFF24120A))], const [0, 0.3, 0.55, 0.8, 1])
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
        c.drawCircle(p, 0.5 + r.nextDouble() * 0.9, _fill(_k(scene, const Color(0xFF140804)).withValues(alpha: 0.8)));
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
            Paint()..shader = ui.Gradient.radial(p - Offset(rivet * 0.3, rivet * 0.3), rivet * 1.2, [_k(scene, const Color(0xFFD08A4C)), _k(scene, const Color(0xFF6A3416)), _k(scene, const Color(0xFF140804))], const [0, 0.45, 1]));
      }
    case Scene.forest:
      final rr = RRect.fromRectAndRadius(rect.deflate(t / 2), Radius.circular(math.max(radius, t)));
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [_k(scene, const Color(0xFF5E3B1F)), _k(scene, const Color(0xFF3A2414)), _k(scene, const Color(0xFF6A4424)), _k(scene, const Color(0xFF2E1C10))], const [0, 0.35, 0.65, 1])
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
        c.drawPath(path, _stroke(_k(scene, const Color(0xFF1E4626)), math.max(1.2, t * 0.35)));
        for (var i = 0; i < 4; i++) {
          final m = path.computeMetrics().first;
          final tg = m.getTangentForOffset(m.length * (0.15 + i * 0.22))!;
          leafAt(c, tg.position, math.max(4, k * 0.9), (i.isEven ? -0.6 : 0.6) + (sx > 0 ? 0 : math.pi), r, scene: scene);
        }
      }
    case Scene.sketch:
      _sketchCoverFrame(c, rect, radius);
    case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
      final sharp = rect.deflate(0.5);
      c.drawRect(sharp, _stroke(_k(scene, _neon).withValues(alpha: 0.4), 1)..strokeCap = StrokeCap.butt);
      final len = rect.width * 0.2;
      for (final (corner, dx, dy) in [
        (sharp.topLeft, 1.0, 1.0),
        (sharp.topRight, -1.0, 1.0),
        (sharp.bottomLeft, 1.0, -1.0),
        (sharp.bottomRight, -1.0, -1.0),
      ]) {
        bracket(c, corner, len, dx, dy, _k(scene, _neon), width: math.max(1.2, t * 0.35));
      }
  }
}

/// A frame drawn over a cover (or a tile) in [scene].
class CoverFramePainter extends CustomPainter {
  const CoverFramePainter(this.scene, this.radius, {this.within});

  final Scene scene;
  final double radius;

  /// Corners the frame is kept inside (a tile's: a frame's outer edge and
  /// its leaves reach a little past the box).
  final BorderRadius? within;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final within = this.within;
    if (within == null) {
      paintCoverFrame(canvas, rect, scene, radius);
      return;
    }
    canvas.save();
    canvas.clipRRect(within.toRRect(rect));
    paintCoverFrame(canvas, rect, scene, radius);
    canvas.restore();
  }

  @override
  bool shouldRepaint(CoverFramePainter old) => old.scene != scene || old.radius != radius || old.within != within;
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

/// The outline of a panel at [rect]: [corners] rounded, but a hull's
/// cut off at its top left and bottom right, as a ship's hatches are.
Path panelPath(Rect rect, Scene scene, BorderRadius corners) {
  if (scene.kin != Scene.solar) return Path()..addRRect(corners.toRRect(rect));
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
    if (scene.kin == Scene.solar) {
      c.drawPath(panelPath(rect.shift(s.offset).inflate(s.spreadRadius), scene, corners), s.toPaint());
    } else {
      c.drawRRect(rr.shift(s.offset).inflate(s.spreadRadius), s.toPaint());
    }
  }
  final r = math.Random((rect.width * 31 + rect.height).round());
  switch (scene.kin) {
    case Scene.dungeon:
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            lit ? _k(scene, const Color(0xFF2A211B)) : _k(scene, const Color(0xFF221B16)),
            _k(scene, const Color(0xFF17120F)),
            _k(scene, const Color(0xFF110D0B)),
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
        ..color = _k(scene, const Color(0xFF6A3416)).withValues(alpha: 0.55)
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
              [_k(scene, const Color(0xFF14180C)).withValues(alpha: 0), _k(scene, const Color(0xFF1A2010)).withValues(alpha: 0.45)]),
      );
      if (rect.height > 50) {
        for (var i = 0; i < 9; i++) {
          final p = Offset(rect.left + 4 + r.nextDouble() * 34, rect.bottom - 2 - r.nextDouble() * 9);
          c.drawOval(Rect.fromCenter(center: p, width: 3 + r.nextDouble() * 6, height: 1.6 + r.nextDouble() * 2.4),
              _fill(Color.lerp(_k(scene, const Color(0xFF3A4A20)), _k(scene, const Color(0xFF243014)), r.nextDouble())!.withValues(alpha: 0.8)));
        }
      }
      c.restore();
      c.drawRRect(rr, _stroke(_k(scene, const Color(0xFF3E2E22)), 1.2));
      c.drawRRect(rr.deflate(1.2), _stroke(Colors.white.withValues(alpha: 0.04), 1));
      if (rect.height > 36 && rect.width > 60) {
        for (final p in [
          rect.topLeft + const Offset(9, 9),
          rect.topRight + const Offset(-9, 9),
          rect.bottomLeft + const Offset(9, -9),
          rect.bottomRight + const Offset(-9, -9),
        ]) {
          c.drawCircle(p, 2.4,
              Paint()..shader = ui.Gradient.radial(p - const Offset(0.8, 0.8), 3, [_k(scene, const Color(0xFFC07A40)), _k(scene, const Color(0xFF5A2A12)), _k(scene, const Color(0xFF140804))], const [0, 0.5, 1]));
        }
      }
    case Scene.forest:
      c.drawRRect(
        rr,
        Paint()
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            lit ? _k(scene, const Color(0xFF173222)) : _k(scene, const Color(0xFF12281A)),
            _k(scene, const Color(0xFF0C1C12)),
          ]),
      );
      c.drawRRect(rr, _stroke(_k(scene, const Color(0xFF3A6A34)).withValues(alpha: 0.7), 1.3));
      c.drawRRect(rr.deflate(2.5), _stroke(_k(scene, const Color(0xFF5A3A1E)).withValues(alpha: 0.5), 1));
      // A vine curling over two corners.
      if (rect.height > 30 && rect.width > 60) {
        for (final (corner, sx, sy) in [(rect.topLeft, 1.0, 1.0), (rect.bottomRight, -1.0, -1.0)]) {
          final k = math.min(36.0, rect.height * 0.7);
          final path = Path()
            ..moveTo(corner.dx + sx * k * 1.6, corner.dy + sy * 1)
            ..quadraticBezierTo(corner.dx + sx * 2, corner.dy + sy * 2, corner.dx + sx * 1, corner.dy + sy * k);
          c.drawPath(path, _stroke(_k(scene, const Color(0xFF1E4626)), 1.8));
          final m = path.computeMetrics().first;
          for (var i = 0; i < 3; i++) {
            final tg = m.getTangentForOffset(m.length * (0.2 + i * 0.3))!;
            leafAt(c, tg.position, 7, (i.isEven ? -0.7 : 0.7) + (sx > 0 ? 0 : math.pi), r, scene: scene);
          }
          _curl(c, corner + Offset(sx * k * 1.6, sy * 1), 4, sx, scene: scene);
        }
      }
    case Scene.sketch:
      _sketchPanel(c, rect, rr, lit: lit);
    case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
      final hull = panelPath(rect, scene, corners);
      c.drawPath(
        hull,
        Paint()
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
            lit ? _k(scene, const Color(0xFF0C1A2C)) : _k(scene, const Color(0xFF0A1424)),
            _k(scene, const Color(0xFF060C17)),
          ]),
      );
      // Faint scan lines across it, as on a screen.
      if (rect.height > 30) {
        c.save();
        c.clipPath(hull);
        final scan = _stroke(_k(scene, _neon).withValues(alpha: 0.035), 1)..strokeCap = StrokeCap.butt;
        for (var y = rect.top + 3; y < rect.bottom; y += 4) {
          c.drawLine(Offset(rect.left, y), Offset(rect.right, y), scan);
        }
        c.restore();
      }
      c.drawPath(hull, _stroke(_k(scene, const Color(0xFF1F4A66)), 1)..strokeJoin = StrokeJoin.miter);
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
        c.drawPath(edge, _glow(_k(scene, _neon).withValues(alpha: 0.5), 3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.4);
        c.drawPath(edge, _stroke(_k(scene, const Color(0xFF9FF6FF)), 1.3)..strokeJoin = StrokeJoin.miter);
      }
      final len = math.min(14.0, math.min(rect.width, rect.height) * 0.3);
      for (final (corner, dx, dy) in [
        (rect.topRight, -1.0, 1.0),
        (rect.bottomLeft, 1.0, -1.0),
      ]) {
        bracket(c, corner + Offset(dx * 1, dy * 1), len, dx, dy, _k(scene, _neon), width: 1.4);
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

  /// The shape a button takes in [scene] at [radius]: a hull's is cut.
  static ShapeBorder shape(Scene scene, BorderRadius radius) => scene.kin == Scene.solar
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
  final path = scene.kin == Scene.solar
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
  switch (scene.kin) {
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
    case Scene.sketch:
      _sketchButtonInside(c, rect, bright: bright);
    case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
      for (var y = rect.top + 2; y < rect.bottom; y += 3.5) {
        c.drawLine(Offset(rect.left, y), Offset(rect.right, y), _stroke(Colors.white.withValues(alpha: 0.03), 1)..strokeCap = StrokeCap.butt);
      }
  }
  c.restore();
  switch (scene.kin) {
    case Scene.dungeon:
      c.drawPath(path, _stroke(Colors.black.withValues(alpha: 0.75), 1.4));
      c.drawPath(path, _stroke((bright ? _k(scene, const Color(0xFFFFC08A)) : _k(scene, const Color(0xFF6A3416))).withValues(alpha: bright ? 0.35 : 0.75), 0.9));
    case Scene.forest:
      c.drawPath(path, _stroke(_k(scene, const Color(0xFF0A1A0E)).withValues(alpha: 0.8), 1.4));
      c.drawPath(path, _stroke((bright ? _k(scene, const Color(0xFFCFFFF0)) : _k(scene, const Color(0xFF3A6A34))).withValues(alpha: bright ? 0.35 : 0.8), 0.9));
    case Scene.sketch:
      _sketchButtonEdge(c, path, rect, fill, bright: bright);
    case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
      if (bright) {
        c.drawPath(path, _glow(fill.withValues(alpha: 0.6), 4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
      }
      c.drawPath(path, _stroke(bright ? _k(scene, const Color(0xFFCFFBFF)) : _k(scene, _neon).withValues(alpha: 0.55), 1)..strokeJoin = StrokeJoin.miter);
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

/// Android's battery saver is on: the scenes' life stands still, as when
/// the phone removes animations. Read as the app opens and each time it
/// comes back to the front.
final sceneBatterySaver = ValueNotifier<bool>(false);
DateTime? _saverAskedAt;

Future<void> _askSaver() async {
  if (!Platform.isAndroid) return;
  final now = DateTime.now();
  final was = _saverAskedAt;
  if (was != null && now.difference(was) < const Duration(seconds: 5)) return;
  _saverAskedAt = now;
  final d = await const SpeechService().phoneDetails();
  sceneBatterySaver.value = d['powerSave'] == true;
}

class _SceneLifeState extends State<SceneLife> with WidgetsBindingObserver {
  final _time = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;
  int? _frame;

  /// False while another screen covers this one, or it is put away
  /// (TickerMode off).
  bool _current = true;
  bool _enabled = true;

  /// The phone removes animations (read with the screen's other settings).
  bool _noMotion = false;

  /// How long to wait after a picture before asking for the next frame:
  /// drawn on the first frame after 26 ms, about 30 a second at 60, 90 and
  /// 120 Hz alike, smooth for flames and fireflies. A ticker woke every
  /// frame of the display (twice or four times the pictures drawn) for as
  /// long as a scene was on screen, reading aloud on a slow phone too.
  static const _rest = Duration(milliseconds: 26);

  bool get _visible {
    final app = WidgetsBinding.instance.lifecycleState;
    final still = !sceneLifeMoves || _noMotion || sceneBatterySaver.value;
    return !still && _current && _enabled && (app == null || app == AppLifecycleState.resumed);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sceneBatterySaver.addListener(_sync);
    if (sceneLifeMoves) unawaited(_askSaver());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    _enabled = TickerMode.valuesOf(context).enabled;
    _noMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && sceneLifeMoves) unawaited(_askSaver());
    _sync();
  }

  /// Moving only while it can be seen and may move; asleep otherwise (no
  /// timer left running behind another screen or with the app away).
  void _sync() {
    if (!mounted) return;
    if (!_visible) {
      _timer?.cancel();
      _timer = null;
      if (_frame != null) SchedulerBinding.instance.cancelFrameCallbackWithId(_frame!);
      _frame = null;
      _clock.stop();
    } else if (_timer == null && _frame == null) {
      _clock.start();
      _next();
    }
  }

  void _next() {
    _timer = Timer(_rest, () {
      _timer = null;
      if (!mounted || !_visible) return;
      _frame = SchedulerBinding.instance.scheduleFrameCallback((_) {
        _frame = null;
        if (!mounted || !_visible) return;
        _time.value = _clock.elapsedMicroseconds / 1e6;
        _next();
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sceneBatterySaver.removeListener(_sync);
    _timer?.cancel();
    if (_frame != null) SchedulerBinding.instance.cancelFrameCallbackWithId(_frame!);
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
      case Scene.silverWitch:
        _silverWitchLife(canvas, s, t);
      case Scene.solar:
        _solarLife(canvas, s, t);
      case Scene.sketch:
        _sketchLife(canvas, s, t);
      case Scene.blackRose:
        _blackRoseLife(canvas, s, t);
      case Scene.dragonSlate:
        _dragonSlateLife(canvas, s, t);
      case Scene.oldTome:
        _oldTomeLife(canvas, s, t);
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
  if (_art.containsKey(Scene.dungeon)) {
    // Over the photograph: an iron sconce holding each flame, and now and
    // then an ember's light running down the sides.
    for (final at in torches) {
      final toCentre = at.dx < s.width / 2 ? 1.0 : -1.0;
      final cup = at + Offset(10 * toCentre, 4);
      c.drawRect(Rect.fromCenter(center: Offset(at.dx, cup.dy + 16), width: 6, height: 34), _fill(const Color(0xFF1A120C)));
      c.drawPath(
          Path()
            ..moveTo(cup.dx - 9, cup.dy - 4)
            ..lineTo(cup.dx + 9, cup.dy - 4)
            ..lineTo(cup.dx + 5, cup.dy + 8)
            ..lineTo(cup.dx - 5, cup.dy + 8)
            ..close(),
          _fill(const Color(0xFF2A1C12)));
    }
    _drips(c, s, t);
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
  if (_art.containsKey(Scene.forest)) {
    // Over the painting: vines growing in from the top corners as the
    // screen opens, light running down them like sap, then swaying.
    _vine(c, s, t, left: true);
    _vine(c, s, t - 1.1, left: false);
  } else {
    // The drawn forest's glowing mushrooms breathing.
    final m = Offset(s.width - 46, s.height - 34);
    _light(c, m, 40 + 8 * math.sin(t * 1.3), const Color(0xFF5AF0D0).withValues(alpha: 0.10 + 0.06 * math.sin(t * 1.3)));
  }
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

/// A vine from the top of the screen down one side ([left] or right),
/// [t] seconds after the screen opened: it grows for the first few seconds
/// (leaves budding as its tip passes, growing to full size), then a glow
/// runs down it now and then while its tip sways. Plain fills only: no
/// gradient made per frame.
void _vine(Canvas c, Size s, double t, {required bool left}) {
  if (t <= 0) return;
  final grown = Curves.easeOutCubic.transform((t / 5.5).clamp(0.0, 1.0));
  final dir = left ? 1.0 : -1.0;
  final x0 = left ? 0.0 : s.width;
  final len = s.height * (left ? 0.58 : 0.42);
  const n = 56;
  final pts = <Offset>[];
  for (var i = 0; i <= n; i++) {
    final f = i / n;
    final sway = math.sin(t * 0.8 + f * 2.6) * 5 * f * f;
    final x = x0 + dir * (8 + 15 * math.sin(f * 5.4 + (left ? 0 : 1.9)) * (0.35 + f * 0.65) + 6 * f + sway);
    pts.add(Offset(x, -4 + f * len));
  }
  final upto = grown * n;
  final whole = upto.floor();
  // The stem: thick at its root, thin at its tip.
  for (var i = 0; i < whole && i < n; i++) {
    final w = 4.2 - 3.0 * i / n;
    c.drawLine(pts[i], pts[i + 1], _stroke(const Color(0xFF16351A).withValues(alpha: 0.92), w));
    c.drawLine(pts[i], pts[i + 1], _stroke(const Color(0xFF3E7A3A).withValues(alpha: 0.55), w * 0.45));
  }
  if (whole < n) {
    final tip = Offset.lerp(pts[whole], pts[whole + 1], upto - whole)!;
    c.drawLine(pts[whole], tip, _stroke(const Color(0xFF16351A), 1.4));
  }
  // Leaves, in pairs of sides, each growing to size after the tip passes.
  final leaf = Paint()..color = const Color(0xFF2F6B32).withValues(alpha: 0.95);
  final vein = _stroke(const Color(0xFF0E2A12).withValues(alpha: 0.7), 0.6);
  for (var i = 3; i < n; i += 4) {
    final age = (upto - i) / 6;
    if (age <= 0) continue;
    final size = 11 * Curves.easeOutCubic.transform(age.clamp(0.0, 1.0));
    final side = (i ~/ 4).isEven ? 1.0 : -1.0;
    final a = pts[i];
    final along = pts[math.min(n, i + 1)] - a;
    final angle = math.atan2(along.dy, along.dx) + side * 1.0 + math.sin(t * 1.1 + i) * 0.12;
    c.save();
    c.translate(a.dx, a.dy);
    c.rotate(angle);
    c.drawPath(
      Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(size * 0.55, -size * 0.45, size, 0)
        ..quadraticBezierTo(size * 0.55, size * 0.45, 0, 0)
        ..close(),
      leaf,
    );
    c.drawLine(Offset.zero, Offset(size * 0.8, 0), vein);
    c.restore();
  }
  // Grown: a light runs down it every few seconds, a soft gold-green.
  if (grown >= 1) {
    final run = ((t - 5.5) * 0.16 + (left ? 0 : 0.5)) % 1.3;
    if (run < 1) {
      final at = pts[(run * n).floor().clamp(0, n)];
      _light(c, at, 16, const Color(0xFFE8FF8A).withValues(alpha: 0.42));
      c.drawCircle(at, 1.6, _fill(const Color(0xFFFFFBD0).withValues(alpha: 0.9)));
    }
  }
}

/// Dungeon: water seeping down the stone, a drop at a time: each slides
/// down its wet streak catching the torchlight, falls, and rings out in a
/// small ripple below.
void _drips(Canvas c, Size s, double t) {
  for (var i = 0; i < 3; i++) {
    final x = i == 1 ? s.width - 46.0 : (i == 0 ? 52.0 : s.width * 0.62);
    final top = s.height * (0.08 + i * 0.05);
    final len = s.height * (0.22 + i * 0.04);
    // The wet streak, darker and faintly shining.
    c.drawLine(Offset(x, top), Offset(x, top + len), _stroke(const Color(0xFF0C0806).withValues(alpha: 0.35), 3));
    c.drawLine(Offset(x - 0.8, top), Offset(x - 0.8, top + len),
        _stroke(const Color(0xFFFFC890).withValues(alpha: 0.06), 1));
    const cycle = 7.0;
    final k = ((t + i * 2.3) % cycle) / cycle;
    if (k < 0.55) {
      // Gathering, then sliding down the streak, slow then quick.
      final slide = Curves.easeInQuad.transform(k / 0.55);
      final p = Offset(x, top + len * slide);
      final r = 1.6 + 1.2 * math.min(1.0, k * 6);
      _light(c, p, 7, const Color(0xFFFFB060).withValues(alpha: 0.25));
      c.drawCircle(p, r, _fill(const Color(0xFFE8F4FF).withValues(alpha: 0.75)));
    } else if (k < 0.7) {
      // Falling free.
      final f = (k - 0.55) / 0.15;
      final p = Offset(x, top + len + f * f * s.height * 0.25);
      c.drawOval(Rect.fromCenter(center: p, width: 2.4, height: 5), _fill(const Color(0xFFE8F4FF).withValues(alpha: 0.7)));
    } else {
      // Its ripple on the floor, spreading and fading.
      final f = (k - 0.7) / 0.3;
      final at = Offset(x, top + len + s.height * 0.25);
      c.drawOval(Rect.fromCenter(center: at, width: 6 + 40 * f, height: 2 + 9 * f),
          _stroke(const Color(0xFFFFD0A0).withValues(alpha: 0.35 * (1 - f)), 1));
    }
  }
}

/// Silver witch: a ring of runes drawing itself low on the screen, its
/// line running round as if by an unseen hand, glowing, then fading, then
/// again.
void _sigil(Canvas c, Size s, double t) {
  const cycle = 14.0;
  final k = ((t + 2) % cycle) / cycle;
  if (k > 0.8) return;
  final drawn = Curves.easeInOut.transform((k / 0.45).clamp(0.0, 1.0));
  final fade = k < 0.6 ? 1.0 : 1 - (k - 0.6) / 0.2;
  final centre = Offset(s.width * 0.5, s.height * 0.72);
  final r = s.width * 0.3;
  const color = Color(0xFFD8E4FF);
  final glow = _glow(color.withValues(alpha: 0.35 * fade), 4)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;
  final line = _stroke(color.withValues(alpha: 0.55 * fade), 1);
  final oval = Rect.fromCenter(center: centre, width: r * 2, height: r * 0.7);
  final sweep = math.pi * 2 * drawn;
  c.drawArc(oval, -math.pi / 2, sweep, false, glow);
  c.drawArc(oval, -math.pi / 2, sweep, false, line);
  c.drawArc(oval.deflate(10), math.pi / 2, sweep, false, line);
  // Runes appearing round it as the line passes them.
  for (var i = 0; i < 8; i++) {
    final a = -math.pi / 2 + i * math.pi / 4 + math.pi / 8;
    if ((a + math.pi / 2) > sweep) continue;
    final p = Offset(centre.dx + math.cos(a) * (r - 5), centre.dy + math.sin(a) * (r * 0.35 - 2.5));
    final rune = Path()
      ..moveTo(p.dx, p.dy - 4)
      ..lineTo(p.dx, p.dy + 4)
      ..moveTo(p.dx - 3, p.dy - 2 + (i % 3))
      ..lineTo(p.dx + 3, p.dy + 1 - (i % 2) * 2);
    c.drawPath(rune, line);
  }
}

/// Space, solar: a small planet on its slow way across the face of the
/// sun, dark against it, its orbit a faint line.
void _transit(Canvas c, Size s, double t) {
  final sun = Offset(s.width * 1.02, s.height * 0.48);
  final orbit = Rect.fromCenter(center: sun, width: s.width * 1.5, height: s.height * 0.18);
  c.drawOval(orbit, _stroke(const Color(0xFFFFD080).withValues(alpha: 0.06), 1));
  const cycle = 40.0;
  final a = math.pi * 2 * ((t % cycle) / cycle) + math.pi * 0.85;
  final p = Offset(sun.dx + math.cos(a) * orbit.width / 2, sun.dy + math.sin(a) * orbit.height / 2);
  final front = math.sin(a) > 0;
  _light(c, p, 10, const Color(0xFFFFB040).withValues(alpha: front ? 0.18 : 0.08));
  c.drawCircle(p, 4.5, _fill(front ? const Color(0xFF120A04) : const Color(0xFF6A4A2A)));
}

/// Silver witch: the moon's light breathing high up, mist drifting across,
/// silver motes falling and twinkling, a silver light running down the
/// sides.
void _silverWitchLife(Canvas c, Size s, double t) {
  _light(c, Offset(s.width * 0.37, s.height * 0.235), 130 + 14 * math.sin(t * 0.5),
      const Color(0xFFDDE8FF).withValues(alpha: 0.10 + 0.04 * math.sin(t * 0.5)), mid: 0.25);
  for (var i = 0; i < 3; i++) {
    final y = s.height * (0.35 + i * 0.22);
    final x = ((t * (8 + i * 3) + i * 140) % (s.width + 400)) - 200;
    c.drawOval(
      Rect.fromCenter(center: Offset(x, y), width: 360, height: 70),
      Paint()
        ..shader = ui.Gradient.radial(Offset(x, y), 180,
            [const Color(0xFFC8D4E8).withValues(alpha: 0.07), const Color(0xFFC8D4E8).withValues(alpha: 0)]),
    );
  }
  for (var i = 0; i < 26; i++) {
    const fall = 16.0;
    final age = ((t + i * 1.7) % fall) / fall;
    final x = (i * 61.0 % s.width) + math.sin(t * 0.7 + i) * 16;
    final y = -10 + age * (s.height + 20);
    final tw = 0.5 + 0.5 * math.sin(t * (2 + i % 3) + i);
    c.drawCircle(Offset(x, y), 0.8 + (i % 3) * 0.4, _fill(const Color(0xFFF0F4FF).withValues(alpha: 0.25 + 0.5 * tw)));
  }
  _sigil(c, s, t);
}

/// Space, solar: the sun's glow swelling and easing, now and then a flare
/// lifting off it; gold dust drifting; gold light running down the sides.
void _solarLife(Canvas c, Size s, double t) {
  final sun = Offset(s.width * 1.02, s.height * 0.48);
  final pulse = 0.5 + 0.5 * math.sin(t * 0.6);
  _light(c, sun, s.width * (0.9 + 0.08 * pulse), const Color(0xFFFFB030).withValues(alpha: 0.12 + 0.06 * pulse), mid: 0.25);
  final flare = (t % 11) / 11;
  if (flare < 0.35) {
    final k = flare / 0.35;
    // Off the sun's left limb, where the painting's prominence is.
    final foot = Offset(s.width * 0.2, s.height * 0.36);
    final arc = Path()
      ..moveTo(foot.dx, foot.dy - 30)
      ..quadraticBezierTo(foot.dx - s.width * (0.06 + 0.1 * k), foot.dy - 50 - 40 * k, foot.dx + 6, foot.dy + 34);
    c.drawPath(arc, _glow(const Color(0xFFFF7A20).withValues(alpha: 0.45 * (1 - k)), 6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5);
  }
  for (var d = 0; d < 20; d++) {
    final x = (d * 97.0 + t * (5 + d % 4)) % s.width;
    final y = (d * 151.0 % s.height) + math.sin(t * 0.4 + d) * 10;
    c.drawCircle(Offset(x, y), 0.8 + (d % 3) * 0.3, _fill(const Color(0xFFFFE0A0).withValues(alpha: 0.10 + 0.1 * math.sin(t + d))));
  }
  _transit(c, s, t);
}

/// Black rose: the moon's light at the window breathing, a faint mist
/// drifting low, and dark-red petals falling, each turning slowly as it
/// sways, gone before it reaches the player.
void _blackRoseLife(Canvas c, Size s, double t) {
  // The painting's moon, at its window.
  _light(c, Offset(s.width * 0.9, s.height * 0.19), 110 + 12 * math.sin(t * 0.45),
      const Color(0xFFD8E2FF).withValues(alpha: 0.08 + 0.035 * math.sin(t * 0.45)), mid: 0.25);
  for (var i = 0; i < 2; i++) {
    final y = s.height * (0.62 + i * 0.16);
    final x = ((t * (6 + i * 3) + i * 220) % (s.width + 420)) - 210;
    c.drawOval(
      Rect.fromCenter(center: Offset(x, y), width: 380, height: 64),
      Paint()
        ..shader = ui.Gradient.radial(Offset(x, y), 190,
            [const Color(0xFFB8C4E0).withValues(alpha: 0.05), const Color(0xFFB8C4E0).withValues(alpha: 0)]),
    );
  }
  for (var i = 0; i < 9; i++) {
    final fall = 15.0 + (i % 4) * 3.5;
    final age = ((t + i * 2.9) % fall) / fall;
    // In from the top, out by four fifths down: off the player.
    final y = -16 + age * s.height * 0.84;
    final x = (i * 0.137 + 0.05) % 1 * s.width + math.sin(t * 0.6 + i * 1.3) * 26;
    final fade = math.min(1.0, math.min(age * 8, (1 - age) * 5));
    final turn = t * (0.5 + (i % 3) * 0.25) + i;
    final size = 5.0 + (i % 3) * 1.6;
    c.save();
    c.translate(x, y);
    c.rotate(turn);
    // A petal: wider at its tip, foreshortened as it turns.
    final squash = 0.45 + 0.55 * math.cos(turn * 1.3).abs();
    final petal = Path()
      ..moveTo(0, -size)
      ..cubicTo(size * 0.9 * squash, -size * 0.7, size * 0.7 * squash, size * 0.8, 0, size)
      ..cubicTo(-size * 0.7 * squash, size * 0.8, -size * 0.9 * squash, -size * 0.7, 0, -size);
    c.drawPath(petal, _fill(Color.lerp(const Color(0xFF5E0F1C), const Color(0xFF8E1F30), (i % 3) / 2)!.withValues(alpha: 0.7 * fade)));
    c.drawPath(petal, _stroke(const Color(0xFFE6A0AE).withValues(alpha: 0.12 * fade), 0.6));
    c.restore();
  }
}

/// Dragon slate: embers rising from the foot of the screen, drifting as
/// they go and dimming out; now and then one burns cold, ice-blue.
void _dragonSlateLife(Canvas c, Size s, double t) {
  for (var i = 0; i < 22; i++) {
    final rise = 9.0 + (i % 5) * 2.2;
    final age = ((t + i * 1.37) % rise) / rise;
    final y = s.height * (1.02 - age * 0.9);
    final x = (i * 0.173 + 0.03) % 1 * s.width + math.sin(t * 0.9 + i * 2.1) * (10 + age * 22);
    // Bright as it leaves the coals, out before it reaches the top.
    final a = math.min(1.0, age * 10) * math.pow(1 - age, 1.6).toDouble();
    final flick = 0.75 + 0.25 * math.sin(t * (6 + i % 4) + i);
    final cold = i % 9 == 4;
    final core = cold ? const Color(0xFFA8F0FF) : const Color(0xFFFFC46A);
    final halo = cold ? const Color(0xFF3FC8E0) : const Color(0xFFFF7A1A);
    final r = 0.9 + (i % 3) * 0.45;
    _light(c, Offset(x, y), r * 7, halo.withValues(alpha: 0.18 * a * flick), mid: 0.2);
    c.drawCircle(Offset(x, y), r, _fill(core.withValues(alpha: 0.85 * a * flick)));
  }
  // The coals' glow along the foot, breathing.
  final b = 0.5 + 0.5 * math.sin(t * 0.7);
  c.drawRect(
    Rect.fromLTRB(0, s.height * 0.86, s.width, s.height),
    Paint()
      ..shader = ui.Gradient.linear(Offset(0, s.height * 0.86), Offset(0, s.height), [
        const Color(0xFFFF7A1A).withValues(alpha: 0),
        const Color(0xFFFF7A1A).withValues(alpha: 0.05 + 0.04 * b),
      ]),
  );
}

/// Old tome: a candle's warm light breathing at the upper left, and dust
/// drifting slowly through it, catching the light as it turns.
void _oldTomeLife(Canvas c, Size s, double t) {
  final f = _flicker(t * 0.35, 1.7).clamp(0.0, 1.0);
  _light(c, Offset(s.width * 0.12, s.height * 0.14), s.width * (0.7 + 0.05 * f),
      const Color(0xFFFFB45A).withValues(alpha: 0.06 + 0.05 * f), mid: 0.25);
  for (var i = 0; i < 28; i++) {
    final drift = 40.0 + (i % 5) * 9;
    final age = ((t + i * 3.1) % drift) / drift;
    final x = ((i * 0.191 + 0.02) % 1 + age * 0.18) % 1 * s.width + math.sin(t * 0.3 + i) * 14;
    final y = ((i * 0.317 + 0.05) % 1) * s.height * 0.8 + math.sin(t * 0.22 + i * 1.9) * 24 - age * 30;
    // Brighter nearer the candle, glinting as a mote turns.
    final near = 1 - ((Offset(x, y) - Offset(s.width * 0.12, s.height * 0.14)).distance / s.height).clamp(0.0, 1.0);
    final glint = 0.5 + 0.5 * math.sin(t * (1.1 + (i % 4) * 0.3) + i);
    final fade = math.min(1.0, math.min(age * 6, (1 - age) * 6));
    c.drawCircle(Offset(x, y), 0.7 + (i % 3) * 0.35,
        _fill(const Color(0xFFFFE2B0).withValues(alpha: (0.08 + 0.32 * near * glint) * fade)));
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
    switch (scene.kin) {
      case Scene.dungeon:
        // A candle stub burning on a skull.
        _light(c, m + Offset(0, -s.height * 0.3), s.width * 0.6, _k(scene, const Color(0xFFFF8A2A)).withValues(alpha: 0.35));
        skullAt(c, m + Offset(0, s.height * 0.18), s.width * 0.62);
        final top = m + Offset(0, -s.height * 0.08);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: top + const Offset(0, -6), width: 10, height: 18), const Radius.circular(2)),
            _fill(_k(scene, const Color(0xFFE6D8B8))));
        c.drawPath(
          Path()
            ..moveTo(top.dx - 5, top.dy + 1)
            ..quadraticBezierTo(top.dx - 9, top.dy + 8, top.dx - 4, top.dy + 10),
          _stroke(_k(scene, const Color(0xFFE6D8B8)), 2.4),
        );
        final f = top + const Offset(0, -16);
        c.drawCircle(f + const Offset(0, -4), 8, _glow(_k(scene, const Color(0xFFFF8A20)).withValues(alpha: 0.6), 6));
        c.drawPath(
          Path()
            ..moveTo(f.dx, f.dy - 14)
            ..quadraticBezierTo(f.dx + 6, f.dy - 4, f.dx, f.dy + 1)
            ..quadraticBezierTo(f.dx - 6, f.dy - 4, f.dx, f.dy - 14)
            ..close(),
          Paint()..shader = ui.Gradient.linear(Offset(f.dx, f.dy - 14), Offset(f.dx, f.dy), [_k(scene, const Color(0xFFFF6A10)), _k(scene, const Color(0xFFFFE6A0))]),
        );
      case Scene.forest:
        final r = math.Random(3);
        _light(c, m, s.width * 0.55, _k(scene, const Color(0xFF5AF0D0)).withValues(alpha: 0.25));
        for (var i = 0; i < 3; i++) {
          final p = m + Offset((i - 1) * s.width * 0.2, s.height * 0.25 - (i == 1 ? 8 : 0));
          final k = s.width / 90 * (i == 1 ? 1.25 : 0.9);
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p + Offset(0, -8 * k), width: 7 * k, height: 18 * k), const Radius.circular(3)),
              _fill(_k(scene, const Color(0xFFCFC4A8))));
          c.drawPath(
            Path()
              ..moveTo(p.dx - 16 * k, p.dy - 16 * k)
              ..quadraticBezierTo(p.dx, p.dy - 42 * k, p.dx + 16 * k, p.dy - 16 * k)
              ..close(),
            _fill(_k(scene, const Color(0xFF2FB8A0))),
          );
        }
        for (var i = 0; i < 6; i++) {
          final p = Offset(r.nextDouble() * s.width, r.nextDouble() * s.height * 0.6);
          _light(c, p, 6, _k(scene, const Color(0xFFE6FF6A)).withValues(alpha: 0.6));
          c.drawCircle(p, 1.2, _fill(_k(scene, const Color(0xFFFFF6B0))));
        }
      case Scene.sketch:
        _sketchEmpty(c, s);
      case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
        final r = math.Random(9);
        for (var i = 0; i < 30; i++) {
          c.drawCircle(Offset(r.nextDouble() * s.width, r.nextDouble() * s.height), r.nextDouble() * 0.9 + 0.3,
              _fill(Colors.white.withValues(alpha: 0.3 + r.nextDouble() * 0.5)));
        }
        final p = m + Offset(0, s.height * 0.05);
        c.drawCircle(p, s.width * 0.26,
            Paint()..shader = ui.Gradient.radial(p - Offset(s.width * 0.08, s.width * 0.08), s.width * 0.34, [_k(scene, const Color(0xFFFFCF8A)), _k(scene, const Color(0xFFD0622D)), _k(scene, const Color(0xFF3A1208))], const [0, 0.5, 1]));
        c.drawOval(Rect.fromCenter(center: p, width: s.width * 0.9, height: s.width * 0.16), _stroke(_k(scene, _neon).withValues(alpha: 0.8), 1.6));
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
    switch ((scene.kin, foot)) {
      case (Scene.dungeon, false):
        // Crossed bones behind a skull.
        final m = Offset(s.width / 2, s.height / 2);
        for (final (a, b) in [
          (m + Offset(-s.width * 0.36, -s.height * 0.3), m + Offset(s.width * 0.36, s.height * 0.3)),
          (m + Offset(s.width * 0.36, -s.height * 0.3), m + Offset(-s.width * 0.36, s.height * 0.3)),
        ]) {
          c.drawLine(a, b, _stroke(_k(scene, const Color(0xFF8F7D5C)), 5));
          for (final e in [a, b]) {
            c.drawCircle(e + const Offset(2.5, 2.5), 3.6, _fill(_k(scene, const Color(0xFF9E8C68))));
            c.drawCircle(e - const Offset(2.5, 2.5), 3.6, _fill(_k(scene, const Color(0xFF8F7D5C))));
          }
        }
        skullAt(c, m, s.width * 0.55, cracked: true);
      case (Scene.dungeon, true):
        // A rotting hand reaching up from the rubble, by a candle stub.
        final base = Offset(s.width * 0.42, s.height);
        final hand = Paint()
          ..shader = ui.Gradient.linear(base, base - Offset(0, s.height * 0.8), [_k(scene, const Color(0xFF2A3420)), _k(scene, const Color(0xFF5A6A40)), _k(scene, const Color(0xFF7A8058))], const [0, 0.5, 1]);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(base.dx - 9, base.dy - s.height * 0.45, 18, s.height * 0.45), const Radius.circular(6)), hand);
        final palm = base - Offset(0, s.height * 0.5);
        c.drawOval(Rect.fromCenter(center: palm, width: 30, height: 26), hand);
        for (var i = 0; i < 4; i++) {
          final a = -math.pi / 2 + (i - 1.5) * 0.32;
          final len = s.height * (i == 1 || i == 2 ? 0.3 : 0.24);
          final tip = palm + Offset(math.cos(a), math.sin(a)) * len;
          c.drawLine(palm + Offset((i - 1.5) * 6, -6), tip, _stroke(_k(scene, const Color(0xFF66704A)), 5.2));
          c.drawCircle(tip, 2, _fill(_k(scene, const Color(0xFF2A2018))));
        }
        c.drawLine(palm + const Offset(-12, 4), palm + const Offset(-26, -10), _stroke(_k(scene, const Color(0xFF66704A)), 5.2));
        // Rot and a torn sleeve.
        c.drawCircle(palm + const Offset(4, 4), 3, _fill(_k(scene, const Color(0xFF2A2214))));
        c.drawPath(
          Path()
            ..moveTo(base.dx - 13, base.dy - s.height * 0.2)
            ..lineTo(base.dx + 13, base.dy - s.height * 0.24)
            ..lineTo(base.dx + 13, base.dy)
            ..lineTo(base.dx - 13, base.dy)
            ..close(),
          _fill(_k(scene, const Color(0xFF241A14))),
        );
        // The candle.
        final cnd = Offset(s.width * 0.82, s.height);
        c.drawRect(Rect.fromLTWH(cnd.dx - 5, cnd.dy - 26, 10, 26), _fill(_k(scene, const Color(0xFFE6D8B8))));
        _light(c, cnd - const Offset(0, 34), 36, _k(scene, const Color(0xFFFF8A2A)).withValues(alpha: 0.3));
        c.drawPath(
          Path()
            ..moveTo(cnd.dx, cnd.dy - 42)
            ..quadraticBezierTo(cnd.dx + 5, cnd.dy - 33, cnd.dx, cnd.dy - 28)
            ..quadraticBezierTo(cnd.dx - 5, cnd.dy - 33, cnd.dx, cnd.dy - 42)
            ..close(),
          _fill(_k(scene, const Color(0xFFFFC060))),
        );
      case (Scene.forest, false):
        final m = Offset(s.width / 2, s.height / 2);
        for (var i = 0; i < 14; i++) {
          final a = i / 14 * math.pi * 2;
          leafAt(c, m + Offset(math.cos(a), math.sin(a)) * s.width * 0.3, s.width * 0.16, a + math.pi / 2, r, scene: scene);
        }
        _light(c, m, s.width * 0.2, _k(scene, const Color(0xFFE6FF6A)).withValues(alpha: 0.6));
        c.drawCircle(m, 2.4, _fill(_k(scene, const Color(0xFFFFF6B0))));
      case (Scene.forest, true):
        final rr = math.Random(4);
        final base = Offset(s.width * 0.3, s.height);
        for (var i = 0; i < 3; i++) {
          final p = base + Offset(i * 22.0, -i * 2.0);
          _light(c, p - const Offset(0, 16), 26, _k(scene, const Color(0xFF5AF0D0)).withValues(alpha: 0.3));
          c.drawRect(Rect.fromLTWH(p.dx - 3, p.dy - 16, 6, 16), _fill(_k(scene, const Color(0xFFCFC4A8))));
          c.drawPath(
            Path()
              ..moveTo(p.dx - 14, p.dy - 14)
              ..quadraticBezierTo(p.dx, p.dy - 38, p.dx + 14, p.dy - 14)
              ..close(),
            _fill(_k(scene, const Color(0xFF2FB8A0))),
          );
        }
        for (var i = 0; i < 5; i++) {
          final p = Offset(rr.nextDouble() * s.width, rr.nextDouble() * s.height * 0.6);
          _light(c, p, 6, _k(scene, const Color(0xFFE6FF6A)).withValues(alpha: 0.6));
        }
      case (Scene.sketch, final foot):
        _sketchOrnament(c, s, foot: foot);
      case (Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome, false):
        final m = Offset(s.width / 2, s.height / 2);
        final hex = Path();
        for (var i = 0; i < 6; i++) {
          final a = i / 6 * math.pi * 2 - math.pi / 2;
          final p = m + Offset(math.cos(a), math.sin(a)) * s.width * 0.34;
          i == 0 ? hex.moveTo(p.dx, p.dy) : hex.lineTo(p.dx, p.dy);
        }
        hex.close();
        c.drawPath(hex, _glow(_k(scene, _neon).withValues(alpha: 0.5), 5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4);
        c.drawPath(hex, _stroke(_k(scene, const Color(0xFF9FF6FF)), 1.6)..strokeJoin = StrokeJoin.miter);
        c.drawCircle(m, s.width * 0.1, _fill(_k(scene, _neon).withValues(alpha: 0.8)));
      case (Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome, true):
        for (var i = 0; i < 8; i++) {
          final color = [_k(scene, const Color(0xFF39FF88)), _k(scene, const Color(0xFFFFB13A)), _k(scene, _neon), _k(scene, const Color(0xFFFF4A6A))][r.nextInt(4)];
          final p = Offset(s.width * (0.1 + i * 0.11), s.height - 14);
          _light(c, p, 8, color.withValues(alpha: 0.5));
          c.drawRect(Rect.fromCenter(center: p, width: 5, height: 3), _fill(color));
        }
        c.drawLine(Offset(0, s.height - 30), Offset(s.width, s.height - 30), _glow(_k(scene, const Color(0xFFFF3FD0)).withValues(alpha: 0.5), 4)..strokeWidth = 3);
        c.drawLine(Offset(0, s.height - 30), Offset(s.width, s.height - 30), _stroke(_k(scene, const Color(0xFFFFA8EC)), 1));
    }
  }

  @override
  bool shouldRepaint(_OrnamentPainter old) => old.scene != scene || old.foot != foot;
}

/// A rule between groups: a line of runes in the dungeon, a vine in the
/// forest, a neon rule on the hull.
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
    switch (scene.kin) {
      case Scene.dungeon:
        final rune = _stroke(_k(scene, const Color(0xFF8A6A4A)).withValues(alpha: 0.55), 1.1);
        c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_k(scene, const Color(0xFF3E2E22)), 1));
        final r = math.Random(12);
        for (var x = 10.0; x < s.width - 10; x += 26) {
          c.drawRect(Rect.fromCenter(center: Offset(x, y), width: 9, height: 10), _fill(_k(scene, const Color(0xFF15100C))));
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
        c.drawPath(path, _stroke(_k(scene, const Color(0xFF2E5A2E)), 1.4));
        for (var x = 16.0; x < s.width; x += 34) {
          leafAt(c, Offset(x, y + math.sin(x / 14) * 2), 7, (x ~/ 34).isEven ? -0.6 : 0.6, r, scene: scene);
        }
      case Scene.sketch:
        _sketchDivider(c, s);
      case Scene.solar || Scene.silverWitch || Scene.blackRose || Scene.dragonSlate || Scene.oldTome:
        c.drawLine(Offset(0, y), Offset(s.width, y), _glow(_k(scene, _neon).withValues(alpha: 0.35), 3)..strokeWidth = 2);
        c.drawLine(Offset(0, y), Offset(s.width, y), _stroke(_k(scene, _neon).withValues(alpha: 0.6), 0.8)..strokeCap = StrokeCap.butt);
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
  Widget build(BuildContext context) {
    // Its painting, where it has one: drawn again once it has loaded.
    _loadArt(scene);
    return ValueListenableBuilder<int>(
      valueListenable: sceneArtReady,
      builder: (context, ready, child) => _small(context),
    );
  }

  Widget _small(BuildContext context) => LayoutBuilder(
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
  _PreviewPainter(this.scene) : super(repaint: sceneArtReady);

  final Scene scene;

  @override
  void paint(Canvas canvas, Size size) {
    _loadArt(scene);
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
