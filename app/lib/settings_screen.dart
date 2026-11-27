import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary, ScrollCacheExtent;
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'app_update.dart';
import 'auto_backup.dart';
import 'backup_flow.dart';
import 'brand.dart';
import 'categories_screen.dart';
import 'folders.dart';
import 'guide.dart';
import 'library_store.dart';
import 'listen_sheet.dart';
import 'journal_questions_screen.dart';
import 'neural_screen.dart';
import 'novel_updates.dart';
import 'noveldokusha_import.dart';
import 'own_colours.dart';
import 'own_colours_sheet.dart';
import 'download_queue.dart' show DownloadPace;
import 'play_update.dart';
import 'prefs.dart';
import 'problem_report.dart';
import 'relayout.dart';
import 'rules_screen.dart';
import 'scene.dart';
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
import 'tap_log_sheet.dart';
import 'voice_log_sheet.dart';
import 'voices.dart';
import 'wallpaper_colours.dart';
import 'store_build.dart';

const _svc = SpeechService();

/// Where the project lives.
const repositoryUrl = 'https://github.com/Sayandeep1013/TomeVoice';

/// The privacy policy, on the site. The Play version's is a page of its
/// own (the publisher's Google Site), about that version only.
const privacyUrl = playBuild
    ? 'https://sites.google.com/view/tomevoice'
    : 'https://sayandeep1013.github.io/TomeVoice/privacy.html';

