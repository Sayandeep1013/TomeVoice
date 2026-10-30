import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'page_style.dart';
import 'theme.dart';
import 'ui.dart';

// The reader's chrome: its top bar, the bars folding or sliding out of the
// way of the page, the pills that rise over it (back to the voice, back to
// where the reader was, a search's matches), and the safe area it holds
// steady.

/// The reader's top bar: back to the library, the book's title over the
/// chapter being read (a tap opens the Contents), and its buttons: a PDF's
/// real pages, search, the page's bookmark (held, every bookmark) and how
/// the page looks.
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.layout,
    required this.style,
    required this.line,
    required this.cursor,
    required this.detached,
    required this.viewChapter,
    required this.chapterNumber,
    required this.bookmarked,
    required this.onContents,
    required this.onSearch,
    required this.onBookmark,
    required this.onBookmarks,
    required this.onSettings,
    this.positionOf,
    this.realPages,
    this.onRealPages,
  });

  final ReadingLayout layout;
  final PageStyle style;

  /// Told when the chapter line changes: the place, looking around, or
  /// the chapter on screen.
  final Listenable line;
  final ValueListenable<int> cursor;
  final ValueListenable<bool> detached;
  final ValueListenable<int> viewChapter;

  /// The number a chapter goes by (see ReaderScreen.chapterNumberOf).
  final int Function(int chapter) chapterNumber;

  /// "12/340" for a sentence in the whole work (see ReaderScreen.positionOf).
  final String Function(int u)? positionOf;

  /// The page (or the paragraph read) shown has a bookmark.
  final ValueListenable<bool> bookmarked;

  /// A PDF: whether its real pages are shown (null for a book that has
  /// none), and the button that switches.
  final bool? realPages;
  final VoidCallback? onRealPages;

  final VoidCallback onContents;
  final VoidCallback onSearch;
  final VoidCallback onBookmark;
  final VoidCallback onBookmarks;
  final VoidCallback onSettings;

  /// The chapter line's arrow, which says it opens the Contents.
  static const _arrow = 15.0;

  // The round buttons take 48 dp for a finger and draw 44: the gaps and the
  // edges are 2 dp less on each side, so every circle stays where it was.
  @override
  Widget build(BuildContext context) {
    final book = layout.book;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        children: [
          RoundButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back to library',
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              button: true,
              label: 'Contents',
              child: GestureDetector(
                key: const ValueKey('contents'),
                behavior: HitTestBehavior.opaque,
                onTap: onContents,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      book.metadata.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // On a page tone's paper, in its ink: the app's (cream
                      // in a dark theme) vanished on Ink's white.
                      style: Skin.title(context, size: 18, color: style.barInk),
                    ),
                    ListenableBuilder(
                      listenable: line,
                      builder: (context, _) {
                        // The chapter on screen while looking around; the
                        // one being read otherwise.
                        final looking = detached.value && !layout.isEmpty;
                        final c = looking ? viewChapter.value : layout.chapterOfUnit(cursor.value);
                        final u = looking ? layout.chapterFirstUnit[c] : cursor.value;
                        final meta = Skin.meta(context, size: 10.5, color: style.barSoftInk);
                        if (!(layout.chapters.length > 1 || positionOf != null)) {
                          return Text(
                            book.metadata.authorLine.isEmpty
                                ? book.source.name.toUpperCase()
                                : book.metadata.authorLine.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: meta,
                          );
                        }
                        // A long title gives way; the count shows whole
                        // unless even it has no room (a split screen), when
                        // it gives way too rather than run off the end.
                        // A new chapter's name rises into place.
                        return AnimatedSwitcher(
                          duration: Motion.of(context, Motion.standard),
                          transitionBuilder: fadeRise,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, if (current != null) current],
                          ),
                          child: LayoutBuilder(
                            key: ValueKey(c),
                            builder: (context, box) => Row(
                              children: [
                                Flexible(
                                  child: Text(layout.chapterTitle(c).toUpperCase(),
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: meta),
                                ),
                                ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: math.max(0.0, box.maxWidth - _arrow)),
                                  child: Text(
                                    '  ·  ${positionOf?.call(u) ?? '${chapterNumber(c)}/${layout.chapters.length}'}',
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: meta,
                                  ),
                                ),
                                Icon(Icons.expand_more_rounded, size: _arrow, color: meta.color),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (realPages != null) ...[
            const SizedBox(width: 4),
            RoundButton(
              icon: realPages! ? Icons.notes_rounded : Icons.auto_stories_rounded,
              tooltip: realPages! ? 'Show as text' : 'Show the real pages',
              onTap: onRealPages,
            ),
          ],
          const SizedBox(width: 4),
          RoundButton(
            icon: Icons.search_rounded,
            tooltip: 'Search',
            onTap: onSearch,
          ),
          const SizedBox(width: 4),
          // Contents is the title's (its chapter line says so); the bar
          // keeps a page's bookmark at hand.
          ValueListenableBuilder<bool>(
            valueListenable: bookmarked,
            builder: (context, marked, _) => RoundButton(
              icon: marked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              iconColor: marked ? Skin.accentInkOf(context) : null,
              tooltip: marked ? 'Remove bookmark' : 'Bookmark this page',
              onTap: onBookmark,
              onLongPress: onBookmarks,
            ),
          ),
          const SizedBox(width: 4),
          // How the page looks. The voice's settings are on the player
          // (its voice and speed), in the same sheet.
          RoundButton(
            icon: Icons.text_fields_rounded,
            tooltip: 'Reading settings',
            onTap: onSettings,
          ),
        ],
      ),
    );
  }
}

