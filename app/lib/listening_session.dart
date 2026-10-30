import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'listen_sheet.dart';
import 'marks.dart';
import 'prefs.dart';
import 'reading_rules.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'stats.dart';
import 'voices.dart';
import 'web_reader.dart';

/// The scheduler that reads [layout] of book [bookId] aloud, as the reader
/// sets one up: its voice (and dialogue voice), speed, pronunciation fixes,
/// what its skip presets pass over, and pauses. One place, so a book read
/// on after its page is closed (or saved as audio) sounds as it did on it.
PlaybackScheduler readingScheduler({
  required ReadingLayout layout,
  required ListeningPrefs Function() prefs,
  required String language,
  required String bookId,
  SpeechService service = const SpeechService(),
}) {
  ListenController listen() =>
      ListenController(prefs: prefs(), language: language, bookId: bookId, onChanged: ({required bool restart}) {});

  // The chapters read: a web novel's window of them grows as the reading
  // rolls it on (see readOnInto), and the pauses are found in it as it is.
  final read = _Read(layout);

  int pauseAfter(int i) {
    final layout = read.layout;
    final s = prefs().settings;
    if (i + 1 >= layout.units.length) return s.sentencePauseMs;
    final here = layout.units[i];
    final next = layout.units[i + 1];
    if (layout.unitChapter[i] != layout.unitChapter[i + 1]) return s.paragraphPauseMs + 400;
    if (next.blockId != here.blockId) return s.paragraphPauseMs;
    return s.sentencePauseMs;
  }

  // Whether a quotation is still open where sentence [u] begins, counted
  // over its paragraph's text before it: an odd number of straight quotes,
  // or more opening curly marks than closing ones.
  bool quoteOpenAt(int u) {
    final layout = read.layout;
    if (u < 0 || u >= layout.units.length) return false;
    final text = layout.items[layout.unitItem[u]].block?.text ?? '';
    final before = text.substring(0, layout.unitOffset[u].clamp(0, text.length));
    final straight = '"'.allMatches(before).length;
    final opens = RegExp('[“«「]').allMatches(before).length;
    final closes = RegExp('[”»」]').allMatches(before).length;
    return straight.isOdd || opens > closes;
  }

  sendHighlightOffsets(prefs(), service);
  final scheduler = PlaybackScheduler(
    service: service,
    units: layout.units,
    settingsFor: (text) => prefs().settingsFor(listen().voiceName, book: bookId).copyWith(text: text),
    engineIdOf: () => prefs().engineId ?? VoiceCatalog.instance.engineId,
    voiceNameOf: () => listen().voiceName,
    pauseAfter: pauseAfter,
    // The reader's fixes, and what the book's presets pass over (an author's
    // note, a row of symbols), found with the chapter the sentence is in.
    respell: (unit) {
      final rules = ReadingRules.instance;
      final on = rules.presetsFor(bookId);
      final l = read.layout;
      return respellUnit(unit, rules.sayFor(bookId),
          presets: on, quiet: quietStretches(l.book, unit, on, skipped: l.skipped));
    },
    dialogueVoiceOf: () => listen().dialogueVoice,
    pitchOf: (voice) => prefs().pitchOf(voice),
    quoteOpenAt: quoteOpenAt,
    fallbackVoiceOf: () => VoiceCatalog.instance.bestFor(language)?.name,
  );
  _bookOf[scheduler] = bookId;
  _readOf[scheduler] = read;
  return scheduler;
}

/// [player], made by [readingScheduler], reads on into [longer]: the layout
/// it reads with the chapters after it joined on, its sentences the same
/// and in the same places. The voice goes on into them with no gap.
void readOnInto(PlaybackScheduler player, ReadingLayout longer) {
  _readOf[player]?.layout = longer;
  player.readOnInto(longer.units);
}

