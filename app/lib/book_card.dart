import 'dart:io';

import 'package:flutter/material.dart';

import 'library_store.dart';
import 'theme.dart';
import 'voices.dart';

/// A book's cover: the real one when the file has it, otherwise a cover made
/// from the title, so every book on the shelf is recognisable at a glance.
class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.entry, required this.width});

  final LibraryEntry entry;
  final double width;

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
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.08),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(width * 0.08),
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
              style: Skin.title(context, size: width * 0.16, color: Skin.nightInk)
                  .copyWith(height: 1.1),
            ),
          ),
          Text(
            entry.formatLabel,
            style: Skin.meta(context, color: Skin.nightInk.withValues(alpha: 0.7), size: width * 0.1)
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

/// Where the reader stands in [e], in words.
String progressLine(LibraryEntry e) {
  if (e.progress >= 0.995) return 'Finished';
  final where = e.where;
  final useful = where != null && where.toLowerCase() != e.title.toLowerCase();
  if (e.openedAt == null || e.progress <= 0) {
    return 'Not started · added ${relativeDay(e.addedAt)}';
  }
  final pct = '${(e.progress * 100).round()}%';
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
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final ink = Skin.inkOn(context);
    final facts = [
      e.formatLabel,
      if (e.language != null) languageName(e.language!).toUpperCase(),
      if (e.wordCount > 0) listenLength(e.wordCount),
    ];
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onMenu,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Skin.capsuleEdge),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(entry: e, width: 62),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.title(context, size: 18).copyWith(height: 1.15),
                    ),
                    if (e.authorLine.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        e.authorLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.label(context, size: 12),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [for (final f in facts) _Chip(f)],
                    ),
                    const SizedBox(height: 10),
                    if (e.progress > 0 && e.progress < 0.995)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6, right: 10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: e.progress.clamp(0.0, 1.0),
                            minHeight: 3,
                            color: Skin.amber,
                            backgroundColor: ink.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    Text(
                      progressLine(e).toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.meta(context, size: 8.5),
                    ),
                  ],
                ),
              ),
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

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Skin.inkFaintOn(context).withValues(alpha: 0.45)),
        ),
        child: Text(label, style: Skin.meta(context, size: 8).copyWith(height: 1.4)),
      );
}

/// The book you were last reading, with one-tap resume.
class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onPlay,
    required this.onMenu,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final onDark = Skin.onDark(context);
    final left = e.wordCount > 0 ? listenLength((e.wordCount * (1 - e.progress)).round()) : '';
    return Material(
      color: Skin.darkOn(context),
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onMenu,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              BookCover(entry: e, width: 74),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.title(context, size: 20, color: onDark).copyWith(height: 1.12),
                    ),
                    if (e.authorLine.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        e.authorLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.label(context, color: onDark.withValues(alpha: 0.7), size: 12),
                      ),
                    ],
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: e.progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: Skin.amber,
                        backgroundColor: onDark.withValues(alpha: 0.14),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        progressLine(e),
                        if (left.isNotEmpty && e.progress < 0.995) '$left left',
                      ].join(' · ').toUpperCase(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.meta(context, color: onDark.withValues(alpha: 0.6), size: 8.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'Continue reading aloud',
                child: Material(
                  color: Skin.amber,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onPlay,
                    child: const SizedBox(
                      width: 54,
                      height: 54,
                      child: Icon(Icons.play_arrow_rounded, size: 32, color: Skin.dark),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
