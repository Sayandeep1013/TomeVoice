import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'listen_sheet.dart' show trimSpeed;
import 'player_controls.dart';
import 'prefs.dart';
import 'reader_screen.dart' show wordAt;
import 'scheduler.dart';
import 'theme.dart';
import 'voice_glow.dart';

/// The book filling the screen while it is read: the cover over a blur of
/// itself in the book's colour, and the words scrolling like lyrics, the
/// sentence being read set large with the word under the voice lit.
///
/// Opened by swiping up on the reader's player bar; swipe down to close.
/// Everything it shows and does belongs to the reader, which hands it the
/// same listenables and actions as its player bar.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({
    super.key,
    required this.title,
    required this.cover,
    required this.layout,
    required this.cursor,
    required this.player,
    required this.speed,
    required this.voiceLabel,
    required this.sleepNote,
    required this.onPlay,
    required this.onGoTo,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.moreAfter,
    required this.onSpeed,
    required this.onVoice,
    required this.onSleep,
    required this.onSave,
    required this.onHold,
  });

  final String title;

  /// The shown cover picture, or null for a book without one.
  final String? cover;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final PlaybackScheduler player;

  /// Read when shown, so a change made from a sheet shows at once.
  final double Function() speed;
  final String Function() voiceLabel;
  final String? Function() sleepNote;
  final VoidCallback onPlay;
  final ValueChanged<int> onGoTo;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;

  /// Chapters follow the last one here (a web novel's, still on the site).
  final bool moreAfter;
  final VoidCallback onSpeed;
  final VoidCallback onVoice;
  final VoidCallback onSleep;

  /// Keep the sentence being read as a quote.
  final VoidCallback onSave;

  /// Press and hold on sentence [unit] (on [word] in it, or '' for none):
  /// the reader's menu for it (save, bookmark, share, copy, say it right).
  final void Function(int unit, String word) onHold;

  @override
  Widget build(BuildContext context) {
    final accent = Skin.accentOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Backdrop(cover: cover, accent: accent),
            // The voice, rising from the foot of the screen as it reads.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 300,
              child: VoiceGlow(level: player.level, state: player.state, dark: true),
            ),
            SafeArea(
              child: OrientationBuilder(
                builder: (context, orientation) => orientation == Orientation.landscape
                    ? Stack(
                        children: [
                          Row(
                            children: [
                              Expanded(flex: 2, child: Center(child: _art(context))),
                              Expanded(flex: 3, child: _panel(context, compact: true)),
                            ],
                          ),
                          Positioned(
                            left: Gap.xs,
                            top: Gap.xs,
                            child: IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          _closeBar(context),
                          Expanded(flex: 5, child: Center(child: _art(context))),
                          Expanded(flex: 6, child: _panel(context, compact: false)),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _closeBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.s, Gap.xs, Gap.s, 0),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white),
            ),
            Expanded(
              child: Text(
                'NOW READING',
                textAlign: TextAlign.center,
                style: Skin.meta(context, color: Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
      );

  Widget _art(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.card),
              boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 32, offset: Offset(0, 16))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: cover == null
                  ? _DrawnCover(title: title)
                  : Image.file(File(cover!), fit: BoxFit.cover, cacheWidth: 600, gaplessPlayback: true),
            ),
          ),
        ),
      );

  Widget _panel(BuildContext context, {required bool compact}) => Padding(
        padding: EdgeInsets.fromLTRB(Gap.xl, compact ? Gap.l : 0, Gap.xl, Gap.l),
        child: ListenableBuilder(
          listenable: Listenable.merge([cursor, ListeningPrefs.revision]),
          builder: (context, _) {
            final u = cursor.value.clamp(0, layout.units.isEmpty ? 0 : layout.units.length - 1);
            final empty = layout.isEmpty;
            final chapter = empty ? 0 : layout.chapterOfUnit(u);
            final (first, count) = empty ? (0, 1) : layout.chapterRange(chapter);
            final inChapter = (u - first).clamp(0, count - 1);
            final end = first + count;
            final wordsLeft = empty ? 0 : (end < layout.units.length ? layout.wordsBefore[end] : layout.totalWords) -
                layout.wordsBefore[u];
            final minutes = (wordsLeft / (165 * speed())).round();
            final sleep = sleepNote();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.title(context, size: 24, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  empty ? '' : layout.chapterTitle(chapter).toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.meta(context, color: Colors.white.withValues(alpha: 0.62)),
                ),
                const SizedBox(height: Gap.m),
                Expanded(child: _Lyrics(layout: layout, unit: u, player: player, onTap: onGoTo, onHold: onHold)),
                const SizedBox(height: Gap.s),
                ChapterScrubber(
                  value: count <= 1 ? 0 : inChapter / (count - 1),
                  onSeek: count <= 1 ? null : (f) => onGoTo(first + (f * (count - 1)).round()),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    [
                      minutes < 1 ? 'UNDER A MINUTE LEFT' : '${_duration(minutes)} LEFT IN CHAPTER',
                      if (sleep != null) sleep,
                    ].join('  ·  '),
                    textAlign: TextAlign.end,
                    style: Skin.meta(context, size: 10.5, color: Colors.white.withValues(alpha: 0.55)),
                  ),
                ),
                const SizedBox(height: Gap.s),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _icon(Icons.skip_previous_rounded, 'Previous chapter', chapter > 0 ? onPrevChapter : null),
                    _icon(Icons.fast_rewind_rounded, 'Previous sentence', u > 0 ? () => onGoTo(u - 1) : null),
                    PlayButton(player: player, onTap: empty ? null : onPlay),
                    _icon(Icons.fast_forward_rounded, 'Next sentence',
                        u < layout.units.length - 1 ? () => onGoTo(u + 1) : null),
                    _icon(Icons.skip_next_rounded, 'Next chapter',
                        chapter < layout.chapters.length - 1 || moreAfter ? onNextChapter : null),
                  ],
                ),
                const SizedBox(height: Gap.m),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _chip(context, '${trimSpeed(speed())}×', Icons.speed_rounded, onSpeed),
                    _chip(context, sleep == null ? 'Sleep' : 'Sleep on', Icons.bedtime_outlined, onSleep),
                    _chip(context, 'Save', Icons.bookmark_add_outlined, onSave),
                    _chip(context, voiceLabel(), Icons.record_voice_over_rounded, onVoice),
                  ],
                ),
              ],
            );
          },
        ),
      );

  Widget _icon(IconData icon, String tip, VoidCallback? onTap) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: 30,
        color: Colors.white,
        disabledColor: Colors.white.withValues(alpha: 0.25),
        icon: Icon(icon),
      );

  Widget _chip(BuildContext context, String label, IconData icon, VoidCallback onTap) => Flexible(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Material(
            color: Colors.white.withValues(alpha: 0.10),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 9),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: Skin.accentSoftOf(context)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.ui(size: 13, weight: FontWeight.w600, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

String _duration(int minutes) {
  if (minutes < 60) return '${minutes}M';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}H' : '${h}H ${m}M';
}

/// The cover blurred to colour, under a scrim that keeps white text legible,
/// washed with the book's accent. Without a cover, the accent alone.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.cover, required this.accent});

  final String? cover;
  final Color accent;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Color.lerp(accent, Colors.black, 0.72)!),
          if (cover != null)
            // Its own layer: the blur is drawn once, not again on every frame
            // of the slide up.
            RepaintBoundary(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36, tileMode: TileMode.clamp),
                // A small decode is all a blur needs, and keeps it cheap.
                child: Image.file(File(cover!), fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.30),
                  Color.lerp(accent, Colors.black, 0.80)!.withValues(alpha: 0.78),
                  Colors.black.withValues(alpha: 0.92),
                ],
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
        ],
      );
}

