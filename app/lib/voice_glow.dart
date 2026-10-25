import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'scheduler.dart';
import 'theme.dart';

/// A soft glow rising from the foot of the box while the voice reads, as
/// tall and bright as the voice is loud at that moment, like breath on cold
/// glass. Lobes in the book's colours drift slowly along it.
///
/// It fades in when reading starts, sinks to an ember between sentences and
/// fades out on pause. Nothing is drawn when the phone is set to remove
/// animations, and the ticker only runs while there is something to show.
class VoiceGlow extends StatefulWidget {
  const VoiceGlow({super.key, required this.level, required this.state, this.dark});

  /// Loudness at the playback head, 0 to 1.
  final ValueListenable<double> level;
  final ValueListenable<PlayState> state;

  /// The light-giving look of the dark theme, on a screen that is always
  /// dark; otherwise it follows the theme.
  final bool? dark;

  @override
  State<VoiceGlow> createState() => _VoiceGlowState();
}

class _VoiceGlowState extends State<VoiceGlow> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_frame);
  final _paint = ValueNotifier<int>(0);
  Duration _last = Duration.zero;

  /// Seconds since the glow last woke, for the drift.
  double _time = 0;

  /// The loudness, followed quickly on the way up and slowly on the way
  /// down, so it swells with each word instead of flickering.
  double _voice = 0;

  /// How present the glow is: 1 while reading, 0 when stopped.
  double _shown = 0;

  bool get _reading => widget.state.value == PlayState.playing;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_wake);
    _wake();
  }

  @override
  void didUpdateWidget(VoiceGlow old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_wake);
      widget.state.addListener(_wake);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_wake);
    _ticker.dispose();
    _paint.dispose();
    super.dispose();
  }

  void _wake() {
    if (_reading && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _frame(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    _time += dt;
    final target = _reading ? widget.level.value : 0.0;
    // Time constants: 70 ms rising, 320 ms falling, 450 ms to come and go.
    _voice += (target - _voice) * (1 - math.exp(-dt / (target > _voice ? 0.07 : 0.32)));
    _shown += ((_reading ? 1.0 : 0.0) - _shown) * (1 - math.exp(-dt / 0.45));
    if (!_reading && _shown < 0.004) {
      _shown = 0;
      _voice = 0;
      _ticker.stop();
    }
    _paint.value++;
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return const SizedBox.shrink();
    final accent = Skin.accentOf(context);
    final hsl = HSLColor.fromColor(accent);
    Color turn(double degrees) => hsl.withHue((hsl.hue + degrees) % 360).toColor();
    final dark = widget.dark ?? Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _GlowPainter(
            repaint: _paint,
            state: this,
            // The accent in the middle, its neighbours on the wheel around it.
            colours: [turn(-34), accent, Skin.accentSoftOf(context), accent, turn(34)],
            dark: dark,
          ),
        ),
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required Listenable repaint, required this.state, required this.colours, required this.dark})
      : super(repaint: repaint);

  final _VoiceGlowState state;
  final List<Color> colours;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final shown = state._shown;
    if (shown <= 0 || size.isEmpty) return;
    final voice = state._voice;
    final t = state._time;
    // An ember while the voice draws breath; full when it is loud.
    final energy = 0.16 + 0.84 * voice;
    // Light grounds take colour, they do not give light: less of it, laid on.
    final strength = (dark ? 0.62 : 0.4) * shown;
    final blend = dark ? BlendMode.plus : BlendMode.srcOver;
    final w = size.width;
    final h = size.height;

    for (var i = 0; i < colours.length; i++) {
      final k = i / (colours.length - 1);
      // Each lobe drifts at its own pace and breathes a little out of step.
      final drift = math.sin(t * (0.23 + 0.07 * i) + i * 1.9) * w * 0.07;
      final breath = 0.82 + 0.18 * math.sin(t * (1.3 + 0.21 * i) + i * 2.4);
      final cx = w * (0.1 + 0.8 * k) + drift;
      final rx = w * 0.3;
      final ry = h * (0.3 + 0.7 * energy * breath);
      final alpha = (strength * (0.55 + 0.45 * energy) * (i == 2 ? 1.0 : 0.85)).clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(cx, h);
      canvas.scale(1, ry / rx);
      canvas.drawCircle(
        Offset.zero,
        rx,
        Paint()
          ..blendMode = blend
          ..shader = RadialGradient(
            colors: [
              colours[i].withValues(alpha: alpha),
              colours[i].withValues(alpha: alpha * 0.35),
              colours[i].withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: rx)),
      );
      canvas.restore();
    }

    // The bright seam along the foot the glow rises from.
    final seam = Rect.fromLTWH(0, h - 3, w, 3);
    canvas.drawRect(
      seam,
      Paint()
        ..blendMode = blend
        ..shader = LinearGradient(
          colors: [
            for (final c in colours)
              c.withValues(alpha: (strength * (0.35 + 0.65 * voice)).clamp(0.0, 1.0)),
          ],
        ).createShader(seam),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.colours != colours || old.dark != dark;
}
