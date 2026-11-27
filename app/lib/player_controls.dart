import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'motion.dart';
import 'scene.dart' show Scene, SketchDiscPainter;
import 'scheduler.dart';
import 'slider_shapes.dart';
import 'tap_log.dart';
import 'theme.dart';
import 'ui.dart';

// The play button and chapter scrubber, shared by the reader's player bar
// and the Now Playing screen.

/// [minutes] as the player bar and Now Playing write a time left: "45M",
/// "2H", "1H 5M".
String durationLabel(int minutes) {
  if (minutes < 60) return '${minutes}M';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}H' : '${h}H ${m}M';
}

/// Play or pause, with a ring while the first sentence is being made.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.player, required this.onTap, this.voice});

  final PlaybackScheduler player;
  final VoidCallback? onTap;

  /// Whether the voice reads, when it is not [player]'s: this book reading
  /// on in the background while the page shows another chapter.
  final ValueListenable<bool>? voice;

  @override
  Widget build(BuildContext context) {
    final voice = this.voice;
    // One shape whichever voice it follows: a builder of the page's play
    // state for one and of a bool for the other, the whole button was
    // built anew (a press on it lost) when the voice moved between them.
    return ListenableBuilder(
      listenable: voice ?? player.state,
      builder: (context, _) =>
          _button(context, voice == null ? player.state.value : (voice.value ? PlayState.playing : PlayState.paused)),
    );
  }

  Widget _button(BuildContext context, PlayState state) {
          final speaking = state == PlayState.playing || state == PlayState.loading;
          return Tooltip(
            message: speaking ? 'Pause' : 'Play',
            child: SizedBox(
              width: 62,
              height: 62,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // The ring fades in and out rather than popping, and is
                  // gone (not spinning unseen) once it has. Each turn of it
                  // is faded on its own, keyed by when it came, not by what
                  // it is: loading and playing taking turns faster than the
                  // fade left two rings on their way out, keyed alike.
                  AnimatedSwitcher(
                    duration: Motion.of(context, Motion.quick),
                    transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
                    child: state == PlayState.loading
                        ? SizedBox(
                            key: const ValueKey('ring'),
                            width: 60,
                            height: 60,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Skin.accentInkOf(context)),
                          )
                        : const SizedBox(width: 60, height: 60),
                  ),
                  Jelly.listen(
                    strength: 1.3,
                    child: tapTagged(
                    'Play',
                    speaking ? 'Pause' : 'Play',
                    Material(
                    color: onTap == null ? Skin.accentOf(context).withValues(alpha: 0.4) : Skin.accentOf(context),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: tapAnswered(speaking ? 'Pause' : 'Play', onTap),
                      // On the board, a painted disc: grain and a chalk rim.
                      child: CustomPaint(
                        foregroundPainter: Skin.sceneOf(context) == Scene.sketch
                            ? SketchDiscPainter(Skin.accentOf(context))
                            : null,
                        child: SizedBox(
                        width: 54,
                        height: 54,
                        // Play and pause turn into each other: the new one
                        // spins in from small and pops a touch past its size,
                        // the old one fades; the press answered at once.
                        child: AnimatedSwitcher(
                          duration: Motion.of(context, const Duration(milliseconds: 380)),
                          reverseDuration: Motion.of(context, Motion.quick),
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a.drive(CurveTween(curve: const Interval(0, 0.45))),
                            child: RotationTransition(
                              turns: a.drive(Tween(begin: -0.12, end: 0.0).chain(CurveTween(curve: Motion.pop))),
                              child: ScaleTransition(
                                scale: a.drive(Tween(begin: 0.6, end: 1.0).chain(CurveTween(curve: Motion.pop))),
                                child: child,
                              ),
                            ),
                          ),
                          child: Skin.icon(
                            context,
                            speaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            key: ValueKey(speaking),
                            size: 32,
                            color: Skin.onAccentOf(context),
                          ),
                        ),
                      ),
                      ),
                    ),
                  ),
                  ),
                  ),
                ],
              ),
            ),
          );
  }
}

/// Position within the chapter. Drag or tap to jump.
class ChapterScrubber extends StatefulWidget {
  const ChapterScrubber({super.key, required this.value, required this.onSeek, this.above = 0, this.below = 0});

  final double value;
  final ValueChanged<double>? onSeek;

  /// It is drawn 26 dp tall: a tap this far over it and under it still
  /// reaches it, as much of a finger's 48 dp as its place has room for (see
  /// TapBand).
  final double above;
  final double below;

  @override
  State<ChapterScrubber> createState() => _ChapterScrubberState();
}

class _ChapterScrubberState extends State<ChapterScrubber> {
  double? _drag;

  /// A new chapter began: the thumb starts it again at once. Gliding back
  /// across the whole bar read as the chapter rewinding.
  bool _restart = false;

  @override
  void didUpdateWidget(ChapterScrubber old) {
    super.didUpdateWidget(old);
    _restart = widget.value < old.value - 0.5;
  }

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          inactiveTrackColor: Skin.onDark(context).withValues(alpha: 0.14),
          trackHeight: 4,
          thumbShape: const PillThumbShape(width: 32, height: 14),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: TapBand(
          above: widget.above,
          below: widget.below,
          child: SizedBox(
            height: 26,
            // The thumb glides from sentence to sentence instead of stepping;
            // under a finger it follows at once.
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: (_drag ?? widget.value).clamp(0.0, 1.0)),
              duration: _drag != null || _restart ? Duration.zero : Motion.of(context, Motion.standard),
              curve: Motion.out,
              builder: (context, value, _) => Slider(
                value: value.clamp(0.0, 1.0),
                semanticFormatterCallback: (v) => 'Chapter position ${(v * 100).round()} percent',
                onChanged: widget.onSeek == null ? null : (v) => setState(() => _drag = v),
                onChangeEnd: widget.onSeek == null
                    ? null
                    : (v) {
                        setState(() => _drag = null);
                        widget.onSeek!(v);
                      },
              ),
            ),
          ),
        ),
      );
}
