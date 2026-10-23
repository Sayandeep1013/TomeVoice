import 'dart:io';

import 'package:flutter/material.dart';

import 'library_store.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// A book's cover: the real one when the file has it, otherwise a cover made
/// from the title, so every book on the shelf is recognisable at a glance.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.entry,
    required this.width,
    this.shadow = true,
    this.titled = true,
  });

  final LibraryEntry entry;
  final double width;
  final bool shadow;

  /// Whether a cover made from the title shows the title. Tiles print the
  /// title on their own band, so theirs shows only an initial.
  final bool titled;

  double get height => width * 1.5;

  static const _palette = [
    Color(0xFF2F4A3A), // forest
    Color(0xFF6B4226), // tan leather
    Color(0xFF34454F), // slate
    Color(0xFF4A3446), // plum
    Color(0xFF4C5530), // olive
    Color(0xFF7A3E22), // rust
    Color(0xFF283A4A), // ink blue
  ];

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final generated = _generated(context);
    final path = entry.shownCover;
    final radius = BorderRadius.circular((width * 0.07).clamp(4.0, Radii.chip));
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: path == null
            ? generated
            : Image.file(
                File(path),
                width: width,
                height: height,
                fit: BoxFit.cover,
                // A full-size cover is megabytes of pixels for a thumbnail.
                cacheWidth: (width * dpr).round(),
                errorBuilder: (_, __, ___) => generated,
              ),
      ),
    );
  }

  Widget _generated(BuildContext context) {
    final color = _palette[entry.title.hashCode.abs() % _palette.length];
    if (!titled) {
      final t = entry.title.trim();
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(color, Colors.white, 0.10)!, color],
          ),
        ),
        alignment: const Alignment(0, -0.35),
        child: Text(
          t.isEmpty ? '?' : t.characters.first.toUpperCase(),
          style: Skin.title(context,
              size: width * 0.62, weight: FontWeight.w400, color: Skin.nightInk.withValues(alpha: 0.22)),
        ),
      );
    }
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.08)!, color],
        ),
      ),
      padding: EdgeInsets.all(width * 0.1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: width * 0.22, height: 2, color: Skin.amber),
          SizedBox(height: width * 0.08),
          Expanded(
            child: Text(
              entry.title,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: Skin.title(context, size: width * 0.15, color: Skin.nightInk)
                  .copyWith(height: 1.1),
            ),
          ),
          Text(
            entry.formatLabel,
            style: Skin.meta(context, color: Skin.nightInk.withValues(alpha: 0.7), size: width * 0.095)
                .copyWith(height: 1),
          ),
        ],
      ),
    );
  }
}

/// Listening time for [words] at normal speed, as "7 H 40 M".
String listenLength(int words) {
  if (words <= 0) return '';
  final minutes = (words / 165).round();
  if (minutes < 1) return '< 1 M';
  if (minutes < 60) return '$minutes M';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h H' : '$h H $m M';
}

/// "today", "yesterday", "3 days ago", "12 Oct".
String relativeDay(DateTime when, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final a = DateTime(when.year, when.month, when.day);
  final b = DateTime(today.year, today.month, today.day);
  final days = b.difference(a).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${when.day} ${months[when.month - 1]}';
}

/// "34%". A book that has been started never reads "0%".
String percentLabel(double progress) =>
    '${progress <= 0 ? 0 : (progress * 100).round().clamp(1, 100)}%';

/// Where the reader stands in [e], in words.
String progressLine(LibraryEntry e) {
  if (e.finished) return 'Finished';
  final where = e.where;
  final useful = where != null && where.toLowerCase() != e.title.toLowerCase();
  if (e.openedAt == null || e.progress <= 0) {
    return 'Not started · added ${relativeDay(e.addedAt)}';
  }
  final pct = percentLabel(e.progress);
  return useful ? '$pct · $where' : '$pct · read ${relativeDay(e.openedAt!)}';
}

