import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

/// Everything that talks to the platform, plus the decoding that has to happen
/// before the pure-Dart pipeline can be handed anything.
///
/// Shared by the reading screen and the measurement batch so the two cannot
/// drift apart — the batch is only useful if it exercises the same code the
/// user hears.
class SpeechService {
  const SpeechService();

  static const _channel = MethodChannel('tomevoice/tts');

  Future<Map<String, String>> launchArgs() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('launchArgs');
      return {
        for (final e in (raw ?? const {}).entries)
          e.key: e.value?.toString() ?? '',
      };
    } on PlatformException {
      return const {};
    }
  }

  Future<List<Map<String, String>>> engines() async {
    final raw =
        await _channel.invokeListMethod<Map<Object?, Object?>>('listEngines');
    return [
      for (final e in raw ?? const [])
        {
          'name': e['name'] as String? ?? '',
          'label': e['label'] as String? ?? '',
        },
    ];
  }

  Future<List<Map<String, Object?>>> voices(String? engineId) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listVoices',
      {'engineId': engineId},
    );
    return [
      for (final v in raw ?? const [])
        {
          'name': v['name'] as String? ?? '',
          'locale': v['locale'] as String? ?? '',
          'quality': v['quality'] as int? ?? 0,
          'networkRequired': v['networkRequired'] == true,
        },
    ];
  }

  Future<Map<String, Object?>> synthesise({
    required String text,
    String? engineId,
    String? voiceName,
    double rate = 1.0,
    double pitch = 1.0,
  }) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('synthesise', {
      'text': text,
      'engineId': engineId,
      'voiceName': voiceName,
      'rate': rate,
      'pitch': pitch,
    });
    if (raw == null) throw Exception('synthesise returned nothing');
    return raw;
  }

  Future<String?> outputDir() => _channel.invokeMethod<String>('outputDir');

  Future<void> play(String path) =>
      _channel.invokeMethod<void>('play', {'path': path});

  /// Reads the WAV the engine wrote and runs it through the pipeline.
  Future<ProcessedSpeech> process(
    Map<String, Object?> native,
    PipelineSettings settings,
  ) async {
    final raw = WavCodec.decode(
      await File(native['wavPath'] as String).readAsBytes(),
    );
    final decoded = decodeTimings(native, raw.frameCount, settings.text.length);

    final traced = buildStandardPipeline(settings).runTraced(
      SynthesisResult(
        audio: raw,
        wordTimings: decoded.timings.isNotEmpty
            ? decoded.timings
            : estimateTimings(settings.text, raw.frameCount),
        engineId: native['engineId'] as String? ?? 'unknown',
      ),
    );

    return ProcessedSpeech(
      result: traced.result,
      trace: traced.trace,
      rawFrames: raw.frameCount,
      layout: decoded.layout,
      voice: native['voiceName'] as String? ?? 'unknown',
      engine: native['engineId'] as String? ?? 'unknown',
      native: native,
    );
  }

  /// Detects which `onRangeStart` parameter carries the frame position instead
  /// of trusting the documented order.
  ///
  /// The platform documents `(utteranceId, start, end, frame)`, but Google TTS
  /// delivers `(frame, charStart, charEnd)` — matching the engine-side
  /// `SynthesisCallback#rangeStart(markerInFrames, start, end)` it forwards
  /// from. Character offsets are bounded by the text length and frame positions
  /// at 24 kHz are not, so whichever column runs past the text length is the
  /// frame.
  ///
  /// Getting this wrong is not subtle: it put every word at frames 3, 9, 15,
  /// which sent all the injected silence to the front of the buffer where edge
  /// trimming removed it.
  static ({List<WordTiming> timings, String layout}) decodeTimings(
    Map<String, Object?> native,
    int totalFrames,
    int textLength,
  ) {
    final events = [
      for (final e in (native['rangeEvents'] as List? ?? const []))
        (a: (e as Map)['start'] as int, b: e['end'] as int, c: e['frame'] as int),
    ];
    if (events.isEmpty) return (timings: const [], layout: 'none');

    int maxOf(int Function(({int a, int b, int c})) pick) =>
        events.map(pick).reduce((x, y) => x > y ? x : y);

    final overA = maxOf((e) => e.a) > textLength;
    final overB = maxOf((e) => e.b) > textLength;
    final overC = maxOf((e) => e.c) > textLength;

    final String layout;
    int Function(({int a, int b, int c})) frameOf, startOf, endOf;

    if (overA && !overB && !overC) {
      layout = 'frameFirst';
      frameOf = (e) => e.a;
      startOf = (e) => e.b;
      endOf = (e) => e.c;
    } else if (overC && !overA && !overB) {
      layout = 'documented';
      frameOf = (e) => e.c;
      startOf = (e) => e.a;
      endOf = (e) => e.b;
    } else {
      layout = 'ambiguous';
      frameOf = (e) => e.c;
      startOf = (e) => e.a;
      endOf = (e) => e.b;
    }

    return (
      timings: [
        for (var i = 0; i < events.length; i++)
          WordTiming(
            charStart: startOf(events[i]),
            charEnd: endOf(events[i]),
            frameStart: frameOf(events[i]).clamp(0, totalFrames),
            frameEnd:
                (i + 1 < events.length ? frameOf(events[i + 1]) : totalFrames)
                    .clamp(0, totalFrames),
            source: layout == 'ambiguous'
                ? WordTimingSource.estimated
                : WordTimingSource.engineReported,
          ),
      ],
      layout: layout,
    );
  }

  /// Fallback when an engine supplies no timings: spread the duration across
  /// words by character count. Good enough to place gaps, visibly wrong for
  /// highlighting — which is why the source is recorded rather than hidden.
  static List<WordTiming> estimateTimings(String text, int totalFrames) {
    final words = RegExp(r'\S+').allMatches(text).toList();
    if (words.isEmpty) return const [];
    final totalChars =
        words.fold<int>(0, (s, m) => s + (m.end - m.start));

    var cursor = 0;
    return [
      for (final w in words)
        () {
          final frames = (totalFrames * (w.end - w.start) / totalChars).round();
          final t = WordTiming(
            charStart: w.start,
            charEnd: w.end,
            frameStart: cursor,
            frameEnd: (cursor + frames).clamp(0, totalFrames),
            source: WordTimingSource.estimated,
          );
          cursor = t.frameEnd;
          return t;
        }(),
    ];
  }

  /// Language first, then offline, then quality.
  ///
  /// Ranking by quality alone once selected an Arabic voice for English text,
  /// so language match is the primary key rather than a tiebreaker.
  static Map<String, Object?>? pickVoice(
    List<Map<String, Object?>> voices,
    String language,
  ) {
    if (voices.isEmpty) return null;
    final matching = voices
        .where((v) =>
            (v['locale'] as String? ?? '').toLowerCase().startsWith(language))
        .toList();
    final pool = matching.isNotEmpty ? matching : voices;
    final offline = pool.where((v) => v['networkRequired'] != true).toList();
    final ranked = (offline.isNotEmpty ? offline : pool)
      ..sort((a, b) =>
          ((b['quality'] as int?) ?? 0).compareTo((a['quality'] as int?) ?? 0));
    return ranked.first;
  }

  /// Android's `setPitch` is a linear multiplier around 1.0. Semitones are the
  /// perceptually even unit, so the UI speaks semitones and this converts.
  static double semitonesToPitch(double semitones) {
    if (semitones == 0) return 1.0;
    var r = 1.0;
    final x = semitones / 12;
    // 2^x without importing dart:math into the widget layer.
    final whole = x.truncate();
    for (var i = 0; i < whole.abs(); i++) {
      r = whole > 0 ? r * 2 : r / 2;
    }
    return (r * (1 + (x - whole) * 0.6931471805599453)).clamp(0.5, 2.0);
  }
}