/// A bar of the scroll, folding away into its edge (the [top] one, or the
/// foot's) while [shown] is false; the text grows into its place. With
/// [keep] (a PDF's real pages: a tap there reads from the page) it stays.
class FoldingBar extends StatelessWidget {
  const FoldingBar({super.key, required this.shown, required this.top, required this.child, this.keep = false});

  final ValueListenable<bool> shown;
  final bool top;
  final bool keep;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (context, shown, child) {
          final show = shown || keep;
          return ClipRect(
            // Clipped while it folds away. Shown, the player is not: its
            // shadow, cut at the safe area's edge, drew a line under it.
            // (The top bar's coming back would show over the status bar.)
            clipBehavior: top || !show ? Clip.hardEdge : Clip.none,
            child: IgnorePointer(
              ignoring: !show,
              child: AnimatedAlign(
                alignment: top ? Alignment.bottomCenter : Alignment.topCenter,
                heightFactor: show ? 1 : 0,
                duration: Motion.of(context, Motion.standard),
                curve: Motion.out,
                child: AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: Motion.of(context, Motion.quick),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: child,
      );
}

/// A bar over the pages (or the player docked over the scroll): it slides
/// in from its edge (the [top] one, or the foot's) while [shown].
class SlidingBar extends StatelessWidget {
  const SlidingBar({super.key, required this.shown, required this.top, required this.child});

  final ValueListenable<bool> shown;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (context, shown, child) => IgnorePointer(
          ignoring: !shown,
          child: AnimatedSlide(
            offset: shown ? Offset.zero : Offset(0, top ? -0.5 : 0.5),
            duration: Motion.of(context, Motion.standard),
            curve: Motion.out,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: Motion.of(context, Motion.quick),
              child: child,
            ),
          ),
        ),
        child: child,
      );
}

/// "3 of 12 · ↑ ↓ ✕" while stepping through search matches.
class MatchesPill extends StatelessWidget {
  const MatchesPill({
    super.key,
    required this.query,
    required this.index,
    required this.count,
    required this.onStep,
    required this.onDone,
  });

  final String query;
  final int index;
  final int count;

  /// To the match before (-1) or after (1).
  final ValueChanged<int> onStep;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Material(
        color: Skin.darkOn(context),
        shape: const StadiumBorder(),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.only(left: Gap.l),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  '“$query”  ${index + 1} of $count',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.onDark(context)),
                ),
              ),
              IconButton(
                tooltip: 'Previous match',
                icon: Icon(Icons.keyboard_arrow_up_rounded, color: Skin.onDark(context)),
                onPressed: () => onStep(-1),
              ),
              IconButton(
                tooltip: 'Next match',
                icon: Icon(Icons.keyboard_arrow_down_rounded, color: Skin.onDark(context)),
                onPressed: () => onStep(1),
              ),
              IconButton(
                tooltip: 'Done',
                icon: Icon(Icons.close_rounded, color: Skin.onDark(context)),
                onPressed: onDone,
              ),
            ],
          ),
        ),
      );
}

/// "Back to where you were" after a jump while reading without the voice;
/// its cross keeps the new place.
class ReturnPill extends StatelessWidget {
  const ReturnPill({super.key, required this.onBack, required this.onStay});

  final VoidCallback onBack;
  final VoidCallback onStay;

  @override
  Widget build(BuildContext context) => Material(
        color: Skin.darkOn(context),
        shape: const StadiumBorder(),
        elevation: 4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onBack,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // On the dark pill, the soft accent (the deep one by
                      // day would not show on it).
                      Icon(Icons.undo_rounded, size: 16, color: Skin.accentSoftOf(context)),
                      const SizedBox(width: Gap.s),
                      Flexible(
                        child: Text('Back to where you were',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.onDark(context))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Stay here',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: Skin.onDark(context)),
              onPressed: onStay,
            ),
          ],
        ),
      );
}

/// "Back to reading": while the reader looks around ([detached]), the way
/// back to the sentence the voice is on.
class BackToReadingPill extends StatelessWidget {
  const BackToReadingPill({super.key, required this.detached, required this.onTap});

  final ValueListenable<bool> detached;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: detached,
        builder: (context, detached, _) => AnimatedSlide(
          offset: detached ? Offset.zero : const Offset(0, 1.6),
          duration: Motion.of(context, const Duration(milliseconds: 220)),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: detached ? 1 : 0,
            duration: Motion.of(context, const Duration(milliseconds: 180)),
            child: IgnorePointer(
              ignoring: !detached,
              child: Capsule(
                onTap: onTap,
                color: Skin.darkOn(context),
                border: false,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // On the dark pill, the soft accent (the deep one by day
                    // would not show on it).
                    Icon(Icons.my_location_rounded, size: 16, color: Skin.accentSoftOf(context)),
                    const SizedBox(width: Gap.s),
                    Text('Back to reading',
                        style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.onDark(context))),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// A [SafeArea] of the [insets] given rather than the phone's of the moment:
/// the reader's, held steady while a system sheet is over it (see
/// _ReaderScreenState._steadyInsets).
class HeldSafeArea extends StatelessWidget {
  const HeldSafeArea({super.key, required this.insets, required this.child});

  final EdgeInsets insets;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: insets,
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: child,
        ),
      );
}
