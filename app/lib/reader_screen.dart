import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback, SystemChrome, SystemUiMode, SystemUiOverlayStyle;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'book_tint.dart';
import 'cast.dart';
import 'cast_sheet.dart';
import 'chapter_finder.dart';
import 'export_audio_sheet.dart';
import 'fast_scroller.dart';
import 'highlights.dart';
import 'library_store.dart';
import 'book_search.dart';
import 'listen_sheet.dart';
import 'marks.dart';
import 'neural_voices.dart';
import 'now_playing.dart';
import 'page_style.dart';
import 'page_tone.dart';
import 'paged_view.dart';
import 'pages_view.dart';
import 'player_controls.dart';
import 'prefs.dart';
import 'quote_sheet.dart';
import 'reader_chrome.dart';
import 'reader_controller.dart';
import 'reader_player_bar.dart';
import 'reader_sheets.dart';
import 'reader_text.dart';
import 'reading_rules.dart';
import 'rules_screen.dart';
import 'share_card.dart';
import 'sources/source_engine.dart';
import 'scheduler.dart';
import 'speakers.dart' show Character;
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
    this.window,
  });

  final ReadingLayout layout;

  /// The chapters shown as they grow while the page is open: a web novel's
  /// window, the chapters after it joined on as the reading (or the eyes)
  /// nears its end (see WebNovelReader). Each is [layout] with more chapters
  /// after its own; the voice and the page carry on into them as they are,
  /// with no break.
  final ValueListenable<ReadingLayout>? window;

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

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver implements ReaderView {
  /// The chapters shown: the reading's, which grow with a web novel's
  /// window (see [ReaderScreen.window]).
  ReadingLayout get _l => _reader.layout;
  Book get _book => _l.book;

  /// The reading this page shows: the place, the voice, the card, the
  /// sleep timer (see ReaderController).
  late final ReaderController _reader;

  ValueNotifier<int> get _cursor => _reader.cursor;
  ValueNotifier<bool> get _detached => _reader.detached;
  ValueNotifier<int> get _marked => _reader.marked;
  PlaybackScheduler get _player => _reader.player;
  ListeningPrefs get _prefs => _reader.prefs;
  double get _speed => _reader.speed;
  String? get _cover => _reader.cover;

  /// The text faded out for a moment, while it travels a long way to the voice.
  final _veiled = ValueNotifier<bool>(false);

  /// A drag began while nothing was being read aloud: once the page
  /// settles, the place moves to what is being read.
  bool _eyes = false;
  Timer? _eyesTimer;

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

  final _catalog = VoiceCatalog.instance;

  /// Arabic, Hebrew and the other right-to-left scripts are set and turned
  /// that way (they were laid out left to right).
  late final TextDirection _direction = directionOfLanguage(_reader.language);

  /// Search matches being stepped through, and which one is shown.
  List<SearchHit> _hits = const [];
  int _hit = 0;
  String _hitQuery = '';
  bool _programmaticScroll = false;

  bool get _isPdf => _book.source == SourceKind.pdf && widget.sourcePath != null;
  bool get _showPages => _isPdf && _prefs.pdfPages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The place and the voice: this book's reading in the background taken
    // back if it reads on there, else a voice of its own.
    _reader = ReaderController(layout: widget.layout, view: this, initialCursor: widget.initialCursor, store: widget.store);
    widget.window?.addListener(_onWindow);
    _player.word.addListener(_onWord);
    MarkStore.instance.changes.addListener(_onMarks);
    _onMarks();
    _positions.itemPositions.addListener(_onPositions);
    if (!_l.isEmpty && _startItem != _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)]) {
      _detached.value = true;
      _viewChapter.value = _l.items[_startItem].chapter;
    }
    _catalog.addListener(_onCatalog);
    unawaited(_catalog.ensureLoaded());
    ListeningPrefs.revision.addListener(_onPrefs);
    ReadingRules.instance.changes.addListener(_onRules);
    unawaited(_loadPrefs());
    unawaited(_reader.loadCover());
    if (_reader.resumeAt >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_player.play(_cursor.value));
      });
    } else if (widget.autoplay && !_reader.tookBack) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Looking ahead while it reads: carry on aloud where it was, and
        // leave the page where the reader is looking.
        if (_detached.value && !_l.isEmpty) {
          unawaited(_player.play(_cursor.value));
        } else {
          unawaited(_reader.togglePlay());
        }
      });
    }
  }

  // ------------------------------------------- what the reading asks of it

  @override
  Future<void> Function({required bool playing, bool browse})? get onReachedEnd => widget.onReachedEnd;

  @override
  ValueChanged<int>? get onChapterChanged => widget.onChapterChanged;

  @override
  double Function(int u)? get progressOf => widget.progressOf;

  @override
  void changed() {
    if (mounted) setState(() {});
  }

  /// The chapters after the page's joined on (see [ReaderScreen.window]):
  /// the voice reads on into them with no break, and the page shows them
  /// after its own, where it is, as it is.
  void _onWindow() {
    final longer = widget.window!.value;
    if (!mounted || !_reader.widen(longer)) return;
    _highlights.layout = longer;
    _onMarks();
    setState(() {});
  }

  @override
  void didUpdateWidget(ReaderScreen old) {
    super.didUpdateWidget(old);
    if (old.window != widget.window) {
      old.window?.removeListener(_onWindow);
      widget.window?.addListener(_onWindow);
    }
  }

  @override
  void reveal(int unit, {bool force = false}) => _reveal(unit, force: force);

  @override
  void placeMoved() => _syncBookmarkHere();

  @override
  void say(String text) => _snack(text);

  @override
  void saveLine() => unawaited(_save(MarkKind.quote));

  @override
  void turnPage(int delta) {
    if (_inPages) {
      _paged.turn(delta);
    } else if (_pdfBook) {
      _pdf.turn(delta);
    }
  }

  @override
  void playStateChanged() => _applyReadingMode();

  Future<void> _loadPrefs() async {
    final dir = widget.store?.root.path;
    if (dir == null) return;
    final p = await ListeningPrefs.load(dir);
    if (!mounted) return;
    setState(() => _reader.prefs = p);
    _wasPaged = _inPages;
    _layoutKey = _layoutOf(p);
    _applyScreenOn();
    _applyReadingMode();
    _warmVoice();
    _findPeople();
    if (p.engineId != null && p.engineId != _catalog.engineId) {
      await _catalog.ensureLoaded();
      await _catalog.switchEngine(p.engineId!);
    }
  }

  /// A natural voice is loaded while the page settles, so Play does not
  /// wait for it (a second or two, longer for HD, the first time); a natural
  /// dialogue voice too, where the phone keeps two loaded (with room for
  /// one, loading it would only push the narrator out); and where it keeps
  /// two and has room left, the first character's (see castVoiceToWarm).
  void _warmVoice() {
    final listen = _listen;
    final narrator = neuralVoiceFor(listen.voiceName);
    final dialogue = neuralVoiceFor(listen.dialogueVoice);
    final voices = [
      if (narrator != null) narrator,
      if (dialogue != null && (narrator == null || NeuralEngine.instance.holdsTwo)) dialogue,
    ];
    final character = castVoiceToWarm(
      _prefs.castByBook[_book.id],
      narrator: listen.voiceName,
      dialogue: listen.dialogueVoice,
      slots: NeuralEngine.instance.slots,
      held: {for (final v in voices) v.modelId},
      here: (v) => _catalog.byName(v) != null,
    );
    if (character != null) voices.add(character);
    if (voices.isEmpty) return;
    Timer(const Duration(milliseconds: 1200), () async {
      for (final v in voices) {
        if (!mounted || _player.state.value != PlayState.idle) return;
        await NeuralEngine.instance.warm(v);
      }
    });
  }

  /// Who the book's speech tags name, once found (a book's, not a web
  /// novel's, and in English): the listening sheet offers them, as the
  /// book's page does.
  List<Character> _people = const [];
  Timer? _peopleTimer;

  /// The book's characters are looked for once the page has settled, on
  /// another isolate: a long book takes a second or more, and its page has
  /// often found them already this run.
  void _findPeople() {
    if (widget.onReachedEnd != null || _l.isEmpty) return;
    _peopleTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (!mounted) return;
      final people = await bookCharacters(_book.id, _l);
      if (mounted && people.isNotEmpty) setState(() => _people = people);
    });
  }

  /// How the book's characters are read now, for the listening sheet.
  String _peopleNote() =>
      castSummary(_prefs.castByBook[_book.id]) ??
      '${_people.length} ${_people.length == 1 ? 'speaks' : 'speak'}, all in the dialogue voice';

  /// The book's characters, and the voice each one's lines are read in.
  Future<void> _openPeople() async {
    final people = await bookCharacters(_book.id, _l);
    if (!mounted || people.isEmpty) return;
    final before = _prefs.castByBook[_book.id];
    await showCastSheet(
      context,
      bookId: _book.id,
      title: _book.metadata.title,
      people: people,
      listen: _listen,
      // A line said for a character shares the reading's stream: the
      // reading stops for it, as for a voice's sample.
      beforeHear: () async {
        if (_player.state.value != PlayState.idle) await _player.stop();
      },
    );
    // A voice given or taken away is heard from the sentence being read.
    if (mounted && !identical(before, _prefs.castByBook[_book.id])) _reader.settingsChanged(restart: true);
  }

  bool _screenOn = false;

  /// A pronunciation was fixed: say the current sentence again with it.
  void _onRules() => _reader.settingsChanged(restart: true);

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

  /// Now Playing, while it is open over this reader, and the navigator it is on.
  Route<void>? _nowPlaying;
  NavigatorState? _nowPlayingNav;

  /// Now Playing's screen, for where a message sits over it (see
  /// [_snackMargin]); a new key each time it opens.
  GlobalKey _nowPlayingKey = GlobalKey();

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
    _eyesTimer?.cancel();
    _backTimer?.cancel();
    _insetsTimer?.cancel();
    _peopleTimer?.cancel();
    if (_fullScreen) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    if (_volumeKeys) unawaited(_svc.volumeKeysTurnPages(false));
    WidgetsBinding.instance.removeObserver(this);
    ListeningPrefs.revision.removeListener(_onPrefs);
    ReadingRules.instance.changes.removeListener(_onRules);
    if (_screenOn) unawaited(_svc.keepScreenOn(false));
    _catalog.removeListener(_onCatalog);
    _player.word.removeListener(_onWord);
    widget.window?.removeListener(_onWindow);
    // The place saved and the time counted; the voice ended, or reading on
    // without the page.
    _reader.dispose();
    _positions.itemPositions.removeListener(_onPositions);
    _veiled.dispose();
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
      unawaited(_reader.persist());
      _reader.countTime();
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

  void _onCatalog() {
    if (mounted) setState(() {});
  }

  ListenController get _listen => ListenController(
        prefs: _prefs,
        language: _reader.language,
        bookId: _book.id,
        // The book's reading rules, opened from the sheet, go by its title.
        bookTitle: _book.metadata.title,
        onChanged: _reader.settingsChanged,
        sleep: _reader.sleep,
        onSleep: _reader.setSleep,
        onPreview: _previewVoice,
        isPlaying: () =>
            _player.state.value == PlayState.playing || _player.state.value == PlayState.loading,
        isPdf: _isPdf,
        characters: _people.isEmpty ? null : _peopleNote,
        onCharacters: _people.isEmpty ? null : _openPeople,
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

  // --------------------------------------------------------------- cursor

  /// On pages, the page turns as the voice reads onto the next, not when
  /// the sentence the last line begins is reached (half a page early in a
  /// long sentence).
  void _onWord() {
    final w = _player.word.value;
    if (!_inPages || _detached.value || _reader.quiet || w.start < 0 || w.unit != _cursor.value) return;
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
    if (n is ScrollUpdateNotification && n.dragDetails != null) _reader.lastScroll = DateTime.now();
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
    if (u != null) _reader.moveQuietly(u);
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
    _reader.lastScroll = DateTime.now();
    if (_listening) {
      _detached.value = true;
      // Fetch ahead of where the reader is looking, as on the scroll.
      widget.onChapterChanged?.call(_l.units[unit].sectionIndex);
    } else {
      _reader.moveQuietly(unit);
    }
  }

  /// A PDF's page turned to: as a text page is (see [_onPage]).
  void _onPdfPage(int page, {required bool byHand}) {
    if (!byHand || _l.isEmpty) return;
    _reader.lastScroll = DateTime.now();
    if (_listening) {
      _detached.value = true;
    } else {
      _reader.moveQuietly(_l.unitForPage(page));
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
    final web = _reader.entry?.plugin != null;
    final picked = await showSentenceActions(
      context,
      sentence: sentence,
      word: word,
      web: web,
      onSaveAsAudio: () => unawaited(showSaveAsAudio(
        context,
        layout: _l,
        bookId: _book.id,
        title: _book.metadata.title,
        author: _book.metadata.authorLine,
        cover: _cover,
        chapter: _l.chapterOfUnit(unit),
        reading: _player,
        wholeBook: !web,
      )),
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'read':
        await _reader.goTo(unit, play: true);
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
        final plugin = _reader.entry?.plugin;
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
        _reader.jump(hits[i].unit);
      },
    ));
  }

  void _stepHit(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + delta) % _hits.length);
    unawaited(_reader.goTo(_hits[_hit].unit));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    _style = PageStyle.of(context, _prefs);
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
      sleepNote: _reader.sleepNote,
      onPlay: _reader.togglePlay,
      onPrevSentence: () => _reader.goTo(_cursor.value - 1),
      onNextSentence: () => _reader.goTo(_cursor.value + 1),
      onPrevChapter: () => _reader.goChapter(-1),
      onNextChapter: () => _reader.goChapter(1),
      moreAfter: widget.onReachedEnd != null,
      progressOf: widget.progressOf,
      onSeekInChapter: (u) => _reader.goTo(u),
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
        if (didPop) _reader.leaving = true;
        if (!didPop) setState(() => _hits = const []);
      },
      child: Scaffold(
      body: _ground(
        context,
        HeldSafeArea(
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
                    // in the gap beneath it, into the page's own paper (the
                    // app's ground was a band on Papyrus, Ink and Dusk). Out
                    // to the screen's edges like the glow: stopping at the
                    // safe area, its edge showed.
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
                              colors: [_style.paperFoot.withValues(alpha: 0), _style.paperFoot],
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
                        child: SlidingBar(shown: _scrollBars, top: false, child: Center(child: bar)),
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

  /// The page's type and colours for every view of it (the scroll, pages, a
  /// PDF's real pages, the bars over them), made as the page is built; the
  /// scroll's rows, built as it scrolls, take them from here.
  late PageStyle _style;

  /// The ground under everything: the app's, or the page tone's paper, with
  /// the phone's bars drawn to suit it. One shape for every tone: another
  /// shape for the app's own rebuilt the whole page under it, and the book
  /// went back to where it was opened.
  Widget _ground(BuildContext context, Widget child) {
    final icons = _style.barIcons;
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
        child: PageGround(tone: _style.tone, vignette: !_inPages, child: child),
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
        // A PDF's real pages keep the bars: a tap there reads from the page.
        FoldingBar(shown: _scrollBars, keep: _showPages, top: true, child: _topBar(context)),
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
                          onTapPage: (page) => _reader.goTo(_l.unitForPage(page), play: true),
                          controller: _pdf,
                          turn: _prefs.pages ? PageTurn.byName(_prefs.pageTurn) : null,
                          spread: MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height &&
                              MediaQuery.sizeOf(context).width >= 600,
                          tapToTurn: _prefs.tapToTurn,
                          dark: _style.pdfInk,
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
                          child: _tapForBars(toned(context, _style.tone, _text(context, glow: glow))),
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
        if (!rail) FoldingBar(shown: _scrollBars, keep: _showPages, top: false, child: bar),
      ],
    );
  }

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
      if (read && mounted) unawaited(_reader.goTo(_highlights.startOf(m) ?? unitOfMark(_l, m), play: true));
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
    unawaited(showBookmarks(
      context,
      layout: _l,
      marks: () => _bookmarks,
      onOpen: (u) {
        if (_inPages) _chrome.value = true;
        _reader.jump(u);
      },
      onRemove: (m) async {
        await MarkStore.instance.remove(m.id);
        if (!mounted) return;
        showSnack(context, 'Bookmark removed.',
            margin: _snackMargin, actionLabel: 'Undo', onAction: () => unawaited(MarkStore.instance.restore(m)));
      },
    ));
  }

  /// Back to reading, the search matches, or the way back after a jump:
  /// whichever is wanted, rising into place.
  Widget _pill(BuildContext context) {
    if (_hits.isNotEmpty) {
      return KeyedSubtree(
        key: const ValueKey('matches'),
        child: MatchesPill(
          query: _hitQuery,
          index: _hit,
          count: _hits.length,
          onStep: _stepHit,
          onDone: () => setState(() => _hits = const []),
        ),
      );
    }
    if (_reader.returnTo != null) {
      return KeyedSubtree(
        key: const ValueKey('return'),
        child: ReturnPill(
          onBack: () {
            final back = _reader.returnTo;
            setState(() => _reader.returnTo = null);
            if (back != null) unawaited(_reader.goTo(back));
          },
          onStay: () => setState(() => _reader.returnTo = null),
        ),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('back'),
      child: BackToReadingPill(detached: _detached, onTap: () => _reader.follow(force: true)),
    );
  }

  /// The book in pages, with the top bar and the player over them, shown
  /// by a tap in the middle of the page and gone as the page turns.
  Widget _pagedReading(BuildContext context, Widget bar, bool rail, Widget glow, EdgeInsets insets) {
    final style = _style;
    final ground = style.paperTop;
    final foot = style.paperFoot;
    final size = MediaQuery.sizeOf(context);
    // On its side, a wide screen opens like a book: two pages.
    final spread = size.width > size.height && size.width >= 600;
    return Stack(
      // The glow reaches past the safe area, as on the scrolling page.
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: toned(context, style.tone, PagedBook(
            layout: _l,
            look: style.look,
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
            paper: style.paper,
            crease: style.crease,
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
          child: SlidingBar(
            shown: _chrome,
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
          child: SlidingBar(
            shown: _chrome,
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
        // Built again on a web novel's chapters joined on, as the page is.
        ListenableBuilder(
          listenable: Listenable.merge([widget.window]),
          builder: (_, __) => NowPlayingScreen(
            key: key,
            title: _book.metadata.title,
            cover: _cover,
            layout: _l,
            cursor: _cursor,
            player: _player,
            speed: () => _speed,
            voiceLabel: _voiceLabel,
            sleepNote: () => _reader.sleepNote,
            onPlay: _reader.togglePlay,
            onGoTo: (u) => _reader.goTo(u),
            onPrevChapter: () => _reader.goChapter(-1),
            onNextChapter: () => _reader.goChapter(1),
            moreAfter: widget.onReachedEnd != null,
            onSpeed: () => showListenSheet(ctx, _listen, focus: ListenFocus.speed),
            onVoice: () => showListenSheet(ctx, _listen),
            onSleep: () => showListenSheet(ctx, _listen),
            onSave: () => _save(MarkKind.quote),
            onHold: (unit, word) => unawaited(_onLongPress(unit, word)),
          ),
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

  /// The top bar, for the scroll and over the pages.
  Widget _topBar(BuildContext context) => ReaderTopBar(
        layout: _l,
        style: _style,
        line: _topLine,
        cursor: _cursor,
        detached: _detached,
        viewChapter: _viewChapter,
        chapterNumber: _chapterNumber,
        positionOf: widget.positionOf,
        bookmarked: _bookmarkedHere,
        realPages: _isPdf ? _showPages : null,
        onRealPages: () {
          setState(() => _prefs.pdfPages = !_prefs.pdfPages);
          _prefs.save();
          _detached.value = false;
        },
        onContents: _openContents,
        onSearch: _openSearch,
        onBookmark: () => unawaited(_toggleBookmark()),
        onBookmarks: _openBookmarks,
        onSettings: () => showListenSheet(context, _listen, focus: ListenFocus.read),
      );

  Widget _text(BuildContext context, {Widget? glow}) {
    if (_l.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'This file has no text that can be read aloud.',
            textAlign: TextAlign.center,
            style: _style.emptyText,
          ),
        ),
      );
    }
    // Built afresh after the first time (back from a PDF's real pages), the
    // list opens at the place, not where the book was opened.
    final initial = _scrollFrom ??
        (_textShown ? _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)] : _startItem);
    _textShown = true;
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
        tone: _style.tone,
        vignette: !_inPages,
        child: glow == null ? const SizedBox.shrink() : Stack(children: [glow]),
      ),
    );
  }

  late final _fastText = _TextScrollTarget(this);

  /// The scroll has been shown once (see [_text]).
  bool _textShown = false;

  /// The fast scroller's thumb taken or let go: as a scroll by hand, a look
  /// around while listening, and the place moved there while reading.
  void _onFastScroll(bool dragging) {
    _reader.lastScroll = DateTime.now();
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
    // start is never scrolled past unnoticed. The same look as pages, so the
    // scroll is in the page tone's ink too.
    final look = _style.look;
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
            onTapUnit: (u) => _reader.goTo(u, play: true),
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
                  ? Icon(Icons.bookmark_rounded, size: 16, semanticLabel: 'Bookmarked', color: Skin.accentInkOf(context))
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
              await _reader.persist();
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
      final ink = _style.ornamentInk;
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

  int _chapterNumber(int c) => widget.chapterNumberOf?.call(c) ?? c + 1;

  static final _digit = RegExp(r'[0-9]');

  void _openContents() {
    final whole = widget.openContents;
    if (whole != null && !_l.isEmpty) {
      final s = _player.state.value;
      unawaited(_reader.persist());
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
      if (chapter != null && mounted) _reader.jump(_l.chapterFirstUnit[chapter]);
    }));
  }
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
      _s._reader.lastScroll != null &&
      DateTime.now().difference(_s._reader.lastScroll!) < const Duration(seconds: 2);

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

