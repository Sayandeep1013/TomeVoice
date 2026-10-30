import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'listen_sheet.dart';
import 'listening_session.dart';
import 'prefs.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'stats.dart';

const _svc = SpeechService();

/// What a book's page does for the reading behind it (its
/// [ReaderController]): shows the place, says what happened, and turns its
/// pages. ReaderScreen's state is the one.
abstract interface class ReaderView {
  /// The page is still up.
  bool get mounted;

  /// As ReaderScreen's: the end of what is here reached (a web novel's
  /// next chapters still on the site), the chapter being read moved on, and
  /// how far through the whole work a sentence is.
  Future<void> Function({required bool playing, bool browse})? get onReachedEnd;
  ValueChanged<int>? get onChapterChanged;
  double Function(int u)? get progressOf;

  /// Something the page shows changed (the sleep timer, the speed, the way
  /// back after a jump, the cover): it is built again.
  void changed();

  /// Bring sentence [unit] into view, unless it already is; with [force],
  /// even then (Back to reading).
  void reveal(int unit, {bool force = false});

  /// The place moved: the bookmark at the top follows it.
  void placeMoved();

  /// A short message over the page.
  void say(String text);

  /// The card's Save this line: the sentence being read kept as a quote.
  void saveLine();

  /// The page keys (the volume keys, while they turn pages): a page on (1)
  /// or back (-1).
  void turnPage(int delta);

  /// Reading started, paused or stopped.
  void playStateChanged();
}

/// The reading behind a book's page: where the book is (the place, washed
/// on the page while it is read aloud and saved as it moves), the voice
/// reading it, and what comes with reading aloud: the card in the
/// notification shade and the headset's buttons, the phone's audio, the
/// sleep timer, and the time and words counted. The page draws all this
/// and moves it (see [ReaderView]); when it goes, the reading may go on
/// without it (see BackgroundReading).
class ReaderController {
  /// The reading of [layout] for [view]. This book reading on in the
  /// background is taken back, still reading; otherwise it is read from
  /// [initialCursor] (a place saved before is restored as it was; a book
  /// opened for the first time skips a title page named like it).
  ReaderController({
    required this.layout,
    required this.view,
    required ReadingCursor initialCursor,
    this.store,
  }) : cursor = ValueNotifier(layout.isEmpty
            ? 0
            : layout.unitForCursor(initialCursor, saved: initialCursor != ReadingCursor.zero)) {
    // This book reading on in the background: take its voice back, still
    // reading, so opening the book again does not break the flow.
    final bg = BackgroundReading.current.value;
    final back = bg != null && bg.bookId == _book.id ? bg.takeBack(layout) : null;
    if (bg != null && bg.bookId == _book.id && back == null) {
      // Its chapters changed meanwhile (a web novel): start again here.
      final u = bg.unitIn(layout);
      if (bg.playing) _resumeAt = u;
      cursor.value = u;
      unawaited(bg.stop());
    }
    player = back?.player ??
        readingScheduler(layout: layout, prefs: () => prefs, language: language, bookId: _book.id, service: _svc);
    player.onFinished = _onFinished;
    tookBack = back != null;
    if (back != null) {
      cursor.value = player.unit.value;
      _restoreSleep(back.sleep, back.sleepAt, back.sleepChapter);
    }
    player.unit.addListener(_onPlayerUnit);
    player.state.addListener(_onPlayState);
    player.notice.addListener(_onNotice);
    cursor.addListener(_syncMarked);
    cursor.addListener(_onCursor);
    _syncMarked();
    _events = SpeechService.events.listen(_onPlatformEvent);
    _statsTimer = Timer.periodic(const Duration(seconds: 15), (_) => countTime());
  }

  final ReadingLayout layout;
  final LibraryStore? store;
  final ReaderView view;

  Book get _book => layout.book;

  /// The book's language, its voices are chosen by.
  late final String language = primaryLanguage(_book.metadata.language);

  /// The reading and listening settings: the shared ones, once the page has
  /// loaded them.
  ListeningPrefs prefs = ListeningPrefs.memory;

  /// The place: the sentence being read, or to be read from.
  final ValueNotifier<int> cursor;

  /// The reader is looking around (scrolled or turned away from the voice);
  /// the voice keeps its place meanwhile.
  final detached = ValueNotifier<bool>(false);

  /// The sentence washed on the page: the place, while it is read aloud,
  /// and when the book opens (where you left off); -1 once the reader has
  /// read on without the voice, when a wash moving with the eyes would only
  /// be in the way.
  final marked = ValueNotifier<int>(-1);
  bool _placeShown = true;

