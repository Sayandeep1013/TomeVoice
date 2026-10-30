import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback, SystemChrome, SystemUiMode, SystemUiOverlayStyle;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'chapter_finder.dart';
import 'export_audio_sheet.dart';
import 'fast_scroller.dart';
import 'highlights.dart';
import 'library_store.dart';
import 'book_search.dart';
import 'listen_sheet.dart';
import 'listening_session.dart';
import 'marks.dart';
import 'neural_voices.dart';
import 'now_playing.dart';
import 'page_tone.dart';
import 'paged_view.dart';
import 'pages_view.dart';
import 'player_controls.dart';
import 'prefs.dart';
import 'quote_sheet.dart';
import 'reader_player_bar.dart';
import 'reader_text.dart';
import 'reading_rules.dart';
import 'rules_screen.dart';
import 'share_card.dart';
import 'sources/source_engine.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'stats.dart';
import 'theme.dart';
import 'ui.dart';
import 'voice_glow.dart';
import 'voices.dart';
import 'web_reader.dart';

export 'reader_text.dart' show directionOfLanguage, wordAt;

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

  /// The reader's first frame is heavy (every paragraph on screen laid
  /// out): it waits for the page to finish sliding in, so the two do not
  /// share frames and the slide does not stutter.
  bool _arrived = false;
  Animation<double>? _arriving;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arrived || _arriving != null) return;
    final a = ModalRoute.of(context)?.animation;
    if (a == null || a.isCompleted) {
      _arrived = true;
      return;
    }
    _arriving = a..addStatusListener(_onArrival);
  }

  void _onArrival(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _arriving?.removeStatusListener(_onArrival);
    if (mounted) setState(() => _arrived = true);
  }

  @override
  void dispose() {
    _arriving?.removeStatusListener(_onArrival);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _load,
        builder: (context, snap) {
          final data = snap.data;
          // The book fades in over the frame it opened with.
          return FadeIn(
            key: ValueKey(data != null && _arrived),
            child: data != null && _arrived
                ? ReaderScreen(
                    layout: data.$1,
                    store: widget.store,
                    initialCursor: data.$2,
                    autoplay: widget.autoplay,
                    bookDir: widget.store.bookDir(widget.entry.id),
                    sourcePath: widget.entry.sourcePath,
                  )
                : _ReaderSkeleton(
                    title: widget.entry.title,
                    error: snap.hasError ? '${snap.error}' : null,
                  ),
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
          // Two less each way round the back button: its target is 48 dp,
          // its circle 44, and the circle stays where it was.
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
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
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.title(context, size: 18)),
                    ),
                  ],
                ),
                const SizedBox(height: 26),
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
      ValueNotifier(_l.isEmpty
          ? 0
          // A place saved before is restored as it was; a book opened
          // for the first time skips a title page named like it.
          : _l.unitForCursor(widget.initialCursor, saved: widget.initialCursor != ReadingCursor.zero));
  final _detached = ValueNotifier<bool>(false);

  /// The text faded out for a moment, while it travels a long way to the voice.
  final _veiled = ValueNotifier<bool>(false);

  /// The sentence washed on the page: the place, while it is read aloud,
  /// and when the book opens (where you left off); -1 once the reader has
  /// read on without the voice, when a wash moving with the eyes would only
  /// be in the way.
  final _marked = ValueNotifier<int>(-1);
  bool _placeShown = true;

  /// Set while the place follows the reader's eyes, so the page is not
  /// moved to it: it is already where they are looking.
  bool _quiet = false;

  /// A drag began while nothing was being read aloud: once the page
  /// settles, the place moves to what is being read.
  bool _eyes = false;
  Timer? _eyesTimer;

  /// Where the reader was before a jump (Contents, a search match), while
  /// reading without the voice: "Back to where you were".
  int? _returnTo;

  /// Sentences with a bookmark in this book, and whether the page (or the
  /// paragraph read) shown has one: the ribbon, and the bar's button.
  final _markedUnits = ValueNotifier<Set<int>>(const {});
  final _bookmarkedHere = ValueNotifier<bool>(false);

  /// Saved quotes, washed on the page in their colours.
  late final _highlights = Highlights(_l);

  /// Pages: turned from outside, and the reader's bars shown over them.
  final _paged = PagedController();
  final _chrome = ValueNotifier<bool>(false);

  /// A PDF's real pages, turned from outside (the page keys).
  final _pdf = PdfPagesController();

  /// The ground under the page, which the fades at the text's edges draw
  /// again over it (see [GroundFade]).
  final _groundLink = LayerLink();

  /// The scroll's top bar and player: there until a tap on the text puts
  /// them away for reading alone, and back with another.
  final _scrollBars = ValueNotifier<bool>(true);

  /// When the scroll last moved: a tap that stops a fling is not a tap
  /// for the bars.
  DateTime? _lastMove;
  bool _tapStopsScroll = false;

  /// The first sentence of the page shown, in pages.
  int? _pageUnit;

  /// Where pages open (the place on screen when they were turned on), and
  /// where the scrolling page opens when it comes back from them.
  int? _pageStart;
  int? _scrollFrom;
  bool _wasPaged = false;
  Object? _layoutKey;
  bool _fullScreen = false;
  bool _volumeKeys = false;

  /// The safe area the page is laid out in and the size it was for (see
  /// [_steadyInsets]); whether the app is away, or only just back; and the
  /// waits before a change of insets is followed.
  EdgeInsets? _insets;
  Size? _insetsFor;
  bool _away = false;
  Timer? _backTimer;
  Timer? _insetsTimer;

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

  /// Scrolls the page by a distance, for travelling far.
  final _offsets = ScrollOffsetController();

  /// The page's height on screen, for travelling far.
  double _viewport = 600;
  final _positions = ItemPositionsListener.create();

  late final PlaybackScheduler _player;
  ListeningPrefs _prefs = ListeningPrefs.memory;
  final _catalog = VoiceCatalog.instance;
  late final String _language = primaryLanguage(_book.metadata.language);

  /// Arabic, Hebrew and the other right-to-left scripts are set and turned
  /// that way (they were laid out left to right).
  late final TextDirection _direction = directionOfLanguage(_language);

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _persistTimer;
  Timer? _restartTimer;

  /// Paused for the phone's audio taken a moment (a ping, a call): resumed
  /// when it comes back, unless that took longer than resumeAfterLossWithin.
  bool _resumeOnFocus = false;
  Timer? _lossTimer;
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
    // This book reading on in the background: take its voice back, still
    // reading, so opening the book again does not break the flow.
    final bg = BackgroundReading.current.value;
    final back = bg != null && bg.bookId == _book.id ? bg.takeBack(_l) : null;
    var resumeAt = -1;
    if (bg != null && bg.bookId == _book.id && back == null) {
      // Its chapters changed meanwhile (a web novel): start again here.
      final u = bg.unitIn(_l);
      if (bg.playing) resumeAt = u;
      _cursor.value = u;
      unawaited(bg.stop());
    }
    _player = back?.player ??
        readingScheduler(layout: _l, prefs: () => _prefs, language: _language, bookId: _book.id, service: _svc);
    _player.onFinished = _onFinished;
    if (back != null) {
      _cursor.value = _player.unit.value;
      _restoreSleep(back.sleep, back.sleepAt, back.sleepChapter);
    }
    _player.unit.addListener(_onPlayerUnit);
    _player.state.addListener(_onPlayState);
    _player.word.addListener(_onWord);
    _player.notice.addListener(_onNotice);
    _cursor.addListener(_syncMarked);
    _cursor.addListener(_onCursor);
    _syncMarked();
    MarkStore.instance.changes.addListener(_onMarks);
    _onMarks();
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
    if (resumeAt >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_player.play(_cursor.value));
      });
    } else if (widget.autoplay && back == null) {
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

  void _onPlayerUnit() => _cursor.value = _player.unit.value;

  /// A line from the player while it reads on (a natural voice that failed,
  /// and the phone's reading instead).
  void _onNotice() {
    final note = _player.notice.value;
    if (note != null) _snack(note);
  }

  /// The sleep timer as the background reading left it. A time already
  /// past fired there, and is not armed again (it paused the book a second
  /// time when it was opened).
  void _restoreSleep(SleepChoice choice, DateTime? at, int chapter) {
    final live = at != null && at.isAfter(DateTime.now());
    _sleep = at != null && !live ? SleepChoice.off : choice;
    _sleepAt = live ? at : null;
    _sleepChapter = chapter;
    if (live) {
      _player.fadeOutBy(at);
      _sleepTimer = Timer(at.difference(DateTime.now()), () => _sleepNow('Sleep timer: paused.'));
      _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted && _sleepAt != null) setState(() {});
      });
    }
  }

  /// The page is being left by Back (not replaced by another chapter's).
  bool _leaving = false;

  /// The voice went on past this page's chapters without it (see
  /// [_readOn]): the reading, the card and the place are the background
  /// reading's until the page for those chapters takes them back.
  bool _handedOn = false;

  /// Reading aloud goes on without this page: back goes to the library and
  /// the voice reads on there (Settings > Listening).
  bool get _readsOn =>
      _leaving && _prefs.keepReading && _player.state.value != PlayState.idle && !_l.isEmpty && widget.store != null;

  Future<void> _loadPrefs() async {
    final dir = widget.store?.root.path;
    if (dir == null) return;
    final p = await ListeningPrefs.load(dir);
    if (!mounted) return;
    setState(() => _prefs = p);
    _wasPaged = _inPages;
    _layoutKey = _layoutOf(p);
    _applyScreenOn();
    _applyReadingMode();
    _warmVoice();
    if (p.engineId != null && p.engineId != _catalog.engineId) {
      await _catalog.ensureLoaded();
      await _catalog.switchEngine(p.engineId!);
    }
  }

  /// A natural voice is loaded while the page settles, so Play does not
  /// wait for it (a second or two, longer for HD, the first time); a natural
  /// dialogue voice too, where the phone keeps two loaded (with room for
  /// one, loading it would only push the narrator out).
  void _warmVoice() {
    final listen = _listen;
    final narrator = neuralVoiceFor(listen.voiceName);
    final dialogue = neuralVoiceFor(listen.dialogueVoice);
    final voices = [
      if (narrator != null) narrator,
      if (dialogue != null && (narrator == null || NeuralEngine.instance.holdsTwo)) dialogue,
    ];
    if (voices.isEmpty) return;
    Timer(const Duration(milliseconds: 1200), () async {
      for (final v in voices) {
        if (!mounted || _player.state.value != PlayState.idle) return;
        await NeuralEngine.instance.warm(v);
      }
    });
  }

  Future<void> _loadCover() async {
    final store = widget.store;
    if (store == null) return;
    try {
      final entry = (await store.list(all: true)).where((e) => e.id == _book.id).firstOrNull;
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
    final paged = _inPages;
    if (paged != _wasPaged) {
      // Pages open at what is on screen; the scroll comes back at the page.
      if (paged) {
        _pageStart = _detached.value ? (_unitAtEyes() ?? _cursor.value) : _cursor.value;
        _pageUnit = null;
      } else {
        _scrollFrom = _l.unitItem[(_pageUnit ?? _cursor.value).clamp(0, _l.units.length - 1)];
      }
      _wasPaged = paged;
      _chrome.value = false;
      _scrollBars.value = true;
    } else if (!paged && _layoutOf(_prefs) != _layoutKey) {
      _keepAnchor();
    }
    _layoutKey = _layoutOf(_prefs);
    _applyReadingMode();
    setState(() {});
  }

  /// What moves the scrolling page's lines when it changes.
  static Object _layoutOf(ListeningPrefs p) =>
      Object.hash(p.textSize, p.bookFont, p.lineHeight, p.margin, p.justify, p.indent);

  /// Text reflowing for a new size, font or spacing: the paragraph at the
  /// top of the screen stays where it is. (The list keeps an item of its
  /// own choosing in place, and the text slid away under the reader.)
  void _keepAnchor() {
    if (_l.isEmpty || !_scroll.isAttached || _programmaticScroll) return;
    ItemPosition? top;
    for (final p in _positions.itemPositions.value) {
      if (p.index >= _l.items.length || p.itemTrailingEdge <= 0) continue;
      if (top == null || p.index < top.index) top = p;
    }
    final at = top;
    if (at == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.isAttached) return;
      if (_listening && !_detached.value) {
        _reveal(_cursor.value);
      } else {
        _scroll.jumpTo(index: at.index, alignment: at.itemLeadingEdge);
      }
    });
  }

  /// The book in pages (not a PDF's real pages).
  bool get _inPages => _prefs.pages && !_showPages && !_l.isEmpty;

  /// A PDF's real pages, turned as a book's: the page keys turn them too.
  bool get _pdfBook => _prefs.pages && _showPages && !_l.isEmpty;

  /// The voice is reading, or paused in the middle of it.
  bool get _listening => _player.state.value != PlayState.idle;

  /// Full screen and the volume keys, as the prefs and the moment ask. The
  /// keys turn pages only while nothing is read aloud: then they are for
  /// the volume.
  void _applyReadingMode() {
    final full = _prefs.fullScreen;
    if (full != _fullScreen) {
      _fullScreen = full;
      unawaited(SystemChrome.setEnabledSystemUIMode(full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
    }
    final keys = _prefs.volumeKeys && (_inPages || _pdfBook) && !_player.isPlaying;
    if (keys != _volumeKeys) {
      _volumeKeys = keys;
      unawaited(_svc.volumeKeysTurnPages(keys));
    }
  }

  void _syncMarked() => _marked.value = _placeShown ? _cursor.value : -1;

  void _showPlace(bool on) {
    _placeShown = on;
    _syncMarked();
  }

  /// Now Playing, while it is open over this reader, and the navigator it is on.
  Route<void>? _nowPlaying;
  NavigatorState? _nowPlayingNav;

  /// Now Playing's screen, for where a message sits over it (see
  /// [_snackMargin]); a new key each time it opens.
  GlobalKey _nowPlayingKey = GlobalKey();

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
    _eyesTimer?.cancel();
    _backTimer?.cancel();
    _insetsTimer?.cancel();
    if (_fullScreen) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    if (_volumeKeys) unawaited(_svc.volumeKeysTurnPages(false));
    WidgetsBinding.instance.removeObserver(this);
    ListeningPrefs.revision.removeListener(_onPrefs);
    ReadingRules.instance.changes.removeListener(_onRules);
    if (_screenOn) unawaited(_svc.keepScreenOn(false));
    _persistTimer?.cancel();
    _restartTimer?.cancel();
    _sleepTimer?.cancel();
    _lossTimer?.cancel();
    _statsTimer?.cancel();
    _countTime();
    unawaited(StatsStore.instance.flush());
    unawaited(_persist());
    unawaited(_events?.cancel());
    _catalog.removeListener(_onCatalog);
    _player.word.removeListener(_onWord);
    _player.notice.removeListener(_onNotice);
    if (_handedOn) {
      // The voice went on without this page (into the next chapters): the
      // card and the stream are the background reading's now, unless Back
      // left the book with reading on after leaving turned off.
      final bg = BackgroundReading.current.value;
      if (_leaving && !_prefs.keepReading && bg != null && bg.bookId == _book.id) unawaited(bg.stop());
      _player.dispose();
    } else if (_readsOn) {
      _player.unit.removeListener(_onPlayerUnit);
      _player.state.removeListener(_onPlayState);
      _player.onFinished = null;
      BackgroundReading.adopt(
        player: _player,
        layout: _l,
        store: widget.store!,
        bookId: _book.id,
        title: _book.metadata.title,
        cover: _cover,
        language: _language,
        web: widget.onReachedEnd != null,
        sleepAt: _sleepAt,
        sleepChapter: _sleepChapter,
        sleep: _sleep,
      );
    } else {
      // Only a page whose voice was on the card takes the card away: an idle
      // page of another book must not end one reading in the background.
      if (_sessionState != PlayState.idle) unawaited(_svc.session(active: false));
      _player.dispose();
    }
    _positions.itemPositions.removeListener(_onPositions);
    _cursor.dispose();
    _detached.dispose();
    _veiled.dispose();
    _marked.dispose();
    MarkStore.instance.changes.removeListener(_onMarks);
    _markedUnits.dispose();
    _bookmarkedHere.dispose();
    _highlights.dispose();
    _chrome.dispose();
    _scrollBars.dispose();
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
    _insetsTimer?.cancel();
    _backTimer?.cancel();
    if (state != AppLifecycleState.resumed) {
      _away = true;
      return;
    }
    // Back in front: the phone's bars a system sheet brought go again in a
    // moment. Insets still changed after that are followed.
    _backTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _away = false;
      setState(() {});
    });
  }

  /// The safe area the page is laid out in. In full screen, a system sheet
  /// over the app (Look up's choice of apps) brings the phone's bars back,
  /// and they go again as it closes: followed, the pages were cut afresh
  /// behind the sheet and again after it, and the page jumped. So in full
  /// screen new insets at the same size are held while the app is away and
  /// a moment after it is back, and bars that appear are held a moment with
  /// it in front too (the sheet can come before the app is told it is away);
  /// a change still there then is followed. A new size (the phone turned) is
  /// followed at once, and so is room given back (bars gone).
  EdgeInsets _steadyInsets(BuildContext context) {
    final now = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final held = _insets;
    if (!_prefs.fullScreen || held == null || size != _insetsFor) {
      _insetsTimer?.cancel();
      _insets = now;
      _insetsFor = size;
      return now;
    }
    if (now == held) {
      _insetsTimer?.cancel();
      return held;
    }
    if (_away) return held;
    final grew = now.left > held.left || now.top > held.top || now.right > held.right || now.bottom > held.bottom;
    if (!grew) {
      _insetsTimer?.cancel();
      _insets = now;
      return now;
    }
    if (!(_insetsTimer?.isActive ?? false)) {
      _insetsTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && !_away) setState(() => _insets = null);
      });
    }
    return held;
  }

  /// The width the scroll was last laid out at.
  double? _laidWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Turned on its side (or into a split screen), the text reflows: the
    // paragraph at the top stays there, as for a new text size.
    final width = MediaQuery.sizeOf(context).width;
    if (_laidWidth != null && width != _laidWidth && !_inPages) _keepAnchor();
    _laidWidth = width;
  }

  /// Read on past the chapters here (a web novel's, the rest still on the
  /// site), handing the voice to the reading that goes on without a page.
  /// Building the next chapters' page waits for a frame, and with the screen
  /// off none comes: the voice stopped at the end of what was fetched. The
  /// background reading needs none, keeps the card up meanwhile (Android 12
  /// may refuse to start it again from the background), and the next page
  /// takes the voice back when it is built. False with nowhere to hand it.
  Future<bool> _readOn() async {
    final store = widget.store;
    if (_handedOn || store == null || _l.isEmpty) return false;
    _handedOn = true;
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    // Its own voice stops (it may be mid-chapter: Next chapter at the
    // last one), leaving the card up for the reading that carries on.
    await _player.stop();
    _player.endFade();
    if (!mounted) return false;
    final bg = BackgroundReading.adopt(
      player: readingScheduler(layout: _l, prefs: () => _prefs, language: _language, bookId: _book.id, service: _svc),
      layout: _l,
      store: store,
      bookId: _book.id,
      title: _book.metadata.title,
      cover: _cover,
      language: _language,
      web: true,
      sleepAt: _sleepAt,
      sleepChapter: _sleepChapter,
      sleep: _sleep,
    );
    unawaited(bg.readOn());
    return true;
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
        settings: _prefs.settingsFor(voiceName, book: _book.id),
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
      final at = DateTime.now().add(d);
      _sleepAt = at;
      _sleepTimer = Timer(d, () => _sleepNow('Sleep timer: paused.'));
      // The voice fades over the last half minute rather than stopping dead.
      _player.fadeOutBy(at);
      // The countdown in the player bar is redrawn as it runs.
      _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted && _sleepAt != null) setState(() {});
      });
    } else {
      _player.endFade();
      if (choice == SleepChoice.chapterEnd) _sleepChapter = _l.chapterOfUnit(_cursor.value);
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
    // Faded out already: paused at once, then back to full volume for Play.
    unawaited(_player.pause(now: true).whenComplete(_player.endFade));
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

  // ------------------------------------------------------------- playback

  Future<void> _togglePlay() async {
    if (_l.isEmpty) return;
    if (_handedOn) {
      // Shown a moment longer while the next chapters load: the voice is
      // the background reading's.
      final bg = BackgroundReading.current.value;
      if (bg != null && bg.bookId == _book.id) await bg.toggle();
      return;
    }
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
    // Handed on: this page goes as soon as the next is built; the voice is
    // not to be pulled back to it.
    if (_l.isEmpty || _handedOn) return;
    final next = unit.clamp(0, _l.units.length - 1);
    _showPlace(true);
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
      final playing = s == PlayState.playing || s == PlayState.loading;
      unawaited(_persist());
      if (playing) {
        // Read on there without waiting for a frame (the card's Next can
        // come with the screen off).
        unawaited(_readOn().then((_) => more(playing: true)));
      } else {
        unawaited(more(playing: false));
      }
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
      // The end of the chapters here: the voice reads on into the next ones
      // without this page (see _readOn), and the web reader shows them.
      unawaited(_readOn().then((_) => more(playing: true)));
      return;
    }
    if (mounted) {
      _snack('Finished. That is the end of the book.');
    }
  }

  void _onPlayState() {
    final s = _player.state.value;
    if (s == PlayState.playing || s == PlayState.loading) _parked = false;
    if (s != PlayState.idle) {
      if (!_placeShown) _showPlace(true);
      if (_returnTo != null && mounted) setState(() => _returnTo = null);
    }
    _applyReadingMode();
    final err = _player.error.value;
    if (s == PlayState.idle && err != null && mounted) {
      _snack('Reading stopped: $err');
    }
    _updateSession();
  }

  void _updateSession({bool force = false}) {
    // Handed on: the card is the background reading's.
    if (_handedOn) return;
    final actual = _player.state.value;
    // The end of a web novel's chapters here, read on into the next: the
    // card stays up (playing) while they load. Ended, Android 12 might not
    // let it start again with the app in the background.
    final rolling = actual == PlayState.idle && _player.reachedEnd && widget.onReachedEnd != null;
    final s = actual == PlayState.idle && _parked
        ? PlayState.paused
        : rolling
            ? PlayState.loading
            : actual;
    final u = _cursor.value;
    final chapter = _l.chapterOfUnit(u);
    final speed = _speed;
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
    // A book on a secret shelf is not named on the lock screen.
    final secret = widget.store?.isSecret(_book.id) ?? false;
    unawaited(_svc.session(
      active: true,
      title: secret ? 'TomeVoice' : _book.metadata.title,
      subtitle: secret ? '' : _l.chapterTitle(chapter),
      playing: s != PlayState.paused,
      cover: secret ? null : _cover,
      positionMs: _msFor(_wordsAt(u) - _wordsAt(first)),
      durationMs: _msFor(_wordsAt(first + count) - _wordsAt(first)),
      speed: speed,
    ));
  }

  void _onPlatformEvent(Map<String, Object?> e) {
    // Another book reads on in the background (or this one, handed on): the
    // card, the headset and the phone's audio are its, not this idle page's.
    final bg = BackgroundReading.current.value;
    if ((bg != null || _handedOn) && e['type'] != 'pageKey' && _player.state.value == PlayState.idle) return;
    switch (e['type']) {
      case 'pageKey':
        final delta = (e['delta'] as num?)?.toInt() ?? 1;
        if (_inPages) {
          _paged.turn(delta);
        } else if (_pdfBook) {
          _pdf.turn(delta);
        }
      case 'noisy':
        // Unplugged: not another word out of the speaker.
        _resumeOnFocus = false;
        unawaited(_player.pause(now: true));
      case 'focusLoss':
        _resumeOnFocus = false;
        unawaited(_player.pause());
      case 'focusLossTransient':
        if (_player.isPlaying) {
          _resumeOnFocus = true;
          _lossTimer?.cancel();
          _lossTimer = Timer(resumeAfterLossWithin, () => _resumeOnFocus = false);
          unawaited(_player.pause(now: true));
        }
      case 'focusGain':
        // From the start of the sentence the interruption cut into, and
        // not at all after a long one (a call): the listener may be gone.
        _lossTimer?.cancel();
        if (_resumeOnFocus && _player.state.value == PlayState.paused) unawaited(_player.resume(rewind: true));
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
            _cardSkip(1);
          case 'prev':
            _park();
            _cardSkip(-1);
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

  /// The speed this book reads at: its own, or everyone's.
  double get _speed => _prefs.speedFor(_book.id);

  /// How long [words] take at the reading speed: the same 165 words a minute
  /// as the time left under the player.
  int _msFor(int words) => (words / (165 * _speed) * 60000).round();

  /// Next (+1) or previous (-1) on headphones, the lock screen or the
  /// notification: a sentence (the default: a double press once lost a
  /// whole chapter), 30 seconds, or a chapter, as chosen in the sheet.
  void _cardSkip(int dir) {
    if (_l.isEmpty) return;
    final heard = _player.state.value == PlayState.idle ? Duration.zero : _player.heard;
    final to = skipTarget(_l, _cursor.value, dir, _prefs.skipBy, _speed, heard);
    if (to != null) {
      unawaited(_goTo(to));
    } else if (dir > 0) {
      _goChapter(1);
    } else {
      _cardPrevious();
    }
  }

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
    final target = _wordsAt(first) + ms / 60000 * 165 * _speed;
    var u = first;
    while (u + 1 < first + count && _wordsAt(u + 1) <= target) {
      u++;
    }
    unawaited(_goTo(u));
  }

  /// The card's speed button: the next of the common speeds, round to the
  /// slowest after the fastest (this book's own speed, if it has one).
  void _nextSpeed() {
    final now = _speed;
    final next = speedPresets.firstWhere((p) => p > now + 0.001, orElse: () => speedPresets.first);
    _prefs.setSpeed(next, book: _book.id);
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
    if (!_detached.value && !_quiet) _reveal(_cursor.value);
    _syncBookmarkHere();
  }

  /// Resume following the voice. [force] scrolls even if the paragraph is
  /// already on screen (the "Back to reading" pill).
  void _follow({bool force = false}) {
    _detached.value = false;
    _reveal(_cursor.value, force: force);
  }

  /// On pages, the page turns as the voice reads onto the next, not when
  /// the sentence the last line begins is reached (half a page early in a
  /// long sentence).
  void _onWord() {
    final w = _player.word.value;
    if (!_inPages || _detached.value || _quiet || w.start < 0 || w.unit != _cursor.value) return;
    _paged.showUnit(w.unit, at: w.start);
  }

  /// Scroll so the sentence being read is in view, unless it already is.
  void _reveal(int unit, {bool force = false}) {
    if (_inPages) {
      // Listening, the page is the one the voice is reading on (a sentence
      // runs over a page's foot); otherwise the sentence's own.
      final w = _player.word.value;
      _paged.showUnit(unit, at: _listening ? (w.unit == unit && w.start >= 0 ? w.start : 0) : null);
      return;
    }
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
    final duration = Motion.of(context, Motion.follow);
    // Motion turned down: go straight there.
    if (duration == Duration.zero) {
      _scroll.jumpTo(index: item, alignment: alignment);
      _programmaticScroll = false;
      return;
    }
    // Far away (not laid out): the list's own long scroll cross-fades two
    // copies of the text, and a plain jump is a cut. Travel instead.
    if (shown == null) {
      unawaited(_travel(item, alignment).whenComplete(() => _programmaticScroll = false));
      return;
    }
    unawaited(_scroll
        .scrollTo(index: item, alignment: alignment, duration: duration, curve: Curves.easeInOutCubic)
        .whenComplete(() => _programmaticScroll = false));
  }

  /// A long way to [item]: it scrolls there the way a short way does, up
  /// to a voice above what is on screen and down to one below. The text fades
  /// out for a moment while the page jumps to a screen short of the sentence,
  /// on the side it is coming from, then it scrolls the rest of the way by
  /// distance as the text comes back. (The list cannot scroll through the
  /// hundreds of paragraphs between, and asked to scroll to one it has not
  /// laid out, it cross-faded two copies of the text.)
  Future<void> _travel(int item, double alignment) async {
    final shown = _positions.itemPositions.value;
    final up = shown.isNotEmpty && shown.map((p) => p.index).reduce(math.min) > item;
    final way = up ? -1.0 : 1.0;
    _veiled.value = true;
    await Future<void>.delayed(_veil);
    if (!mounted || !_scroll.isAttached) return;
    _scroll.jumpTo(index: item, alignment: alignment + way);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.isAttached) return;
    _veiled.value = false;
    await _offsets.animateScroll(
      offset: way * _viewport,
      duration: Motion.of(context, Motion.travel),
      curve: Motion.out,
    );
  }

  static const _veil = Duration(milliseconds: 120);

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
    if (n is ScrollUpdateNotification) _lastMove = DateTime.now();
    if (n is ScrollUpdateNotification && n.dragDetails != null) _lastScroll = DateTime.now();
    if (n is ScrollStartNotification) _eyesTimer?.cancel();
    if (n is ScrollStartNotification && n.dragDetails != null && !_programmaticScroll) {
      // Listening, a scroll is a look around: the voice keeps its place.
      // Reading, the place goes where the reader does.
      if (_listening) {
        _detached.value = true;
      } else {
        _eyes = true;
      }
    }
    if (n is ScrollEndNotification && _eyes) {
      _eyesTimer?.cancel();
      _eyesTimer = Timer(const Duration(milliseconds: 250), _placeFromEyes);
    }
    if (n is ScrollEndNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncBookmarkHere();
      });
    }
    return false;
  }

  /// Reading without the voice: the sentence at the top of what is being
  /// read becomes the place, saved as it would be by the voice. Before,
  /// only the voice moved it, and a book read by scrolling reopened where
  /// it was last heard.
  void _placeFromEyes() {
    _eyes = false;
    if (!mounted || _listening || _l.isEmpty) return;
    final u = _unitAtEyes();
    if (u != null) _moveQuietly(u);
  }

  void _moveQuietly(int u) {
    _detached.value = false;
    _placeShown = false;
    _quiet = true;
    _cursor.value = u.clamp(0, _l.units.length - 1);
    _quiet = false;
    _syncMarked();
  }

  /// The sentence crossing a line just under the top bar, where the eye
  /// starts reading; in a long paragraph, estimated from its share of it.
  int? _unitAtEyes() {
    if (_l.isEmpty) return null;
    const line = 0.12;
    ItemPosition? at, below;
    for (final p in _positions.itemPositions.value) {
      if (p.index >= _l.items.length) continue;
      if (p.itemLeadingEdge <= line && p.itemTrailingEdge > line) at = p;
      if (p.itemLeadingEdge > line && (below == null || p.index < below.index)) below = p;
    }
    final p = at ?? below;
    if (p == null) return null;
    final item = _l.items[p.index];
    if (p != at || item.unitCount == 0) return item.firstUnit.clamp(0, _l.units.length - 1);
    final text = item.block?.text ?? '';
    final frac = ((line - p.itemLeadingEdge) / (p.itemTrailingEdge - p.itemLeadingEdge)).clamp(0.0, 1.0);
    final offset = (frac * text.length).round();
    var unit = item.firstUnit;
    for (var u = item.firstUnit; u < item.firstUnit + item.unitCount; u++) {
      if (_l.unitOffset[u] <= offset) unit = u;
    }
    return unit;
  }

  /// A page came to rest. Turned by hand while listening, it is a look
  /// around; while reading, the place goes with it.
  void _onPage(int unit, {required bool byHand}) {
    _pageUnit = unit;
    _viewChapter.value = _l.chapterOfUnit(unit);
    _syncBookmarkHere();
    if (!byHand) return;
    if (_chrome.value) _chrome.value = false;
    _lastScroll = DateTime.now();
    if (_listening) {
      _detached.value = true;
    } else {
      _moveQuietly(unit);
    }
  }

  /// A PDF's page turned to: as a text page is (see [_onPage]).
  void _onPdfPage(int page, {required bool byHand}) {
    if (!byHand || _l.isEmpty) return;
    _lastScroll = DateTime.now();
    if (_listening) {
      _detached.value = true;
    } else {
      _moveQuietly(_l.unitForPage(page));
    }
  }

  /// Press and hold on a page: the sentence and the word under the finger.
  void _onHoldAt(int item, int offset) {
    final it = _l.items[item];
    var unit = it.firstUnit;
    for (var u = it.firstUnit; u < it.firstUnit + it.unitCount; u++) {
      if (_l.unitOffset[u] <= offset) unit = u;
    }
    unawaited(_onLongPress(unit, wordAt(it.block?.text ?? '', offset)));
  }

  /// Jump, remembering where the reader was so they can go back.
  void _jump(int unit) {
    // Not while the voice reads (Back to reading is the way back then); a
    // pause counts as reading here, as the jump ends it and with it that way.
    if (!_player.isPlaying && unit != _cursor.value) {
      setState(() => _returnTo = _cursor.value);
    }
    unawaited(_goTo(unit));
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1500), () => unawaited(_persist()));
  }

  Future<void> _persist() async {
    final store = widget.store;
    // Handed on: the place is the background reading's, further on.
    if (store == null || _l.isEmpty || _handedOn) return;
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

  /// The player's height, so a message shows above it instead of over it.
  final _barKey = GlobalKey();
  double get _barLift => !_inPages && !_scrollBars.value
      ? 0
      : (_barKey.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  void _snack(String text) {
    if (mounted) showSnack(context, text, margin: _snackMargin);
  }

  /// Where a message floats: above the player, or at the foot while the
  /// bars are away. With Now Playing open over the page, above its scrubber
  /// instead, over the fade at the foot of its text and across its panel
  /// only: the player's height put it over Now Playing's own controls.
  EdgeInsets get _snackMargin {
    final open = _nowPlaying;
    final now = _nowPlayingKey.currentContext;
    if (open != null && open.isActive && now != null) {
      RenderBox? scrubber;
      void find(Element e) {
        if (scrubber != null) return;
        if (e.widget is ChapterScrubber) {
          scrubber = e.findRenderObject() as RenderBox?;
        } else {
          e.visitChildren(find);
        }
      }

      now.visitChildElements(find);
      final box = scrubber;
      if (box != null && box.hasSize && box.attached) {
        final at = box.localToGlobal(Offset.zero);
        final screen = MediaQuery.sizeOf(now);
        final foot = screen.height - MediaQuery.paddingOf(now).bottom;
        return EdgeInsets.fromLTRB(
          at.dx,
          0,
          math.max(0.0, screen.width - at.dx - box.size.width),
          math.max(Gap.l, foot - at.dy + Gap.s),
        );
      }
    }
    return EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + _barLift);
  }

  // ----------------------------------------------------- keep and share

  /// Keep sentence [unit] (the one being read by default) as a quote or a
  /// bookmark. The message offers Undo, for a save made by mistake.
  Future<Mark?> _save(MarkKind kind, {int? unit, int span = 1, String? note, bool hint = false}) async {
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
    final said = kind == MarkKind.quote
        ? 'Saved to your quotes.'
        : hint
            ? 'Bookmarked. Hold the bookmark button to see them all.'
            : 'Bookmarked.';
    showSnack(
      context,
      said,
      margin: _snackMargin,
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
      sheetAnimationStyle: sheetMotion(context),
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
                SheetAction(
                  icon: Icons.save_alt_rounded,
                  label: 'Save as audio…',
                  detail: web ? 'This chapter, as you hear it' : 'This chapter or the whole book, as you hear it',
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(showSaveAsAudio(
                      context,
                      layout: _l,
                      bookId: _book.id,
                      title: _book.metadata.title,
                      author: _book.metadata.authorLine,
                      cover: _cover,
                      chapter: _l.chapterOfUnit(unit),
                      reading: _player,
                      wholeBook: !web,
                    ));
                  },
                ),
                if (word.isNotEmpty)
                  SheetAction(
                    icon: Icons.menu_book_outlined,
                    label: 'Look up "$word"',
                    onTap: () => Navigator.pop(ctx, 'lookup'),
                  ),
                SheetAction(
                  icon: Icons.translate_rounded,
                  label: 'Translate',
                  detail: 'This sentence, in your translate app',
                  onTap: () => Navigator.pop(ctx, 'translate'),
                ),
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
      case 'lookup':
        if (!await _svc.lookUp(word) && mounted) _snack('No app on this phone looks words up. A dictionary app can.');
      case 'translate':
        if (!await _svc.translate(sentence) && mounted) _snack('No app on this phone translates. Google Translate can.');
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
              settings: _prefs.settingsFor(_listen.voiceName),
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
        if (_inPages) _chrome.value = true;
        _jump(hits[i].unit);
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
    final bar = ReaderPlayerBar(
      key: _barKey,
      layout: _l,
      cursor: _cursor,
      player: _player,
      speed: _speed,
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
    // Out to the screen's own edges, past the safe area (the camera's side,
    // the gesture bar): ending inside the screen, the haze showed a hard edge.
    final insets = _steadyInsets(context);
    // It glows from behind the player: with the player put away (a tap
    // on the page), it goes with it rather than lighting a bare edge.
    final light = ValueListenableBuilder<bool>(
      valueListenable: _inPages ? _chrome : _scrollBars,
      builder: (context, shown, glow) => AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: Motion.of(context, Motion.standard),
        curve: Motion.out,
        child: TickerMode(enabled: shown, child: glow!),
      ),
      child: VoiceGlow(level: _player.level, state: _player.state),
    );
    // Tall enough to rise clear of the player card at a speaking voice.
    final rise = (rail ? 240 : 600) + insets.bottom;
    final glow = Positioned(
      // Made afresh with the text's fade (the phone turned, a PDF's pages
      // and back), so it keeps time with its copy there.
      key: ValueKey(('glow', rail, _showPages)),
      left: -insets.left,
      right: -insets.right,
      bottom: -insets.bottom,
      height: rise,
      child: light,
    );
    final paged = _inPages;
    final reading = paged
        ? _pagedReading(context, bar, rail, glow, insets)
        // Upright, the glow lies under the text and shows through the fade
        // at its foot: the fade draws it again, in its place on the ground.
        : _scrollReading(context, bar, rail,
            rail ? null : Positioned(left: 0, right: 0, bottom: 0, height: rise, child: light));
    return PopScope(
      canPop: _hits.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _leaving = true;
        if (!didPop) setState(() => _hits = const []);
      },
      child: Scaffold(
      body: _ground(
        context,
        _HeldSafeArea(
          insets: insets,
          child: Stack(
                  // The glow reaches past the safe area.
                  clipBehavior: Clip.none,
                  // One shape upright and on its side, the parts not wanted
                  // left empty: with the text second here and first there,
                  // turning the phone built the text afresh, and the book
                  // went back to where it was opened.
                  children: [
                    // The voice, glowing out from behind the player as it
                    // reads; the text and the player sit over it. (Pages
                    // have it over their paper, which hid all but the strip
                    // under the screen's edge: see _pagedReading.)
                    if (!rail && !paged) glow else const SizedBox.shrink(),
                    KeyedSubtree(key: ValueKey(paged), child: reading),
                    // The text fades out before the dock, instead of showing
                    // in the gap beneath it. Out to the screen's edges like
                    // the glow: stopping at the safe area, its edge showed.
                    if (rail && !paged)
                    Positioned(
                      left: -insets.left,
                      right: -insets.right,
                      bottom: -insets.bottom,
                      height: 96 + insets.bottom,
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
                    )
                    else
                      const SizedBox.shrink(),
                    if (rail && !paged) glow else const SizedBox.shrink(),
                    if (rail && !paged)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _overBar(context, top: false, shownBy: _scrollBars, child: Center(child: bar)),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
        ),
      ),
      ),
    );
  }

  /// The page's tone (a PDF's real pages keep their own paper, drawn dark
  /// on a dark tone: see [_pdfInk]).
  PageTone get _tone => PageTone.byId(_prefs.pageTone);

  /// On a dark page tone (Dusk, or the app's own in the dark), a PDF's real
  /// page drawn in the tone's paper and ink, so a white page is no lamp at
  /// night. Null on a light tone: the page as it was printed.
  ({Color paper, Color ink})? _pdfInk(BuildContext context) {
    final tone = _tone;
    if (!(tone.dark || (tone.isApp && Skin.isDark(context)))) return null;
    return (paper: tone.paper?.first ?? Skin.darkOn(context), ink: tone.inkOf(context));
  }

  /// The ground under everything: the app's, or the page tone's paper, with
  /// the phone's bars drawn to suit it. One shape for every tone: another
  /// shape for the app's own rebuilt the whole page under it, and the book
  /// went back to where it was opened.
  Widget _ground(BuildContext context, Widget child) {
    final tone = _tone;
    final dark = tone.isApp ? Skin.isDark(context) : tone.dark;
    final icons = dark ? Brightness.light : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Every field, as in main.dart: one left out falls back to Android's
      // default, a separator line above the home bar.
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: icons,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      // The text's fades draw this ground again where they are (GroundFade).
      child: CompositedTransformTarget(
        link: _groundLink,
        child: PageGround(tone: tone, vignette: !_inPages, child: child),
      ),
    );
  }

  /// The book as one long page, the top bar above it and the player below;
  /// a tap on the text folds them away, and another brings them back.
  /// [glow] is the voice's glow placed on the ground, when it lies under the
  /// text (see [_text]).
  Widget _scrollReading(BuildContext context, Widget bar, bool rail, Widget? glow) {
    return Column(
      children: [
        _fold(context, top: true, child: _topBar(context)),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // Pages and text fade into each other's place.
                child: FadeIn(
                  key: ValueKey(_showPages),
                  child: _showPages
                      ? PdfPagesView(
                          path: widget.sourcePath!,
                          layout: _l,
                          cursor: _cursor,
                          detached: _detached,
                          onTapPage: (page) => _goTo(_l.unitForPage(page), play: true),
                          controller: _pdf,
                          turn: _prefs.pages ? PageTurn.byName(_prefs.pageTurn) : null,
                          spread: MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height &&
                              MediaQuery.sizeOf(context).width >= 600,
                          tapToTurn: _prefs.tapToTurn,
                          dark: _pdfInk(context),
                          onTurned: _onPdfPage,
                        )
                      : ValueListenableBuilder<bool>(
                          valueListenable: _veiled,
                          builder: (context, veiled, text) => AnimatedOpacity(
                            opacity: veiled ? 0 : 1,
                            // Out quickly, back as it glides in.
                            duration: veiled ? _veil : Motion.standard,
                            curve: veiled ? Curves.easeIn : Motion.out,
                            child: text,
                          ),
                          child: _tapForBars(toned(context, _tone, _text(context, glow: glow))),
                        ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _scrollBars,
                builder: (context, shown, pill) => AnimatedPositioned(
                  duration: Motion.of(context, Motion.standard),
                  curve: Motion.out,
                  left: 0,
                  right: 0,
                  // Above the dock when it floats over the text.
                  bottom: rail && shown ? 112 : (rail ? 24 : 10),
                  child: pill!,
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: Motion.of(context, Motion.standard),
                    transitionBuilder: fadeRise,
                    child: _pill(context),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!rail) _fold(context, top: false, child: bar),
      ],
    );
  }

  /// A bar of the scroll, folding away into its edge while the bars are put
  /// away; the text grows into its place. A PDF's real pages keep them: a
  /// tap there reads from the page.
  Widget _fold(BuildContext context, {required bool top, required Widget child}) =>
      ValueListenableBuilder<bool>(
        valueListenable: _scrollBars,
        builder: (context, shown, child) {
          final show = shown || _showPages;
          return ClipRect(
            // Clipped while it folds away. Shown, the player is not: its
            // shadow, cut at the safe area's edge, drew a line under it.
            // (The top bar's coming back would show over the status bar.)
            clipBehavior: top || !show ? Clip.hardEdge : Clip.none,
            child: IgnorePointer(
              ignoring: !show,
              child: AnimatedAlign(
                alignment: top ? Alignment.bottomCenter : Alignment.topCenter,
                heightFactor: show ? 1 : 0,
                duration: Motion.of(context, Motion.standard),
                curve: Motion.out,
                child: AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: Motion.of(context, Motion.quick),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: child,
      );

  /// A tap on the scrolling text puts the bars away or brings them back.
  /// The paragraphs take no tap of their own (pictures do, and keep it);
  /// a tap that stops a fling only stops it.
  Widget _tapForBars(Widget child) => Listener(
        onPointerDown: (_) {
          final moved = _lastMove;
          _tapStopsScroll = moved != null && DateTime.now().difference(moved) < const Duration(milliseconds: 150);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () {
            if (_tapStopsScroll) return;
            _scrollBars.value = !_scrollBars.value;
          },
          child: child,
        ),
      );

  /// A tap on a paragraph holding a saved quote. On the quote, while the
  /// voice is not reading, its note and actions; anywhere else, the bars.
  void _onTapText(int unit) {
    if (_tapStopsScroll) return;
    final m = _player.isPlaying ? null : _highlights.at(unit);
    if (m == null) {
      _scrollBars.value = !_scrollBars.value;
      return;
    }
    unawaited(showQuoteActions(context, m, cover: _cover, author: _book.metadata.authorLine).then((read) {
      if (read && mounted) unawaited(_goTo(_highlights.startOf(m) ?? unitOfMark(_l, m), play: true));
    }));
  }

  // ------------------------------------------------------------ bookmarks

  List<Mark> get _bookmarks => [
        for (final m in MarkStore.instance.forBook(_book.id))
          // A web novel's bookmark in a chapter not on the phone is left out.
          if (m.kind == MarkKind.bookmark && _l.chapters.contains(m.at.sectionIndex)) m,
      ];

  /// Bookmarks were added or removed: the ribbons and the bar's button follow.
  void _onMarks() {
    if (_l.isEmpty) return;
    _markedUnits.value = {for (final m in _bookmarks) unitOfMark(_l, m)};
    _syncBookmarkHere();
    if (mounted) setState(() {});
  }

  /// The sentences shown: the page (both, in a spread), a PDF's page, or
  /// the paragraph being read on the scroll (the voice's while it reads and
  /// is followed, else the one at the top of what is being read).
  (int, int) _viewRange() {
    if (_l.isEmpty) return (0, 0);
    final cursor = _cursor.value.clamp(0, _l.units.length - 1);
    if (_showPages && _l.hasPages) {
      final page = _l.unitPage[cursor];
      var end = cursor;
      while (end < _l.units.length && _l.unitPage[end] == page) {
        end++;
      }
      return (_l.unitForPage(page), end);
    }
    if (_inPages) {
      final r = _paged.range;
      if (r != null) return r;
    }
    final u = (_detached.value ? _unitAtEyes() : null) ?? cursor;
    final item = _l.items[_l.unitItem[u]];
    return (item.firstUnit, item.firstUnit + math.max(1, item.unitCount));
  }

  void _syncBookmarkHere() {
    if (_l.isEmpty) return;
    final (from, to) = _viewRange();
    _bookmarkedHere.value = _markedUnits.value.any((u) => u >= from && u < to);
  }

  /// The ribbon at the top: this page bookmarked, or its bookmarks taken
  /// off (with Undo).
  Future<void> _toggleBookmark() async {
    if (_l.isEmpty) return;
    final (from, to) = _viewRange();
    final here = [
      for (final m in _bookmarks)
        if (unitOfMark(_l, m) >= from && unitOfMark(_l, m) < to) m,
    ];
    HapticFeedback.selectionClick();
    if (here.isEmpty) {
      // Listening and followed: the sentence being read; else the page's
      // first (or the paragraph's).
      final listeningHere = _listening && !_detached.value && !_inPages && !_showPages;
      await _save(MarkKind.bookmark, unit: listeningHere ? _cursor.value : from, hint: true);
      return;
    }
    for (final m in here) {
      await MarkStore.instance.remove(m.id);
    }
    if (!mounted) return;
    showSnack(
      context,
      here.length == 1 ? 'Bookmark removed.' : '${here.length} bookmarks removed.',
      margin: _snackMargin,
      actionLabel: 'Undo',
      onAction: () async {
        for (final m in here) {
          await MarkStore.instance.restore(m);
        }
      },
    );
  }

  /// Every bookmark in this book, in the order of the book: a tap goes
  /// there (with the way back), the bin takes one off.
  void _openBookmarks() {
    if (_l.isEmpty) return;
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(context),
      builder: (ctx) => carryTint(
        context,
        ValueListenableBuilder<int>(
          valueListenable: MarkStore.instance.changes,
          builder: (ctx, _, __) {
            final marks = [
              for (final m in _bookmarks) (m: m, u: unitOfMark(_l, m)),
            ]..sort((a, b) => a.u.compareTo(b.u));
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetHeader('Bookmarks', subtitle: marks.isEmpty ? null : '${marks.length} in this book'),
                  if (marks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xxl),
                      child: Text(
                        'None yet. Tap the bookmark at the top of the page to keep a place you want to come back to. '
                        'Where you stopped reading is kept on its own.',
                        style: Skin.label(ctx, size: 14),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: Gap.xl),
                        children: [
                          for (final x in marks)
                            ListTile(
                              key: ValueKey(x.m.id),
                              leading: Icon(Icons.bookmark_rounded, color: Skin.accentOf(ctx)),
                              title: Text(
                                (x.m.chapter ?? _l.chapterTitle(_l.chapterOfUnit(x.u))).toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.meta(ctx, size: 10.5),
                              ),
                              subtitle: Text(
                                x.m.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Skin.page(ctx, size: 15, height: 1.35).copyWith(color: Skin.inkOn(ctx)),
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove bookmark',
                                icon: Icon(Icons.delete_outline_rounded, color: Skin.inkSoftOn(ctx)),
                                onPressed: () async {
                                  final m = x.m;
                                  await MarkStore.instance.remove(m.id);
                                  if (!mounted) return;
                                  showSnack(context, 'Bookmark removed.',
                                      margin: _snackMargin,
                                      actionLabel: 'Undo',
                                      onAction: () => unawaited(MarkStore.instance.restore(m)));
                                },
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                if (_inPages) _chrome.value = true;
                                _jump(x.u);
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Back to reading, the search matches, or the way back after a jump:
  /// whichever is wanted, rising into place.
  Widget _pill(BuildContext context) {
    if (_hits.isNotEmpty) return KeyedSubtree(key: const ValueKey('matches'), child: _matches(context));
    if (_returnTo != null) return KeyedSubtree(key: const ValueKey('return'), child: _returnPill(context));
    return KeyedSubtree(key: const ValueKey('back'), child: _backToReading(context));
  }

  Widget _returnPill(BuildContext context) => Material(
        color: Skin.darkOn(context),
        shape: const StadiumBorder(),
        elevation: 4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () {
                  final back = _returnTo;
                  setState(() => _returnTo = null);
                  if (back != null) unawaited(_goTo(back));
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.undo_rounded, size: 16, color: Skin.accentOf(context)),
                      const SizedBox(width: Gap.s),
                      Flexible(
                        child: Text('Back to where you were',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.onDark(context))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Stay here',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: Skin.onDark(context)),
              onPressed: () => setState(() => _returnTo = null),
            ),
          ],
        ),
      );

  /// The book in pages, with the top bar and the player over them, shown
  /// by a tap in the middle of the page and gone as the page turns.
  Widget _pagedReading(BuildContext context, Widget bar, bool rail, Widget glow, EdgeInsets insets) {
    final tone = _tone;
    final ground = tone.paper?.first ?? Skin.ground(context).colors.first;
    final foot = tone.paper?.last ?? Skin.groundFoot(context);
    final size = MediaQuery.sizeOf(context);
    // On its side, a wide screen opens like a book: two pages.
    final spread = size.width > size.height && size.width >= 600;
    return Stack(
      // The glow reaches past the safe area, as on the scrolling page.
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: toned(context, tone, PagedBook(
            layout: _l,
            look: _pageLook(context),
            controller: _paged,
            // The page on screen, once one has settled: built afresh, the
            // book must not go back to where it was opened.
            startUnit: _pageUnit ?? _pageStart ?? (_detached.value ? _l.items[_startItem].firstUnit : _cursor.value),
            marked: _marked,
            word: _player.word,
            chapterName: _l.chapterTitle,
            chapterLabel: (c) => _digit.hasMatch(_l.chapterTitle(c)) ? '' : 'CHAPTER ${_chapterNumber(c)}',
            onPage: _onPage,
            onTapMiddle: () => _chrome.value = !_chrome.value,
            onHold: _onHoldAt,
            pictureOf: (b, size) => _pictureImage(context, b, size.width, size.height),
            turn: PageTurn.byName(_prefs.pageTurn),
            spread: spread,
            paper: tone.paperOf(context),
            // The binding in the page's own ink; black on a dark page.
            crease: tone.dark || (tone.isApp && Skin.isDark(context)) ? Colors.black : tone.inkOf(context),
            tapToTurn: _prefs.tapToTurn,
            endButton: widget.onReachedEnd == null ? null : _more(context),
            marks: _markedUnits,
            highlights: _highlights,
            textDirection: _direction,
          )),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _overBar(
            context,
            top: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [ground, ground, ground.withValues(alpha: 0)],
                  stops: const [0, 0.7, 1],
                ),
              ),
              child: Padding(padding: const EdgeInsets.only(bottom: 14), child: _topBar(context)),
            ),
          ),
        ),
        // Back to reading and the other pills come and go with the bars:
        // left on the page they covered its words.
        ValueListenableBuilder<bool>(
          valueListenable: _chrome,
          builder: (context, shown, pill) => AnimatedPositioned(
            duration: Motion.of(context, Motion.standard),
            curve: Motion.out,
            left: 0,
            right: 0,
            bottom: shown ? _barLift + 10 : 24,
            child: IgnorePointer(
              ignoring: !shown,
              child: AnimatedOpacity(
                opacity: shown ? 1 : 0,
                duration: Motion.of(context, Motion.quick),
                child: pill,
              ),
            ),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.standard),
              transitionBuilder: fadeRise,
              child: _pill(context),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // Over a fade to the ground, so the page's foot line does not
          // show under the player's edge; the voice's glow rises over the
          // fade, from behind the player. The fade runs out to the screen's
          // edge: ending at the safe area, it hid the glow above that line
          // and left it showing below, cut straight across.
          child: _overBar(
            context,
            top: false,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: -insets.left,
                  right: -insets.right,
                  top: 0,
                  bottom: -insets.bottom,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [foot.withValues(alpha: 0), foot, foot],
                          stops: const [0, 0.3, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                glow,
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: rail ? Center(child: bar) : bar,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A bar over the pages (or the player docked over the scroll, by
  /// [shownBy]): it slides in from its edge when shown.
  Widget _overBar(BuildContext context, {required bool top, required Widget child, ValueListenable<bool>? shownBy}) =>
      ValueListenableBuilder<bool>(
        valueListenable: shownBy ?? _chrome,
        builder: (context, shown, child) => IgnorePointer(
          ignoring: !shown,
          child: AnimatedSlide(
            offset: shown ? Offset.zero : Offset(0, top ? -0.5 : 0.5),
            duration: Motion.of(context, Motion.standard),
            curve: Motion.out,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: Motion.of(context, Motion.quick),
              child: child,
            ),
          ),
        ),
        child: child,
      );

  /// The page drawn in pages: the same type and colours as the scroll.
  PageLook _pageLook(BuildContext context) {
    final scale = _prefs.textSize / 19;
    final tone = _tone;
    final ink = tone.inkOf(context);
    final accent = tone.accentOf(context);
    return PageLook(
      text: Skin.page(context, size: _prefs.textSize, font: _prefs.bookFont, height: _prefs.lineHeight)
          .copyWith(color: ink),
      heading: Skin.title(context, size: 22 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: ink),
      chapterHeading:
          Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(height: 1.2, color: accent),
      title: Skin.title(context, size: 30 * scale, weight: FontWeight.w500).copyWith(color: accent),
      label: Skin.meta(context, size: 11, color: accent).copyWith(fontWeight: FontWeight.w600),
      status: Skin.meta(context, size: 10, color: tone.inkSoft),
      accent: accent,
      sentenceWash: tone.isApp ? Skin.sentenceWash(context) : accent.withValues(alpha: tone.dark ? 0.22 : 0.16),
      wordWash: tone.isApp ? Skin.wordWash(context) : accent.withValues(alpha: tone.dark ? 0.5 : 0.36),
      textScaler: MediaQuery.textScalerOf(context),
      justify: _prefs.justify,
      indent: _prefs.indent,
      margin: _prefs.margin,
    );
  }

  /// The book filling the screen, its words like lyrics.
  void _openNowPlaying() {
    // A swipe and a tap on the handle together must not open it twice.
    if (_nowPlaying?.isActive ?? false) return;
    final from = context;
    final nav = Navigator.of(context);
    // Its own key: one closing may still be on screen as this one opens.
    final key = _nowPlayingKey = GlobalKey();
    final route = PageRouteBuilder<void>(
      transitionDuration: Motion.of(context, Motion.page),
      reverseTransitionDuration: Motion.of(context, Motion.standard),
      pageBuilder: (ctx, _, __) => carryTint(
        from,
        NowPlayingScreen(
          key: key,
          title: _book.metadata.title,
          cover: _cover,
          layout: _l,
          cursor: _cursor,
          player: _player,
          speed: () => _speed,
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

  // The round buttons take 48 dp for a finger and draw 44: the gaps and the
  // edges are 2 dp less on each side, so every circle stays where it was.
  Widget _topBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Row(
          children: [
            RoundButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back to library',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Contents',
                child: GestureDetector(
                  key: const ValueKey('contents'),
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
                        // On a page tone's paper, in its ink: the app's (cream
                        // in a dark theme) vanished on Ink's white.
                        style: Skin.title(context, size: 18, color: _tone.ink),
                      ),
                      ListenableBuilder(
                        listenable: _topLine,
                        builder: (context, _) {
                          // The chapter on screen while looking around; the
                          // one being read otherwise.
                          final looking = _detached.value && !_l.isEmpty;
                          final c = looking ? _viewChapter.value : _l.chapterOfUnit(_cursor.value);
                          final u = looking ? _l.chapterFirstUnit[c] : _cursor.value;
                          final style = Skin.meta(context, size: 10.5, color: _tone.inkSoft);
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
                          // A new chapter's name rises into place.
                          return AnimatedSwitcher(
                            duration: Motion.of(context, Motion.standard),
                            transitionBuilder: fadeRise,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.centerLeft,
                              children: [...previous, if (current != null) current],
                            ),
                            child: Row(
                              key: ValueKey(c),
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
                                Icon(Icons.expand_more_rounded, size: 15, color: style.color),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isPdf) ...[
              const SizedBox(width: 4),
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
            const SizedBox(width: 4),
            RoundButton(
              icon: Icons.search_rounded,
              tooltip: 'Search',
              onTap: _openSearch,
            ),
            const SizedBox(width: 4),
            // Contents is the title's (its chapter line says so); the bar
            // keeps a page's bookmark at hand.
            ValueListenableBuilder<bool>(
              valueListenable: _bookmarkedHere,
              builder: (context, marked, _) => RoundButton(
                icon: marked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                iconColor: marked ? Skin.accentOf(context) : null,
                tooltip: marked ? 'Remove bookmark' : 'Bookmark this page',
                onTap: () => unawaited(_toggleBookmark()),
                onLongPress: _openBookmarks,
              ),
            ),
            const SizedBox(width: 4),
            // How the page looks. The voice's settings are on the player
            // (its voice and speed), in the same sheet.
            RoundButton(
              icon: Icons.text_fields_rounded,
              tooltip: 'Reading settings',
              onTap: () => showListenSheet(context, _listen, focus: ListenFocus.read),
            ),
          ],
        ),
      );

  Widget _text(BuildContext context, {Widget? glow}) {
    if (_l.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'This file has no text that can be read aloud.',
            textAlign: TextAlign.center,
            style: Skin.page(context, size: 20).copyWith(color: _tone.inkOf(context)),
          ),
        ),
      );
    }
    // Built afresh after the first time (back from a PDF's real pages), the
    // list opens at the place, not where the book was opened.
    final initial = _scrollFrom ??
        (_textShown ? _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)] : _startItem);
    _textShown = true;
    // The same look as pages, so the scroll is in the page tone's ink too:
    // its text kept the app's, which turned near-white on Papyrus when the
    // phone went dark.
    _look = _pageLook(context);
    // A wide screen keeps a comfortable line (about 70 characters), centred.
    final side = math.max(_prefs.margin, (MediaQuery.sizeOf(context).width - 720) / 2);
    // Text fades out under the top bar and the player instead of being cut
    // off against them: the ground is drawn again over its two edges, fading
    // away from them. (A mask over all the text did the same at the cost of
    // drawing it all again offscreen on every frame it scrolled.)
    // A long book has a thumb at the edge: dragged, it goes straight through
    // the book, the bubble naming the chapter.
    return FastScroller(
      target: _fastText,
      top: 8,
      bottom: 16,
      labelAt: (f) => _l.chapterTitle(_l.items[(f * (_l.items.length - 1)).round()].chapter),
      onDrag: _onFastScroll,
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: LayoutBuilder(
              builder: (context, box) {
                _viewport = box.maxHeight;
                return Directionality(
                  textDirection: _direction,
                  child: ScrollablePositionedList.builder(
                  // One more item at the end when there is more to fetch: the way on.
                  itemCount: _l.items.length + (widget.onReachedEnd == null ? 0 : 1),
                  itemScrollController: _scroll,
                  scrollOffsetController: _offsets,
                  itemPositionsListener: _positions,
                  initialScrollIndex: initial,
                  initialAlignment: initial == 0 ? 0 : 0.12,
                  padding: EdgeInsets.fromLTRB(side, 16, side, 120),
                  itemBuilder: (context, i) => i == _l.items.length ? _more(context) : _item(context, i),
                ),
                );
              },
            ),
          ),
          Positioned(left: 0, top: 0, right: 0, height: 18, child: _edge(context, top: true)),
          Positioned(left: 0, right: 0, bottom: 0, height: 28, child: _edge(context, glow: glow)),
        ],
      ),
    );
  }

  /// The ground once more over an edge of the scrolling text, fading it out
  /// there (see [GroundFade]): the page's paper and its vignette and, at the
  /// foot, the voice's [glow], which shows through the text's fade there.
  Widget _edge(BuildContext context, {bool top = false, Widget? glow}) {
    return GroundFade(
      link: _groundLink,
      // The page's ground fills the screen. (A keyboard shortens it, but
      // only ever comes with a sheet over the page, and following it would
      // build the whole page again on every frame it rises.)
      size: MediaQuery.sizeOf(context),
      top: top,
      ground: PageGround(
        tone: _tone,
        vignette: !_inPages,
        child: glow == null ? const SizedBox.shrink() : Stack(children: [glow]),
      ),
    );
  }

  late final _fastText = _TextScrollTarget(this);

  /// The page's type and colours for the scroll, set as it is built.
  late PageLook _look;

  /// The scroll has been shown once (see [_text]).
  bool _textShown = false;

  /// The fast scroller's thumb taken or let go: as a scroll by hand, a look
  /// around while listening, and the place moved there while reading.
  void _onFastScroll(bool dragging) {
    _lastScroll = DateTime.now();
    _eyesTimer?.cancel();
    if (dragging) {
      if (_listening) {
        _detached.value = true;
      } else {
        _eyes = true;
      }
      return;
    }
    if (_eyes) _eyesTimer = Timer(const Duration(milliseconds: 250), _placeFromEyes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBookmarkHere();
    });
  }

  Widget _item(BuildContext context, int i) {
    final item = _l.items[i];
    final chapterStart = i == _l.chapterFirstItem[item.chapter];
    // Every chapter opens the same way, in the book's colour, so a chapter
    // start is never scrolled past unnoticed.
    final look = _look;
    final accent = look.accent;
    final label = chapterStart && _l.chapters.length > 1
        ? Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : 56, bottom: 12),
            child: Row(
              children: [
                // A title that carries its own number ("Chapter 3222
                // Liberation") is not given a second one: a site's list
                // can be one off from its titles.
                if (!_digit.hasMatch(_l.chapterTitle(item.chapter))) ...[
                  Text('CHAPTER ${_chapterNumber(item.chapter)}', style: look.label),
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
            child: Text(item.title ?? '', style: look.title),
          ),
        ],
      );
    }

    if (item.displayOnly) {
      // A note (or a caption): on the page in smaller type, never read
      // aloud. Its marker in the text is silent too.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) label,
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(item.block!.text, style: noteStyle(look)),
          ),
        ],
      );
    }

    final heading = item.block!.role == BlockRole.heading;
    final style = heading ? (chapterStart ? look.chapterHeading : look.heading) : look.text;
    final indent = _prefs.indent && indentedAt(_l, i)
        ? MediaQuery.textScalerOf(context).scale(_prefs.textSize) * indentEm
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) label,
        Padding(
          padding: EdgeInsets.only(
            bottom: heading ? 18 : (_prefs.indent ? 2 : 16),
            top: heading && !chapterStart ? 12 : 0,
          ),
          child: _ribboned(
            context,
            item,
            BlockText(
            item: item,
            layout: _l,
            cursor: _marked,
            indent: indent,
            word: _player.word,
            style: style,
            wash: look.sentenceWash,
            wordWash: look.wordWash,
            heading: heading && !chapterStart,
            justify: _prefs.justify && !heading,
            onTapUnit: (u) => _goTo(u, play: true),
            onLongPressUnit: _onLongPress,
            highlights: _highlights,
            onTapAt: _onTapText,
          ),
          ),
        ),
      ],
    );
  }

  /// [child] with a ribbon in the margin beside it when one of [item]'s
  /// sentences is bookmarked.
  ///
  /// The ribbon listens for bookmarks itself: the list keeps rows it does
  /// not build again, and a ribbon taken off stayed on one of them.
  Widget _ribboned(BuildContext context, LayoutItem item, Widget child) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            top: 2,
            right: -math.min(_prefs.margin - 2, 20.0),
            child: ValueListenableBuilder<Set<int>>(
              valueListenable: _markedUnits,
              builder: (context, marks, _) => marks.any(item.containsUnit)
                  ? Icon(Icons.bookmark_rounded, size: 16, semanticLabel: 'Bookmarked', color: Skin.accentOf(context))
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      );

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
    return LayoutBuilder(
      builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // Small ornaments stay small; plates and maps fill the column.
        final width = math.min(c.maxWidth, iw / dpr * 2.2);
        final height = width * ih / iw;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Center(child: _pictureImage(context, block, width, height)),
        );
      },
    );
  }

  /// A picture drawn at [width] x [height], opening full screen on a tap.
  Widget _pictureImage(BuildContext context, Block block, double width, double height) {
    final dir = widget.bookDir;
    final iw = block.imageWidth ?? 1, ih = block.imageHeight ?? 1;
    if (dir == null) return SizedBox(width: width, height: height);
    final file = File('$dir/img/${imageFileName(block.image!)}');
    final dpr = MediaQuery.devicePixelRatioOf(context);
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
      final ink = _tone.inkSoft ?? Skin.inkSoftOn(context);
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
    return GestureDetector(
      onTap: () => PictureViewer.open(context, file, caption: block.text),
      child: Semantics(
        image: true,
        label: block.text.isEmpty ? 'Picture. Double tap to enlarge' : block.text,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: image,
        ),
      ),
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
    // The finder a web novel's whole Contents use, set as a book's own:
    // its parts as dividers, its numbers short, the keyboard left up by a
    // drag.
    unawaited(showChapterFinder(
      context,
      titles: [for (var c = 0; c < _l.chapters.length; c++) _l.chapterTitle(c)],
      current: _l.chapterOfUnit(_cursor.value),
      numberOf: _chapterNumber,
      hint: 'Find a chapter',
      parts: true,
      numberWidth: 40,
      dismissOnDrag: false,
    ).then((chapter) {
      if (chapter != null && mounted) _jump(_l.chapterFirstUnit[chapter]);
    }));
  }
}

