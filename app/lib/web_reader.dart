import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'browser_check.dart';
import 'library_store.dart';
import 'reader_screen.dart';
import 'sources/plugin_host.dart';
import 'sources/source_engine.dart';
import 'theme.dart';
import 'ui.dart';

/// How many chapters are fetched ahead of the one being read.
const _ahead = 3;

/// Fetch chapters [from] .. [from + count - 1] of web novel [id] that are not
/// on the phone yet. [onProgress] hears each one as it starts.
Future<void> fetchChapters(
  LibraryStore store,
  String id,
  int from, {
  int count = _ahead,
  void Function(int chapter)? onProgress,
}) async {
  final info = await store.webNovel(id);
  if (info == null) return;
  final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
  for (var i = from; i < from + count && i < info.chapters.length; i++) {
    if (i < 0 || store.hasChapter(id, i)) continue;
    if (plugin == null) {
      throw MissingSourceException(info.plugin.id, info.plugin.name);
    }
    onProgress?.call(i);
    final c = info.chapters[i];
    final html = await SourceEngine.instance.chapter(plugin, c.path);
    await store.saveChapter(id, i, c.name, html, language: languageCodeOf(info.plugin.lang));
  }
}

/// Reads a web novel: fetches the chapters it needs before showing them,
/// keeps a few ahead while you read or listen, and carries on into the next
/// chapters when it reaches the end of what has been fetched.
class WebNovelReader extends StatefulWidget {
  const WebNovelReader({
    super.key,
    required this.store,
    required this.entry,
    this.startChapter,
    this.autoplay = false,
  });

  final LibraryStore store;
  final LibraryEntry entry;

  /// Open at this chapter instead of the saved place.
  final int? startChapter;
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

  @override
  void initState() {
    super.initState();
    unawaited(_open(widget.startChapter, autoplay: widget.autoplay));
  }

  /// Make sure chapter [start] (or the saved place) and a few after it are
  /// here, then (re)build the book and show it there.
  Future<void> _open(int? start, {required bool autoplay}) async {
    setState(() {
      _error = null;
      _status = 'Opening…';
    });
    try {
      final info = await _store.webNovel(_id);
      _total = info?.chapters.length ?? 0;
      var cursor = await _store.cursorFor(_id);
      final from = start ?? cursor.sectionIndex;
      await fetchChapters(_store, _id, from, onProgress: (c) {
        if (mounted) setState(() => _status = 'Fetching chapter ${c + 1}…');
      });
      final layout = await _store.loadLayout(_id);
      if (start != null && !layout.isEmpty) {
        final unit = layout.units.indexWhere((u) => u.sectionIndex == start);
        if (unit >= 0) cursor = cursorOf(layout.units[unit]);
      }
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _cursor = cursor;
        _autoplay = autoplay;
        _generation++;
        _status = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
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
  Future<void> _onEnd({required bool playing}) async {
    final layout = _layout;
    if (layout == null || layout.isEmpty) return;
    final current = layout.units.last.sectionIndex;
    final next = current + 1;
    if (next >= _total && !await _refreshChapters()) {
      if (mounted) showSnack(context, 'That is the latest chapter so far. New ones appear when the site adds them.');
      return;
    }
    await _open(next, autoplay: playing);
  }

  /// Ask the source for the chapter list again. True if it grew.
  Future<bool> _refreshChapters() async {
    try {
      final info = await _store.webNovel(_id);
      if (info == null) return false;
      final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
      if (plugin == null) return false;
      if (mounted) showSnack(context, 'Checking for new chapters…');
      final fresh = await SourceEngine.instance.novel(plugin, info.novel.path);
      if (fresh.chapters.length <= info.chapters.length) return false;
      await _store.saveWebChapters(_id, fresh.chapters);
      _total = fresh.chapters.length;
      return true;
    } on Object {
      return false;
    }
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
    if (layout != null && _status == null && _error == null) {
      return ReaderScreen(
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
        endLabel: layout.isEmpty || layout.units.last.sectionIndex + 1 >= _total ? 'Check for new chapters' : 'Next chapter',
      );
    }
    return Scaffold(
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
                          onRetry: () => _open(widget.startChapter, autoplay: widget.autoplay),
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
}
