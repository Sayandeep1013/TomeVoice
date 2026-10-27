import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_actions.dart';
import 'book_card.dart';
import 'book_screen.dart';
import 'book_tint.dart';
import 'categories_screen.dart';
import 'library_store.dart';
import 'listening_session.dart';
import 'novel_screen.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

const _svc = SpeechService();

/// The shelf.
///
/// Top: the menu, and search, Add books, view and Settings on the right.
/// Middle: one page per category, swiped sideways, with tabs that follow.
/// Bottom: the books you are in the middle of, one swipe apart, with a play
/// button: picking up where you left off is what this screen is for most
/// of the time, so it sits where the thumb is.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _Importing {
  _Importing(this.name);
  final String name;
  int done = 0;
  int total = 0;
}

class _LibraryScreenState extends State<LibraryScreen> with WhenShown<LibraryScreen> {
  LibraryStore get _store => widget.store;
  LibraryIndex? _index;
  int _page = 0;

  /// The shelves' pager, made when the shelves first show. By then the
  /// index has been read, so it starts on the default shelf: made at once,
  /// it showed the first shelf for a frame and then cut to the default.
  PageController? _pager;
  PageController get _pages => _pager ??= PageController(initialPage: _page);

  /// Bumped when the shelf jumps to a far category, which then fades in.
  int _leap = 0;

  /// What the body showed last: nothing yet, the empty shelf, a search or
  /// the shelves.
  String _shownMode = 'none';

  /// Books that came onto the shelf after it first showed (imported, added
  /// from Browse), with when: each eases into its place once.
  final _arrived = <String, DateTime>{};
  _Importing? _importing;
  String _query = '';
  bool _searching = false;
  final _selected = <String>{};
  final _searchController = TextEditingController();

  /// When each shelf (category, in list or covers) first showed: its books
  /// ease in that once, never again on a rebuild or a swipe back.
  final _introduced = <String, DateTime>{};

  /// Off while a book page opens from the Continue dock, so the cover does
  /// not fly in from a tile somewhere on the shelf behind it.
  bool _shelfHeroes = true;

  final _shelfKey = GlobalKey();

  /// Files handed over by "Open with" arrive both as an event and as the
  /// pending-open value; whichever reaches us second is ignored.
  final _handled = <String>{};
  StreamSubscription<Map<String, Object?>>? _events;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(VoiceCatalog.instance.ensureLoaded());
    _events = SpeechService.events.listen(_onPlatformEvent);
    _store.changes.addListener(_refresh);
    _store.placeChanges.addListener(_placeSaved);
    ListeningPrefs.revision.addListener(_onPrefs);
    BackgroundReading.current.addListener(_onBackground);
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _store.changes.removeListener(_refresh);
    _store.placeChanges.removeListener(_placeSaved);
    ListeningPrefs.revision.removeListener(_onPrefs);
    BackgroundReading.current.removeListener(_onBackground);
    _searchController.dispose();
    _pager?.dispose();
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  /// A reader saved its place. The reader covers the shelf while it reads,
  /// so the shelf catches up once, when it shows again.
  void _placeSaved() => whenShown(_refresh);

  /// The index changed (a place saved, a cover changed): re-read it so the
  /// shelf order and progress are never a step behind.
  Future<void> _refresh() async {
    final idx = await _store.index();
    if (!mounted) return;
    setState(() {
      _noteArrivals(idx);
      _index = idx;
      _page = _page.clamp(0, idx.categories.length - 1);
    });
  }

  /// Marks the books in [idx] that the shelf did not have, so they ease in.
  void _noteArrivals(LibraryIndex idx) {
    final before = _index;
    if (before == null) return;
    final had = {for (final e in before.entries) e.id};
    final now = DateTime.now();
    for (final e in idx.entries) {
      if (!had.contains(e.id)) _arrived[e.id] = now;
    }
  }

