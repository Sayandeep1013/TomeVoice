import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'library_store.dart';
import 'book_search.dart';
import 'listen_sheet.dart';
import 'marks.dart';
import 'now_playing.dart';
import 'pages_view.dart';
import 'player_controls.dart';
import 'prefs.dart';
import 'quote_sheet.dart';
import 'reading_rules.dart';
import 'rules_screen.dart';
import 'share_card.dart';
import 'sources/source_engine.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'stats.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';
import 'web_reader.dart';

const _svc = SpeechService();

/// Open [entry] in the reader, straight to where it was left.
Future<void> openBook(
  BuildContext context,
  LibraryStore store,
  LibraryEntry entry, {
  bool autoplay = false,
  Mark? at,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BookTint(
        bookId: entry.id,
        cover: entry.shownCover,
        child: entry.isWeb
            ? WebNovelReader(store: store, entry: entry, autoplay: autoplay, startChapter: at?.at.sectionIndex)
            : BookLoader(store: store, entry: entry, autoplay: autoplay, at: at),
      ),
    ),
  );
}

/// Opens a book: shows the reading surface's frame at once and fills it when
/// the background isolate has the layout, so a tap on a book responds
/// immediately even for a 200-chapter EPUB.
class BookLoader extends StatefulWidget {
  const BookLoader({
    super.key,
    required this.store,
    required this.entry,
    this.autoplay = false,
    this.at,
  });

  final LibraryStore store;
  final LibraryEntry entry;
  final bool autoplay;

  /// Open at this saved quote or bookmark instead of the reading place.
  final Mark? at;

  @override
  State<BookLoader> createState() => _BookLoaderState();
}

class _BookLoaderState extends State<BookLoader> {
  // The place is read after the layout: loading may re-parse the book and
  // carry the saved place over to the new structure first.
  late final Future<(ReadingLayout, ReadingCursor)> _load = () async {
    final layout = await widget.store.loadLayout(widget.entry.id);
    final at = widget.at;
    if (at != null && !layout.isEmpty) return (layout, cursorOf(layout.units[unitOfMark(layout, at)]));
    final cursor = await widget.store.cursorFor(widget.entry.id);
    return (layout, cursor);
  }();

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _load,
        builder: (context, snap) {
          final data = snap.data;
          if (data != null) {
            return ReaderScreen(
              layout: data.$1,
              store: widget.store,
              initialCursor: data.$2,
              autoplay: widget.autoplay,
              bookDir: widget.store.bookDir(widget.entry.id),
              sourcePath: widget.entry.sourcePath,
            );
          }
          return _ReaderSkeleton(
            title: widget.entry.title,
            error: snap.hasError ? '${snap.error}' : null,
          );
        },
      );
}

class _ReaderSkeleton extends StatelessWidget {
  const _ReaderSkeleton({required this.title, this.error});