  /// Set while the place follows the reader's eyes, so the page is not
  /// moved to it: it is already where they are looking.
  bool get quiet => _quiet;
  bool _quiet = false;

  /// Where the reader was before a jump (Contents, a search match), while
  /// reading without the voice: "Back to where you were".
  int? returnTo;

  late final PlaybackScheduler player;

  /// Opened while this book read on in the background: its voice taken back.
  late final bool tookBack;

  /// Opened while this book read on in the background, in chapters that
  /// have changed since (a web novel): the sentence it reads on from once
  /// the page is up; -1 for none.
  int get resumeAt => _resumeAt;
  var _resumeAt = -1;

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _persistTimer;
  Timer? _restartTimer;

  /// The phone's audio, followed as the background reading follows it.
  late final _focus = FocusFollower(
    pause: ({bool now = false}) => unawaited(player.pause(now: now)),
    resume: () => unawaited(player.resume(rewind: true)),
  );
  int _sessionChapter = -1;
  int _sessionUnit = -1;
  double _sessionSpeed = 0;
  PlayState _sessionState = PlayState.idle;

  /// The book's cover file, for the shade's media card.
  String? cover;

  /// This book in the library (web source, author), once looked up.
  LibraryEntry? entry;

  /// Reading time: counted every 15 seconds as listening (playing) or
  /// reading (scrolled in the last minute), from the time actually passed.
  Timer? _statsTimer;
  DateTime _lastTick = DateTime.now();

  /// When the reader last moved the page by hand: reading time, and the
  /// fast scroller's thumb.
  DateTime? lastScroll;
  int _statsUnit = -1;

  /// The card moved the place while paused. Moving stops the player, but
  /// the card stays up, paused at the new place, until reading resumes.
  bool _parked = false;

  SleepChoice _sleep = SleepChoice.off;
  Timer? _sleepTimer;
  DateTime? _sleepAt;
  int _sleepChapter = -1;

  /// Redraws the sleep countdown in the player bar.
  Timer? _sleepTick;

  /// The page is being left by Back (not replaced by another chapter's).
  bool leaving = false;

  /// The voice went on past this page's chapters without it (see
  /// [_readOn]): the reading, the card and the place are the background
  /// reading's until the page for those chapters takes them back.
  bool _handedOn = false;

  /// The voice is reading, or paused in the middle of it.
  bool get listening => player.state.value != PlayState.idle;

  /// Reading aloud goes on without this page: back goes to the library and
  /// the voice reads on there (Settings > Listening).
  bool get _readsOn =>
      leaving && prefs.keepReading && player.state.value != PlayState.idle && !layout.isEmpty && store != null;

  void _onPlayerUnit() => cursor.value = player.unit.value;