  Future<void> _open() async {
    try {
      final idx = await _store.index();
      if (!mounted) return;
      final start = idx.categories.indexWhere((c) => c.id == idx.defaultCategory);
      setState(() {
        _index = idx;
        _page = start < 0 ? 0 : start;
      });
      // Only if a change showed the shelves before this: then the pager
      // was made on the first shelf.
      if (_pager?.positions.length == 1) _pager!.jumpToPage(_page);
      final pending = await _svc.pendingOpen();
      if (pending != null && _handled.add(pending.path)) {
        await _importAll([pending], openAfter: true);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(
        () => _index = const LibraryIndex(
          entries: [],
          categories: Category.defaults,
          defaultCategory: 'reading',
        ),
      );
      _snack('Could not open the library: $e');
    }
  }

  /// The dock's Play: the book reads aloud from where it was left, and the
  /// shelf stays.
  Future<void> _playHere(LibraryEntry e) async {
    try {
      await BackgroundReading.startFrom(_store, e);
    } on Object catch (err) {
      _snack('Could not start reading: $err');
    }
  }

  /// A book began or stopped reading on in the background: the dock follows.
  void _onBackground() {
    if (mounted) setState(() {});
  }

  void _onPlatformEvent(Map<String, Object?> e) {
    if (e['type'] == 'openFile') {
      // "Open with TomeVoice" while the app is running: come back to the
      // shelf, import, open.
      final file = PickedFile.fromMap(e);
      // Before the shelf has loaded, _open picks it up from pendingOpen.
      if (_index == null || !_handled.add(file.path)) return;
      unawaited(_svc.pendingOpen());
      Navigator.of(context).popUntil((r) => r.isFirst);
      unawaited(_importAll([file], openAfter: true));
    } else if (e['type'] == 'openFailed') {
      _snack('Could not open that file: ${e['message']}');
    }
  }

  Future<void> _pick() async {
    if (_importing != null) return;
    try {
      final files = await _svc.pickDocuments();
      if (files.isEmpty) return;
      await _importAll(files, openAfter: files.length == 1);
    } on PlatformException catch (e) {
      _snack(e.message ?? e.code);
    }
  }

  Future<void> _importAll(List<PickedFile> files, {required bool openAfter}) async {
    final imported = <LibraryEntry>[];
    final failures = <String>[];
    for (final f in files) {
      final job = _Importing(f.name);
      setState(() => _importing = job);
      try {
        imported.add(
          await _store.importFile(
            f,
            onProgress: (done, total) {
              if (!mounted) return;
              setState(() {
                job.done = done;
                job.total = total;
              });
            },
          ),
        );
      } on EncryptedDocumentException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on UnsupportedDocumentException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on ParseException catch (e) {
        failures.add('${f.name}: ${e.message}');
      } on PlatformException catch (e) {
        failures.add('${f.name}: ${e.message ?? e.code}');
      } on Object catch (e) {
        failures.add('${f.name}: $e');
      }
    }
    final idx = await _store.index();
    if (!mounted) return;
    setState(() {
      _importing = null;
      _noteArrivals(idx);
      _index = idx;
    });
    // Show the shelf the new books went to.
    if (imported.isNotEmpty) {
      final cat = imported.last.categoryIn(idx.categories, idx.defaultCategory);
      final page = idx.categories.indexWhere((c) => c.id == cat);
      if (page >= 0) _goToPage(page);
    }
    if (failures.isNotEmpty) {
      _snack(failures.join('\n'), long: true);
    } else if (imported.length > 1) {
      _snack('Added ${imported.length} books.');
    }
    if (openAfter && imported.length == 1) await _showBook(imported.single);
  }

  /// The next shelf slides across; a far one is gone to at once and fades
  /// in, rather than paging past every shelf between (building each one's
  /// books and covers on the way).
  void _goToPage(int page) {
    final from = _page;
    setState(() => _page = page);
    // Not while two pagers share it (the shelves fading back in over the
    // search, for a moment).
    if (_pages.positions.length != 1) return;
    final at = _pages.page?.round() ?? from;
    final far = (page - at).abs() > 1;
    if (far || Motion.reduced(context)) {
      _pages.jumpToPage(page);
      if (far) setState(() => _leap++);
    } else {
      unawaited(_pages.animateToPage(page, duration: Motion.page, curve: Motion.emphasized));
    }
  }

  /// A book's page: details, voice, chapters, Play. Its cover flies from
  /// the shelf unless [fromShelf] is false.
  Future<void> _showBook(LibraryEntry entry, {bool fromShelf = true}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // A web novel's page lists every chapter on the site, not only the ones
    // fetched so far.
    if (entry.isWeb) {
      await NovelScreen.openEntry(context, _store, entry);
      return;
    }
    if (!fromShelf) setState(() => _shelfHeroes = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookTint(
          bookId: entry.id,
          cover: entry.shownCover,
          child: BookScreen(store: _store, entry: entry),
        ),
      ),
    );
    if (!fromShelf && mounted) setState(() => _shelfHeroes = true);
    await _refresh();
  }

