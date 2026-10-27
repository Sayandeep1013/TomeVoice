import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'listen_sheet.dart';
import 'prefs.dart';
import 'reading_rules.dart';
import 'scheduler.dart';
import 'speech_service.dart';
import 'stats.dart';
import 'voices.dart';
import 'web_reader.dart';

/// The scheduler that reads [layout] of book [bookId] aloud, as the reader
/// sets one up: its voice (and dialogue voice), speed, pronunciation fixes
/// and pauses. One place, so a book read on after its page is closed sounds
/// as it did on it.
PlaybackScheduler readingScheduler({
  required ReadingLayout layout,
  required ListeningPrefs Function() prefs,
  required String language,
  required String bookId,
  SpeechService service = const SpeechService(),
}) {
  ListenController listen() =>
      ListenController(prefs: prefs(), language: language, bookId: bookId, onChanged: ({required bool restart}) {});

  int pauseAfter(int i) {
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
    if (u < 0 || u >= layout.units.length) return false;
    final text = layout.items[layout.unitItem[u]].block?.text ?? '';
    final before = text.substring(0, layout.unitOffset[u].clamp(0, text.length));
    final straight = '"'.allMatches(before).length;
    final opens = RegExp('[“«「]').allMatches(before).length;
    final closes = RegExp('[”»」]').allMatches(before).length;
    return straight.isOdd || opens > closes;
  }

  return PlaybackScheduler(
    service: service,
    units: layout.units,
    settingsFor: (text) => prefs().settings.copyWith(text: text),
    engineIdOf: () => prefs().engineId ?? VoiceCatalog.instance.engineId,
    voiceNameOf: () => listen().voiceName,
    pauseAfter: pauseAfter,
    respell: (text) => respell(text, ReadingRules.instance.sayFor(bookId)),
    dialogueVoiceOf: () => listen().dialogueVoice,
    quoteOpenAt: quoteOpenAt,
  );
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
class BackgroundReading {
  BackgroundReading._({
    required this.player,
    required this.layout,
    required this.store,
    required this.bookId,
    required this.title,
    required this.cover,
    required this.language,
    required this.web,
    required DateTime? sleepAt,
    required int sleepChapter,
    required SleepChoice sleep,
  })  : _sleepAt = sleepAt,
        _sleepChapter = sleepChapter,
        _sleep = sleep;

  /// The book read on in the background, if any; the library's player
  /// listens here.
  static final current = ValueNotifier<BackgroundReading?>(null);

  PlaybackScheduler player;
  ReadingLayout layout;
  final LibraryStore store;
  final String bookId;
  final String title;
  final String? cover;
  final String language;

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
  bool _resumeOnFocus = false;

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

  /// Take over [player], reading [layout] of [bookId], from a reader whose
  /// page is closing.
  static void adopt({
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
      sleepAt: sleepAt,
      sleepChapter: sleepChapter,
      sleep: sleep,
    );
    b._attach();
    b._events = SpeechService.events.listen(b._onEvent);
    b._statsTimer = Timer.periodic(const Duration(seconds: 15), (_) => b._countTime());
    final at = sleepAt;
    if (at != null) {
      b._sleepTimer = Timer(at.difference(DateTime.now()), b.pause);
    }
    if (web) {
      unawaited(store.webNovel(bookId).then((info) => b._webTotal = info?.chapters.length ?? 0));
    }
    current.value = b;
    b._updateCard();
  }

  /// The player is about to read something else: whatever plays in the
  /// background stops first (two players cannot share the one stream).
  static void claim(PlaybackScheduler? next) {
    final b = current.value;
    if (b != null && !identical(b.player, next)) unawaited(b.stop());
  }

  void _attach() {
    _lastUnit = player.unit.value;
    player.unit.addListener(_onUnit);
    player.state.addListener(_onState);
    player.onFinished = () => unawaited(_onFinished());
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
    final same = readerLayout.units.length == layout.units.length &&
        (layout.units.isEmpty ||
            (readerLayout.units.first.text == layout.units.first.text &&
                readerLayout.units.last.text == layout.units.last.text));
    if (!same || _parkedAt != null) return null;
    _persistNow();
    _release();
    return (player: player, sleepAt: _sleepAt, sleepChapter: _sleepChapter, sleep: _sleep);
  }

  /// Where this reading is, as a sentence of [other] (another layout of the
  /// same book).
  int unitIn(ReadingLayout other) {
    if (layout.isEmpty || other.isEmpty) return 0;
    return other.unitForCursor(cursorOf(layout.units[unit.clamp(0, layout.units.length - 1)]));
  }

  Future<void> pause() async {
    await player.pause();
    _updateCard();
  }

  Future<void> resume() async {
    final parked = _parkedAt;
    _parkedAt = null;
    if (parked != null) {
      await player.play(parked);
    } else if (player.state.value == PlayState.paused) {
      await player.resume();
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
    await player.stop();
    player.dispose();
    await _svc.session(active: false);
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
    if (web) _fetchAhead(u);
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1500), _persistNow);
    _updateCard();
  }

  void _onState() {
    if (player.state.value != PlayState.idle) _parkedAt = null;
    playingNow.value = playing;
    _updateCard();
  }

  /// The end of what is here: a web novel's next chapters are fetched and
  /// read on into; a book has ended.
  Future<void> _onFinished() async {
    if (!web || layout.isEmpty) {
      await stop();
      return;
    }
    final last = layout.units.last.sectionIndex;
    try {
      await fetchChapters(store, bookId, last + 1);
      final next = await store.loadLayout(bookId);
      if (!identical(current.value, this)) return;
      final start = next.units.indexWhere((u) => u.sectionIndex > last);
      if (start < 0) {
        await stop();
        return;
      }
      _detach();
      player.dispose();
      layout = next;
      player = readingScheduler(layout: next, prefs: () => _prefs, language: language, bookId: bookId);
      _attach();
      await player.play(start);
    } on Object {
      await stop();
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

  int _wordsAt(int u) => u < layout.units.length ? layout.wordsBefore[u] : layout.totalWords;
  int _msFor(int words) => (words / (165 * _prefs.settings.speedScale) * 60000).round();

  void _updateCard() {
    if (!identical(current.value, this) || layout.isEmpty) return;
    final s = player.state.value;
    final u = unit.clamp(0, layout.units.length - 1);
    final chapter = layout.chapterOfUnit(u);
    final (first, count) = layout.chapterRange(chapter);
    unawaited(_svc.session(
      active: true,
      title: title,
      subtitle: layout.chapterTitle(chapter),
      playing: s == PlayState.playing || s == PlayState.loading,
      cover: cover,
      positionMs: _msFor(_wordsAt(u) - _wordsAt(first)),
      durationMs: _msFor(_wordsAt(first + count) - _wordsAt(first)),
      speed: _prefs.settings.speedScale,
    ));
  }

  /// The card's buttons, a headset's, and the phone's audio.
  void _onEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'noisy':
      case 'focusLoss':
        unawaited(pause());
      case 'focusLossTransient':
        if (playing) {
          _resumeOnFocus = true;
          unawaited(pause());
        }
      case 'focusGain':
        if (_resumeOnFocus && player.state.value == PlayState.paused) unawaited(resume());
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
            _moveTo(_chapterStart(layout.chapterOfUnit(unit) + 1));
          case 'prev':
            final (first, _) = layout.chapterRange(layout.chapterOfUnit(unit));
            _moveTo(_msFor(_wordsAt(unit) - _wordsAt(first)) > 3000
                ? first
                : _chapterStart(layout.chapterOfUnit(unit) - 1));
          case 'seek':
            final (first, count) = layout.chapterRange(layout.chapterOfUnit(unit));
            final ms = (e['value'] as num?)?.toInt() ?? 0;
            final target = _wordsAt(first) + ms / 60000 * 165 * _prefs.settings.speedScale;
            var u = first;
            while (u + 1 < first + count && _wordsAt(u + 1) <= target) {
              u++;
            }
            _moveTo(u);
          case 'speed':
            final now = _prefs.settings.speedScale;
            final next = speedPresets.firstWhere((p) => p > now + 0.001, orElse: () => speedPresets.first);
            _prefs.settings = _prefs.settings.copyWith(speedScale: next);
            _prefs.save();
            if (playing) unawaited(player.play(unit));
            _updateCard();
        }
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
