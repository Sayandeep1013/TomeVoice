import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'dialogue.dart';
import 'eleven_labs.dart';
import 'neural_voices.dart';
import 'reading_rules.dart';
import 'speech_service.dart';
import 'voice_log.dart';

enum PlayState { idle, loading, playing, paused }

/// The word being spoken: unit index plus a character range in that unit's
/// text. `start < 0` means no word (between sentences, or not playing).
@immutable
class WordMark {
  const WordMark(this.unit, this.start, this.end);
  static const none = WordMark(-1, -1, -1);

  final int unit;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is WordMark && other.unit == unit && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(unit, start, end);
}

/// The voices a book's cast gives its characters (cast.dart): who says the
/// words in quotation marks in each sentence, in the voice chosen for them.
abstract interface class SpeakerVoices {
  /// The voice for unit [unit]'s quotations: the one its speaker is given,
  /// or null for the dialogue voice. A Future the first time a stretch of
  /// the book is read for it; at once after.
  FutureOr<String?> voiceAt(int unit);

  /// Every voice the cast reads with now: a natural one stays loaded
  /// between its character's lines.
  Iterable<String> get voices;
}

/// A book's own recorded narration (an EPUB's media overlays), read for the
/// scheduler (narration.dart): the audio that says a sentence, made ready
/// for the player as a voice's sentence is.
abstract interface class BookNarration {
  /// How sentence [unit] is read: [NarrationRole.voiced] for every one
  /// while the book is read in a voice.
  NarrationRole at(int unit);

  /// Sentence [unit] as the narration says it, at [settings]' speed (its
  /// pitch kept) and loudness: no word gap or pause is put into a
  /// recording, and [pauseAfterMs] of silence follows it only where the
  /// recording has no pause of its own after it. [levelDb] as for
  /// [makeSentence]. Null when [stale] says it was overtaken; throws when
  /// the recording could not be read.
  Future<RenderedSpeech?> make(
    int unit, {
    required PipelineSettings settings,
    required int pauseAfterMs,
    double? levelDb,
    bool Function()? stale,
  });
}

class _Chunk {
  _Chunk(this.unit, this.start, this.speechFrames, this.totalFrames, this.timings, this.levels, this.pcm, {this.made});
  final int unit;

  /// How a natural voice made it (null for a recording or the phone's
  /// voice): kept so a change of speed alone can play it faster or slower
  /// at once ([PlaybackScheduler._restretch]).
  final _Made? made;

  /// Where it starts in the stream; it moves when the sentence is queued
  /// again from its start (see [PlaybackScheduler._rewind]).
  int start;
  final int speechFrames;
  final int totalFrames;
  final List<WordTiming> timings;
  final Uint8List levels;

  /// The speech itself, kept while it is queued or heard, so going back to
  /// the start of a sentence needs nothing made again.
  final Uint8List pcm;
  int get end => start + totalFrames;
}

/// A sentence as a natural voice made it, at the stream's rate: its sound,
/// its words' places, the speed it was made at, and [way], everything else
/// about how it was said (voices, pitch, pauses, the words as respelled).
/// A stretched sentence keeps the one it came from, so it is always
/// stretched from what the voice made, never stretched twice.
class _Made {
  const _Made(this.pcm, this.speechFrames, this.totalFrames, this.timings, this.speed, this.way);
  final Uint8List pcm;
  final int speechFrames;
  final int totalFrames;
  final List<WordTiming> timings;
  final double speed;
  final String way;
}

/// How far a change of speed is bridged by stretching what is already made
/// (see [PlaybackScheduler._restretch]): a few steps either way sound
/// close to the voice's own; further (3x to 1x), stretched speech smears,
/// and it is made again as before.
const restretchRange = (low: 0.6, high: 1.7);

/// [restretchAll] on another isolate. A function of its own, so the
/// closure sent there holds [job] alone (one made inside the scheduler
/// carries the scheduler's whole context with it, and fails to send).
Future<List<({Uint8List pcm, Uint8List levels})>> _restretchOff(
  List<({Uint8List pcm, int speechFrames, int silenceFrames, int rate, double ratio})> job,
) =>
    Isolate.run(() => restretchAll(job));

