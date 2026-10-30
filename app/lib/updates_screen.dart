import 'dart:async';

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'book_tint.dart';
import 'browser_check.dart';
import 'library_store.dart';
import 'sources/bridge.dart';
import 'sources/plugin_host.dart';
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

class _UpdatesScreenState extends State<UpdatesScreen> with WidgetsBindingObserver {
  List<NewChapter> _items = const [];
  DateTime? _checked;
  bool _hasWeb = false;

  /// Sources whose novels could not be checked the last time, and why.
  List<CheckProblem> _problems = const [];

  /// Android 13 and later: whether TomeVoice may post the new-chapters
  /// notification (null where there is nothing to ask).
  bool? _notify;

  /// False until the log is first read: before, "No new chapters" showed
  /// for a moment on every opening.
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.updates.running.addListener(_reload);
    widget.store.changes.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.updates.running.removeListener(_reload);
    widget.store.changes.removeListener(_reload);
    super.dispose();
  }

  /// Back from Android's permission prompt (or its settings).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reload());
  }

  // Only on the library's changes, not each saved place (placeChanges):
  // nothing here shows a place.
  Future<void> _reload() async {
    final log = await widget.updates.log();
    final hasWeb = (await widget.store.list()).any((e) => e.isWeb);
    final hidden = await widget.store.hiddenIds();
    final notify = await SourcesBridge.notificationsAllowed();
    if (!mounted) return;
    setState(() {
      _items = [for (final c in log.items) if (!hidden.contains(c.bookId)) c];
      _checked = log.checked;
      _problems = log.problems;
      _hasWeb = hasWeb;
      _notify = notify;
      _loaded = true;
    });
  }

  Future<void> _check() async {
    final r = await widget.updates.checkAll();
    if (!mounted) return;
    final n = r.found;
    showSnack(
      context,
      r.checked == 0 && r.failed > 0
          ? 'No site could be reached. Check the internet connection.'
          : n == 0
              ? 'No new chapters.'
              : '$n new ${n == 1 ? 'chapter' : 'chapters'}.',
    );
  }

  Future<void> _open(NewChapter c) async {
    final entry = (await widget.store.list()).where((e) => e.id == c.bookId).firstOrNull;
    if (entry == null || !mounted) return;
    // Found again by its address: the list may have shifted since.
    final info = await widget.store.webNovel(entry.id);
    final at = c.path == null ? -1 : info?.chapters.indexWhere((x) => x.path == c.path) ?? -1;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: entry.id,
        cover: entry.shownCover,
        child: WebNovelReader(store: widget.store, entry: entry, startChapter: at >= 0 ? at : c.index),
      ),
    ));
  }

  /// The way on for a source that could not be checked.
  Widget? _fix(CheckProblem p) {
    switch (p.kind) {
      case CheckProblemKind.challenge:
        final url = p.url;
        if (url == null) return null;
        return TextButton(
          onPressed: () async {
            if (await passBrowserCheck(context, ChallengeException(url, pluginId: p.pluginId))) await _check();
          },
          child: const Text('Open the check'),
        );
      case CheckProblemKind.missing:
        return TextButton(
          onPressed: () async {
            if (await installMissingSource(context, MissingSourceException(p.pluginId, p.source))) await _check();
          },
          child: const Text('Install'),
        );
      case CheckProblemKind.tampered:
        return TextButton(
          onPressed: () async {
            if (await reinstallSource(context, p.pluginId, p.source)) await _check();
          },
          child: const Text('Reinstall'),
        );
      case CheckProblemKind.failed:
        final update = pendingUpdate(p.pluginId);
        if (update == null) return null;
        return TextButton(
          onPressed: () async {
            if (await updateSource(context, update)) await _check();
          },
          child: const Text('Update'),
        );
      case CheckProblemKind.refused:
        return null;
    }
  }

  Widget _problemRow(BuildContext context, CheckProblem p) {
    final fix = _fix(p);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.s, Gap.xs),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: Skin.inkFaintOn(context)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Text(
              '${p.source} (${p.novels} ${p.novels == 1 ? 'novel' : 'novels'}): ${p.why}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Skin.label(context, size: 13.5),
            ),
          ),
          if (fix != null) fix,
        ],
      ),
    );
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
          // A pull counts even when it starts a little way down the list.
          triggerMode: RefreshIndicatorTriggerMode.anywhere,
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
                      // Check and its spinner turn into each other.
                      ValueListenableBuilder<bool>(
                        valueListenable: widget.updates.running,
                        builder: (context, running, _) => AnimatedSwitcher(
                          duration: Motion.of(context, Motion.quick),
                          switchInCurve: Motion.out,
                          switchOutCurve: Motion.out,
                          child: running
                              ? const Padding(
                                  key: ValueKey('checking'),
                                  padding: EdgeInsets.all(Gap.m),
                                  child: SizedBox(
                                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                                )
                              : RoundButton(
                                  key: const ValueKey('check'),
                                  icon: Icons.refresh_rounded,
                                  tooltip: 'Check for new chapters',
                                  size: 42,
                                  onTap: _hasWeb ? _check : null,
                                ),
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
              // What could not be checked the last time, each with its way on.
              if (_hasWeb && _problems.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  sliver: SliverList.list(children: [for (final p in _problems) _problemRow(context, p)]),
                ),
              // New chapters arrive with the app closed too; Android 13 and
              // later ask before they may be told.
              if (_hasWeb && _notify == false)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.s, 0),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Icon(Icons.notifications_none_rounded, size: 18, color: Skin.inkFaintOn(context)),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: Text('Be told when new chapters arrive, with TomeVoice closed.',
                              style: Skin.label(context, size: 13.5)),
                        ),
                        TextButton(
                          onPressed: () async {
                            await SourcesBridge.askNotifications();
                            await _reload();
                          },
                          child: const Text('Allow'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_loaded && _items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: FadeIn(
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
                ),
              // The chapters fade in once read, rather than popping in.
              if (groups.isNotEmpty)
                SliverFadeIn(
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      for (final g in groups.entries) ...[
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.s),
                          sliver: SliverToBoxAdapter(child: Eyebrow(g.key)),
                        ),
                        SliverList.list(
                          children: [
                            for (final c in g.value)
                              ListTile(
                                leading: Icon(Icons.fiber_new_rounded, color: Skin.accentInkOf(context)),
                                title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: Skin.title(context, size: 16.5)),
                                subtitle: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: const Icon(Icons.play_circle_outline_rounded),
                                onTap: () => _open(c),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

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
