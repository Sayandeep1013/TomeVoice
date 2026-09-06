import 'dart:io';
import 'dart:typed_data';

import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'speech_service.dart';

/// Sequential sentence playback with one-sentence lookahead.
///
/// System TTS is fast enough that depth 1 covers gaps between sentences.
/// Neural engines (Phase 3) will raise this from measured RTF. Invalidating
/// controls flush n+1 and let the current sentence finish — docs/02 §2.7.
class PlaybackScheduler {
  PlaybackScheduler({
    required this.service,
    required this.units,
    required this.settingsFor,
    required this.engineIdOf,
    required this.voiceNameOf,
    required this.speedViaEngineOf,
    required this.onUnit,
    required this.onTimings,
    required this.onWord,
    required this.onStatus,
    required this.onFinished,
  });

  final SpeechService service;
  final List<Speakable> units;
  final PipelineSettings Function(String text) settingsFor;
  final String? Function() engineIdOf;
  final String? Function() voiceNameOf;
  final bool Function() speedViaEngineOf;
  final void Function(int index, Speakable unit) onUnit;
  final void Function(List<WordTiming> timings) onTimings;
  final void Function(int wordIndex) onWord;
  final void Function(String status) onStatus;
  final void Function() onFinished;

  bool _running = false;
  bool _stop = false;
  int _index = 0;
  Future<ProcessedSpeech>? _lookahead;
  int _lookaheadIndex = -1;

  bool get running => _running;
  int get index => _index;

  Future<void> start(int from) async {
    if (units.isEmpty) return;
    await stop();
    _stop = false;
    _running = true;
    _index = from.clamp(0, units.length - 1);
    try {
      while (!_stop && _index < units.length) {
        final i = _index;
        final unit = units[i];
        onUnit(i, unit);
        onStatus('Synthesising');

        final current = (_lookaheadIndex == i && _lookahead != null)
            ? _lookahead!
            : _process(unit);
        _lookahead = null;
        _lookaheadIndex = -1;

        if (i + 1 < units.length && !_stop) {
          _lookaheadIndex = i + 1;
          _lookahead = _process(units[i + 1]);
        }

        final run = await current;
        if (_stop) break;

        onTimings(run.timings);
        onStatus('');
        await _play(run, _gapAfter(unit, i));
        if (_stop) break;
        _index = i + 1;
      }
    } finally {
      _running = false;
      _lookahead = null;
      onWord(-1);
      if (!_stop) onFinished();
    }
  }

  /// Drop buffered audio after the current sentence. Call when voice/rate/gap
  /// change so the new settings are audible at sentence n+1.
  void invalidateLookahead() {
    _lookahead = null;
    _lookaheadIndex = -1;
  }

  Future<void> stop() async {
    _stop = true;
    _lookahead = null;
    _lookaheadIndex = -1;
    try {
      await service.stopPlayback();
    } on Object {
      // Platform may not be ready in widget tests.
    }
    _running = false;
  }

  Future<ProcessedSpeech> _process(Speakable unit) async {
    final native = await service.synthesise(
      text: unit.text,
      engineId: engineIdOf(),
      voiceName: voiceNameOf(),
      rate: speedViaEngineOf() ? settingsFor(unit.text).speedScale : 1.0,
      pitch: SpeechService.semitonesToPitch(
        settingsFor(unit.text).pitchSemitones,
      ),
    );
    final settings = settingsFor(unit.text).copyWith(sentencePauseMs: 0);
    return service.process(native, settings);
  }

  /// Scheduler owns inter-sentence and inter-paragraph silence so the
  /// paragraph slider actually does something. The pipeline still bakes a
  /// trailing sentence pause if we leave it on — that would stack.
  int _gapAfter(Speakable unit, int i) {
    final settings = settingsFor(unit.text);
    if (i + 1 >= units.length) return settings.sentencePauseMs;
    final next = units[i + 1];
    if (next.blockId != unit.blockId) return settings.paragraphPauseMs;
    return settings.sentencePauseMs;
  }

  Future<void> _play(ProcessedSpeech run, int gapMs) async {
    final dir = await service.outputDir();
    if (dir == null) {
      onStatus('No storage');
      return;
    }
    var audio = run.audio;
    if (gapMs > 0) {
      final extra = audio.msToFrames(gapMs);
      final samples = Float32List(audio.frameCount + extra)
        ..setRange(0, audio.frameCount, audio.samples);
      audio = audio.withSamples(samples);
    }
    final path = '$dir/preview.wav';
    await File(path).writeAsBytes(WavCodec.encodePcm16(audio));

    final follow = _followAlong(
      run.timings,
      audio.sampleRate,
      audio.frameCount,
    );
    await service.play(path, wait: true);
    await follow;
  }

  Future<void> _followAlong(
    List<WordTiming> timings,
    int rate,
    int frameCount,
  ) async {
    final started = DateTime.now();
    while (!_stop) {
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final frame = elapsed * rate ~/ 1000;
      if (frame > frameCount) break;
      final i = timings.lastIndexWhere((t) => t.frameStart <= frame);
      onWord(i);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    onWord(-1);
  }
}
