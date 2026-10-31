import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'listen_sheet.dart' show trimSpeed;
import 'page_style.dart';
import 'player_controls.dart';
import 'prefs.dart';
import 'reader_text.dart' show wordAt;
import 'scheduler.dart';
import 'theme.dart';
import 'ui.dart';
import 'voice_glow.dart';

/// The book filling the screen while it is read: the cover over a blur of
/// itself in the book's colour, and the page around the voice, the sentence
/// being read lit and the word under the voice in the accent.
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
    required this.sleepChanges,
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

  /// Ticks as the sleep timer changes, runs down or pauses the book.
  final Listenable sleepChanges;
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
              // About a third of the screen: on its side a fixed height
              // flooded most of it.
              height: (MediaQuery.sizeOf(context).height * 0.34).clamp(120, 300).toDouble(),
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
                          Expanded(flex: 4, child: Center(child: _art(context))),
                          Expanded(flex: 7, child: _panel(context, compact: false)),
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
          listenable: Listenable.merge([cursor, ListeningPrefs.revision, sleepChanges]),
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
                // A new chapter's name rises into place.
                AnimatedSwitcher(
                  duration: Motion.of(context, Motion.standard),
                  transitionBuilder: fadeRise,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, if (current != null) current],
                  ),
                  child: Text(
                    empty ? '' : layout.chapterTitle(chapter).toUpperCase(),
                    key: ValueKey(chapter),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.meta(context, color: Colors.white.withValues(alpha: 0.62)),
                  ),
                ),
                const SizedBox(height: Gap.m),
                Expanded(child: _Passage(layout: layout, unit: u, player: player, onTap: onGoTo, onHold: onHold)),
                const SizedBox(height: Gap.s),
                // Its taps reach over the gap above it and the line under it,
                // which are no target: a finger's 48 dp.
                ChapterScrubber(
                  value: count <= 1 ? 0 : inChapter / (count - 1),
                  onSeek: count <= 1 ? null : (f) => onGoTo(first + (f * (count - 1)).round()),
                  above: 8,
                  below: 14,
                ),
                // A tap on it is the scrubber's.
                IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      [
                        minutes < 1 ? 'UNDER A MINUTE LEFT' : '${durationLabel(minutes)} LEFT IN CHAPTER',
                        if (sleep != null) sleep,
                      ].join('  ·  '),
                      textAlign: TextAlign.end,
                      style: Skin.meta(context, size: 10.5, color: Colors.white.withValues(alpha: 0.55)),
                    ),
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
                // The chips are drawn 37 dp tall: a tap in the gap over them
                // is theirs too, a finger's 48.
                TapBand(
                  above: 11,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _chip(context, '${trimSpeed(speed())}×', Icons.speed_rounded, onSpeed),
                      _chip(context, sleep == null ? 'Sleep' : 'Sleep on', Icons.bedtime_outlined, onSleep),
                      _chip(context, 'Save', Icons.bookmark_add_outlined, onSave),
                      _chip(context, voiceLabel(), Icons.record_voice_over_rounded, onVoice),
                    ],
                  ),
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

/// The book around the voice, set as a page: whole paragraphs, the sentence
/// being read in full white with its word lit, the rest dimmed. It glides to
/// keep the voice on one line a little above the middle of the window, and
/// fades away above and below it. Tap a sentence to read from it; press and
/// hold for a word.
class _Passage extends StatefulWidget {
  const _Passage({required this.layout, required this.unit, required this.player, required this.onTap, required this.onHold});

  final ReadingLayout layout;
  final int unit;
  final PlaybackScheduler player;
  final ValueChanged<int> onTap;
  final void Function(int unit, String word) onHold;

  @override
  State<_Passage> createState() => _PassageState();
}

class _PassageState extends State<_Passage> {
  /// Where the voice is kept, as a share of the window from its top.
  static const _focus = 0.4;

  /// Characters of whole paragraphs kept above and below the voice; the
  /// window is laid out afresh once it comes within [_margin] of an end.
  static const _reach = 2400;
  static const _margin = 900;

  final _scroll = ScrollController();
  final _content = GlobalKey();

  /// Each paragraph's text, by its first unit.
  final _keys = <int, GlobalKey>{};

