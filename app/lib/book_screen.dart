import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_actions.dart';
import 'book_card.dart';
import 'book_replace.dart';
import 'book_search.dart';
import 'book_tint.dart';
import 'cast.dart';
import 'cast_sheet.dart';
import 'chapter_finder.dart';
import 'export_audio_sheet.dart';
import 'fast_scroller.dart';
import 'journal.dart' show JournalStamp;
import 'journal_page.dart';
import 'journal_screen.dart';
import 'library_store.dart';
import 'novel_move.dart' show chapterNumberOf;
import 'listening_session.dart' show BackgroundReading;
import 'novel_screen.dart';
import 'organise.dart' show seriesLine;
import 'organise_sheets.dart';
import 'saved_screen.dart';
import 'listen_sheet.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'relayout.dart';
import 'rules_screen.dart';
import 'speakers.dart' show Character;
import 'speech_service.dart';
import 'text_chapters_sheet.dart';
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

class _BookScreenState extends State<BookScreen> with WhenShown<BookScreen> {
  late LibraryEntry _entry = widget.entry;

  /// Its file is being replaced (Replace the file): the book going from
  /// the library is not this page closing.
  bool _replacing = false;
  LibraryIndex? _index;
  ReadingLayout? _layout;
  ReadingCursor _cursor = ReadingCursor.zero;
  Object? _error;
  bool _blurbOpen = false;

  /// Who the book's speech tags name, once found (none for a book with no
  /// dialogue, or not in English).
  List<Character> _people = const [];

