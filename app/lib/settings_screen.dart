import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'brand.dart';
import 'categories_screen.dart';
import 'library_store.dart';
import 'listen_sheet.dart';
import 'prefs.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

const _svc = SpeechService();

/// Where the project lives.
const repositoryUrl = 'https://github.com/Sayandeep1013/TomeVoice';

/// Settings, grouped the way readers look for them: how it looks, how the
/// page reads, how it sounds, how the library is kept.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  LibraryIndex? _index;

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  @override
  void initState() {
    super.initState();
    ListeningPrefs.revision.addListener(_rebuild);
    unawaited(_loadIndex());
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    ListeningPrefs.revision.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadIndex() async {
    final idx = await widget.store.index();
    if (mounted) setState(() => _index = idx);
  }

  void _change(void Function() f) {
    setState(f);
    _prefs.save();
  }

  Timer? _sampleTimer;

  /// Say a line in the voice you would hear, a moment after the last change
  /// to speed or style, so the change can be judged by ear.
  void _sample() {
    _sampleTimer?.cancel();
    _sampleTimer = Timer(const Duration(milliseconds: 650), () async {
      final catalog = VoiceCatalog.instance;
      await catalog.ensureLoaded();
      final lang = PlatformDispatcher.instance.locale.languageCode;
      final voice = _prefs.voiceByLanguage[lang] ?? catalog.bestFor(lang)?.name ?? catalog.bestFor('en')?.name;
      if (voice == null) return;
      try {
        await speakSample(
          voiceName: voice,
          text: 'This is how your books will sound.',
          settings: _prefs.settings,
          engineId: _prefs.engineId ?? catalog.engineId,
        );
      } on Object {
        // A sample that cannot play is not worth an error.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final idx = _index;
    final active = SpeechPreset.all.where((p) => p.id == _prefs.presetId).firstOrNull;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Settings', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    _Group(
                      title: 'Appearance',
                      children: [
                        const SectionTitle('Theme'),
                        const SizedBox(height: Gap.m),
                        _PaletteSwatches(
                          selected: _prefs.paletteId,
                          onPick: (id) => _change(() => _prefs.paletteId = id),
                        ),
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Light or dark'),
                        const SizedBox(height: Gap.m),
                        if (Palette.byId(_prefs.paletteId).only == null)
                          ChoiceRow<ThemeMode>(
                            options: const [
                              (ThemeMode.system, 'Phone'),
                              (ThemeMode.light, 'Light'),
                              (ThemeMode.dark, 'Dark'),
                            ],
                            value: _prefs.themeMode,
                            onChanged: (m) => _change(() => _prefs.themeMode = m),
                          )
                        else
                          Text(
                            '${Palette.byId(_prefs.paletteId).label} is always '
                            '${Palette.byId(_prefs.paletteId).only == Brightness.dark ? 'dark' : 'light'}.',
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                          ),
                      ],
                    ),
                    _Group(
                      title: 'Reading',
                      children: [
                        ReadingControls(prefs: _prefs, showTheme: false, onChanged: _rebuild),
                      ],
                    ),
                    _Group(
                      title: 'Listening',
                      children: [
                        const SectionTitle('Speed'),
                        const SizedBox(height: Gap.m),
                        SpeedControl(
                          prefs: _prefs,
                          onChanged: ({required bool restart}) {
                            _rebuild();
                            if (restart) _sample();
                          },
                        ),
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Style'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<String?>(
                          options: [for (final p in SpeechPreset.all) (p.id, p.label)],
                          value: _prefs.presetId,
                          minSegment: 200,
                          onChanged: (id) {
                            final p = SpeechPreset.all.firstWhere((x) => x.id == id);
                            _change(() {
                              _prefs.settings = p.settings;
                              _prefs.presetId = p.id;
                            });
                            _sample();
                          },
                        ),
                        const SizedBox(height: Gap.s),
                        Text(
                          active?.description ?? 'Custom: adjusted in a book’s Fine-tune.',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                        ),
                        const SizedBox(height: Gap.l),
                        _Link(
                          icon: Icons.record_voice_over_outlined,
                          title: 'Voices',
                          subtitle: 'Each book picks its voice on its own page. '
                              'Install more voices in the phone’s speech settings.',
                          onTap: () => _svc.openTtsSettings(),
                        ),
                      ],
                    ),
                    _Group(
                      title: 'Library',
                      children: [
                        _Link(
                          icon: Icons.folder_copy_outlined,
                          title: 'Categories',
                          subtitle: idx?.categories.map((c) => c.name).join(', '),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => CategoriesScreen(store: widget.store),
                            ));
                            await _loadIndex();
                          },
                        ),
                        if (idx != null && idx.categories.length > 1) ...[
                          const SizedBox(height: Gap.l),
                          const SectionTitle('New books go to'),
                          const SizedBox(height: Gap.m),
                          ChoiceRow<String>(
                            options: [for (final c in idx.categories) (c.id, c.name)],
                            value: idx.defaultCategory,
                            minSegment: 96,
                            onChanged: (id) async {
                              await widget.store.saveCategories(idx.categories, defaultCategory: id);
                              await _loadIndex();
                            },
                          ),
                        ],
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Show books as'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<bool>(
                          options: const [(false, 'List'), (true, 'Covers')],
                          value: _prefs.gridView,
                          onChanged: (v) => _change(() => _prefs.gridView = v),
                        ),
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Sort by'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<LibrarySort>(
                          options: [for (final s in LibrarySort.values) (s, s.label)],
                          value: _prefs.sort,
                          minSegment: 84,
                          onChanged: (v) => _change(() => _prefs.sort = v),
                        ),
                      ],
                    ),
                    _Group(
                      title: 'About',
                      children: [
                        _Link(
                          icon: Icons.info_outline_rounded,
                          title: 'About TomeVoice',
                          subtitle: 'Version, licences, source code',
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const AboutScreen(),
                          )),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colour themes, each drawn as a little card of its own ground and
/// accent, in the brightness it would show in now.
class _PaletteSwatches extends StatelessWidget {
  const _PaletteSwatches({required this.selected, required this.onPick});

  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final dark = Skin.isDark(context);
    // All five in one row, so none hides off the side.
    return Row(
      children: [
        for (final (i, p) in Palette.all.indexed) ...[
          if (i > 0) const SizedBox(width: Gap.s),
          Expanded(child: _swatch(context, p, p.only ?? (dark ? Brightness.dark : Brightness.light))),
        ],
      ],
    );
  }

  Widget _swatch(BuildContext context, Palette p, Brightness b) {
    final on = p.id == selected;
    final ink = b == Brightness.dark ? Skin.nightInk : Skin.ink;
    return Semantics(
      button: true,
      selected: on,
      label: '${p.label} theme',
      child: GestureDetector(
        onTap: () => onPick(p.id),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 76,
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                gradient: Skin.groundFor(b, p),
                borderRadius: BorderRadius.circular(Radii.row),
                border: Border.all(
                  color: on ? p.accent : Skin.outlineOn(context),
                  width: on ? 2.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.6,
                    child: Container(height: 4, decoration: BoxDecoration(color: ink.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 5),
                  FractionallySizedBox(
                    widthFactor: 0.85,
                    child: Container(height: 4, decoration: BoxDecoration(color: ink.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2))),
                  ),
                  const Spacer(),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                      child: on ? Icon(Icons.check_rounded, size: 13, color: p.onAccent) : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              p.label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: Skin.ui(
                size: 13,
                weight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? Skin.inkOn(context) : Skin.inkSoftOn(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled card of settings.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.s),
              child: Eyebrow(title),
            ),
            Container(
              padding: const EdgeInsets.all(Gap.l + 2),
              decoration: BoxDecoration(
                color: Skin.capsuleOn(context),
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: Skin.outlineOn(context)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ],
        ),
      );
}

/// A row that opens something.
class _Link extends StatelessWidget {
  const _Link({required this.icon, required this.title, required this.onTap, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s),
          child: Row(
            children: [
              Icon(icon, color: Skin.inkSoftOn(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
            ],
          ),
        ),
      );
}

/// The app, its version, its licence and the licences of what it is made of.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _svc.appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'About', onBack: () => Navigator.of(context).maybePop()),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.l, Gap.page, Gap.xxl),
                    children: [
                      const Center(child: BrandMark(size: 84)),
                      const SizedBox(height: Gap.l),
                      Text('TomeVoice',
                          textAlign: TextAlign.center,
                          style: Skin.title(context, size: 38, weight: FontWeight.w500)),
                      Text('Any book, read aloud.',
                          textAlign: TextAlign.center,
                          style: Skin.title(context, size: 18, italic: true, weight: FontWeight.w400,
                              color: Skin.inkSoftOn(context))),
                      const SizedBox(height: Gap.s),
                      Text(
                        _version == null ? '' : 'VERSION $_version',
                        textAlign: TextAlign.center,
                        style: Skin.meta(context),
                      ),
                      const SizedBox(height: Gap.xl),
                      Text(
                        'Reads EPUB, PDF, Word, MOBI and more aloud with the voices on your phone, '
                        'on the device. No account, no cloud. Free software under the GPL-3.0.',
                        textAlign: TextAlign.center,
                        style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                            .copyWith(height: 1.5),
                      ),
                      const SizedBox(height: Gap.xl),
                      _Link(
                        icon: Icons.code_rounded,
                        title: 'Source code',
                        subtitle: 'github.com/Sayandeep1013/TomeVoice',
                        onTap: () => _svc.openUrl(repositoryUrl),
                      ),
                      _Link(
                        icon: Icons.new_releases_outlined,
                        title: 'Releases',
                        subtitle: 'Download the latest version',
                        onTap: () => _svc.openUrl('$repositoryUrl/releases/latest'),
                      ),
                      _Link(
                        icon: Icons.gavel_rounded,
                        title: 'Open-source licences',
                        subtitle: 'Fonts and libraries TomeVoice is made with',
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'TomeVoice',
                          applicationVersion: _version,
                          applicationLegalese: 'GPL-3.0',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
