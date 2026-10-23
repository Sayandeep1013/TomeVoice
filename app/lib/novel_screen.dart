import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show SourceKind;

import 'book_actions.dart';
import 'book_card.dart';
import 'browser_check.dart';
import 'library_store.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/source_engine.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'web_reader.dart';

/// A web novel's page, the way NovelDokusha shows one: cover and details,
/// Add to library, Listen, and every chapter (read, downloaded, the one you
/// are on), any of which opens the reader there. The same page for a novel
/// found in Browse and one already in your library.
class NovelScreen extends StatefulWidget {
  const NovelScreen({
    super.key,
    required this.store,
    required this.plugin,
    required this.path,
    this.name,
    this.cover,
  });

  final LibraryStore store;
  final PluginInfo plugin;
  final String path;

  /// What the list showed, so the page has a title before details arrive.
  final String? name;
  final String? cover;

  /// The page of a web novel already in the library.
  static Future<void> openEntry(BuildContext context, LibraryStore store, LibraryEntry e) async {
    final info = await store.webNovel(e.id);
    if (info == null || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NovelScreen(store: store, plugin: info.plugin, path: info.novel.path, name: e.title),
    ));
  }

  @override
  State<NovelScreen> createState() => _NovelScreenState();
}

class _NovelScreenState extends State<NovelScreen> {
  LibraryStore get _store => widget.store;
  late final String _id = LibraryStore.webId(widget.plugin.id, widget.path);

