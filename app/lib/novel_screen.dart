import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, SourceKind, cursorOf;

import 'book_actions.dart';
import 'book_card.dart';
import 'book_search.dart';
import 'book_tint.dart';
import 'browser_check.dart';
import 'chapter_finder.dart';
import 'download_queue.dart';
import 'epub_export.dart';
import 'fast_scroller.dart';
import 'library_store.dart';
import 'novel_move_screen.dart';
import 'prefs.dart';
import 'read_marks.dart';
import 'saved_screen.dart';
import 'secret_shelf.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/net_image.dart';
import 'sources/plugin_host.dart';
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
      builder: (_) => BookTint(
        bookId: e.id,
        cover: e.shownCover,
        child: NovelScreen(store: store, plugin: info.plugin, path: info.novel.path, name: e.title),
      ),
    ));
  }

  @override
  State<NovelScreen> createState() => _NovelScreenState();
}

class _NovelScreenState extends State<NovelScreen> {
  LibraryStore get _store => widget.store;
  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;
  late final String _id = LibraryStore.webId(widget.plugin.id, widget.path);

  SourceNovel? _novel;
  List<ChapterItem> _chapters = const [];

  /// Why the site's latest chapter list was not taken, if it was not.
  ListRefusal? _refusal;

  /// The list holding the chapters, for the fast scroller beside them.
  final _scroll = ScrollController();
  LibraryEntry? _entry;
  Set<int> _downloaded = const {};
  int _current = -1;

  /// Chapters marked read or unread by hand (see ReadMarks).
  ReadMarks _marks = ReadMarks.none;
  Object? _error;
  bool _loading = true;
  /// Newest chapter first: remembered for this novel (and, for novels not
  /// turned yet, the order chosen last).
  late bool _newestFirst = _prefs.newestFirstFor(_id);
  bool _blurbOpen = false;

  /// This novel's downloads in the queue (see DownloadQueue), and the
  /// chapters waiting there, for the spinners on their rows.
  BookDownloads? _downloads;
  Set<String> _queued = const {};

  /// Chapters picked by a long press, for downloading or removing together.
  final _picked = <int>{};
  bool get _picking => _picked.isNotEmpty;

  void _toggle(int i) {
    HapticFeedback.selectionClick();
    setState(() => _picked.contains(i) ? _picked.remove(i) : _picked.add(i));
  }

