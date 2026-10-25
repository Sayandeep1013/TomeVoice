import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'scheduler.dart';
import 'theme.dart';

/// A soft glow rising from the foot of the box while the voice reads, as
/// tall and bright as the voice is loud at that moment, like breath on cold
/// glass. One haze in the book's colours, its top swelling slowly.
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
    final w = size.width;
    final h = size.height;
    // An ember while the voice draws breath; full when it is loud.
    final energy = 0.18 + 0.82 * voice;
    // Light grounds take colour, they do not give light: less of it, laid on.
    final strength = ((dark ? 0.72 : 0.45) * shown).clamp(0.0, 1.0);
    final blur = h * 0.14;
    final box = Offset.zero & size;

    // One haze whose top is a slow swell of long waves, so no part of it
    // stands apart; it runs past the sides so the blur does not thin there.
    final haze = Path()..moveTo(-blur * 2, h + blur);
    const steps = 32;
    for (var i = 0; i <= steps; i++) {
      final x = -blur * 2 + (w + blur * 4) * i / steps;
      final k = x / w;
      final swell = 0.62 +
          0.22 * math.sin(k * math.pi * 2 + t * 0.35) +
          0.16 * math.sin(k * math.pi * 3.3 - t * 0.5 + 1.3);
      haze.lineTo(x, h - h * 0.8 * energy * swell);
    }
    haze
      ..lineTo(w + blur * 2, h + blur)
      ..close();

    canvas.saveLayer(
      box,
      Paint()
        ..blendMode = dark ? BlendMode.plus : BlendMode.srcOver
        ..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal),
    );
    canvas.drawPath(
      haze,
      Paint()
        ..shader = LinearGradient(colors: [for (final c in colours) c.withValues(alpha: strength)])
            .createShader(box),
    );
    // Brightest at the foot, thinning to nothing as it rises.
    canvas.drawRect(
      box,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xFFFFFFFF), Color(0x8CFFFFFF), Color(0x00FFFFFF)],
          stops: [0, 0.4, 1],
        ).createShader(box),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.colours != colours || old.dark != dark;
}
