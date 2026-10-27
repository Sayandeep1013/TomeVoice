import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'backup.dart';
import 'backup_flow.dart';
import 'book_tint.dart';
import 'brand.dart';
import 'browse_screen.dart';
import 'categories_screen.dart';
import 'history_screen.dart';
import 'library_screen.dart';
import 'library_store.dart';
import 'marks.dart';
import 'neural_voices.dart';
import 'prefs.dart';
import 'reader_screen.dart';
import 'reading_rules.dart';
import 'saved_screen.dart';
import 'stats.dart';
import 'stats_screen.dart';
import 'settings_screen.dart';
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
    if (launch['page'] == 'stats') {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StatsScreen(store: store))));
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
    _lifecycle?.dispose();
    _store?.changes.removeListener(_scheduleFollow);
    _store?.placeChanges.removeListener(_scheduleFollow);
    _store?.changes.removeListener(_scheduleWidgets);
    _store?.placeChanges.removeListener(_scheduleWidgets);
    super.dispose();
  }

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
      final dir = await const SpeechService().outputDir();
      if (dir == null) throw const FileSystemException('No storage');
      await ListeningPrefs.load(dir);
      // Sources ask as the phone's own browser does (see Net.userAgent).
      final agent = await const SpeechService().webUserAgent();
      if (agent != null && agent.isNotEmpty) Net.userAgent = agent;
      final sources = SourceStore(Directory(dir));
      await sources.ensure();
      SourceEngine.instance.attach(sources);
      final store = LibraryStore(Directory(dir));
      await TintCache.instance.attach(Directory(dir));
      await ReadingRules.instance.attach(Directory(dir));
      await MarkStore.instance.attach(Directory(dir));
      await StatsStore.instance.attach(Directory(dir));
      NeuralVoices.instance.attach(Directory(dir));
      StatsStore.instance.onSaved = _scheduleWidgets;
      final updates = Updates(store);
      if (mounted) {
        setState(() {
          _store = store;
          _sources = sources;
          _updates = updates;
        });
      }
      // A restore that was interrupted leaves its unpacked copy behind.
      unawaited(clearStaleRestore(Directory(dir)));
      // A saved place can make another book the one being read, and moves
      // the widgets' progress on.
      store.changes.addListener(_scheduleFollow);
      store.placeChanges.addListener(_scheduleFollow);
      store.changes.addListener(_scheduleWidgets);
      store.placeChanges.addListener(_scheduleWidgets);
      // A widget may have opened the app.
      unawaited(_fromWidget());
      _widgetEvents = SpeechService.events.where((e) => e['type'] == 'widgetLaunch').listen((_) => _fromWidget());
      unawaited(_follow());
      // A fresh install may be someone moving over: from the older
      // TomeVoice (another app id), or from another phone.
      final fresh = !File('$dir/starter.json').existsSync() && (await store.list()).isEmpty;
      if (fresh) Future<void>.delayed(const Duration(seconds: 3), () => _offerRestore(store));
      // A new install's first shelf: a classic and two web novels.
      unawaited(Starter.seed(Directory(dir), store, sources));
      // A newer TomeVoice: on opening, and on coming back to the app.
      Future<void>.delayed(const Duration(seconds: 8), () => _offerUpdate(Directory(dir)));
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(_offerUpdate(Directory(dir))));
      // New chapters, at most as often as the reader asked, a moment after
      // the shelf is up so opening the app stays quick.
      Future<void>.delayed(const Duration(seconds: 4), () async {
        final every = UpdateEvery.byName(ListeningPrefs.loaded?.updateEvery);
        try {
          await updates.checkIfDue(every);
        } on Object {
          // A failed check simply runs again next time.
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
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
    if (_offering) return;
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
                      color: selected ? Skin.amber : Skin.inkSoftOn(context)),
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
