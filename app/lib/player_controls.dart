import 'package:flutter/material.dart';

import 'scheduler.dart';
import 'theme.dart';

// The play button and chapter scrubber, shared by the reader's player bar
// and the Now Playing screen.

/// Play or pause, with a ring while the first sentence is being made.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.player, required this.onTap});

  final PlaybackScheduler player;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayState>(
        valueListenable: player.state,
        builder: (context, state, _) {
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
                  if (state == PlayState.loading)
                    SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Skin.accentSoftOf(context)),
                    ),
                  Material(
                    color: onTap == null ? Skin.accentOf(context).withValues(alpha: 0.4) : Skin.accentOf(context),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onTap,
                      child: SizedBox(
                        width: 54,
                        height: 54,
                        child: Icon(
                          speaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 32,
                          color: Skin.onAccentOf(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

/// Position within the chapter. Drag or tap to jump.
class ChapterScrubber extends StatefulWidget {
  const ChapterScrubber({super.key, required this.value, required this.onSeek});

  final double value;
  final ValueChanged<double>? onSeek;

  @override
  State<ChapterScrubber> createState() => _ChapterScrubberState();
}

class _ChapterScrubberState extends State<ChapterScrubber> {
  double? _drag;

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          inactiveTrackColor: Skin.onDark(context).withValues(alpha: 0.14),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: SizedBox(
          height: 26,
          child: Slider(
            value: (_drag ?? widget.value).clamp(0.0, 1.0),
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
      );
}
