import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'browser_check.dart';
import 'chapter_finder.dart';
import 'library_store.dart';
import 'listening_session.dart';
import 'reader_screen.dart';
import 'reading_rules.dart';
import 'sources/plugin_host.dart';
import 'sources/source_engine.dart';
import 'theme.dart';
import 'ui.dart';

/// How many chapters are fetched ahead of the one being read.
const _ahead = 3;

/// Fetch chapters [from] .. [from + count - 1] of web novel [id] that are not
/// on the phone yet. [onProgress] hears each one as it starts; [stop], asked
/// before each, ends the run early.
Future<void> fetchChapters(
  LibraryStore store,
  String id,
  int from, {
  int count = _ahead,
  void Function(int chapter)? onProgress,
  bool Function()? stop,
}) async {
  final info = await store.webNovel(id);
  if (info == null) return;
  final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
  for (var i = from; i < from + count && i < info.chapters.length; i++) {
    if (i < 0 || store.hasChapter(id, i)) continue;
    if (stop?.call() ?? false) return;
    if (plugin == null) {
      throw MissingSourceException(info.plugin.id, info.plugin.name);
    }
    onProgress?.call(i);
    final c = info.chapters[i];
    final html = await SourceEngine.instance.chapter(plugin, c.path);
    await store.saveChapter(id, i, c.name, html, language: languageCodeOf(info.plugin.lang));
  }
}

/// Ask the source for web novel [id]'s chapter list again. If it grew, the
/// chapter after [current] (which may have moved in the new list); else null.
/// A list that looks wrong is not stored (see LibraryStore.offerWebChapters):
/// [onRefused] hears why.
Future<int?> refreshWebChapters(
  LibraryStore store,
  String id,
  int current, {
  void Function(String why)? onRefused,
}) async {
  try {
    final info = await store.webNovel(id);
    if (info == null) return null;
    final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
    if (plugin == null) return null;
    final fresh = await SourceEngine.instance.novel(plugin, info.novel.path);
    final verdict = await store.offerWebChapters(id, fresh.chapters, complete: fresh.complete);
    if (!verdict.taken) {
      if (verdict.refused && verdict.why != null) onRefused?.call(verdict.why!);
      return null;
    }
    final path = info.chapters.elementAtOrNull(current)?.path;
    final now = fresh.chapters.indexWhere((c) => c.path == path);
    final after = (now < 0 ? current : now) + 1;
    return after < fresh.chapters.length ? after : null;
  } on Object {
    return null;
  }
}

/// Reads a web novel: fetches the chapters it needs before showing them,
/// keeps a few ahead while you read or listen, and carries on into the next
/// chapters when it reaches the end of what has been fetched.
///
/// Read aloud, that carrying on is the background reading's (see
/// BackgroundReading.readOn): it needs no frame, so it goes on with the
/// screen off, and this page follows it to the chapter it reads.
class WebNovelReader extends StatefulWidget {
  const WebNovelReader({
    super.key,
    required this.store,
    required this.entry,
    this.startChapter,
    this.at,
    this.autoplay = false,
  });

  final LibraryStore store;
  final LibraryEntry entry;

  /// Open at this chapter instead of the saved place.
  final int? startChapter;

  /// Open at this sentence (a passage found in the text) instead.
  final ReadingCursor? at;
  final bool autoplay;

  @override
  State<WebNovelReader> createState() => _WebNovelReaderState();
}

class _WebNovelReaderState extends State<WebNovelReader> {
  LibraryStore get _store => widget.store;
  String get _id => widget.entry.id;

  ReadingLayout? _layout;
  ReadingCursor _cursor = ReadingCursor.zero;
  bool _autoplay = false;
  int _generation = 0;
  int _total = 0;
  String? _status;
  Object? _error;
  bool _prefetching = false;

  /// The chapter (section) to show on opening when the reader looked ahead
  /// past the fetched chapters; null opens at the place being read.
  int? _view;

  late List<SkipRule> _skip = ReadingRules.instance.skip;

  @override
  void initState() {
    super.initState();
    ReadingRules.instance.changes.addListener(_onRules);
    // Read aloud in the background: the page opens on the chapters the voice
    // reads, and so takes the voice back with no break (on a window of its
    // own, the voice was started again from its place).
    final bg = BackgroundReading.current.value;
    if (widget.at == null &&
        widget.startChapter == null &&
        bg != null &&
        bg.bookId == _id &&
        bg.rolling == null &&
        !bg.layout.isEmpty) {
      final layout = bg.layout;
      _layout = layout;
      _cursor = cursorOf(layout.units[bg.unit.clamp(0, layout.units.length - 1)]);
      // Every chapter the novel lists has its section.
      _total = layout.book.sections.length;
      return;
    }
    unawaited(_open(widget.at?.sectionIndex ?? widget.startChapter, autoplay: widget.autoplay, at: widget.at));
  }