  /// Straight into the reader, at the saved place.
  Future<void> _resume(LibraryEntry entry, {bool autoplay = false}) async {
    await openBook(context, _store, entry, autoplay: autoplay);
    await _refresh();
  }

  // ------------------------------------------------------------ selection

  void _toggle(LibraryEntry e) {
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(e.id) ? _selected.remove(e.id) : _selected.add(e.id));
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _moveSelected() async {
    final n = _selected.length;
    final target = await pickCategory(context, _store, title: 'Move $n ${n == 1 ? 'book' : 'books'} to');
    if (target == null) return;
    await _store.moveBooks({..._selected}, target);
    if (!mounted) return;
    final name = _index?.categories.where((c) => c.id == target).firstOrNull?.name ?? 'the category';
    _clearSelection();
    _snack('Moved to $name.');
  }

  Future<void> _removeSelected() async {
    final n = _selected.length;
    final ok = await confirm(
      context,
      title: 'Remove $n ${n == 1 ? 'book' : 'books'}?',
      body:
          'They are deleted from TomeVoice with their reading places. '
          'The original files on your phone are not touched.',
      action: 'Remove',
    );
    if (!ok) return;
    for (final id in {..._selected}) {
      await _store.remove(id);
    }
    if (!mounted) return;
    _clearSelection();
    _snack('Removed $n ${n == 1 ? 'book' : 'books'}.');
  }

