import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'listen_sheet.dart' show trimSpeed;
import 'player_controls.dart';
import 'scheduler.dart';
import 'theme.dart';
import 'ui.dart';

/// The reader's player: what is playing, how fast, in whose voice, and the
/// controls; upright a bar under the text, on its side a dock over it.
class ReaderPlayerBar extends StatelessWidget {
  const ReaderPlayerBar({
    super.key,
    required this.layout,
    required this.cursor,
    required this.player,
    required this.speed,
    required this.voiceLabel,
    this.sleepNote,
    required this.onPlay,
    required this.onPrevSentence,
    required this.onNextSentence,
    required this.onPrevChapter,
    required this.onNextChapter,
    this.moreAfter = false,
    this.progressOf,
    required this.onSeekInChapter,
    required this.onSpeed,
    required this.onVoice,
    required this.onExpand,
    this.dock = false,
    this.title = '',
    this.cover,
    this.onSleep,
    this.onSave,
  });

  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final PlaybackScheduler player;
  final double speed;
  final String voiceLabel;
  final String? sleepNote;
  final VoidCallback onPlay;
  final VoidCallback onPrevSentence;
  final VoidCallback onNextSentence;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;

  /// Chapters follow the last one here (a web novel's, still on the site).
  final bool moreAfter;

  /// As [ReaderScreen.progressOf]. When set, this layout is only part of
  /// the work, so the time shown is what is left of the chapter.
  final double Function(int u)? progressOf;
  final ValueChanged<int> onSeekInChapter;
  final VoidCallback onSpeed;
  final VoidCallback onVoice;

  /// Open Now Playing: swipe the bar up, or tap its handle.
  final VoidCallback onExpand;

  /// A phone on its side: one floating row over the text (see [_dock]).
  final bool dock;

