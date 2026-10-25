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

  static const _ahead = Duration(seconds: 10);

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
    _gen++;
    _ticker?.cancel();
    unawaited(service.stopPlayback());
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

  Future<void> _fill(int gen) async {
    var failures = 0;
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
        _next = i + 1;
        failures = 0;
      } on PlatformException catch (e) {
        if (gen != _gen) return;
        if (e.code == 'TTS_STOPPED') return;
        // A line with nothing to say ("* * *") is skipped, not a failure.
        if (e.code == 'EMPTY_TEXT') {
          _next = i + 1;
          continue;
        }
        // One unspeakable line ("* * *") should not end the book.
        failures++;
        _next = i + 1;
        if (failures >= 3) {
          error.value = e.message ?? e.code;
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
