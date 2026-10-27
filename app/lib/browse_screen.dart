import 'dart:async';

import 'package:flutter/material.dart';

import 'browser_check.dart';
import 'library_store.dart';
import 'novel_screen.dart';
import 'sources/models.dart';
import 'sources/source_engine.dart';
import 'sources/source_store.dart';
import 'sources_screen.dart';
import 'theme.dart';
import 'ui.dart';

/// Find web novels: search every installed source at once, or open one
/// source to browse what is popular or new there.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.store, required this.sources});

  final LibraryStore store;
  final SourceStore sources;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

/// One source's answer to a global search.
class _Results {
  _Results(this.plugin);
  final PluginInfo plugin;
  List<NovelItem>? items;
  Object? error;
  bool get done => items != null || error != null;
}

class _BrowseScreenState extends State<BrowseScreen> {
  List<PluginInfo> _installed = const [];
  final _search = TextEditingController();
  String _query = '';
  List<_Results> _results = const [];
  bool _onlyFound = false;
  int _searchRun = 0;

  @override
  void initState() {
    super.initState();
    widget.sources.changes.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.sources.changes.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await widget.sources.installed();
    if (mounted) setState(() => _installed = list);
  }

  /// Ask every installed source, a few at a time; each row fills in as its
  /// site answers, so one slow site never holds up the rest.
  Future<void> _globalSearch(String q) async {
    final query = q.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
      });
      return;
    }
    final run = ++_searchRun;
    final results = [for (final p in _installed) _Results(p)];
    setState(() {
      _query = query;
      _results = results;
    });
    var next = 0;
    Future<void> worker() async {
      while (next < results.length && run == _searchRun) {
        final r = results[next++];
        await _ask(r);
        if (mounted && run == _searchRun) setState(() {});
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
  }

  Future<void> _ask(_Results r) async {
    try {
      r.items = await SourceEngine.instance.search(r.plugin, _query, 1);
    } on Object catch (e) {
      r.error = e;
    }
  }

  /// One source again, after its browser check.
  Future<void> _retry(_Results r) async {
    final run = _searchRun;
    setState(() {
      r.items = null;
      r.error = null;
    });
    await _ask(r);
    if (mounted && run == _searchRun) setState(() {});
  }

  void _openSources() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SourcesScreen(store: widget.sources),
      ));

  void _openNovel(PluginInfo p, NovelItem n) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => NovelScreen(store: widget.store, plugin: p, path: n.path, name: n.name, cover: n.cover),
      ));

  @override
  Widget build(BuildContext context) {
    final searching = _query.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(gradient: Skin.ground(context)),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.s),
              child: Row(
                children: [
                  RoundButton(
                    icon: Icons.menu_rounded,
                    tooltip: 'Menu',
                    size: 42,
                    onTap: () => Scaffold.maybeOf(context)?.openDrawer(),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(child: Text('Browse', style: Skin.title(context, size: 28, weight: FontWeight.w500))),
                  RoundButton(icon: Icons.extension_outlined, tooltip: 'Sources', size: 42, onTap: _openSources),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context)),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.travel_explore_rounded, size: 20),
                  hintText: _installed.isEmpty ? 'Install sources to search' : 'Search every source',
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () {
                            _search.clear();
                            _globalSearch('');
                          },
                        )
                      : null,
                ),
                enabled: _installed.isNotEmpty,
                onSubmitted: _globalSearch,
              ),
            ),
            Expanded(
              child: _installed.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        child: EmptyState(
                          icon: Icons.travel_explore_rounded,
                          title: 'Find web novels',
                          body: 'Install the sites you read from the list in Sources, or bring your own list. '
                              'Then search them all '
                              'from here, add novels to your library, and listen to them like any book.',
                          action: FilledButton.icon(
                            onPressed: _openSources,
                            icon: const Icon(Icons.extension_outlined),
                            label: const Text('Install sources'),
                          ),
                        ),
                      ),
                    )
                  // The sources and a search's results fade into each
                  // other's place.
                  : fadeSwitch(
                      context,
                      searching
                          ? KeyedSubtree(key: const ValueKey('results'), child: _resultsList(context))
                          : KeyedSubtree(key: const ValueKey('sources'), child: _sourcesList(context)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourcesList(BuildContext context) {
    final byLang = <String, List<PluginInfo>>{};
    for (final p in _installed) {
      byLang.putIfAbsent(p.lang.replaceAll(String.fromCharCode(0x200E), ''), () => []).add(p);
    }
    return ListView(
      padding: EdgeInsets.only(bottom: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        for (final group in byLang.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.xs),
            child: Eyebrow(group.key),
          ),
          for (final p in group.value)
            ListTile(
              leading: SourceIcon(plugin: p),
              title: Text(p.name),
              subtitle: Text(Uri.tryParse(p.site)?.host ?? p.site),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SourceScreen(store: widget.store, plugin: p),
              )),
            ),
        ],
      ],
    );
  }

  Widget _resultsList(BuildContext context) {
    final shown = [
      for (final r in _results)
        if (!_onlyFound || (r.items?.isNotEmpty ?? false)) r,
    ];
    final waiting = _results.where((r) => !r.done).length;
    return ListView(
      padding: EdgeInsets.only(bottom: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.s),
          child: Row(
            children: [
              Expanded(
                child: Eyebrow(waiting > 0 ? 'Asking ${_results.length} sources… $waiting to go' : 'Searched ${_results.length} sources'),
              ),
              FilterChip(
                label: const Text('Has results'),
                selected: _onlyFound,
                onSelected: (v) => setState(() => _onlyFound = v),
              ),
            ],
          ),
        ),
        for (final r in shown) _resultRow(context, r),
      ],
    );
  }

  Widget _resultRow(BuildContext context, _Results r) {
    final items = r.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.s, Gap.s),
          child: Row(
            children: [
              SourceIcon(plugin: r.plugin, size: 28),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(r.plugin.name, style: Skin.title(context, size: 18))),
              AnimatedSwitcher(
                duration: Motion.of(context, Motion.quick),
                child: !r.done
                    ? const SizedBox(
                        key: ValueKey('wait'),
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : items != null
                        ? Text('${items.length}', key: const ValueKey('count'), style: Skin.meta(context))
                        : const SizedBox.shrink(),
              ),
              if (items != null && items.isNotEmpty)
                IconButton(
                  tooltip: 'More from ${r.plugin.name}',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => SourceScreen(store: widget.store, plugin: r.plugin, initialQuery: _query),
                  )),
                )
              else
                // Where the arrow would be, so the counts line up.
                const SizedBox(width: 48),
            ],
          ),
        ),
        // What the source answered opens in under its name, instead of the
        // rows below jumping as each source replies.
        growIn(
          context,
          r.error != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  child: SourceProblemLine(error: r.error!, onRetry: () => _retry(r)),
                )
              : items == null
                  ? null
                  : items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                          child: Text(
                            'Nothing found here.',
                            style: Skin.label(context, size: 13, color: Skin.inkFaintOn(context)),
                          ),
                        )
                      : SizedBox(
                          height: 196,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                            itemCount: items.length,
                            separatorBuilder: (_, __) => const SizedBox(width: Gap.m),
                            itemBuilder: (context, i) => SizedBox(
                              width: 112,
                              child: RemoteNovelTile(
                                item: items[i],
                                referer: r.plugin.site,
                                onTap: () => _openNovel(r.plugin, items[i]),
                              ),
                            ),
                          ),
                        ),
        ),
      ],
    );
  }
}