  /// A line from the player while it reads on (a natural voice that failed,
  /// and the phone's reading instead).
  void _onNotice() {
    final note = player.notice.value;
    if (note != null) view.say(note);
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
      player.fadeOutBy(at);
      _sleepTimer = Timer(at.difference(DateTime.now()), () => _sleepNow('Sleep timer: paused.'));
      _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (view.mounted && _sleepAt != null) view.changed();
      });
    }
  }

  /// The book's entry in the library, for its cover on the card (and the
  /// web source it came from).
  Future<void> loadCover() async {
    final store = this.store;
    if (store == null) return;
    try {
      final found = (await store.list(all: true)).where((e) => e.id == _book.id).firstOrNull;
      if (!view.mounted) return;
      entry = found;
      cover = found?.shownCover;
      view.changed();
      _updateSession(force: true);
    } on Object {
      // The card goes without a picture.
    }
  }

  /// Leaving the page: what it held goes, or goes on in the background.
  void dispose() {
    _sleepTick?.cancel();
    _persistTimer?.cancel();
    _restartTimer?.cancel();
    _sleepTimer?.cancel();
    _focus.dispose();
    _statsTimer?.cancel();
    countTime();
    unawaited(StatsStore.instance.flush());
    unawaited(persist());
    unawaited(_events?.cancel());
    player.notice.removeListener(_onNotice);
    if (_handedOn) {
      // The voice went on without this page (into the next chapters): the
      // card and the stream are the background reading's now, unless Back
      // left the book with reading on after leaving turned off.
      final bg = BackgroundReading.current.value;
      if (leaving && !prefs.keepReading && bg != null && bg.bookId == _book.id) unawaited(bg.stop());
      player.dispose();
    } else if (_readsOn) {
      player.unit.removeListener(_onPlayerUnit);
      player.state.removeListener(_onPlayState);
      player.onFinished = null;
      BackgroundReading.adopt(
        player: player,
        layout: layout,
        store: store!,
        bookId: _book.id,
        title: _book.metadata.title,
        cover: cover,
        language: language,
        web: view.onReachedEnd != null,
        sleepAt: _sleepAt,
        sleepChapter: _sleepChapter,
        sleep: _sleep,
      );
    } else {
      // Only a page whose voice was on the card takes the card away: an idle
      // page of another book must not end one reading in the background.
      if (_sessionState != PlayState.idle) unawaited(_svc.session(active: false));
      player.dispose();
    }
    cursor.dispose();
    detached.dispose();
    marked.dispose();
  }

  /// Read on past the chapters here (a web novel's, the rest still on the
  /// site), handing the voice to the reading that goes on without a page.
  /// Building the next chapters' page waits for a frame, and with the screen
  /// off none comes: the voice stopped at the end of what was fetched. The
  /// background reading needs none, keeps the card up meanwhile (Android 12
  /// may refuse to start it again from the background), and the next page
  /// takes the voice back when it is built. False with nowhere to hand it.
  Future<bool> _readOn() async {
    final store = this.store;
    if (_handedOn || store == null || layout.isEmpty) return false;
    _handedOn = true;
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    // Its own voice stops (it may be mid-chapter: Next chapter at the
    // last one), leaving the card up for the reading that carries on.
    await player.stop();
    player.endFade();
    if (!view.mounted) return false;
    final bg = BackgroundReading.adopt(
      player: readingScheduler(layout: layout, prefs: () => prefs, language: language, bookId: _book.id, service: _svc),
      layout: layout,
      store: store,
      bookId: _book.id,
      title: _book.metadata.title,
      cover: cover,
      language: language,
      web: true,
      sleepAt: _sleepAt,
      sleepChapter: _sleepChapter,
      sleep: _sleep,
    );
    unawaited(bg.readOn());
    return true;
  }

  // ---------------------------------------------------------------- sleep

  /// The sleep timer as it is set.
  SleepChoice get sleep => _sleep;

  /// Stop reading after a while, or at the end of this chapter — for
  /// listening in bed with the screen off.
  void setSleep(SleepChoice choice) {
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
      player.fadeOutBy(at);
      // The countdown in the player bar is redrawn as it runs.
      _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (view.mounted && _sleepAt != null) view.changed();
      });
    } else {
      player.endFade();
      if (choice == SleepChoice.chapterEnd) _sleepChapter = layout.chapterOfUnit(cursor.value);
    }
    _sleep = choice;
    view.changed();
  }

  void _sleepNow(String message) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepAt = null;
    _sleepChapter = -1;
    // Faded out already: paused at once, then back to full volume for Play.
    unawaited(player.pause(now: true).whenComplete(player.endFade));
    if (view.mounted) {
      _sleep = SleepChoice.off;
      view.changed();
      view.say(message);
    }
  }

  /// "SLEEP 25M" or "SLEEP AT CHAPTER END" while a sleep timer is set.
  String? get sleepNote {
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

  Future<void> togglePlay() async {
    if (layout.isEmpty) return;
    if (_handedOn) {
      // Shown a moment longer while the next chapters load: the voice is
      // the background reading's.
      final bg = BackgroundReading.current.value;
      if (bg != null && bg.bookId == _book.id) await bg.toggle();
      return;
    }
    switch (player.state.value) {
      case PlayState.idle:
        follow();
        await player.play(cursor.value);
      case PlayState.paused:
        // Scrolled away to look around: Play goes back to the voice first.
        if (detached.value) follow();
        await player.resume();
      case PlayState.playing:
      case PlayState.loading:
        await player.pause();
    }
  }

  /// Move to [unit]. Tapping text always means "read from here"; the
  /// buttons keep playing if we were playing and just move if not.
  Future<void> goTo(int unit, {bool play = false}) async {
    // Handed on: this page goes as soon as the next is built; the voice is
    // not to be pulled back to it.
    if (layout.isEmpty || _handedOn) return;
    final next = unit.clamp(0, layout.units.length - 1);
    _showPlace(true);
    cursor.value = next;
    follow();
    final state = player.state.value;
    if (play || state == PlayState.playing || state == PlayState.loading) {
      await player.play(next);
    } else if (state == PlayState.paused) {
      await player.stop();
    }
  }

  void goChapter(int delta) {
    final more = view.onReachedEnd;
    if (delta > 0 && more != null && layout.chapterOfUnit(cursor.value) >= layout.chapters.length - 1) {
      // Past what is here: the next chapters are still on the site.
      final s = player.state.value;
      final playing = s == PlayState.playing || s == PlayState.loading;
      unawaited(persist());
      if (playing) {
        // Read on there without waiting for a frame (the card's Next can
        // come with the screen off).
        unawaited(_readOn().then((_) => more(playing: true)));
      } else {
        unawaited(more(playing: false));
      }
      return;
    }
    final c = (layout.chapterOfUnit(cursor.value) + delta).clamp(0, layout.chapters.length - 1);
    unawaited(goTo(layout.chapterFirstUnit[c]));
  }

  /// Jump, remembering where the reader was so they can go back.
  void jump(int unit) {
    // Not while the voice reads (Back to reading is the way back then); a
    // pause counts as reading here, as the jump ends it and with it that way.
    if (!player.isPlaying && unit != cursor.value) {
      returnTo = cursor.value;
      view.changed();
    }
    unawaited(goTo(unit));
  }

  /// The settings changed (speed, voice, style, a pronunciation fixed).
  void settingsChanged({required bool restart}) {
    if (view.mounted) view.changed();
    _updateSession();
    if (!restart) return;
    // Make the change audible from the current sentence, once the user has
    // stopped fiddling.
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 350), () {
      final s = player.state.value;
      if (s == PlayState.playing || s == PlayState.loading) {
        unawaited(player.play(cursor.value));
      }
    });
  }

  void _onFinished() {
    unawaited(persist());
    final more = view.onReachedEnd;
    if (more != null) {
      // The end of the chapters here: the voice reads on into the next ones
      // without this page (see _readOn), and the web reader shows them.
      unawaited(_readOn().then((_) => more(playing: true)));
      return;
    }
    if (view.mounted) {
      view.say('Finished. That is the end of the book.');
    }
  }

  void _onPlayState() {
    final s = player.state.value;
    if (s == PlayState.playing || s == PlayState.loading) _parked = false;
    if (s != PlayState.idle) {
      if (!_placeShown) _showPlace(true);
      if (returnTo != null && view.mounted) {
        returnTo = null;
        view.changed();
      }
    }
    view.playStateChanged();
    final err = player.error.value;
    if (s == PlayState.idle && err != null && view.mounted) {
      view.say('Reading stopped: $err');
    }
    _updateSession();
  }

  // ----------------------------------------------------------- media card

  void _updateSession({bool force = false}) {
    // Handed on: the card is the background reading's.
    if (_handedOn) return;
    final actual = player.state.value;
    // The end of a web novel's chapters here, read on into the next: the
    // card stays up (playing) while they load. Ended, Android 12 might not
    // let it start again with the app in the background.
    final rolling = actual == PlayState.idle && player.reachedEnd && view.onReachedEnd != null;
    final s = actual == PlayState.idle && _parked
        ? PlayState.paused
        : rolling
            ? PlayState.loading
            : actual;
    final u = cursor.value;
    final chapter = layout.chapterOfUnit(u);
    final speed = this.speed;
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
    final clock = cardClock(layout, u, speed);
    // A book on a secret shelf is not named on the lock screen.
    final secret = store?.isSecret(_book.id) ?? false;
    unawaited(_svc.session(
      active: true,
      title: secret ? 'TomeVoice' : _book.metadata.title,
      subtitle: secret ? '' : layout.chapterTitle(chapter),
      playing: s != PlayState.paused,
      cover: secret ? null : cover,
      positionMs: clock.positionMs,
      durationMs: clock.durationMs,
      speed: speed,
    ));
  }

  void _onPlatformEvent(Map<String, Object?> e) {
    // Another book reads on in the background (or this one, handed on): the
    // card, the headset and the phone's audio are its, not this idle page's.
    final bg = BackgroundReading.current.value;
    if ((bg != null || _handedOn) && e['type'] != 'pageKey' && player.state.value == PlayState.idle) return;
    switch (e['type']) {
      case 'pageKey':
        view.turnPage((e['delta'] as num?)?.toInt() ?? 1);
      case 'action':
        switch (e['action']) {
          case 'play':
            if (player.state.value != PlayState.playing) unawaited(togglePlay());
          case 'pause':
            unawaited(player.pause());
          case 'stop':
            _parked = false;
            unawaited(player.stop());
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
            view.saveLine();
        }
      default:
        _focus.follow(e['type'], player);
    }
  }

  void _park() {
    if (player.state.value == PlayState.paused) _parked = true;
  }

  /// The speed this book reads at: its own, or everyone's.
  double get speed => prefs.speedFor(_book.id);

  /// Next (+1) or previous (-1) on headphones, the lock screen or the
  /// notification: a sentence (the default: a double press once lost a
  /// whole chapter), 30 seconds, or a chapter, as chosen in the sheet.
  void _cardSkip(int dir) {
    if (layout.isEmpty) return;
    final heard = player.state.value == PlayState.idle ? Duration.zero : player.heard;
    final to = skipTarget(layout, cursor.value, dir, prefs.skipBy, speed, heard);
    if (to != null) {
      unawaited(goTo(to));
    } else if (dir > 0) {
      goChapter(1);
    } else {
      _cardPrevious();
    }
  }

  /// The card's previous button: back to the start of this chapter, or to the
  /// previous chapter when within its first seconds, as a music player does.
  void _cardPrevious() {
    if (layout.isEmpty) return;
    final first = chapterStartBehind(layout, cursor.value, speed);
    if (first != null) {
      unawaited(goTo(first));
    } else {
      goChapter(-1);
    }
  }

  /// The card's seek bar was dragged to [ms] into the chapter.
  void _seekInChapter(int ms) {
    if (layout.isEmpty) return;
    unawaited(goTo(seekTarget(layout, cursor.value, ms, speed)));
  }

  /// The card's speed button: the next of the common speeds, round to the
  /// slowest after the fastest (this book's own speed, if it has one).
  void _nextSpeed() {
    prefs.setSpeed(nextSpeed(speed), book: _book.id);
    prefs.save();
    settingsChanged(restart: true);
  }

  // --------------------------------------------------------------- cursor

  int _lastSection = -1;

  /// Time since the last count, to listening or reading. A gap longer than a
  /// tick (the phone asleep with nothing playing) is not counted.
  void countTime() {
    final now = DateTime.now();
    final passed = now.difference(_lastTick);
    _lastTick = now;
    if (passed > const Duration(seconds: 20) || layout.isEmpty) return;
    if (player.isPlaying) {
      StatsStore.instance.addTime(_book.id, passed, listening: true);
    } else if (lastScroll != null && now.difference(lastScroll!) < const Duration(minutes: 1)) {
      StatsStore.instance.addTime(_book.id, passed, listening: false);
    }
  }

  /// A sentence heard to its end (reading moved on by one while playing),
  /// and a chapter finished (the next one begun).
  void _countProgress(int u) {
    final prev = _statsUnit;
    _statsUnit = u;
    countHeard(layout, prev, u, playing: player.isPlaying);
  }

  void _onCursor() {
    _countProgress(cursor.value);
    final changed = view.onChapterChanged;
    if (changed != null && !layout.isEmpty) {
      final section = layout.units[cursor.value.clamp(0, layout.units.length - 1)].sectionIndex;
      if (section != _lastSection) {
        _lastSection = section;
        changed(section);
      }
    }
    if (_sleep == SleepChoice.chapterEnd &&
        _sleepChapter >= 0 &&
        layout.chapterOfUnit(cursor.value) != _sleepChapter) {
      _sleepNow('End of chapter: paused.');
    }
    _schedulePersist();
    _updateSession();
    if (!detached.value && !_quiet) view.reveal(cursor.value);
    view.placeMoved();
  }

  /// Resume following the voice. [force] scrolls even if the paragraph is
  /// already on screen (the "Back to reading" pill).
  void follow({bool force = false}) {
    detached.value = false;
    view.reveal(cursor.value, force: force);
  }

  void _syncMarked() => marked.value = _placeShown ? cursor.value : -1;

  void _showPlace(bool on) {
    _placeShown = on;
    _syncMarked();
  }

  /// The place moved to the sentence the reader's eyes are on (read on by
  /// scrolling, or a page turned by hand), with no wash following them and
  /// the page left where it is.
  void moveQuietly(int u) {
    detached.value = false;
    _placeShown = false;
    _quiet = true;
    cursor.value = u.clamp(0, layout.units.length - 1);
    _quiet = false;
    _syncMarked();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1500), () => unawaited(persist()));
  }

  /// Save the place now.
  Future<void> persist() async {
    final store = this.store;
    // Handed on: the place is the background reading's, further on.
    if (store == null || layout.isEmpty || _handedOn) return;
    final u = cursor.value.clamp(0, layout.units.length - 1);
    try {
      await store.saveCursor(
        _book.id,
        cursorOf(layout.units[u]),
        view.progressOf?.call(u) ?? progressFraction(layout.units, u),
        where: layout.chapterTitle(layout.unitChapter[u]),
      );
    } on Object {
      // Losing a position save is not worth an error on screen.
    }
  }
}