/// The sentence before (dim), the one being read (large, its word lit) and
/// the next (dim). Tap one to read from it.
class _Lyrics extends StatefulWidget {
  const _Lyrics({required this.layout, required this.unit, required this.player, required this.onTap, required this.onHold});

  final ReadingLayout layout;
  final int unit;
  final PlaybackScheduler player;
  final ValueChanged<int> onTap;
  final void Function(int unit, String word) onHold;

  @override
  State<_Lyrics> createState() => _LyricsState();
}

class _LyricsState extends State<_Lyrics> {
  /// Moving on through the book (the text pushes up) or back (down).
  bool _forward = true;

  @override
  void didUpdateWidget(_Lyrics old) {
    super.didUpdateWidget(old);
    if (widget.unit != old.unit) _forward = widget.unit > old.unit;
  }

  /// The old sentence leaves first, fading out over the first half; the new
  /// one rises in after it, so the two never sit on top of each other
  /// half-faded. Both keep to the top: blocks of different heights don't jump.
  Widget _push(Widget child, Animation<double> a) => AnimatedBuilder(
        animation: a,
        child: child,
        builder: (context, child) {
          // Arriving or leaving is read from the animation as it runs: the
          // switcher keeps the transition it built for a child when it
          // arrived, also while that child leaves (its animation then runs
          // backwards, from 1 to 0).
          final leaving = a.status == AnimationStatus.reverse || a.status == AnimationStatus.dismissed;
          final dir = _forward ? 1.0 : -1.0;
          final t = a.value;
          final opacity = leaving
              ? const Interval(0.5, 1, curve: Curves.easeIn).transform(t)
              : const Interval(0.35, 1, curve: Curves.easeOut).transform(t);
          final dy = leaving ? -0.1 * dir * (1 - Curves.easeIn.transform(t)) : 0.1 * dir * (1 - Motion.out.transform(t));
          return Opacity(opacity: opacity, child: FractionalTranslation(translation: Offset(0, dy), child: child));
        },
      );

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    final unit = widget.unit;
    final player = widget.player;
    final onTap = widget.onTap;
    final onHold = widget.onHold;
    if (layout.isEmpty) return const SizedBox.shrink();
    final dim = Skin.ui(size: 14, weight: FontWeight.w400, color: Colors.white.withValues(alpha: 0.38))
        .copyWith(height: 1.35);
    const read = TextStyle(
      fontFamily: 'Newsreader',
      fontSize: 23,
      height: 1.32,
      color: Colors.white,
    );
    Widget line(int u, TextStyle style, int maxLines) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(u),
          onLongPress: () => onHold(u, ''),
          child: Text(layout.units[u].text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style),
        );
    return LayoutBuilder(
      builder: (context, box) {
        // Too short for three lines (a small screen on its side): only the
        // one being read, so it is never squeezed out.
        final roomy = box.maxHeight >= 160;
        return ClipRect(
          child: AnimatedSwitcher(
            duration: Motion.of(context, _sentenceChange),
            transitionBuilder: _push,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: Column(
              key: ValueKey(unit),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (roomy && unit > 0) line(unit - 1, dim, 2),
                const SizedBox(height: Gap.s),
                Flexible(
                  // Press and hold: the word under the finger, found as the
                  // reader finds it.
                  child: LayoutBuilder(
                    builder: (context, box) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: (d) {
                        final text = layout.units[unit].text;
                        final painter = TextPainter(
                          text: TextSpan(text: text, style: read),
                          textDirection: TextDirection.ltr,
                          textScaler: MediaQuery.textScalerOf(context),
                        )..layout(maxWidth: box.maxWidth);
                        final at = painter.getPositionForOffset(d.localPosition).offset;
                        painter.dispose();
                        onHold(unit, wordAt(text, at));
                      },
                      child: ValueListenableBuilder<WordMark>(
                        valueListenable: player.word,
                        builder: (context, word, _) {
                          final text = layout.units[unit].text;
                          final on = word.unit == unit && word.start >= 0 && word.end > word.start;
                          final ws = on ? word.start.clamp(0, text.length) : 0;
                          final we = on ? word.end.clamp(ws, text.length) : 0;
                          return Text.rich(
                            TextSpan(children: [
                              TextSpan(text: text.substring(0, ws)),
                              if (on)
                                TextSpan(text: text.substring(ws, we), style: TextStyle(color: Skin.accentSoftOf(context))),
                              TextSpan(text: text.substring(we)),
                            ]),
                            style: read,
                            overflow: TextOverflow.fade,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.s),
                if (roomy && unit + 1 < layout.units.length) line(unit + 1, dim, 2),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Long enough to follow the line upwards; short beside a sentence.
const _sentenceChange = Duration(milliseconds: 380);

/// A plain cover for a book without a picture: its title on the accent.
class _DrawnCover extends StatelessWidget {
  const _DrawnCover({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Color.lerp(Skin.accentOf(context), Colors.black, 0.35)!,
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Text(title, style: Skin.title(context, size: 22, color: Colors.white)),
          ),
        ),
      );
}
