import 'dart:async';

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'library_store.dart';
import 'theme.dart';
import 'ui.dart';
import 'updates.dart';
import 'web_reader.dart';

/// New chapters of the web novels in your library, newest first, one tap
/// from the reader.
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, required this.store, required this.updates});

  final LibraryStore store;
  final Updates updates;

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  List<NewChapter> _items = const [];
  DateTime? _checked;
  bool _hasWeb = false;

  @override
  void initState() {
    super.initState();
    widget.updates.running.addListener(_reload);
    widget.store.changes.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.updates.running.removeListener(_reload);
    widget.store.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.updates.recent();
    final checked = await widget.updates.lastChecked();
    final hasWeb = (await widget.store.list()).any((e) => e.isWeb);
    if (!mounted) return;
    setState(() {
      _items = items;
      _checked = checked;
      _hasWeb = hasWeb;
    });
  }

  Future<void> _check() async {
    final n = await widget.updates.checkAll();
    if (!mounted) return;
    showSnack(context, n == 0 ? 'No new chapters.' : '$n new ${n == 1 ? 'chapter' : 'chapters'}.');
  }

  Future<void> _open(NewChapter c) async {
    final entry = (await widget.store.list()).where((e) => e.id == c.bookId).firstOrNull;
    if (entry == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WebNovelReader(store: widget.store, entry: entry, startChapter: c.index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<NewChapter>>{};
    for (final c in _items) {
      final day = relativeDay(c.foundAt);
      groups.putIfAbsent(day[0].toUpperCase() + day.substring(1), () => []).add(c);
    }
    return DecoratedBox(
      decoration: BoxDecoration(gradient: Skin.ground(context)),
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _check,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
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
                      Expanded(child: Text('Updates', style: Skin.title(context, size: 28, weight: FontWeight.w500))),
                      ValueListenableBuilder<bool>(
                        valueListenable: widget.updates.running,
                        builder: (context, running, _) => running
                            ? const Padding(
                                padding: EdgeInsets.all(Gap.m),
                                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                              )
                            : RoundButton(
                                icon: Icons.refresh_rounded,
                                tooltip: 'Check for new chapters',
                                size: 42,
                                onTap: _hasWeb ? _check : null,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
                sliver: SliverToBoxAdapter(
                  child: ValueListenableBuilder<String?>(
                    valueListenable: widget.updates.status,
                    builder: (context, status, _) => Eyebrow(
                      status ?? (_checked == null ? 'Not checked yet' : 'Checked ${_ago(_checked!)}'),
                    ),
                  ),
                ),
              ),
              if (_items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: EmptyState(
                      icon: Icons.new_releases_outlined,
                      title: _hasWeb ? 'No new chapters' : 'Nothing to follow yet',
                      body: _hasWeb
                          ? 'When the sites add chapters to novels in your library, they show up here.'
                          : 'Add web novels from Browse. Their new chapters show up here as the sites add them.',
                      action: _hasWeb ? FilledButton(onPressed: _check, child: const Text('Check now')) : null,
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
                    for (final c in g.value)
                      ListTile(
                        leading: Icon(Icons.fiber_new_rounded, color: Skin.amber),
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: Skin.title(context, size: 16.5)),
                        subtitle: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.play_circle_outline_rounded),
                        onTap: () => _open(c),
                      ),
                  ],
                ),
              ],
              SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom)),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return relativeDay(t);
  }
}