  final String title;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final faint = Skin.inkFaintOn(context).withValues(alpha: 0.18);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    RoundButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back to library',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.title(context, size: 18)),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(error!, style: Skin.label(context, size: 13)),
                  )
                else
                  for (final w in const [0.5, 0.95, 0.9, 0.97, 0.6, 0.0, 0.93, 0.88, 0.96, 0.4])
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                      child: FractionallySizedBox(
                        widthFactor: w == 0 ? 0.01 : w,
                        child: Container(
                          height: w == 0 ? 6 : 14,
                          decoration: BoxDecoration(
                            color: w == 0 ? Colors.transparent : faint,
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
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

/// The reading surface.
///
/// Laid out from the reference design (docs/10 ADR-017): a soft gradient
/// ground, chrome as floating capsules, monospace instrumentation, and the
/// text itself as the loudest thing on screen. The whole book scrolls as one
/// page; the sentence being spoken is washed amber and the word under the
/// voice a little stronger.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.layout,
    this.store,
    this.initialCursor = ReadingCursor.zero,
    this.autoplay = false,
    this.bookDir,
    this.sourcePath,
    this.onReachedEnd,
    this.onChapterChanged,
    this.progressOf,
    this.endLabel,
    this.positionOf,
    this.chapterNumberOf,
    this.viewSection,
    this.openContents,
  });

  final ReadingLayout layout;
  final LibraryStore? store;
  final ReadingCursor initialCursor;
  final bool autoplay;

  /// The end of what is here was reached (a web novel whose next chapters
  /// are still on the site). [playing] says whether to carry on aloud;
  /// [browse], that the reader is only looking ahead (the button at the end
  /// of the page), so the place being read stays where it is. When null,
  /// the end is the end of the book.
  final Future<void> Function({required bool playing, bool browse})? onReachedEnd;

  /// The section (chapter number) being read changed.
  final ValueChanged<int>? onChapterChanged;

  /// Contents of the whole work, for one longer than [layout] (a web
  /// novel's chapters, downloaded or not), in place of [layout]'s own.
  /// [section] is the chapter being read; [playing], whether aloud.
  final void Function(BuildContext context, {required int section, required bool playing})? openContents;

  /// How far through the whole work unit [u] is; defaults to the share of
  /// this layout read so far.
  final double Function(int u)? progressOf;

  /// The button at the end of the page when [onReachedEnd] is set.
  final String? endLabel;

  /// "12/340" for unit [u] in the whole work, when this layout holds only
  /// part of it (a web novel's downloaded chapters).
  final String Function(int u)? positionOf;

  /// The number a chapter goes by (a web novel's 3222, not its place among
  /// the chapters on the phone); defaults to its place in this layout.
  final int Function(int chapter)? chapterNumberOf;

  /// Open showing this section (a chapter looked ahead to) instead of the
  /// place being read, which stays where it is until Play.
  final int? viewSection;

  /// Where the book's pictures were stored at import.
  final String? bookDir;

  /// The original file; a PDF's pages are drawn from it.
  final String? sourcePath;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  ReadingLayout get _l => widget.layout;
  Book get _book => _l.book;

  late final ValueNotifier<int> _cursor =
      ValueNotifier(_l.isEmpty ? 0 : _l.unitForCursor(widget.initialCursor));
  final _detached = ValueNotifier<bool>(false);

  /// The chapter at the top of the screen. While the reader looks around
  /// (detached), the top bar names it instead of the one being read.
  late final _viewChapter = ValueNotifier<int>(_l.chapterOfUnit(_cursor.value));
  late final _topLine = Listenable.merge([_cursor, _detached, _viewChapter]);

  /// The item the list opens at: the place being read, or the chapter asked
  /// to be shown.
  late final int _startItem = () {
    if (_l.isEmpty) return 0;
    final cursorItem = _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)];
    final view = widget.viewSection;
    final c = view == null ? -1 : _l.chapters.indexOf(view);
    return c < 0 ? cursorItem : _l.chapterFirstItem[c];
  }();
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();

  late final PlaybackScheduler _player;
  ListeningPrefs _prefs = ListeningPrefs.memory;
  final _catalog = VoiceCatalog.instance;
  late final String _language = _primaryLanguage(_book.metadata.language);

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _persistTimer;
  Timer? _restartTimer;
  bool _resumeOnFocus = false;
  int _sessionChapter = -1;
  int _sessionUnit = -1;
  double _sessionSpeed = 0;
  PlayState _sessionState = PlayState.idle;

  /// The book's cover file, for the shade's media card.
  String? _cover;

  /// This book in the library (web source, author), once looked up.
  LibraryEntry? _entry;

  /// Reading time: counted every [_tick] as listening (playing) or reading
  /// (scrolled in the last minute), from the time actually passed.
  Timer? _statsTimer;
  DateTime _lastTick = DateTime.now();
  DateTime? _lastScroll;
  int _statsUnit = -1;

  /// Search matches being stepped through, and which one is shown.
  List<SearchHit> _hits = const [];
  int _hit = 0;
  String _hitQuery = '';

  /// The card moved the place while paused. Moving stops the player, but
  /// the card stays up, paused at the new place, until reading resumes.
  bool _parked = false;
  bool _programmaticScroll = false;

  bool get _isPdf => _book.source == SourceKind.pdf && widget.sourcePath != null;
  bool get _showPages => _isPdf && _prefs.pdfPages;

  SleepChoice _sleep = SleepChoice.off;
  Timer? _sleepTimer;
  DateTime? _sleepAt;
  int _sleepChapter = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = PlaybackScheduler(
      service: _svc,
      units: _l.units,
      settingsFor: (text) => _prefs.settings.copyWith(text: text),
      engineIdOf: () => _prefs.engineId ?? _catalog.engineId,
      voiceNameOf: () => _listen.voiceName,
      pauseAfter: _pauseAfter,
      respell: (text) => respell(text, ReadingRules.instance.sayFor(_book.id)),
      dialogueVoiceOf: () => _listen.dialogueVoice,
      quoteOpenAt: _quoteOpenAt,
    )..onFinished = _onFinished;
    _player.unit.addListener(() => _cursor.value = _player.unit.value);
    _player.state.addListener(_onPlayState);
    _cursor.addListener(_onCursor);
    _positions.itemPositions.addListener(_onPositions);
    if (!_l.isEmpty && _startItem != _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)]) {
      _detached.value = true;
      _viewChapter.value = _l.items[_startItem].chapter;
    }
    _catalog.addListener(_onCatalog);
    unawaited(_catalog.ensureLoaded());
    _events = SpeechService.events.listen(_onPlatformEvent);
    ListeningPrefs.revision.addListener(_onPrefs);
    ReadingRules.instance.changes.addListener(_onRules);
    unawaited(_loadPrefs());
    unawaited(_loadCover());
    _statsTimer = Timer.periodic(const Duration(seconds: 15), (_) => _countTime());
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Looking ahead while it reads: carry on aloud where it was, and
        // leave the page where the reader is looking.
        if (_detached.value && !_l.isEmpty) {
          unawaited(_player.play(_cursor.value));
        } else {
          unawaited(_togglePlay());
        }
      });
    }
  }

  Future<void> _loadPrefs() async {
    final dir = widget.store?.root.path;
    if (dir == null) return;
    final p = await ListeningPrefs.load(dir);
    if (!mounted) return;
    setState(() => _prefs = p);
    _applyScreenOn();
    if (p.engineId != null && p.engineId != _catalog.engineId) {
      await _catalog.ensureLoaded();
      await _catalog.switchEngine(p.engineId!);
    }
  }

  Future<void> _loadCover() async {
    final store = widget.store;
    if (store == null) return;
    try {
      final entry = (await store.list()).where((e) => e.id == _book.id).firstOrNull;
      if (!mounted) return;
      setState(() {
        _entry = entry;
        _cover = entry?.shownCover;
      });
      _updateSession(force: true);
    } on Object {
      // The card goes without a picture.
    }
  }

  bool _screenOn = false;

  /// A pronunciation was fixed: say the current sentence again with it.
  void _onRules() => _onSettingsChanged(restart: true);

  void _applyScreenOn() {
    if (_prefs.keepScreenOn == _screenOn) return;
    _screenOn = _prefs.keepScreenOn;
    unawaited(_svc.keepScreenOn(_screenOn));
  }

  /// Font, size, spacing or theme changed somewhere (this book's sheet, or
  /// Settings): redraw the page.
  void _onPrefs() {
    if (!mounted) return;
    _applyScreenOn();
    setState(() {});
  }

  /// Now Playing, while it is open over this reader, and the navigator it is on.
  Route<void>? _nowPlaying;
  NavigatorState? _nowPlayingNav;

  /// Redraws the sleep countdown in the player bar.
  Timer? _sleepTick;

  @override
  void dispose() {
    final open = _nowPlaying;
    final nav = _nowPlayingNav;
    if (open != null && nav != null && open.isActive) {
      // It holds this reader's player and place, which are going: close it
      // after this frame (a route cannot be removed while the tree is torn down).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (open.isActive) nav.removeRoute(open);
      });
    }
    _sleepTick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ListeningPrefs.revision.removeListener(_onPrefs);
    ReadingRules.instance.changes.removeListener(_onRules);
    if (_screenOn) unawaited(_svc.keepScreenOn(false));
    _persistTimer?.cancel();
    _restartTimer?.cancel();
    _sleepTimer?.cancel();
    _statsTimer?.cancel();
    _countTime();
    unawaited(StatsStore.instance.flush());
    unawaited(_persist());
    unawaited(_events?.cancel());
    _catalog.removeListener(_onCatalog);
    unawaited(_svc.session(active: false));
    _player.dispose();
    _positions.itemPositions.removeListener(_onPositions);
    _cursor.dispose();
    _detached.dispose();
    _viewChapter.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_persist());
      _countTime();
      unawaited(StatsStore.instance.flush());
    }
  }

  void _onCatalog() {
    if (mounted) setState(() {});
  }

  ListenController get _listen => ListenController(
        prefs: _prefs,
        language: _language,
        bookId: _book.id,
        onChanged: _onSettingsChanged,
        sleep: _sleep,
        onSleep: _setSleep,
        onPreview: _previewVoice,
        isPlaying: () =>
            _player.state.value == PlayState.playing || _player.state.value == PlayState.loading,
        isPdf: _isPdf,
      );

  /// Say the sentence under the cursor in [voiceName], so a voice is judged
  /// on this book's own text.
  Future<void> _previewVoice(String voiceName) async {
    if (_player.state.value != PlayState.idle) await _player.stop();
    final u = _cursor.value.clamp(0, math.max(0, _l.units.length - 1)).toInt();
    var text = _l.isEmpty ? '' : _l.units[u].text;
    if (text.length < 40 && !_l.isEmpty && u + 1 < _l.units.length) {
      text = '$text ${_l.units[u + 1].text}';
    }
    if (text.trim().isEmpty) text = 'This is how I will sound reading your book.';
    if (text.length > 220) text = '${text.substring(0, text.lastIndexOf(' ', 220).clamp(80, 220))}.';
    try {
      await speakSample(
        voiceName: voiceName,
        text: text,
        settings: _prefs.settings,
        engineId: _prefs.engineId ?? _catalog.engineId,
      );
    } on Object catch (e) {
      debugPrint('Voice sample failed: $e');
      _snack('That voice could not play a sample. Try another.');
    }
  }

  /// Stop reading after a while, or at the end of this chapter — for
  /// listening in bed with the screen off.
  void _setSleep(SleepChoice choice) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepAt = null;
    _sleepChapter = -1;
    final minutes = switch (choice) {
      SleepChoice.min15 => 15,
      SleepChoice.min30 => 30,
      SleepChoice.min60 => 60,
      _ => 0,
    };
    if (minutes > 0) {
      final d = Duration(minutes: minutes);
      _sleepAt = DateTime.now().add(d);
      _sleepTimer = Timer(d, () => _sleepNow('Sleep timer: paused.'));
      // The countdown in the player bar is redrawn as it runs.
      _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted && _sleepAt != null) setState(() {});
      });
    } else if (choice == SleepChoice.chapterEnd) {
      _sleepChapter = _l.chapterOfUnit(_cursor.value);
    }
    setState(() => _sleep = choice);
  }

  void _sleepNow(String message) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepAt = null;
    _sleepChapter = -1;
    unawaited(_player.pause());
    if (mounted) {
      setState(() => _sleep = SleepChoice.off);
      _snack(message);
    }
  }

  String? get _sleepNote {
    final at = _sleepAt;
    if (at != null) {
      // Round up: 29:59 left reads as 30 minutes, and so does 30:00.
      final left = (at.difference(DateTime.now()).inSeconds / 60).ceil();
      return 'SLEEP ${left}M';
    }
    if (_sleep == SleepChoice.chapterEnd) return 'SLEEP AT CHAPTER END';
    return null;
  }

  int _pauseAfter(int i) {
    final s = _prefs.settings;
    if (i + 1 >= _l.units.length) return s.sentencePauseMs;
    final here = _l.units[i];
    final next = _l.units[i + 1];
    if (_l.unitChapter[i] != _l.unitChapter[i + 1]) return s.paragraphPauseMs + 400;
    if (next.blockId != here.blockId) return s.paragraphPauseMs;
    return s.sentencePauseMs;
  }

  // ------------------------------------------------------------- playback

  Future<void> _togglePlay() async {
    if (_l.isEmpty) return;
    switch (_player.state.value) {
      case PlayState.idle:
        _follow();
        await _player.play(_cursor.value);
      case PlayState.paused:
        // Scrolled away to look around: Play goes back to the voice first.
        if (_detached.value) _follow();
        await _player.resume();
      case PlayState.playing:
      case PlayState.loading:
        await _player.pause();
    }
  }

  /// Move to [unit]. Tapping text always means "read from here"; the
  /// buttons keep playing if we were playing and just move if not.
  Future<void> _goTo(int unit, {bool play = false}) async {
    if (_l.isEmpty) return;
    final next = unit.clamp(0, _l.units.length - 1);
    _cursor.value = next;
    _follow();
    final state = _player.state.value;
    if (play || state == PlayState.playing || state == PlayState.loading) {
      await _player.play(next);
    } else if (state == PlayState.paused) {
      await _player.stop();
    }
  }

  void _goChapter(int delta) {
    final more = widget.onReachedEnd;
    if (delta > 0 && more != null && _l.chapterOfUnit(_cursor.value) >= _l.chapters.length - 1) {
      // Past what is here: the next chapters are still on the site.
      final s = _player.state.value;
      unawaited(_persist());
      unawaited(more(playing: s == PlayState.playing || s == PlayState.loading));
      return;
    }
    final c = (_l.chapterOfUnit(_cursor.value) + delta).clamp(0, _l.chapters.length - 1);
    unawaited(_goTo(_l.chapterFirstUnit[c]));
  }

  void _onSettingsChanged({required bool restart}) {
    if (mounted) setState(() {});
    _updateSession();
    if (!restart) return;
    // Make the change audible from the current sentence, once the user has
    // stopped fiddling.
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 350), () {
      final s = _player.state.value;
      if (s == PlayState.playing || s == PlayState.loading) {
        unawaited(_player.play(_cursor.value));
      }
    });
  }

  void _onFinished() {
    unawaited(_persist());
    final more = widget.onReachedEnd;
    if (more != null) {
      unawaited(more(playing: true));
      return;
    }
    if (mounted) {
      _snack('Finished. That is the end of the book.');
    }
  }

  void _onPlayState() {
    final s = _player.state.value;
    if (s == PlayState.playing || s == PlayState.loading) _parked = false;
    final err = _player.error.value;
    if (s == PlayState.idle && err != null && mounted) {
      _snack('Reading stopped: $err');
    }
    _updateSession();
  }

  void _updateSession({bool force = false}) {
    final actual = _player.state.value;
    final s = actual == PlayState.idle && _parked ? PlayState.paused : actual;
    final u = _cursor.value;
    final chapter = _l.chapterOfUnit(u);
    final speed = _prefs.settings.speedScale;
    if (!force &&
        s == _sessionState &&
        chapter == _sessionChapter &&
        u == _sessionUnit &&
        speed == _sessionSpeed) {
      return;
    }
    final wasActive = _sessionState != PlayState.idle;
    _sessionState = s;
    _sessionChapter = chapter;
    _sessionUnit = u;
    _sessionSpeed = speed;
    if (s == PlayState.idle) {
      if (wasActive) unawaited(_svc.session(active: false));
      return;
    }
    final (first, count) = _l.chapterRange(chapter);
    unawaited(_svc.session(
      active: true,
      title: _book.metadata.title,
      subtitle: _l.chapterTitle(chapter),
      playing: s != PlayState.paused,
      cover: _cover,
      positionMs: _msFor(_wordsAt(u) - _wordsAt(first)),
      durationMs: _msFor(_wordsAt(first + count) - _wordsAt(first)),
      speed: speed,
    ));
  }

  void _onPlatformEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'noisy':
      case 'focusLoss':
        unawaited(_player.pause());
      case 'focusLossTransient':
        if (_player.isPlaying) {
          _resumeOnFocus = true;
          unawaited(_player.pause());
        }
      case 'focusGain':
        if (_resumeOnFocus && _player.state.value == PlayState.paused) {
          unawaited(_player.resume());
        }
        _resumeOnFocus = false;
      case 'action':
        switch (e['action']) {
          case 'play':
            if (_player.state.value != PlayState.playing) unawaited(_togglePlay());
          case 'pause':
            unawaited(_player.pause());
          case 'stop':
            _parked = false;
            unawaited(_player.stop());
          case 'next':
            _park();
            _goChapter(1);
          case 'prev':
            _park();
            _cardPrevious();
          case 'seek':
            _park();
            _seekInChapter((e['value'] as num?)?.toInt() ?? 0);
          case 'speed':
            _nextSpeed();
          case 'save':
            unawaited(_save(MarkKind.quote));
        }
    }
  }

  // ----------------------------------------------------------- media card

  void _park() {
    if (_player.state.value == PlayState.paused) _parked = true;
  }

  /// Words before unit [u]; [u] may be one past the end.
  int _wordsAt(int u) => u < _l.units.length ? _l.wordsBefore[u] : _l.totalWords;

  /// How long [words] take at the reading speed: the same 165 words a minute
  /// as the time left under the player.
  int _msFor(int words) => (words / (165 * _prefs.settings.speedScale) * 60000).round();

  /// The card's previous button: back to the start of this chapter, or to the
  /// previous chapter when within its first seconds, as a music player does.
  void _cardPrevious() {
    if (_l.isEmpty) return;
    final u = _cursor.value;
    final (first, _) = _l.chapterRange(_l.chapterOfUnit(u));
    if (_msFor(_wordsAt(u) - _wordsAt(first)) > 3000) {
      unawaited(_goTo(first));
    } else {
      _goChapter(-1);
    }
  }

  /// The card's seek bar was dragged to [ms] into the chapter.
  void _seekInChapter(int ms) {
    if (_l.isEmpty) return;
    final (first, count) = _l.chapterRange(_l.chapterOfUnit(_cursor.value));
    final target = _wordsAt(first) + ms / 60000 * 165 * _prefs.settings.speedScale;
    var u = first;
    while (u + 1 < first + count && _wordsAt(u + 1) <= target) {
      u++;
    }
    unawaited(_goTo(u));
  }

  /// The card's speed button: the next of the common speeds, round to the
  /// slowest after the fastest.
  void _nextSpeed() {
    final now = _prefs.settings.speedScale;
    final next = speedPresets.firstWhere((p) => p > now + 0.001, orElse: () => speedPresets.first);
    _prefs.settings = _prefs.settings.copyWith(speedScale: next);
    _prefs.save();
    _onSettingsChanged(restart: true);
  }

  // --------------------------------------------------------------- cursor

  int _lastSection = -1;

  /// Time since the last count, to listening or reading. A gap longer than a
  /// tick (the phone asleep with nothing playing) is not counted.
  void _countTime() {
    final now = DateTime.now();
    final passed = now.difference(_lastTick);
    _lastTick = now;
    if (passed > const Duration(seconds: 20) || _l.isEmpty) return;
    if (_player.isPlaying) {
      StatsStore.instance.addTime(_book.id, passed, listening: true);
    } else if (_lastScroll != null && now.difference(_lastScroll!) < const Duration(minutes: 1)) {
      StatsStore.instance.addTime(_book.id, passed, listening: false);
    }
  }

  /// A sentence heard to its end (reading moved on by one while playing),
  /// and a chapter finished (the next one begun).
  void _countProgress(int u) {
    final prev = _statsUnit;
    _statsUnit = u;
    if (prev < 0 || u != prev + 1 || !_player.isPlaying || _l.isEmpty) return;
    StatsStore.instance.addWords(_l.wordsBefore[u] - _l.wordsBefore[prev]);
    if (_l.chapterOfUnit(u) == _l.chapterOfUnit(prev) + 1) StatsStore.instance.addChapter();
  }

  void _onCursor() {
    _countProgress(_cursor.value);
    final changed = widget.onChapterChanged;
    if (changed != null && !_l.isEmpty) {
      final section = _l.units[_cursor.value.clamp(0, _l.units.length - 1)].sectionIndex;
      if (section != _lastSection) {
        _lastSection = section;
        changed(section);
      }
    }
    if (_sleep == SleepChoice.chapterEnd &&
        _sleepChapter >= 0 &&
        _l.chapterOfUnit(_cursor.value) != _sleepChapter) {
      _sleepNow('End of chapter: paused.');
    }
    _schedulePersist();
    _updateSession();
    if (!_detached.value) _reveal(_cursor.value);
  }

  /// Resume following the voice. [force] scrolls even if the paragraph is
  /// already on screen (the "Back to reading" pill).
  void _follow({bool force = false}) {
    _detached.value = false;
    _reveal(_cursor.value, force: force);
  }

  /// Scroll so the sentence being read is in view, unless it already is.
  void _reveal(int unit, {bool force = false}) {
    if (_l.isEmpty || !_scroll.isAttached) return;
    final u = unit.clamp(0, _l.units.length - 1);
    final item = _l.unitItem[u];
    ItemPosition? shown;
    for (final p in _positions.itemPositions.value) {
      if (p.index == item) shown = p;
    }
    var alignment = 0.15;
    if (shown != null) {
      final height = shown.itemTrailingEdge - shown.itemLeadingEdge;
      if (height > 0.75) {
        // A paragraph taller than most of the screen is followed sentence by
        // sentence: where the sentence sits is estimated from its place in
        // the paragraph's text. (Following the paragraph left the voice
        // below the fold until the next one.)
        final text = _l.items[item].block?.text ?? '';
        final frac = text.isEmpty ? 0.0 : (_l.unitOffset[u] / text.length).clamp(0.0, 1.0);
        final at = shown.itemLeadingEdge + frac * height;
        if (!force && at >= 0.05 && at <= 0.75) return;
        alignment = 0.15 - frac * height;
      } else if (!force && shown.itemLeadingEdge >= 0.0 && shown.itemTrailingEdge <= 0.9) {
        return;
      }
    }
    _programmaticScroll = true;
    final duration = Motion.of(context, const Duration(milliseconds: 360));
    // Far away (not laid out) or motion turned down: go straight there. The
    // list would otherwise cross-fade two copies of the text.
    if (shown == null || duration == Duration.zero) {
      _scroll.jumpTo(index: item, alignment: alignment);
      _programmaticScroll = false;
      return;
    }
    unawaited(_scroll
        .scrollTo(index: item, alignment: alignment, duration: duration, curve: Curves.easeInOutCubic)
        .whenComplete(() => _programmaticScroll = false));
  }

  /// Track the chapter at the top of the screen as the page moves.
  void _onPositions() {
    if (_l.isEmpty) return;
    ItemPosition? top;
    for (final p in _positions.itemPositions.value) {
      // What crosses a line a fifth of the way down (below the top bar).
      if (p.index >= _l.items.length || p.itemTrailingEdge <= 0.2) continue;
      if (top == null || p.index < top.index) top = p;
    }
    if (top == null) return;
    final c = _l.items[top.index].chapter;
    if (c == _viewChapter.value) return;
    _viewChapter.value = c;
    // Fetch ahead of where the reader is looking, too.
    if (_detached.value) widget.onChapterChanged?.call(_l.chapters[c]);
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification && n.dragDetails != null) _lastScroll = DateTime.now();
    if (n is ScrollStartNotification && n.dragDetails != null && !_programmaticScroll) {
      _detached.value = true;
    }
    return false;
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1500), () => unawaited(_persist()));
  }

  Future<void> _persist() async {
    final store = widget.store;
    if (store == null || _l.isEmpty) return;
    final u = _cursor.value.clamp(0, _l.units.length - 1);
    try {
      await store.saveCursor(
        _book.id,
        cursorOf(_l.units[u]),
        widget.progressOf?.call(u) ?? progressFraction(_l.units, u),
        where: _l.chapterTitle(_l.unitChapter[u]),
      );
    } on Object {
      // Losing a position save is not worth an error on screen.
    }
  }

  /// Whether a quotation is still open where sentence [u] begins, counted
  /// over its paragraph's text before it: an odd number of straight quotes,
  /// or more opening curly marks than closing ones.
  bool _quoteOpenAt(int u) {
    if (u < 0 || u >= _l.units.length) return false;
    final text = _l.items[_l.unitItem[u]].block?.text ?? '';
    final before = text.substring(0, _l.unitOffset[u].clamp(0, text.length));
    final straight = '"'.allMatches(before).length;
    final opens = RegExp('[“«「]').allMatches(before).length;
    final closes = RegExp('[”»」]').allMatches(before).length;
    return straight.isOdd || opens > closes;
  }

  /// The player's height, so a message shows above it instead of over it.
  final _barKey = GlobalKey();
  double get _barLift => (_barKey.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  void _snack(String text) {
    if (mounted) showSnack(context, text, lift: _barLift);
  }

  // ----------------------------------------------------- keep and share

  /// Keep sentence [unit] (the one being read by default) as a quote or a
  /// bookmark. The message offers Undo, for a save made by mistake.
  Future<Mark?> _save(MarkKind kind, {int? unit, int span = 1, String? note}) async {
    if (_l.isEmpty) return null;
    final u = (unit ?? _cursor.value).clamp(0, _l.units.length - 1);
    final end = (u + span).clamp(u + 1, _l.units.length);
    final text = [for (var i = u; i < end; i++) _l.units[i].text].join(' ');
    final mark = await MarkStore.instance.add(
      bookId: _book.id,
      bookTitle: _book.metadata.title,
      kind: kind,
      at: cursorOf(_l.units[u]),
      span: end - u,
      text: text,
      chapter: _l.chapterTitle(_l.chapterOfUnit(u)),
      note: note,
    );
    if (!mounted) return mark;
    final said = kind == MarkKind.quote ? 'Saved to your quotes.' : 'Bookmarked.';
    showSnack(
      context,
      said,
      lift: _barLift,
      actionLabel: 'Undo',
      onAction: () => unawaited(MarkStore.instance.remove(mark.id)),
    );
    return mark;
  }

  void _share(Mark mark) =>
      unawaited(showQuoteShare(context, mark, cover: _cover, author: _book.metadata.authorLine));

  /// Press and hold on the text: what can be done with that sentence.
  Future<void> _onLongPress(int unit, String word) async {
    if (!mounted || _l.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    final sentence = _l.units[unit].text;
    final web = _entry?.plugin != null;
    final picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => carryTint(
        context,
        SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
                  child: Text(
                    sentence,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Newsreader',
                      fontStyle: FontStyle.italic,
                      fontSize: 16,
                      height: 1.4,
                      color: Skin.inkSoftOn(ctx),
                    ),
                  ),
                ),
                SheetAction(icon: Icons.play_arrow_rounded, label: 'Read from here', onTap: () => Navigator.pop(ctx, 'read')),
                SheetAction(icon: Icons.format_quote_rounded, label: 'Save as a quote', onTap: () => Navigator.pop(ctx, 'quote')),
                SheetAction(
                  icon: Icons.ios_share_rounded,
                  label: 'Share as a picture',
                  onTap: () => Navigator.pop(ctx, 'share'),
                ),
                SheetAction(icon: Icons.bookmark_add_outlined, label: 'Bookmark here', onTap: () => Navigator.pop(ctx, 'bookmark')),
                SheetAction(icon: Icons.copy_rounded, label: 'Copy', onTap: () => Navigator.pop(ctx, 'copy')),
                if (word.isNotEmpty)
                  SheetAction(
                    icon: Icons.record_voice_over_outlined,
                    label: 'Fix how "$word" is said',
                    onTap: () => Navigator.pop(ctx, 'say'),
                  ),
                if (web)
                  SheetAction(
                    icon: Icons.visibility_off_outlined,
                    label: "Don't read lines like this",
                    detail: 'Site notices, credits, links: left out from now on',
                    onTap: () => Navigator.pop(ctx, 'skip'),
                  ),
                const SizedBox(height: Gap.s),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'read':
        await _goTo(unit, play: true);
      case 'quote':
        // Widen it to the sentences around, add a note, then keep it.
        final choice = await showQuoteSheet(context, layout: _l, unit: unit);
        if (choice != null && mounted) {
          await _save(MarkKind.quote, unit: choice.first, span: choice.count, note: choice.note);
        }
      case 'share':
        final mark = await _save(MarkKind.quote, unit: unit);
        if (mark != null && mounted) _share(mark);
      case 'bookmark':
        await _save(MarkKind.bookmark, unit: unit);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: sentence));
        _snack('Copied.');
      case 'say':
        await showSayDialog(
          context,
          word: word,
          bookId: _book.id,
          bookTitle: _book.metadata.title,
          preview: (text) async {
            await _player.stop();
            return speakSample(
              voiceName: _listen.voiceName ?? '',
              text: text,
              settings: _prefs.settings,
              engineId: _prefs.engineId ?? _catalog.engineId,
            );
          },
        );
      case 'skip':
        final plugin = _entry?.plugin;
        if (plugin == null) return;
        final name = (await SourceEngine.instance.store.installedById(plugin))?.name ?? plugin;
        if (!mounted) return;
        if (await showSkipDialog(context, line: sentence, plugin: plugin, siteName: name)) {
          _snack('Lines like that are left out now.');
        }
    }
  }

  // ---------------------------------------------------------------- search

  void _openSearch() {
    if (_l.isEmpty) return;
    unawaited(showBookSearch(
      context,
      layout: _l,
      chapter: _l.chapterOfUnit(_cursor.value),
      onPick: (hits, i, query) {
        setState(() {
          _hits = hits;
          _hit = i;
          _hitQuery = query;
        });
        _detached.value = false;
        unawaited(_goTo(hits[i].unit));
      },
    ));
  }

  void _stepHit(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + delta) % _hits.length);
    unawaited(_goTo(_hits[_hit].unit));
  }

  /// "3 of 12 · ↑ ↓ ✕" while stepping through search matches.
  Widget _matches(BuildContext context) => Material(
        color: Skin.darkOn(context),
        shape: const StadiumBorder(),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.only(left: Gap.l),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  '“$_hitQuery”  ${_hit + 1} of ${_hits.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.onDark(context)),
                ),
              ),
              IconButton(
                tooltip: 'Previous match',
                icon: Icon(Icons.keyboard_arrow_up_rounded, color: Skin.onDark(context)),
                onPressed: () => _stepHit(-1),
              ),
              IconButton(
                tooltip: 'Next match',
                icon: Icon(Icons.keyboard_arrow_down_rounded, color: Skin.onDark(context)),
                onPressed: () => _stepHit(1),
              ),
              IconButton(
                tooltip: 'Done',
                icon: Icon(Icons.close_rounded, color: Skin.onDark(context)),
                onPressed: () => setState(() => _hits = const []),
              ),
            ],
          ),
        ),
      );

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // A phone on its side: the player floats over the foot of the text as
    // one row, so the text keeps the height.
    final rail = size.width > size.height && size.height < 600;
    final bar = _PlayerBar(
      key: _barKey,
      layout: _l,
      cursor: _cursor,
      player: _player,
      speed: _prefs.settings.speedScale,
      voiceLabel: _voiceLabel(),
      sleepNote: _sleepNote,
      onPlay: _togglePlay,
      onPrevSentence: () => _goTo(_cursor.value - 1),
      onNextSentence: () => _goTo(_cursor.value + 1),
      onPrevChapter: () => _goChapter(-1),
      onNextChapter: () => _goChapter(1),
      moreAfter: widget.onReachedEnd != null,
      progressOf: widget.progressOf,
      onSeekInChapter: (u) => _goTo(u),
      onSpeed: () => showListenSheet(context, _listen, focus: ListenFocus.speed),
      onVoice: () => showListenSheet(context, _listen),
      onExpand: _openNowPlaying,
      dock: rail,
      title: _book.metadata.title,
      cover: _cover,
      onSleep: () => showListenSheet(context, _listen),
      onSave: () => unawaited(_save(MarkKind.quote)),
    );
    final reading = Column(
      children: [
        _topBar(context),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _showPages
                    ? PdfPagesView(
                        path: widget.sourcePath!,
                        layout: _l,
                        cursor: _cursor,
                        detached: _detached,
                        onTapPage: (page) => _goTo(_l.unitForPage(page), play: true),
                      )
                    : _text(context),
              ),
              Positioned(
                left: 0,
                right: 0,
                // Above the dock when it floats over the text.
                bottom: rail ? 112 : 10,
                child: Center(child: _hits.isEmpty ? _backToReading(context) : _matches(context)),
              ),
            ],
          ),
        ),
        if (!rail) bar,
      ],
    );
    return PopScope(
      canPop: _hits.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _hits = const []);
      },
      child: Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Stack(
                  children: [
                    reading,
                    // The text fades out before the dock, instead of showing
                    // in the gap beneath it.
                    if (rail)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 96,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Skin.groundFoot(context).withValues(alpha: 0), Skin.groundFoot(context)],
                              stops: const [0, 0.55],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (rail) Positioned(left: 0, right: 0, bottom: 0, child: Center(child: bar)),
                  ],
                ),
        ),
      ),
      ),
    );
  }

  /// The book filling the screen, its words like lyrics.
  void _openNowPlaying() {
    // A swipe and a tap on the handle together must not open it twice.
    if (_nowPlaying?.isActive ?? false) return;
    final from = context;
    final nav = Navigator.of(context);
    final route = PageRouteBuilder<void>(
      transitionDuration: Motion.of(context, Motion.page),
      reverseTransitionDuration: Motion.of(context, Motion.standard),
      pageBuilder: (ctx, _, __) => carryTint(
        from,
        NowPlayingScreen(
          title: _book.metadata.title,
          cover: _cover,
          layout: _l,
          cursor: _cursor,
          player: _player,
          speed: () => _prefs.settings.speedScale,
          voiceLabel: _voiceLabel,
          sleepNote: () => _sleepNote,
          onPlay: _togglePlay,
          onGoTo: (u) => _goTo(u),
          onPrevChapter: () => _goChapter(-1),
          onNextChapter: () => _goChapter(1),
          moreAfter: widget.onReachedEnd != null,
          onSpeed: () => showListenSheet(ctx, _listen, focus: ListenFocus.speed),
          onVoice: () => showListenSheet(ctx, _listen),
          onSleep: () => showListenSheet(ctx, _listen),
          onSave: () => _save(MarkKind.quote),
          onHold: (unit, word) => unawaited(_onLongPress(unit, word)),
        ),
      ),
      transitionsBuilder: (ctx, animation, _, child) => SlideTransition(
        position: animation.drive(
          Tween(begin: const Offset(0, 1), end: Offset.zero).chain(CurveTween(curve: Motion.emphasized)),
        ),
        child: child,
      ),
    );
    _nowPlaying = route;
    _nowPlayingNav = nav;
    unawaited(nav.push(route).whenComplete(() {
      if (identical(_nowPlaying, route)) _nowPlaying = null;
    }));
  }

  String _voiceLabel() {
    final v = _catalog.byName(_listen.voiceName);
    if (v != null) return v.region.isEmpty ? languageName(v.language) : '${v.language.toUpperCase()} · ${regionLabel(v.region)}';
    if (!_catalog.loaded) return 'Voice…';
    return 'No voice';
  }

  Widget _topBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            RoundButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back to library',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Contents',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openContents,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _book.metadata.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 18),
                      ),
                      ListenableBuilder(
                        listenable: _topLine,
                        builder: (context, _) {
                          // The chapter on screen while looking around; the
                          // one being read otherwise.
                          final looking = _detached.value && !_l.isEmpty;
                          final c = looking ? _viewChapter.value : _l.chapterOfUnit(_cursor.value);
                          final u = looking ? _l.chapterFirstUnit[c] : _cursor.value;
                          final style = Skin.meta(context, size: 10.5);
                          if (!(_l.chapters.length > 1 || widget.positionOf != null)) {
                            return Text(
                              _book.metadata.authorLine.isEmpty
                                  ? _book.source.name.toUpperCase()
                                  : _book.metadata.authorLine.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            );
                          }
                          // A long title gives way; the count always shows.
                          return Row(
                            children: [
                              Flexible(
                                child: Text(_l.chapterTitle(c).toUpperCase(),
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                              ),
                              Text(
                                '  ·  ${widget.positionOf?.call(u) ?? '${_chapterNumber(c)}/${_l.chapters.length}'}',
                                maxLines: 1,
                                style: style,
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isPdf) ...[
              const SizedBox(width: 8),
              RoundButton(
                icon: _showPages ? Icons.notes_rounded : Icons.auto_stories_rounded,
                tooltip: _showPages ? 'Show as text' : 'Show the real pages',
                onTap: () {
                  setState(() => _prefs.pdfPages = !_prefs.pdfPages);
                  _prefs.save();
                  _detached.value = false;
                },
              ),
            ],
            const SizedBox(width: 8),
            RoundButton(
              icon: Icons.search_rounded,
              tooltip: 'Search',
              onTap: _openSearch,
            ),
            const SizedBox(width: 8),
            RoundButton(
              icon: Icons.format_list_bulleted_rounded,
              tooltip: 'Contents',
              onTap: _openContents,
            ),
            const SizedBox(width: 8),
            RoundButton(
              icon: Icons.tune_rounded,
              tooltip: 'Listening settings',
              onTap: () => showListenSheet(context, _listen),
            ),
          ],
        ),
      );

  Widget _text(BuildContext context) {
    if (_l.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'This file has no text that can be read aloud.',
            textAlign: TextAlign.center,
            style: Skin.page(context, size: 20),
          ),
        ),
      );
    }
    final initial = _startItem;
    // A wide screen keeps a comfortable line (about 70 characters), centred.
    final side = math.max(_prefs.margin, (MediaQuery.sizeOf(context).width - 720) / 2);
    // Text fades out under the top bar and the player instead of being cut
    // off against them.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
        stops: [0, 18 / rect.height, 1 - 28 / rect.height, 1],
      ).createShader(rect),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: ScrollablePositionedList.builder(
          // One more item at the end when there is more to fetch: the way on.
          itemCount: _l.items.length + (widget.onReachedEnd == null ? 0 : 1),
          itemScrollController: _scroll,
          itemPositionsListener: _positions,
          initialScrollIndex: initial,
          initialAlignment: initial == 0 ? 0 : 0.12,
          padding: EdgeInsets.fromLTRB(side, 16, side, 120),
          itemBuilder: (context, i) => i == _l.items.length ? _more(context) : _item(context, i),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i) {
    final item = _l.items[i];
    final chapterStart = i == _l.chapterFirstItem[item.chapter];
    // Every chapter opens the same way, in the book's colour, so a chapter
    // start is never scrolled past unnoticed.
    final accent = Skin.accentOf(context);
    final label = chapterStart && _l.chapters.length > 1
        ? Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : 56, bottom: 12),
            child: Row(
              children: [
                // A title that carries its own number ("Chapter 3222
                // Liberation") is not given a second one: a site's list
                // can be one off from its titles.
                if (!_digit.hasMatch(_l.chapterTitle(item.chapter))) ...[
                  Text('CHAPTER ${_chapterNumber(item.chapter)}',
                      style: Skin.meta(context, size: 11, color: accent).copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: Gap.m),
                ],
                Expanded(child: Container(height: 1, color: accent.withValues(alpha: 0.35))),
              ],
            ),
          )
        : null;

    if (item.isImage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) label,
          _picture(context, item.block!),
        ],
      );
    }

    if (item.isTitle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) label,
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Text(item.title ?? '',
                style: Skin.title(context, size: 30 * _prefs.textSize / 19, weight: FontWeight.w500)
                    .copyWith(color: accent)),
          ),
        ],
      );
    }

    final heading = item.block!.role == BlockRole.heading;
    final scale = _prefs.textSize / 19;
    final style = heading
        ? Skin.title(context, size: (chapterStart ? 30 : 22) * scale, weight: FontWeight.w500)
            .copyWith(height: 1.2, color: chapterStart ? accent : null)
        : Skin.page(context, size: _prefs.textSize, font: _prefs.bookFont, height: _prefs.lineHeight);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) label,
        Padding(
          padding: EdgeInsets.only(bottom: heading ? 18 : 16, top: heading && !chapterStart ? 12 : 0),
          child: _BlockText(
            item: item,
            layout: _l,
            cursor: _cursor,
            word: _player.word,
            style: style,
            heading: heading && !chapterStart,
            justify: _prefs.justify && !heading,
            onTapUnit: (u) => _goTo(u, play: true),
            onLongPressUnit: _onLongPress,
          ),
        ),
      ],
    );
  }

  /// The end of what has been fetched: carry on to the next chapter.
  Widget _more(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xxl),
        child: Center(
          child: FilledButton.icon(
            onPressed: () async {
              final s = _player.state.value;
              final playing = s == PlayState.playing || s == PlayState.loading;
              // Looking ahead: the place being read is saved and kept.
              await _persist();
              unawaited(widget.onReachedEnd!(playing: playing, browse: true));
            },
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(widget.endLabel ?? 'Next chapter'),
          ),
        ),
      );

  /// A picture from the book, at its natural size up to the column width.
  /// Its space is reserved from the stored pixel size, so the text the voice
  /// is following never jumps when a picture finishes loading.
  Widget _picture(BuildContext context, Block block) {
    final dir = widget.bookDir;
    final iw = block.imageWidth, ih = block.imageHeight;
    if (dir == null || iw == null || ih == null || iw == 0) return const SizedBox.shrink();
    final file = File('$dir/img/${imageFileName(block.image!)}');
    return LayoutBuilder(
      builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // Small ornaments stay small; plates and maps fill the column.
        final width = math.min(c.maxWidth, iw / dpr * 2.2);
        final height = width * ih / iw;
        // A thin, wide picture is a printer's ornament: usually black on
        // white, which on this page is a glaring strip. Draw it in the
        // page's ink with the white taken out.
        final ornament = iw >= ih * 2.5 && height <= 120;
        Widget image = Image.file(
          file,
          width: width,
          height: height,
          fit: BoxFit.contain,
          cacheWidth: (width * dpr).round(),
          errorBuilder: (_, __, ___) => SizedBox(width: width, height: height),
        );
        if (ornament) {
          final ink = Skin.inkSoftOn(context);
          image = ColorFiltered(
            colorFilter: ColorFilter.matrix([
              0, 0, 0, 0, ink.r * 255, //
              0, 0, 0, 0, ink.g * 255, //
              0, 0, 0, 0, ink.b * 255, //
              -0.2126, -0.7152, -0.0722, 1, 0,
            ]),
            child: image,
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: GestureDetector(
              onTap: () => PictureViewer.open(context, file, caption: block.text),
              child: Semantics(
                image: true,
                label: block.text.isEmpty ? 'Picture. Double tap to enlarge' : block.text,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: image,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _backToReading(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _detached,
        builder: (context, detached, _) => AnimatedSlide(
          offset: detached ? Offset.zero : const Offset(0, 1.6),
          duration: Motion.of(context, const Duration(milliseconds: 220)),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: detached ? 1 : 0,
            duration: Motion.of(context, const Duration(milliseconds: 180)),
            child: IgnorePointer(
              ignoring: !detached,
              child: Capsule(
                onTap: () => _follow(force: true),
                color: Skin.darkOn(context),
                border: false,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.my_location_rounded, size: 16, color: Skin.accentOf(context)),
                    const SizedBox(width: Gap.s),
                    Text('Back to reading',
                        style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.onDark(context))),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  int _chapterNumber(int c) => widget.chapterNumberOf?.call(c) ?? c + 1;

  static final _digit = RegExp(r'[0-9]');

  void _openContents() {
    final whole = widget.openContents;
    if (whole != null && !_l.isEmpty) {
      final s = _player.state.value;
      unawaited(_persist());
      whole(
        context,
        section: _l.units[_cursor.value.clamp(0, _l.units.length - 1)].sectionIndex,
        playing: s == PlayState.playing || s == PlayState.loading,
      );
      return;
    }
    if (_l.chapters.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => carryTint(context, _ContentsSheet(
        layout: _l,
        numberOf: _chapterNumber,
        current: _l.chapterOfUnit(_cursor.value),
        onPick: (chapter) {
          Navigator.pop(ctx);
          unawaited(_goTo(_l.chapterFirstUnit[chapter]));
        },
      )),
    );
  }
}

String _primaryLanguage(String? tag) {
  final t = (tag ?? 'en').toLowerCase();
  final p = t.split(RegExp('[-_]')).first;
  return p.length >= 2 ? p : 'en';
}

/// One paragraph. Rebuilds only when the spoken sentence enters, leaves or
/// moves within it — not when anything else in the book changes.
class _BlockText extends StatefulWidget {
  const _BlockText({
    required this.item,
    required this.layout,
    required this.cursor,
    required this.word,
    required this.style,
    required this.onTapUnit,
    required this.onLongPressUnit,
    this.heading = false,
    this.justify = false,
  });

  final LayoutItem item;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final ValueListenable<WordMark> word;
  final TextStyle style;
  final ValueChanged<int> onTapUnit;

  /// Press and hold: the sentence, and the word under the finger.
  final void Function(int unit, String word) onLongPressUnit;

  /// A heading being spoken turns amber rather than sitting in a box.
  final bool heading;
  final bool justify;

  @override
  State<_BlockText> createState() => _BlockTextState();
}

class _BlockTextState extends State<_BlockText> {
  final _key = GlobalKey();
  late int _current = _mine(widget.cursor.value);

  int _mine(int u) => widget.item.containsUnit(u) ? u : -1;

  @override
  void initState() {
    super.initState();
    widget.cursor.addListener(_onCursor);
  }

  @override
  void didUpdateWidget(_BlockText old) {
    super.didUpdateWidget(old);
    if (old.cursor != widget.cursor) {
      old.cursor.removeListener(_onCursor);
      widget.cursor.addListener(_onCursor);
    }
    _current = _mine(widget.cursor.value);
  }

  @override
  void dispose() {
    widget.cursor.removeListener(_onCursor);
    super.dispose();
  }

  void _onCursor() {
    final next = _mine(widget.cursor.value);
    if (next != _current) setState(() => _current = next);
  }

  void _onLongPress(LongPressStartDetails d) {
    final render = _paragraphOf(_key.currentContext?.findRenderObject());
    if (render == null) return;
    final offset = render.getPositionForOffset(render.globalToLocal(d.globalPosition)).offset;
    final l = widget.layout;
    var unit = widget.item.firstUnit;
    for (var u = widget.item.firstUnit; u < widget.item.firstUnit + widget.item.unitCount; u++) {
      if (l.unitOffset[u] <= offset) unit = u;
    }
    widget.onLongPressUnit(unit, wordAt(widget.item.block!.text, offset));
  }

  /// Text may wrap its paragraph in semantics or selection render objects.
  static RenderParagraph? _paragraphOf(RenderObject? r) {
    if (r == null) return null;
    if (r is RenderParagraph) return r;
    RenderParagraph? found;
    r.visitChildren((child) => found ??= _paragraphOf(child));
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final body = _current < 0
        ? _span(context, WordMark.none)
        : ValueListenableBuilder<WordMark>(
            valueListenable: widget.word,
            builder: (context, w, _) => _span(context, w.unit == _current ? w : WordMark.none),
          );
    // A tap does nothing: taps while scrolling kept sending the voice
    // somewhere else. Press and hold, then Read from here. A screen reader's
    // double tap still reads from the paragraph.
    return Semantics(
      button: true,
      hint: 'Double tap to read from here',
      onTap: () => widget.onTapUnit(widget.item.firstUnit),
      child: GestureDetector(onLongPressStart: _onLongPress, child: body),
    );
  }

  Widget _span(BuildContext context, WordMark word) {
    final text = widget.item.block!.text;
    final align = widget.justify ? TextAlign.justify : TextAlign.start;
    if (_current < 0) {
      return Text.rich(TextSpan(text: text), key: _key, style: widget.style, textAlign: align);
    }
    final l = widget.layout;
    final s = l.unitOffset[_current].clamp(0, text.length);
    final e = (s + l.units[_current].text.length).clamp(s, text.length);
    final wash = widget.heading ? Skin.sentenceWash(context).withValues(alpha: 0.08) : Skin.sentenceWash(context);
    final spoken = widget.heading ? TextStyle(color: Skin.accentOf(context)) : null;
    final spans = <InlineSpan>[
      if (s > 0) TextSpan(text: text.substring(0, s)),
    ];
    final ws = word.start < 0 ? -1 : (s + word.start).clamp(s, e);
    final we = word.start < 0 ? -1 : (s + word.end).clamp(ws, e);
    final sentence = TextStyle(backgroundColor: wash, color: spoken?.color);
    if (ws < 0 || we <= ws) {
      spans.add(TextSpan(text: text.substring(s, e), style: sentence));
    } else {
      spans
        ..add(TextSpan(text: text.substring(s, ws), style: sentence))
        ..add(TextSpan(
          text: text.substring(ws, we),
          style: TextStyle(backgroundColor: Skin.wordWash(context), color: spoken?.color),
        ))
        ..add(TextSpan(text: text.substring(we, e), style: sentence));
    }
    if (e < text.length) spans.add(TextSpan(text: text.substring(e)));
    return Text.rich(TextSpan(children: spans), key: _key, style: widget.style, textAlign: align);
  }
}

/// The player: what is playing, how fast, in whose voice, and the controls.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    super.key,
    required this.layout,
    required this.cursor,
    required this.player,
    required this.speed,
    required this.voiceLabel,
    this.sleepNote,
    required this.onPlay,
    required this.onPrevSentence,
    required this.onNextSentence,
    required this.onPrevChapter,
    required this.onNextChapter,
    this.moreAfter = false,
    this.progressOf,
    required this.onSeekInChapter,
    required this.onSpeed,
    required this.onVoice,
    required this.onExpand,
    this.dock = false,
    this.title = '',
    this.cover,
    this.onSleep,
    this.onSave,
  });

  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final PlaybackScheduler player;
  final double speed;
  final String voiceLabel;
  final String? sleepNote;
  final VoidCallback onPlay;
  final VoidCallback onPrevSentence;
  final VoidCallback onNextSentence;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;

  /// Chapters follow the last one here (a web novel's, still on the site).
  final bool moreAfter;

  /// As [ReaderScreen.progressOf]. When set, this layout is only part of
  /// the work, so the time shown is what is left of the chapter.
  final double Function(int u)? progressOf;
  final ValueChanged<int> onSeekInChapter;
  final VoidCallback onSpeed;
  final VoidCallback onVoice;

  /// Open Now Playing: swipe the bar up, or tap its handle.
  final VoidCallback onExpand;

  /// A phone on its side: one floating row over the text (see [_dock]).
  final bool dock;

  /// The book and its shown cover, for the dock.
  final String title;
  final String? cover;
  final VoidCallback? onSleep;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -250) onExpand();
        },
        child: dock ? _dock(context) : _bar(context),
      );

  /// Where [u] stands: its chapter, the chapter's span, the minutes left and
  /// how far through (of the chapter when this layout is part of the work).
  ({int chapter, int first, int count, int minutes, int pct}) _at(int u) {
    if (layout.isEmpty) return (chapter: 0, first: 0, count: 1, minutes: 0, pct: 0);
    final chapter = layout.chapterOfUnit(u);
    final (first, count) = layout.chapterRange(chapter);
    final end = first + count;
    final upTo = progressOf != null && end < layout.units.length ? layout.wordsBefore[end] : layout.totalWords;
    final wordsLeft = upTo - layout.wordsBefore[u];
    return (
      chapter: chapter,
      first: first,
      count: count,
      minutes: (wordsLeft / (165 * speed)).round(),
      pct: ((progressOf?.call(u) ?? progressFraction(layout.units, u)) * 100).round(),
    );
  }

  /// The handle: says the bar swipes up to Now Playing, and opens it on a tap.
  Widget _handle(BuildContext context, {double below = 6}) => Semantics(
        button: true,
        label: 'Open Now Playing',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onExpand,
          child: Padding(
            padding: EdgeInsets.only(bottom: below),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Skin.onDark(context).withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      );

  /// Landscape: everything the portrait bar has, and sleep and save, as one
  /// floating row in the book's colour, so the text keeps the screen's height
  /// (the bar as a column beside it left half the column empty).
  Widget _dock(BuildContext context) {
    final onDark = Skin.onDark(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 980),
      margin: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.s),
      padding: const EdgeInsets.fromLTRB(Gap.s, Gap.s, Gap.s, Gap.xs),
      decoration: BoxDecoration(
        color: Color.lerp(Skin.darkOn(context), Skin.accentOf(context), 0.16),
        borderRadius: BorderRadius.circular(Radii.card + 4),
        boxShadow: Skin.lift(context),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: cursor,
        builder: (context, u, _) {
          final empty = layout.isEmpty;
          final at = _at(u);
          final inChapter = (u - at.first).clamp(0, at.count - 1);
          final partial = progressOf != null;
          final left = partial ? '${_duration(at.minutes)} left in chapter' : '${_duration(at.minutes)} left';
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _handle(context, below: 2),
              // Three parts: the book at the left and the options at the
              // right share what is left equally, so the controls sit in the
              // very middle of the bar.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Semantics(
                          button: true,
                          label: 'Open Now Playing',
                          child: GestureDetector(
                            onTap: onExpand,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 40,
                                height: 58,
                                child: cover == null
                                    ? ColoredBox(
                                        color: Skin.accentOf(context).withValues(alpha: 0.35),
                                        child: Icon(Icons.menu_book_rounded, size: 18, color: onDark),
                                      )
                                    : Image.file(File(cover!), fit: BoxFit.cover, cacheWidth: 120, gaplessPlayback: true),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                empty ? title : layout.chapterTitle(at.chapter),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.ui(size: 13.5, weight: FontWeight.w600, color: onDark),
                              ),
                              Text(
                                [if (sleepNote == null) '${at.pct}%', left.toUpperCase(), if (sleepNote != null) sleepNote!]
                                    .join('  ·  '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.meta(context, color: onDark.withValues(alpha: 0.62), size: 10),
                              ),
                              ChapterScrubber(
                                value: at.count <= 1 ? 0 : inChapter / (at.count - 1),
                                onSeek: at.count <= 1 ? null : (f) => onSeekInChapter(at.first + (f * (at.count - 1)).round()),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Gap.l),
                      ],
                    ),
                  ),
                  _icon(context, Icons.skip_previous_rounded, 'Previous chapter', at.chapter > 0 ? onPrevChapter : null),
                  _icon(context, Icons.fast_rewind_rounded, 'Previous sentence', u > 0 ? onPrevSentence : null),
                  PlayButton(player: player, onTap: empty ? null : onPlay),
                  _icon(context, Icons.fast_forward_rounded, 'Next sentence',
                      u < layout.units.length - 1 ? onNextSentence : null),
                  _icon(context, Icons.skip_next_rounded, 'Next chapter',
                      at.chapter < layout.chapters.length - 1 || moreAfter ? onNextChapter : null),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: Gap.l),
                      // On a narrower phone, sleep and save (both in Now
                      // Playing too) step aside before the row overflows.
                      child: LayoutBuilder(
                        builder: (context, box) => Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _chip(context, '${trimSpeed(speed)}×', Icons.speed_rounded, onSpeed, tooltip: 'Speed'),
                            if (onSleep != null && box.maxWidth >= 200)
                              _small(context, sleepNote == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                                  'Sleep timer', onSleep!, lit: sleepNote != null),
                            if (onSave != null && box.maxWidth >= 250)
                              _small(context, Icons.bookmark_add_outlined, 'Save this line', onSave!),
                            Flexible(
                              child: _chip(context, voiceLabel, Icons.record_voice_over_rounded, onVoice, tooltip: 'Voice'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _small(BuildContext context, IconData icon, String tip, VoidCallback onTap, {bool lit = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: 21,
        visualDensity: VisualDensity.compact,
        color: lit ? Skin.accentSoftOf(context) : Skin.onDark(context),
        icon: Icon(icon),
      );

  Widget _bar(BuildContext context) {
    final onDark = Skin.onDark(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.m),
      padding: const EdgeInsets.fromLTRB(14, Gap.m, 14, 10),
      decoration: BoxDecoration(
        color: Skin.darkOn(context),
        borderRadius: BorderRadius.circular(Radii.card + 4),
        boxShadow: Skin.lift(context),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: cursor,
        builder: (context, u, _) {
          final empty = layout.isEmpty;
          final (:chapter, :first, :count, :minutes, :pct) = _at(u);
          final inChapter = (u - first).clamp(0, count - 1);
          final partial = progressOf != null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _handle(context),
              Row(
                children: [
                  _chip(context, '${trimSpeed(speed)}×', Icons.speed_rounded, onSpeed,
                      tooltip: 'Speed'),
                  Expanded(
                    child: Text(
                      // With a sleep timer there is no room for all three.
                      [
                        if (sleepNote == null) '$pct%',
                        partial ? '${_duration(minutes)} LEFT IN CHAPTER' : '${_duration(minutes)} LEFT',
                        if (sleepNote != null) sleepNote!,
                      ].join('  ·  '),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.meta(context, color: onDark.withValues(alpha: 0.62), size: 10.5),
                    ),
                  ),
                  _chip(context, voiceLabel, Icons.record_voice_over_rounded, onVoice,
                      tooltip: 'Voice'),
                ],
              ),
              const SizedBox(height: 6),
              ChapterScrubber(
                value: count <= 1 ? 0 : inChapter / (count - 1),
                onSeek: count <= 1 ? null : (f) => onSeekInChapter(first + (f * (count - 1)).round()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _icon(context, Icons.skip_previous_rounded, 'Previous chapter',
                      chapter > 0 ? onPrevChapter : null),
                  _icon(context, Icons.fast_rewind_rounded, 'Previous sentence',
                      u > 0 ? onPrevSentence : null),
                  PlayButton(player: player, onTap: empty ? null : onPlay),
                  _icon(context, Icons.fast_forward_rounded, 'Next sentence',
                      u < layout.units.length - 1 ? onNextSentence : null),
                  _icon(context, Icons.skip_next_rounded, 'Next chapter',
                      chapter < layout.chapters.length - 1 || moreAfter ? onNextChapter : null),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _icon(BuildContext context, IconData icon, String tip, VoidCallback? onTap) {
    final onDark = Skin.onDark(context);
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      iconSize: 26,
      color: onDark,
      disabledColor: onDark.withValues(alpha: 0.25),
      icon: Icon(icon),
    );
  }

  Widget _chip(BuildContext context, String label, IconData icon, VoidCallback onTap,
      {required String tooltip}) {
    final onDark = Skin.onDark(context);
    return Tooltip(
      message: tooltip,
      child: Capsule(
        onTap: onTap,
        border: false,
        color: Colors.white.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 7),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Skin.accentSoftOf(context)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Skin.ui(size: 13, weight: FontWeight.w600, color: onDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentsSheet extends StatefulWidget {
  const _ContentsSheet({
    required this.layout,
    required this.numberOf,
    required this.current,
    required this.onPick,
  });

  final ReadingLayout layout;
  final int Function(int chapter) numberOf;
  final int current;
  final ValueChanged<int> onPick;

  @override
  State<_ContentsSheet> createState() => _ContentsSheetState();
}

class _ContentsSheetState extends State<_ContentsSheet> {
  static const _rowHeight = 58.0;
  String _query = '';
  late final _controller = ScrollController(
    initialScrollOffset: ((widget.current - 2) * _rowHeight).clamp(0, double.infinity).toDouble(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.layout;
    final q = _query.trim().toLowerCase();
    final rows = [
      for (var c = 0; c < l.chapters.length; c++)
        if (q.isEmpty || l.chapterTitle(c).toLowerCase().contains(q) || '${widget.numberOf(c)}' == q) c,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(
              'Contents',
              trailing: Text(
                '${l.chapters.length} ${l.chapters.length == 1 ? 'CHAPTER' : 'CHAPTERS'}',
                style: Skin.meta(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
              child: SearchField(
                hint: 'Find a chapter',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text('No chapters match.', style: Skin.label(context, size: 15)),
                    )
                  : ChapterList(
                      layout: l,
                      numberOf: widget.numberOf,
                      chapters: rows,
                      current: widget.current,
                      controller: q.isEmpty ? _controller : null,
                      rowHeight: _rowHeight,
                      onPick: widget.onPick,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A book's chapters: number, title, the one being read marked. Parts
/// ("Part II: Reborn") read as dividers above the chapters they hold.
class ChapterList extends StatelessWidget {
  const ChapterList({
    super.key,
    required this.layout,
    required this.chapters,
    required this.current,
    required this.onPick,
    this.numberOf,
    this.controller,
    this.rowHeight = 56,
    this.shrinkWrap = false,
  });

  final ReadingLayout layout;

  /// The number shown for a chapter; its place in [layout] by default.
  final int Function(int chapter)? numberOf;
  final List<int> chapters;
  final int current;
  final ValueChanged<int> onPick;
  final ScrollController? controller;
  final double rowHeight;
  final bool shrinkWrap;

  static final _part = RegExp(r'^(part|book|volume|act)\b', caseSensitive: false);

  @override
  Widget build(BuildContext context) => ListView.builder(
        controller: controller,
        shrinkWrap: shrinkWrap,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xl),
        itemExtent: rowHeight,
        itemCount: chapters.length,
        itemBuilder: (context, i) => chapterRow(context, chapters[i]),
      );

  Widget chapterRow(BuildContext context, int c) {
    final isCurrent = c == current;
    final title = layout.chapterTitle(c);
    final part = _part.hasMatch(title);
    return Material(
      color: isCurrent ? Skin.accentOf(context).withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.row),
        onTap: () => onPick(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.m),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text('${numberOf?.call(c) ?? c + 1}',
                    style: Skin.meta(context, size: 11.5, color: isCurrent ? Skin.accentOf(context) : null)),
              ),
              Expanded(
                child: part
                    ? Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.meta(context, size: 12, color: isCurrent ? Skin.accentOf(context) : Skin.inkSoftOn(context)),
                      )
                    : Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 17, color: isCurrent ? Skin.accentOf(context) : null),
                      ),
              ),
              if (isCurrent) Icon(Icons.graphic_eq_rounded, size: 18, color: Skin.accentOf(context)),
            ],
          ),
        ),
      ),
    );
  }
}

String _duration(int minutes) {
  if (minutes < 60) return '${minutes}M';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}H' : '${h}H ${m}M';
}

/// Kept so the batch measurement path still has a JSON shape to write.
String encodeReport(Map<String, Object?> m) =>
    const JsonEncoder.withIndent('  ').convert(m);

/// The word around [offset] in [text] (letters, digits, apostrophes,
/// hyphens), or the one just beside it; empty far from any word.
String wordAt(String text, int offset) {
  final letter = RegExp(r"[\p{L}\p{N}'’-]", unicode: true);
  bool isLetter(int i) => i >= 0 && i < text.length && letter.hasMatch(text[i]);
  var i = offset.clamp(0, text.length);
  // A finger on a space or a comma means the word beside it.
  if (!isLetter(i)) {
    i = [i - 1, i + 1, i - 2, i + 2].firstWhere(isLetter, orElse: () => -1);
    if (i < 0) return '';
  }
  var s = i;
  var e = i;
  while (isLetter(s - 1)) {
    s--;
  }
  while (isLetter(e)) {
    e++;
  }
  return text.substring(s, e).replaceAll(RegExp(r"^['’-]+|['’-]+$"), '');
}