  /// The units set out: whole paragraphs, [_from] up to [_to].
  int _from = 0;
  int _to = 0;

  /// Jump to the voice instead of gliding: the page was just laid out.
  bool _jump = true;
  double _height = 0;

  /// The sentence just read, and how far down the window it was, when the
  /// window is set out afresh as the voice reads on: it is put back there
  /// before the glide to the next, which was a cut every page or so.
  int? _anchor;
  double _anchorY = 0;

  ReadingLayout get _l => widget.layout;

  @override
  void initState() {
    super.initState();
    _place(widget.unit);
  }

  @override
  void didUpdateWidget(_Passage old) {
    super.didUpdateWidget(old);
    final u = widget.unit;
    final far = old.layout != _l || u < _from || u >= _to;
    if (far ||
        (_from > 0 && _chars(_from, u) < _margin) ||
        (_to < _l.units.length && _chars(u + 1, _to) < _margin)) {
      final y = far || !_scroll.hasClients ? null : _topOf(old.unit);
      _place(u);
      if (y != null) {
        _anchor = old.unit;
        _anchorY = y - _scroll.offset;
      }
    }
  }

  /// Where sentence [u] starts in the window's text, if it is laid out.
  double? _topOf(int u) {
    if (u < _from || u >= _to) return null;
    final (a, _) = _paragraph(u);
    final text = _keys[a]?.currentContext?.findRenderObject();
    final content = _content.currentContext?.findRenderObject();
    if (text is! RenderParagraph || content is! RenderBox) return null;
    final start = _startIn(a, u);
    final boxes = text.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + _l.units[u].text.length),
    );
    if (boxes.isEmpty) return null;
    return text.localToGlobal(Offset(0, boxes.first.top), ancestor: content).dy;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _chars(int a, int b) {
    var n = 0;
    for (var i = a; i < b; i++) {
      n += _l.units[i].text.length;
    }
    return n;
  }

  /// The paragraph holding unit [u]: its first unit, and the one after its last.
  (int, int) _paragraph(int u) {
    final item = _l.unitItem[u];
    var a = u;
    while (a > 0 && _l.unitItem[a - 1] == item) {
      a--;
    }
    var b = u + 1;
    while (b < _l.units.length && _l.unitItem[b] == item) {
      b++;
    }
    return (a, b);
  }

  /// Set out the paragraphs around unit [u], out to [_reach] characters each way.
  void _place(int u) {
    _keys.clear();
    _jump = true;
    if (_l.isEmpty) {
      _from = _to = 0;
      return;
    }
    var (a, b) = _paragraph(u.clamp(0, _l.units.length - 1));
    var before = 0;
    while (a > 0 && before < _reach) {
      final (pa, _) = _paragraph(a - 1);
      before += _chars(pa, a);
      a = pa;
    }
    var after = 0;
    while (b < _l.units.length && after < _reach) {
      final (_, pb) = _paragraph(b);
      after += _chars(b, pb);
      b = pb;
    }
    _from = a;
    _to = b;
  }

  /// Where unit [u] starts in the text of the paragraph beginning at [a].
  int _startIn(int a, int u) {
    var n = 0;
    for (var i = a; i < u; i++) {
      n += _l.units[i].text.length + 1;
    }
    return n;
  }

  /// The unit at [local] in the paragraph [a] to [b], and the offset in its text.
  (int, int)? _unitAt(int a, int b, GlobalKey key, Offset local) {
    final text = key.currentContext?.findRenderObject();
    if (text is! RenderParagraph) return null;
    final at = text.getPositionForOffset(local).offset;
    var start = 0;
    for (var i = a; i < b; i++) {
      final len = _l.units[i].text.length;
      if (at <= start + len || i == b - 1) return (i, (at - start).clamp(0, len));
      start += len + 1;
    }
    return null;
  }

  /// Bring the voice to the focus line: a glide, or a jump after a new layout.
  void _follow() {
    if (!mounted || !_scroll.hasClients) return;
    final u = widget.unit;
    if (u < _from || u >= _to) return;
    final (a, _) = _paragraph(u);
    final text = _keys[a]?.currentContext?.findRenderObject();
    final content = _content.currentContext?.findRenderObject();
    if (text is! RenderParagraph || content is! RenderBox) return;
    final start = _startIn(a, u);
    final boxes = text.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + _l.units[u].text.length),
    );
    if (boxes.isEmpty) return;
    final top = text.localToGlobal(Offset(0, boxes.first.top), ancestor: content).dy;
    final bottom = text.localToGlobal(Offset(0, boxes.last.bottom), ancestor: content).dy;
    // The sentence's middle on the focus line; a long one starts just below
    // the fade at the top instead, so its end stays in the window.
    final at = bottom - top > _height * 0.5 ? top - _height * 0.22 : (top + bottom) / 2 - _height * _focus;
    final target = at.clamp(0.0, _scroll.position.maxScrollExtent);
    var jump = _jump || Motion.reduced(context);
    _jump = false;
    final anchor = _anchor;
    _anchor = null;
    final was = anchor == null ? null : _topOf(anchor);
    if (jump && was != null && !Motion.reduced(context)) {
      // Set out afresh as it read on: the last sentence back where it was,
      // then the usual glide.
      _scroll.jumpTo((was - _anchorY).clamp(0.0, _scroll.position.maxScrollExtent));
      jump = false;
    }
    if ((target - _scroll.offset).abs() < 1) return;
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      unawaited(_scroll.animateTo(target, duration: Motion.travel, curve: Motion.out));
    }
  }

  List<InlineSpan> _sentence(BuildContext context, int i, bool current, WordMark word) {
    final text = _l.units[i].text;
    if (!current) return [TextSpan(text: text)];
    final on = word.unit == i && word.start >= 0 && word.end > word.start;
    final ws = on ? word.start.clamp(0, text.length) : 0;
    final we = on ? word.end.clamp(ws, text.length) : 0;
    return [
      TextSpan(
        style: const TextStyle(color: Colors.white),
        children: [
          TextSpan(text: text.substring(0, ws)),
          if (on) TextSpan(text: text.substring(ws, we), style: TextStyle(color: Skin.accentSoftOf(context))),
          TextSpan(text: text.substring(we)),
        ],
      ),
    ];
  }

  Widget _para(BuildContext context, int a, int b) {
    final key = _keys.putIfAbsent(a, GlobalKey.new);
    final heading = _l.units[a].role == BlockRole.heading;
    final dim = Colors.white.withValues(alpha: 0.4);
    // The reader's text size (19 unless it was changed), as on the page.
    final prefs = ListeningPrefs.loaded ?? ListeningPrefs.memory;
    final style = PageStyle.passage(context, prefs, heading: heading, color: dim);
    final u = widget.unit;
    final current = u >= a && u < b;
    Widget text(WordMark word) => Text.rich(
          TextSpan(children: [
            for (var i = a; i < b; i++) ...[
              if (i > a) const TextSpan(text: ' '),
              ..._sentence(context, i, current && i == u, word),
            ],
          ]),
          key: key,
          style: style,
        );
    return Padding(
      padding: EdgeInsets.only(bottom: heading ? Gap.m : Gap.l),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final at = _unitAt(a, b, key, d.localPosition);
          if (at != null) widget.onTap(at.$1);
        },
        onLongPressStart: (d) {
          final at = _unitAt(a, b, key, d.localPosition);
          if (at != null) widget.onHold(at.$1, wordAt(_l.units[at.$1].text, at.$2));
        },
        // Only the paragraph being read follows the word.
        child: current
            ? ValueListenableBuilder<WordMark>(
                valueListenable: widget.player.word,
                builder: (context, word, _) => text(word),
              )
            : text(WordMark.none),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_l.isEmpty) return const SizedBox.shrink();
    final paragraphs = <Widget>[];
    for (var a = _from; a < _to;) {
      final (_, b) = _paragraph(a);
      paragraphs.add(_para(context, a, b));
      a = b;
    }
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxHeight != _height) {
          _height = box.maxHeight;
          _jump = true;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
            stops: [0, 0.2, 0.78, 1],
          ).createShader(r),
          child: SingleChildScrollView(
            controller: _scroll,
            // It follows the voice; a drag is left to the screen (down closes it).
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              key: _content,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: box.maxHeight * _focus),
                ...paragraphs,
                SizedBox(height: box.maxHeight * (1 - _focus)),
              ],
            ),
          ),
        );
      },
    );
  }
}

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
