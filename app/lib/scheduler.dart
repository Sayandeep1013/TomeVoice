import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'dialogue.dart';
import 'neural_voices.dart';
import 'reading_rules.dart';
import 'speech_service.dart';

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

class _Chunk {
  _Chunk(this.unit, this.start, this.speechFrames, this.totalFrames, this.timings, this.levels, this.pcm);
  final int unit;

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
    this.fallbackVoiceOf,
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

  /// The phone's own voice for the book's language: what reads on when a
  /// natural voice fails (docs/04 section 4.9), rather than sentences being
  /// skipped and the book stopping.
  final String? Function()? fallbackVoiceOf;

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

  /// The head as last seen moving, and for how many ticks it has not.
  int _lastHead = -1;
  int _stillTicks = 0;

  /// The player was restarted once in this play after it stopped moving.
  bool _restarted = false;

  /// Natural voices that failed in this scheduler: the phone's voice reads
  /// in their place (a natural dialogue voice: the narrator's).
  final _failed = <String>{};

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

  /// Start speaking at [from], discarding anything queued.
  Future<void> play(int from) async {
    if (units.isEmpty) return;
    beforePlay?.call(this);
    final gen = await _reset();
    if (gen != _gen) return;
    _next = from.clamp(0, units.length - 1);
    unit.value = _next;
    word.value = WordMark.none;
    error.value = null;
    _levelDb = null;
    _restarted = false;
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
    state.value = PlayState.paused;
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
    _rewindTimer?.cancel();
    _rewindDue = false;
    error.value = null;
    if ((rewind || long) && _chunks.isNotEmpty) {
      await _rewind();
      return;
    }
    state.value = PlayState.playing;
    _startTicker(gen);
    await service.resumePlayback();
  }

  Future<void> stop() async {
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
    _ticker?.cancel();
    _rewindTimer?.cancel();
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
    _stillTicks = 0;
    await service.cancelSynthesis();
    await service.stopPlayback();
    return gen;
  }

  void _startTicker(int gen) {
    _ticker?.cancel();
    _lastHead = -1;
    _stillTicks = 0;
    _ticker = Timer.periodic(_tickEvery, (_) => _tick(gen));
  }

  static const _tickEvery = Duration(milliseconds: 40);