  @override
  void dispose() {
    ReadingRules.instance.changes.removeListener(_onRules);
    _following?.layouts.removeListener(_onFollowed);
    super.dispose();
  }

  /// The reading this page's voice was handed to at the end of its
  /// chapters, while it carries on into more of them.
  BackgroundReading? _following;

  /// Show the chapters [bg] reads aloud, and keep up as it reads on into
  /// more: the page built for them takes its voice back (with the screen off
  /// that page waits for the screen; the voice does not).
  void _follow(BackgroundReading bg) {
    _following?.layouts.removeListener(_onFollowed);
    _following = bg;
    bg.layouts.addListener(_onFollowed);
    _onFollowed();
  }

  void _onFollowed() {
    final bg = _following;
    if (bg == null || !mounted) return;
    if (!identical(BackgroundReading.current.value, bg)) {
      // Taken back by the page, or stopped: nothing more to follow.
      bg.layouts.removeListener(_onFollowed);
      _following = null;
      return;
    }
    // Still moving into those chapters: the page for them is built once it
    // reads there, so the page can take the voice back.
    final rolling = bg.rolling;
    if (rolling != null) {
      unawaited(rolling.whenComplete(_onFollowed));
      return;
    }
    final layout = bg.layout;
    if (identical(layout, _layout) || layout.isEmpty) return;
    setState(() {
      _layout = layout;
      _cursor = cursorOf(layout.units[bg.unit.clamp(0, layout.units.length - 1)]);
      _autoplay = false;
      _view = null;
      _generation++;
      _status = null;
      _error = null;
    });
    unawaited(_store.webNovel(_id).then((info) {
      if (info != null && mounted) setState(() => _total = info.chapters.length);
    }));
  }

  /// A line rule was added or removed: rebuild the chapters at the saved
  /// place (the reader saves it as it goes), so the change shows at once.
  void _onRules() {
    final skip = ReadingRules.instance.skip;
    if (identical(skip, _skip)) return;
    _skip = skip;
    Future<void>.delayed(const Duration(milliseconds: 1700), () {
      if (mounted) unawaited(_open(null, autoplay: false));
    });
  }