  /// The list holding the chapters, for the fast scroller beside them.
  final _scroll = ScrollController();
  final _catalog = VoiceCatalog.instance;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;
  LibraryStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_refreshEntry);
    _store.placeChanges.addListener(_placeSaved);
    _catalog.addListener(_rebuild);
    ListeningPrefs.revision.addListener(_rebuild);
    unawaited(_catalog.ensureLoaded());
    unawaited(_load());
  }

  @override
  void dispose() {
    _store.changes.removeListener(_refreshEntry);
    _store.placeChanges.removeListener(_placeSaved);
    _catalog.removeListener(_rebuild);
    ListeningPrefs.revision.removeListener(_rebuild);
    _scroll.dispose();
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
      // The chapters and the description open in once the page is in place,
      // not in the frames of its arrival.
      await arrived();
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _cursor = cursor;
        _index = idx;
      });
      // Who speaks in it, found off the screen's isolate: the Characters
      // entry appears when anyone does.
      final people = await bookCharacters(_entry.id, layout);
      if (mounted && people.isNotEmpty) setState(() => _people = people);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// A place saved, most often by the reader opened from here, which covers
  /// this page: it catches up when it shows again.
  void _placeSaved() => whenShown(_refreshEntry);

  /// Where the story is, for the journal: the voice's sentence when it
  /// reads this book in the background, else the place.
  JournalStamp _stampNow() {
    final bg = BackgroundReading.current.value;
    if (bg != null && bg.bookId == _entry.id) {
      return stampAt(bg.layout, bg.unit,
          numberOf: (c) => chapterNumberOf(bg.layout.chapterTitle(c))?.floor() ?? c + 1);
    }
    final l = _layout;
    if (l == null || l.isEmpty) return const JournalStamp(at: ReadingCursor.zero, chapter: 0);
    return stampAt(l, l.unitForCursor(_cursor, saved: true));
  }

  Future<void> _refreshEntry() async {
    final idx = await _store.index();
    final fresh = idx.entries.where((e) => e.id == _entry.id).firstOrNull;
    final cursor = await _store.cursorFor(_entry.id);
    if (!mounted) return;
    if (fresh == null) {
      // Its file being replaced: the new book's page takes this one's place
      // (see 'replace'). Popped here, the page under it was replaced
      // instead, and the library was gone from under the reader.
      if (_replacing) return;
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
    return l.chapterOfUnit(l.unitForCursor(_cursor, saved: true));
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
    final cursor = await _store.cursorFor(_entry.id);
    // A chapter or a sentence picked is looked at; the place stays (see
    // ReaderScreen.lookAt). Play on it reads from there.
    final look = l.isEmpty
        ? null
        : unit != null
            ? cursorOf(l.units[unit.clamp(0, l.units.length - 1)])
            : chapter != null
                ? cursorOf(l.units[l.chapterFirstUnit[chapter]])
                : null;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: _entry.id,
        cover: _entry.shownCover,
        child: ReaderScreen(
          layout: l,
          store: _store,
          initialCursor: cursor,
          lookAt: look,
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
        bookTitle: _entry.title,
        onChanged: ({required bool restart}) => _rebuild(),
        onPreview: _preview,
        narration: _layout?.book.narration != null,
      );

  Future<void> _preview(String voiceName) async {
    final l = _layout;
    var text = 'This is how I will sound reading ${_entry.title}.';
    if (l != null && !l.isEmpty) {
      final u = l.unitForCursor(_cursor, saved: true);
      final first = l.units[u].text;
      if (first.length >= 30) text = first.length > 200 ? '${first.substring(0, 200)}…' : first;
    }
    try {
      await speakSample(
        voiceName: voiceName,
        text: text,
        settings: _prefs.settingsFor(voiceName),
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
    Widget fast(Widget list, {double top = 0}) => FastScroller(
          controller: _scroll,
          top: top,
          bottom: Gap.m + MediaQuery.viewPaddingOf(context).bottom,
          labelAt: (f) => l == null || chapters.isEmpty
              ? null
              : l.chapterTitle(chapters[(f * (chapters.length - 1)).round()]),
          child: list,
        );
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
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: growIn(
            context,
            l?.book.metadata.description == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: Gap.xl),
                    child: _blurb(context, l!.book.metadata.description!),
                  ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _voice(context),
              growIn(
                context,
                _people.isEmpty
                    ? null
                    : Padding(padding: const EdgeInsets.only(top: Gap.s), child: _characters(context)),
              ),
              // A TXT file's chapters are only what TomeVoice could find in
              // it: its reader can say where they start.
              if (e.source == SourceKind.text)
                Padding(padding: const EdgeInsets.only(top: Gap.s), child: _textChapters(context)),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(child: BookSavedSection(store: _store, entry: _entry)),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xl, Gap.page, 0),
        sliver: SliverToBoxAdapter(
          child: BookJournalSection(
            bookId: _entry.id,
            bookTitle: _entry.title,
            stampNow: _stampNow,
            onSeeAll: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => JournalScreen(store: _store, bookId: _entry.id)),
            ),
          ),
        ),
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
        SliverFadeIn(
          sliver: SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
            sliver: SliverFixedExtentList(
              itemExtent: 56,
              delegate: SliverChildBuilderDelegate(
                childCount: chapters.length,
                (context, i) => list.chapterRow(context, chapters[i]),
              ),
            ),
          ),
        ),
    ];
    return shownGate(Scaffold(
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
                    Expanded(child: fast(CustomScrollView(controller: _scroll, slivers: [...chapterList, bottomGap]))),
                  ],
                )
              : fast(CustomScrollView(controller: _scroll, slivers: [...info, ...chapterList, bottomGap]),
                  top: PinnedBar.height),
        ),
      ),
    ));
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
                  case 'audio':
                    final l = _layout;
                    if (l == null) break;
                    await showSaveAsAudio(
                      context,
                      layout: l,
                      bookId: _entry.id,
                      title: _entry.title,
                      author: _entry.authorLine,
                      cover: _entry.shownCover,
                      chapter: _currentChapter,
                      preferBook: true,
                      secret: _store.isSecret(_entry.id),
                    );
                  case 'rules':
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RulesScreen(
                        bookTitles: {for (final e in _index?.entries ?? const <LibraryEntry>[]) e.id: e.title},
                        bookId: _entry.id,
                        bookTitle: _entry.title,
                      ),
                    ));
                  case 'journal':
                    await openJournal(context, bookId: _entry.id, bookTitle: _entry.title, stampNow: _stampNow);
                  case 'cover':
                    await changeCover(context, _store, _entry);
                  case 'replace':
                    final nav = Navigator.of(context);
                    _replacing = true;
                    LibraryEntry? fresh;
                    try {
                      fresh = await askReplaceBookFile(context, _store, _entry);
                    } finally {
                      // Replaced, this page is going: it stays out of the way
                      // until it has (a check of the library still under way
                      // must not pop the new book's page).
                      if (fresh == null) _replacing = false;
                    }
                    // The book is another now: its page, in this one's place.
                    if (fresh != null && mounted) {
                      unawaited(nav.pushReplacement(MaterialPageRoute<void>(
                        builder: (_) => BookScreen(store: _store, entry: fresh!),
                      )));
                    }
                  case 'move':
                    await moveBook(context, _store, _entry);
                  case 'organise':
                    await editTagsAndSeries(context, _store, _entry);
                  case 'restart':
                    // One tap from the menu: the place it had is one tap away.
                    final was = _entry;
                    // The book's own place file, which a re-read book's place
                    // reaches first.
                    final place = await _store.cursorFor(was.id);
                    await _store.saveCursor(_entry.id, ReadingCursor.zero, 0);
                    await _refreshEntry();
                    if (!context.mounted) break;
                    // Long enough to reach: the place is otherwise gone.
                    showSnack(context, 'Back to the beginning.', long: true, actionLabel: 'Undo', onAction: () async {
                      await _store.saveCursor(was.id, place, was.progress, where: was.where);
                      await _refreshEntry();
                    });
                  case 'remove':
                    final nav = Navigator.of(context);
                    if (await removeBook(context, _store, _entry)) await nav.maybePop();
                }
              },
              itemBuilder: (_) => [
                if (_layout?.isEmpty == false) const PopupMenuItem(value: 'passage', child: Text('Find a passage')),
                if (_layout?.isEmpty == false) const PopupMenuItem(value: 'audio', child: Text('Save as audio…')),
                const PopupMenuItem(value: 'rules', child: Text('Reading rules')),
                const PopupMenuItem(value: 'cover', child: Text('Change cover')),
                // A file's book only: a web novel's chapters are the site's.
                if (!_entry.isWeb && _entry.sourcePath.isNotEmpty)
                  const PopupMenuItem(value: 'replace', child: Text('Replace the file…')),
                const PopupMenuItem(value: 'move', child: Text('Move to…')),
                const PopupMenuItem(value: 'organise', child: Text('Tags and series…')),
                const PopupMenuItem(value: 'journal', child: Text('Write in the journal')),
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
      if (e.wordCount > 0) listenLength(e.wordCount, speed: _prefs.speedFor(e.id)),
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
              // A scan whose words OCR read (ocr.dart).
              if (e.ocr != null) ...[
                const SizedBox(height: Gap.s),
                Text('Read by OCR: may contain errors', style: Skin.label(context, size: 13)),
              ],
              if (category != null) ...[
                const SizedBox(height: Gap.m),
                _detail(
                  context,
                  icon: Icons.folder_outlined,
                  label: category.name,
                  onTap: () => moveBook(context, _store, _entry),
                ),
              ],
              // Its series, in order, a tap away; and its tags.
              if (e.seriesName != null)
                _detail(
                  context,
                  icon: Icons.collections_bookmark_outlined,
                  label: seriesLine(e),
                  onTap: _showSeries,
                  more: Icons.chevron_right_rounded,
                ),
              _detail(
                context,
                icon: Icons.sell_outlined,
                label: e.tags.isEmpty ? 'Add tags' : e.tags.join(' · '),
                faint: e.tags.isEmpty,
                onTap: () => editTagsAndSeries(context, _store, _entry),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One quiet line of the book's details under its facts: its shelf, its
  /// series, its tags, each opening what changes it.
  Widget _detail(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    IconData more = Icons.arrow_drop_down_rounded,
    bool faint = false,
  }) {
    final color = faint ? Skin.inkFaintOn(context) : Skin.inkSoftOn(context);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.pill),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.ui(size: 14, weight: FontWeight.w600, color: color)),
            ),
            Icon(more, color: color),
          ],
        ),
      ),
    );
  }

  /// The book's series in its order; another of them opens its own page.
  Future<void> _showSeries() async {
    final name = _entry.seriesName;
    if (name == null) return;
    final books = (await _store.index()).entries;
    if (!mounted) return;
    final picked = await showSeriesBooks(context, name: name, books: books, current: _entry.id);
    if (picked == null || picked.id == _entry.id || !mounted) return;
    if (picked.isWeb) {
      await NovelScreen.openEntry(context, _store, picked);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: picked.id,
        cover: picked.shownCover,
        child: BookScreen(store: _store, entry: picked),
      ),
    ));
  }

  Widget _actions(BuildContext context) {
    final e = _entry;
    final started = e.progress > 0 && !e.finished;
    final left = e.wordCount > 0 ? listenLength((e.wordCount * (1 - e.progress)).round(), speed: _prefs.speedFor(e.id)) : '';
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
                  style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
            ],
          ),
        ),
      );

  Widget _voice(BuildContext context) {
    final controller = _listen;
    final v = _catalog.byName(controller.voiceName);
    // This book's own speed, when it has one ("For this book only").
    final speed = trimSpeed(_prefs.speedFor(_entry.id));
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
              Icon(Icons.record_voice_over_rounded, color: Skin.accentInkOf(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Eyebrow('Voice for this book'),
                    const SizedBox(height: 2),
                    Text(
                      controller.narrated
                          ? "Book's own narration · $speed×"
                          : !_catalog.loaded
                          ? 'Loading voices…'
                          : v == null
                              ? 'No ${languageName(_language)} voice yet'
                              : '${v.languageLabel} · ${_catalog.friendlyName(v)} · $speed×',
                      style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context)),
                    ),
                  ],
                ),
              ),
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
            ],
          ),
        ),
      ),
    );
  }

  /// How a TXT book is cut into chapters, under its voice: found by
  /// TomeVoice, or as its reader said (see showTextChapters).
  Widget _textChapters(BuildContext context) => Material(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row + 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.row + 4),
          onTap: _layout == null ? null : _changeChapters,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.format_list_numbered_rounded, color: Skin.accentInkOf(context)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Eyebrow('Chapters'),
                      const SizedBox(height: 2),
                      Text(
                        _splitting ? 'Splitting the book…' : textChaptersLabel(_entry.textChapters),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context)),
                      ),
                    ],
                  ),
                ),
                Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
              ],
            ),
          ),
        ),
      );

  /// Set while the book is being split again.
  bool _splitting = false;

  /// The book cut into chapters another way: split again, its place, its
  /// bookmarks and quotes carried with their words (see splitTextBook).
  Future<void> _changeChapters() async {
    final was = _layout;
    if (was == null || _splitting) return;
    final rule = await showTextChapters(
      context,
      title: _entry.title,
      current: _entry.textChapters,
      load: () => _store.textOf(_entry.id),
    );
    if (rule == null || !mounted) return;
    // The chapters go while it is split, and nothing opens meanwhile.
    setState(() {
      _splitting = true;
      _layout = null;
    });
    try {
      final layout = await splitTextBook(_store, _entry.id, rule);
      final cursor = await _store.cursorFor(_entry.id);
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _cursor = cursor;
      });
      await _refreshEntry();
      if (!mounted) return;
      final n = layout.chapters.length;
      showSnack(context,
          'Split into $n ${n == 1 ? 'chapter' : 'chapters'}. Your place, bookmarks and quotes are where they were.');
    } on Object catch (e) {
      debugPrint('Splitting the book failed: $e');
      if (!mounted) return;
      setState(() => _layout = was);
      showSnack(context, 'The book could not be split again. It is as it was.');
    } finally {
      if (mounted) setState(() => _splitting = false);
    }
  }

  /// The book's characters, and the voices their lines are read in: under
  /// its voice, once its speech tags have named anyone.
  Widget _characters(BuildContext context) {
    final summary = castSummary(_prefs.castByBook[_entry.id]);
    final n = _people.length;
    return Material(
      color: Skin.capsuleOn(context),
      borderRadius: BorderRadius.circular(Radii.row + 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row + 4),
        onTap: () => showCastSheet(
          context,
          bookId: _entry.id,
          title: _entry.title,
          people: _people,
          listen: _listen,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.groups_outlined, color: Skin.accentInkOf(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Eyebrow('Characters'),
                    const SizedBox(height: 2),
                    Text(
                      summary ?? '$n ${n == 1 ? 'speaks' : 'speak'}, all in the dialogue voice',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(size: 15.5, weight: FontWeight.w600, color: Skin.inkOn(context)),
                    ),
                  ],
                ),
              ),
              Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: Skin.accentInkOf(context))),
            ],
          ),
        ),
      ),
    );
  }
}