/// A [SafeArea] of the [insets] given rather than the phone's of the moment:
/// the reader's, held steady while a system sheet is over it (see
/// _ReaderScreenState._steadyInsets).
class _HeldSafeArea extends StatelessWidget {
  const _HeldSafeArea({required this.insets, required this.child});

  final EdgeInsets insets;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: insets,
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: child,
        ),
      );
}

/// The book's text as the fast scroller sees it: how far through its
/// paragraphs the one at the top of the screen is.
class _TextScrollTarget extends FastScrollTarget {
  _TextScrollTarget(this._s);
  final _ReaderScreenState _s;

  int get _count => _s._l.items.length;

  @override
  bool get long => _count > 80;

  /// Not while the text follows the voice.
  @override
  bool get byHand =>
      !_s._programmaticScroll &&
      _s._lastScroll != null &&
      DateTime.now().difference(_s._lastScroll!) < const Duration(seconds: 2);

  @override
  double get fraction {
    ItemPosition? top;
    for (final p in _s._positions.itemPositions.value) {
      if (p.index >= _count || p.itemTrailingEdge <= 0) continue;
      if (top == null || p.index < top.index) top = p;
    }
    if (top == null || _count <= 1) return 0;
    final h = top.itemTrailingEdge - top.itemLeadingEdge;
    final within = h <= 0 ? 0.0 : (-top.itemLeadingEdge / h).clamp(0.0, 1.0);
    return ((top.index + within) / (_count - 1)).clamp(0.0, 1.0);
  }

  @override
  void jumpTo(double fraction) {
    if (_s._scroll.isAttached) _s._scroll.jumpTo(index: (fraction * (_count - 1)).round());
  }

  @override
  void addListener(VoidCallback listener) => _s._positions.itemPositions.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _s._positions.itemPositions.removeListener(listener);
}

/// Kept so the batch measurement path still has a JSON shape to write.
String encodeReport(Map<String, Object?> m) =>
    const JsonEncoder.withIndent('  ').convert(m);

