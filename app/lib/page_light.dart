import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'prefs.dart';

/// The page's light: how bright the screen is while a book is open, and how
/// warm the page is. [brightness] runs from the dimmest (the phone's lowest,
/// with the page itself darkened below it) to full, and null leaves it as
/// the phone has it; [warmth] runs from none to a deep amber, for reading at
/// night.
///
/// Down to the phone's lowest it is the window's own brightness (the
/// phone's, so it costs nothing to draw); below that, and the amber, are a
/// veil over the page (see [LightVeil]) which the bars and the player are
/// not under.
@immutable
class PageLight {
  const PageLight({this.brightness, this.warmth = 0});

  /// The light as [prefs] keep it.
  factory PageLight.of(ListeningPrefs prefs) => PageLight(brightness: prefs.pageBrightness, warmth: prefs.pageWarmth);

  /// As the phone is: its own brightness, and no amber.
  static const phone = PageLight();

  final double? brightness;
  final double warmth;

  /// The share of the brightness slider below the phone's lowest, where the
  /// page itself is darkened.
  static const below = 0.25;

  /// The share of its light the page keeps at the slider's very end.
  static const deepest = 0.3;

  /// Where the slider's thumb rests while the phone's own brightness is
  /// kept: half way along the phone's part of it.
  static const resting = (1 + below) / 2;

  /// The amber at full warmth: the share of red, green and blue kept. Blue
  /// goes most, as a phone's night light takes it.
  static const _amber = (red: 1.0, green: 0.76, blue: 0.48);

  /// Nothing of its own set: the window and the page as the phone has them.
  bool get isPhone => brightness == null && warmth <= 0;

  /// The window's brightness, 0 (the phone's lowest) to 1, or null for the
  /// phone's own. Squared, so the slider's steps look even: the eye sees a
  /// change in a dim screen's light far more than the same in a bright one's.
  double? get window {
    final b = brightness;
    if (b == null) return null;
    if (b <= below) return 0;
    final t = (b - below) / (1 - below);
    return t * t;
  }

  /// The share of its light the page keeps: all of it, down to [deepest]
  /// below the phone's lowest.
  double get keep {
    final b = brightness;
    if (b == null || b >= below) return 1;
    return deepest + (1 - deepest) * b.clamp(0.0, below) / below;
  }

  /// No veil: the page as it is.
  bool get clear => keep >= 1 && warmth <= 0;

  /// What every colour of the page is multiplied by: white leaves it as it is.
  Color get filter {
    final k = keep;
    final w = warmth.clamp(0.0, 1.0);
    return Color.from(
      alpha: 1,
      red: k * (1 + (_amber.red - 1) * w),
      green: k * (1 + (_amber.green - 1) * w),
      blue: k * (1 + (_amber.blue - 1) * w),
    );
  }

  /// [c] as it is under the veil: for what is drawn over the veil and must
  /// meet the page under it without a seam (the fades into the paper behind
  /// the bars).
  Color lit(Color c) {
    if (clear) return c;
    final f = filter;
    return Color.from(alpha: c.a, red: c.r * f.r, green: c.g * f.g, blue: c.b * f.b);
  }

  @override
  bool operator ==(Object other) => other is PageLight && other.brightness == brightness && other.warmth == warmth;

  @override
  int get hashCode => Object.hash(brightness, warmth);
}

/// The page's [light] over what is under it: one rectangle the page's
/// colours are multiplied by, darker below the phone's lowest brightness and
/// warmer for the night. With [around], only outside those insets: the
/// strips past the safe area, where nothing but the ground is.
///
/// Cheap enough to lie over a page as it scrolls: no layer drawn offscreen
/// and no shader, only a plain colour blended by the graphics hardware as it
/// draws (a multiply, not one of the blends that read the screen back
/// first), and drawn once, not again as the page moves under it (its own
/// repaint boundary). Nothing at all while the light is the phone's.
class LightVeil extends StatelessWidget {
  const LightVeil({super.key, required this.light, this.around});

  final ValueListenable<PageLight> light;
  final EdgeInsets? around;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(size: Size.infinite, painter: _VeilPainter(light, around)),
        ),
      );
}

class _VeilPainter extends CustomPainter {
  _VeilPainter(this.light, this.around) : super(repaint: light);

  final ValueListenable<PageLight> light;
  final EdgeInsets? around;

  @override
  void paint(Canvas canvas, Size size) {
    final l = light.value;
    if (l.clear || size.isEmpty) return;
    // Multiplied into the page rather than laid over it: the amber takes
    // blue out of the light, as a night light does, and black ink stays
    // black (a colour laid over would tint the ink too, and cut the
    // contrast). Drawn pixel for pixel, with no softened edge, so the veils
    // of the page's parts meet with no seam between them.
    final paint = Paint()
      ..color = l.filter
      ..blendMode = BlendMode.modulate
      ..isAntiAlias = false;
    final all = Offset.zero & size;
    final a = around;
    if (a == null) {
      canvas.drawRect(all, paint);
      return;
    }
    final inner = a.deflateRect(all);
    for (final r in [
      Rect.fromLTRB(all.left, all.top, all.right, inner.top),
      Rect.fromLTRB(all.left, inner.bottom, all.right, all.bottom),
      Rect.fromLTRB(all.left, inner.top, inner.left, inner.bottom),
      Rect.fromLTRB(inner.right, inner.top, all.right, inner.bottom),
    ]) {
      if (!r.isEmpty) canvas.drawRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(_VeilPainter old) => old.light != light || old.around != around;
}
