import 'dart:async';

import 'package:flutter/material.dart';

import 'browse_screen.dart';
import 'browser_check.dart';
import 'library_store.dart';
import 'listening_session.dart';
import 'novel_move.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/plugin_host.dart';
import 'sources/source_engine.dart';
import 'theme.dart';
import 'ui.dart';

/// What moving a novel will do, in words, for the question before it is
/// moved.
String moveSummary(MovePlan plan) {
  final n = plan.novel.chapters.length;
  final from = plan.match.fromCount;
  final d = plan.downloads, carried = plan.carried;
  return [
    '"${plan.novel.name}" has $n ${n == 1 ? 'chapter' : 'chapters'} there; '
        '${plan.match.matched} of the $from here were found among them.',
    if (plan.place >= 0) 'Your place, chapter ${plan.place + 1}, is chapter ${plan.placeThere + 1} there.',
    if (d > 0)
      carried == d
          ? (d == 1 ? 'The downloaded chapter goes to its chapter there.' : 'All $d downloaded chapters go to their chapters there.')
          : '$carried of $d downloaded chapters go to their chapters there; the ${d - carried} that match none '
              'are kept aside, not deleted.',
    if (plan.marks > 0) '${plan.marks == 1 ? 'Its quote or bookmark goes' : 'Its ${plan.marks} quotes and bookmarks go'} with it.',
    if (plan.readMarks > 0) 'So do the chapters you marked read or unread.',
  ].join(' ');
}

/// Why a novel being read aloud is not moved yet: its place is being saved
/// as it reads.
const _stillReading = 'It is being read aloud. Stop it first, then move it.';

/// Move a web novel to another source, as Mihon migrates: the other sources
/// installed are searched for it (in its source's language, or every one),
/// and the novel picked takes its place in the library, with its place,
/// downloads, quotes and read marks carried to the same chapters there.
/// Pops the novel's new entry once it has moved.
class NovelMoveScreen extends StatefulWidget {
  const NovelMoveScreen({super.key, required this.store, required this.entry, required this.from});

  final LibraryStore store;
  final LibraryEntry entry;

  /// The source it comes from now.
  final PluginInfo from;

  /// Whether [entry] can move now (it is not being read aloud); says why not.
  static bool mayMove(BuildContext context, LibraryEntry entry) {
    if (BackgroundReading.current.value?.bookId != entry.id) return true;
    showSnack(context, _stillReading);
    return false;
  }

  @override
  State<NovelMoveScreen> createState() => _NovelMoveScreenState();
}

/// One source's answer.
class _Found {
  _Found(this.plugin);

  final PluginInfo plugin;
  List<NovelItem>? items;
  Object? error;

  bool get done => items != null || error != null;
}

class _NovelMoveScreenState extends State<NovelMoveScreen> {
  late final _search = TextEditingController(text: widget.entry.title);
  List<PluginInfo> _installed = const [];
  List<_Found> _results = const [];
  bool _everyLanguage = false;
  int _run = 0;

  /// The novel picked is being read, or moved.
  String? _busy;