/// Whether [longer] begins with [now]'s sentences, the same and in the same
/// order: a reading of [now] can then go on into it, every place kept.
bool continuesLayout(ReadingLayout longer, ReadingLayout now) {
  if (longer.units.length < now.units.length) return false;
  for (var i = 0; i < now.units.length; i++) {
    final a = now.units[i];
    final b = longer.units[i];
    if (a.sectionIndex != b.sectionIndex ||
        a.blockIndex != b.blockIndex ||
        a.sentenceIndex != b.sentenceIndex ||
        a.text != b.text) {
      return false;
    }
  }
  return true;
}

/// The book each scheduler reads (a book's page's, or the background's):
/// a Play from outside the app for the book a page is reading carries on
/// there.
final _bookOf = Expando<String>('book');

/// The layout each scheduler made by [readingScheduler] reads.
final _readOf = Expando<_Read>('read');

class _Read {
  _Read(this.layout);
  ReadingLayout layout;
}

/// The reader's Highlight timing, per route, to the player.
void sendHighlightOffsets(ListeningPrefs p, [SpeechService service = const SpeechService()]) => unawaited(
      service.setHighlightOffsets(
        bluetoothMs: p.highlightOffset(SpeechService.routeBluetooth),
        otherMs: p.highlightOffset(SpeechService.routeOther),
      ),
    );

/// A book's language as its voices are chosen by: "bn" from "bn-BD".
String primaryLanguage(String? tag) {
  final t = (tag ?? 'en').toLowerCase();
  final p = t.split(RegExp('[-_]')).first;
  return p.length >= 2 ? p : 'en';
}

/// A transient loss of the audio longer than this (a long call, not a
/// notification's ping) does not resume on its own when it ends: the
/// listener may have walked away.
const resumeAfterLossWithin = Duration(minutes: 1);

/// Where next (+1) or previous (-1) on headphones, the lock screen or the
/// notification take a reading at sentence [u] when they skip [by] a
/// sentence or 30 seconds, at [speed]. Previous goes back to the start of
/// the sentence being heard when [heard] of it is already past, as a music
/// player's does with a song. Null when they skip by chapter, which the
/// reader and the background reading each do in their own way (a web
/// novel's next chapter may still be on the site).
int? skipTarget(ReadingLayout l, int u, int dir, SkipBy by, double speed, Duration heard) {
  if (l.isEmpty) return null;
  final last = l.units.length - 1;
  switch (by) {
    case SkipBy.chapter:
      return null;
    case SkipBy.sentence:
      if (dir < 0 && heard > const Duration(seconds: 2)) return u.clamp(0, last);
      return (u + dir).clamp(0, last);
    case SkipBy.seconds:
      final words = l.wordsBefore[u.clamp(0, last)] + dir * 30 * 165 * speed / 60;
      var v = u.clamp(0, last);
      while (dir > 0 && v < last && l.wordsBefore[v + 1] <= words) {
        v++;
      }
      while (dir < 0 && v > 0 && l.wordsBefore[v] > words) {
        v--;
      }
      return v;
  }
}

/// What a reader takes back from a book read on in the background.
typedef TakenBack = ({
  PlaybackScheduler player,
  DateTime? sleepAt,
  int sleepChapter,
  SleepChoice sleep,
});

/// A book read on after its page was closed: back from the reader goes to
/// the library while the voice carries on, as a music player's does. It
/// keeps everything the reader did while reading aloud: the place saved,
/// the card in the notification shade and its buttons, the sleep timer,
/// listening time, pausing for calls and unplugged headphones, and a web
/// novel's next chapters fetched and read on into. Pausing it (from the
/// library's player, the card or a headset) keeps it, paused; stopping it
/// from the card, or playing another book, ends it. Opening the book again
/// takes it back without a break.
///
/// It also carries a reading over the end of a web novel's chapters while
/// its page is still open (see [readOn]): that needs no frame drawn, so it
/// goes on with the screen off, where the page's own next chapter waits for
/// the screen to come on.
class BackgroundReading {
  BackgroundReading._({
    required this.player,
    required ReadingLayout layout,
    required this.store,
    required this.bookId,
    required this.title,
    required this.cover,
    required this.language,
    required this.web,
    required DateTime? sleepAt,
    required int sleepChapter,
    required SleepChoice sleep,
  })  : _layout = ValueNotifier(layout),
        _sleepAt = sleepAt,
        _sleepChapter = sleepChapter,
        _sleep = sleep;