/// One source: its popular or newest novels, or a search, endlessly paged.
class SourceScreen extends StatefulWidget {
  const SourceScreen({super.key, required this.store, required this.plugin, this.initialQuery});

  final LibraryStore store;
  final PluginInfo plugin;
  final String? initialQuery;

  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

enum _Feed { popular, latest, search }

class _SourceScreenState extends State<SourceScreen> {
  late _Feed _feed = widget.initialQuery == null ? _Feed.popular : _Feed.search;
  late final _search = TextEditingController(text: widget.initialQuery);
  final _items = <NovelItem>[];
  int _page = 0;
  bool _loading = false;
  bool _end = false;
  Object? _error;
  int _run = 0;

  /// The novels showing are the last feed's, dimmed, while the first page
  /// of a new one (Popular, Latest, a search) is on its way.
  bool _stale = false;

  /// Bumped as each feed's first page comes in, which fades in from the top.
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reset());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Another feed. The grid used to empty at once and pop full again; now
  /// it stays, dimmed, until the new feed's first page takes its place.
  Future<void> _reset() async {
    _run++;
    setState(() {
      _stale = _items.isNotEmpty;
      _page = 0;
      _end = false;
      _error = null;
      // A page of the last feed still on its way is dropped when it lands;
      // it must not hold this one up.
      _loading = false;
    });
    await _more();
  }

  /// The last feed's novels, gone for the new feed's (or its problem).
  void _replaceStale() {
    if (_stale) _items.clear();
    _stale = false;
    _shown++;
  }

