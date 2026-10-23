import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'listen_sheet.dart';
import 'pages_view.dart';
import 'prefs.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';
import 'voices.dart';

const _svc = SpeechService();

/// Open [entry] in the reader, straight to where it was left.
Future<void> openBook(
  BuildContext context,
  LibraryStore store,
  LibraryEntry entry, {
  bool autoplay = false,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BookLoader(store: store, entry: entry, autoplay: autoplay),
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
  });

  final LibraryStore store;
  final LibraryEntry entry;
  final bool autoplay;

  @override
  State<BookLoader> createState() => _BookLoaderState();
}

class _BookLoaderState extends State<BookLoader> {
  // The place is read after the layout: loading may re-parse the book and
  // carry the saved place over to the new structure first.
  late final Future<(ReadingLayout, ReadingCursor)> _load = () async {
    final layout = await widget.store.loadLayout(widget.entry.id);
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
  });

  final ReadingLayout layout;
  final LibraryStore? store;
  final ReadingCursor initialCursor;
  final bool autoplay;

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
  PlayState _sessionState = PlayState.idle;
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
    )..onFinished = _onFinished;
    _player.unit.addListener(() => _cursor.value = _player.unit.value);
    _player.state.addListener(_onPlayState);
    _cursor.addListener(_onCursor);
    _catalog.addListener(_onCatalog);
    unawaited(_catalog.ensureLoaded());
    _events = SpeechService.events.listen(_onPlatformEvent);
    ListeningPrefs.revision.addListener(_onPrefs);
    unawaited(_loadPrefs());
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _togglePlay());
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

  bool _screenOn = false;

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ListeningPrefs.revision.removeListener(_onPrefs);
    if (_screenOn) unawaited(_svc.keepScreenOn(false));
    _persistTimer?.cancel();
    _restartTimer?.cancel();
    _sleepTimer?.cancel();
    unawaited(_persist());
    unawaited(_events?.cancel());
    _catalog.removeListener(_onCatalog);
    unawaited(_svc.session(active: false));
    _player.dispose();
    _cursor.dispose();
    _detached.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(_persist());
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
      _snack('Could not play a sample: $e');
    }
  }

  /// Stop reading after a while, or at the end of this chapter — for
  /// listening in bed with the screen off.
  void _setSleep(SleepChoice choice) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
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
    } else if (choice == SleepChoice.chapterEnd) {
      _sleepChapter = _l.chapterOfUnit(_cursor.value);
    }
    setState(() => _sleep = choice);
  }

  void _sleepNow(String message) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
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
    final c = (_l.chapterOfUnit(_cursor.value) + delta).clamp(0, _l.chapters.length - 1);
    unawaited(_goTo(_l.chapterFirstUnit[c]));
  }

  void _onSettingsChanged({required bool restart}) {
    if (mounted) setState(() {});
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
    if (mounted) {
      _snack('Finished. That is the end of the book.');
    }
  }

  void _onPlayState() {
    final s = _player.state.value;
    final err = _player.error.value;
    if (s == PlayState.idle && err != null && mounted) {
      _snack('Reading stopped: $err');
    }
    _updateSession();
  }

  void _updateSession({bool force = false}) {
    final s = _player.state.value;
    final chapter = _l.chapterOfUnit(_cursor.value);
    if (!force && s == _sessionState && chapter == _sessionChapter) return;
    final wasActive = _sessionState != PlayState.idle;
    _sessionState = s;
    _sessionChapter = chapter;
    if (s == PlayState.idle) {
      if (wasActive) unawaited(_svc.session(active: false));
      return;
    }
    unawaited(_svc.session(
      active: true,
      title: _book.metadata.title,
      subtitle: _l.chapterTitle(chapter),
      playing: s != PlayState.paused,
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
            unawaited(_player.stop());
          case 'next':
            unawaited(_goTo(_cursor.value + 1));
          case 'prev':
            unawaited(_goTo(_cursor.value - 1));
        }
    }
  }

  // --------------------------------------------------------------- cursor

  void _onCursor() {
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

  /// Scroll so the paragraph being read is in view, unless it already is.
  void _reveal(int unit, {bool force = false}) {
    if (_l.isEmpty || !_scroll.isAttached) return;
    final item = _l.unitItem[unit.clamp(0, _l.units.length - 1)];
    if (!force) {
      for (final p in _positions.itemPositions.value) {
        if (p.index == item && p.itemLeadingEdge >= 0.0 && p.itemTrailingEdge <= 0.9) {
          return;
        }
      }
    }
    _programmaticScroll = true;
    unawaited(_scroll
        .scrollTo(
          index: item,
          alignment: 0.15,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeInOutCubic,
        )
        .whenComplete(() => _programmaticScroll = false));
  }

  bool _onScrollNotification(ScrollNotification n) {
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
        progressFraction(_l.units, u),
        where: _l.chapterTitle(_l.unitChapter[u]),
      );
    } on Object {
      // Losing a position save is not worth an error on screen.
    }
  }

  void _snack(String text) {
    if (mounted) showSnack(context, text);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          child: Column(
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
                      bottom: 10,
                      child: Center(child: _backToReading(context)),
                    ),
                  ],
                ),
              ),
              _PlayerBar(
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
                onSeekInChapter: (u) => _goTo(u),
                onSpeed: () => showListenSheet(context, _listen, focus: ListenFocus.speed),
                onVoice: () => showListenSheet(context, _listen),
              ),
            ],
          ),
        ),
      ),
    );
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
                      ValueListenableBuilder<int>(
                        valueListenable: _cursor,
                        builder: (context, u, _) {
                          final c = _l.chapterOfUnit(u);
                          return Text(
                            _l.chapters.length > 1
                                ? '${_l.chapterTitle(c)}  ·  ${c + 1}/${_l.chapters.length}'
                                    .toUpperCase()
                                : (_book.metadata.authorLine.isEmpty
                                    ? _book.source.name.toUpperCase()
                                    : _book.metadata.authorLine.toUpperCase()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.meta(context, size: 10.5),
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
    final initial = _l.unitItem[_cursor.value.clamp(0, _l.units.length - 1)];
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
          itemCount: _l.items.length,
          itemScrollController: _scroll,
          itemPositionsListener: _positions,
          initialScrollIndex: initial,
          initialAlignment: initial == 0 ? 0 : 0.12,
          padding: EdgeInsets.fromLTRB(_prefs.margin, 16, _prefs.margin, 120),
          itemBuilder: (context, i) => _item(context, i),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i) {
    final item = _l.items[i];
    final chapterStart = i == _l.chapterFirstItem[item.chapter];
    final label = chapterStart && _l.chapters.length > 1
        ? Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : 44, bottom: 10),
            child: Row(
              children: [
                Text('CHAPTER ${item.chapter + 1}', style: Skin.meta(context, size: 10.5)),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Container(height: 1, color: Skin.inkFaintOn(context).withValues(alpha: 0.25)),
                ),
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
                style: Skin.title(context, size: 30 * _prefs.textSize / 19, weight: FontWeight.w500)),
          ),
        ],
      );
    }

    final heading = item.block!.role == BlockRole.heading;
    final scale = _prefs.textSize / 19;
    final style = heading
        ? Skin.title(context, size: (chapterStart ? 30 : 22) * scale, weight: FontWeight.w500)
            .copyWith(height: 1.2)
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
            heading: heading,
            justify: _prefs.justify && !heading,
            onTapUnit: (u) => _goTo(u, play: true),
          ),
        ),
      ],
    );
  }

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
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: detached ? 1 : 0,
            duration: const Duration(milliseconds: 180),
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
                    const Icon(Icons.my_location_rounded, size: 16, color: Skin.amber),
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

  void _openContents() {
    if (_l.chapters.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ContentsSheet(
        layout: _l,
        current: _l.chapterOfUnit(_cursor.value),
        onPick: (chapter) {
          Navigator.pop(ctx);
          unawaited(_goTo(_l.chapterFirstUnit[chapter]));
        },
      ),
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
    this.heading = false,
    this.justify = false,
  });

  final LayoutItem item;
  final ReadingLayout layout;
  final ValueListenable<int> cursor;
  final ValueListenable<WordMark> word;
  final TextStyle style;
  final ValueChanged<int> onTapUnit;

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

  void _onTapUp(TapUpDetails d) {
    final render = _paragraphOf(_key.currentContext?.findRenderObject());
    if (render == null) return;
    final offset = render.getPositionForOffset(render.globalToLocal(d.globalPosition)).offset;
    final l = widget.layout;
    var unit = widget.item.firstUnit;
    for (var u = widget.item.firstUnit; u < widget.item.firstUnit + widget.item.unitCount; u++) {
      if (l.unitOffset[u] <= offset) unit = u;
    }
    widget.onTapUnit(unit);
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
    return Semantics(
      button: true,
      hint: 'Double tap to read from here',
      child: GestureDetector(onTapUp: _onTapUp, child: body),
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
    final spoken = widget.heading ? const TextStyle(color: Skin.amber) : null;
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
    required this.onSeekInChapter,
    required this.onSpeed,
    required this.onVoice,
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
  final ValueChanged<int> onSeekInChapter;
  final VoidCallback onSpeed;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
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
          final chapter = empty ? 0 : layout.chapterOfUnit(u);
          final (first, count) = empty ? (0, 1) : layout.chapterRange(chapter);
          final inChapter = (u - first).clamp(0, count - 1);
          final wordsLeft = empty ? 0 : layout.totalWords - layout.wordsBefore[u];
          final minutes = (wordsLeft / (165 * speed)).round();
          final pct = empty ? 0 : (progressFraction(layout.units, u) * 100).round();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _chip(context, '${trimSpeed(speed)}×', Icons.speed_rounded, onSpeed,
                      tooltip: 'Speed'),
                  Expanded(
                    child: Text(
                      // With a sleep timer there is no room for all three.
                      [
                        if (sleepNote == null) '$pct%',
                        '${_duration(minutes)} LEFT',
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
              _ChapterScrubber(
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
                  _PlayButton(player: player, onTap: empty ? null : onPlay),
                  _icon(context, Icons.fast_forward_rounded, 'Next sentence',
                      u < layout.units.length - 1 ? onNextSentence : null),
                  _icon(context, Icons.skip_next_rounded, 'Next chapter',
                      chapter < layout.chapters.length - 1 ? onNextChapter : null),
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
              Icon(icon, size: 14, color: Skin.amberSoft),
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

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.player, required this.onTap});

  final PlaybackScheduler player;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayState>(
        valueListenable: player.state,
        builder: (context, state, _) {
          final speaking = state == PlayState.playing || state == PlayState.loading;
          return Tooltip(
            message: speaking ? 'Pause' : 'Play',
            child: SizedBox(
              width: 62,
              height: 62,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  if (state == PlayState.loading)
                    const SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Skin.amberSoft),
                    ),
                  Material(
                    color: onTap == null ? Skin.amber.withValues(alpha: 0.4) : Skin.amber,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onTap,
                      child: SizedBox(
                        width: 54,
                        height: 54,
                        child: Icon(
                          speaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 32,
                          color: Skin.onAmber,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

/// Position within the chapter. Drag or tap to jump.
class _ChapterScrubber extends StatefulWidget {
  const _ChapterScrubber({required this.value, required this.onSeek});

  final double value;
  final ValueChanged<double>? onSeek;

  @override
  State<_ChapterScrubber> createState() => _ChapterScrubberState();
}

class _ChapterScrubberState extends State<_ChapterScrubber> {
  double? _drag;

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          inactiveTrackColor: Skin.onDark(context).withValues(alpha: 0.14),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: SizedBox(
          height: 26,
          child: Slider(
            value: (_drag ?? widget.value).clamp(0.0, 1.0),
            semanticFormatterCallback: (v) => 'Chapter position ${(v * 100).round()} percent',
            onChanged: widget.onSeek == null ? null : (v) => setState(() => _drag = v),
            onChangeEnd: widget.onSeek == null
                ? null
                : (v) {
                    setState(() => _drag = null);
                    widget.onSeek!(v);
                  },
          ),
        ),
      );
}

class _ContentsSheet extends StatefulWidget {
  const _ContentsSheet({
    required this.layout,
    required this.current,
    required this.onPick,
  });

  final ReadingLayout layout;
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
        if (q.isEmpty || l.chapterTitle(c).toLowerCase().contains(q) || '${c + 1}' == q) c,
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
    this.controller,
    this.rowHeight = 56,
    this.shrinkWrap = false,
  });

  final ReadingLayout layout;
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
      color: isCurrent ? Skin.amber.withValues(alpha: 0.14) : Colors.transparent,
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
                child: Text('${c + 1}',
                    style: Skin.meta(context, size: 11.5, color: isCurrent ? Skin.amber : null)),
              ),
              Expanded(
                child: part
                    ? Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.meta(context, size: 12, color: isCurrent ? Skin.amber : Skin.inkSoftOn(context)),
                      )
                    : Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Skin.title(context, size: 17, color: isCurrent ? Skin.amber : null),
                      ),
              ),
              if (isCurrent) const Icon(Icons.graphic_eq_rounded, size: 18, color: Skin.amber),
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