  /// The book read on in the background, if any; the library's player
  /// listens here.
  static final current = ValueNotifier<BackgroundReading?>(null);

  PlaybackScheduler player;
  final ValueNotifier<ReadingLayout> _layout;
  final LibraryStore store;
  final String bookId;
  final String title;
  final String? cover;
  final String language;

  /// The chapters being read; it changes as a web novel reads on.
  ReadingLayout get layout => _layout.value;

  /// Told when the reading moves into another layout (a web novel's next
  /// chapters), so the web reader's page can follow it.
  ValueListenable<ReadingLayout> get layouts => _layout;

  /// A web novel: its next chapters are fetched as it goes.
  final bool web;

  static const _svc = SpeechService();
  static ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  DateTime? _sleepAt;
  int _sleepChapter;
  SleepChoice _sleep;
  Timer? _sleepTimer;
  Timer? _persistTimer;
  Timer? _statsTimer;
  DateTime _lastTick = DateTime.now();
  StreamSubscription<Map<String, Object?>>? _events;

  /// Paused for the phone's audio taken a moment: resumed when it comes
  /// back, unless that took longer than [resumeAfterLossWithin].
  bool _resumeOnFocus = false;
  Timer? _lossTimer;

  /// The move into the next chapters under way, if one is.
  Future<bool?>? _rolling;

  /// The chapters after a web novel's window being joined to it, if they
  /// are (see [_extend]).
  Future<void>? _extending;

  /// Where they were last looked for: the window's last chapter, and the
  /// chapter being read then.
  (int, int)? _extendTried;

  /// Moved by the card while paused: where Play carries on from.
  int? _parkedAt;
  int _lastUnit = -1;
  int _webTotal = 0;
  int _fetchedFor = -1;

  /// The sentence being read (or parked at).
  int get unit => _parkedAt ?? player.unit.value;

  bool get playing => player.isPlaying;

  /// Whether it is reading aloud right now, for the library's player.
  final playingNow = ValueNotifier<bool>(true);

  /// The move into the next chapters under way, if one is: true once it
  /// reads on there, false when there was nothing more (it has stopped),
  /// null when something else stopped it first.
  Future<bool?>? get rolling => _rolling;

  /// Take over [player], reading [layout] of [bookId], from a reader whose
  /// page is closing (or handing its reading on, see [readOn]).
  static BackgroundReading adopt({
    required PlaybackScheduler player,
    required ReadingLayout layout,
    required LibraryStore store,
    required String bookId,
    required String title,
    required String? cover,
    required String language,
    required bool web,
    DateTime? sleepAt,
    int sleepChapter = -1,
    SleepChoice sleep = SleepChoice.off,
  }) {
    PlaybackScheduler.beforePlay ??= claim;
    current.value?.stop();
    final b = BackgroundReading._(
      player: player,
      layout: layout,
      store: store,
      bookId: bookId,
      title: title,
      cover: cover,
      language: language,
      web: web,
      // A time already past fired in the reader; it is not armed again.
      sleepAt: sleepAt != null && sleepAt.isAfter(DateTime.now()) ? sleepAt : null,
      sleepChapter: sleepChapter,
      sleep: sleep,
    );
    b._attach();
    b._events = SpeechService.events.listen(b._onEvent);
    b._statsTimer = Timer.periodic(const Duration(seconds: 15), (_) => b._countTime());
    b._armSleep();
    if (web) {
      unawaited(store.webNovel(bookId).then((info) => b._webTotal = info?.chapters.length ?? 0));
    }
    current.value = b;
    b._updateCard();
    return b;
  }