/// The source code of TomeVoice [version], as an archive: what the GPL asks
/// the Play version to point to, said on its licences page.
String sourceArchiveUrl(String? version) => version == null || version.isEmpty
    ? '$repositoryUrl/archive/refs/heads/main.zip'
    : '$repositoryUrl/archive/refs/tags/v${version.split('+').first}.zip';

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

  /// Whether there is a secret shelf, open or shut: automatic backups leave
  /// it out unless the reader lets it in.
  bool _secretShelf = false;

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
    // The wallpaper's theme shows once the phone has said it has colours.
    WallpaperColours.current.addListener(_rebuild);
    unawaited(_loadIndex());
    AppUpdates.enabled(widget.store.root).then((on) {
      if (mounted) setState(() => _tellUpdates = on);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    _before?.dispose();
    _findText.dispose();
    _sampleTimer?.cancel();
    ListeningPrefs.revision.removeListener(_rebuild);
    WallpaperColours.current.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadIndex() async {
    final idx = await widget.store.index();
    final secret = (await widget.store.index(all: true)).categories.any((c) => c.secret);
    if (mounted) {
      setState(() {
        _index = idx;
        _secretShelf = secret;
      });
    }
  }

  void _change(void Function() f) {
    setState(f);
    _prefs.save();
  }

  // Finding a setting: what is typed, the settings list (whose words are
  // read for it), and what matched, each with its section and where it is.
  String _find = '';
  bool _showFound = false;
  final _findText = TextEditingController();
  final _list = GlobalKey();
  List<({String text, String group, Element at})> _found = const [];

  void _onFind(String q) {
    setState(() {
      _find = q;
      _showFound = q.trim().isNotEmpty;
    });
    // Every row built first (the list keeps them all while finding), then
    // read.
    WidgetsBinding.instance.addPostFrameCallback((_) => _collect());
  }

  /// The words of every setting on the screen that hold what was typed,
  /// each once, with the section it is in: read from the settings as they
  /// stand, so a new one is found without being listed anywhere.
  void _collect() {
    if (!mounted) return;
    final q = _find.trim().toLowerCase();
    final root = _list.currentContext as Element?;
    if (root == null || q.isEmpty) {
      setState(() => _found = const []);
      return;
    }
    final out = <({String text, String group, Element at})>[];
    final seen = <String>{};
    void visit(Element e, String group) {
      final w = e.widget;
      if (w is _Found || w is SearchField) return;
      final g = w is _Group ? w.title : group;
      final text = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
      if (text != null && g.isNotEmpty) {
        final t = text.trim();
        if (t.length < 140 && wordsMatch(t, q) && seen.add('$g/$t')) out.add((text: t, group: g, at: e));
      }
      e.visitChildren((c) => visit(c, g));
    }

    root.visitChildren((c) => visit(c, ''));
    // Short ones (a setting's name) before long ones (its explanation).
    out.sort((a, b) => a.text.length.compareTo(b.text.length));
    setState(() => _found = out.take(40).toList());
  }

  /// A match tapped: the list scrolled to it, the matches folded away (the
  /// words stay, so the list keeps its rows and the place holds).
  void _goTo(({String text, String group, Element at}) f) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _showFound = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final at = f.at.mounted ? f.at : _locate(f.text);
      if (at == null) return;
      unawaited(Scrollable.ensureVisible(at,
          alignment: 0.2, duration: Motion.of(context, Motion.page), curve: Motion.out));
    });
  }

  /// The words [text] where they stand in the list now.
  Element? _locate(String text) {
    Element? hit;
    void visit(Element e) {
      if (hit != null || e.widget is _Found) return;
      final w = e.widget;
      if (w is Text && (w.data ?? w.textSpan?.toPlainText())?.trim() == text) {
        hit = e;
        return;
      }
      e.visitChildren(visit);
    }

    (_list.currentContext as Element?)?.visitChildren(visit);
    return hit;
  }

  void _clearFind() {
    _findText.clear();
    _onFind('');
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

  /// Your own colours: the editor opens on the ones kept (or where a reader
  /// starts), and what it gives back is kept and shown.
  Future<void> _pickOwn() async {
    final picked = await showOwnColours(context, OwnColours.of(_prefs));
    if (picked == null || !mounted) return;
    _changeTheme(() {
      picked.saveTo(_prefs);
      _prefs.paletteId = 'own';
    });
  }

  /// The designer themes, each drawn as a little page in its own colours;
  /// the one picked is put on, cross-faded, as the swatches above are.
  Future<void> _pickDesigner() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DesignerSheet(selected: chosenPaletteId(_prefs)),
    );
    if (picked == null || !mounted) return;
    _changeTheme(() => _prefs.paletteId = picked);
  }

  /// What "Light or dark" says of a theme shown only one way.
  String _alwaysSaid(Palette p) {
    final way = p.only == Brightness.dark ? 'dark' : 'light';
    return _prefs.paletteId == 'own' ? 'Your own colours are $way, as their page is.' : '${p.label} is always $way.';
  }

  /// Automatic backups on or off. On needs a folder: picked first, and
  /// left off if none is.
  Future<void> _setBackupEvery(BackupEvery every) async {
    if (every != BackupEvery.off && _prefs.backupFolder == null && !await _pickBackupFolder()) return;
    _change(() => _prefs.backupEvery = every.name);
    if (every != BackupEvery.off) unawaited(AutoBackup.runIfDue(widget.store));
  }

  /// The secret shelf in automatic backups, or out of them. In only once the
  /// reader has been told what that means, and said yes.
  Future<void> _setBackupSecret(bool on) async {
    if (on &&
        !await confirm(
          context,
          title: 'Back up the secret shelf too?',
          body: 'Automatic backups are plain files. Anyone who has one can open the books on your secret shelf, '
              'and read what you saved from them.',
          action: 'Back it up',
        )) {
      return;
    }
    if (mounted) _change(() => _prefs.backupSecret = on);
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
    // A backup is a plain file, as one saved by hand: let in, the secret
    // shelf's books are in each one (they are left out otherwise).
    if (_prefs.backupSecret && _secretShelf && mounted) {
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
      body: Ground(
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Settings', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  key: _list,
                  // While finding, every row is kept built, so its words can
                  // be read and it can be scrolled to.
                  scrollCacheExtent: _find.trim().isEmpty ? null : const ScrollCacheExtent.pixels(100000),
                  // Closer to the screen's edges than other pages: the
                  // cards line up with the back button and the rows inside
                  // them get the room.
                  padding: EdgeInsets.fromLTRB(
                      Gap.m, 0, Gap.m, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 0),
                      child: SearchField(
                        hint: 'Find a setting',
                        controller: _findText,
                        onChanged: _onFind,
                        onClear: _find.isEmpty ? null : _clearFind,
                      ),
                    ),
                    // Always this one place in the list (empty when nothing is
                    // being found), so the rows after it keep theirs.
                    if (_showFound)
                      _Found(
                        found: _found,
                        query: _find.trim(),
                        onPick: _goTo,
                      )
                    else
                      const SizedBox.shrink(),
                    _Group(
                      title: 'Appearance',
                      children: [
                        const SectionTitle('Theme'),
                        const SizedBox(height: Gap.m),
                        _PaletteSwatches(
                          selected: chosenPaletteId(_prefs),
                          own: OwnColours.of(_prefs).made.palette,
                          wallpaper: WallpaperColours.palette,
                          onPick: (id) => _changeTheme(() => _prefs.paletteId = id),
                          onOwn: _pickOwn,
                        ),
                        if (_prefs.paletteId == 'own')
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(onPressed: _pickOwn, child: const Text('Change your colours')),
                          ),
                        // The designer themes, apart and folded into one
                        // row: each a reading place or a material, seen in
                        // a picker of previews one tap away.
                        const SizedBox(height: Gap.l),
                        _DesignerRow(
                          selected: chosenPaletteId(_prefs),
                          onOpen: _pickDesigner,
                        ),
                        const SizedBox(height: Gap.l),
                        SwitchRow(
                          title: 'Colours from book covers',
                          subtitle: chosenPalette(_prefs).scene != null
                              ? 'Off in a scene: ${chosenPalette(_prefs).label} keeps its own light'
                              : 'Each book takes the colour of its cover, and the app the colour '
                                  'of the book you are reading',
                          value: _prefs.bookColours,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _changeTheme(() => _prefs.bookColours = v),
                        ),
                        const SizedBox(height: Gap.xl),
                        const SectionTitle('Light or dark'),
                        const SizedBox(height: Gap.m),
                        if (chosenPalette(_prefs).only == null)
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
                            _alwaysSaid(chosenPalette(_prefs)),
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                          ),
                        const SizedBox(height: Gap.l),
                        SwitchRow(
                          title: 'Animations',
                          subtitle: !_prefs.animations
                              ? 'Off: everything changes at once and the scenes stand still'
                              : WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations
                                  ? 'Off on this phone: its own setting removes animations'
                                  : 'Screens, sheets and presses move, and the scenes come alive',
                          value: _prefs.animations,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.animations = v),
                        ),
                        if (Skin.sceneOf(context) != null) ...[
                          const SizedBox(height: Gap.l),
                          SwitchRow(
                            title: 'Scene behind the page',
                            subtitle: _prefs.sceneOnPage
                                ? "The scene's painting under the words, softened so they read (with the app's own page tone)"
                                : 'Off: the page you read is plain',
                            value: _prefs.sceneOnPage,
                            padding: EdgeInsets.zero,
                            onChanged: (v) => _change(() => _prefs.sceneOnPage = v),
                          ),
                        ],
                      ],
                    ),
                    _Group(
                      title: 'Reading',
                      children: [
                        ReadingControls(prefs: _prefs, showTheme: false, onChanged: _rebuild),
                      ],
                    ),
                    _Group(
                      title: 'Journal',
                      children: [
                        _Link(
                          icon: Icons.edit_note_rounded,
                          title: 'Journal questions',
                          subtitle: 'What the journal asks when you write: change them, add your own',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const JournalQuestionsScreen()),
                          ),
                        ),
                        SwitchRow(
                          title: "Ask at a chapter's end",
                          subtitle: 'A quiet offer to write about the chapter just read. The voice reads on',
                          value: _prefs.journalAsk,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.journalAsk = v),
                        ),
                        SwitchRow(
                          title: 'Interview me',
                          subtitle: "At a chapter's end the reading waits, the voice asks your journal questions, "
                              'and what you answer aloud is written down. Then it reads on',
                          value: _prefs.journalInterview,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.journalInterview = v),
                        ),
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
                          subtitle: 'Words said your way, shared lists of them, and what the voice skips',
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
                          onTap: () async {
                            await showSecretShelfSheet(context, widget.store);
                            // Made, or turned back into an ordinary shelf.
                            await _loadIndex();
                          },
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
                          if (_secretShelf)
                            SwitchRow(
                              title: 'With the secret shelf',
                              subtitle: _prefs.backupSecret
                                  ? 'Anyone who has a backup file can open its books'
                                  : 'Left out: its books, quotes and places are not in these backups',
                              value: _prefs.backupSecret,
                              padding: EdgeInsets.zero,
                              onChanged: (v) => unawaited(_setBackupSecret(v)),
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
                        const SectionTitle('Download speed'),
                        const SizedBox(height: Gap.m),
                        ChoiceRow<String>(
                          options: [for (final p in DownloadPace.values) (p.name, p.label)],
                          value: DownloadPace.byName(_prefs.downloadPace).name,
                          minSegment: 76,
                          onChanged: (v) => _change(() => _prefs.downloadPace = v),
                        ),
                        const SizedBox(height: Gap.xs),
                        Text(
                          'How quickly chapters come from a site, for downloads and memories. Fast gets a long '
                          'novel sooner, but a site may slow you down or turn you away for a while.',
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
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
                        const SizedBox(height: Gap.s),
                        SwitchRow(
                          title: 'Only while charging',
                          subtitle: 'With TomeVoice closed, novels are checked only while the phone charges',
                          value: _prefs.checkCharging,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.checkCharging = v),
                        ),
                        SwitchRow(
                          title: "Only novels I've begun",
                          subtitle: 'One added but never opened is not checked',
                          value: _prefs.checkStartedOnly,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.checkStartedOnly = v),
                        ),
                        SwitchRow(
                          title: 'Find on NovelUpdates',
                          subtitle: NovelUpdates.about,
                          value: _prefs.novelUpdates,
                          padding: EdgeInsets.zero,
                          onChanged: (v) => _change(() => _prefs.novelUpdates = v),
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
                          subtitle: playBuild
                              ? 'Asks Google Play whether a newer TomeVoice is out, and updates it here'
                              : 'Asks GitHub every few hours whether a newer TomeVoice is out',
                          value: _tellUpdates,
                          padding: EdgeInsets.zero,
                          onChanged: (v) {
                            setState(() => _tellUpdates = v);
                            unawaited(AppUpdates.setEnabled(widget.store.root, v));
                          },
                        ),
                        const SizedBox(height: Gap.s),
                        _Link(
                          icon: Icons.tips_and_updates_outlined,
                          title: 'Show the guide again',
                          subtitle: 'Bringing books in, play, the voices and the page',
                          onTap: () => unawaited(showGuide(context)),
                        ),
                        _Link(
                          icon: Icons.school_outlined,
                          title: 'How the AI works',
                          subtitle: 'Keys, the memory, Talk, the graph and spoilers',
                          onTap: () => unawaited(showAiGuide(context)),
                        ),
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
/// accent, in the brightness it would show in now: the five, the
/// wallpaper's where the phone makes one, and the reader's own, which opens
/// its colours.
class _PaletteSwatches extends StatelessWidget {
  const _PaletteSwatches({
    required this.selected,
    required this.own,
    required this.wallpaper,
    required this.onPick,
    required this.onOwn,
  });