  Future<void> _more() async {
    if (_loading || _end) return;
    final run = _run;
    setState(() => _loading = true);
    try {
      final page = _page + 1;
      final engine = SourceEngine.instance;
      final got = switch (_feed) {
        _Feed.popular => await engine.popular(widget.plugin, page),
        _Feed.latest => await engine.popular(widget.plugin, page, latest: true),
        _Feed.search => await engine.search(widget.plugin, _search.text.trim(), page),
      };
      if (!mounted || run != _run) return;
      final seen = {if (!_stale) for (final n in _items) n.path};
      final fresh = [for (final n in got) if (seen.add(n.path)) n];
      setState(() {
        if (page == 1) _replaceStale();
        _items.addAll(fresh);
        _page = page;
        _end = fresh.isEmpty;
      });
    } on Object catch (e) {
      if (mounted && run == _run) {
        setState(() {
          if (_page == 0) _replaceStale();
          _error = e;
        });
      }
    } finally {
      if (mounted && run == _run) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: widget.plugin.name, onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context)),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: 'Search ${widget.plugin.name}',
                  ),
                  onSubmitted: (q) {
                    _feed = q.trim().isEmpty ? _Feed.popular : _Feed.search;
                    unawaited(_reset());
                  },
                ),
              ),
              // Popular and Latest fold away for a search, rather than the
              // grid jumping up under them.
              growIn(
                context,
                _feed == _Feed.search
                    ? null
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                        child: ChoiceRow<_Feed>(
                          options: const [(_Feed.popular, 'Popular'), (_Feed.latest, 'Latest')],
                          value: _feed,
                          onChanged: (f) {
                            _feed = f;
                            unawaited(_reset());
                          },
                        ),
                      ),
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 600) unawaited(_more());
                    return false;
                  },
                  // Each feed's first page fades in, from the top.
                  child: FadeIn(
                    trigger: _shown,
                    arrive: false,
                    child: CustomScrollView(
                      key: ValueKey(_shown),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, 0),
                          sliver: SliverAnimatedOpacity(
                            opacity: _stale ? 0.4 : 1,
                            duration: Motion.of(context, Motion.standard),
                            curve: Motion.out,
                            sliver: SliverGrid(
                              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: landscape ? 170 : 190,
                                mainAxisSpacing: 14,
                                crossAxisSpacing: 14,
                                childAspectRatio: 2 / 3,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                childCount: _items.length,
                                (context, i) => RemoteNovelTile(
                                  item: _items[i],
                                  referer: widget.plugin.site,
                                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                                    builder: (_) => NovelScreen(
                                      store: widget.store,
                                      plugin: widget.plugin,
                                      path: _items[i].path,
                                      name: _items[i].name,
                                      cover: _items[i].cover,
                                    ),
                                  )),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                                Gap.page, Gap.xl, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                            child: _loading
                                ? const Center(child: CircularProgressIndicator())
                                : _error != null
                                    ? SourceProblem(error: _error!, onRetry: _reset)
                                    : _items.isEmpty
                                        ? Text('Nothing here.', textAlign: TextAlign.center, style: Skin.label(context))
                                        : const SizedBox.shrink(),
                          ),
                        ),
                      ],
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

/// A novel from a site: its cover with the title on a translucent band, the
/// way the library shows books.
class RemoteNovelTile extends StatelessWidget {
  const RemoteNovelTile({super.key, required this.item, required this.onTap, this.referer});

  final NovelItem item;
  final VoidCallback onTap;
  final String? referer;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: item.name,
        child: GestureDetector(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, c) => ClipRRect(
              borderRadius: BorderRadius.circular(Radii.row - 4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    child: NetworkCover(url: item.cover, title: item.name, width: c.maxWidth, referer: referer, titled: false),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.85)],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.s, 28, Gap.s, Gap.s),
                        child: Text(
                          item.name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.title(context, size: 14, color: Colors.white).copyWith(height: 1.15),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// A source's icon from its repository, or a globe.
class SourceIcon extends StatelessWidget {
  const SourceIcon({super.key, required this.plugin, this.size = 40});

  final PluginInfo plugin;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Skin.raisedOn(context),
      child: Icon(Icons.public_rounded, size: size * 0.6, color: Skin.inkSoftOn(context)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: SizedBox(
        width: size,
        height: size,
        child: plugin.iconUrl == null
            ? fallback
            : Image.network(plugin.iconUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
      ),
    );
  }
}