/// [job]'s sentences played [ratio] times as fast, their pitch kept (WSOLA,
/// as for a book's own narration): the speech stretched, the silence after
/// it given its new length. On another isolate: it takes nothing of the
/// scheduler with it.
List<({Uint8List pcm, Uint8List levels})> restretchAll(
  List<({Uint8List pcm, int speechFrames, int silenceFrames, int rate, double ratio})> job,
) =>
    [
      for (final j in job)
        () {
          final data = ByteData.sublistView(j.pcm);
          final n = math.min(j.speechFrames, j.pcm.length ~/ 2);
          final x = Float32List(n);
          for (var i = 0; i < n; i++) {
            x[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
          }
          final y = TimeStretchStage.stretch(x, j.rate, j.ratio);
          final buffer = AudioBuffer(y, j.rate);
          return (
            pcm: WavCodec.pcm16Bytes(buffer, silenceFrames: j.silenceFrames),
            levels: speechLevels(y, j.rate),
          );
        }(),
    ];

/// Streams sentences into the platform player, keeping several seconds of
/// audio queued ahead of what is audible.
///
/// Synthesis stays strictly one sentence at a time (the engine has a single
/// progress listener; see SpeechService.synthesise), but because the player
/// streams, sentence n+1 is already queued behind n when n ends: there is no
/// gap to fill. What is audible is read back from the hardware playback head,
/// so the current sentence and word follow the sound itself rather than a
/// timer started when we asked for playback.
class PlaybackScheduler {
  PlaybackScheduler({
    required this.service,
    required this.units,
    required this.settingsFor,
    required this.engineIdOf,
    required this.voiceNameOf,
    required this.pauseAfter,
    this.respell,
    this.dialogueVoiceOf,
    this.pitchOf,
    this.quoteOpenAt,
    this.quickStart = true,
    this.fallbackVoiceOf,
    this.speakers,
    this.narration,
    this.noVoice,
  });

  final SpeechService service;

  /// The sentences it reads; longer once [readOnInto] adds more after them.
  List<Speakable> units;
  final PipelineSettings Function(String text) settingsFor;
  final String? Function() engineIdOf;
  final String? Function() voiceNameOf;

  /// Silence after unit i (sentence or paragraph pause).
  final int Function(int index) pauseAfter;

  /// The sentence as the voice should say it (its silent marks left out, a
  /// link said as its site, the reader's pronunciation fixes), with the way
  /// back to the page's text for the highlight.
  final Respelled Function(Speakable unit)? respell;

  /// The voice for words in quotation marks, when not the narrator's.
  final String? Function()? dialogueVoiceOf;

  /// A voice's own pitch in semitones, for the dialogue voice; the
  /// narrator's comes with [settingsFor].
  final double Function(String? voiceName)? pitchOf;

  /// Whether a quotation is open where unit i begins (said on from an
  /// earlier sentence of its paragraph), when that can be told.
  final bool Function(int index)? quoteOpenAt;

  /// A start makes the first clause of its first sentence alone, so the
  /// voice is heard sooner (see [firstClauseEnd]): a natural voice, and the
  /// phone's too, whose engine says nothing of a sentence until it has made
  /// all of it (a long one took most of a second before a word was heard,
  /// on every Play, skip and change of speed).
  final bool quickStart;

  /// The phone's own voice for the book's language: what reads on when a
  /// natural voice fails (docs/04 section 4.9), rather than sentences being
  /// skipped and the book stopping.
  final String? Function()? fallbackVoiceOf;

  /// The book's cast: its characters' lines in voices of their own. Null
  /// (or a cast that gives nobody a voice) reads every quotation in the
  /// dialogue voice, exactly as before.
  final SpeakerVoices? speakers;

  /// The book's own recorded narration, when it brings one: chosen, a
  /// sentence it says is played from it (no voice, cast or respelling: the
  /// recording is what it is), one it leaves out among lines it reads is
  /// passed over, and the rest is read by the voice.
  final BookNarration? narration;

  /// Why there is no voice to read this book with ("No Bengali voice…"),
  /// or null: asked before reading starts, so the phone's engine is not
  /// handed text in letters none of its voices can read (Samsung's crashed
  /// on Bengali, again for every sentence, and the phone crawled).
  final String? Function()? noVoice;

  /// The voice for the words in quotation marks in unit [i]: the one the
  /// book's cast gives whoever says them (the narrator's, for a character
  /// read in it), else the dialogue voice. Saving as audio makes each
  /// sentence with this, as reading aloud does.
  Future<String?> quoteVoiceAt(int i) async {
    final dialogue = dialogueVoiceOf?.call();
    final cast = speakers;
    if (cast == null) return dialogue;
    return await cast.voiceAt(i) ?? dialogue;
  }

  final state = ValueNotifier<PlayState>(PlayState.idle);
  final unit = ValueNotifier<int>(0);
  final word = ValueNotifier<WordMark>(WordMark.none);

  /// How loud the voice is at the playback head, 0 to 1 (the glow behind
  /// the player follows it).
  final level = ValueNotifier<double>(0);

  /// Last error worth showing, cleared on the next play.
  final error = ValueNotifier<String?>(null);

  /// Something worth a line on screen while reading goes on: a natural
  /// voice that failed, and the phone's voice reading instead.
  final notice = ValueNotifier<String?>(null);

  /// Called when the end of the book has been spoken.
  VoidCallback? onFinished;

  /// Whether reading stopped because it reached the end (not a stop): until
  /// the next play, so whoever reads on into more (a web novel's next
  /// chapters) can keep the card up meanwhile.
  bool get reachedEnd => _reachedEnd;
  bool _reachedEnd = false;

  /// Told before any scheduler starts reading (and before a voice sample,
  /// with null): a book read on in the background stops for it, as two
  /// cannot share the one audio stream.
  static void Function(PlaybackScheduler? next)? beforePlay;

  /// Told when any scheduler pauses: the library writes the reading places
  /// it keeps in memory then, rather than a few seconds on
  /// (LibraryStore.settlePlaces).
  static void Function()? onPaused;

  static const _ahead = Duration(seconds: 10);

  /// A pause longer than this goes back to the start of the sentence on
  /// resume (docs/05 section 5.8): after a few seconds away, the listener
  /// has lost the thread of a sentence picked up in its middle.
  static const rewindAfter = Duration(seconds: 3);

  /// Pause waits for the word being said to finish, if it ends within this.
  static const _finishWord = Duration(milliseconds: 600);

  /// The playback head standing still this long while it plays means the
  /// player died under us (an audio server restart, a failed write).
  static const _stallAfter = Duration(seconds: 5);

  /// The sleep timer's fade (docs/05 section 5.8).
  static const fadeLength = Duration(seconds: 30);

  static const busyHint = "The phone's audio is taken by something else (a call?). Try again when it ends.";
  static const stalledHint = 'The audio stopped and could not be started again. Press Play to try once more.';

  /// Time to make a character of speech, learnt from the sentences made so
  /// far (null until one is). A heavy voice on a slow phone needs far more
  /// warning than a light one: a fixed 3 s let a long sentence of an HD
  /// voice start too late and run the voice dry (seen on the phone).
  double? _msPerChar;

  /// How long the last sentence took to make, for the log when the voice
  /// runs dry (how a slow phone or voice shows itself).
  ({int ms, int speechMs, bool urgent})? _lastMade;

  int _gen = 0;
  final _chunks = <_Chunk>[];
  int _next = 0;
  int _rate = 24000;

  /// The rate of the audio stream since the last start. A sentence at
  /// another rate (a second voice from another engine) is converted to it:
  /// a new rate would restart the player, dropping what is queued.
  int? _streamRate;
  int _position = 0;
  bool _fillDone = false;
  bool _ticking = false;
  Timer? _ticker;
  bool _tickerOn = false;

  /// The fill loop waits here for room in the queue (woken by the head
  /// moving on, or by any restart): no polling while paused.
  Completer<void>? _room;

  /// The levelling gain the last sentence was given: the next moves on from
  /// it (see renderInBackground). Null starts afresh, as each play does.
  double? _levelDb;

  /// Set [rewindAfter] into a pause: the resume goes back to the sentence's
  /// start. (Timers, not the clock, so tests' fake time runs it too.)
  Timer? _rewindTimer;
  bool _rewindDue = false;

  /// Bumped by every pause and resume: a pause still waiting for its word
  /// to finish is called off by the resume after it.
  int _pauseToken = 0;

  /// The head as last seen moving, and for how long (ms) it has not.
  int _lastHead = -1;
  int _stillMs = 0;

  /// The player was restarted once in this play after it stopped moving.
  bool _restarted = false;

  /// Natural voices that failed in this scheduler: the phone's voice reads
  /// in their place (a natural dialogue voice: the narrator's).
  final _failed = <String>{};

  /// What is queued was made before a change to how sentences are said
  /// (speed, voice, pitch, pauses, a pronunciation): see [remake].
  bool _stale = false;
  Timer? _remakeTimer;

  /// For the voice log (voice_log.dart): when the last change of speed or
  /// voice was asked for; when this start was asked for and what it was,
  /// until it is heard; when the voice last ran dry, until it is heard again.
  DateTime? _changedAt;
  DateTime? _askedAt;
  String _asked = '';
  DateTime? _dryAt;

  /// [SpeechService.streamStops] when this scheduler last started its own
  /// stream: a voice sample (or another reading) played since has taken
  /// the player, and what this one had queued there is gone.
  int _streamAt = -1;

  /// Waiting for audio focus the phone promised later (a call): play goes
  /// on when it comes.
  StreamSubscription<Map<String, Object?>>? _focusWait;
  Timer? _fade;

  bool get active => state.value != PlayState.idle;
  bool get isPlaying =>
      state.value == PlayState.playing || state.value == PlayState.loading;

  /// How much of the sentence being heard has been heard: previous goes
  /// back to its start once it is under way, or to the one before.
  Duration get heard {
    for (final c in _chunks) {
      if (_position >= c.start && _position < c.end) {
        return Duration(milliseconds: (_position - c.start) * 1000 ~/ _rate);
      }
    }
    return Duration.zero;
  }

  /// How long after the last of a run of changes (taps on the speed's − or
  /// +, a slider let go) the voice is made again: once, the way it was left,
  /// not once a tap, each tap cutting off the one before.
  static const remakeAfter = Duration(milliseconds: 300);

  /// How sentences are said has changed (speed, voice, pitch, pauses, a
  /// pronunciation): what is queued was made the old way. Reading, it is made
  /// again from the sentence being heard ([from], if given) once the changes
  /// stop coming; paused, when it resumes (it played on at the old speed
  /// before, as long as ten seconds of it). Idle, the next play makes all
  /// afresh anyway.
  void remake({int Function()? from}) {
    if (!active) return;
    _stale = true;
    // The voice log times the restart from the last change asked for.
    _changedAt = DateTime.now();
    _remakeTimer?.cancel();
    _remakeTimer = Timer(remakeAfter, () {
      _remakeTimer = null;
      if (_stale && isPlaying) unawaited(_remakeFrom(from?.call() ?? unit.value));
    });
  }

  /// After a change, reading: a change of speed alone is heard at once
  /// from what is already made ([_restretch]); anything else is made again.
  Future<void> _remakeFrom(int from) async {
    if (await _restretch(from)) return;
    if (_stale && isPlaying) await play(from);
  }

  /// A change of speed alone, with a natural voice: the sentences already
  /// made, from [from] on, played at the new speed with their pitch kept
  /// ([restretchAll]), from the start of [from], as a remake would; the
  /// voice goes on making the ones after at the new speed itself. A natural
  /// voice took seconds to be heard again after each change of speed (6.2
  /// s on a friend's phone, 25 Nov 2026), while what it had made waited
  /// to be thrown away. False, and nothing changed, when anything but the
  /// speed changed, the voice is the phone's (it is heard again in well
  /// under a second anyway), or the change is too big to stretch well.
  Future<bool> _restretch(int from) async {
    if (state.value != PlayState.playing) return false;
    final at = _chunks.indexWhere((c) => c.unit == from);
    if (at < 0) return false;
    final kept = _chunks.sublist(at);
    if (kept.any((c) => c.made == null)) return false;
    // What each sentence would be made with now.
    final now = <int, ({double speed, String way, bool follows})>{};
    for (final c in kept) {
      if (now.containsKey(c.unit)) continue;
      String? character;
      final cast = speakers;
      if (cast != null) {
        final asked = cast.voiceAt(c.unit);
        if (asked is Future<String?>) return false;
        character = asked;
      }
      final (narrator, _, quoted) = _voicesFor(character);
      if (!isNeural(narrator)) return false;
      final said = (respell?.call(units[c.unit]) ?? Respelled.same(units[c.unit].text)).text;
      final settings = settingsFor(said);
      now[c.unit] = (
        speed: settings.speedScale,
        way: _wayOf(narrator, quoted, said, settings),
        follows: settings.pausesFollowSpeed,
      );
    }
    for (final c in kept) {
      final made = c.made!;
      final want = now[c.unit]!;
      if (made.way != want.way) return false;
      final ratio = want.speed / made.speed;
      if (ratio < restretchRange.low || ratio > restretchRange.high) return false;
    }
    final gen = _gen;
    final watch = Stopwatch()..start();
    final job = [
      for (final c in kept)
        () {
          final made = c.made!;
          final want = now[c.unit]!;
          final ratio = want.speed / made.speed;
          // The silence after it shortened as it would be at the new speed
          // (see [pauseAtSpeed]).
          final scale = want.follows ? pauseScaleAt(want.speed) / pauseScaleAt(made.speed) : 1.0;
          return (
            pcm: made.pcm,
            speechFrames: made.speechFrames,
            silenceFrames: ((made.totalFrames - made.speechFrames) * scale).round(),
            rate: _rate,
            ratio: ratio,
          );
        }(),
    ];
    final List<({Uint8List pcm, Uint8List levels})> out;
    try {
      out = await _restretchOff(job);
    } on Object {
      return false;
    }
    // Overtaken while it was stretched: a skip, a stop, another change.
    if (gen != _gen || !_stale || state.value != PlayState.playing) return false;
    final stretched = <_Chunk, _Chunk>{};
    for (final (k, c) in kept.indexed) {
      final made = c.made!;
      final ratio = job[k].ratio;
      final speechFrames = (made.speechFrames / ratio).round();
      final totalFrames = out[k].pcm.length ~/ 2;
      stretched[c] = _Chunk(
        c.unit,
        c.start,
        speechFrames,
        totalFrames,
        [
          for (final t in made.timings)
            WordTiming(
              charStart: t.charStart,
              charEnd: t.charEnd,
              frameStart: (t.frameStart / ratio).round().clamp(0, speechFrames),
              frameEnd: (t.frameEnd / ratio).round().clamp(0, speechFrames),
              source: t.source,
            ),
        ],
        out[k].levels,
        out[k].pcm,
        made: made,
      );
    }
    // Meanwhile the head may have moved on, and the voice queued more the
    // old way: the sentence [from] must still be there, and what follows it
    // is kept only while it was stretched.
    final start = _chunks.indexWhere((c) => identical(c, kept.first));
    if (start < 0) return false;
    var end = start;
    // A sentence still being made (its first part queued, the rest not
    // yet) is left to be made again whole.
    while (end < _chunks.length && stretched.containsKey(_chunks[end]) && _chunks[end].unit < _next) {
      end++;
    }
    if (end == start) return false;
    _chunks.replaceRange(start, _chunks.length, [for (final c in _chunks.sublist(start, end)) stretched[c]!]);
    _stale = false;
    _changedAt = null;
    VoiceLog.instance.note('restretched', {
      'ms': watch.elapsedMilliseconds,
      'sentences': end - start,
      'ratio': double.parse(job.first.ratio.toStringAsFixed(2)),
    });
    await _rewind(from: start);
    return true;
  }

  /// Whether a [remake] is waiting: for tests.
  @visibleForTesting
  bool get remakeDue => _stale;

  /// Start speaking at [from], discarding anything queued.
  ///
  /// With [reuse] (a move with nothing about the voice changed: Next,
  /// Previous, a sentence tapped), speech already made for [from] and what
  /// follows it is queued again rather than made afresh, so a skip is
  /// heard at once (with a natural voice it was seconds of silence). Not
  /// after a change of speed, voice or pronunciation: that must be made
  /// again.
  Future<void> play(int from, {bool reuse = false}) async {
    if (units.isEmpty) return;
    // For the voice log: what this start was, and when it was asked for.
    final asked = _changedAt != null ? 'a change of speed or voice' : (reuse ? 'a skip' : 'Play');
    final askedAt = _changedAt ?? DateTime.now();
    _changedAt = null;
    // What is queued is not the way it is said now: nothing of it is reused.
    if (reuse && !_stale && state.value == PlayState.playing) {
      final to = from.clamp(0, units.length - 1);
      final at = _chunks.indexWhere((c) => c.unit == to);
      if (at >= 0) {
        error.value = null;
        _restarted = false;
        await _rewind(from: at);
        return;
      }
    }
    beforePlay?.call(this);
    // Made afresh from here, the way it is said now.
    _stale = false;
    _remakeTimer?.cancel();
    _remakeTimer = null;
    final gen = await _reset();
    if (gen != _gen) return;
    _next = from.clamp(0, units.length - 1);
    unit.value = _next;
    word.value = WordMark.none;
    error.value = null;
    _levelDb = null;
    _restarted = false;
    _askedAt = askedAt;
    _asked = asked;
    _dryAt = null;
    if (VoiceLog.instance.on) {
      final voice = voiceNameOf();
      VoiceLog.instance.note('ask', {
        'for': asked,
        'speed': settingsFor(units[_next].text).speedScale,
        'voice': voice ?? '',
        'natural': isNeural(voice),
        'engine': engineIdOf() ?? '',
      });
    }
    final missing = noVoice?.call();
    if (missing != null) {
      VoiceLog.instance.note('error', {'code': 'NO_VOICE', 'message': voiceLogError(missing)});
      error.value = missing;
      state.value = PlayState.idle;
      return;
    }
    state.value = PlayState.loading;
    // The phone's audio first: during a call the answer is "later", and the
    // sentence is made meanwhile and waits, paused, for the call to end
    // (it was once read straight over the call).
    final focus = await service.requestFocus();
    if (gen != _gen) return;
    if (focus == SpeechService.focusFailed) {
      error.value = busyHint;
      state.value = PlayState.idle;
      return;
    }
    if (focus == SpeechService.focusDelayed) {
      await service.pausePlayback();
      if (gen != _gen) return;
      state.value = PlayState.paused;
      _awaitFocus(gen);
    } else if (state.value == PlayState.loading) {
      // (Not if paused while the phone was asked.)
      _startTicker(gen);
    }
    unawaited(_fill(gen));
  }

  /// Pause. The word being said is let finish first when it ends soon
  /// (docs/05 section 5.8: a cut in the middle of a word feels broken);
  /// [now] stops at once (the sleep timer, whose fade has already ended it).
  Future<void> pause({bool now = false}) async {
    if (!active || state.value == PlayState.paused) return;
    final gen = _gen;
    final token = ++_pauseToken;
    VoiceLog.instance.note('pause');
    state.value = PlayState.paused;
    onPaused?.call();
    _rewindDue = false;
    _rewindTimer?.cancel();
    _rewindTimer = Timer(rewindAfter, () => _rewindDue = true);
    _stopTicker();
    if (!now) {
      final end = _wordEnd();
      if (end != null) {
        for (var waited = 0; waited < _finishWord.inMilliseconds; waited += 20) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (token != _pauseToken || gen != _gen) return;
          if (await service.position(raw: true) >= end) break;
        }
        if (token != _pauseToken || gen != _gen) return;
      }
    }
    await service.pausePlayback();
  }

  /// Where the word being heard ends, in the stream (its next word's start,
  /// which an engine puts after the gap between them), if that is soon and
  /// its place is known; null to pause at once.
  int? _wordEnd() {
    if (_chunks.isEmpty) return null;
    final pos = _position;
    for (final c in _chunks) {
      if (pos < c.start || pos >= c.start + c.speechFrames) continue;
      final rel = pos - c.start;
      for (var t = 0; t < c.timings.length; t++) {
        final w = c.timings[t];
        if (w.frameStart > rel) {
          if (!w.source.showsWord) return null;
          final end = c.start + w.frameStart;
          return end - pos <= _rate * _finishWord.inMilliseconds ~/ 1000 ? end : null;
        }
      }
      return null;
    }
    return null;
  }

  /// Carry on. After a pause longer than [rewindAfter], or with [rewind],
  /// it goes back to the start of the sentence being heard.
  Future<void> resume({bool rewind = false}) async {
    if (state.value != PlayState.paused) return;
    // Changed while paused (a faster speed, another voice): made again from
    // the sentence being heard, rather than ten seconds more the old way.
    if (_stale) {
      await play(unit.value);
      return;
    }
    final gen = _gen;
    final long = _rewindDue;
    final focus = await service.requestFocus();
    if (gen != _gen || state.value != PlayState.paused) return;
    if (focus == SpeechService.focusDelayed) {
      _awaitFocus(gen);
      return;
    }
    if (focus == SpeechService.focusFailed) {
      error.value = busyHint;
      return;
    }
    unawaited(_focusWait?.cancel());
    _focusWait = null;
    ++_pauseToken;
    VoiceLog.instance.note('resume');
    _warmNatural();
    _rewindTimer?.cancel();
    _rewindDue = false;
    error.value = null;
    // A voice sample played meanwhile (a voice tried in the sheet, the speed
    // heard): the player's stream is its now, and this one's is gone.
    // Resumed as it was, the head never moved and the sentence came back
    // only when the stall check gave up, five seconds on.
    final lost = _streamAt != SpeechService.streamStops;
    if ((rewind || long || lost) && _chunks.isNotEmpty) {
      await _rewind();
      return;
    }
    state.value = PlayState.playing;
    _startTicker(gen);
    await service.resumePlayback();
  }

  /// A natural voice let go while reading was paused (after three minutes
  /// unused) loaded again at once, while what was made before the pause
  /// plays. Left to the next sentence, the load came on top of making it:
  /// on a slow 32-bit phone that sentence took 20 s for 5 s of speech, and
  /// the voice was silent for ten (a friend's log, 23 Nov 2026).
  void _warmNatural() {
    final narrator = voiceNameOf();
    if (_failed.contains(narrator)) return;
    final natural = neuralVoiceFor(narrator);
    if (natural == null || NeuralEngine.instance.holds(natural)) return;
    unawaited(NeuralEngine.instance.warm(natural, urgent: true));
  }

  Future<void> stop() async {
    if (active) VoiceLog.instance.note('stop');
    _stale = false;
    _changedAt = null;
    _remakeTimer?.cancel();
    _remakeTimer = null;
    await _reset();
    state.value = PlayState.idle;
    word.value = WordMark.none;
    level.value = 0;
  }

  /// Read on into [longer]: [units], with more sentences after them (a web
  /// novel's window of chapters rolled on). What is queued and being made
  /// stays as it is, and the new sentences are made after it into the same
  /// stream, so the voice goes on into them with no gap.
  void readOnInto(List<Speakable> longer) {
    units = longer;
    // Everything there was had been made: making goes on.
    if (_fillDone && active && _next < units.length) {
      _fillDone = false;
      unawaited(_fill(_gen));
    }
  }

  /// Fade the voice out over the [fadeLength] before [at] (the sleep timer):
  /// a voice that stops dead wakes the listener it was meant to let sleep.
  void fadeOutBy(DateTime at) {
    _fade?.cancel();
    void step() {
      final left = at.difference(DateTime.now());
      if (left > fadeLength) {
        _fade = Timer(left - fadeLength, step);
        return;
      }
      final v = (left.inMilliseconds / fadeLength.inMilliseconds).clamp(0.0, 1.0);
      // Level is heard in ratios: a square curve sounds like an even fade.
      unawaited(service.setVolume(v * v));
      _fade = left > Duration.zero ? Timer(const Duration(milliseconds: 500), step) : null;
    }

    step();
  }

  /// The voice back at full volume: the sleep timer fired or was changed.
  void endFade() {
    _fade?.cancel();
    _fade = null;
    unawaited(service.setVolume(1));
  }

  void dispose() {
    // An idle scheduler (another book's page, never played) leaves the
    // stream alone: a book may be reading in the background.
    final owned = active;
    _gen++;
    _wake();
    _stopTicker();
    _rewindTimer?.cancel();
    _remakeTimer?.cancel();
    unawaited(_focusWait?.cancel());
    if (_fade != null) {
      _fade?.cancel();
      unawaited(service.setVolume(1));
    }
    if (owned) unawaited(service.stopPlayback());
    state.dispose();
    unit.dispose();
    word.dispose();
    level.dispose();
    error.dispose();
    notice.dispose();
  }

  Future<int> _reset() async {
    final gen = ++_gen;
    _stopTicker();
    _wake();
    unawaited(_focusWait?.cancel());
    _focusWait = null;
    _chunks.clear();
    _position = 0;
    _streamRate = null;
    _fillDone = false;
    _reachedEnd = false;
    _rewindTimer?.cancel();
    _rewindDue = false;
    _lastHead = -1;
    _stillMs = 0;
    await service.cancelSynthesis();
    await service.stopPlayback();
    _streamAt = SpeechService.streamStops;
    return gen;
  }

  void _startTicker(int gen) {
    _ticker?.cancel();
    _tickerOn = true;
    _lastHead = -1;
    _stillMs = 0;
    _ticker = Timer(_tickEvery, () => _tickOn(gen));
  }

  /// The head asked after, then again after a while: every [_tickEvery]
  /// while the page can be seen (the word lit, the glow), every [_tickAway]
  /// with the screen off or the app away, where only the sentence matters.
  /// Polled every 40 ms throughout, a reading with the screen off woke the
  /// phone 25 times a second for nothing.
  Future<void> _tickOn(int gen) async {
    final every = _away ? _tickAway : _tickEvery;
    await _tick(gen, every);
    if (!_tickerOn || gen != _gen) return;
    _ticker = Timer(_away ? _tickAway : _tickEvery, () => _tickOn(gen));
  }

  static const _tickEvery = Duration(milliseconds: 40);
  static const _tickAway = Duration(milliseconds: 300);

  static bool get _away {
    try {
      final s = SchedulerBinding.instance.lifecycleState;
      return s == AppLifecycleState.paused || s == AppLifecycleState.hidden;
    } on Object {
      // No app around it (a test of the scheduler alone): as if seen.
      return false;
    }
  }

  /// No polling while nothing moves (paused, finished): the head is still.
  void _stopTicker() {
    _tickerOn = false;
    _ticker?.cancel();
    _ticker = null;
  }

  void _wake() {
    final r = _room;
    _room = null;
    r?.complete();
  }

  /// The phone said the audio comes later (a call): play when it does.
  void _awaitFocus(int gen) {
    unawaited(_focusWait?.cancel());
    _focusWait = SpeechService.events.listen((e) {
      if (e['type'] != 'focusGain') return;
      unawaited(_focusWait?.cancel());
      _focusWait = null;
      if (gen == _gen && state.value == PlayState.paused) unawaited(resume());
    });
  }

  /// Back to the start of the sentence being heard, with what is queued
  /// after it. The speech already made is queued again: nothing is made
  /// afresh, so it starts at once. With [from], from that chunk instead
  /// (a skip to a sentence already made, see [play]).
  Future<void> _rewind({int? from}) async {
    final gen = ++_gen;
    _stopTicker();
    _wake();
    final pos = _position;
    final keep = from != null ? _chunks.sublist(from) : [for (final c in _chunks) if (c.end > pos) c];
    _chunks.clear();
    _fillDone = false;
    // The sentence being made is dropped; the fill makes it again after
    // what is kept.
    await service.cancelSynthesis();
    await service.stopPlayback();
    _streamAt = SpeechService.streamStops;
    if (gen != _gen) return;
    _position = 0;
    for (final c in keep) {
      final start = await service.enqueue(c.pcm, _rate);
      if (gen != _gen) return;
      c.start = start;
      _chunks.add(c);
    }
    if (keep.isNotEmpty) {
      _next = keep.last.unit + 1;
      unit.value = keep.first.unit;
    }
    word.value = WordMark.none;
    state.value = keep.isEmpty ? PlayState.loading : PlayState.playing;
    _startTicker(gen);
    unawaited(_fill(gen));
  }

  /// Word positions from the voice, moved onto the page's text.
  static List<WordTiming> _onPage(List<WordTiming> timings, Respelled said) => [
        for (final t in timings)
          WordTiming(
            charStart: said.toOriginal(t.charStart),
            charEnd: said.toOriginal(t.charEnd, end: true),
            frameStart: t.frameStart,
            frameEnd: t.frameEnd,
            source: t.source,
          ),
      ];

  int get _queuedEnd => _chunks.isEmpty ? 0 : _chunks.last.end;

  static final _quoteMark = RegExp('[“”"«»「」„]');

  /// A line with something in it to say: a letter or a digit, in any script.
  static final _sayable = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Whether [text] has something in it to say: a line without ("* * *")
  /// is passed over, read aloud or saved as audio.
  static bool sayable(String text) => _sayable.hasMatch(text);

  /// The voice failed for want of the internet (an online voice): worth
  /// asking again before calling it a failure.
  static bool _offline(PlatformException e) =>
      e.code == 'TTS_TIMEOUT' ||
      (e.code == 'TTS_ERROR' && (e.message?.contains('code -6)') == true || e.message?.contains('code -7)') == true));

  /// [e] is an online voice out of reach (see [_offline]).
  static bool offline(PlatformException e) => _offline(e);

  /// What to tell the reader when the speech engine failed for good, by
  /// Android's error code; null for an error one sentence may have alone.
  static String? engineHint(PlatformException e) {
    if (e.code != 'TTS_ERROR') return null;
    final code = RegExp(r'code (-?\d+)').firstMatch(e.message ?? '')?.group(1);
    return switch (code) {
      '-4' => "The phone's speech engine stopped working on this book (Android error -4). It may have no voice "
          "for the book's language: choose another voice, or another speech engine, under Voice.",
      '-9' => "This voice is not downloaded yet. Download it in the phone's speech settings, or choose another "
          'voice under Voice.',
      _ => null,
    };
  }

  static const timeoutHint = 'The voice did not answer. It may not be installed for this language: choose '
      "another voice, or download the language's voice in the phone's speech settings.";

  static const offlineHint = 'The voice needs the internet and could not reach it. Try again, or pick a voice '
      "that works offline (or download this language's voice in the phone's speech settings).";

  /// A natural voice in this sentence failed: the phone's voice reads from
  /// here (a natural dialogue voice gives way to the narrator's, and a
  /// character's to the dialogue voice), with a line on screen saying why.
  /// False when there is nothing to fall back to.
  bool _fallBack(String? narrator, String? dialogue, Object e, {bool character = false}) {
    // An ElevenLabs voice too: out of credits, offline, a key gone.
    bool gives(String? v) => (isNeural(v) || isEleven(v)) && !_failed.contains(v);
    final natural = [
      if (gives(narrator)) narrator!,
      if (gives(dialogue)) dialogue!,
    ];
    if (natural.isEmpty) return false;
    if (natural.contains(narrator) && fallbackVoiceOf?.call() == null) return false;
    _failed.addAll(natural);
    VoiceLog.instance.note('fallback', {
      'from': natural.first,
      'to': fallbackVoiceOf?.call() ?? '',
      'why': voiceLogError(e),
    });
    final name = neuralVoiceFor(natural.first)?.name ?? ElevenLabs.instance.byVoiceName(natural.first)?.name ?? 'The natural voice';
    debugPrint('TomeVoice: $name failed ($e); reading on in the phone\'s voice');
    // ElevenLabs says why (credits, the key, the network).
    notice.value = e is ElevenError
        ? (natural.contains(narrator)
            ? "${e.message} The phone's own voice reads on."
            : '${e.message} The narrator reads the dialogue.')
        : natural.contains(narrator)
        ? "$name could not speak on this phone, so the phone's own voice reads on."
        : character
            ? "$name could not speak on this phone, so its character's lines are read in the dialogue voice."
            : '$name could not speak on this phone, so the narrator reads the dialogue too.';
    return true;
  }

  Future<void> _fill(int gen) async {
    var failures = 0;
    var retries = 0;
    while (gen == _gen) {
      if (_next >= units.length) break;
      var ahead = _queuedEnd - _position;
      if (_chunks.isNotEmpty && ahead > _rate * _ahead.inSeconds) {
        // Full: wait for the head to make room, without polling.
        await (_room ??= Completer<void>()).future;
        continue;
      }
      final i = _next;
      // The book's own narration: a line it says is played as recorded, one
      // it leaves out among the lines it reads is passed over. A recording
      // that cannot be read here leaves the line to the voice.
      final told = narration?.at(i);
      if (told == NarrationRole.passed) {
        _next = i + 1;
        continue;
      }
      if (told == NarrationRole.recorded) {
        final played = await _narrate(gen, i);
        if (gen != _gen) return;
        if (played) {
          failures = 0;
          retries = 0;
          continue;
        }
      }
      final said = respell?.call(units[i]) ?? Respelled.same(units[i].text);
      final text = said.text;
      // A line with nothing to say ("।।।", "* * *", a lone full stop) is
      // passed over: an online voice could time out on it, and three such
      // lines in a row stopped the book.
      if (!_sayable.hasMatch(text)) {
        _next = i + 1;
        continue;
      }
      // The voice the book's cast gives whoever says this sentence's
      // quotations. Its stretch of the book is read for it once, on
      // another isolate, a chapter ahead; a book with no cast waits for
      // nothing here.
      final cast = speakers;
      String? character;
      if (cast != null) {
        final asked = cast.voiceAt(i);
        if (asked is Future<String?>) {
          character = await asked;
          if (gen != _gen) return;
          ahead = _queuedEnd - _position;
        } else {
          character = asked;
        }
      }
      // Little queued for the time this sentence will take (starting, or
      // the voice catching up): make it at full priority. Well ahead, with
      // twice that to spare and a second and a half more: let the screen
      // go first.
      final perChar = _msPerChar;
      final aheadMs = ahead * 1000 ~/ _rate;
      final urgent = _chunks.isEmpty || perChar == null || aheadMs < text.length * perChar * 2 + 1500;
      final watch = Stopwatch()..start();
      // A natural voice that failed is not asked again: the phone's voice
      // (the narrator's, for dialogue) reads in its place.
      final (narrator, dialogue, quoted) = _voicesFor(character);
      // A natural voice switched away from (or one that failed) is let go
      // now, before another loads, not minutes later. The cast's stay: each
      // is admitted only while the phone holds them all (cast.dart).
      NeuralEngine.instance.keepOnly([
        for (final v in [
          narrator,
          dialogue,
          if (quoted != dialogue) quoted,
          if (cast != null) ...cast.voices.where((v) => !_failed.contains(v)),
        ])
          if (neuralVoiceFor(v) case final natural?) natural,
      ]);
      try {
        final settings = settingsFor(text);
        // Kept with a natural voice's sentence, so a change of speed alone
        // can be heard at once (see [_restretch]).
        final way = isNeural(narrator) ? _wayOf(narrator, quoted, text, settings) : null;
        final open = quoted == null ? null : quoteOpenAt?.call(i);
        // The first sentence of a start: nothing is heard until it is all
        // made (seconds, for a long one with a slow natural voice; most of a
        // second with the phone's). Its first clause is made and queued
        // alone, then the rest.
        final plain = quoted == null || (open != true && !text.contains(_quoteMark));
        final cut = quickStart && _chunks.isEmpty && plain ? firstClauseEnd(text) : -1;
        var headSpeechMs = 0;
        if (cut > 0) {
          final head = await makeSentence(
            service: service,
            text: text.substring(0, cut).trimRight(),
            settings: settings,
            engineId: engineIdOf(),
            narrator: narrator,
            dialogue: null,
            pitchOf: pitchOf,
            pauseAfterMs: () => 0,
            levelDb: _levelDb,
            urgent: true,
            stale: () => gen != _gen,
          );
          if (head == null || gen != _gen) return;
          if (!await _queue(gen, i, head, said.changed ? _onPage(head.timings, said) : head.timings,
              speed: settings.speedScale, way: way)) {
            return;
          }
          headSpeechMs = head.speechFrames * 1000 ~/ head.sampleRate;
          VoiceLog.instance.note('first part made', {'ms': watch.elapsedMilliseconds, 'speechMs': headSpeechMs});
        }
        // With a natural voice, the rest of that first sentence is queued
        // a piece at a time, as each is made, cut at its commas as its
        // first clause is ([clausePieces], pieces of 50 characters or
        // more): the first is heard while the next are made. Made whole,
        // the rest of a long one came seconds after its first clause (a
        // friend's phone, 25 Nov 2026: two seconds of silence there).
        final rest = cut > 0 ? text.substring(cut) : text;
        final parts =
            cut > 0 && isNeural(narrator) ? clausePieces(rest, over: 120, min: 50) : [(start: 0, text: rest)];
        for (final part in parts.take(parts.length - 1)) {
          final piece = await makeSentence(
            service: service,
            text: part.text,
            settings: settings,
            engineId: engineIdOf(),
            narrator: narrator,
            dialogue: null,
            pitchOf: pitchOf,
            pauseAfterMs: () => 0,
            levelDb: _levelDb,
            urgent: true,
            stale: () => gen != _gen,
          );
          if (piece == null || gen != _gen) return;
          final placed = shiftTimings(piece.timings, cut + part.start);
          if (!await _queue(gen, i, piece, said.changed ? _onPage(placed, said) : placed,
              speed: settings.speedScale, way: way)) {
            return;
          }
          headSpeechMs += piece.speechFrames * 1000 ~/ piece.sampleRate;
        }
        final last = parts.last;
        final r = await makeSentence(
          service: service,
          text: last.text,
          settings: settings,
          open: cut > 0 ? null : open,
          engineId: engineIdOf(),
          narrator: narrator,
          dialogue: cut > 0 ? null : quoted,
          pitchOf: pitchOf,
          pauseAfterMs: () => pauseAfter(i),
          levelDb: _levelDb,
          urgent: urgent || cut > 0,
          stale: () => gen != _gen,
        );
        if (r == null || gen != _gen) return;
        // The rest's words, placed in the whole sentence.
        final timings = cut > 0 ? shiftTimings(r.timings, cut + last.start) : r.timings;
        if (!await _queue(gen, i, r, said.changed ? _onPage(timings, said) : timings,
            speed: settings.speedScale, way: way)) {
          return;
        }
        final took = watch.elapsedMilliseconds;
        _lastMade = (ms: took, speechMs: r.speechFrames * 1000 ~/ r.sampleRate, urgent: urgent);
        if (VoiceLog.instance.on) {
          VoiceLog.instance.note('made', {
            'chars': text.length,
            'script': scriptOf(text),
            'ms': took,
            'speechMs': headSpeechMs + r.speechFrames * 1000 ~/ r.sampleRate,
            'speed': settings.speedScale,
            'voice': narrator ?? '',
            if (quoted != null) 'quotesVoice': quoted,
            if (cut > 0) 'inTwo': true,
            if (!urgent) 'early': true,
          });
        }
        if (text.length >= 20) {
          final per = took / text.length;
          // The slower of what was learnt and this one leads, so a slow
          // stretch is answered at once and forgotten gradually.
          _msPerChar = perChar == null || per > perChar ? per : perChar * 0.8 + per * 0.2;
        }
        _next = i + 1;
        failures = 0;
        retries = 0;
      } on PlatformException catch (e) {
        if (gen != _gen) return;
        if (e.code == 'TTS_STOPPED') return;
        // A line with nothing to say ("* * *") is skipped, not a failure.
        if (e.code == 'EMPTY_TEXT') {
          _next = i + 1;
          continue;
        }
        VoiceLog.instance.note('error', {
          'code': e.code,
          'message': voiceLogError(e.message),
          'voice': narrator ?? '',
          'script': scriptOf(text),
        });
        // No answer from the voice in 30 s: asked again, it is 30 s more of
        // silence each time (a voice the engine lists but cannot speak, as
        // a Bengali voice never downloaded). Reading stops at once, saying so.
        if (e.code == 'TTS_TIMEOUT') {
          error.value = timeoutHint;
          break;
        }
        // The engine itself failed (its service crashed: Android's -4), or
        // the voice is not downloaded (-9): every sentence would fail the
        // same way, each time restarting the engine. Stopped at once.
        if (engineHint(e) case final hint?) {
          error.value = hint;
          break;
        }
        // An online voice out of reach: the same sentence again, after a
        // breath, twice, before it counts.
        final offline = _offline(e);
        if (offline && retries < 2) {
          retries++;
          await Future<void>.delayed(Duration(milliseconds: 700 * retries));
          continue;
        }
        retries = 0;
        // One unspeakable line ("* * *") should not end the book.
        failures++;
        _next = i + 1;
        if (failures >= 3) {
          error.value = offline ? offlineHint : e.message ?? e.code;
          break;
        }
      } on Object catch (e) {
        if (gen != _gen) return;
        VoiceLog.instance.note('error', {
          'code': e.runtimeType.toString(),
          'message': voiceLogError(e),
          'voice': narrator ?? '',
          'script': scriptOf(text),
        });
        // A natural voice that cannot speak (a broken download, too little
        // memory, its worker gone): the same sentence again in the phone's
        // voice, not skipped.
        // ElevenLabs busy (too many at once): the same sentence again, after
        // a breath, twice, before it counts.
        if (e is ElevenError && e.status == 429 && retries < 2) {
          retries++;
          await Future<void>.delayed(Duration(milliseconds: 900 * retries));
          continue;
        }
        retries = 0;
        // An ElevenLabs voice that cannot speak goes the way of a natural one.
        if (_fallBack(narrator, quoted, e, character: quoted != dialogue)) continue;
        failures++;
        _next = i + 1;
        if (failures >= 3) {
          error.value = '$e';
          break;
        }
      }
    }
    if (gen == _gen) _fillDone = true;
  }

  /// [r], sentence [i] made, queued after what is queued (at the stream's
  /// rate, which a sentence at another rate is brought to), with [timings]
  /// on the page's text. False when it was overtaken meanwhile.
  /// Who says a sentence: the narrator (the phone's voice in place of a
  /// natural one that failed), the dialogue voice (none when it is the
  /// narrator's), and who says its quotations: the character's own voice
  /// (none, for one read in the narrator's), else the dialogue voice.
  (String?, String?, String?) _voicesFor(String? character) {
    var narrator = voiceNameOf();
    if (_failed.contains(narrator)) narrator = fallbackVoiceOf?.call() ?? narrator;
    var dialogue = dialogueVoiceOf?.call();
    if (_failed.contains(dialogue) || dialogue == narrator) dialogue = null;
    var quoted = dialogue;
    if (character != null && !_failed.contains(character)) quoted = character == narrator ? null : character;
    return (narrator, dialogue, quoted);
  }

  /// Everything about how [said] is said but its speed: the engine, the
  /// voices and their pitches, the words as respelled, the pauses and the
  /// loudness. Two sentences of the same [way] differ only in speed.
  String _wayOf(String? narrator, String? quoted, String said, PipelineSettings s) {
    final p = s.punctuation;
    return [
      engineIdOf(),
      narrator,
      quoted,
      pitchOf?.call(narrator),
      pitchOf?.call(quoted),
      identityHashCode(speakers),
      s.pitchSemitones,
      s.wordGapMs,
      s.sentencePauseMs,
      s.paragraphPauseMs,
      s.crossfadeMs,
      s.snapSearchMs,
      s.trimEdges,
      s.trimDb,
      s.volume,
      s.normaliseLoudness,
      s.compression,
      s.pausesFollowSpeed,
      p.topUp,
      p.commaMs,
      p.clauseMs,
      p.colonMs,
      p.dashMs,
      p.ellipsisMs,
      p.quoteMs,
      said,
    ].join('\u0001');
  }

  Future<bool> _queue(int gen, int i, RenderedSpeech r, List<WordTiming> timings, {double? speed, String? way}) async {
    final to = _streamRate ??= r.sampleRate;
    final k = to / r.sampleRate;
    int at(int frame) => (frame * k).round();
    final pcm = to == r.sampleRate ? r.pcm : resamplePcm16(r.pcm, r.sampleRate, to);
    final start = await service.enqueue(pcm, to);
    if (gen != _gen) return false;
    _rate = to;
    _levelDb = r.gainDb;
    final speechFrames = at(r.speechFrames);
    final totalFrames = to == r.sampleRate ? r.totalFrames : pcm.length ~/ 2;
    final placed = [
      for (final t in timings)
        to == r.sampleRate
            ? t
            : WordTiming(
                charStart: t.charStart,
                charEnd: t.charEnd,
                frameStart: at(t.frameStart),
                frameEnd: at(t.frameEnd),
                source: t.source,
              ),
    ];
    _chunks.add(_Chunk(
      i,
      start,
      speechFrames,
      totalFrames,
      placed,
      r.levels,
      pcm,
      made: speed == null || way == null ? null : _Made(pcm, speechFrames, totalFrames, placed, speed, way),
    ));
    return true;
  }

  /// Sentence [i] from the book's own narration, queued (or passed over,
  /// when its clip holds no sound). False when its recording could not be
  /// read: the voice reads it instead, and says so once.
  Future<bool> _narrate(int gen, int i) async {
    // A natural voice switched from is let go: the recording needs none.
    NeuralEngine.instance.keepOnly(const []);
    try {
      final settings = settingsFor(units[i].text);
      final r = await narration!.make(
        i,
        settings: settings,
        pauseAfterMs: pauseAtSpeed(pauseAfter(i), settings),
        levelDb: _levelDb,
        stale: () => gen != _gen,
      );
      if (gen != _gen) return true;
      if (r != null && r.totalFrames > 0 && !await _queue(gen, i, r, r.timings)) return true;
      _next = i + 1;
      return true;
    } on Object catch (e) {
      if (gen != _gen) return true;
      debugPrint('TomeVoice: the narration of sentence $i could not be played ($e); the voice reads it');
      notice.value ??= "Part of the book's own narration could not be played on this phone, so the voice reads it.";
      return false;
    }
  }

  Future<void> _tick(int gen, [Duration every = _tickEvery]) async {
    if (_ticking || gen != _gen) return;
    _ticking = true;
    try {
      final pos = await service.position();
      if (gen != _gen) return;
      if (pos < 0) {
        // The player reported its writer failed.
        await _stalled(gen);
        return;
      }
      _position = pos;
      if (_room != null && _queuedEnd - pos <= _rate * _ahead.inSeconds) _wake();
      if (_chunks.isEmpty) {
        if (_fillDone) await _finish(gen);
        return;
      }
      if (pos >= _queuedEnd) {
        level.value = 0;
        if (_fillDone) {
          await _finish(gen);
        } else if (state.value == PlayState.playing) {
          // Ran dry: synthesis is behind. Say so instead of looking frozen.
          state.value = PlayState.loading;
          final m = _lastMade;
          _dryAt = DateTime.now();
          VoiceLog.instance.note('ran dry', {if (m != null) 'lastMadeMs': m.ms, if (m != null) 'lastSpeechMs': m.speechMs});
          if (m != null && m.urgent && m.ms > m.speechMs) _fellBehind();
          if (m != null) {
            debugPrint('TomeVoice: the voice ran dry; the last sentence took ${m.ms} ms to make '
                '${m.speechMs} ms of speech${m.urgent ? '' : ' (low priority)'}');
          }
        }
        return;
      }
      if (state.value == PlayState.playing && _stuck(pos, every)) {
        await _stalled(gen);
        return;
      }

      var k = _chunks.length - 1;
      while (k > 0 && _chunks[k].start > pos) {
        k--;
      }
      final c = _chunks[k];
      // Drop what has been played, keep the current chunk.
      if (k > 0) _chunks.removeRange(0, k);

      if (state.value == PlayState.loading) {
        state.value = PlayState.playing;
        _heard();
      }
      if (unit.value != c.unit) unit.value = c.unit;

      final rel = pos - c.start;
      var w = -1;
      for (var t = 0; t < c.timings.length; t++) {
        if (c.timings[t].frameStart <= rel) {
          w = t;
        } else {
          break;
        }
      }
      // A word whose place was only guessed is not highlighted: the
      // sentence is, which is honest (docs/05 section 5.9).
      final mark = w < 0 || rel >= c.speechFrames || !c.timings[w].source.showsWord
          ? WordMark.none
          : WordMark(c.unit, c.timings[w].charStart, c.timings[w].charEnd);
      if (word.value != mark) word.value = mark;
      final at = rel * 1000 ~/ (_rate * speechLevelMs);
      level.value = at >= 0 && at < c.levels.length ? c.levels[at] / 255 : 0;
    } on Object {
      // A missed tick is invisible; the next one catches up.
    } finally {
      _ticking = false;
    }
  }

  /// How often a natural voice ran dry at each speed for making speech
  /// slower than it is said, and the speeds the reader was told of.
  final _behind = <double, int>{};
  final _toldBehind = <double>{};

  /// A natural voice ran dry, its last sentence slower to make than to
  /// say: the second time at a speed, the reader is told once why there
  /// are gaps, and what reads without them. Before, the voice only stopped
  /// and started (a friend's phone at 3x, 25 Nov 2026).
  void _fellBehind() {
    final narrator = voiceNameOf();
    if (!isNeural(narrator) || _failed.contains(narrator) || units.isEmpty) return;
    final speed = settingsFor(units[unit.value.clamp(0, units.length - 1)].text).speedScale;
    final times = _behind[speed] = (_behind[speed] ?? 0) + 1;
    if (times < 2 || !_toldBehind.add(speed)) return;
    final name = neuralVoiceFor(narrator)?.name ?? 'The natural voice';
    notice.value = speed > 1
        ? "$name can't keep up at ${speedLabel(speed)} on this phone, so there are gaps. "
            "A slower speed, or the phone's own voice, reads without them."
        : "$name is slower than speech on this phone, so there are gaps. "
            "The phone's own voice, or a lighter natural voice, reads without them.";
  }

  /// The voice is heard (seen at the tick after the player moved on): for
  /// the voice log, how long after it was asked for, or how long it was dry.
  void _heard() {
    final now = DateTime.now();
    final asked = _askedAt;
    final dry = _dryAt;
    _askedAt = null;
    _dryAt = null;
    if (asked != null) {
      VoiceLog.instance.note('sound', {'after': _asked, 'ms': now.difference(asked).inMilliseconds});
    } else if (dry != null) {
      VoiceLog.instance.note('gap', {'ms': now.difference(dry).inMilliseconds});
    }
  }

  /// Whether the head has stood still at [pos] for [_stallAfter] while
  /// there is audio queued past it.
  bool _stuck(int pos, Duration every) {
    if (pos != _lastHead) {
      _lastHead = pos;
      _stillMs = 0;
      return false;
    }
    _stillMs += every.inMilliseconds;
    return _stillMs > _stallAfter.inMilliseconds;
  }

  /// The player stopped while it should be playing: the sentence is queued
  /// again from its start, once; if it stops again, reading ends and says so.
  Future<void> _stalled(int gen) async {
    if (gen != _gen) return;
    VoiceLog.instance.note('stall', {'restarted': _restarted});
    if (_stale) {
      // What is queued is the old way: made again, not queued again.
      await play(unit.value);
      return;
    }
    if (!_restarted) {
      _restarted = true;
      debugPrint('TomeVoice: the player stopped moving; starting the sentence again');
      await _rewind();
      return;
    }
    error.value = stalledHint;
    await stop();
  }

  Future<void> _finish(int gen) async {
    if (gen != _gen) return;
    _stopTicker();
    // Only a reading that got to the end reached it: one ended by an error
    // (a voice that would not speak) is not read on into the next chapter,
    // which left the media card saying Playing over a stopped reader.
    _reachedEnd = error.value == null;
    VoiceLog.instance.note(error.value == null ? 'end' : 'stopped on an error');
    state.value = PlayState.idle;
    word.value = WordMark.none;
    level.value = 0;
    await service.stopPlayback();
    if (error.value == null) onFinished?.call();
  }
}

