import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'app_update.dart';
import 'auto_backup.dart';
import 'backup_flow.dart';
import 'brand.dart';
import 'categories_screen.dart';
import 'folders.dart';
import 'library_store.dart';
import 'listen_sheet.dart';
import 'neural_screen.dart';
import 'noveldokusha_import.dart';
import 'prefs.dart';
import 'problem_report.dart';
import 'relayout.dart';
import 'rules_screen.dart';
import 'sources/source_engine.dart';
import 'secret_shelf.dart';
import 'sources_screen.dart';
import 'stats_screen.dart' show addWidget;
import 'speech_service.dart';
import 'sync.dart';
import 'sync_screen.dart';
import 'theme.dart';
import 'ui.dart';
import 'updates.dart';
import 'update_flow.dart';
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

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  LibraryIndex? _index;
  bool _tellUpdates = true;

  /// The screen as it looked before a theme change, fading out over the
  /// screen as it looks now: a true cross-fade, where a theme animation
  /// alone would snap every colour the app draws itself.
  ui.Image? _before;
  final _screen = GlobalKey();
  late final _fade = AnimationController(vsync: this, duration: Motion.page)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _forgetBefore();
    });

  ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  @override
  void initState() {
    super.initState();
    ListeningPrefs.revision.addListener(_rebuild);
    unawaited(_loadIndex());
    AppUpdates.enabled(widget.store.root).then((on) {
      if (mounted) setState(() => _tellUpdates = on);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    _before?.dispose();
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

  /// A change of palette or of light and dark, cross-faded.
  void _changeTheme(void Function() f) {
    final boundary = _screen.currentContext?.findRenderObject();
    if (!Motion.reduced(context) && boundary is RenderRepaintBoundary) {
      try {
        final shot = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context));
        _before?.dispose();
        _before = shot;
        _fade.forward(from: 0);
      } on Object {
        // No picture, no cross-fade: the change still happens.
      }
    }
    _change(f);
  }

  void _forgetBefore() {
    if (!mounted) return;
    setState(() {
      _before?.dispose();
      _before = null;
    });
  }

  /// Automatic backups on or off. On needs a folder: picked first, and
  /// left off if none is.
  Future<void> _setBackupEvery(BackupEvery every) async {
    if (every != BackupEvery.off && _prefs.backupFolder == null && !await _pickBackupFolder()) return;
    _change(() => _prefs.backupEvery = every.name);
    if (every != BackupEvery.off) unawaited(AutoBackup.runIfDue(widget.store));
  }

  /// The folder backups go to. True if one was picked.
  Future<bool> _pickBackupFolder() async {
    PickedFolder? folder;
    try {
      folder = await const Folders().pick();
    } on PlatformException catch (e) {
      if (mounted) showSnack(context, 'The folder could not be used: ${e.message ?? e.code}');
    }
    if (folder == null || !mounted) return false;
    final picked = folder;
    _change(() => _prefs.backupFolder = picked);
    AutoBackup.problem.value = null;
    // A backup is a plain file, as one saved by hand: it carries the secret
    // shelf's books too.
    if ((await widget.store.index(all: true)).categories.any((c) => c.secret) && mounted) {
      showSnack(context, 'Backups include your secret shelf. Anyone who has one can open its books.', long: true);
    }
    return true;
  }

  /// Pick a NovelDokusha backup and bring its web novels into the library.
  Future<void> _importNovelDokusha() async {
    final List<PickedFile> files;
    try {
      files = await _svc.pickDocuments();
    } on Object catch (e) {
      debugPrint('File picker failed: $e');
      if (mounted) showSnack(context, 'The file picker could not open. Try again.');
      return;
    }
    if (files.isEmpty || !mounted) return;
    final progress = ValueNotifier<String>('Reading the backup…');
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Importing'),
        content: Row(
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: Gap.l),
            Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, v, __) => Text(v))),
          ],
        ),
      ),
    ));
    String message;
    try {
      final json = await _svc.readNovelDokushaBackup(files.first.path);
      final report = await importNovelDokushaJson(widget.store, SourceEngine.instance.store, json,
          onProgress: (title, done, total) => progress.value = '$title (${done + 1} of $total)');
      message = report.novels == 0
          ? 'That backup has no web novels in its library.'
          : 'Imported ${report.novels} ${report.novels == 1 ? 'novel' : 'novels'} '
              'with ${report.chapters} downloaded ${report.chapters == 1 ? 'chapter' : 'chapters'}.'
              '${report.unmatched.isEmpty ? '' : ' Install a source for ${report.unmatched.join(', ')} to get new chapters.'}';
    } on Object catch (e) {
      message = e is PlatformException ? (e.message ?? e.code) : '$e';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    showSnack(context, message, long: true);
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
      final usual = catalog.byName(_prefs.voiceByLanguage[lang]);
      final voice = (usual?.language == lang ? usual?.name : null) ??
          catalog.bestFor(lang)?.name ??
          catalog.bestFor('en')?.name;
      if (voice == null) return;
      try {
        await speakSample(
          voiceName: voice,
          text: 'This is how your books will sound.',
          settings: _prefs.settingsFor(voice),
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
    final before = _before;
    return Stack(
      children: [
        RepaintBoundary(key: _screen, child: _body(context, idx, active)),
        if (before != null)
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: ReverseAnimation(_fade.drive(CurveTween(curve: Motion.emphasized))),
                child: RawImage(image: before, fit: BoxFit.fill),
              ),
            ),
          ),
      ],
    );
  }

  Widget _body(BuildContext context, LibraryIndex? idx, SpeechPreset? active) {
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
                          onPick: (id) => _changeTheme(() => _prefs.paletteId = id),
                        ),
                        const SizedBox(height: Gap.l),
                        SwitchRow(
                          title: 'Colours from book covers',
                          subtitle: 'Each book takes the colour of its cover, and the app the colour '
                              'of the book you are reading',
                          value: _prefs.bookColours,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _changeTheme(() => _prefs.bookColours = v),
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
                            onChanged: (m) => _changeTheme(() => _prefs.themeMode = m),
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
                        SwitchRow(
                          title: 'Keep reading after leaving a book',
                          subtitle: 'Back goes to your library while the voice reads on. Pause it from the '
                              "library's player or the card in the notification shade",
                          value: _prefs.keepReading,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.keepReading = v),
                        ),
                        const ScreenOffRow(),
                        const SizedBox(height: Gap.l),
                        SwitchRow(
                          title: 'Read notes aloud',
                          subtitle: 'Footnotes and endnotes are read where they stand in the book. '
                              'The little numbers pointing at them stay silent',
                          value: _prefs.notesAloud,
                          padding: EdgeInsets.zero,
                          onChanged: (v) {
                            _change(() => _prefs.notesAloud = v);
                            // A book reading on goes on in the new layout.
                            unawaited(relayReadingBook());
                          },
                        ),
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Style'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<String?>(
                          options: [for (final p in SpeechPreset.all) (p.id, p.label)],
                          value: _prefs.presetId,
                          minSegment: 96,
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
                          icon: Icons.auto_awesome_rounded,
                          title: 'Natural voices',
                          subtitle: 'Voices that sound like people, made on your phone',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const NeuralVoicesScreen()),
                          ),
                        ),
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
                          icon: Icons.extension_outlined,
                          title: 'Sources',
                          subtitle: 'Where web novels come from: add source lists, install sites',
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => SourcesScreen(store: SourceEngine.instance.store),
                          )),
                        ),
                        _Link(
                          icon: Icons.rule_rounded,
                          title: 'Reading rules',
                          subtitle: 'Words said your way, and lines left out of web novels',
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => RulesScreen(
                              bookTitles: {for (final e in idx?.entries ?? const <LibraryEntry>[]) e.id: e.title},
                            ),
                          )),
                        ),
                        _Link(
                          icon: Icons.lock_outline_rounded,
                          title: 'Secret shelf',
                          subtitle: 'Books that only your fingerprint, face or phone PIN opens',
                          onTap: () => showSecretShelfSheet(context, widget.store),
                        ),
                        _Link(
                          icon: Icons.backup_outlined,
                          title: 'Back up library',
                          subtitle: 'Your books, places, categories and settings in one file',
                          onTap: () => runBackup(context, widget.store),
                        ),
                        _Link(
                          icon: Icons.settings_backup_restore_rounded,
                          title: 'Restore a backup',
                          subtitle: 'From a TomeVoice backup on this phone or in Drive',
                          onTap: () => runRestore(context, widget.store),
                        ),
                        const SizedBox(height: Gap.l),
                        const SectionTitle('Back up automatically'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<BackupEvery>(
                          options: [for (final e in BackupEvery.values) (e, e.label)],
                          value: BackupEvery.byName(_prefs.backupEvery),
                          onChanged: (e) => unawaited(_setBackupEvery(e)),
                        ),
                        if (BackupEvery.byName(_prefs.backupEvery) != BackupEvery.off) ...[
                          const SizedBox(height: Gap.s),
                          _Link(
                            icon: Icons.folder_outlined,
                            title: _prefs.backupFolder?.name ?? 'Choose a folder',
                            subtitle: 'Where the backups go, when TomeVoice opens and one is due. '
                                'The last $autoBackupsKept are kept',
                            onTap: () => unawaited(_pickBackupFolder()),
                          ),
                          SwitchRow(
                            title: 'With downloaded chapters',
                            subtitle: 'Bigger backups; web novel chapters otherwise download again after a restore',
                            value: _prefs.backupChapters,
                            padding: EdgeInsets.zero,
                            onChanged: (v) => _change(() => _prefs.backupChapters = v),
                          ),
                          _AutoBackupStatus(store: widget.store, prefs: _prefs),
                        ],
                        const SizedBox(height: Gap.s),
                        _Link(
                          icon: Icons.sync_rounded,
                          title: 'Sync',
                          subtitle: BookSync.on
                              ? 'On: places, quotes and reading time'
                              : 'Off. Keep places and quotes the same on your phones, or with KOReader',
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => SyncScreen(store: widget.store),
                          )),
                        ),
                        _Link(
                          icon: Icons.move_to_inbox_outlined,
                          title: 'Import from NovelDokusha',
                          subtitle: 'Bring your web novels across from a NovelDokusha backup (.zip)',
                          onTap: _importNovelDokusha,
                        ),
                        const SizedBox(height: Gap.l),
                        const SectionTitle('Check for new chapters'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<String>(
                          options: [for (final u in UpdateEvery.values) (u.name, u.label.replaceAll('Every ', ''))],
                          value: UpdateEvery.byName(_prefs.updateEvery).name,
                          minSegment: 76,
                          onChanged: (v) => _change(() => _prefs.updateEvery = v),
                        ),
                        const SizedBox(height: Gap.xs),
                        Text(
                          'Web novels in your library are checked when TomeVoice opens, at most this often.',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                        ),
                        const SizedBox(height: Gap.l),
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
                      title: 'Home screen',
                      children: [
                        for (final (kind, icon, title, sub) in const [
                          ('player', Icons.album_outlined, 'Now reading', 'The cover in a ring of dots, and play'),
                          ('playerStamp', Icons.local_post_office_outlined, 'Now reading, stamp', 'The same, cut like a postage stamp'),
                          ('playerWide', Icons.view_agenda_outlined, 'Now reading, wide', 'Cover, chapter, progress and play'),
                          ('streak', Icons.local_fire_department_outlined, 'Streak', 'Your streak and this week'),
                          ('streakWide', Icons.grid_view_rounded, 'Streak, wide', 'Your streak and eighteen weeks'),
                        ])
                          _Link(icon: icon, title: title, subtitle: sub, onTap: () => addWidget(context, kind)),
                      ],
                    ),
                    _Group(
                      title: 'About',
                      children: [
                        SwitchRow(
                          title: 'Tell me about new versions',
                          subtitle: 'Asks GitHub every few hours whether a newer TomeVoice is out',
                          value: _tellUpdates,
                          padding: EdgeInsets.zero,
                          onChanged: (v) {
                            setState(() => _tellUpdates = v);
                            unawaited(AppUpdates.setEnabled(widget.store.root, v));
                          },
                        ),
                        const SizedBox(height: Gap.s),
                        _Link(
                          icon: Icons.info_outline_rounded,
                          title: 'About TomeVoice',
                          subtitle: 'Version, licences, source code',
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => AboutScreen(root: widget.store.root),
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
              duration: Motion.of(context, const Duration(milliseconds: 160)),
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

/// When the last automatic backup was made, or why it could not be, and
/// Back up now.
class _AutoBackupStatus extends StatelessWidget {
  const _AutoBackupStatus({required this.store, required this.prefs});

  final LibraryStore store;
  final ListeningPrefs prefs;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([AutoBackup.problem, AutoBackup.running]),
        builder: (context, _) {
          final problem = AutoBackup.problem.value;
          final last = prefs.lastBackup;
          final said = AutoBackup.running.value
              ? 'Backing up…'
              : problem ??
                  (last == null
                      ? 'No backup made yet.'
                      : 'Last backup ${MaterialLocalizations.of(context).formatMediumDate(last)}, '
                          '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(last))}.');
          return Row(
            children: [
              Expanded(
                child: Text(
                  said,
                  style: Skin.ui(
                    size: 13.5,
                    weight: problem == null ? FontWeight.w400 : FontWeight.w600,
                    color: problem == null ? Skin.inkFaintOn(context) : Skin.inkOn(context),
                  ),
                ),
              ),
              TextButton(
                onPressed: AutoBackup.running.value ? null : () => unawaited(AutoBackup.backUpNow(store)),
                child: const Text('Back up now'),
              ),
            ],
          );
        },
      );
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

/// Phone makers known to stop apps reading in the background in ways of
/// their own, beyond Android's battery saving (dontkillmyapp.com ranks them):
/// the name the phone goes by, and the maker's page there. Brand first: a
/// Redmi is made by Xiaomi. Null for the rest (Pixel, Nothing and others that
/// behave as Android does; dontkillmyapp.com has no page for Honor, whose
/// apps the Huawei page covers).
({String name, String page})? aggressiveMaker(String maker, String brand) {
  const pages = {
    'xiaomi': ('Xiaomi', 'xiaomi'),
    'redmi': ('Redmi', 'xiaomi'),
    'poco': ('POCO', 'xiaomi'),
    'samsung': ('Samsung', 'samsung'),
    'oppo': ('OPPO', 'oppo'),
    'realme': ('realme', 'realme'),
    'oneplus': ('OnePlus', 'oneplus'),
    'vivo': ('vivo', 'vivo'),
    'iqoo': ('iQOO', 'vivo'),
    'huawei': ('Huawei', 'huawei'),
    'honor': ('Honor', 'huawei'),
  };
  for (final key in [brand.trim().toLowerCase(), maker.trim().toLowerCase()]) {
    final hit = pages[key];
    if (hit != null) return (name: hit.$1, page: hit.$2);
  }
  return null;
}

/// Settings > Listening: whether Android lets TomeVoice read on with the
/// screen off, and the way to its setting (the phone's own question, or its
/// list of apps). On phones whose makers stop apps in ways of their own as
/// well, a line to the maker's page on dontkillmyapp.com, which says what
/// else to turn off. Nothing shows where the phone cannot say (tests).
class ScreenOffRow extends StatefulWidget {
  const ScreenOffRow({super.key});

  @override
  State<ScreenOffRow> createState() => _ScreenOffRowState();
}

class _ScreenOffRowState extends State<ScreenOffRow> {
  ({bool exempt, String maker, String brand})? _status;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // Back from Android's setting: show what it says now.
    _life = AppLifecycleListener(onResume: () => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final status = await _svc.batteryStatus();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _open() async {
    if (!await _svc.openBatterySettings() && mounted) {
      showSnack(context, 'This phone has no battery setting TomeVoice can open.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final maker = aggressiveMaker(status.maker, status.brand);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Link(
            icon: status.exempt ? Icons.bedtime_outlined : Icons.battery_alert_outlined,
            title: 'Keep reading with the screen off',
            subtitle: status.exempt
                ? 'Allowed: battery saving leaves TomeVoice alone'
                : 'Battery saving may stop the voice with the screen off. Tap to allow TomeVoice',
            onTap: _open,
          ),
          if (maker != null)
            // In line with the row's text, under its icon's gap.
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Semantics(
                link: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.row),
                  onTap: () => _svc.openUrl('https://dontkillmyapp.com/${maker.page}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Text(
                      '${maker.name} phones can also stop apps in ways of their own: '
                      'dontkillmyapp.com/${maker.page}',
                      style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The app, its version, its licence and the licences of what it is made of.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.root});

  /// The library folder, where the update check keeps its state.
  final Directory? root;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;
  bool _checking = false;

  Future<void> _checkForUpdate() async {
    final root = widget.root;
    if (root == null || _checking) return;
    setState(() => _checking = true);
    try {
      final update = await AppUpdates.check(root, force: true);
      if (!mounted) return;
      if (update == null) {
        showSnack(context, 'This is the latest TomeVoice.');
      } else {
        unawaited(offerUpdate(context, update));
      }
    } on Object {
      if (mounted) showSnack(context, 'Could not reach GitHub. Check the internet connection.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

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
                      if (widget.root != null)
                        _Link(
                          icon: Icons.system_update_outlined,
                          title: _checking ? 'Checking…' : 'Check for updates',
                          subtitle: 'New versions are published on GitHub',
                          onTap: _checkForUpdate,
                        ),
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
                        icon: Icons.bug_report_outlined,
                        title: 'Report a problem',
                        subtitle: 'See every word it would say, then send it yourself on GitHub',
                        onTap: () => unawaited(showProblemReport(context)),
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
                      // No Support row until there is a page to point it
                      // at: a row that did nothing on a tap read as broken.
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
