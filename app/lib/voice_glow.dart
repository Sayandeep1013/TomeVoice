import 'dart:async';
import 'dart:math' as math;

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
/// animations.
///
/// Kept cheap, as it runs the whole time a book is read: soft gradients
/// rather than a blur, redrawn about thirty times a second (the loudness
/// itself only changes every 40 ms), and not at all while it cannot be seen.
/// Each picture is drawn on a frame of the display, a steady number of
/// frames apart (see [_VoiceGlowState._rest]).
/// A blurred layer redrawn every frame competed with everything else on the
/// screen, and scrolling and transitions dropped frames.
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

class _VoiceGlowState extends State<VoiceGlow> {
  /// How long to wait after a picture before asking for the next frame.
  ///
  /// A plain 33 ms timer drifted against the display: its pictures came
  /// mostly two frames apart, but every second or so one came after one
  /// frame and the next after three, a hitch in a glow meant to breathe.
  /// Now the next picture is drawn on the first frame after 26 ms, which is
  /// 33 ms on at 60, 90 and 120 Hz alike (two, three or four frames), and
  /// its time is taken on that frame. A ticker would do it too, but would
  /// wake every frame of the whole reading for a picture every few.
  static const _rest = Duration(milliseconds: 26);

  Timer? _timer;
  int? _frame;
  bool get _running => _timer != null || _frame != null;
  final _clock = Stopwatch();
  final _paint = ValueNotifier<int>(0);
  int _last = 0;

  /// False while another screen covers this one.
  bool _current = true;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
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
    _timer?.cancel();
    if (_frame != null) SchedulerBinding.instance.cancelFrameCallbackWithId(_frame!);
    _paint.dispose();
    super.dispose();
  }

  void _wake() {
    if (_reading && !_running) {
      _clock
        ..reset()
        ..start();
      _last = 0;
      _next();
    }
  }

  /// Under another screen, or the app away: nothing is drawn.
  bool get _visible => _current && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// The next step after a rest: on a frame while the glow can be seen, so
  /// the picture keeps time with the display; on the timer alone while it
  /// cannot, where no frame is wanted.
  void _next() {
    _timer = Timer(_rest, () {
      _timer = null;
      if (!mounted) return;
      if (_visible) {
        _frame = SchedulerBinding.instance.scheduleFrameCallback((_) {
          _frame = null;
          if (mounted) _step();
        });
      } else {
        _step();
      }
    });
  }

  void _step() {
    final now = _clock.elapsedMicroseconds;
    final dt = ((now - _last) / 1e6).clamp(0.0, 0.1);
    _last = now;
    _time += dt;
    final target = _reading ? widget.level.value : 0.0;
    // Time constants: 70 ms rising, 320 ms falling, 450 ms to come and go.
    _voice += (target - _voice) * (1 - math.exp(-dt / (target > _voice ? 0.07 : 0.32)));
    _shown += ((_reading ? 1.0 : 0.0) - _shown) * (1 - math.exp(-dt / 0.45));
    final done = !_reading && _shown < 0.004;
    if (done) {
      _shown = 0;
      _voice = 0;
    }
    // Under another screen, or the app away: keep time, draw nothing.
    if (_visible) _paint.value++;
    if (!done) _next();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return const SizedBox.shrink();
    final accent = Skin.accentOf(context);
    final hsl = HSLColor.fromColor(accent);
    // Hues close around the accent, all at one lightness: an even haze with
    // no colour brighter than the rest to stand out as a patch.
    Color tone(double degrees) => hsl
        .withHue((hsl.hue + degrees) % 360)
        .withSaturation(math.min(1, hsl.saturation * 0.8 + 0.2))
        .withLightness(0.62)
        .toColor();
    final dark = widget.dark ?? Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _GlowPainter(
            repaint: _paint,
            state: this,
            colours: [tone(-24), tone(-8), tone(0), tone(8), tone(24)],
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
    // Light grounds take colour, they do not give light: less of it.
    final strength = ((dark ? 0.75 : 0.48) * shown).clamp(0.0, 1.0);
    // Nine wide, soft lobes along the foot, each overlapping four others,
    // their heights following one slow swell: together one haze, with no
    // lobe standing apart and no blur to pay for.
    const lobes = 9;
    final rx = w * 0.32;
    for (var i = 0; i < lobes; i++) {
      final k = -0.1 + 1.2 * i / (lobes - 1);
      final swell = 0.62 +
          0.22 * math.sin(k * math.pi * 2 + t * 0.35) +
          0.16 * math.sin(k * math.pi * 3.3 - t * 0.5 + 1.3);
      final ry = math.max(h * 0.12, h * 0.85 * energy * swell);
      final colour = _along(k.clamp(0.0, 1.0));
      final a = strength * 0.42;
      canvas.save();
      canvas.translate(w * k, h);
      canvas.scale(1, ry / rx);
      canvas.drawCircle(
        Offset.zero,
        rx,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colour.withValues(alpha: a),
              colour.withValues(alpha: a * 0.55),
              colour.withValues(alpha: a * 0.18),
              colour.withValues(alpha: 0),
            ],
            stops: const [0, 0.35, 0.65, 1],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: rx)),
      );
      canvas.restore();
    }
  }

  /// The colour [k] of the way along the foot.
  Color _along(double k) {
    final x = k * (colours.length - 1);
    final i = x.floor().clamp(0, colours.length - 2);
    return Color.lerp(colours[i], colours[i + 1], x - i)!;
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.colours != colours || old.dark != dark;
}