/// Where the first clause of [text] ends (just after its comma, semicolon,
/// colon or dash), for a first sentence made in two parts; -1 when the
/// sentence is short, or has no such mark with enough on both sides.
///
/// A sentence long enough for a natural voice to make in pieces
/// ([clausePieces]) is cut where its first piece ends, so the head is that
/// piece.
int firstClauseEnd(String text, {int minHead = 30, int minTail = 25, int minLength = 70}) {
  if (text.length < minLength) return -1;
  final pieces = clausePieces(text);
  if (pieces.length > 1) return pieces[1].start;
  for (var i = minHead; i < text.length - minTail; i++) {
    final c = text.codeUnitAt(i);
    // , ; : and the en and em dashes.
    if (c == 0x2C || c == 0x3B || c == 0x3A || c == 0x2013 || c == 0x2014) {
      // Not inside a number ("1,000", "10:30").
      final next = text.codeUnitAt(i + 1);
      if (next >= 0x30 && next <= 0x39) continue;
      return i + 1;
    }
  }
  return -1;
}

/// [timings] of a part of a sentence that starts [by] characters in, as
/// places in the whole sentence.
List<WordTiming> shiftTimings(List<WordTiming> timings, int by) => [
      for (final t in timings)
        WordTiming(
          charStart: t.charStart + by,
          charEnd: t.charEnd + by,
          frameStart: t.frameStart,
          frameEnd: t.frameEnd,
          source: t.source,
        ),
    ];

