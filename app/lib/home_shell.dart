import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'auto_backup.dart';
import 'auto_download.dart';
import 'background_check.dart';
import 'backup.dart';
import 'backup_flow.dart';
import 'book_tint.dart';
import 'brand.dart';
import 'browse_screen.dart';
import 'catalogues_screen.dart';
import 'categories_screen.dart';
import 'download_queue.dart';
import 'error_log.dart';
import 'export_audio_sheet.dart';
import 'guide.dart';
import 'history_screen.dart';
import 'library_screen.dart';
import 'library_store.dart';
import 'marks.dart';
import 'neural_voices.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'reading_rules.dart';
import 'saved_screen.dart';
import 'scheduler.dart' show PlaybackScheduler;
import 'stats.dart';
import 'stats_screen.dart';
import 'settings_screen.dart';
import 'sources/bridge.dart';
import 'sync.dart';
import 'sources/net.dart';
import 'sources/source_engine.dart';
import 'sources/source_store.dart';
import 'sources_screen.dart';
import 'speech_service.dart';
import 'starter.dart';
import 'updates.dart';
import 'updates_screen.dart';
import 'theme.dart';
import 'ui.dart';
import 'update_flow.dart';

/// The library as the app keeps it open: its folder, the books, the
/// sources (web novels) and the check for their new chapters, with the
/// settings, rules, marks, stats and natural voices attached beside them.
typedef OpenLibrary = ({String dir, LibraryStore store, SourceStore sources, Updates updates});

({String dir, Future<OpenLibrary> opened})? _library;

/// Open the library, once for each folder: the shelves, and a book started
/// from outside the app with no screen at all (backgroundMain, then the
/// shelves when TomeVoice is opened onto the same engine), share it. Two
/// stores would each write their own copy of library.json over the other's.
Future<OpenLibrary> openLibrary() async {
  final dir = await const SpeechService().outputDir();
  if (dir == null) throw const FileSystemException('No storage');
  final known = _library;
  if (known != null && known.dir == dir) return known.opened;
  final opened = _open(dir);
  _library = (dir: dir, opened: opened);
  try {
    return await opened;
  } on Object {
    // Asked again, it is tried again.
    if (_library?.dir == dir) _library = null;
    rethrow;
  }
}

Future<OpenLibrary> _open(String dir) async {
  await ListeningPrefs.load(dir);
  // Sources ask as the phone's own browser does (see Net.userAgent).
  final agent = await const SpeechService().webUserAgent();
  if (agent != null && agent.isNotEmpty) Net.userAgent = agent;
  // Sources live in internal storage, moved there once from the library's
  // folder (which other apps can read on Android 8 to 10).
  final internal = await SourcesBridge.sourcesRoot();
  final sources = await SourceStore.open(Directory(internal ?? dir), legacyRoot: Directory(dir));
  await Net.instance.attach(sources.dir);
  SourceEngine.instance.attach(sources);
  // The check made with the app closed asks with the same agent.
  if (agent != null && agent.isNotEmpty) unawaited(sources.saveUserAgent(agent));
  final store = LibraryStore(Directory(dir));
  _settleWhenLeft(store);
  // What the error log must never write, whatever an error says: every
  // book's title, author, series and tags, and the secret shelves' names.
  void keepOutOfLog() => unawaited(store.index(all: true).then((idx) {
        ErrorLog.instance.privateWords = [
          for (final e in idx.entries) ...[e.title, ...e.authors, ...e.tags, if (e.seriesName != null) e.seriesName!],
          for (final c in idx.categories)
            if (c.secret) c.name,
        ];
      }, onError: (Object _) {}));
  store.changes.addListener(keepOutOfLog);
  keepOutOfLog();
  // Chapters left downloading when the app last closed carry on.
  unawaited(DownloadQueue.instance.attach(store));
  await TintCache.instance.attach(Directory(dir));
  await ReadingRules.instance.attach(Directory(dir));
  await MarkStore.instance.attach(Directory(dir));
  await StatsStore.instance.attach(Directory(dir));
  NeuralVoices.instance.attach(Directory(dir));
  // One check for the whole engine (the shelves', the Updates page's, and
  // the closed-app check's worker's, see checkInApp), which queues the new
  // chapters of novels that download them by themselves.
  final updates = Updates(store, auto: AutoDownloads());
  return (dir: dir, store: store, sources: sources, updates: updates);
}

