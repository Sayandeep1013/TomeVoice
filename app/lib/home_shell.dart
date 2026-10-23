import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'categories_screen.dart';
import 'history_screen.dart';
import 'library_screen.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'settings_screen.dart';
import 'speech_service.dart';
import 'theme.dart';

/// The app around the screens: storage and settings are opened once here,
/// and the menu (top left of the library) moves between them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

enum _Place { library, history }

class _HomeShellState extends State<HomeShell> {
  LibraryStore? _store;
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
      if (mounted) setState(() => _store = LibraryStore(Directory(dir)));
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
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
              _item(context, Icons.history_rounded, Icons.history_rounded, 'History',
                  selected: _place == _Place.history, onTap: () => _go(_Place.history)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.m),
                child: Divider(),
              ),
              _item(context, Icons.folder_copy_outlined, Icons.folder_copy_rounded, 'Categories',
                  onTap: () => _push((s) => CategoriesScreen(store: s))),
              _item(context, Icons.settings_outlined, Icons.settings_rounded, 'Settings',
                  onTap: () => _push((s) => SettingsScreen(store: s))),
              _item(context, Icons.info_outline_rounded, Icons.info_rounded, 'About',
                  onTap: () => _push((_) => const AboutScreen())),
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