/// How much the silences put into speech are shortened at [speed]: not at
/// all at 1x or slower; above it, by the square root of the speed, so a
/// pause is 82% as long at 1.5x, 71% at 2x and 58% at 3x. Kept as they
/// were, the voice sped up and the 350 ms between its sentences did not:
/// at 2x and over it was heard as the reader lagging. Shortened fully, at
/// 2.5x a sentence pause all but vanished (docs/05 section 5.3).
double pauseScaleAt(double speed) => speed <= 1 ? 1 : 1 / math.sqrt(speed);

/// [ms] of silence as [settings] put it in at their speed (see
/// [pauseScaleAt]), unless pauses are kept as they are set.
int pauseAtSpeed(int ms, PipelineSettings settings) =>
    settings.pausesFollowSpeed ? (ms * pauseScaleAt(settings.speedScale)).round() : ms;

/// [settings] with the silences they put inside a sentence (the word gap,
/// the pauses at punctuation) as long as they are at their speed.
PipelineSettings pausesAtSpeed(PipelineSettings settings) {
  if (!settings.pausesFollowSpeed || settings.speedScale <= 1) return settings;
  int f(int ms) => pauseAtSpeed(ms, settings);
  final p = settings.punctuation;
  return settings.copyWith(
    wordGapMs: f(settings.wordGapMs),
    punctuation: p.copyWith(
      commaMs: f(p.commaMs),
      clauseMs: f(p.clauseMs),
      colonMs: f(p.colonMs),
      dashMs: f(p.dashMs),
      ellipsisMs: f(p.ellipsisMs),
      quoteMs: f(p.quoteMs),
    ),
  );
}