  Future<void> _manageCategories() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => CategoriesScreen(store: _store)));
    await _refresh();
  }

  // ------------------------------------------------------------- book menu

  Future<void> _bookMenu(LibraryEntry e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(
                e.title,
                subtitle: [
                  e.formatLabel,
                  if (e.wordCount > 0) '${_thousands(e.wordCount)} words',
                  if (e.language != null) languageName(e.language!),
                ].join('  ·  '),
              ),
              SheetAction(
                icon: Icons.play_arrow_rounded,
                label: 'Read aloud',
                detail: e.progress > 0 ? 'From where you left off' : 'From the beginning',
                onTap: () => Navigator.pop(ctx, 'play'),
              ),
              SheetAction(
                icon: Icons.info_outline_rounded,
                label: 'Book details and chapters',
                onTap: () => Navigator.pop(ctx, 'details'),
              ),
              SheetAction(
                icon: Icons.drive_file_move_outline,
                label: 'Move to…',
                onTap: () => Navigator.pop(ctx, 'move'),
              ),
              SheetAction(
                icon: Icons.checklist_rounded,
                label: 'Select',
                detail: 'Pick several books to move or remove',
                onTap: () => Navigator.pop(ctx, 'select'),
              ),
              SheetAction(
                icon: Icons.image_outlined,
                label: 'Change cover',
                onTap: () => Navigator.pop(ctx, 'cover'),
              ),
              SheetAction(
                icon: Icons.delete_outline_rounded,
                label: 'Remove from library',
                danger: true,
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
              const SizedBox(height: Gap.s),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        await _resume(e, autoplay: true);
      case 'details':
        await _showBook(e);
      case 'cover':
        await changeCover(context, _store, e);
      case 'move':
        await moveBook(context, _store, e);
      case 'select':
        _toggle(e);
      case 'remove':
        if (await removeBook(context, _store, e)) _snack('Removed "${e.title}".');
    }
  }

  void _snack(String text, {bool long = false}) {
    if (!mounted) return;
    // Above the Continue bar, not on top of it.
    showSnack(context, text, long: long, lift: 84);
  }

  // ---------------------------------------------------------------- build

  List<LibraryEntry> _sorted(List<LibraryEntry> books) {
    final out = [...books];
    switch (_prefs.sort) {
      case LibrarySort.recent:
        break; // The index is already newest first.
      case LibrarySort.added:
        out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case LibrarySort.title:
        out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.progress:
        out.sort((a, b) => b.progress.compareTo(a.progress));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final idx = _index;
    final q = _query.trim().toLowerCase();
    final searching = _searching && q.isNotEmpty;
    final entries = idx?.entries ?? const <LibraryEntry>[];
    final categories = idx?.categories ?? Category.defaults;
    // The book reading on in the background comes first, finished or not
    // (a web novel near its newest chapter counts as finished): it is the
    // one the dock's button pauses.
    final live = BackgroundReading.current.value?.bookId;
    final reading = [
      for (final e in entries)
        if (e.id == live) e,
      for (final e in entries)
        if (e.openedAt != null && !e.finished && e.id != live) e,
    ].take(6).toList();
    final showDock = reading.isNotEmpty && !_selecting && !searching;

    // A new sort or view fades the books round, rather than swapping them
    // under the finger.
    final arrangement = (_prefs.sort, _prefs.gridView);
    final String mode;
    Widget body;
    if (idx == null) {
      mode = 'none';
      body = const SizedBox.shrink();
    } else if (entries.isEmpty && _importing == null) {
      mode = 'empty';
      body = Center(child: SingleChildScrollView(child: _emptyLibrary(context)));
    } else if (searching) {
      mode = 'search';
      final found = _sorted([
        for (final e in entries)
          if (e.title.toLowerCase().contains(q) || e.authorLine.toLowerCase().contains(q)) e,
      ]);
      body = FadeIn(
        trigger: arrangement,
        arrive: false,
        child: _books(
          context,
          found,
          shelf: 'search',
          header: Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Eyebrow(found.isEmpty ? 'Nothing matches "${_query.trim()}"' : '${found.length} found'),
          ),
          bottomPad: Gap.xl,
        ),
      );
    } else {
      mode = 'shelf';
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.s, Gap.s),
            child: _CategoryTabs(
              index: idx,
              current: _page,
              pages: _pages,
              onPick: _goToPage,
              onManage: _manageCategories,
            ),
          ),
          Expanded(
            child: FadeIn(
              trigger: (arrangement, _leap),
              arrive: false,
              child: PageView.builder(
                // Keeps the shelf it was on when it is built again (after a
                // search), which an unkeyed pager forgets.
                key: const PageStorageKey('shelves'),
                controller: _pages,
                itemCount: categories.length,
                onPageChanged: (p) => setState(() => _page = p),
                itemBuilder: (context, p) {
                  final c = categories[p];
                  final books = _sorted(idx.inCategory(c.id));
                  final since = _introduced.putIfAbsent('${c.id}/${_prefs.gridView}', DateTime.now);
                  return books.isEmpty
                      ? _emptyCategory(context, c.name)
                      : _books(context, books, shelf: c.id, bottomPad: showDock ? 120 : Gap.xl, since: since);
                },
              ),
            ),
          ),
        ],
      );
    }
    // The empty shelf, the search and the shelves fade into each other's
    // place instead of cutting. The first, once the index is read, comes
    // with the whole screen fading in from the opening lockup.
    body = fadeSwitch(context, KeyedSubtree(key: ValueKey(mode), child: body), instant: _shownMode == 'none');
    _shownMode = mode;

    return shownGate(PopScope(
      canPop: !_selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _clearSelection();
        } else if (_searching) {
          _closeSearch();
        }
      },
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.s),
                    child: AnimatedSwitcher(
                      duration: Motion.of(context, Motion.standard),
                      switchInCurve: Motion.out,
                      switchOutCurve: const Interval(0.5, 1),
                      transitionBuilder: fadeRise,
                      child: _selecting
                          ? KeyedSubtree(key: const ValueKey('selecting'), child: _selectionBar(context))
                          : KeyedSubtree(key: const ValueKey('header'), child: _header(context)),
                    ),
                  ),
                  _unfold(
                    context,
                    _searching
                        ? Padding(
                            key: const ValueKey('search'),
                            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                            child: SearchField(
                              hint: 'Search your books',
                              controller: _searchController,
                              autofocus: true,
                              onChanged: (v) => setState(() => _query = v),
                              onClear: _closeSearch,
                            ),
                          )
                        : null,
                  ),
                  _unfold(
                    context,
                    _importing == null
                        ? null
                        : Padding(
                            key: const ValueKey('importing'),
                            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                            child: _importCard(context, _importing!),
                          ),
                  ),
                  // Books fade out as they scroll under the dock. The content
                  // itself fades, so the real ground shows through: a painted
                  // band never matched the diagonal ground and read as a bar.
                  // The fade grows and shrinks as the dock rises and sinks
                  // (it snapped on and off under the moving dock). The key
                  // carries the shelf across the mask coming and going
                  // (selecting a book hides the dock): rebuilt fresh, the
                  // pages would snap back to the first category.
                  Expanded(
                    child: HeroMode(
                      enabled: _shelfHeroes,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: showDock ? 130 : 0),
                        duration: Motion.of(context, showDock ? Motion.page : Motion.standard),
                        curve: Motion.out,
                        child: KeyedSubtree(key: _shelfKey, child: body),
                        builder: (context, fade, shelf) => fade <= 0
                            ? shelf!
                            : ShaderMask(
                                blendMode: BlendMode.dstIn,
                                shaderCallback: (rect) => LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: const [Colors.black, Colors.black, Colors.transparent],
                                  stops: [0, (1 - fade / rect.height).clamp(0.0, 1.0), 1],
                                ).createShader(rect),
                                child: shelf,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                left: Gap.m,
                right: Gap.m,
                bottom: Gap.m,
                // The dock rises from the foot of the screen and sinks back
                // into it.
                child: AnimatedSwitcher(
                  duration: Motion.of(context, Motion.page),
                  reverseDuration: Motion.of(context, Motion.standard),
                  switchInCurve: Motion.out,
                  switchOutCurve: Motion.out,
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: animation.drive(Tween(begin: const Offset(0, 1.5), end: Offset.zero)),
                    child: child,
                  ),
                  child: !showDock
                      ? const SizedBox.shrink()
                      // On a wide screen the dock keeps a phone's width,
                      // centred, instead of a bar a third of the screen tall.
                      : Align(
                          key: const ValueKey('dock'),
                          alignment: Alignment.bottomCenter,
                          heightFactor: 1,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: ContinueDock(
                              books: reading,
                              onOpen: (e) => _resume(e),
                              // Play reads aloud right here; the rest of the
                              // dock opens the book where it is being read.
                              onPlay: (e) => unawaited(_playHere(e)),
                              onDetails: (e) => _showBook(e, fromShelf: false),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  /// Something that unfolds below the header ([child]) or folds away (null).
  Widget _unfold(BuildContext context, Widget? child) => AnimatedSwitcher(
        duration: Motion.of(context, Motion.standard),
        switchInCurve: Motion.out,
        switchOutCurve: Motion.out,
        transitionBuilder: revealDown,
        child: child ?? const SizedBox(width: double.infinity),
      );

  /// The books as covers or rows. With [since], the first rows ease in (see
  /// [Entrance]). [shelf] keeps each shelf's place apart (a category, or the
  /// search), and kept when a book comes or goes.
  Widget _books(
    BuildContext context,
    List<LibraryEntry> books, {
    required String shelf,
    Widget? header,
    required double bottomPad,
    DateTime? since,
  }) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // Each tile is keyed by its book and found again by it, so when books
    // come, go or move, a tile's state (its entrance, its cover) goes with
    // its book instead of staying at its place in the list.
    final at = {for (var i = 0; i < books.length; i++) books[i].id: i};
    int? find(Key key) => key is ValueKey<String> ? at[key.value] : null;
    // A book new on the shelf eases in, first and at once.
    Widget enter(int i, LibraryEntry e, Widget tile) {
      final arrived = _arrived[e.id];
      return Entrance(
        key: ValueKey(e.id),
        index: arrived == null ? i : 0,
        since: arrived ?? since,
        child: tile,
      );
    }

    return CustomScrollView(
      key: PageStorageKey('shelf-$shelf-${_prefs.gridView}'),
      slivers: [
        if (header != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            sliver: SliverToBoxAdapter(child: header),
          ),
        if (_prefs.gridView)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, bottomPad),
            sliver: SliverGrid(
              // Two covers across a phone, more in landscape or on a tablet.
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: landscape ? 170 : 190,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 2 / 3,
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: books.length,
                findChildIndexCallback: find,
                (context, i) {
                  final e = books[i];
                  return enter(
                    i,
                    e,
                    BookTile(
                      entry: e,
                      selected: _selected.contains(e.id),
                      onOpen: () => _selecting ? _toggle(e) : _showBook(e),
                      onLongPress: () => _toggle(e),
                    ),
                  );
                },
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, bottomPad),
            sliver: SliverList.separated(
              itemCount: books.length,
              findItemIndexCallback: find,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final e = books[i];
                return enter(
                  i,
                  e,
                  BookRow(
                    entry: e,
                    selecting: _selecting,
                    selected: _selected.contains(e.id),
                    onOpen: () => _selecting ? _toggle(e) : _showBook(e),
                    onMenu: () => _bookMenu(e),
                    onLongPress: () => _toggle(e),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  void _closeSearch() {
    _searchController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  Widget _header(BuildContext context) {
    const size = 42.0;
    return Row(
      children: [
        RoundButton(
          icon: Icons.menu_rounded,
          tooltip: 'Menu',
          size: size,
          onTap: () => Scaffold.maybeOf(context)?.openDrawer(),
        ),
        const SizedBox(width: Gap.m),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('Library', style: Skin.title(context, size: 28, weight: FontWeight.w500)),
          ),
        ),
        RoundButton(
          icon: _searching ? Icons.search_off_rounded : Icons.search_rounded,
          tooltip: 'Search',
          size: size,
          onTap: () => _searching ? _closeSearch() : setState(() => _searching = true),
        ),
        const SizedBox(width: 6),
        RoundButton(
          icon: _importing != null ? Icons.hourglass_top_rounded : Icons.add_rounded,
          tooltip: 'Add books',
          size: size,
          color: Skin.amber,
          iconColor: Skin.onAmber,
          onTap: _importing != null ? null : _pick,
        ),
        const SizedBox(width: 6),
        _viewMenu(context, size),
        const SizedBox(width: 6),
        RoundButton(
          icon: Icons.settings_outlined,
          tooltip: 'Settings',
          size: size,
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(store: _store))),
        ),
      ],
    );
  }

  Widget _viewMenu(BuildContext context, double size) => PopupMenuButton<Object>(
    tooltip: 'View and sort',
    position: PopupMenuPosition.under,
    padding: EdgeInsets.zero,
    onSelected: (v) {
      if (v is bool) _prefs.gridView = v;
      if (v is LibrarySort) _prefs.sort = v;
      _prefs.save();
    },
    itemBuilder: (ctx) => [
      for (final (grid, label, icon) in const [
        (false, 'List', Icons.view_agenda_outlined),
        (true, 'Covers', Icons.grid_view_rounded),
      ])
        CheckedPopupMenuItem<Object>(
          value: grid,
          checked: _prefs.gridView == grid,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: Gap.m),
              Text(label),
            ],
          ),
        ),
      const PopupMenuDivider(),
      for (final s in LibrarySort.values)
        CheckedPopupMenuItem<Object>(value: s, checked: _prefs.sort == s, child: Text('Sort: ${s.label}')),
    ],
    child: IgnorePointer(
      child: RoundButton(
        icon: _prefs.gridView ? Icons.grid_view_rounded : Icons.view_agenda_outlined,
        size: size,
        onTap: () {},
      ),
    ),
  );

  Widget _selectionBar(BuildContext context) => Row(
    children: [
      RoundButton(icon: Icons.close_rounded, tooltip: 'Cancel', onTap: _clearSelection),
      const SizedBox(width: Gap.m),
      Expanded(child: Text('${_selected.length} selected', style: Skin.title(context, size: 22))),
      RoundButton(icon: Icons.drive_file_move_outline, tooltip: 'Move to…', onTap: _moveSelected),
      const SizedBox(width: Gap.s),
      RoundButton(icon: Icons.delete_outline_rounded, tooltip: 'Remove', onTap: _removeSelected),
    ],
  );

  Widget _emptyLibrary(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      EmptyState(
        icon: Icons.auto_stories_outlined,
        title: 'Your shelf is empty',
        body:
            'Add any book you own. TomeVoice opens it, finds the chapters '
            'and reads it to you, screen on or off.',
        action: FilledButton.icon(
          onPressed: _pick,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add books'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xxl),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final f in const [
              'EPUB',
              'PDF',
              'DOCX',
              'MOBI',
              'AZW3',
              'TXT',
              'RTF',
              'ODT',
              'FB2',
              'HTML',
              'MD',
            ])
              TagChip(f),
          ],
        ),
      ),
      const SizedBox(height: Gap.l),
      Text(
        'Tip: open a book with TomeVoice from any file manager.',
        textAlign: TextAlign.center,
        style: Skin.label(context, size: 13, color: Skin.inkFaintOn(context)),
      ),
      const SizedBox(height: Gap.xl),
    ],
  );

  Widget _emptyCategory(BuildContext context, String name) => ListView(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xxl, Gap.page, 0),
    children: [
      Text('Nothing in $name yet', textAlign: TextAlign.center, style: Skin.title(context, size: 20)),
      const SizedBox(height: Gap.s),
      Text(
        'Long-press a book on another shelf, then tap Move.',
        textAlign: TextAlign.center,
        style: Skin.label(context, size: 14, color: Skin.inkFaintOn(context)),
      ),
    ],
  );

  Widget _importCard(BuildContext context, _Importing job) {
    final frac = job.total > 0 ? job.done / job.total : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.l, 14, Gap.l, 14),
      decoration: BoxDecoration(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row + 4),
        border: Border.all(color: Skin.outlineOn(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 17)),
          const SizedBox(height: Gap.xs),
          Eyebrow(
            frac == null ? 'Opening and finding chapters…' : 'Reading page ${job.done} of ${job.total}…',
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: frac, minHeight: 4),
          ),
        ],
      ),
    );
  }
}

