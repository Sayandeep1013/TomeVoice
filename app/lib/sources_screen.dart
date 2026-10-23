import 'dart:async';

import 'package:flutter/material.dart';

import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/source_store.dart';
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
  List<PluginInfo> _installed = const [];
  List<PluginInfo> _available = const [];
  Map<String, PluginInfo> _updates = const {};
  bool _loading = true;
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
    final installed = await _store.installed();
    final available = await _store.available(refresh: refresh);
    final newest = {for (final p in available) p.id: p};
    if (!mounted) return;
    setState(() {
      _repos = repos;
      _installed = installed;
      _available = available;
      _updates = {
        for (final p in installed)
          if (newest[p.id] != null && p.olderThan(newest[p.id]!)) p.id: newest[p.id]!,
      };
      _language ??= _defaultLanguage(available);
      _loading = false;
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
      await _store.install(p);
      if (mounted) showSnack(context, '${p.name} is ready in Browse.');
    } on Object catch (e) {
      if (mounted) showSnack(context, '${p.name}: ${_message(e)}', long: true);
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
      await _load();
    }
  }

  Future<void> _uninstall(PluginInfo p) async {
    await _store.uninstall(p.id);
    await _load();
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
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.m),
                      child: RoundButton(
                        icon: Icons.refresh_rounded,
                        tooltip: 'Check for updates',
                        onTap: () => _load(refresh: true),
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
                      if (_repos.isEmpty)
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
                          leading: const Icon(Icons.link_rounded),
                          title: Text(_repoName(r), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis),
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
                      if (_installed.isNotEmpty) ...[
                        _section('Installed', note: '${_installed.length}'),
                        for (final p in _installed) _installedRow(context, p),
                      ],
                      if (_available.isNotEmpty) ...[
                        _section('Available', note: '${_available.length - installedIds.length}'),
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
                        for (final p in shown) _availableRow(context, p),
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
              : Image.network(
                  p.iconUrl!,
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
              onPressed: _busy.contains(p.id) ? null : () => _install(update),
              child: const Text('Update'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Options for ${p.name}',
            onSelected: (_) => _uninstall(p),
            itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Uninstall'))],
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
