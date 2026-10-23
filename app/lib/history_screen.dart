import 'dart:async';

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'library_store.dart';
import 'reader_screen.dart';
import 'theme.dart';
import 'ui.dart';

/// Books by when you last opened them, newest first and grouped by day, with
/// one-tap resume.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<LibraryEntry> _entries = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.store.changes.addListener(_refresh);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    widget.store.changes.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final all = await widget.store.list();
    if (!mounted) return;
    setState(() {
      _entries = [for (final e in all) if (e.openedAt != null) e];
      _loaded = true;
    });
  }

  Future<void> _forget(LibraryEntry e) async {
    await widget.store.forgetOpened(e.id);
    if (mounted) showSnack(context, 'Removed "${e.title}" from history.');
  }

  @override
  Widget build(BuildContext context) {
    // Group by day label, keeping the newest-first order.
    final groups = <String, List<LibraryEntry>>{};
    for (final e in _entries) {
      final day = relativeDay(e.openedAt!);
      groups.putIfAbsent(day[0].toUpperCase() + day.substring(1), () => []).add(e);
    }
    return DecoratedBox(
      decoration: BoxDecoration(gradient: Skin.ground(context)),
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.page, Gap.s),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    RoundButton(
                      icon: Icons.menu_rounded,
                      tooltip: 'Menu',
                      size: 42,
                      onTap: () => Scaffold.maybeOf(context)?.openDrawer(),
                    ),
                    const SizedBox(width: Gap.m),
                    Text('History', style: Skin.title(context, size: 28, weight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
            if (_loaded && _entries.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: EmptyState(
                    icon: Icons.history_rounded,
                    title: 'Nothing read yet',
                    body: 'Books you open show up here, newest first, so you can pick one up again in a tap.',
                  ),
                ),
              ),
            for (final g in groups.entries) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.s),
                sliver: SliverToBoxAdapter(child: Eyebrow(g.key)),
              ),
              SliverList.list(
                children: [
                  for (final e in g.value)
                    _HistoryRow(
                      entry: e,
                      onOpen: () => openBook(context, widget.store, e),
                      onPlay: () => openBook(context, widget.store, e, autoplay: true),
                      onForget: () => _forget(e),
                    ),
                ],
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: Gap.xxl)),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onOpen,
    required this.onPlay,
    required this.onForget,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final t = e.openedAt!;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onOpen,
      onLongPress: onForget,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page, vertical: Gap.s),
        child: Row(
          children: [
            BookCover(entry: e, width: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 16.5)),
                  const SizedBox(height: 3),
                  Text(
                    '${progressLine(e)} · $time'.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.meta(context, size: 10.5),
                  ),
                  const SizedBox(height: 5),
                  Progress(e.progress, height: 2.5),
                ],
              ),
            ),
            const SizedBox(width: Gap.s),
            IconButton(
              tooltip: 'Read aloud from here',
              onPressed: onPlay,
              icon: Icon(Icons.play_circle_fill_rounded, color: Skin.amber, size: 34),
            ),
            PopupMenuButton<String>(
              tooltip: 'Options',
              icon: Icon(Icons.more_vert_rounded, color: Skin.inkSoftOn(context)),
              onSelected: (_) => onForget(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'forget', child: Text('Remove from history')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