/// The library's shelves, as a row of pills with their book counts. The
/// amber passes from pill to pill with the shelf as it is swiped, and the
/// row scrolls to keep the chosen pill in view.
class _CategoryTabs extends StatefulWidget {
  const _CategoryTabs({
    required this.index,
    required this.current,
    required this.pages,
    required this.onPick,
    required this.onManage,
  });

  final LibraryIndex index;
  final int current;

  /// The shelves' pager: where it stands between two pages is how far the
  /// amber has passed from one pill to the next.
  final PageController pages;
  final ValueChanged<int> onPick;
  final VoidCallback onManage;

  @override
  State<_CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<_CategoryTabs> {
  final _scroll = ScrollController();

  /// Each pill, by category, to find it when it is to be brought into view.
  final _pills = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _reveal(first: true);
  }

  @override
  void didUpdateWidget(_CategoryTabs old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) _reveal();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the chosen pill to the middle of the row, as far as the row
  /// goes: a shelf picked by swiping, or from a pill at the edge, was
  /// otherwise left out of sight. At once the first time.
  void _reveal({bool first = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cats = widget.index.categories;
      if (!mounted || widget.current >= cats.length) return;
      final pill = _pills[cats[widget.current].id]?.currentContext;
      if (pill == null) return;
      unawaited(Scrollable.ensureVisible(
        pill,
        alignment: 0.5,
        duration: first ? Duration.zero : Motion.of(context, Motion.standard),
        curve: Motion.emphasized,
      ));
    });
  }

  double get _position {
    final pages = widget.pages;
    final current = widget.current;
    if (!pages.hasClients || pages.positions.length != 1) return current.toDouble();
    final p = pages.position;
    if (!p.hasPixels || !p.hasContentDimensions) return current.toDouble();
    return pages.page ?? current.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            // Only these pills rebuild as the shelf moves, never the books.
            child: ListenableBuilder(
              listenable: widget.pages,
              builder: (context, _) {
                final at = _position;
                // Every pill built (they are few), so any can be scrolled to.
                return SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < index.categories.length; i++) ...[
                        _tab(
                          context,
                          i,
                          index.categories[i],
                          index.inCategory(index.categories[i].id).length,
                          (1 - (at - i).abs()).clamp(0.0, 1.0),
                        ),
                        const SizedBox(width: Gap.s),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Edit categories',
            onPressed: widget.onManage,
            icon: Icon(Icons.edit_note_rounded, size: 24, color: Skin.inkSoftOn(context)),
          ),
        ],
      ),
    );
  }

  /// Pill [i]; [t] is how much it is the current one, from 0 to 1.
  Widget _tab(BuildContext context, int i, Category c, int count, double t) {
    final selected = i == widget.current;
    return Semantics(
      key: _pills.putIfAbsent(c.id, GlobalKey.new),
      selected: selected,
      button: true,
      child: Material(
        color: Color.lerp(Skin.capsuleOn(context), Skin.amber, t),
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: () => widget.onPick(i),
          onLongPress: widget.onManage,

          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Gap.s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.name,
                  // The weight follows too, so the label never jumps.
                  style: Skin.ui(
                    size: 14,
                    weight: t >= 0.5 ? FontWeight.w700 : FontWeight.w600,
                    color: Color.lerp(Skin.inkOn(context), Skin.onAmber, t),
                  ).copyWith(fontVariations: [FontVariation('wght', 600 + 100 * t)]),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: Skin.ui(
                    size: 12.5,
                    weight: FontWeight.w600,
                    tabular: true,
                    color: Color.lerp(Skin.inkFaintOn(context), Skin.onAmber.withValues(alpha: 0.7), t),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The books you are in the middle of, at the bottom of the shelf: swipe
/// between them, tap to read, play to listen from where you stopped.
final _notPlaying = ValueNotifier<bool>(false);

class ContinueDock extends StatefulWidget {
  const ContinueDock({
    super.key,
    required this.books,
    required this.onOpen,
    required this.onPlay,
    required this.onDetails,
  });

  final List<LibraryEntry> books;
  final ValueChanged<LibraryEntry> onOpen;
  final ValueChanged<LibraryEntry> onPlay;
  final ValueChanged<LibraryEntry> onDetails;

  @override
  State<ContinueDock> createState() => _ContinueDockState();
}

class _ContinueDockState extends State<ContinueDock> {
  final _controller = PageController();
  int _page = 0;

  @override
  void didUpdateWidget(ContinueDock old) {
    super.didUpdateWidget(old);
    // The book just read moves to the front: show it.
    if (old.books.isNotEmpty &&
        widget.books.isNotEmpty &&
        old.books.first.id != widget.books.first.id &&
        _controller.hasClients) {
      _controller.jumpToPage(0);
      _page = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onDark = Skin.onDark(context);
    final books = widget.books;
    // No blur behind it: the shelf has faded to the bare ground by the time
    // it reaches the dock, so a blur showed nothing, and it cost a layer and
    // a blur on every frame of every scroll. A shade more opaque instead.
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.standard),
        curve: Motion.out,
        height: books.length > 1 ? 96 : 88,
        decoration: BoxDecoration(
          color: Skin.darkOn(context).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          children: [
            Expanded(
              // Another book come to the front fades in, rather than
              // the dock changing under the finger.
              child: FadeIn(
                trigger: books.isEmpty ? null : books.first.id,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: books.length,
                  onPageChanged: (p) => setState(() => _page = p),
                  itemBuilder: (context, i) => BookTint(
                    bookId: books[i].id,
                    cover: books[i].shownCover,
                    child: Builder(builder: (context) => _item(context, books[i], onDark)),
                  ),
                ),
              ),
            ),
            if (books.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < books.length; i++)
                      AnimatedContainer(
                        duration: Motion.of(context, const Duration(milliseconds: 200)),
                        margin: const EdgeInsets.symmetric(horizontal: 2.5),
                        width: i == _page ? 14 : 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: i == _page ? Skin.amber : onDark.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, LibraryEntry e, Color onDark) {
    final left = e.wordCount > 0 ? listenLength((e.wordCount * (1 - e.progress)).round()) : '';
    return InkWell(
      onTap: () => widget.onOpen(e),
      onLongPress: () => widget.onDetails(e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, 10, Gap.s, 4),
        child: Row(
          children: [
            BookCover(entry: e, width: 44, shadow: false),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.title(context, size: 16.5, color: onDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (e.where != null && e.where!.toLowerCase() != e.title.toLowerCase()) e.where!,
                      percentLabel(e.progress),
                      if (left.isNotEmpty) '$left left',
                    ].join(' · ').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.meta(context, size: 10, color: onDark.withValues(alpha: 0.6)),
                  ),
                  const SizedBox(height: 6),
                  Progress(e.progress, height: 2.5, track: onDark.withValues(alpha: 0.14)),
                ],
              ),
            ),
            const SizedBox(width: Gap.s),
            // The book reading on in the background is played and paused
            // here; another opens and reads aloud.
            ValueListenableBuilder<BackgroundReading?>(
              valueListenable: BackgroundReading.current,
              builder: (context, bg, _) {
                final live = bg != null && bg.bookId == e.id ? bg : null;
                return ValueListenableBuilder<bool>(
                  valueListenable: live?.playingNow ?? _notPlaying,
                  builder: (context, playing, _) => Tooltip(
                    message: live == null ? 'Continue reading aloud' : (playing ? 'Pause' : 'Play'),
                    child: Material(
                      color: Skin.accentOf(context),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => live == null ? widget.onPlay(e) : unawaited(live.toggle()),
                        child: SizedBox(
                          width: 52,
                          height: 52,
                          child: AnimatedSwitcher(
                            duration: Motion.of(context, Motion.quick),
                            transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                            child: Icon(
                              live != null && playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              key: ValueKey(live != null && playing),
                              size: 32,
                              color: Skin.onAccentOf(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