/// What the closed-app check's worker asks of this engine when it finds it
/// up (TomeVoice open, left in the background with Back, or reading a book
/// with no screen) instead of starting an engine of its own: two engines
/// must never write the library at once. The check runs here, on the
/// engine's one [Updates] (a check already running is joined), and what to
/// tell the reader is worded as from away from the app (see
/// describeNewChapters). Nothing when checks are turned off, or one ended
/// in the last [recent] (the app checks on opening, and on coming back).
Future<Map<String, Object?>> checkInApp({Duration recent = const Duration(minutes: 30)}) async {
  final started = DateTime.now();
  final library = await openLibrary();
  if (UpdateEvery.byName(ListeningPrefs.loaded?.updateEvery).interval == null) return const {'found': 0};
  final updates = library.updates;
  if (!updates.running.value) {
    final last = await updates.lastChecked();
    if (last != null && DateTime.now().difference(last) < recent) return const {'found': 0};
  }
  final r = await updates.checkAll();
  // Behind the screen, chapters it queued to download by themselves come
  // down while the worker waits for this answer: its run is what keeps the
  // phone from freezing TomeVoice meanwhile (the downloads' own service may
  // not start from the background). The worker gives it nine minutes.
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    await DownloadQueue.instance.settledBy(started.add(const Duration(minutes: 7)));
  }
  return describeNewChapters(library.store, r.added);
}

/// The reading places the library keeps in memory a few seconds (see
/// LibraryStore.saveCursor) are written at once when the app is put away,
/// a screen is left (a book's, most often) or reading pauses.
void _settleWhenLeft(LibraryStore store) {
  placeSettler.store = store;
  void settle() => unawaited(placeSettler.store?.settlePlaces().catchError((Object _) {}));
  PlaybackScheduler.onPaused = settle;
  _appLeft ??= AppLifecycleListener(onHide: settle, onPause: settle, onDetach: settle);
}

AppLifecycleListener? _appLeft;

/// Leaving a screen writes the places the library was keeping in memory,
/// and the reader's own save as it closes, a moment after, is written at
/// once (LibraryStore.settlePlaces). For the app's navigator (main.dart).
class PlaceSettler extends NavigatorObserver {
  LibraryStore? store;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) unawaited(store?.settlePlaces().catchError((Object _) {}));
  }
}

final placeSettler = PlaceSettler();

/// The app around the screens: storage and settings are opened once here,
/// and the menu (top left of the library) moves between them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

enum _Place { library, browse, updates, history }

class _HomeShellState extends State<HomeShell> with WhenShown<HomeShell> {
  Timer? _followTimer;
  Timer? _widgetTimer;
  StreamSubscription<Map<String, Object?>>? _widgetEvents;
  StreamSubscription<Map<String, Object?>>? _shownEvents;
  AppLifecycleListener? _lifecycle;
  bool _offering = false;

  /// The version offered since the app started: once a run is enough, even
  /// if Android's installer was backed out of.
  String? _offered;

  /// The widgets show the library and the streak: redraw them a moment after
  /// a change (places are saved often while reading).
  void _scheduleWidgets() {
    _widgetTimer?.cancel();
    _widgetTimer = Timer(const Duration(seconds: 3), () => unawaited(const SpeechService().refreshWidgets()));
  }

