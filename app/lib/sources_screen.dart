import 'dart:async';

import 'package:flutter/material.dart';

import 'browser_check.dart';
import 'sources/bridge.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/net_image.dart';
import 'sources/source_engine.dart';
import 'sources/source_store.dart';
import 'sources/source_updates.dart';
import 'theme.dart';
import 'ui.dart';

/// Where web-novel sources come from: the repositories you add, and the
/// sources you install from them. TomeVoice ships no list of sites; like
/// LNReader and Mihon, you paste the address of a source list you trust.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.store});

  final SourceStore store;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<String> _repos = const [];

  /// Lists on http:// addresses, added before only https was taken: not
  /// read until added again with https.
  Set<String> _insecure = const {};
  List<PluginInfo> _installed = const [];
  List<PluginInfo> _available = const [];
  Map<String, PluginInfo> _updates = const {};
  bool _loading = true;

  /// When the lists were first read. Until then "No source lists" is not
  /// said (it showed for a moment on every opening); after, the sources
  /// ease in under the lists (they popped in under the spinner).
  DateTime? _loadedAt;
  String? _language;
  String _query = '';
  final _busy = <String>{};

  /// Held here so the search survives the list above it growing.
  final _search = TextEditingController();

  SourceStore get _store => widget.store;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);
    final repos = await _store.repos();
    final insecure = await _store.insecureRepos();
    final installed = await _store.installed();
    final available = await _store.available(refresh: refresh);
    // Each source is updated from the list it came from, never another's.
    final updates = await _store.updates();
    if (!mounted) return;
    setState(() {
      _repos = repos;
      _insecure = insecure.toSet();
      _installed = installed;
      _available = available;
      _updates = updates;
      _language ??= _defaultLanguage(available);
      _loading = false;
      _loadedAt ??= DateTime.now();
    });
  }

  static String? _defaultLanguage(List<PluginInfo> available) {
    final langs = {for (final p in available) p.lang};
    if (langs.contains('English')) return 'English';
    return langs.isEmpty ? null : langs.first;
  }

  Future<void> _addRepo() async {
    final url = await askText(
      context,
      title: 'Add a source list',
      hint: 'https://…/plugins.min.json',
      action: 'Add',
    );
    if (url == null || !mounted) return;
    showSnack(context, 'Checking that list…');
    try {
      final n = await _store.addRepo(url);
      if (!mounted) return;
      showSnack(context, 'Added. It lists $n sources.');
      await _load(refresh: true);
    } on Object catch (e) {
      if (mounted) showSnack(context, _message(e), long: true);
    }
  }

  Future<void> _removeRepo(String url) async {
    final ok = await confirm(
      context,
      title: 'Remove this source list?',
      body: 'Sources you installed from it stay installed, but will not get updates.',
      action: 'Remove',
    );
    if (!ok) return;
    await _store.removeRepo(url);
    await _load();
  }

  Future<void> _install(PluginInfo p) async {
    setState(() => _busy.add(p.id));
    try {
      final installed = await _store.install(p);
      // Tried at once (its first popular page), so a source that does not
      // work here says so now, not when a novel is wanted from it.
      final problem = await SourceEngine.instance.smokeTest(installed, _store.codePath(installed.id), installed.sha256!);
      if (mounted) {
        showSnack(
          context,
          problem == null
              ? '${p.name} is ready in Browse.'
              : '${p.name} is installed, but its first page did not load: $problem',
          long: problem != null,
        );
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, '${p.name}: ${_message(e)}', long: true);
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
      await _load();
    }
  }

  /// "Update all" while it runs: which source, and how far.
  String? _updating;

  /// Update [updates] (one, from its row, or all), each kept at the version
  /// that works (see updateSources), and say what came of it.
  Future<void> _update(List<PluginInfo> updates) async {
    if (_updating != null || updates.isEmpty) return;
    setState(() {
      _busy.addAll(updates.map((p) => p.id));
      _updating = 'Getting ready…';
    });
    try {
      final outcomes = await updateSources(_store, SourceEngine.instance, updates, onProgress: (p, done, total) {
        if (mounted) setState(() => _updating = 'Updating ${p.name} (${done + 1} of $total)…');
      });
      if (!mounted) return;
      final updated = outcomes.where((o) => o.updated).length;
      final notes = [for (final o in outcomes) if (o.note != null) '${o.plugin.name}: ${o.note}'];
      showSnack(
        context,
        [
          if (updated > 0) updated == 1 ? 'Updated.' : 'Updated $updated sources.',
          ...notes,
        ].join(' '),
        long: notes.isNotEmpty,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy.removeAll(updates.map((p) => p.id));
          _updating = null;
        });
      }
      await _load();
    }
  }

  /// Uninstall [p], with its settings and cookies (a sign-in among them):
  /// nothing of it is left for a source installed under its id later.
  Future<void> _uninstall(PluginInfo p) async {
    await _store.uninstall(p.id);
    SourceEngine.instance.forget(p.id);
    await _load();
  }

  /// Forget the cookies sites set (sign-ins and browser checks among them),
  /// the app's and the web view's: every site's, or [p]'s.
  Future<void> _clearCookies([PluginInfo? p]) async {
    final ok = await confirm(
      context,
      title: p == null ? 'Clear site cookies?' : 'Clear ${p.name}\'s cookies?',
      body: 'Sites forget you were here: any sign-in ends, and a site with a browser check may ask for it again.',
      action: 'Clear',
    );
    if (!ok) return;
    await Net.instance.clearCookies(partition: p?.id);
    await SourcesBridge.clearWebCookies(url: p?.site);
    if (mounted) showSnack(context, p == null ? 'Site cookies cleared.' : '${p.name}\'s cookies cleared.');
  }

  static String _message(Object e) => friendlyError(e);

  @override
  Widget build(BuildContext context) {
    final langs = ({for (final p in _available) p.lang}.toList()..sort());
    final installedIds = {for (final p in _installed) p.id};
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final p in _available)
        if (!installedIds.contains(p.id) &&
            (q.isNotEmpty ? p.name.toLowerCase().contains(q) || p.site.toLowerCase().contains(q) : p.lang == _language))
          p,
    ];
    var row = 0;
    Widget arrive(Widget child) => Entrance(index: row++, since: _loadedAt, child: child);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ScreenTopBar(title: 'Sources', onBack: () => Navigator.of(context).maybePop())),
                  if (_repos.isNotEmpty)
                    RoundButton(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Check for updates',
                      onTap: () => _load(refresh: true),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: PopupMenuButton<String>(
                      tooltip: 'More',
                      onSelected: (v) {
                        if (v == 'cookies') unawaited(_clearCookies());
                      },
                      itemBuilder: (_) => const [PopupMenuItem(value: 'cookies', child: Text('Clear site cookies'))],
                    ),
                  ),
                ],
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _load(refresh: true),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(0, 0, 0, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      _section('Source lists'),
                      if (_loadedAt != null && _repos.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                          child: Text(
                            'No source lists. Add the address of one to find web novels: TomeVoice reads lists in '
                            'LNReader\'s format, so any LNReader plugin repository works. The sites belong to '
                            'their owners; add only lists you trust.',
                            style: Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                                .copyWith(height: 1.45),
                          ),
                        ),
                      for (final r in _repos)
                        ListTile(
                          leading: Icon(_insecure.contains(r) ? Icons.link_off_rounded : Icons.link_rounded),
                          title: Text(_repoName(r), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            _insecure.contains(r) ? 'Not read: http:// is not safe for code. Add it again with https://' : r,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove list',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => _removeRepo(r),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
                        child: OutlinedButton.icon(
                          onPressed: _addRepo,
                          icon: const Icon(Icons.add_link_rounded, size: 20),
                          label: const Text('Add a source list'),
                        ),
                      ),
                      if (_updates.isNotEmpty) ...[
                        arrive(_section('Updates', note: '${_updates.length}')),
                        arrive(Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _updating ??
                                      'Sites change, and their sources are fixed to match. Each update is tried '
                                          'first; one that does not work leaves the version you have.',
                                  style: Skin.label(context, size: 13.5),
                                ),
                              ),
                              const SizedBox(width: Gap.m),
                              FilledButton.tonal(
                                onPressed: _updating != null ? null : () => _update([..._updates.values]),
                                child: const Text('Update all'),
                              ),
                            ],
                          ),
                        )),
                      ],
                      if (_installed.isNotEmpty) ...[
                        arrive(_section('Installed', note: '${_installed.length}')),
                        for (final p in _installed) arrive(_installedRow(context, p)),
                      ],
                      if (_available.isNotEmpty) ...[
                        arrive(_section('Available', note: '${_available.length - installedIds.length}')),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                          child: SearchField(
                            hint: 'Find a source',
                            controller: _search,
                            onChanged: (v) => setState(() => _query = v),
                            onClear: _query.isEmpty
                                ? null
                                : () => setState(() {
                                      _search.clear();
                                      _query = '';
                                    }),
                          ),
                        ),
                        if (q.isEmpty && langs.length > 1)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                            child: ChoiceRow<String>(
                              options: [for (final l in langs) (l, l.replaceAll(String.fromCharCode(0x200E), ''))],
                              value: _language ?? langs.first,
                              onChanged: (l) => setState(() => _language = l),
                            ),
                          ),
                        for (final p in shown) arrive(_availableRow(context, p)),

                        if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(Gap.page),
                            child: Text('Nothing more to install here.', style: Skin.label(context)),
                          ),
                      ],
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(Gap.xl),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _repoName(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    final parts = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (u.host.contains('githubusercontent') && parts.length >= 2) return '${parts[0]}/${parts[1]}';
    return u.host;
  }

  Widget _section(String title, {String? note}) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, Gap.s),
        child: SectionTitle(title, note: note),
      );

  Widget _icon(PluginInfo p) => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.chip),
        child: SizedBox(
          width: 40,
          height: 40,
          child: p.iconUrl == null
              ? ColoredBox(color: Skin.raisedOn(context), child: const Icon(Icons.public_rounded))
              : Image(
                  image: ResizeImage.resizeIfNeeded(
                      (40 * MediaQuery.devicePixelRatioOf(context)).round(), null, NetImage(p.iconUrl!)),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      ColoredBox(color: Skin.raisedOn(context), child: const Icon(Icons.public_rounded)),
                ),
        ),
      );

  Widget _installedRow(BuildContext context, PluginInfo p) {
    final update = _updates[p.id];
    return ListTile(
      leading: _icon(p),
      title: Text(p.name),
      subtitle: Text('${p.lang.replaceAll(String.fromCharCode(0x200E), '')} · v${p.version}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (update != null)
            TextButton(
              onPressed: _busy.contains(p.id) || _updating != null ? null : () => _update([update]),
              child: const Text('Update'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Options for ${p.name}',
            onSelected: (v) => switch (v) {
              'signin' => signInToSite(context, p),
              'cookies' => _clearCookies(p),
              _ => _uninstall(p),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'signin', child: Text('Sign in to its site')),
              PopupMenuItem(value: 'cookies', child: Text('Clear its cookies')),
              PopupMenuItem(value: 'remove', child: Text('Uninstall')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _availableRow(BuildContext context, PluginInfo p) => ListTile(
        leading: _icon(p),
        title: Text(p.name),
        subtitle: Text(Uri.tryParse(p.site)?.host ?? p.site, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _busy.contains(p.id)
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            : FilledButton.tonal(onPressed: () => _install(p), child: const Text('Install')),
      );
}