  /// Read [e] aloud from where it was left, without opening it: the
  /// library's player. A web novel's chapter there is fetched first if it
  /// is not on the phone.
  static Future<void> startFrom(LibraryStore store, LibraryEntry e) async {
    final playing = current.value;
    if (playing != null && playing.bookId == e.id) return playing.resume();
    final web = e.source == SourceKind.web;
    var cursor = await store.cursorFor(e.id);
    if (web) {
      try {
        await fetchChapters(store, e.id, cursor.sectionIndex, count: 2);
      } on Object {
        // Read what is on the phone.
      }
    }
    // A web novel's window of chapters round its place, as its page opens
    // one: a novel of thousands is never read in whole (see webWindow).
    final layout = await store.loadLayout(e.id, around: web ? cursor.sectionIndex : null);
    if (layout.isEmpty) return;
    cursor = await store.cursorFor(e.id);
    final language = primaryLanguage(layout.book.metadata.language);
    final player = readingScheduler(layout: layout, prefs: () => _prefs, language: language, bookId: e.id);
    adopt(
      player: player,
      layout: layout,
      store: store,
      bookId: e.id,
      title: e.title,
      cover: e.shownCover,
      language: language,
      web: web,
    );
    await player.play(layout.unitForCursor(cursor, saved: true));
  }

  /// The player is about to read something else: whatever plays in the
  /// background stops first (two players cannot share the one stream).
  static void claim(PlaybackScheduler? next) {
    if (next != null) _claimed = next;
    final b = current.value;
    if (b != null && !identical(b.player, next)) unawaited(b.stop());
  }

  /// The scheduler that began to read last (a voice's sample aside): a
  /// book's page's, or the background's. With nothing in the background and
  /// the card up, it is a page's, reading or paused.
  static PlaybackScheduler? _claimed;

  /// Read book [id], asked for from outside the app: the system's resume
  /// card, a headset's Play, a book picked in Android Auto. The book already
  /// reading carries on: in the background, or in its page (which may be
  /// kept with the app closed); anything else reading stops, and the book
  /// is read in the background from its place, as the library's player
  /// reads one. [reading]: whether a reading had the card when it was asked.
  /// False when it cannot be read: not in the library, or on a secret shelf
  /// that is shut.
  static Future<bool> playFromOutside(LibraryStore store, String id, {required bool reading}) async {
    final playing = current.value;
    if (playing != null && playing.bookId == id) {
      await playing.resume();
      return true;
    }
    final page = reading && playing == null ? _claimed : null;
    if (page != null && page.active) {
      if (_bookOf[page] == id) {
        if (page.state.value == PlayState.paused) await page.resume();
        return true;
      }
      await page.stop();
    }
    final entry = (await store.list(all: true)).where((e) => e.id == id).firstOrNull;
    if (entry == null || (store.isSecret(id) && !LibraryStore.secretOpen.value)) return false;
    // The book's own voice, which only the loaded catalogue knows (the
    // shelf loads it; with no screen, nothing has).
    await VoiceCatalog.instance.ensureLoaded();
    await startFrom(store, entry);
    return current.value?.bookId == id;
  }

  void _attach() {
    _lastUnit = player.unit.value;
    player.unit.addListener(_onUnit);
    player.state.addListener(_onState);
    player.onFinished = () => unawaited(readOn());
    playingNow.value = playing;
  }

  void _detach() {
    player.unit.removeListener(_onUnit);
    player.state.removeListener(_onState);
    player.onFinished = null;
  }

  void _release() {
    _detach();
    _sleepTimer?.cancel();
    _lossTimer?.cancel();
    _statsTimer?.cancel();
    _persistTimer?.cancel();
    unawaited(_events?.cancel());
    _countTime();
    unawaited(StatsStore.instance.flush());
    if (identical(current.value, this)) current.value = null;
  }