  /// A widget was tapped: open its book (and play it), or Stats.
  Future<void> _fromWidget() async {
    final store = _store;
    if (store == null) return;
    final launch = await const SpeechService().widgetLaunch();
    if (launch == null || !mounted) return;
    // A save as audio's notification: how far it is, over whatever shows.
    if (launch['page'] == 'export') {
      await showRunningExport(context);
      return;
    }
    if (launch['page'] == 'stats') {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StatsScreen(store: store))));
      return;
    }
    // The new-chapters notification: the Updates page.
    if (launch['page'] == 'updates') {
      Navigator.of(context).popUntil((r) => r.isFirst);
      setState(() {
        _place = _Place.updates;
        _visited.add(_Place.updates);
      });
      return;
    }
    final id = launch['book'] as String?;
    final entry = (await store.list()).where((e) => e.id == id).firstOrNull;
    if (entry == null || !mounted) return;
    // Back to the shelf first, so the book opens on top of it once.
    Navigator.of(context).popUntil((r) => r.isFirst);
    await openBook(context, store, entry, autoplay: launch['play'] == true);
  }

  @override
  void dispose() {
    _followTimer?.cancel();
    _widgetTimer?.cancel();
    unawaited(_widgetEvents?.cancel());
    unawaited(_shownEvents?.cancel());
    _lifecycle?.dispose();
    ListeningPrefs.revision.removeListener(_scheduleChecks);
    _store?.changes.removeListener(_scheduleFollow);
    _store?.placeChanges.removeListener(_scheduleFollow);
    _store?.changes.removeListener(_scheduleWidgets);
    _store?.placeChanges.removeListener(_scheduleWidgets);
    _store?.placeChanges.removeListener(_scheduleSync);
    super.dispose();
  }

  /// A place was saved: sync once the library shows again (the book was
  /// left), or soon if it already shows (a book reading on behind it).
  void _scheduleSync() => whenShown(BookSync.instance.soon);

  /// The app's accent follows the book being read: the one opened last.
  /// Debounced, since every saved place is a change to the library; and
  /// kept for when the shell shows again. A new accent rebuilds the whole
  /// app and eases its theme across for 300 ms: done behind the reader
  /// (which has the book's colours of its own anyway) it was a stutter in
  /// the reading a moment after each book opened.
  void _scheduleFollow() {
    _followTimer?.cancel();
    _followTimer = Timer(const Duration(milliseconds: 600), () => whenShown(_follow));
  }

  Future<void> _follow() async {
    final store = _store;
    if (store == null) return;
    final entries = await store.list();
    final current = entries.where((e) => e.openedAt != null).firstOrNull;
    final tint = current == null ? 0 : await TintCache.instance.resolve(current.id, current.shownCover);
    final next = tint == 0 ? null : tint;
    if (next == Skin.followTint) return;
    Skin.followTint = next;
    // The app's theme is rebuilt on this; nothing is saved.
    ListeningPrefs.revision.value++;
  }

  LibraryStore? _store;
  SourceStore? _sources;
  Updates? _updates;
  String? _error;
  _Place _place = _Place.library;

  /// The places opened so far: each is built on its first visit and kept
  /// from then on. Built all at once, Browse, Updates and History were made
  /// in the same frames as the library fading in from the opening lockup.
  final _visited = <_Place>{_Place.library};

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      // Already open if a book began reading with no screen (openLibrary).
      final (:dir, :store, :sources, :updates) = await openLibrary();
      StatsStore.instance.onSaved = _scheduleWidgets;
      if (mounted) {
        setState(() {
          _store = store;
          _sources = sources;
          _updates = updates;
        });
      }
      // A restore that was interrupted leaves its unpacked copy behind, and
      // an import a crash stopped leaves the picker's copy.
      unawaited(clearStaleRestore(Directory(dir)));
      unawaited(store.sweepIncoming());
      unawaited(sweepUpdateDownloads());
      // A restore just made starts the app again: say what it did.
      unawaited(takeRestoreReport(Directory(dir)).then((report) {
        if (report != null && mounted) showSnack(context, report, long: true);
      }));
      // A saved place can make another book the one being read, and moves
      // the widgets' progress on.
      store.changes.addListener(_scheduleFollow);
      store.placeChanges.addListener(_scheduleFollow);
      store.changes.addListener(_scheduleWidgets);
      store.placeChanges.addListener(_scheduleWidgets);
      // A widget may have opened the app.
      unawaited(_fromWidget());
      _widgetEvents = SpeechService.events.where((e) => e['type'] == 'widgetLaunch').listen((_) => _fromWidget());
      // TomeVoice opened again onto a save as audio that went on with no
      // window (swiped away from Recents): how far it is shows again.
      _shownEvents = SpeechService.events.where((e) => e['type'] == 'shown').listen((_) {
        if (mounted) unawaited(showRunningExport(context));
      });
      unawaited(_follow());
      // A fresh install may be someone moving over: from the older
      // TomeVoice (another app id), or from another phone.
      final fresh = !File('$dir/starter.json').existsSync() && (await store.list(all: true)).isEmpty;
      // Its first launch has no settings kept either: then the guide, once.
      // An update has its shelf (and the starter's mark) and settings.
      if (fresh) unawaited(_welcome(store, guide: !File('$dir/prefs.json').existsSync()));
      // A new install's first shelf: a classic and two web novels.
      unawaited(Starter.seed(Directory(dir), store, sources));
      // A newer TomeVoice: on opening, and on coming back to the app.
      Future<void>.delayed(const Duration(seconds: 8), () => _offerUpdate(Directory(dir)));
      // Fixed sources: the lists are read again at most daily while the app
      // is used, so Browse and Sources can say an update is waiting.
      Future<void>.delayed(const Duration(seconds: 6), () => _refreshSources(sources));
      // An automatic backup, when one is due (Settings > Library).
      AutoBackup.start(store);
      // Places, quotes and reading time to the reader's sync server, when
      // one is set up: on opening, and on coming back from a book.
      BookSync.instance.start(store);
      store.placeChanges.addListener(_scheduleSync);
      _lifecycle = AppLifecycleListener(onResume: () {
        unawaited(_offerUpdate(Directory(dir)));
        unawaited(_refreshSources(sources));
        unawaited(_checkChapters(updates));
      });
      // New chapters, at most as often as the reader asked, a moment after
      // the shelf is up so opening the app stays quick; on coming back to
      // the app too; and with the app closed (background_check.dart).
      Future<void>.delayed(const Duration(seconds: 4), () => _checkChapters(updates));
      unawaited(_scheduleChecks());
      ListeningPrefs.revision.addListener(_scheduleChecks);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// The interval the background check was last given, so it is only asked
  /// for again when the reader changes it.
  UpdateEvery? _scheduled;

  Future<void> _scheduleChecks() async {
    final every = UpdateEvery.byName(ListeningPrefs.loaded?.updateEvery);
    if (every == _scheduled) return;
    _scheduled = every;
    try {
      await BackgroundChecks.schedule(every);
    } on Object {
      _scheduled = null;
    }
  }

  /// Check for new chapters if one is due. A check made with the app closed
  /// that is still running stops before its next write once the app is open
  /// (background_check.dart): it is waited for, as two engines must not
  /// write the library at once, and what it left is asked then. Chapter
  /// counts such a check found reach the shelf first.
  Future<void> _checkChapters(Updates updates) async {
    try {
      for (var waited = 0; await SourcesBridge.backgroundBusy(); waited++) {
        // A site that does not answer: given up on for now (two minutes),
        // and asked again on coming back to the app.
        if (waited >= 60 || !mounted) return;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await updates.takeCounts();
      // New chapters left to download by themselves (found with the app
      // closed, or off Wi-Fi): queued, if they may go now.
      await updates.takeWaiting();
      await updates.checkIfDue(UpdateEvery.byName(ListeningPrefs.loaded?.updateEvery));
    } on Object {
      // A failed check simply runs again next time.
    }
  }

  Future<void> _refreshSources(SourceStore sources) async {
    try {
      await sources.refreshIfDue();
    } on Object {
      // Offline: the next opening tries again.
    }
  }

  /// The guide is up over the shelf (a new install's first launch).
  bool _guiding = false;

  /// A new install: on its first launch the guide, once, then the offer to
  /// restore a backup, for someone moving over (after the guide, not
  /// hidden under it).
  Future<void> _welcome(LibraryStore store, {required bool guide}) async {
    final prefs = ListeningPrefs.loaded;
    if (guide && GuideScreen.onFirstLaunch && prefs != null && !prefs.guideShown) {
      prefs.guideShown = true;
      prefs.save();
      // The shelf in first, then the guide over it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      _guiding = true;
      await showGuide(context);
      _guiding = false;
      await Future<void>.delayed(const Duration(seconds: 1));
    } else {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    _offerRestore(store);
  }

  void _offerRestore(LibraryStore store) {
    if (!mounted) return;
    showSnack(
      context,
      'Moving from another phone or an older TomeVoice? Restore your backup.',
      long: true,
      actionLabel: 'Restore',
      onAction: () => runRestore(context, store),
    );
  }

  /// A newer TomeVoice, offered in a dialog unless the reader skipped it or
  /// put it off. Asked on opening and on coming back to the app; GitHub is
  /// asked at most every few hours (see AppUpdates.check).
  Future<void> _offerUpdate(Directory root) async {
    // Not over the guide: asked again on coming back to the app.
    if (_offering || _guiding) return;
    _offering = true;
    try {
      final update = await AppUpdates.check(root);
      if (update == null || update.version == _offered || !mounted) return;
      if (!await AppUpdates.shouldOffer(root, update) || !mounted) return;
      _offered = update.version;
      await offerUpdate(context, update, root: root);
    } on Object {
      // The next opening asks again.
    } finally {
      _offering = false;
    }
  }

  void _go(_Place place) {
    Navigator.of(context).pop(); // The drawer.
    setState(() {
      _place = place;
      _visited.add(place);
    });
  }

  void _push(Widget Function(LibraryStore store) page) {
    final store = _store;
    if (store == null) return;
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(store)));
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final Widget body;
    if (store == null) {
      body = DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: Center(
          child: _error == null
              ? const BrandLockup()
              : Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Text('Could not open the library: $_error', textAlign: TextAlign.center),
                ),
        ),
      );
    } else {
      Widget place(_Place p, Widget Function() build) => _visited.contains(p) ? build() : const SizedBox.shrink();
      body = IndexedStack(
        index: _place.index,
        children: [
          LibraryScreen(store: store),
          place(_Place.browse, () => BrowseScreen(store: store, sources: _sources!)),
          place(_Place.updates, () => UpdatesScreen(store: store, updates: _updates!)),
          place(_Place.history, () => HistoryScreen(store: store)),
        ],
      );
    }
    return shownGate(PopScope(
      // Back from History goes to the library before it leaves the app.
      canPop: _place == _Place.library,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _place = _Place.library);
      },
      child: Scaffold(
        drawer: _drawer(context),
        // The library arrives from the opening lockup, and each place picked
        // in the drawer, the way a new screen does: over the same ground.
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: FadeIn(key: ValueKey(store == null), trigger: _place, child: body),
        ),
      ),
    ));
  }

  Widget _drawer(BuildContext context) => Drawer(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Gap.l),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.xl),
                child: Row(
                  children: [
                    const BrandMark(size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('TomeVoice', style: Skin.title(context, size: 26, weight: FontWeight.w500)),
                          Text('Any book, read aloud.',
                              style: Skin.title(context, size: 14, italic: true, weight: FontWeight.w400,
                                  color: Skin.inkSoftOn(context))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _item(context, Icons.auto_stories_outlined, Icons.auto_stories_rounded, 'Library',
                  selected: _place == _Place.library, onTap: () => _go(_Place.library)),
              _item(context, Icons.travel_explore_rounded, Icons.travel_explore_rounded, 'Browse',
                  selected: _place == _Place.browse, onTap: () => _go(_Place.browse)),
              // Ebook libraries (OPDS): Project Gutenberg, Standard Ebooks, Calibre.
              _item(context, Icons.local_library_outlined, Icons.local_library_rounded, 'Catalogues',
                  onTap: () => _push((s) => CataloguesScreen(store: s))),
              _item(context, Icons.new_releases_outlined, Icons.new_releases_rounded, 'Updates',
                  selected: _place == _Place.updates, onTap: () => _go(_Place.updates)),
              _item(context, Icons.history_rounded, Icons.history_rounded, 'History',
                  selected: _place == _Place.history, onTap: () => _go(_Place.history)),
              _item(context, Icons.bookmarks_outlined, Icons.bookmarks_rounded, 'Saved',
                  onTap: () => _push((s) => SavedScreen(store: s))),
              _item(context, Icons.insights_outlined, Icons.insights_rounded, 'Stats',
                  onTap: () => _push((s) => StatsScreen(store: s))),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.m),
                child: Divider(),
              ),
              _item(context, Icons.folder_copy_outlined, Icons.folder_copy_rounded, 'Categories',
                  onTap: () => _push((s) => CategoriesScreen(store: s))),
              _item(context, Icons.extension_outlined, Icons.extension_rounded, 'Sources',
                  onTap: () {
                    final sources = _sources;
                    if (sources != null) _push((_) => SourcesScreen(store: sources));
                  }),
              _item(context, Icons.settings_outlined, Icons.settings_rounded, 'Settings',
                  onTap: () => _push((s) => SettingsScreen(store: s))),
              _item(context, Icons.info_outline_rounded, Icons.info_rounded, 'About',
                  onTap: () => _push((store) => AboutScreen(root: store.root))),
            ],
          ),
        ),
      );

  Widget _item(BuildContext context, IconData icon, IconData selectedIcon, String label,
          {bool selected = false, required VoidCallback onTap}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 2),
        child: Material(
          color: selected ? Skin.amber.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
              child: Row(
                children: [
                  Icon(selected ? selectedIcon : icon,
                      color: selected ? Skin.accentInkOf(context) : Skin.inkSoftOn(context)),
                  const SizedBox(width: Gap.l),
                  Text(label,
                      style: Skin.ui(
                          size: 16,
                          weight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: Skin.inkOn(context))),
                ],
              ),
            ),
          ),
        ),
      );
}