  /// The novel is on a secret shelf that is shut: the page shows it as if it
  /// were not in the library (no downloads, place or Continue), and asks
  /// for the phone's lock before anything is done with it.
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_refreshLocal);
    _store.placeChanges.addListener(_placeSaved);
    LibraryStore.secretOpen.addListener(_secretChanged);
    DownloadQueue.instance.changes.addListener(_queueChanged);
    ReadMarkStore.instance.changes.addListener(_refreshLocal);
    _queueChanged();
    unawaited(_load());
  }

  @override
  void dispose() {
    // Downloads carry on without the page (see DownloadQueue).
    _store.changes.removeListener(_refreshLocal);
    _store.placeChanges.removeListener(_placeSaved);
    LibraryStore.secretOpen.removeListener(_secretChanged);
    DownloadQueue.instance.changes.removeListener(_queueChanged);
    ReadMarkStore.instance.changes.removeListener(_refreshLocal);
    _scroll.dispose();
    super.dispose();
  }

  /// The queue moved on: this novel's progress, and the ticks of chapters
  /// that came down.
  void _queueChanged() {
    if (!mounted) return;
    final q = DownloadQueue.instance;
    final now = _hidden ? null : q.of(_id);
    final queued = _hidden ? const <String>{} : q.waitingPaths(_id);
    final fewer = queued.length < _queued.length;
    setState(() {
      _downloads = now;
      _queued = queued;
    });
    if (fewer) unawaited(_refreshLocal());
  }

  /// The secret shelves opened or shut: the stored novel shows, or hides
  /// behind the site's own page again.
  void _secretChanged() {
    if (!mounted) return;
    unawaited(LibraryStore.secretOpen.value ? _showStored() : _load());
  }

  /// The stored novel's details and chapters, when it may be shown.
  Future<WebNovelInfo?> _showStored() async {
    await _refreshLocal();
    final stored = _hidden ? null : await _store.settleWebChapters(_id);
    if (stored != null && mounted) {
      setState(() {
        _novel = stored.novel;
        _chapters = stored.chapters;
        _refusal = stored.refusal;
        _loading = false;
      });
    }
    return stored;
  }

  /// Before anything is done with a novel on a shut secret shelf: the
  /// phone's lock. True once the stored novel may be used (never a second
  /// copy of it).
  Future<bool> _unlockIfHidden() async {
    if (!_hidden) return true;
    final ok = await SecretShelf.unlock(reason: 'Open a book on the secret shelf');
    if (ok == null && mounted) showSnack(context, SecretShelf.cannotAsk);
    if (ok != true || !mounted) return false;
    await _showStored();
    return !_hidden;
  }

  /// A place saved. While the reader covers this page (it saves every second
  /// or so) nothing here is seen, so nothing is done: the page catches up
  /// when the reader closes (see _openReader).
  void _placeSaved() {
    if (mounted && TickerMode.getValuesNotifier(context).value.enabled) unawaited(_refreshLocal());
  }

  Future<void> _refreshLocal() async {
    // Read in full first, so whether the novel is on a secret shelf is known.
    await _store.index(all: true);
    final hidden = !LibraryStore.secretOpen.value && _store.isSecret(_id);
    final entry = hidden ? null : (await _store.list()).where((e) => e.id == _id).firstOrNull;
    final cursor = entry == null ? null : await _store.cursorFor(_id);
    final marks = entry == null ? ReadMarks.none : await ReadMarkStore.instance.of(_store, _id);
    if (!mounted) return;
    setState(() {
      _hidden = hidden;
      _entry = entry;
      _downloaded = hidden ? const {} : _store.downloadedChapters(_id);
      _current = entry == null || entry.openedAt == null ? -1 : cursor!.sectionIndex;
      _marks = marks;
    });
  }

  /// [pulled]: the reader pulled the page down to check for new chapters,
  /// so say what came of it.
  Future<void> _load({bool pulled = false}) async {
    // What is on the phone first, so the page fills at once (unless it is
    // on a shut secret shelf: then the page is the site's alone).
    final stored = await _showStored();
    // A long novel's list is many pages of the site: asked again at most
    // hourly, unless the reader pulls for new chapters.
    final checked = stored?.checkedAt;
    if (!pulled && checked != null && DateTime.now().difference(checked) < const Duration(hours: 1)) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Then the site, for fresh details and new chapters.
    try {
      final plugin = await SourceEngine.instance.store.installedById(widget.plugin.id);
      if (plugin == null) throw MissingSourceException(widget.plugin.id, widget.plugin.name);
      final fresh = await SourceEngine.instance.novel(plugin, widget.path);
      if (!mounted) return;
      // The rows open the reader by their place in the list, so they show
      // the list the reader has: the site's, once it is stored. A list that
      // looks wrong (cut short, or every address changed) is not stored,
      // and the page says why.
      final verdict = stored == null ? null : await _store.offerWebChapters(_id, fresh.chapters, complete: fresh.complete);
      final take = verdict == null ? fresh.chapters.isNotEmpty : verdict.taken;
      final had = {for (final c in stored?.chapters ?? _chapters) c.path};
      final added = take ? fresh.chapters.where((c) => !had.contains(c.path)).length : 0;
      final refusal = verdict == null ? null : (await _store.webNovel(_id))?.refusal;
      if (!mounted) return;
      if (pulled) {
        showSnack(
          context,
          verdict != null && verdict.refused
              ? verdict.why ?? 'The site\'s list was not taken.'
              : switch (added) {
                  > 1 => '$added new chapters.',
                  1 => 'One new chapter.',
                  _ => 'No new chapters yet.',
                },
          long: verdict?.refused ?? false,
        );
      }
      setState(() {
        _novel = fresh;
        if (take) _chapters = fresh.chapters;
        _refusal = refusal;
        _loading = false;
        _error = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (stored == null) _error = e;
      });
      if (pulled && stored != null) _problem(e);
    }
  }

  /// The list the site gave that was kept aside (its chapters all moved to
  /// new addresses), taken because the reader chose it. Downloads find
  /// their chapters by title; none is deleted.
  Future<void> _useOffered() async {
    final ok = await confirm(
      context,
      title: "Use the site's chapter list?",
      body: 'The chapters on the phone are matched to the new list by their titles. '
          'A download that matches nothing is kept aside, not deleted.',
      action: 'Use it',
    );
    if (!ok || !mounted) return;
    final verdict = await _store.useOfferedChapters(_id);
    if (!mounted) return;
    if (verdict.refused) {
      showSnack(context, verdict.why ?? 'That did not work. Check the site again.', long: true);
      return;
    }
    final info = await _store.webNovel(_id);
    await _refreshLocal();
    if (!mounted || info == null) return;
    setState(() {
      _chapters = info.chapters;
      _refusal = info.refusal;
    });
    showSnack(context, "Now using the site's list.");
  }

  /// A failed check or download, said in a snack; a missing source comes
  /// with a button to install it.
  void _problem(Object e) {
    if (e is! MissingSourceException) {
      showSnack(context, friendlyError(e), long: true);
      return;
    }
    showSnack(
      context,
      '${e.name} is not installed, so new chapters cannot be checked or downloaded. '
      'The chapters on the phone still read.',
      long: true,
      actionLabel: 'Install',
      onAction: () async {
        if (await installMissingSource(context, e) && mounted) await _load(pulled: true);
      },
    );
  }

  /// In the library already, or added now (to the default category).
  Future<LibraryEntry?> _ensureAdded({bool announce = true}) async {
    if (!await _unlockIfHidden()) return null;
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
    // On a shut secret shelf: in the library already, once the lock is given.
    if (_hidden) {
      if (await _unlockIfHidden() && mounted && _entry != null) showSnack(context, 'It is in your library.');
      return;
    }
    final cat = await pickCategory(context, _store, title: 'Add to');
    if (cat == null) return;
    await _store.addWebNovel(widget.plugin, _withChapters(novel), category: cat);
    await _refreshLocal();
    if (mounted) showSnack(context, 'Added to your library.');
  }

  /// Set while the novel is being opened: a second tap does nothing.
  bool _opening = false;

  Future<void> _read({int? chapter, bool play = false}) async {
    if (_opening) return;
    _opening = true;
    try {
      // A row of the site's list, shown while the novel was hidden, is
      // found again in the stored list once the lock is given.
      final paths = _pathsOf([if (chapter != null) chapter]);
      if (!await _unlockIfHidden()) return;
      await _openReader(chapter: chapter == null ? null : _placesOf(paths, [chapter]).firstOrNull, play: play);
    } finally {
      _opening = false;
    }
  }

  List<String> _pathsOf(Iterable<int> chapters) => [
        for (final i in chapters)
          if (i >= 0 && i < _chapters.length) _chapters[i].path,
      ];

  /// Where chapters [paths] are in the list shown now; [fallback] where
  /// they cannot be found.
  List<int> _placesOf(List<String> paths, List<int> fallback) {
    if (paths.length != fallback.length) return fallback;
    final at = {for (var i = 0; i < _chapters.length; i++) _chapters[i].path: i};
    return [for (var k = 0; k < paths.length; k++) at[paths[k]] ?? fallback[k]];
  }

  Future<void> _openReader({int? chapter, ReadingCursor? at, bool play = false}) async {
    final e = await _ensureAdded();
    if (e == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: e.id,
        cover: e.shownCover,
        child: WebNovelReader(store: _store, entry: e, startChapter: chapter, at: at, autoplay: play),
      ),
    ));
    await _refreshLocal();
  }

  /// Find a chapter by its number or words from its title, and read it.
  Future<void> _findChapter() async {
    final picked = await showChapterFinder(
      context,
      titles: [for (final c in _chapters) c.name],
      current: _current,
      onPhone: _downloaded,
      heading: 'Find a chapter',
      autofocus: true,
    );
    if (picked != null && mounted) await _read(chapter: picked);
  }

  /// Find words in the chapters on the phone, and read from the one picked.
  Future<void> _findPassage() async {
    final layout = await _store.loadLayout(_id);
    if (!mounted) return;
    if (layout.isEmpty) {
      showSnack(context, 'Download some chapters first: a passage is found in the chapters on the phone.');
      return;
    }
    await showBookSearch(
      context,
      layout: layout,
      chapter: 0,
      wholeBook: true,
      onPick: (hits, i, _) {
        if (_opening) return;
        _opening = true;
        unawaited(_openReader(at: cursorOf(layout.units[hits[i].unit])).whenComplete(() => _opening = false));
      },
    );
  }

  /// Download [count] chapters from [from] (the place reached, by default)
  /// that are not on the phone yet.
  Future<void> _download(int count, {int? from}) async {
    final start = from ?? (_current < 0 ? 0 : _current);
    await _downloadList([for (var i = start; i < start + count && i < _chapters.length; i++) i]);
  }

  /// Download those of [chapters] not on the phone yet, in order: queued
  /// (see DownloadQueue), so they keep coming when the page is left, with
  /// progress here and in a notification.
  Future<void> _downloadList(Iterable<int> chapters, {bool first = false}) async {
    var wanted = [for (final i in chapters) if (!_downloaded.contains(i)) i]..sort();
    if (wanted.isEmpty) {
      showSnack(context, 'Those chapters are already on the phone.');
      return;
    }
    final paths = _pathsOf(wanted);
    final e = await _ensureAdded(announce: false);
    if (e == null || !mounted) return;
    wanted = [for (final i in _placesOf(paths, wanted)) if (!_downloaded.contains(i)) i]..sort();
    final added = await DownloadQueue.instance.add(_id, [for (final i in wanted) _chapters[i]], first: first);
    if (!mounted || wanted.length == 1) return;
    showSnack(
      context,
      added == 0
          ? 'Those chapters are on their way already.'
          : 'Downloading $added ${added == 1 ? 'chapter' : 'chapters'}. They keep coming if you leave this page.',
    );
  }

  /// The picked chapters that are not on the phone, downloaded.
  Future<void> _downloadPicked() async {
    final picked = {..._picked};
    setState(_picked.clear);
    await _downloadList(picked);
  }

  /// The picked chapters' downloaded text, taken off the phone.
  Future<void> _removePicked() async {
    final gone = _picked.where(_downloaded.contains).toList();
    setState(_picked.clear);
    if (gone.isEmpty) return;
    await _store.deleteChapters(_id, gone);
    await _refreshLocal();
    if (mounted) {
      showSnack(context, gone.length == 1 ? 'Removed the download.' : 'Removed ${gone.length} downloads.');
    }
  }

  /// One chapter, from the download button on its row: first in the queue.
  Future<void> _downloadOne(int chapter) => _downloadList([chapter], first: true);

  /// Whether chapter [i] shows as read: its own mark, or the place past it.
  bool _isRead(int i) => i >= 0 && i < _chapters.length && _marks.isRead(i, _chapters[i].path, _current);

  /// The picked chapters marked read ([how] 'read') or unread ('unread');
  /// or, for one chapter, every chapter before it marked read ('earlier':
  /// those above it, oldest first, or below it, newest first).
  Future<void> _markPicked(String how) async {
    final picked = [..._picked]..sort();
    setState(_picked.clear);
    final paths = how == 'earlier'
        ? chaptersBefore([for (final c in _chapters) c.path], picked.first)
        : _pathsOf(picked);
    if (paths.isEmpty) return;
    // Marks are kept with the novel: one from Browse is added first.
    final e = await _ensureAdded(announce: false);
    if (e == null || !mounted) return;
    final marks = await ReadMarkStore.instance.mark(_store, _id, paths, read: how != 'unread');
    if (!mounted) return;
    setState(() => _marks = marks);
    final n = paths.length;
    showSnack(
      context,
      how == 'unread'
          ? (n == 1 ? 'Marked as unread.' : 'Marked $n chapters as unread.')
          : (n == 1 ? 'Marked as read.' : 'Marked $n chapters as read.'),
    );
  }

  /// Find the novel at another source and move it there (see
  /// NovelMoveScreen); this page then makes way for the novel's page there.
  Future<void> _moveSource() async {
    final e = _entry;
    if (e == null || !NovelMoveScreen.mayMove(context, e)) return;
    final moved = await Navigator.of(context).push<LibraryEntry>(MaterialPageRoute(
      builder: (_) => NovelMoveScreen(store: _store, entry: e, from: widget.plugin),
    ));
    if (moved == null || !mounted) return;
    final info = await _store.webNovel(moved.id);
    if (info == null || !mounted) return;
    unawaited(Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: moved.id,
        cover: moved.shownCover,
        child: NovelScreen(store: _store, plugin: info.plugin, path: info.novel.path, name: moved.title),
      ),
    )));
  }

  Future<void> _openInBrowser() async {
    var url = widget.plugin.site;
    try {
      // What the plugin says is only opened if it is a web page.
      final resolved = await SourceEngine.instance.resolveUrl(widget.plugin, widget.path);
      if (Net.isWebAddress(resolved)) url = resolved;
    } on Object {
      // The site's home page will do.
    }
    if (Net.isWebAddress(url)) await const SpeechService().openUrl(url);
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
    final size = MediaQuery.sizeOf(context);
    final wide = size.width > size.height && size.width >= 720;
    final bottomGap = SliverToBoxAdapter(
      child: SizedBox(height: Gap.xxl + 72 + MediaQuery.viewPaddingOf(context).bottom),
    );
    // Dragged, the thumb names the chapter it has reached.
    Widget fast(Widget list, {double top = 0}) => FastScroller(
          controller: _scroll,
          top: top,
          bottom: Gap.m + MediaQuery.viewPaddingOf(context).bottom,
          labelAt: (f) => order.isEmpty ? null : 'Chapter ${order[(f * (order.length - 1)).round()] + 1}',
          child: list,
        );
    final info = <Widget>[
      PinnedBar(child: _topBar(context)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: _hero(context, novel)),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: _actions(context)),
      ),
      // The site's details open in as they arrive, instead of pushing the
      // chapters down in one jump.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: growIn(
            context,
            novel?.summary == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: Gap.xl),
                    child: _blurb(context, novel!.summary!),
                  ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: growIn(
            context,
            novel == null || novel.genres.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: Gap.l),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [for (final g in novel.genres) TagChip(g)]),
                  ),
          ),
        ),
      ),
      if (_entry != null)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
          sliver: SliverToBoxAdapter(child: BookSavedSection(store: _store, entry: _entry!)),
        ),
    ];
    final chapterList = <Widget>[
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
                onPressed: () {
                  setState(() => _newestFirst = !_newestFirst);
                  _prefs.setNewestFirst(_id, _newestFirst);
                },
                icon: Icon(_newestFirst ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded),
              ),
            ],
          ),
        ),
      ),
      // The site's latest list was not taken: why, and (when its chapters
      // all moved) the choice to take it.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: growIn(
            context,
            _refusal == null || _entry == null ? null : _refusalNote(context, _refusal!),
          ),
        ),
      ),
      // The download line opens and closes instead of shifting the list.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: growIn(context, _downloads == null ? null : _downloadLine(context, _downloads!)),
        ),
      ),
      if (_error != null)
        SliverPadding(
          padding: const EdgeInsets.all(Gap.page),
          sliver: SliverToBoxAdapter(
            child: SourceProblem(
              error: _error!,
              onRetry: _load,
              pluginId: widget.plugin.id,
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
        // Fades in over the spinner, and again when the order turns round.
        SliverFadeIn(
          key: ValueKey(_newestFirst),
          sliver: SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
            sliver: SliverFixedExtentList(
              itemExtent: 60,
              delegate: SliverChildBuilderDelegate(
                childCount: order.length,
                (context, i) => _chapterRow(context, order[i]),
              ),
            ),
          ),
        ),
    ];
    return PopScope(
      canPop: !_picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_picked.clear);
      },
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                // Landscape on a phone: details beside the chapters.
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 420, child: CustomScrollView(slivers: [...info, bottomGap])),
                      Expanded(
                        child: fast(RefreshIndicator(
                          // A pull counts even when it starts a little way down the list.
                          triggerMode: RefreshIndicatorTriggerMode.anywhere,
                          onRefresh: () => _load(pulled: true),
                          child: CustomScrollView(controller: _scroll, slivers: [...chapterList, bottomGap]),
                        )),
                      ),
                    ],
                  )
                else
                  fast(
                    RefreshIndicator(
                      // A pull counts even when it starts a little way down the list.
                      triggerMode: RefreshIndicatorTriggerMode.anywhere,
                      onRefresh: () => _load(pulled: true),
                      child: CustomScrollView(controller: _scroll, slivers: [...info, ...chapterList, bottomGap]),
                    ),
                    top: PinnedBar.height,
                  ),
                Positioned(
                  left: Gap.m,
                  right: Gap.m,
                  bottom: Gap.m + MediaQuery.viewPaddingOf(context).bottom,
                  child: AnimatedSwitcher(
                    duration: Motion.of(context, Motion.standard),
                    switchInCurve: Motion.out,
                    switchOutCurve: const Interval(0.5, 1),
                    transitionBuilder: fadeRise,
                    child: _picking ? _pickBar(context) : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// How this novel's downloads stand, with Pause or Resume, Cancel, and
  /// Retry for those that failed.
  Widget _downloadLine(BuildContext context, BookDownloads d) {
    final q = DownloadQueue.instance;
    final waiting = d.waiting > 0;
    final text = [
      if (waiting)
        q.paused
            ? 'Paused · ${d.waiting} to go'
            : 'Downloading · ${d.waiting} to go${d.current == null ? '' : ' · ${d.current}'}',
      if (d.failed > 0) '${d.failed} could not be downloaded${d.problem == null ? '' : ': ${d.problem}'}',
    ].join('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: waiting && !q.paused
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Icon(d.failed > 0 ? Icons.error_outline_rounded : Icons.pause_rounded,
                    size: 16, color: Skin.inkFaintOn(context)),
          ),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: Skin.label(context))),
          if (d.failed > 0)
            TextButton(onPressed: () => q.retry(_id), child: const Text('Retry'))
          else if (waiting)
            TextButton(
              onPressed: () => q.paused ? q.resume() : q.pause(),
              child: Text(q.paused ? 'Resume' : 'Pause'),
            ),
          IconButton(
            tooltip: 'Cancel downloads',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => q.cancel(_id),
          ),
        ],
      ),
    );
  }

  Widget _refusalNote(BuildContext context, ListRefusal r) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.info_outline_rounded, size: 18, color: Skin.inkFaintOn(context)),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.why, style: Skin.label(context, size: 13.5)),
                  if (r.offered)
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      onPressed: _useOffered,
                      child: const Text("Use the site's list"),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  /// What can be done with the picked chapters.
  Widget _pickBar(BuildContext context) {
    final toGet = _picked.where((i) => !_downloaded.contains(i)).length;
    final toDrop = _picked.length - toGet;
    final read = _picked.where(_isRead).length;
    final onDark = Skin.onDark(context);
    return Center(
      key: const ValueKey('picking'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: Skin.darkOn(context),
          elevation: 6,
          borderRadius: BorderRadius.circular(Radii.card + 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.s, Gap.xs),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Cancel',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded, color: onDark),
                  onPressed: () => setState(_picked.clear),
                ),
                Expanded(
                  child: Text(
                    '${_picked.length} selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.ui(size: 15, weight: FontWeight.w700, color: onDark),
                  ),
                ),
                IconButton(
                  tooltip: 'Select all',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.select_all_rounded, color: onDark),
                  onPressed: _picked.length == _chapters.length
                      ? null
                      : () => setState(() => _picked.addAll([for (var i = 0; i < _chapters.length; i++) i])),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: toDrop == 0 ? 'Remove download' : 'Remove $toDrop download${toDrop == 1 ? '' : 's'}',
                  icon: Icon(Icons.delete_outline_rounded, color: toDrop == 0 ? onDark.withValues(alpha: 0.3) : onDark),
                  onPressed: toDrop == 0 ? null : _removePicked,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Mark as read or unread',
                  position: PopupMenuPosition.over,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  icon: Icon(Icons.done_all_rounded, color: onDark),
                  onSelected: (how) => unawaited(_markPicked(how)),
                  itemBuilder: (_) => [
                    if (read < _picked.length) const PopupMenuItem(value: 'read', child: Text('Mark as read')),
                    if (read > 0) const PopupMenuItem(value: 'unread', child: Text('Mark as unread')),
                    // The chapters before the one picked, wherever they show.
                    if (_picked.length == 1 && _picked.first > 0)
                      PopupMenuItem(
                        value: 'earlier',
                        child: Text(_newestFirst ? 'Mark all below as read' : 'Mark all above as read'),
                      ),
                  ],
                ),
                const SizedBox(width: Gap.xs),
                // Its own width first (as a Flexible beside the Expanded count
                // it was squeezed to "Dow..."), with a cap so a large font
                // shortens the label instead of overflowing the bar.
                FilledButton.icon(
                  onPressed: toGet == 0 ? null : _downloadPicked,
                  icon: const Icon(Icons.download_rounded, size: 20),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 112),
                    child: Text(
                      toGet == 0 ? 'On the phone' : 'Download $toGet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
            if (_chapters.isNotEmpty) ...[
              RoundButton(icon: Icons.search_rounded, tooltip: 'Find a chapter', onTap: _findChapter),
              const SizedBox(width: Gap.s),
            ],
            PopupMenuButton<String>(
              tooltip: 'Novel options',
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                final e = _entry;
                switch (v) {
                  case 'browser':
                    await _openInBrowser();
                  case 'passage':
                    await _findPassage();
                  case 'download10':
                    await _download(10);
                  case 'download50':
                    await _download(50);
                  case 'downloadAll':
                    await _download(_chapters.length, from: 0);
                  case 'move':
                    if (e != null) await moveBook(context, _store, e);
                  case 'source':
                    await _moveSource();
                  case 'epub':
                    if (e != null) await exportNovelEpub(context, _store, e);
                  case 'cover':
                    if (e != null) await changeCover(context, _store, e);
                  case 'remove':
                    final nav = Navigator.of(context);
                    if (e != null && await removeBook(context, _store, e)) await nav.maybePop();
                }
              },
              itemBuilder: (_) => [
                if (_entry != null && _downloaded.isNotEmpty) ...[
                  const PopupMenuItem(value: 'passage', child: Text('Find a passage')),
                  const PopupMenuItem(value: 'epub', child: Text('Export as EPUB')),
                ],
                const PopupMenuItem(value: 'browser', child: Text('Open in browser')),
                const PopupMenuItem(value: 'download10', child: Text('Download next 10 chapters')),
                const PopupMenuItem(value: 'download50', child: Text('Download next 50 chapters')),
                if (_chapters.length > _downloaded.length)
                  PopupMenuItem(
                    value: 'downloadAll',
                    child: Text('Download all (${_chapters.length - _downloaded.length} to go)'),
                  ),
                if (_entry != null) ...[
                  const PopupMenuItem(value: 'move', child: Text('Move to…')),
                  const PopupMenuItem(value: 'source', child: Text('Move to another source')),
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
    return NetworkCover(
      url: url,
      title: _novel?.name ?? widget.name ?? '',
      width: 112,
      referer: widget.plugin.site,
      partition: widget.plugin.id,
    );
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
            icon: Icon(Icons.library_add_check_rounded, size: 20, color: Skin.accentOf(context)),
            label: const Text('In your library'),
          ),
      ],
    );
  }

  Widget _blurb(BuildContext context, String text) => GestureDetector(
        onTap: () => setState(() => _blurbOpen = !_blurbOpen),
        child: AnimatedSize(
          duration: Motion.of(context, const Duration(milliseconds: 200)),
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
                  style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context))),
            ],
          ),
        ),
      );

  Widget _chapterRow(BuildContext context, int i) {
    final c = _chapters[i];
    final isCurrent = i == _current;
    final read = _isRead(i);
    final have = _downloaded.contains(i);
    final release = _shortDate(c.releaseTime);
    final picked = _picked.contains(i);
    // Picking a row washes it in and out instead of switching its colour.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        end: picked
            ? Skin.accentOf(context).withValues(alpha: 0.26)
            : isCurrent
                ? Skin.accentOf(context).withValues(alpha: 0.14)
                : Skin.accentOf(context).withValues(alpha: 0),
      ),
      duration: Motion.of(context, Motion.quick),
      builder: (context, wash, child) => Material(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.row),
        child: child,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => _picking ? _toggle(i) : _read(chapter: i),
        onLongPress: () => _toggle(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: _swap(
                  context,
                  picked
                      ? Align(
                          key: const ValueKey('picked'),
                          alignment: Alignment.centerLeft,
                          child: Icon(Icons.check_circle_rounded, size: 22, color: Skin.accentOf(context)),
                        )
                      : Align(
                          key: const ValueKey('number'),
                          alignment: Alignment.centerLeft,
                          child: Text('${i + 1}',
                              style: Skin.meta(context, size: 11.5, color: isCurrent ? Skin.accentOf(context) : null)),
                        ),
                ),
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
                            ? Skin.accentOf(context)
                            : read
                                ? Skin.inkFaintOn(context)
                                : Skin.inkOn(context),
                      ),
                    ),
                    if (release != null) Text(release.toUpperCase(), style: Skin.meta(context, size: 9.5)),
                  ],
                ),
              ),
              if (isCurrent) Icon(Icons.graphic_eq_rounded, size: 18, color: Skin.accentOf(context)),
              SizedBox(
                width: 44,
                // Download, then the spinner, then the tick, each turning into the next.
                child: _swap(
                  context,
                  _queued.contains(c.path) && !have
                      ? const Center(
                          key: ValueKey('fetching'),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : have
                          ? Tooltip(
                              key: const ValueKey('have'),
                              message: 'On the phone',
                              child: Icon(Icons.offline_pin_rounded, size: 20, color: Skin.inkFaintOn(context)),
                            )
                          : IconButton(
                              key: const ValueKey('download'),
                              tooltip: 'Download chapter ${i + 1}',
                              icon: Icon(Icons.download_for_offline_outlined, size: 22, color: Skin.inkSoftOn(context)),
                              onPressed: () => _downloadOne(i),
                            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One small mark turning into another: a fade and a little growth.
  static Widget _swap(BuildContext context, Widget child) => AnimatedSwitcher(
        duration: Motion.of(context, Motion.quick),
        switchInCurve: Motion.out,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: child),
        ),
        child: child,
      );

  static String? _shortDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final d = DateTime.tryParse(raw);
    if (d == null) return raw.length > 24 ? null : raw;
    return relativeDay(d.toLocal());
  }
}

/// A cover from a web address, with the drawn cover while it loads or if it
/// cannot be fetched. Some sites only serve images to their own pages, so
/// the request names the site as its referrer, and goes with the source's
/// own cookies ([partition], its plugin id).
class NetworkCover extends StatelessWidget {
  const NetworkCover({
    super.key,
    required this.url,
    required this.title,
    required this.width,
    this.referer,
    this.partition = '',
    this.titled = true,
  });

  final String? url;
  final String title;
  final double width;
  final String? referer;
  final String partition;

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
    if (u == null || !Net.isWebAddress(u)) return fallback;
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
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          (width * dpr).round(),
          null,
          NetImage(u, referer: referer, partition: partition),
        ),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        // Fades in over the drawn cover as it arrives, instead of a swap.
        frameBuilder: fadeInOver(fallback),
      ),
    );
  }
}