  /// The reader of this book is open again: it takes the player back, still
  /// reading, with the sleep timer as it stands. Null when [layout] is not
  /// the one being read (a web novel whose chapters changed meanwhile): the
  /// reading stops here and the reader starts it again at [unitIn].
  TakenBack? takeBack(ReadingLayout readerLayout) {
    final same = identical(readerLayout, layout) ||
        (readerLayout.units.length == layout.units.length &&
            (layout.units.isEmpty ||
                (readerLayout.units.first.text == layout.units.first.text &&
                    readerLayout.units.last.text == layout.units.last.text)));
    if (!same || _parkedAt != null || _rolling != null) return null;
    _persistNow();
    _release();
    return (player: player, sleepAt: _sleepAt, sleepChapter: _sleepChapter, sleep: _sleep);
  }

  /// Where this reading is, as a sentence of [other] (another layout of the
  /// same book).
  int unitIn(ReadingLayout other) {
    if (layout.isEmpty || other.isEmpty) return 0;
    return other.unitForCursor(cursorOf(layout.units[unit.clamp(0, layout.units.length - 1)]), saved: true);
  }

  Future<void> pause({bool now = false}) async {
    await player.pause(now: now);
    _updateCard();
  }

  Future<void> resume({bool rewind = false}) async {
    final parked = _parkedAt;
    _parkedAt = null;
    if (parked != null) {
      await player.play(parked);
    } else if (player.state.value == PlayState.paused) {
      await player.resume(rewind: rewind);
    } else if (player.state.value == PlayState.idle) {
      await player.play(player.unit.value);
    }
    _updateCard();
  }

  Future<void> toggle() => playing ? pause() : resume();

  /// The end: the place saved, the card gone.
  Future<void> stop() async {
    if (!identical(current.value, this)) return;
    _persistNow();
    _release();
    player.endFade();
    await player.stop();
    player.dispose();
    await _svc.session(active: false);
  }

  // ---------------------------------------------------------------- sleep

  void _armSleep() {
    _sleepTimer?.cancel();
    final at = _sleepAt;
    if (at == null) return;
    player.fadeOutBy(at);
    _sleepTimer = Timer(at.difference(DateTime.now()), () {
      // Fired: not to be armed again by the book opened after.
      _sleepAt = null;
      _sleep = SleepChoice.off;
      unawaited(pause(now: true).whenComplete(player.endFade));
    });
  }

  // ------------------------------------------------------------ following

