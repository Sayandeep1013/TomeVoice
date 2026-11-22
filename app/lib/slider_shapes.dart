import 'package:flutter/material.dart';

/// The app's sliders: a track set into the page (a shade along its top
/// edge, as if pressed in), filled up to the thumb; and a thumb shaped as a
/// horizontal pill to pull, raised on a soft shadow, that grows and lifts
/// while it is held.
class InsetTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const InsetTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(parentBox: parentBox, offset: offset, sliderTheme: sliderTheme);
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final radius = Radius.circular(rect.height / 2);
    final whole = RRect.fromRectAndRadius(rect, radius);
    final inactive = sliderTheme.inactiveTrackColor ?? Colors.grey;
    final active = sliderTheme.activeTrackColor ?? Colors.amber;
    final shade = Color.lerp(inactive, Colors.black, 0.35)!.withValues(alpha: (inactive.a * 1.6).clamp(0, 1));

    // The groove: darker along its top, as light falls into it.
    canvas.drawRRect(
      whole,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [shade, inactive],
          stops: const [0, 0.7],
        ).createShader(rect),
    );

    // Filled up to the thumb (from the right, in a right-to-left page).
    final ltr = textDirection == TextDirection.ltr;
    final filled = ltr
        ? Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx.clamp(rect.left, rect.right), rect.bottom)
        : Rect.fromLTRB(thumbCenter.dx.clamp(rect.left, rect.right), rect.top, rect.right, rect.bottom);
    if (filled.width > 0) {
      final colour = isEnabled ? active : (sliderTheme.disabledActiveTrackColor ?? active.withValues(alpha: 0.4));
      canvas.drawRRect(
        RRect.fromRectAndRadius(filled, radius),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(colour, Colors.white, 0.18)!, colour],
          ).createShader(filled),
      );
    }
  }
}

/// A horizontal pill to pull, with two grip lines; it grows a little and
/// lifts while held.
class PillThumbShape extends SliderComponentShape {
  const PillThumbShape({this.width = 26, this.height = 16});

  final double width;
  final double height;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width + 8, height + 6);

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
    final canvas = context.canvas;
    final held = activationAnimation.value;
    final w = width + 8 * held, h = height + 3 * held;
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final pill = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));
    final colour = Color.lerp(
      sliderTheme.disabledThumbColor ?? Colors.grey,
      sliderTheme.thumbColor ?? Colors.amber,
      enableAnimation.value,
    )!;
    canvas.drawShadow(Path()..addRRect(pill), Colors.black, 1.5 + 3 * held, true);
    canvas.drawRRect(
      pill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(colour, Colors.white, 0.22)!, colour],
        ).createShader(rect),
    );
    // A fine light edge along the top.
    canvas.drawRRect(
      pill.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.28),
    );
    // Grip lines.
    final grip = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = (colour.computeLuminance() > 0.5 ? Colors.black : Colors.white).withValues(alpha: 0.45);
    for (final dx in const [-2.5, 2.5]) {
      canvas.drawLine(center + Offset(dx, -h * 0.22), center + Offset(dx, h * 0.22), grip);
    }
  }
}
