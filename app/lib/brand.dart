import 'package:flutter/material.dart';

import 'theme.dart';

/// The TomeVoice mark: two facing pages with an amber spine gap.
///
/// The gap is the product — word separation — drawn as the thing that holds
/// the book together. Used in chrome only; never as the text being read.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.asset(
        'assets/brand/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _BrandPainter(dark: Skin.isDark(context))),
        ),
      ),
    );
  }
}

class _BrandPainter extends CustomPainter {
  const _BrandPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = dark ? const Color(0xFFF2EADA) : const Color(0xFF14170F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.045
      ..strokeJoin = StrokeJoin.round;
    final page = Paint()
      ..color = dark
          ? const Color(0xFF2A2E24)
          : const Color(0xFFF7F0E4)
      ..style = PaintingStyle.fill;
    final amber = Paint()
      ..color = const Color(0xFFE07B39)
      ..style = PaintingStyle.fill;

    final inset = size.width * 0.12;
    final gap = size.width * 0.07;
    final top = size.height * 0.18;
    final bot = size.height * 0.82;
    final mid = size.width / 2;
    final radius = Radius.circular(size.width * 0.08);

    final left = RRect.fromLTRBAndCorners(
      inset,
      top,
      mid - gap / 2,
      bot,
      topLeft: radius,
      bottomLeft: radius,
    );
    final right = RRect.fromLTRBAndCorners(
      mid + gap / 2,
      top,
      size.width - inset,
      bot,
      topRight: radius,
      bottomRight: radius,
    );

    canvas.drawRRect(left, page);
    canvas.drawRRect(right, page);
    canvas.drawRRect(left, ink);
    canvas.drawRRect(right, ink);

    canvas.drawRRect(
      RRect.fromLTRBR(
        mid - gap / 2,
        top + size.height * 0.06,
        mid + gap / 2,
        bot - size.height * 0.06,
        Radius.circular(gap),
      ),
      amber,
    );

    final wave = Paint()
      ..color = const Color(0xFFE07B39)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.04
      ..strokeCap = StrokeCap.round;
    for (final t in [0.72, 0.84]) {
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(size.width * 0.78, size.height * 0.38),
          radius: size.width * (t - 0.55),
        ),
        -0.7,
        1.4,
        false,
        wave,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BrandPainter old) => old.dark != dark;
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
          style: Skin.title(context, size: compact ? 16 : 20),
        ),
      ],
    );
  }
}