  /// Make sure chapter [start] (or the saved place) and a few after it are
  /// here, then (re)build the book and show it there.
  /// With [keepPlace], [start] is only shown: the place being read stays.
  /// [at], a sentence in [start], opens there rather than at its start.
  Future<void> _open(int? start, {required bool autoplay, bool keepPlace = false, ReadingCursor? at}) async {
    setState(() => _error = null);
    // The page being read stays until the next is ready: chapters already
    // on the phone open in a moment, and a wait screen flashed between.
    // Only a slow open (one fetched from the site) says what it is doing.
    final slow = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _status ??= 'Opening…');
    });
    try {
      final info = await _store.settleWebChapters(_id);
      _total = info?.chapters.length ?? 0;
      var cursor = await _store.cursorFor(_id);
      final from = start ?? cursor.sectionIndex;
      await fetchChapters(_store, _id, from, onProgress: (c) {
        if (mounted) setState(() => _status = 'Fetching chapter ${c + 1}…');
      });
      // A window of chapters round the place, not every one on the phone
      // (see LibraryStore.webWindow): its end opens the next.
      final layout = await _store.loadLayout(_id, around: at?.sectionIndex ?? from);
      if (at != null) {
        cursor = at;
      } else if (start != null && !keepPlace && !layout.isEmpty) {
        final unit = layout.units.indexWhere((u) => u.sectionIndex == start);
        if (unit >= 0) cursor = cursorOf(layout.units[unit]);
      }
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _cursor = cursor;
        _autoplay = autoplay;
        _view = keepPlace ? start : null;
        _generation++;
        _status = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      slow.cancel();
    }
  }

  /// The highest chapter number with text, in a row from [from].
  int _lastLoaded(int from) {
    var c = from;
    while (c + 1 < _total && _store.hasChapter(_id, c + 1)) {
      c++;
    }
    return c;
  }

  /// Reading moved to [chapter]: fetch ahead quietly, so the next chapters
  /// are ready before they are needed.
  void _onChapter(int chapter) {
    if (_prefetching) return;
    final last = _lastLoaded(chapter);
    if (last - chapter >= 1 || last + 1 >= _total) return;
    _prefetching = true;
    unawaited(fetchChapters(_store, _id, last + 1).catchError((Object _) {}).whenComplete(() => _prefetching = false));
  }

  /// The end of the fetched chapters: get the next ones and carry on.
  Future<void> _onEnd({required bool playing, bool browse = false}) async {
    final layout = _layout;
    if (layout == null || layout.isEmpty) return;
    // Read aloud past them: the page handed its voice on (ReaderScreen's
    // _readOn), which fetches and reads on without waiting for a frame.
    // This page shows where it reads once it does.
    final bg = BackgroundReading.current.value;
    if (playing && bg != null && bg.bookId == _id) {
      final carried = await (bg.rolling ?? Future<bool?>.value(true));
      if (!mounted) return;
      if (carried == true) {
        _follow(bg);
      } else if (carried == false) {
        showSnack(context, 'That is the latest chapter so far. New ones appear when the site adds them.');
      }
      return;
    }
    final current = layout.units.last.sectionIndex;
    var next = current + 1;
    if (next >= _total) {
      final (after, refused) = await _refreshChapters(current);
      if (after == null) {
        if (mounted) {
          showSnack(context, refused ?? 'That is the latest chapter so far. New ones appear when the site adds them.',
              long: refused != null);
        }
        return;
      }
      next = after;
    }
    // Not on the phone, and the site cannot give it now (offline): on to
    // the next chapter that is on the phone, as reading did before it was
    // opened a window at a time, rather than stopping there.
    if (!_store.hasChapter(_id, next)) {
      try {
        await fetchChapters(_store, _id, next, count: 1);
      } on Object catch (e) {
        final later = [for (final c in _store.downloadedChapters(_id)) if (c > next) c];
        if (later.isEmpty) {
          if (mounted) setState(() => _error = e);
          return;
        }
        final to = later.reduce((a, b) => a < b ? a : b);
        if (mounted) {
          showSnack(context, 'Chapter ${next + 1} could not be fetched, so on to chapter ${to + 1}, which is on the phone.');
        }
        next = to;
      }
    }
    await _open(next, autoplay: playing, keepPlace: browse);
  }

  /// Ask the source for the chapter list again. If it grew, the chapter
  /// after [current] (which may have moved in the new list); else null, and
  /// why the site's list was not taken, if it was not.
  Future<(int?, String?)> _refreshChapters(int current) async {
    if (mounted) showSnack(context, 'Checking for new chapters…');
    String? refused;
    final after = await refreshWebChapters(_store, _id, current, onRefused: (why) => refused = why);
    _total = (await _store.webNovel(_id))?.chapters.length ?? _total;
    return (after, refused);
  }

  /// Every chapter the site lists, not only those on the phone: the one
  /// picked is fetched if need be and read from its start (aloud, if
  /// [playing]).
  Future<void> _contents(BuildContext readerContext, {required int section, required bool playing}) async {
    final info = await _store.webNovel(_id);
    if (info == null || !readerContext.mounted) return;
    final picked = await showChapterFinder(
      readerContext,
      titles: [for (final c in info.chapters) c.name],
      onPhone: _store.downloadedChapters(_id),
      current: section,
    );
    if (picked != null && mounted) await _open(picked, autoplay: playing);
  }

  double _progress(int u) {
    final l = _layout;
    if (l == null || l.isEmpty || _total == 0) return 0;
    final chapter = l.units[u].sectionIndex;
    final (first, count) = l.chapterRange(l.chapterOfUnit(u));
    final within = count <= 1 ? 0.0 : (u - first) / count;
    return ((chapter + within) / _total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    final reading = layout != null && _status == null && _error == null;
    // Each reader (or the wait for one) fades in over the same ground. The
    // old one goes at once: kept for a cross-fade, its player stopping would
    // silence the new one, already reading.
    return DecoratedBox(
      decoration: BoxDecoration(gradient: Skin.ground(context)),
      child: FadeIn(key: ValueKey(reading ? _generation : -1), child: reading ? _reader(layout) : _wait(context)),
    );
  }

  Widget _reader(ReadingLayout layout) => ReaderScreen(
        key: ValueKey(_generation),
        layout: layout,
        store: _store,
        initialCursor: _cursor,
        autoplay: _autoplay,
        bookDir: _store.bookDir(_id),
        onReachedEnd: _onEnd,
        onChapterChanged: _onChapter,
        progressOf: _progress,
        positionOf: (u) => '${layout.units[u].sectionIndex + 1}/$_total',
        chapterNumberOf: (c) => layout.chapters[c] + 1,
        viewSection: _view,
        openContents: _contents,
        endLabel: layout.isEmpty || layout.units.last.sectionIndex + 1 >= _total ? 'Check for new chapters' : 'Next chapter',
      );

  Widget _wait(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: widget.entry.title, onBack: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: Center(
                    child: _error != null
                        ? SourceProblem(
                            error: _error!,
                            title: 'Could not open this chapter',
                            pluginId: widget.entry.plugin,
                            onRetry: () => _open(widget.at?.sectionIndex ?? widget.startChapter, autoplay: widget.autoplay, at: widget.at),
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: Gap.l),
                              Text(_status ?? '', style: Skin.label(context, size: 15)),
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