  final String selected;
  final Palette own;
  final Palette? wallpaper;
  final ValueChanged<String> onPick;
  final VoidCallback onOwn;

  @override
  Widget build(BuildContext context) {
    final dark = Skin.isDark(context);
    final themes = [
      for (final p in Palette.all)
        if (!Palette.designer.contains(p) && p.scene == null) (p, p.id, p.label),
      if (wallpaper != null) (wallpaper!, 'wallpaper', 'Wallpaper'),
      (own, 'own', 'Your own'),
    ];
    // Rows of as many as fit with their names whole (four on a phone held
    // upright), so none hides off the side.
    return LayoutBuilder(
      builder: (context, box) {
        final across = (box.maxWidth / 72).floor().clamp(4, themes.length);
        return Column(
          children: [
            for (var row = 0; row * across < themes.length; row++) ...[
              if (row > 0) const SizedBox(height: Gap.m),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < across; i++) ...[
                    if (i > 0) const SizedBox(width: Gap.s),
                    Expanded(
                      child: row * across + i < themes.length
                          ? _swatch(context, themes[row * across + i], dark)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _swatch(BuildContext context, (Palette, String, String) theme, bool dark) {
    final (p, id, label) = theme;
    final b = p.only ?? (dark ? Brightness.dark : Brightness.light);
    final on = id == selected;
    final mine = id == 'own';
    final ink = p.inkFor(b);
    return Semantics(
      button: true,
      selected: on,
      label: mine ? 'Your own colours' : '$label theme',
      child: GestureDetector(
        onTap: mine ? onOwn : () => onPick(id),
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
                      // Your own opens its colours: a brush until it is chosen.
                      child: on
                          ? Icon(Icons.check_rounded, size: 13, color: p.onAccent)
                          : mine
                              ? Icon(Icons.brush_rounded, size: 11, color: p.onAccent)
                              : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
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

/// The designer themes folded into one row: a strip of their grounds and
/// accents, which one is on (if one is), and a tap to see them all.
class _DesignerRow extends StatelessWidget {
  const _DesignerRow({required this.selected, required this.onOpen});

  final String selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final dark = Skin.isDark(context);
    final on = [...Palette.scenes, ...Palette.designer].where((p) => p.id == selected).firstOrNull;
    return Semantics(
      button: true,
      label: on == null ? 'Designer themes' : 'Designer themes, ${on.label} is on',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Radii.row),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.s, Gap.m),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.row),
              border: Border.all(color: on == null ? Skin.outlineOn(context) : on.accent, width: on == null ? 1 : 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Designer themes',
                              style: Skin.ui(size: 16, weight: FontWeight.w600, color: Skin.inkOn(context))),
                          const SizedBox(height: 2),
                          Text(
                            on == null
                                ? '${Palette.scenes.length} scenes (from a dungeon to the sun) and '
                                    '${Palette.designer.length} more colours. Tap to see them.'
                                : '${on.label} is on. Tap to see the others.',
                            style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
                  ],
                ),
                const SizedBox(height: Gap.m),
                // The scenes, each a glimpse of its place: by night, then by
                // day.
                for (final (row, places) in [
                  (0, [for (final p in Palette.scenes) if (!p.scene!.light) p]),
                  (1, [for (final p in Palette.scenes) if (p.scene!.light) p]),
                ]) ...[
                  if (row > 0) const SizedBox(height: Gap.xs),
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: Row(
                      children: [
                        for (final (i, p) in places.indexed) ...[
                          if (i > 0) const SizedBox(width: Gap.xs),
                          Expanded(child: _sceneChip(context, p, p.id == selected)),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Gap.xs),
                Padding(
                  padding: const EdgeInsets.only(right: Gap.s),
                  child: Row(
                    children: [
                      for (final (i, p) in Palette.designer.indexed) ...[
                        if (i > 0) const SizedBox(width: Gap.xs),
                        Expanded(child: _chip(context, p, dark, p.id == selected)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A scene's backdrop, small.
  Widget _sceneChip(BuildContext context, Palette p, bool on) => Container(
        height: 40,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.chip / 1.5),
          border: Border.all(color: on ? p.accent : Skin.outlineOn(context), width: on ? 2 : 1),
        ),
        child: ScenePreview(p.scene!),
      );

  /// One theme's ground with its accent, small.
  Widget _chip(BuildContext context, Palette p, bool dark, bool on) {
    final b = dark ? Brightness.dark : Brightness.light;
    return Container(
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: Skin.groundFor(b, p),
        borderRadius: BorderRadius.circular(Radii.chip / 1.5),
        border: Border.all(color: on ? p.accent : Skin.outlineOn(context), width: on ? 2 : 1),
      ),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
      ),
    );
  }
}

/// The designer themes, two across, each drawn as a little page of its own
/// colours in the brightness it would show in now: its ground, a page with
/// lines of its type, an accent word, and the player bar with its play
/// button; under it the name and what it is made of. Picking one gives its
/// id back.
class _DesignerSheet extends StatelessWidget {
  const _DesignerSheet({required this.selected});

  final String selected;

  @override
  Widget build(BuildContext context) {
    final b = Skin.isDark(context) ? Brightness.dark : Brightness.light;
    final themes = Palette.designer;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader('Designer themes', subtitle: b == Brightness.dark ? 'Shown dark, as now' : 'Shown light, as now'),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(
                  Gap.l, 0, Gap.l, Gap.xl + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                // Scenes first: a place drawn behind every screen.
                const Padding(
                  padding: EdgeInsets.only(left: Gap.xs, bottom: Gap.s),
                  child: Eyebrow('Scenes'),
                ),
                for (var row = 0; row * 2 < Palette.scenes.length; row++) ...[
                  if (row > 0) const SizedBox(height: Gap.l),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 2; i++) ...[
                        if (i > 0) const SizedBox(width: Gap.m),
                        Expanded(
                          child: row * 2 + i < Palette.scenes.length
                              ? _scenePreview(context, Palette.scenes[row * 2 + i])
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(Gap.xs, Gap.xl, 0, Gap.s),
                  child: Eyebrow('Colours'),
                ),
                for (var row = 0; row * 2 < themes.length; row++) ...[
                  if (row > 0) const SizedBox(height: Gap.l),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 2; i++) ...[
                        if (i > 0) const SizedBox(width: Gap.m),
                        Expanded(
                          child: row * 2 + i < themes.length
                              ? _preview(context, themes[row * 2 + i], b)
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A scene as it would look: a glimpse of its backdrop, a cover in its
  /// frame and the player on its panel; its name and what it is made of.
  Widget _scenePreview(BuildContext context, Palette p) {
    final scene = p.scene!;
    final on = p.id == selected;
    // Its own node (container): alone in its row (an odd count), a tile's
    // was merged into the row's, as wide as the screen, and a tap on its
    // middle missed it.
    return Semantics(
      container: true,
      button: true,
      selected: on,
      label: '${p.label} scene',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(p.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 190,
              clipBehavior: Clip.antiAlias,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.row),
                border: Border.all(color: on ? p.accent : Skin.outlineOn(context), width: on ? 2.5 : 1),
              ),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.row), color: p.night.last),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ScenePreview(scene),
                  // A book in the scene's frame.
                  Positioned(
                    left: Gap.m,
                    top: Gap.xl,
                    width: 44,
                    height: 66,
                    child: CustomPaint(
                      foregroundPainter: CoverFramePainter(scene, 4),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFF2A4232), Color(0xFF0A120D)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // The player, on its panel.
                  Positioned(
                    left: Gap.s,
                    right: Gap.s,
                    bottom: Gap.s,
                    height: 34,
                    child: DecoratedBox(
                      decoration: ScenePanel(scene, radius: BorderRadius.circular(17), lit: true),
                      child: Row(
                        children: [
                          const SizedBox(width: Gap.m),
                          Expanded(
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: 0.7,
                              child: Container(
                                height: 4,
                                decoration: BoxDecoration(
                                  color: p.nightInk.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                            child: Icon(on ? Icons.check_rounded : Icons.play_arrow_rounded, size: 15, color: p.onAccent),
                          ),
                          const SizedBox(width: Gap.s),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.s),
            Text(
              p.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Skin.ui(size: 14.5, weight: on ? FontWeight.w700 : FontWeight.w600, color: Skin.inkOn(context)),
            ),
            Text(
              on ? 'On now · always dark' : '${scene.note} · always dark',
              maxLines: 2,
              style: Skin.ui(size: 12.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, Palette p, Brightness b) {
    final on = p.id == selected;
    final ink = p.inkFor(b);
    final faint = p.inkFaintFor(b);
    final page = b == Brightness.dark ? p.nightSheet : p.daySheet;
    final bar = b == Brightness.dark ? p.nightCapsule : p.dayCapsule;
    final word = b == Brightness.dark ? p.accentSoft : p.accentDeep;
    Widget line(double w, Color c) => FractionallySizedBox(
          widthFactor: w,
          child: Container(height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        );
    return Semantics(
      button: true,
      selected: on,
      label: '${p.label} theme',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(p.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 150,
              padding: const EdgeInsets.all(Gap.s),
              decoration: BoxDecoration(
                gradient: Skin.groundFor(b, p),
                borderRadius: BorderRadius.circular(Radii.row),
                border: Border.all(color: on ? p.accent : Skin.outlineOn(context), width: on ? 2.5 : 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The page, with its heading, lines and the word being read.
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(Gap.s, Gap.s, Gap.s, 0),
                      decoration: BoxDecoration(
                        color: page.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(Radii.chip),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          line(0.5, ink.withValues(alpha: 0.85)),
                          const SizedBox(height: 7),
                          line(0.95, faint.withValues(alpha: 0.6)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(flex: 3, child: line(1, faint.withValues(alpha: 0.6))),
                              const SizedBox(width: 3),
                              Expanded(flex: 2, child: line(1, word)),
                              const SizedBox(width: 3),
                              Expanded(flex: 2, child: line(1, faint.withValues(alpha: 0.6))),
                            ],
                          ),
                          const SizedBox(height: 4),
                          line(0.8, faint.withValues(alpha: 0.6)),
                          const SizedBox(height: 4),
                          line(0.9, faint.withValues(alpha: 0.6)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.s),
                  // The player bar: a title line and the play button.
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                    decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(15)),
                    child: Row(
                      children: [
                        Expanded(child: line(0.7, ink.withValues(alpha: 0.6))),
                        const SizedBox(width: Gap.s),
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                          child: Icon(on ? Icons.check_rounded : Icons.play_arrow_rounded,
                              size: 14, color: p.onAccent),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.s),
            Text(
              p.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Skin.ui(
                size: 14.5,
                weight: on ? FontWeight.w700 : FontWeight.w600,
                color: Skin.inkOn(context),
              ),
            ),
            Text(
              on ? 'On now' : (Palette.designerNotes[p.id] ?? ''),
              maxLines: 2,
              style: Skin.ui(size: 12.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
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
              // A scene theme's stone tablet, wood or hull plate.
              decoration: Skin.panel(
                context,
                BoxDecoration(
                  color: Skin.capsuleOn(context),
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(color: Skin.outlineOn(context)),
                ),
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
/// screen off (and go on downloading chapters and building memories), and
/// the way to its setting (the phone's own question, or its list of apps).
/// Below it, "Keeps stopping?": on phones whose makers stop apps in ways of
/// their own as well, a line to the maker's page on dontkillmyapp.com,
/// which says what else to turn off; on others, while battery saving is
/// on, the same line naming the usual makers. Nothing shows where the phone
/// cannot say (tests).
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
    // The Play build may not ask to be left out of battery saving: the
    // list of apps opens, for the reader to change it there.
    if (!await _svc.openBatterySettings(request: !playBuild) && mounted) {
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
                : playBuild
                    ? 'Battery saving may stop the voice, downloads and memory building with the screen off. '
                        'Tap, find TomeVoice in the list, and let it run unrestricted'
                    : 'Battery saving may stop the voice, downloads and memory building with the screen off. '
                        'Tap to allow TomeVoice',
            onTap: _open,
          ),
          if (maker != null || !status.exempt)
            // In line with the row's text, under its icon's gap.
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Semantics(
                link: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.row),
                  onTap: () => _svc.openUrl('https://dontkillmyapp.com/${maker?.page ?? ''}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Text(
                      maker != null
                          ? 'Keeps stopping? ${maker.name} phones can also stop apps in ways of their own: '
                              'dontkillmyapp.com/${maker.page}'
                          : 'Keeps stopping? Phones by Nothing, Xiaomi, Samsung, OnePlus and others can also stop '
                              'apps in ways of their own: dontkillmyapp.com',
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
    if (playBuild) {
      final info = await PlayUpdates.check();
      if (mounted) setState(() => _checking = false);
      if (!mounted) return;
      if (info == null) {
        showSnack(context, 'Google Play could not say. Check the internet connection, or look in the Play Store.');
      } else if (info.available || info.downloaded) {
        unawaited(offerPlayUpdate(context, info));
      } else {
        showSnack(context, 'This is the latest TomeVoice.');
      }
      return;
    }
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
          decoration: Skin.groundDecoration(context),
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
                          style: Skin.heading(context, size: 38, weight: FontWeight.w500)),
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
                          subtitle: playBuild ? 'New versions come from Google Play' : 'New versions are published on GitHub',
                          onTap: _checkForUpdate,
                        ),
                      // Play: the source is offered on the licences page.
                      if (!playBuild)
                      _Link(
                        icon: Icons.code_rounded,
                        title: 'Source code',
                        subtitle: 'github.com/Sayandeep1013/TomeVoice',
                        onTap: () => _svc.openUrl(repositoryUrl),
                      ),
                      if (!playBuild)
                      _Link(
                        icon: Icons.new_releases_outlined,
                        title: 'Releases',
                        subtitle: 'Download the latest version',
                        onTap: () => _svc.openUrl('$repositoryUrl/releases/latest'),
                      ),
                      _Link(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Privacy',
                        subtitle: 'What stays on the phone, and what goes where',
                        onTap: () => _svc.openUrl(privacyUrl),
                      ),
                      _Link(
                        icon: Icons.bug_report_outlined,
                        title: 'Report a problem',
                        subtitle: playBuild
                            ? 'See every word it would say, then send it yourself by email'
                            : 'See every word it would say, then send it yourself on GitHub',
                        onTap: () => unawaited(showProblemReport(context)),
                      ),
                      _Link(
                        icon: Icons.graphic_eq_rounded,
                        title: 'Voice log',
                        subtitle: 'For a voice that lags or goes wrong: notes what it does, for you to share',
                        onTap: () => unawaited(showVoiceLog(context)),
                      ),
                      _Link(
                        icon: Icons.touch_app_outlined,
                        title: 'Tap log',
                        subtitle: 'For buttons that need tapping again and again: notes your taps, for you to share',
                        onTap: () => unawaited(showTapLog(context)),
                      ),
                      _Link(
                        icon: Icons.gavel_rounded,
                        title: 'Open-source licences',
                        subtitle: 'Fonts and libraries TomeVoice is made with',
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'TomeVoice',
                          applicationVersion: _version,
                          applicationLegalese: playBuild
                              ? 'GPL-3.0. Source code of this version: ${sourceArchiveUrl(_version)}'
                              : 'GPL-3.0',
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

/// What a setting search found: each match's words and the section it is
/// in, a tap scrolling to it; or that nothing matched.
class _Found extends StatelessWidget {
  const _Found({required this.found, required this.query, required this.onPick});

  final List<({String text, String group, Element at})> found;
  final String query;
  final ValueChanged<({String text, String group, Element at})> onPick;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: Material(
          color: Skin.capsuleOn(context),
          shape: Skin.cardShape(context, Radii.row + 4),
          clipBehavior: Clip.antiAlias,
          child: found.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Text('No setting says "$query".', style: Skin.meta(context)),
                )
              : Column(
                  children: [
                    for (final f in found)
                      InkWell(
                        onTap: () => onPick(f),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(f.text,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))),
                                    const SizedBox(height: 2),
                                    Text(f.group.toUpperCase(), style: Skin.meta(context, size: 11)),
                                  ],
                                ),
                              ),
                              Icon(Icons.arrow_forward_rounded, size: 18, color: Skin.inkSoftOn(context)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      );
}