/// One sentence as reading aloud makes it: said by [narrator] (words in
/// quotation marks by [dialogue]: the voice the book's cast gives whoever
/// says them, else the book's dialogue voice, when it has one), at the
/// speed and pitch in [settings] ([pitchOf] gives each voice its own), then
/// through the pipeline with the reader's word gap, punctuation pauses and
/// loudness, with [pauseAfterMs] of silence after it (these silences
/// shortened at a speed over 1x: [pausesAtSpeed]). The scheduler makes
/// every sentence it reads this way, and saving a book as audio
/// (export_audio.dart, with [PlaybackScheduler.quoteVoiceAt]) every
/// sentence it writes, so what is saved is what is heard.
///
/// [settings] are the listening settings for [text]; [open] whether a
/// quotation is already open where the sentence begins, when that is
/// known. [pauseAfterMs] is asked once the speech is made, as it always
/// was. [levelDb] is the levelling gain of the sentence before (see
/// [renderInBackground]). Null when [stale] says the sentence was
/// overtaken while it was made (its file is deleted); the engine's errors
/// are thrown as they come.
Future<RenderedSpeech?> makeSentence({
  required SpeechService service,
  required String text,
  required PipelineSettings settings,
  required String? engineId,
  required String? narrator,
  required String? dialogue,
  required int Function() pauseAfterMs,
  bool? open,
  double Function(String? voiceName)? pitchOf,
  double? levelDb,
  bool urgent = true,
  bool Function()? stale,
}) async {
  final s = settings;
  // A sentence in the middle of a long quote has no marks of its own.
  final native = dialogue == null || !(open == true || text.contains(RegExp('[“”"«»「」„]')))
      ? await service.synthesise(
          text: text,
          engineId: engineId,
          voiceName: narrator,
          rate: s.speedScale,
          pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
          urgent: urgent,
        )
      : await speakWithDialogue(
          svc: service,
          text: text,
          stale: stale,
          startsInside: open,
          narrator: narrator,
          dialogueVoice: dialogue,
          engineId: engineId,
          rate: s.speedScale,
          pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
          dialoguePitch: SpeechService.semitonesToPitch(pitchOf?.call(dialogue) ?? s.pitchSemitones),
          urgent: urgent,
          level: s.normaliseLoudness,
        );
  if (stale?.call() ?? false) {
    // Made for a start that was overtaken: nobody will hear it.
    final wav = native['wavPath'];
    if (wav is String) unawaited(File(wav).delete().catchError((Object _) => File(wav)));
    return null;
  }
  return renderInBackground(
    native: native,
    // Speed is the engine's job (real duration change); the DSP stub
    // would pitch-shift. Sentence pause is ours, appended after it.
    settings: pausesAtSpeed(s).copyWith(speedScale: 1.0, sentencePauseMs: 0, text: text),
    pauseAfterMs: pauseAtSpeed(pauseAfterMs(), s),
    levelDb: levelDb,
  );
}
