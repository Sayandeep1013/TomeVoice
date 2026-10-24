import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_actions.dart';
import 'book_card.dart';
import 'book_search.dart';
import 'book_tint.dart';
import 'chapter_finder.dart';
import 'library_store.dart';
import 'saved_screen.dart';
import 'listen_sheet.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

/// A book's own page, the way NovelDokusha shows a novel: cover and facts,
/// its category and voice, Play to continue where you stopped, and every
/// chapter, any of which opens the reader right there.
class BookScreen extends StatefulWidget {
  const BookScreen({super.key, required this.store, required this.entry});

  final LibraryStore store;
  final LibraryEntry entry;

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  late LibraryEntry _entry = widget.entry;
  LibraryIndex? _index;
  ReadingLayout? _layout;
  ReadingCursor _cursor = ReadingCursor.zero;
  Object? _error;
  bool _blurbOpen = false;
  final _catalog = VoiceCatalog.instance;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;
  LibraryStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_refreshEntry);
    _catalog.addListener(_rebuild);
    ListeningPrefs.revision.addListener(_rebuild);
    unawaited(_catalog.ensureLoaded());
    unawaited(_load());
  }

  @override
  void dispose() {
    _store.changes.removeListener(_refreshEntry);
    _catalog.removeListener(_rebuild);
    ListeningPrefs.revision.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      // The place is read after the layout: loading may re-parse the book and
      // carry the saved place over to the new structure first.
      final layout = await _store.loadLayout(_entry.id);
      final cursor = await _store.cursorFor(_entry.id);
      final idx = await _store.index();
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _cursor = cursor;
        _index = idx;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _refreshEntry() async {
    final idx = await _store.index();
    final fresh = idx.entries.where((e) => e.id == _entry.id).firstOrNull;
    final cursor = await _store.cursorFor(_entry.id);
    if (!mounted) return;
    if (fresh == null) {
      // Removed from the library.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _entry = fresh;
      _index = idx;
      _cursor = cursor;
    });
  }

  String get _language {
    final t = (_layout?.book.metadata.language ?? _entry.language ?? 'en').toLowerCase();
    final p = t.split(RegExp('[-_]')).first;
    return p.length >= 2 ? p : 'en';
  }

  int get _currentChapter {
    final l = _layout;
    if (l == null || l.isEmpty) return 0;
    return l.chapterOfUnit(l.unitForCursor(_cursor));
  }

  /// Set while a book is being opened: a second tap does nothing.
  bool _opening = false;

  Future<void> _read({required bool play, int? chapter, int? unit}) async {
    final l = _layout;
    if (l == null || _opening) return;
    _opening = true;
    try {
      await _open(l, play: play, chapter: chapter, unit: unit);
    } finally {
      _opening = false;
    }
  }

  Future<void> _open(ReadingLayout l, {required bool play, int? chapter, int? unit}) async {
    final cursor = l.isEmpty
        ? await _store.cursorFor(_entry.id)
        : unit != null
            ? cursorOf(l.units[unit.clamp(0, l.units.length - 1)])
            : chapter != null
                ? cursorOf(l.units[l.chapterFirstUnit[chapter]])
                : await _store.cursorFor(_entry.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: _entry.id,
        cover: _entry.shownCover,
        child: ReaderScreen(
          layout: l,
          store: _store,
          initialCursor: cursor,
          autoplay: play,
          bookDir: _store.bookDir(_entry.id),
          sourcePath: _entry.sourcePath,
        ),
      ),
    ));
    await _refreshEntry();
  }

  ListenController get _listen => ListenController(
        prefs: _prefs,
        language: _language,
        bookId: _entry.id,
        onChanged: ({required bool restart}) => _rebuild(),
        onPreview: _preview,
      );

  Future<void> _preview(String voiceName) async {
    final l = _layout;
    var text = 'This is how I will sound reading ${_entry.title}.';
    if (l != null && !l.isEmpty) {
      final u = l.unitForCursor(_cursor);
      final first = l.units[u].text;
      if (first.length >= 30) text = first.length > 200 ? '${first.substring(0, 200)}…' : first;
    }
    try {
      await speakSample(
        voiceName: voiceName,
        text: text,
        settings: _prefs.settings,
        engineId: _prefs.engineId ?? _catalog.engineId,
      );
    } on Object catch (e) {
      debugPrint('Voice sample failed: $e');
      if (mounted) showSnack(context, 'That voice could not play a sample. Try another.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _layout;
    final e = _entry;
    final idx = _index;
    final category =
        idx?.categories.where((c) => c.id == e.categoryIn(idx.categories, idx.defaultCategory)).firstOrNull;
    final chapters = l == null ? const <int>[] : [for (var c = 0; c < l.chapters.length; c++) c];
    final list = l == null
        ? null
        : ChapterList(
            layout: l,
            chapters: chapters,
            current: e.progress > 0 ? _currentChapter : -1,
            onPick: (c) => _read(play: false, chapter: c),
          );
    final size = MediaQuery.sizeOf(context);
    final wide = size.width > size.height && size.width >= 720;
    final bottomGap = SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + MediaQuery.viewPaddingOf(context).bottom));
    final info = <Widget>[
      PinnedBar(child: _topBar(context)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: _hero(context, category)),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: _actions(context)),
      ),
      if (l?.book.metadata.description != null)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
          sliver: SliverToBoxAdapter(child: _blurb(context, l!.book.metadata.description!)),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: _voice(context)),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: BookSavedSection(store: _store, entry: _entry)),
      ),
    ];
    final chapterList = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xxl, Gap.page, Gap.s),
        sliver: SliverToBoxAdapter(
          child: SectionTitle(
            'Chapters',
            note: l == null ? null : '${l.chapters.length} ${l.chapters.length == 1 ? 'chapter' : 'chapters'}',
          ),
        ),
      ),
      if (_error != null)
        SliverPadding(
          padding: const EdgeInsets.all(Gap.page),
          sliver: SliverToBoxAdapter(
            child: Text('$_error', style: Skin.label(context, size: 14)),
          ),
        )
      else if (list == null)
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
            itemExtent: 56,
            delegate: SliverChildBuilderDelegate(
              childCount: chapters.length,
              (context, i) => list.chapterRow(context, chapters[i]),
            ),
          ),
        ),
    ];
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          // Landscape on a phone: details beside the chapters, each scrolling
          // on its own, instead of one long column of which little shows.
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 420,
                      child: CustomScrollView(slivers: [...info, bottomGap]),
                    ),
                    Expanded(child: CustomScrollView(slivers: [...chapterList, bottomGap])),
                  ],
                )
              : CustomScrollView(slivers: [...info, ...chapterList, bottomGap]),
        ),
      ),
    );
  }

  /// Find a chapter by its number or words from its title, and read it.
  Future<void> _findChapter() async {
    final l = _layout;
    if (l == null || l.isEmpty) return;
    final picked = await showChapterFinder(
      context,
      titles: [for (var c = 0; c < l.chapters.length; c++) l.chapterTitle(c)],
      current: _currentChapter,
      heading: 'Find a chapter',
      autofocus: true,
    );
    if (picked != null && mounted) await _read(play: false, chapter: picked);
  }

  /// Find a line or a quote remembered, anywhere in the book, and read from it.
  Future<void> _findPassage() async {
    final l = _layout;
    if (l == null || l.isEmpty) return;
    await showBookSearch(
      context,
      layout: l,
      chapter: 0,
      wholeBook: true,
      onPick: (hits, i, _) => _read(play: false, unit: hits[i].unit),
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
            if (_layout?.isEmpty == false) ...[
              RoundButton(icon: Icons.search_rounded, tooltip: 'Find a chapter', onTap: _findChapter),
              const SizedBox(width: Gap.s),
            ],
            PopupMenuButton<String>(
              tooltip: 'Book options',
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                switch (v) {
                  case 'passage':
                    await _findPassage();
                  case 'cover':
                    await changeCover(context, _store, _entry);
                  case 'move':
                    await moveBook(context, _store, _entry);
                  case 'restart':
                    await _store.saveCursor(_entry.id, ReadingCursor.zero, 0);
                    await _refreshEntry();
                  case 'remove':
                    final nav = Navigator.of(context);
                    if (await removeBook(context, _store, _entry)) await nav.maybePop();
                }
              },
              itemBuilder: (_) => [
                if (_layout?.isEmpty == false) const PopupMenuItem(value: 'passage', child: Text('Find a passage')),
                const PopupMenuItem(value: 'cover', child: Text('Change cover')),
                const PopupMenuItem(value: 'move', child: Text('Move to…')),
                if (_entry.progress > 0)
                  const PopupMenuItem(value: 'restart', child: Text('Start from the beginning')),
                const PopupMenuItem(value: 'remove', child: Text('Remove from library')),
              ],
              child: const IgnorePointer(child: RoundButton(icon: Icons.more_vert_rounded)),
            ),
          ],
        ),
      );

  Widget _hero(BuildContext context, Category? category) {
    final e = _entry;
    final facts = [
      e.formatLabel,
      if (e.language != null) languageName(e.language!),
      if (e.wordCount > 0) listenLength(e.wordCount),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => changeCover(context, _store, _entry),
          child: CoverHero(entry: e, child: BookCover(entry: e, width: 112)),
        ),
        const SizedBox(width: Gap.l),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.title(context, size: 25, weight: FontWeight.w500).copyWith(height: 1.12)),
              if (e.authorLine.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(e.authorLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.label(context, size: 15)),
              ],
              const SizedBox(height: Gap.m),
              Wrap(spacing: 5, runSpacing: 5, children: [for (final f in facts) TagChip(f)]),
              if (category != null) ...[
                const SizedBox(height: Gap.m),
                InkWell(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  onTap: () => moveBook(context, _store, _entry),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_outlined, size: 18, color: Skin.inkSoftOn(context)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(category.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.inkSoftOn(context))),
                        ),
                        Icon(Icons.arrow_drop_down_rounded, color: Skin.inkSoftOn(context)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final e = _entry;
    final started = e.progress > 0 && !e.finished;
    final left = e.wordCount > 0 ? listenLength((e.wordCount * (1 - e.progress)).round()) : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (e.progress > 0) ...[
          Progress(e.progress, height: 4),
          const SizedBox(height: 6),
          Text(
            [progressLine(e), if (left.isNotEmpty && !e.finished) '$left left'].join(' · ').toUpperCase(),
            style: Skin.meta(context, size: 10.5),
          ),
          const SizedBox(height: Gap.l),
        ],
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: _layout == null ? null : () => _read(play: true),
                icon: const Icon(Icons.play_arrow_rounded, size: 26),
                label: Text(started ? 'Continue' : (e.finished ? 'Listen again' : 'Listen')),
              ),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: _layout == null ? null : () => _read(play: false),
                icon: const Icon(Icons.menu_book_rounded, size: 20),
                label: const Text('Read'),
              ),
            ),
          ],
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
                style: Skin.page(context, size: 16, font: _prefs.bookFont, height: 1.5)
                    .copyWith(color: Skin.inkSoftOn(context)),
              ),
              const SizedBox(height: Gap.xs),
              Text(_blurbOpen ? 'Less' : 'More',
                  style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context))),
            ],
          ),
        ),
      );

  Widget _voice(BuildContext context) {
    final controller = _listen;
    final v = _catalog.byName(controller.voiceName);
    final speed = trimSpeed(_prefs.settings.speedScale);
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: BorderRadius.circular(Radii.row + 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row + 4),
        onTap: () => showVoicePicker(context, controller),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded, color: Skin.accentOf(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Eyebrow('Voice for this book'),
                    const SizedBox(height: 2),
                    Text(
                      !_catalog.loaded
                          ? 'Loading voices…'
                          : v == null
                              ? 'No ${languageName(_language)} voice yet'
                              : '${v.languageLabel} · ${_catalog.friendlyName(v)} · $speed×',
                      style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context)),
                    ),
                  ],
                ),
              ),
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentSoftOf(context))),
            ],
          ),
        ),
      ),
    );
  }
}