  void _onUnit() {
    final u = player.unit.value;
    final prev = _lastUnit;
    _lastUnit = u;
    if (prev >= 0 && u == prev + 1 && player.isPlaying && !layout.isEmpty) {
      StatsStore.instance.addWords(layout.wordsBefore[u] - layout.wordsBefore[prev]);
      if (layout.chapterOfUnit(u) == layout.chapterOfUnit(prev) + 1) StatsStore.instance.addChapter();
    }
    if (_sleep == SleepChoice.chapterEnd && _sleepChapter >= 0 && layout.chapterOfUnit(u) != _sleepChapter) {
      _sleep = SleepChoice.off;
      _sleepChapter = -1;
      unawaited(pause());
    }
    if (web) {
      _extendNear(u);
      // (Joining them on fetches them too.)
      if (_extending == null) _fetchAhead(u);
    }
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1500), _persistNow);
    _updateCard();
  }

  void _onState() {
    if (player.state.value != PlayState.idle) _parkedAt = null;
    playingNow.value = playing || _rolling != null;
    _updateCard();
  }

  /// The end of what is here: a web novel's next chapters are fetched (the
  /// site asked for new ones when its list runs out) and read on into, in a
  /// new player on the longer layout; a book has ended. Needs no frame, so
  /// it carries on with the screen off. The card stays up, playing, while it
  /// does. See [rolling] for the answer.
  Future<bool?> readOn() => _rolling ??= _readOn().whenComplete(() => _rolling = null);

  Future<bool?> _readOn() async {
    playingNow.value = true;
    _updateCard();
    final carried = await _intoNext();
    if (carried == false) await stop();
    return carried;
  }

  Future<bool?> _intoNext() async {
    if (!web || layout.isEmpty) return false;
    final last = layout.units.last.sectionIndex;
    try {
      // The next chapters were being joined on as the last sentences were
      // heard: read on there, in this player.
      await _extending;
      if (!identical(current.value, this)) return null;
      var start = layout.units.indexWhere((u) => u.sectionIndex > last);
      if (start < 0) {
        await fetchChapters(store, bookId, last + 1);
        // A window of chapters from there, not every one on the phone.
        var next = await store.loadLayout(bookId, around: last + 1);
        start = next.units.indexWhere((u) => u.sectionIndex > last);
        if (start < 0) {
          // The last chapter the site listed: ask it for new ones.
          final after = await refreshWebChapters(store, bookId, last);
          if (after == null) return false;
          await fetchChapters(store, bookId, after);
          next = await store.loadLayout(bookId, around: after);
          start = next.units.indexWhere((u) => u.sectionIndex >= after);
          if (start < 0) return false;
        }
        if (!identical(current.value, this)) return null;
        _detach();
        final old = player;
        _layout.value = next;
        player = readingScheduler(layout: next, prefs: () => _prefs, language: language, bookId: bookId);
        _attach();
        old.dispose();
      }
      _fetchedFor = -1;
      if (_sleep == SleepChoice.chapterEnd) {
        // Asked to stop at the chapter's end: waits at the next, paused.
        _sleep = SleepChoice.off;
        _sleepChapter = -1;
        _parkedAt = start;
        _persistNow();
        _updateCard();
        return true;
      }
      _armSleep();
      await player.play(start);
      return true;
    } on Object {
      return identical(current.value, this) ? false : null;
    }
  }

  /// The voice is in the last two chapters of a web novel's window: the
  /// chapters after it are joined on while it reads (see [_extend]), with a
  /// chapter to spare.
  void _extendNear(int u) {
    if (_extending != null || _rolling != null || layout.isEmpty) return;
    final chapter = layout.chapterOfUnit(u);
    if (chapter < layout.chapters.length - 2) return;
    // Once a chapter, not at every sentence (offline, each would try the site).
    final at = (layout.units.last.sectionIndex, chapter);
    if (at == _extendTried) return;
    _extendTried = at;
    _extending = _extend().whenComplete(() => _extending = null);
  }

  /// Join the chapters after a web novel's window to it, fetched first if
  /// they are not on the phone: the same player reads on into them, so the
  /// voice goes on with no gap (a new player would start a new stream, and
  /// wait for its first sentence to be made). Only the window and the
  /// chapters after it are read, never the whole novel: listening used to
  /// parse every chapter on the phone, thousands for a long novel, at every
  /// Play and at every end of what was fetched. Nothing changes if the
  /// window changed meanwhile, or its chapters no longer read the same (a
  /// skip rule since).
  Future<void> _extend() async {
    final now = layout;
    final reading = player;
    final last = now.units.last.sectionIndex;
    try {
      await fetchChapters(store, bookId, last + 1);
    } on Object {
      // Offline: what is on the phone.
    }
    try {
      final info = await store.webNovel(bookId);
      if (info == null) return;
      final more = webWindow(last + 1, info.chapters.length, store.downloadedChapters(bookId).contains, before: 0);
      if (more.isEmpty || !identical(current.value, this)) return;
      final longer = await store.loadLayout(bookId, chapters: {...now.chapters, ...more});
      if (!identical(current.value, this) || !identical(layout, now) || !identical(player, reading)) return;
      if (longer.units.length == now.units.length || !continuesLayout(longer, now)) return;
      _layout.value = longer;
      readOnInto(reading, longer);
    } on Object catch (e) {
      // Read on at the end instead, as before (see readOn).
      debugPrint('TomeVoice: the next chapters could not be joined on: $e');
    }
  }

  /// Keep the next chapter on the phone before the voice gets there.
  void _fetchAhead(int u) {
    final section = layout.units[u.clamp(0, layout.units.length - 1)].sectionIndex;
    if (section == _fetchedFor) return;
    _fetchedFor = section;
    if (store.hasChapter(bookId, section + 1)) return;
    unawaited(fetchChapters(store, bookId, section + 1).catchError((Object _) {}));
  }

  void _persistNow() {
    _persistTimer?.cancel();
    if (layout.isEmpty) return;
    final u = unit.clamp(0, layout.units.length - 1);
    unawaited(store
        .saveCursor(bookId, cursorOf(layout.units[u]), _progress(u), where: layout.chapterTitle(layout.unitChapter[u]))
        .catchError((Object _) {}));
  }

  double _progress(int u) {
    if (!web || _webTotal == 0) return progressFraction(layout.units, u);
    final chapter = layout.units[u].sectionIndex;
    final (first, count) = layout.chapterRange(layout.chapterOfUnit(u));
    final within = count <= 1 ? 0.0 : (u - first) / count;
    return ((chapter + within) / _webTotal).clamp(0.0, 1.0);
  }

  void _countTime() {
    final now = DateTime.now();
    final passed = now.difference(_lastTick);
    _lastTick = now;
    if (passed > const Duration(seconds: 20) || !player.isPlaying) return;
    StatsStore.instance.addTime(bookId, passed, listening: true);
  }

  // ----------------------------------------------------------------- card

  double get _speed => _prefs.speedFor(bookId);
  int _wordsAt(int u) => u < layout.units.length ? layout.wordsBefore[u] : layout.totalWords;
  int _msFor(int words) => (words / (165 * _speed) * 60000).round();

  void _updateCard() {
    if (!identical(current.value, this) || layout.isEmpty) return;
    final s = player.state.value;
    final u = unit.clamp(0, layout.units.length - 1);
    final chapter = layout.chapterOfUnit(u);
    final (first, count) = layout.chapterRange(chapter);
    // A book on a secret shelf is not named on the lock screen.
    final secret = store.isSecret(bookId);
    unawaited(_svc.session(
      active: true,
      title: secret ? 'TomeVoice' : title,
      subtitle: secret ? '' : layout.chapterTitle(chapter),
      // Moving into the next chapters counts as playing: the card (and the
      // phone kept awake) stay with it.
      playing: s == PlayState.playing || s == PlayState.loading || (_rolling != null && _parkedAt == null),
      cover: secret ? null : cover,
      positionMs: _msFor(_wordsAt(u) - _wordsAt(first)),
      durationMs: _msFor(_wordsAt(first + count) - _wordsAt(first)),
      speed: _speed,
      book: secret ? null : bookId,
    ));
  }

  /// The card's buttons, a headset's, and the phone's audio.
  void _onEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'noisy':
        // Unplugged: not another word out of the speaker.
        _resumeOnFocus = false;
        unawaited(pause(now: true));
      case 'focusLoss':
        _resumeOnFocus = false;
        unawaited(pause());
      case 'focusLossTransient':
        if (playing) {
          _resumeOnFocus = true;
          _lossTimer?.cancel();
          _lossTimer = Timer(resumeAfterLossWithin, () => _resumeOnFocus = false);
          unawaited(pause(now: true));
        }
      case 'focusGain':
        // From the start of the sentence the interruption cut into; not at
        // all after a long one (a call: the listener may have gone).
        _lossTimer?.cancel();
        if (_resumeOnFocus && player.state.value == PlayState.paused) unawaited(resume(rewind: true));
        _resumeOnFocus = false;
      case 'action':
        switch (e['action']) {
          case 'play':
            if (!playing) unawaited(resume());
          case 'pause':
            unawaited(pause());
          case 'stop':
            unawaited(stop());
          case 'next':
            _skip(1);
          case 'prev':
            _skip(-1);
          case 'seek':
            final (first, count) = layout.chapterRange(layout.chapterOfUnit(unit));
            final ms = (e['value'] as num?)?.toInt() ?? 0;
            final target = _wordsAt(first) + ms / 60000 * 165 * _speed;
            var u = first;
            while (u + 1 < first + count && _wordsAt(u + 1) <= target) {
              u++;
            }
            _moveTo(u);
          case 'speed':
            final now = _speed;
            final next = speedPresets.firstWhere((p) => p > now + 0.001, orElse: () => speedPresets.first);
            _prefs.setSpeed(next, book: bookId);
            _prefs.save();
            if (playing) unawaited(player.play(unit));
            _updateCard();
          case 'save':
            unawaited(_saveLine());
        }
    }
  }

  /// Next (+1) or previous (-1), by what the reader chose: a sentence, 30
  /// seconds or a chapter.
  void _skip(int dir) {
    if (layout.isEmpty) return;
    final to = skipTarget(layout, unit, dir, _prefs.skipBy, _speed, _parkedAt == null ? player.heard : Duration.zero);
    if (to != null) {
      _moveTo(to);
    } else if (dir > 0) {
      _moveTo(_chapterStart(layout.chapterOfUnit(unit) + 1));
    } else {
      final (first, _) = layout.chapterRange(layout.chapterOfUnit(unit));
      _moveTo(_msFor(_wordsAt(unit) - _wordsAt(first)) > 3000 ? first : _chapterStart(layout.chapterOfUnit(unit) - 1));
    }
  }

  /// The card's Save this line: the sentence being read, kept as a quote
  /// (it did nothing while the book read on in the background).
  Future<void> _saveLine() async {
    if (layout.isEmpty) return;
    final u = unit.clamp(0, layout.units.length - 1);
    try {
      await MarkStore.instance.add(
        bookId: bookId,
        bookTitle: title,
        kind: MarkKind.quote,
        at: cursorOf(layout.units[u]),
        text: layout.units[u].text,
        chapter: layout.chapterTitle(layout.chapterOfUnit(u)),
      );
    } on Object {
      // Nothing to show it on; the reader can save it again.
    }
  }

  int _chapterStart(int chapter) => layout.chapterFirstUnit[chapter.clamp(0, layout.chapters.length - 1)];

  /// The card moved the place: reading carries on there, or, paused, waits
  /// there for Play.
  void _moveTo(int u) {
    if (layout.isEmpty) return;
    final to = u.clamp(0, layout.units.length - 1);
    if (playing) {
      unawaited(player.play(to));
    } else {
      _parkedAt = to;
      _persistNow();
      _updateCard();
    }
  }
}