  /// How long one source has to answer before it is said to be slow.
  static const _patience = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _run++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final all = await SourceEngine.instance.store.installed();
    if (!mounted) return;
    setState(() => _installed = [for (final p in all) if (p.id != widget.from.id) p]);
    await _ask();
  }

  /// The sources asked: those in the novel's source's language, or every one.
  List<PluginInfo> get _asked => [
        for (final p in _installed)
          if (_everyLanguage || p.lang == widget.from.lang) p,
      ];

  /// Search the sources for the words in the field, a few at a time; each
  /// row fills in as its site answers.
  Future<void> _ask() async {
    final query = _search.text.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    final run = ++_run;
    final results = [for (final p in _asked) _Found(p)];
    setState(() => _results = results);
    if (query.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < results.length && run == _run) {
        final r = results[next++];
        await _one(r, query);
        if (mounted && run == _run) setState(() {});
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
  }

  Future<void> _one(_Found r, String query) async {
    try {
      r.items = await SourceEngine.instance.search(r.plugin, query, 1).timeout(_patience);
    } on TimeoutException {
      r.error = 'Took too long to answer.';
    } on Object catch (e) {
      r.error = e;
    }
  }

  /// One source again, after its browser check.
  Future<void> _retry(_Found r) async {
    final run = _run;
    setState(() {
      r.items = null;
      r.error = null;
    });
    await _one(r, _search.text.trim());
    if (mounted && run == _run) setState(() {});
  }

  /// [n] on [p] picked: its chapters read and matched, what moving it does
  /// asked, and then it is moved.
  Future<void> _pick(PluginInfo p, NovelItem n) async {
    if (_busy != null) return;
    setState(() => _busy = 'Reading its chapters at ${p.name}…');
    try {
      final novel = await SourceEngine.instance.novel(p, n.path);
      final plan = await planMove(widget.store, widget.entry, p, novel);
      if (!mounted) return;
      final ok = await confirm(context, title: 'Move to ${p.name}?', body: moveSummary(plan), action: 'Move');
      if (!ok || !mounted || !NovelMoveScreen.mayMove(context, widget.entry)) return;
      setState(() => _busy = 'Moving it…');
      final moved = await moveNovel(widget.store, widget.entry, plan);
      if (!mounted) return;
      showSnack(context, 'Moved to ${p.name}.');
      Navigator.of(context).pop(moved);
    } on MoveRefused catch (e) {
      if (mounted) showSnack(context, e.message, long: true);
    } on ChallengeException catch (e) {
      if (mounted && await passBrowserCheck(context, e) && mounted) {
        setState(() => _busy = null);
        await _pick(p, n);
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, e is SourceException ? e.message : friendlyError(e), long: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _results.where((r) => !r.done).length;
    final langs = {for (final p in _installed) p.lang};
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Move to another source', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: Text(
                  'Now from ${widget.from.name}. Pick it at another source: your place, downloads, quotes and '
                  'read marks go to the same chapters there.',
                  style: Skin.label(context, size: 14),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context)),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.travel_explore_rounded, size: 20),
                    hintText: 'Its title',
                  ),
                  onSubmitted: (_) => unawaited(_ask()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Eyebrow(_asked.isEmpty
                          ? 'No other source'
                          : waiting > 0
                              ? 'Asking ${_results.length} sources… $waiting to go'
                              : 'Asked ${_results.length} sources'),
                    ),
                    if (langs.any((l) => l != widget.from.lang))
                      FilterChip(
                        label: const Text('Every language'),
                        selected: _everyLanguage,
                        onSelected: (on) {
                          setState(() => _everyLanguage = on);
                          unawaited(_ask());
                        },
                      ),
                  ],
                ),
              ),
              growIn(
                context,
                _busy == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.s),
                        child: Row(
                          children: [
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: Gap.m),
                            Expanded(child: Text(_busy!, style: Skin.label(context))),
                          ],
                        ),
                      ),
              ),
              Expanded(
                child: _asked.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          child: EmptyState(
                            icon: Icons.extension_outlined,
                            title: 'No other source',
                            body: _installed.isEmpty
                                ? 'Install another source that has this novel, in Sources.'
                                : 'No other source in ${widget.from.lang} is installed. Ask them all, '
                                    'or install one in Sources.',
                            action: _installed.isEmpty
                                ? null
                                : OutlinedButton(
                                    onPressed: () {
                                      setState(() => _everyLanguage = true);
                                      unawaited(_ask());
                                    },
                                    child: const Text('Ask every language'),
                                  ),
                          ),
                        ),
                      )
                    : AbsorbPointer(
                        absorbing: _busy != null,
                        child: ListView(
                          padding: EdgeInsets.only(bottom: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                          children: [for (final r in _results) _row(context, r)],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _Found r) {
    final items = r.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.s),
          child: Row(
            children: [
              SourceIcon(plugin: r.plugin, size: 28),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(r.plugin.name, style: Skin.title(context, size: 18))),
              if (!r.done)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else if (items != null)
                Text('${items.length}', style: Skin.meta(context)),
            ],
          ),
        ),
        growIn(
          context,
          r.error != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  child: SourceProblemLine(error: r.error!, onRetry: () => _retry(r), pluginId: r.plugin.id),
                )
              : items == null
                  ? null
                  : items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                          child: Text('Not found here.',
                              style: Skin.label(context, size: 13, color: Skin.inkFaintOn(context))),
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
                                partition: r.plugin.id,
                                onTap: () => _pick(r.plugin, items[i]),
                              ),
                            ),
                          ),
                        ),
        ),
      ],
    );
  }
}