class ProcessedSpeech {
  const ProcessedSpeech({
    required this.result,
    required this.trace,
    required this.rawFrames,
    required this.layout,
    required this.voice,
    required this.engine,
    required this.native,
  });

  final SynthesisResult result;
  final List<StageTrace> trace;
  final int rawFrames;
  final String layout;
  final String voice;
  final String engine;
  final Map<String, Object?> native;

  AudioBuffer get audio => result.audio;
  List<WordTiming> get timings => result.wordTimings;

  Map<String, Object?> toJson(String text, PipelineSettings s) => {
        'engineId': engine,
        'voiceName': voice,
        'deviceModel': native['deviceModel'],
        'androidVersion': native['androidVersion'],
        'text': text,
        'settings': {
          'gapMs': s.wordGapMs,
          'speedScale': s.speedScale,
          'sentencePauseMs': s.sentencePauseMs,
          'commaMs': s.punctuation.commaMs,
          'clauseMs': s.punctuation.clauseMs,
          'pitchSemitones': s.pitchSemitones,
        },
        'rangeStartFired': native['rangeStartFired'],
        'granularity': native['granularity'],
        'rangeEvents': native['rangeEvents'],
        'timingSource':
            timings.isEmpty ? 'none' : timings.first.source.name,
        'eventLayout': layout,
        'sampleRate': audio.sampleRate,
        'rawFrameCount': rawFrames,
        'processedFrameCount': audio.frameCount,
        'stages': [
          for (final t in trace)
            {'name': t.stageName, 'in': t.framesIn, 'out': t.framesOut},
        ],
        'reportedTimings': [
          for (final t in timings)
            {
              'charStart': t.charStart,
              'charEnd': t.charEnd,
              'frameStart': t.frameStart,
              'frameEnd': t.frameEnd,
            },
        ],
      };
}