  /// The book and its shown cover, for the dock.
  final String title;
  final String? cover;
  final VoidCallback? onSleep;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -250) onExpand();
        },
        child: dock ? _dock(context) : _bar(context),
      );

  /// Where [u] stands: its chapter, the chapter's span, the minutes left and
  /// how far through (of the chapter when this layout is part of the work).
  ({int chapter, int first, int count, int minutes, int pct}) _at(int u) {
    if (layout.isEmpty) return (chapter: 0, first: 0, count: 1, minutes: 0, pct: 0);
    final chapter = layout.chapterOfUnit(u);
    final (first, count) = layout.chapterRange(chapter);
    final end = first + count;
    final upTo = progressOf != null && end < layout.units.length ? layout.wordsBefore[end] : layout.totalWords;
    final wordsLeft = upTo - layout.wordsBefore[u];
    return (
      chapter: chapter,
      first: first,
      count: count,
      minutes: (wordsLeft / (165 * speed)).round(),
      pct: ((progressOf?.call(u) ?? progressFraction(layout.units, u)) * 100).round(),
    );
  }

  /// The handle's drawing: says the bar swipes up to Now Playing. What a tap
  /// on it reaches is [_opener]'s (the bar's) or the dock's own strip.
  Widget _handle(BuildContext context, {double above = 0, double below = 6}) => IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(top: above, bottom: below),
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Skin.onDark(context).withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );

  /// [child] (the handle and the row under it) over what opens Now Playing
  /// on a tap: the whole of it, more than a finger's 48 dp tall, though the
  /// handle is drawn 4 dp thin. What can be tapped in it (the chips) is
  /// still its own; the rest of it is passed through to here.
  Widget _opener(Widget child) => Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              container: true,
              button: true,
              label: 'Open Now Playing',
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onExpand),
            ),
          ),
          child,
        ],
      );

  /// Landscape: everything the portrait bar has, and sleep and save, as one
  /// floating row in the book's colour, so the text keeps the screen's height
  /// (the bar as a column beside it left half the column empty).
  Widget _dock(BuildContext context) {
    final onDark = Skin.onDark(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 980),
      margin: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.s),
      // The top's room is the handle's (see below).
      padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.xs),
      decoration: BoxDecoration(
        color: Color.lerp(Skin.darkOn(context), Skin.accentOf(context), 0.16),
        borderRadius: BorderRadius.circular(Radii.card + 4),
        boxShadow: Skin.lift(context),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: cursor,
        builder: (context, u, _) {
          final empty = layout.isEmpty;
          final at = _at(u);
          final inChapter = (u - at.first).clamp(0, at.count - 1);
          final partial = progressOf != null;
          final left = partial ? '${durationLabel(at.minutes)} left in chapter' : '${durationLabel(at.minutes)} left';
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The whole strip above the row opens Now Playing, not only
              // the thin handle drawn in it. A screen reader is offered the
              // cover instead, the dock's own 48 dp way in.
              ExcludeSemantics(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onExpand,
                  child: _handle(context, above: Gap.s, below: 2),
                ),
              ),
              // Three parts: the book at the left and the options at the
              // right share what is left equally, so the controls sit in the
              // very middle of the bar.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        // The cover and the gap beside it: 52 dp across for
                        // a finger, though the cover is drawn 40 wide.
                        Semantics(
                          container: true,
                          button: true,
                          label: 'Open Now Playing',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onExpand,
                            child: Padding(
                              padding: const EdgeInsets.only(right: Gap.m),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: SizedBox(
                                  width: 40,
                                  height: 58,
                                  child: cover == null
                                      ? ColoredBox(
                                          color: Skin.accentOf(context).withValues(alpha: 0.35),
                                          child: Icon(Icons.menu_book_rounded, size: 18, color: onDark),
                                        )
                                      : Image.file(File(cover!), fit: BoxFit.cover, cacheWidth: 120, gaplessPlayback: true),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // A new chapter's name rises into place, as in the top bar.
                              AnimatedSwitcher(
                                duration: Motion.of(context, Motion.standard),
                                transitionBuilder: fadeRise,
                                layoutBuilder: (current, previous) => Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [...previous, if (current != null) current],
                                ),
                                child: Text(
                                  empty ? title : layout.chapterTitle(at.chapter),
                                  key: ValueKey(empty ? -1 : at.chapter),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.ui(size: 13.5, weight: FontWeight.w600, color: onDark),
                                ),
                              ),
                              Text(
                                [if (sleepNote == null) '${at.pct}%', left.toUpperCase(), if (sleepNote != null) sleepNote!]
                                    .join('  ·  '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.meta(context, color: onDark.withValues(alpha: 0.62), size: 10),
                              ),
                              ChapterScrubber(
                                value: at.count <= 1 ? 0 : inChapter / (at.count - 1),
                                onSeek: at.count <= 1 ? null : (f) => onSeekInChapter(at.first + (f * (at.count - 1)).round()),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Gap.l),
                      ],
                    ),
                  ),
                  _icon(context, Icons.skip_previous_rounded, 'Previous chapter', at.chapter > 0 ? onPrevChapter : null),
                  _icon(context, Icons.fast_rewind_rounded, 'Previous sentence', u > 0 ? onPrevSentence : null),
                  PlayButton(player: player, onTap: empty ? null : onPlay),
                  _icon(context, Icons.fast_forward_rounded, 'Next sentence',
                      u < layout.units.length - 1 ? onNextSentence : null),
                  _icon(context, Icons.skip_next_rounded, 'Next chapter',
                      at.chapter < layout.chapters.length - 1 || moreAfter ? onNextChapter : null),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: Gap.l),
                      // On a narrower phone, sleep and save (both in Now
                      // Playing too) step aside before the row overflows
                      // (each takes 48 dp, as the voice keeps its room).
                      child: LayoutBuilder(
                        builder: (context, box) => Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _chip(context, '${trimSpeed(speed)}×', Icons.speed_rounded, onSpeed, tooltip: 'Speed'),
                            if (onSleep != null && box.maxWidth >= 208)
                              _small(context, sleepNote == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                                  'Sleep timer', onSleep!, lit: sleepNote != null),
                            if (onSave != null && box.maxWidth >= 266)
                              _small(context, Icons.bookmark_add_outlined, 'Save this line', onSave!),
                            Flexible(
                              child: _chip(context, voiceLabel, Icons.record_voice_over_rounded, onVoice, tooltip: 'Voice'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// Sleep and save on the dock: the icon drawn small, the target a
  /// finger's 48 dp (a compact button was 40).
  Widget _small(BuildContext context, IconData icon, String tip, VoidCallback onTap, {bool lit = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: 21,
        color: lit ? Skin.accentSoftOf(context) : Skin.onDark(context),
        icon: Icon(icon),
      );

  Widget _bar(BuildContext context) {
    final onDark = Skin.onDark(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.m),
      // The top's room is the handle's: part of what a tap opens Now
      // Playing from (see _opener).
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      decoration: BoxDecoration(
        color: Skin.darkOn(context),
        borderRadius: BorderRadius.circular(Radii.card + 4),
        boxShadow: Skin.lift(context),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: cursor,
        builder: (context, u, _) {
          final empty = layout.isEmpty;
          final (:chapter, :first, :count, :minutes, :pct) = _at(u);
          final inChapter = (u - first).clamp(0, count - 1);
          final partial = progressOf != null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _opener(
                Column(
                  children: [
                    _handle(context, above: Gap.m),
                    Row(
                      children: [
                        _chip(context, '${trimSpeed(speed)}×', Icons.speed_rounded, onSpeed,
                            tooltip: 'Speed'),
                        Expanded(
                          // A tap here is the handle's.
                          child: IgnorePointer(
                            child: Text(
                              // With a sleep timer there is no room for all three.
                              [
                                if (sleepNote == null) '$pct%',
                                partial ? '${durationLabel(minutes)} LEFT IN CHAPTER' : '${durationLabel(minutes)} LEFT',
                                if (sleepNote != null) sleepNote!,
                              ].join('  ·  '),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Skin.meta(context, color: onDark.withValues(alpha: 0.62), size: 10.5),
                            ),
                          ),
                        ),
                        _chip(context, voiceLabel, Icons.record_voice_over_rounded, onVoice,
                            tooltip: 'Voice'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              ChapterScrubber(
                value: count <= 1 ? 0 : inChapter / (count - 1),
                onSeek: count <= 1 ? null : (f) => onSeekInChapter(first + (f * (count - 1)).round()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _icon(context, Icons.skip_previous_rounded, 'Previous chapter',
                      chapter > 0 ? onPrevChapter : null),
                  _icon(context, Icons.fast_rewind_rounded, 'Previous sentence',
                      u > 0 ? onPrevSentence : null),
                  PlayButton(player: player, onTap: empty ? null : onPlay),
                  _icon(context, Icons.fast_forward_rounded, 'Next sentence',
                      u < layout.units.length - 1 ? onNextSentence : null),
                  _icon(context, Icons.skip_next_rounded, 'Next chapter',
                      chapter < layout.chapters.length - 1 || moreAfter ? onNextChapter : null),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _icon(BuildContext context, IconData icon, String tip, VoidCallback? onTap) {
    final onDark = Skin.onDark(context);
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      iconSize: 26,
      color: onDark,
      disabledColor: onDark.withValues(alpha: 0.25),
      icon: Icon(icon),
    );
  }

  Widget _chip(BuildContext context, String label, IconData icon, VoidCallback onTap,
      {required String tooltip}) {
    final onDark = Skin.onDark(context);
    return Tooltip(
      message: tooltip,
      child: Capsule(
        onTap: onTap,
        border: false,
        color: Colors.white.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 7),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Skin.accentSoftOf(context)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.ui(size: 13, weight: FontWeight.w600, color: onDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