/// Books asked for from outside the app: Play on the system's resume card
/// (Android 11+) after the app was closed, a headset's Play, a book picked
/// in Android Auto. ReadAloudService answers what it can itself (Play for
/// the reading on the card); for a book to start, it keeps the request and
/// wakes Dart with a `mediaPlay` event, starting the engine at
/// backgroundMain first if the app is not running. Both ways in listen
/// here, and take the request themselves on starting, in case it came
/// before they listened.
class MediaRequests {
  const MediaRequests._();

  static const _svc = SpeechService();
  static StreamSubscription<Map<String, Object?>>? _events;

  /// Listen for requests; [library] opens the library when one comes.
  static void listen(Future<LibraryStore> Function() library) {
    // Every player's start is seen (BackgroundReading.claim), so a book's
    // page reading aloud can be found and carried on.
    PlaybackScheduler.beforePlay ??= BackgroundReading.claim;
    unawaited(_events?.cancel());
    _events = SpeechService.events.where((e) => e['type'] == 'mediaPlay').listen((_) => unawaited(take(library)));
    unawaited(take(library));
  }

  /// Take the waiting request, if any, and read its book; the card put up
  /// for it goes if it cannot be read.
  static Future<void> take(Future<LibraryStore> Function() library) async {
    final asked = await _svc.takeMediaPlay();
    if (asked == null) return;
    var ok = false;
    try {
      ok = await BackgroundReading.playFromOutside(await library(), asked.book, reading: asked.reading);
    } on Object catch (e) {
      debugPrint('TomeVoice: could not read the book asked for: $e');
    }
    if (!ok) await _svc.mediaPlayFailed();
  }
}