  SourceNovel? _novel;
  List<ChapterItem> _chapters = const [];
  LibraryEntry? _entry;
  Set<int> _downloaded = const {};
  int _current = -1;
  Object? _error;
  bool _loading = true;
  bool _newestFirst = false;
  bool _blurbOpen = false;
  String? _downloading;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_refreshLocal);
    unawaited(_load());
  }

  @override
  void dispose() {
    _store.changes.removeListener(_refreshLocal);
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final entry = (await _store.list()).where((e) => e.id == _id).firstOrNull;
    final cursor = entry == null ? null : await _store.cursorFor(_id);
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _downloaded = _store.downloadedChapters(_id);
      _current = entry == null || entry.openedAt == null ? -1 : cursor!.sectionIndex;
    });
  }

  Future<void> _load() async {
    await _refreshLocal();
    // What is on the phone first, so the page fills at once.
    final stored = await _store.webNovel(_id);
    if (stored != null && mounted) {
      setState(() {
        _novel = stored.novel;
        _chapters = stored.chapters;
        _loading = false;
      });
    }
    // Then the site, for fresh details and new chapters.
    try {
      final plugin = await SourceEngine.instance.store.installedById(widget.plugin.id) ?? widget.plugin;
      final fresh = await SourceEngine.instance.novel(plugin, widget.path);
      if (!mounted) return;
      setState(() {
        _novel = fresh;
        if (fresh.chapters.isNotEmpty) _chapters = fresh.chapters;
        _loading = false;
        _error = null;
      });
      if (stored != null && fresh.chapters.length > stored.chapters.length) {
        await _store.saveWebChapters(_id, fresh.chapters);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (stored == null) _error = e;
      });
    }
  }

  /// In the library already, or added now (to the default category).
  Future<LibraryEntry?> _ensureAdded({bool announce = true}) async {
    final have = _entry;
    if (have != null) return have;
    final novel = _novel;
    if (novel == null) return null;
    final e = await _store.addWebNovel(widget.plugin, _withChapters(novel));
    await _refreshLocal();
    if (announce && mounted) {
      final idx = await _store.index();
      final shelf = idx.categories.where((c) => c.id == e.category).firstOrNull?.name ?? 'your library';
      if (mounted) showSnack(context, 'Added to $shelf.');
    }
    return e;
  }

  SourceNovel _withChapters(SourceNovel n) => SourceNovel(
        path: n.path,
        name: n.name.isEmpty ? (widget.name ?? 'Untitled') : n.name,
        cover: n.cover ?? widget.cover,
        author: n.author,
        summary: n.summary,
        status: n.status,
        genres: n.genres,
        chapters: _chapters,
      );

  Future<void> _add() async {
    final novel = _novel;
    if (novel == null) return;
    final cat = await pickCategory(context, _store, title: 'Add to');
    if (cat == null) return;
    await _store.addWebNovel(widget.plugin, _withChapters(novel), category: cat);
    await _refreshLocal();
    if (mounted) showSnack(context, 'Added to your library.');
  }

  Future<void> _read({int? chapter, bool play = false}) async {
    final e = await _ensureAdded();
    if (e == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WebNovelReader(store: _store, entry: e, startChapter: chapter, autoplay: play),
    ));
    await _refreshLocal();
  }

  Future<void> _download(int count) async {
    final e = await _ensureAdded(announce: false);
    if (e == null) return;
    final from = _current < 0 ? 0 : _current;
    try {
      await fetchChapters(_store, _id, from, count: count, onProgress: (c) {
        if (mounted) setState(() => _downloading = 'Downloading chapter ${c + 1}…');
      });
      if (mounted) showSnack(context, 'Downloaded. Those chapters open offline now.');
    } on Object catch (err) {
      if (mounted) showSnack(context, '$err', long: true);
    } finally {
      if (mounted) setState(() => _downloading = null);
      await _refreshLocal();
    }
  }

  Future<void> _openInBrowser() async {
    try {
      final url = await SourceEngine.instance.resolveUrl(widget.plugin, widget.path);
      await const SpeechService().openUrl(url);
    } on Object {
      await const SpeechService().openUrl(widget.plugin.site);
    }
  }

  @override
  Widget build(BuildContext context) {
    final novel = _novel;
    final order = [for (var i = 0; i < _chapters.length; i++) i];
    if (_newestFirst) {
      final reversed = order.reversed.toList();
      order
        ..clear()
        ..addAll(reversed);
    }
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _topBar(context)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
                  sliver: SliverToBoxAdapter(child: _hero(context, novel)),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
                  sliver: SliverToBoxAdapter(child: _actions(context)),
                ),
                if (novel?.summary != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
                    sliver: SliverToBoxAdapter(child: _blurb(context, novel!.summary!)),
                  ),
                if (novel != null && novel.genres.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, 0),
                    sliver: SliverToBoxAdapter(
                      child: Wrap(spacing: 6, runSpacing: 6, children: [for (final g in novel.genres) TagChip(g)]),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xxl, Gap.s, Gap.s),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: SectionTitle(
                            'Chapters',
                            note: _chapters.isEmpty ? null : '${_chapters.length}',
                          ),
                        ),
                        IconButton(
                          tooltip: _newestFirst ? 'Oldest first' : 'Newest first',
                          onPressed: () => setState(() => _newestFirst = !_newestFirst),
                          icon: Icon(_newestFirst ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_downloading != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        children: [
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: Gap.m),
                          Text(_downloading!, style: Skin.label(context)),
                        ],
                      ),
                    ),
                  ),
                if (_error != null)
                  SliverPadding(
                    padding: const EdgeInsets.all(Gap.page),
                    sliver: SliverToBoxAdapter(
                      child: SourceProblem(
                        error: _error!,
                        onRetry: _load,
                        more: OutlinedButton(onPressed: _openInBrowser, child: const Text('Open in browser')),
                      ),
                    ),
                  )
                else if (_loading && _chapters.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(Gap.xxl),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                    sliver: SliverFixedExtentList(
                      itemExtent: 60,
                      delegate: SliverChildBuilderDelegate(
                        childCount: order.length,
                        (context, i) => _chapterRow(context, order[i]),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
        child: Row(
          children: [
            RoundButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const Spacer(),
            PopupMenuButton<String>(
              tooltip: 'Novel options',
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                final e = _entry;
                switch (v) {
                  case 'browser':
                    await _openInBrowser();
                  case 'download10':
                    await _download(10);
                  case 'download50':
                    await _download(50);
                  case 'move':
                    if (e != null) await moveBook(context, _store, e);
                  case 'cover':
                    if (e != null) await changeCover(context, _store, e);
                  case 'remove':
                    final nav = Navigator.of(context);
                    if (e != null && await removeBook(context, _store, e)) await nav.maybePop();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'browser', child: Text('Open in browser')),
                const PopupMenuItem(value: 'download10', child: Text('Download next 10 chapters')),
                const PopupMenuItem(value: 'download50', child: Text('Download next 50 chapters')),
                if (_entry != null) ...[
                  const PopupMenuItem(value: 'move', child: Text('Move to…')),
                  const PopupMenuItem(value: 'cover', child: Text('Change cover')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove from library')),
                ],
              ],
              child: const IgnorePointer(child: RoundButton(icon: Icons.more_vert_rounded)),
            ),
          ],
        ),
      );

  Widget _cover(BuildContext context) {
    final e = _entry;
    if (e != null && e.shownCover != null) return BookCover(entry: e, width: 112);
    final url = _novel?.cover ?? widget.cover;
    return NetworkCover(url: url, title: _novel?.name ?? widget.name ?? '', width: 112, referer: widget.plugin.site);
  }

  Widget _hero(BuildContext context, SourceNovel? novel) {
    final facts = [
      widget.plugin.name,
      if (novel?.status != null && novel!.status != 'Unknown') novel.status!,
      if (_chapters.isNotEmpty) '${_chapters.length} chapters',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _cover(context),
        const SizedBox(width: Gap.l),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (novel?.name.isNotEmpty ?? false) ? novel!.name : (widget.name ?? ''),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Skin.title(context, size: 24, weight: FontWeight.w500).copyWith(height: 1.12),
              ),
              if (novel?.author != null) ...[
                const SizedBox(height: Gap.xs),
                Text(novel!.author!, style: Skin.label(context, size: 15)),
              ],
              const SizedBox(height: Gap.m),
              Wrap(spacing: 5, runSpacing: 5, children: [for (final f in facts) TagChip(f)]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final e = _entry;
    final started = e != null && e.openedAt != null && _current >= 0;
    final ready = _novel != null && _chapters.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (started) ...[
          Progress(e.progress, height: 4),
          const SizedBox(height: 6),
          Text(
            'CHAPTER ${_current + 1} OF ${_chapters.length} · ${percentLabel(e.progress)}',
            style: Skin.meta(context, size: 10.5),
          ),
          const SizedBox(height: Gap.l),
        ],
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: ready ? () => _read(play: true) : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 26),
                label: Text(started ? 'Continue' : 'Listen'),
              ),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: ready ? () => _read() : null,
                icon: const Icon(Icons.menu_book_rounded, size: 20),
                label: const Text('Read'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.m),
        if (e == null)
          OutlinedButton.icon(
            onPressed: _novel == null ? null : _add,
            icon: const Icon(Icons.library_add_outlined, size: 20),
            label: const Text('Add to library'),
          )
        else
          OutlinedButton.icon(
            onPressed: () => moveBook(context, _store, e),
            icon: Icon(Icons.library_add_check_rounded, size: 20, color: Skin.amber),
            label: const Text('In your library'),
          ),
      ],
    );
  }

  Widget _blurb(BuildContext context, String text) => GestureDetector(
        onTap: () => setState(() => _blurbOpen = !_blurbOpen),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                maxLines: _blurbOpen ? null : 4,
                overflow: _blurbOpen ? TextOverflow.visible : TextOverflow.ellipsis,
                style: Skin.page(context, size: 16, height: 1.5).copyWith(color: Skin.inkSoftOn(context)),
              ),
              const SizedBox(height: Gap.xs),
              Text(_blurbOpen ? 'Less' : 'More',
                  style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.amberSoft)),
            ],
          ),
        ),
      );

  Widget _chapterRow(BuildContext context, int i) {
    final c = _chapters[i];
    final isCurrent = i == _current;
    final read = _current >= 0 && i < _current;
    final have = _downloaded.contains(i);
    final release = _shortDate(c.releaseTime);
    return Material(
      color: isCurrent ? Skin.amber.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => _read(chapter: i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text('${i + 1}', style: Skin.meta(context, size: 11.5, color: isCurrent ? Skin.amber : null)),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(
                        size: 15,
                        weight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent
                            ? Skin.amber
                            : read
                                ? Skin.inkFaintOn(context)
                                : Skin.inkOn(context),
                      ),
                    ),
                    if (release != null) Text(release.toUpperCase(), style: Skin.meta(context, size: 9.5)),
                  ],
                ),
              ),
              if (isCurrent) Icon(Icons.graphic_eq_rounded, size: 18, color: Skin.amber),
              if (have && !isCurrent)
                Icon(Icons.offline_pin_rounded, size: 18, color: Skin.inkFaintOn(context)),
            ],
          ),
        ),
      ),
    );
  }

  static String? _shortDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final d = DateTime.tryParse(raw);
    if (d == null) return raw.length > 24 ? null : raw;
    return relativeDay(d.toLocal());
  }
}

/// A cover from a web address, with the drawn cover while it loads or if it
/// cannot be fetched. Some sites only serve images to their own pages, so
/// the request names the site as its referrer.
class NetworkCover extends StatelessWidget {
  const NetworkCover({
    super.key,
    required this.url,
    required this.title,
    required this.width,
    this.referer,
    this.titled = true,
  });

  final String? url;
  final String title;
  final double width;
  final String? referer;

  /// As [BookCover.titled]: tiles with their own title band say false.
  final bool titled;

  @override
  Widget build(BuildContext context) {
    final fallback = BookCover(
      entry: LibraryEntry(
        id: title,
        title: title,
        authors: const [],
        source: SourceKind.web,
        wordCount: 0,
        sourcePath: '',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      width: width,
      titled: titled,
    );
    final u = url;
    if (u == null || !u.startsWith('http')) return fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular((width * 0.07).clamp(4.0, Radii.chip)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        u,
        fit: BoxFit.cover,
        cacheWidth: (width * dpr).round(),
        headers: {
          'User-Agent': Net.userAgent,
          if (referer != null) 'Referer': referer!,
          if (Net.instance.cookieHeader(Uri.parse(u).host) case final cookie?) 'Cookie': cookie,
        },
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
      ),
    );
  }
}
