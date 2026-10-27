import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'dialogue.dart';
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
  _Chunk(this.unit, this.start, this.speechFrames, this.totalFrames, this.timings, this.levels);
  final int unit;
  final int start;
  final int speechFrames;
  final int totalFrames;
  final List<WordTiming> timings;
  final Uint8List levels;
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
  });

  final SpeechService service;
  final List<Speakable> units;
  final PipelineSettings Function(String text) settingsFor;
  final String? Function() engineIdOf;
  final String? Function() voiceNameOf;

  /// Silence after unit i (sentence or paragraph pause).
  final int Function(int index) pauseAfter;

  /// The sentence as the voice should say it (the reader's pronunciation
  /// fixes), with the way back to the page's text for the highlight.
  final Respelled Function(String text)? respell;

  /// The voice for words in quotation marks, when not the narrator's.
  final String? Function()? dialogueVoiceOf;

  /// A voice's own pitch in semitones, for the dialogue voice; the
  /// narrator's comes with [settingsFor].
  final double Function(String? voiceName)? pitchOf;

  /// Whether a quotation is open where unit i begins (said on from an
  /// earlier sentence of its paragraph), when that can be told.
  final bool Function(int index)? quoteOpenAt;

  final state = ValueNotifier<PlayState>(PlayState.idle);
  final unit = ValueNotifier<int>(0);
  final word = ValueNotifier<WordMark>(WordMark.none);

  /// How loud the voice is at the playback head, 0 to 1 (the glow behind
  /// the player follows it).
  final level = ValueNotifier<double>(0);

  /// Last error worth showing, cleared on the next play.
  final error = ValueNotifier<String?>(null);

  /// Called when the end of the book has been spoken.
  VoidCallback? onFinished;

  /// Told before any scheduler starts reading (and before a voice sample,
  /// with null): a book read on in the background stops for it, as two
  /// cannot share the one audio stream.
  static void Function(PlaybackScheduler? next)? beforePlay;

  static const _ahead = Duration(seconds: 10);

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

  bool get active => state.value != PlayState.idle;
  bool get isPlaying =>
      state.value == PlayState.playing || state.value == PlayState.loading;

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
    state.value = PlayState.loading;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) => _tick(gen));
    unawaited(_fill(gen));
  }

  Future<void> pause() async {
    if (!active || state.value == PlayState.paused) return;
    state.value = PlayState.paused;
    await service.pausePlayback();
  }

  Future<void> resume() async {
    if (state.value != PlayState.paused) return;
    state.value = PlayState.playing;
    await service.resumePlayback();
  }

  Future<void> stop() async {
    await _reset();
    state.value = PlayState.idle;
    word.value = WordMark.none;
    level.value = 0;
  }

  void dispose() {
    // An idle scheduler (another book's page, never played) leaves the
    // stream alone: a book may be reading in the background.
    final owned = active;
    _gen++;
    _ticker?.cancel();
    if (owned) unawaited(service.stopPlayback());
    state.dispose();
    unit.dispose();
    word.dispose();
    level.dispose();
    error.dispose();
  }

  Future<int> _reset() async {
    final gen = ++_gen;
    _ticker?.cancel();
    _ticker = null;
    _chunks.clear();
    _position = 0;
    _streamRate = null;
    _fillDone = false;
    await service.cancelSynthesis();
    await service.stopPlayback();
    return gen;
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

  /// The voice failed for want of the internet (an online voice): worth
  /// asking again before calling it a failure.
  static bool _offline(PlatformException e) =>
      e.code == 'TTS_TIMEOUT' ||
      (e.code == 'TTS_ERROR' && (e.message?.contains('code -6)') == true || e.message?.contains('code -7)') == true));

  static const offlineHint = 'The voice needs the internet and could not reach it. Try again, or pick a voice '
      "that works offline (or download this language's voice in the phone's speech settings).";

  Future<void> _fill(int gen) async {
    var failures = 0;
    var retries = 0;
    while (gen == _gen) {
      if (_next >= units.length) break;
      final ahead = _queuedEnd - _position;
      if (_chunks.isNotEmpty && ahead > _rate * _ahead.inSeconds) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      final i = _next;
      final said = respell?.call(units[i].text) ?? Respelled.same(units[i].text);
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
      try {
        final s = settingsFor(text);
        final dialogue = dialogueVoiceOf?.call();
        final open = dialogue == null ? null : quoteOpenAt?.call(i);
        // A sentence in the middle of a long quote has no marks of its own.
        final native = dialogue == null || !(open == true || text.contains(RegExp('[“”"«»「」„]')))
            ? await service.synthesise(
                text: text,
                engineId: engineIdOf(),
                voiceName: voiceNameOf(),
                rate: s.speedScale,
                pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
                urgent: urgent,
              )
            : await speakWithDialogue(
                svc: service,
                text: text,
                stale: () => gen != _gen,
                startsInside: open,
                narrator: voiceNameOf(),
                dialogueVoice: dialogue,
                engineId: engineIdOf(),
                rate: s.speedScale,
                pitch: SpeechService.semitonesToPitch(s.pitchSemitones),
                dialoguePitch: SpeechService.semitonesToPitch(pitchOf?.call(dialogue) ?? s.pitchSemitones),
                urgent: urgent,
              );
        if (gen != _gen) {
          // Made for a start that was overtaken: nobody will hear it.
          final wav = native['wavPath'];
          if (wav is String) unawaited(File(wav).delete().catchError((Object _) => File(wav)));
          return;
        }
        final r = await renderInBackground(
          native: native,
          // Speed is the engine's job (real duration change); the DSP stub
          // would pitch-shift. Sentence pause is ours, appended below.
          settings: s.copyWith(speedScale: 1.0, sentencePauseMs: 0, text: text),
          pauseAfterMs: pauseAfter(i),
        );
        if (gen != _gen) return;
        final to = _streamRate ??= r.sampleRate;
        final k = to / r.sampleRate;
        int at(int frame) => (frame * k).round();
        final pcm = to == r.sampleRate ? r.pcm : resamplePcm16(r.pcm, r.sampleRate, to);
        final start = await service.enqueue(pcm, to);
        if (gen != _gen) return;
        _rate = to;
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
            r.levels));
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
      _position = pos;
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
      final mark = w < 0 || rel >= c.speechFrames
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

  Future<void> _finish(int gen) async {
    if (gen != _gen) return;
    _ticker?.cancel();
    _ticker = null;
    state.value = PlayState.idle;
    word.value = WordMark.none;
    level.value = 0;
    await service.stopPlayback();
    if (error.value == null) onFinished?.call();
  }
}