  /// No polling while nothing moves (paused, finished): the head is still.
  void _stopTicker() {
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
  /// afresh, so it starts at once.
  Future<void> _rewind() async {
    final gen = ++_gen;
    _stopTicker();
    _wake();
    final pos = _position;
    final keep = [for (final c in _chunks) if (c.end > pos) c];
    _chunks.clear();
    _fillDone = false;
    // The sentence being made is dropped; the fill makes it again after
    // what is kept.
    await service.cancelSynthesis();
    await service.stopPlayback();
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

  static const offlineHint = 'The voice needs the internet and could not reach it. Try again, or pick a voice '
      "that works offline (or download this language's voice in the phone's speech settings).";

  /// A natural voice in this sentence failed: the phone's voice reads from
  /// here (a natural dialogue voice gives way to the narrator's), with a
  /// line on screen saying why. False when there is nothing to fall back to.
  bool _fallBack(String? narrator, String? dialogue, Object e) {
    final natural = [
      if (isNeural(narrator) && !_failed.contains(narrator)) narrator!,
      if (isNeural(dialogue) && !_failed.contains(dialogue)) dialogue!,
    ];
    if (natural.isEmpty) return false;
    if (natural.contains(narrator) && fallbackVoiceOf?.call() == null) return false;
    _failed.addAll(natural);
    final name = neuralVoiceFor(natural.first)?.name ?? 'The natural voice';
    debugPrint('TomeVoice: $name failed ($e); reading on in the phone\'s voice');
    notice.value = natural.contains(narrator)
        ? "$name could not speak on this phone, so the phone's own voice reads on."
        : '$name could not speak on this phone, so the narrator reads the dialogue too.';
    return true;
  }

  Future<void> _fill(int gen) async {
    var failures = 0;
    var retries = 0;
    while (gen == _gen) {
      if (_next >= units.length) break;
      final ahead = _queuedEnd - _position;
      if (_chunks.isNotEmpty && ahead > _rate * _ahead.inSeconds) {
        // Full: wait for the head to make room, without polling.
        await (_room ??= Completer<void>()).future;
        continue;
      }
      final i = _next;
      final said = respell?.call(units[i]) ?? Respelled.same(units[i].text);
      final text = said.text;
      // A line with nothing to say ("।।।", "* * *", a lone full stop) is
      // passed over: an online voice could time out on it, and three such
      // lines in a row stopped the book.
      if (!_sayable.hasMatch(text)) {
        _next = i + 1;
        continue;
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
      var narrator = voiceNameOf();
      if (_failed.contains(narrator)) narrator = fallbackVoiceOf?.call() ?? narrator;
      var dialogue = dialogueVoiceOf?.call();
      if (_failed.contains(dialogue) || dialogue == narrator) dialogue = null;
      // A natural voice switched away from (or one that failed) is let go
      // now, before another loads, not minutes later.
      NeuralEngine.instance.keepOnly([
        for (final v in [narrator, dialogue])
          if (neuralVoiceFor(v) case final natural?) natural,
      ]);
      try {
        final r = await makeSentence(
          service: service,
          text: text,
          settings: settingsFor(text),
          open: dialogue == null ? null : quoteOpenAt?.call(i),
          engineId: engineIdOf(),
          narrator: narrator,
          dialogue: dialogue,
          pitchOf: pitchOf,
          pauseAfterMs: () => pauseAfter(i),
          levelDb: _levelDb,
          urgent: urgent,
          stale: () => gen != _gen,
        );
        if (r == null || gen != _gen) return;
        final to = _streamRate ??= r.sampleRate;
        final k = to / r.sampleRate;
        int at(int frame) => (frame * k).round();
        final pcm = to == r.sampleRate ? r.pcm : resamplePcm16(r.pcm, r.sampleRate, to);
        final start = await service.enqueue(pcm, to);
        if (gen != _gen) return;
        _rate = to;
        _levelDb = r.gainDb;
        final timings = [
          for (final t in said.changed ? _onPage(r.timings, said) : r.timings)
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
        _chunks.add(_Chunk(i, start, at(r.speechFrames), to == r.sampleRate ? r.totalFrames : pcm.length ~/ 2, timings,
            r.levels, pcm));
        final took = watch.elapsedMilliseconds;
        _lastMade = (ms: took, speechMs: r.speechFrames * 1000 ~/ r.sampleRate, urgent: urgent);
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
        // A natural voice that cannot speak (a broken download, too little
        // memory, its worker gone): the same sentence again in the phone's
        // voice, not skipped.
        if (_fallBack(narrator, dialogue, e)) continue;
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

  Future<void> _tick(int gen) async {
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
          if (m != null) {
            debugPrint('TomeVoice: the voice ran dry; the last sentence took ${m.ms} ms to make '
                '${m.speechMs} ms of speech${m.urgent ? '' : ' (low priority)'}');
          }
        }
        return;
      }
      if (state.value == PlayState.playing && _stuck(pos)) {
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

      if (state.value == PlayState.loading) state.value = PlayState.playing;
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

  /// Whether the head has stood still at [pos] for [_stallAfter] while
  /// there is audio queued past it.
  bool _stuck(int pos) {
    if (pos != _lastHead) {
      _lastHead = pos;
      _stillTicks = 0;
      return false;
    }
    return ++_stillTicks * _tickEvery.inMilliseconds > _stallAfter.inMilliseconds;
  }

  /// The player stopped while it should be playing: the sentence is queued
  /// again from its start, once; if it stops again, reading ends and says so.
  Future<void> _stalled(int gen) async {
    if (gen != _gen) return;
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
    _reachedEnd = true;
    state.value = PlayState.idle;
    word.value = WordMark.none;
    level.value = 0;
    await service.stopPlayback();
    if (error.value == null) onFinished?.call();
  }
}

/// One sentence as reading aloud makes it: said by [narrator] (words in
/// quotation marks by [dialogue], when the book has a dialogue voice), at
/// the speed and pitch in [settings], then through the pipeline with the
/// reader's word gap, punctuation pauses and loudness, with [pauseAfterMs]
/// of silence after it. The scheduler makes every sentence it reads this
/// way, and saving a book as audio (export_audio.dart) every sentence it
/// writes, so what is saved is what is heard.
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
    settings: s.copyWith(speedScale: 1.0, sentencePauseMs: 0, text: text),
    pauseAfterMs: pauseAfterMs(),
    levelDb: levelDb,
  );
}
