import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'backup.dart';
import 'brand.dart';
import 'browse_screen.dart';
import 'categories_screen.dart';
import 'history_screen.dart';
import 'library_screen.dart';
import 'library_store.dart';
import 'prefs.dart';
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

/// The app around the screens: storage and settings are opened once here,
/// and the menu (top left of the library) moves between them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

enum _Place { library, browse, updates, history }

class _HomeShellState extends State<HomeShell> {
  LibraryStore? _store;
  SourceStore? _sources;
  Updates? _updates;
  String? _error;
  _Place _place = _Place.library;

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
      // A new install's first shelf: a classic and two web novels.
      unawaited(Starter.seed(Directory(dir), store, sources));
      // A newer TomeVoice, said once per version.
      Future<void>.delayed(const Duration(seconds: 8), () => _tellAboutUpdate(Directory(dir)));
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

  Future<void> _tellAboutUpdate(Directory root) async {
    final update = await AppUpdates.check(root);
    if (update == null || !mounted || await AppUpdates.told(root, update)) return;
    if (!mounted) return;
    showSnack(
      context,
      'TomeVoice ${update.version} is out.',
      long: true,
      actionLabel: 'See what\'s new',
      onAction: () => const SpeechService().openUrl(update.url),
    );
    await AppUpdates.markTold(root, update);
  }

  void _go(_Place place) {
    Navigator.of(context).pop(); // The drawer.
    setState(() => _place = place);
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
      body = IndexedStack(
        index: _place.index,
        children: [
          LibraryScreen(store: store),
          BrowseScreen(store: store, sources: _sources!),
          UpdatesScreen(store: store, updates: _updates!),
          HistoryScreen(store: store),
        ],
      );
    }
    return PopScope(
      // Back from History goes to the library before it leaves the app.
      canPop: _place == _Place.library,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _place = _Place.library);
      },
      child: Scaffold(
        drawer: _drawer(context),
        body: body,
      ),
    );
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