/// One book on the shelf: cover, title, author, what it is and how long it
/// takes to hear, and where you are in it.
class BookRow extends StatelessWidget {
  const BookRow({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onMenu,
    this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onMenu;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final facts = [
      e.formatLabel,
      if (e.language != null) languageName(e.language!),
      if (e.wordCount > 0) listenLength(e.wordCount),
    ];
    final radius = BorderRadius.circular(Radii.row + 4);
    return Material(
      color: selected ? Skin.amber.withValues(alpha: 0.14) : Skin.capsuleOn(context),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onLongPress ?? onMenu,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected ? Skin.amber : Skin.outlineOn(context),
              width: selected ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.xs, Gap.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SelectableCover(entry: e, width: 62, selected: selected),
              const SizedBox(width: 14),
              Expanded(
                child: ConstrainedBox(
                  // Every row the same height as its cover, author or not.
                  constraints: const BoxConstraints(minHeight: 93),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.title(context, size: 17.5).copyWith(height: 1.18),
                          ),
                          if (e.authorLine.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              e.authorLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Skin.label(context, size: 13.5),
                            ),
                          ],
                          const SizedBox(height: Gap.s),
                          Wrap(
                            spacing: 5,
                            runSpacing: 5,
                            children: [for (final f in facts) TagChip(f)],
                          ),
                        ],
                      ),
                      const SizedBox(height: Gap.s),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (e.progress > 0 && !e.finished)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5, right: Gap.m),
                              child: Progress(e.progress),
                            ),
                          Text(
                            progressLine(e).toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.meta(context, size: 10.5,
                                color: e.finished ? Skin.amber : null),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.all(Gap.m),
                  child: Icon(
                    selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    color: selected ? Skin.amber : Skin.inkFaintOn(context),
                  ),
                )
              else
                IconButton(
                  tooltip: 'More',
                  onPressed: onMenu,
                  icon: Icon(Icons.more_vert_rounded, color: Skin.inkSoftOn(context)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One book in the cover grid: the cover fills the tile, and what the list
/// spells out (title, author, format, length, progress) sits on a dark
/// translucent band across its foot, the way novel readers show a shelf.
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onLongPress,
    this.selected = false,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final tags = [
      e.formatLabel,
      if (e.language != null) languageName(e.language!),
      if (e.wordCount > 0) listenLength(e.wordCount),
    ];
    const white = Colors.white;
    final radius = BorderRadius.circular(Radii.row - 4);
    return Semantics(
      button: true,
      selected: selected,
      label: e.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        onLongPress: onLongPress,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: selected ? Skin.amber : Colors.transparent, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    BookCover(entry: e, width: w, shadow: false, titled: false),
                    // The band: clear at the top, dark enough at the foot for
                    // white text on any cover.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0),
                              Colors.black.withValues(alpha: 0.62),
                              Colors.black.withValues(alpha: 0.86),
                            ],
                            stops: const [0, 0.38, 1],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 34, 10, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                e.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.title(context, size: 15.5, color: white).copyWith(height: 1.15),
                              ),
                              if (e.authorLine.isNotEmpty)
                                Text(
                                  e.authorLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Skin.ui(
                                      size: 12, weight: FontWeight.w500, color: white.withValues(alpha: 0.75)),
                                ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [for (final t in tags) _GlassTag(t)],
                              ),
                              if (e.progress > 0 && !e.finished) ...[
                                const SizedBox(height: 7),
                                Progress(e.progress, height: 3, track: white.withValues(alpha: 0.22)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(left: 7, top: 7, child: _StatusBadge(entry: e)),
                    if (selected)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Skin.amber.withValues(alpha: 0.30),
                          child: const Align(
                            alignment: Alignment(0, -0.4),
                            child: Icon(Icons.check_circle_rounded, color: Colors.white, size: 34),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// "34%", "NEW" or "DONE", top left of a tile.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final loud = e.finished || e.progress <= 0;
    final label = e.finished ? 'DONE' : (e.progress > 0 ? percentLabel(e.progress) : 'NEW');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: loud ? Skin.amber : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, style: Skin.meta(context, size: 10, color: loud ? Skin.onAmber : Colors.white)),
    );
  }
}

/// A tag on a tile's band: white on a faint glass pill.
class _GlassTag extends StatelessWidget {
  const _GlassTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Text(label.toUpperCase(),
            style: Skin.meta(context, size: 9.5, color: Colors.white.withValues(alpha: 0.9))),
      );
}

class _SelectableCover extends StatelessWidget {
  const _SelectableCover({required this.entry, required this.width, required this.selected});

  final LibraryEntry entry;
  final double width;
  final bool selected;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          BookCover(entry: entry, width: width),
          if (entry.finished)
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Skin.amber, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, size: 12, color: Skin.onAmber),
              ),
            ),
          if (selected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Skin.amber.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular((width * 0.07).clamp(4.0, Radii.chip)),
                  border: Border.all(color: Skin.amber, width: 2),
                ),
                child: const Center(
                  child: Icon(Icons.check_circle_rounded, color: Colors.white, size: 26),
                ),
              ),
            ),
        ],
      );
}
