// Audio-engine spike: one screen, deliberately unstyled.
//
// The Ojuju "specimen" visual direction (docs/10 ADR-017) begins at Phase 1,
// when there is a real reader to dress. This screen exists to produce numbers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

void main() => runApp(const SpikeApp());

const _channel = MethodChannel('tomevoice/tts');

const _defaultText =
    'The quick brown fox jumps over the lazy dog. '
    'Pack my box with five dozen liquor jugs.';

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TomeVoice Spike',
        theme: ThemeData(useMaterial3: true),
        home: const SpikeScreen(),
      );
}

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  final _textController = TextEditingController(text: _defaultText);

  List<Map<String, String>> _engines = [];
  String? _engineId;

  List<Map<String, Object?>> _voices = [];
  String? _voiceName;

  /// Where the speed change happens.
  ///
  /// The engine's own rate control is a real duration change and sounds
  /// natural. Our DSP stage is a naive decimating resampler that shifts pitch
  /// with it - measured at 226 Hz -> 444 Hz at 2x, an unmistakable chipmunk.
  /// It exists to prove stage ordering, not to be listened to, so it is off by
  /// default and labelled for what it is.
  bool _speedViaEngine = true;

  double _gapMs = 120;
  double _speed = 1.0;
  double _sentencePauseMs = 350;

  bool _busy = false;
  String _status = 'Ready.';
  _RunReport? _report;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Loads the engine list, then checks whether this launch asked for a batch
  /// run (`--es batch true`). Batch mode exists so a measurement is driven by
  /// one adb command rather than by tapping sliders into the same positions.
  Future<void> _bootstrap() async {
    await _loadEngines();
    if (!mounted) return;

    try {
      final args = await _channel.invokeMapMethod<String, Object?>('launchArgs');
      if (args?['batch']?.toString() == 'true') {
        await _runBatch();
      }
    } catch (_) {
      // Batch mode is an optional convenience; never let it break startup.
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadEngines() async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listEngines',
      );
      setState(() {
        _engines = [
          for (final e in raw ?? const [])
            {
              'name': e['name'] as String? ?? '',
              'label': e['label'] as String? ?? '',
            },
        ];
        _engineId = _engines.isNotEmpty ? _engines.first['name'] : null;
      });
      await _loadVoices();
    } on PlatformException catch (e) {
      setState(() => _status = 'Could not list engines: ${e.message}');
    }
  }

  /// The voices this engine actually has, best quality first.
  ///
  /// Quality varies enormously within one engine: a device may carry a small
  /// embedded fallback alongside a much better downloaded voice for the same
  /// locale. The first listening test sounded robotic because the code forced
  /// Locale.US, which selected the fallback.
  Future<void> _loadVoices() async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listVoices',
        {'engineId': _engineId},
      );
      if (!mounted) return;
      setState(() {
        _voices = [
          for (final v in raw ?? const [])
            {
              'name': v['name'] as String? ?? '',
              'locale': v['locale'] as String? ?? '',
              'quality': v['quality'] as int? ?? 0,
              'networkRequired': v['networkRequired'] == true,
            },
        ];
        _voiceName = _pickDefaultVoice()?['name'] as String?;
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = 'Could not list voices: ${e.message}');
    }
  }

  /// Picks a sensible default voice.
  ///
  /// **Language first, quality second.** An earlier version sorted only by
  /// quality and name, and on a device whose engine offers dozens of locales
  /// that selected `ar-language` — an Arabic voice reading English text. A
  /// perfect-quality voice in the wrong language is worse than a mediocre one
  /// in the right language, so language match is not a tiebreaker, it is the
  /// primary key.
  ///
  /// Within the right language: offline beats network, then highest quality.
  Map<String, Object?>? _pickDefaultVoice() {
    if (_voices.isEmpty) return null;

    bool matchesLanguage(Map<String, Object?> v) =>
        (v['locale'] as String? ?? '')
            .toLowerCase()
            .startsWith(_targetLanguage.toLowerCase());

    final candidates = _voices.where(matchesLanguage).toList();
    final pool = candidates.isNotEmpty ? candidates : _voices;

    final offline = pool.where((v) => v['networkRequired'] != true).toList();
    final ranked = (offline.isNotEmpty ? offline : pool)
      ..sort((a, b) =>
          ((b['quality'] as int?) ?? 0).compareTo((a['quality'] as int?) ?? 0));

    return ranked.first;
  }

  /// The language the text is in. Hard-coded for the spike, whose sample text
  /// is English; the real product derives this from the document
  /// (docs/03 section 3.8).
  static const String _targetLanguage = 'en';

  /// One synthesis call to the platform.
  ///
  /// [rate] is the engine's own speed control. Passing it here produces a real
  /// duration change that sounds natural; passing 1.0 and letting our DSP stage
  /// do the work instead is only for measuring stage ordering, because that
  /// stage is a naive resampler that shifts pitch with speed.
  Future<Map<String, Object?>> _synthesiseNative(
    String? engineId, {
    double rate = 1.0,
    String? voiceName,
  }) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('synthesise', {
      'text': _textController.text,
      'engineId': engineId,
      'voiceName': voiceName,
      'rate': rate,
      'pitch': 1.0,
    });
    if (raw == null) throw Exception('No report returned');
    return raw;
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _status = 'Synthesising...';
      _report = null;
    });

    try {
      final native = await _synthesiseNative(
        _engineId,
        rate: _speedViaEngine ? _speed : 1.0,
        voiceName: _voiceName,
      );
      final report = await _processWith(
        native,
        PipelineSettings(
          wordGapMs: _gapMs.round(),
          // Only one of the two applies the speed change, never both.
          speedScale: _speedViaEngine ? 1.0 : _speed,
          sentencePauseMs: _sentencePauseMs.round(),
        ),
      );
      setState(() {
        _report = report;
        _status = 'Done.';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Engine error: ${e.code} ${e.message}');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Every configuration, every engine, exported — driven by an intent extra so
  /// a measurement run is reproducible instead of depending on someone tapping
  /// sliders to the same positions twice.
  ///
  /// The engine is called once per engine and the resulting audio processed
  /// four ways, so the configurations differ only in our own settings.
  Future<void> _runBatch() async {
    // `viaEngine` decides who applies the speed change. The DSP variant is the
    // one that proves stage ordering (S2); the engine variant is the one a human
    // can actually listen to, because the DSP stage shifts pitch with speed.
    const configs = <({int gap, double speed, bool viaEngine})>[
      (gap: 0, speed: 1.0, viaEngine: false),
      (gap: 120, speed: 1.0, viaEngine: false),
      (gap: 250, speed: 1.0, viaEngine: false),
      (gap: 120, speed: 2.0, viaEngine: false),
      (gap: 120, speed: 2.0, viaEngine: true),
    ];

    setState(() {
      _busy = true;
      _status = 'BATCH: starting...';
    });

    final log = <String>[];

    // Record what the device actually offers. The first run picked an Arabic
    // voice for English text, and without this line that was invisible until
    // someone listened.
    final matching = _voices
        .where((v) => (v['locale'] as String? ?? '')
            .toLowerCase()
            .startsWith(_targetLanguage))
        .length;
    log.add('voices: ${_voices.length} total, $matching match '
        '"$_targetLanguage", chosen="$_voiceName"');

    for (final engine in _engines) {
      final id = engine['name']!;
      final short = id.split('.').last;

      for (final c in configs) {
        try {
          setState(() => _status = 'BATCH: $short gap=${c.gap} '
              'speed=${c.speed}x...');

          // Engine-speed variants need their own synthesis, since the rate is
          // applied inside the engine rather than afterwards.
          final native = await _synthesiseNative(
            id,
            rate: c.viaEngine ? c.speed : 1.0,
            voiceName: _voiceName,
          );

          if (c == configs.first) {
            log.add('$short: onRangeStart=${native['rangeStartFired']} '
                'events=${(native['rangeEvents'] as List?)?.length ?? 0} '
                'granularity=${native['granularity']}');
          }

          final report = await _processWith(
            native,
            PipelineSettings(
              wordGapMs: c.gap,
              speedScale: c.viaEngine ? 1.0 : c.speed,
              sentencePauseMs: 350,
            ),
          );
          final speedTag =
              '${c.viaEngine ? 'eng' : 'dsp'}${c.speed.toStringAsFixed(1).replaceAll('.', '_')}';
          final label = '$short-gap${c.gap}-$speedTag';
          await _exportReport(report, label);
          log.add('  gap=${c.gap} speed=${c.speed}x -> $label');
          if (!mounted) return;
          setState(() {
            _report = report;
            _status = 'BATCH: exported $label';
          });
        } catch (e) {
          log.add('  gap=${c.gap} speed=${c.speed}x FAILED: $e');
        }
      }
    }

    // A sentinel file, so `adb pull` tells us the run finished rather than
    // leaving us guessing whether a missing export means failure or impatience.
    final dir = await _channel.invokeMethod<String>('outputDir');
    if (dir != null) {
      await File('$dir/BATCH-COMPLETE.txt').writeAsString(log.join('\n'));
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = 'BATCH COMPLETE\n${log.join('\n')}';
    });
  }

  /// Turns the engine's report into a [SynthesisResult], runs the pipeline, and
  /// measures the outcome from the audio itself.
  Future<_RunReport> _processWith(
    Map<String, Object?> native,
    PipelineSettings settings,
  ) async {
    final wavPath = native['wavPath'] as String;
    final raw = WavCodec.decode(await File(wavPath).readAsBytes());

    // Neutral names on purpose: the parameter order is not what the platform
    // documentation says, so it is detected rather than assumed. See
    // _timingsFromEvents.
    final events = [
      for (final e in (native['rangeEvents'] as List? ?? const []))
        (
          a: (e as Map)['start'] as int,
          b: e['end'] as int,
          c: e['frame'] as int,
        ),
    ];

    final decoded = _timingsFromEvents(
      events,
      raw.frameCount,
      _textController.text.length,
    );
    final timings = decoded.timings.isNotEmpty
        ? decoded.timings
        : _estimatedTimings(_textController.text, raw.frameCount);

    final traced = buildStandardPipeline(settings).runTraced(
      SynthesisResult(
        audio: raw,
        wordTimings: timings,
        engineId: native['engineId'] as String? ?? 'unknown',
      ),
    );
    final out = traced.result;

    final silences = AudioAnalysis.interiorSilences(
      out.audio,
      minDurationMs: settings.wordGapMs > 0 ? settings.wordGapMs * 0.5 : 20,
    );

    return _RunReport(
      native: native,
      rawFrames: raw.frameCount,
      processed: out,
      trace: traced.trace,
      measuredGapsMs: silences.map((s) => s.durationMs).toList(),
      discontinuity: AudioAnalysis.maxDiscontinuity(out.audio.samples),
      timingSource: timings.isEmpty
          ? WordTimingSource.estimated
          : timings.first.source,
      eventLayout: decoded.layout,
      settings: settings,
    );
  }

  /// Decodes `onRangeStart` events into word timings, **detecting** which
  /// parameter carries the frame position rather than trusting the documented
  /// order.
  ///
  /// The platform documents
  /// `onRangeStart(utteranceId, start, end, frameInAudio)`, but Google TTS on
  /// Android 16 delivers `(frameInAudio, charStart, charEnd)`. The engine-side
  /// callback it forwards from is
  /// `SynthesisCallback#rangeStart(markerInFrames, start, end)`, which puts
  /// frames first, and the ordering evidently passes straight through.
  ///
  /// Hard-coding either layout would break on the other, so the layout is
  /// inferred instead: character offsets are bounded by the text length, while
  /// frame positions at 24 kHz exceed it by orders of magnitude. Whichever
  /// column runs past the text length is the frame.
  ///
  /// Reading this wrongly is not a subtle error. It put every word at frame
  /// 3, 9, 15... so all the injected silence landed at the start of the buffer
  /// and edge-trimming removed it.
  ({List<WordTiming> timings, String layout}) _timingsFromEvents(
    List<({int a, int b, int c})> events,
    int totalFrames,
    int textLength,
  ) {
    if (events.isEmpty) return (timings: const [], layout: 'none');

    int maxOf(int Function(({int a, int b, int c})) pick) =>
        events.map(pick).reduce((x, y) => x > y ? x : y);

    final overA = maxOf((e) => e.a) > textLength;
    final overB = maxOf((e) => e.b) > textLength;
    final overC = maxOf((e) => e.c) > textLength;

    final String layout;
    int Function(({int a, int b, int c})) frameOf;
    int Function(({int a, int b, int c})) startOf;
    int Function(({int a, int b, int c})) endOf;

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
      // Cannot tell - a very short utterance, or an engine doing something
      // else entirely. Assume the documented order and say so, so the report
      // records that this run's timings are not trustworthy.
      layout = 'ambiguous';
      frameOf = (e) => e.c;
      startOf = (e) => e.a;
      endOf = (e) => e.b;
    }

    // A range's audio runs until the next range begins, so ends come from the
    // following event.
    final timings = [
      for (var i = 0; i < events.length; i++)
        WordTiming(
          charStart: startOf(events[i]),
          charEnd: endOf(events[i]),
          frameStart: frameOf(events[i]).clamp(0, totalFrames),
          frameEnd: (i + 1 < events.length
                  ? frameOf(events[i + 1])
                  : totalFrames)
              .clamp(0, totalFrames),
          source: layout == 'ambiguous'
              ? WordTimingSource.estimated
              : WordTimingSource.engineReported,
        ),
    ];

    return (timings: timings, layout: layout);
  }

  /// Fallback when the engine supplies nothing: distribute duration across
  /// words by character count. Good enough to place gaps, visibly wrong for
  /// highlighting — which is exactly why the source is recorded (docs/09 C-13).
  List<WordTiming> _estimatedTimings(String text, int totalFrames) {
    final words = <({int start, int end})>[];
    final pattern = RegExp(r'\S+');
    for (final m in pattern.allMatches(text)) {
      words.add((start: m.start, end: m.end));
    }
    if (words.isEmpty) return const [];

    final totalChars =
        words.fold<int>(0, (sum, w) => sum + (w.end - w.start));

    var cursor = 0;
    return [
      for (final w in words)
        () {
          final share = (w.end - w.start) / totalChars;
          final frames = (totalFrames * share).round();
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

  Future<void> _play() async {
    final report = _report;
    if (report == null) return;

    // Always re-export the current report.
    //
    // This used to be `_lastOutputPath ?? await _export(...)`, and
    // _lastOutputPath was never cleared when a new run produced new audio. The
    // first Play cached a path and every Play afterwards replayed that same
    // file, so changing any setting appeared to do nothing at all. After a
    // batch run it was worse: the cached path was the last export, so the
    // 2x-speed file played back whatever the sliders said.
    final path = await _exportReport(report, 'preview');
    if (path == null) return;
    try {
      await _channel.invokeMethod<void>('play', {'path': path});
    } on PlatformException catch (e) {
      setState(() => _status = 'Playback failed: ${e.message}');
    }
  }

  /// Writes the WAV and its JSON report side by side, sharing a prefix so
  /// `measure.dart` can find both from one argument.
  Future<String?> _exportReport(_RunReport report, String label) async {
    final dir = await _channel.invokeMethod<String>('outputDir');
    if (dir == null) return null;

    final prefix = '$dir/tomevoice-spike-$label';

    await File('$prefix.wav')
        .writeAsBytes(WavCodec.encodePcm16(report.processed.audio));
    await File('$prefix.json').writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(report.toJson(_textController.text)),
    );

    return '$prefix.wav';
  }

  Future<String?> _export() async {
    final report = _report;
    if (report == null) return null;

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '')
        .substring(0, 15);
    final path = await _exportReport(report, stamp);

    if (path != null) {
      setState(() => _status = 'Exported to $path (+ .json)');
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TomeVoice audio spike')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _engineId,
              decoration: const InputDecoration(labelText: 'TTS engine'),
              items: [
                for (final e in _engines)
                  DropdownMenuItem(
                    value: e['name'],
                    child: Text(e['label']!.isEmpty ? e['name']! : e['label']!),
                  ),
              ],
              onChanged: (v) {
                setState(() => _engineId = v);
                _loadVoices();
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _voiceName,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Voice (${_voices.length} available, best first)',
              ),
              items: [
                for (final v in _voices)
                  DropdownMenuItem(
                    value: v['name'] as String,
                    child: Text(
                      '${v['locale']}  q${v['quality']}'
                      '${v['networkRequired'] == true ? '  [network]' : ''}'
                      '  ${v['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _voiceName = v),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _speedViaEngine,
              onChanged: (v) => setState(() => _speedViaEngine = v),
              title: Text(_speedViaEngine
                  ? 'Speed: engine (natural)'
                  : 'Speed: DSP stub (pitch-shifts!)'),
              subtitle: Text(
                _speedViaEngine
                    ? 'Real duration change inside the engine. Use this to listen.'
                    : 'Naive resampler: 2x doubles the pitch. Measurement only.',
                style: TextStyle(
                  color: _speedViaEngine ? null : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Text',
                border: OutlineInputBorder(),
              ),
            ),
            _slider('Word gap', _gapMs, 0, 500, 'ms',
                (v) => setState(() => _gapMs = v)),
            _slider('Speed', _speed, 0.5, 3.0, 'x',
                (v) => setState(() => _speed = v), decimals: 2),
            _slider('Sentence pause', _sentencePauseMs, 0, 2000, 'ms',
                (v) => setState(() => _sentencePauseMs = v)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _run,
                    child: const Text('Synthesise'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _report == null ? null : _play,
                    child: const Text('Play'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _report == null ? null : _export,
              child: const Text('Export WAV + JSON'),
            ),
            const Divider(height: 32),
            Text(_status),
            const SizedBox(height: 8),
            if (_report != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  _report!.render(_gapMs.round()),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    String unit,
    ValueChanged<double> onChanged, {
    int decimals = 0,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ${value.toStringAsFixed(decimals)} $unit'),
          Slider(value: value, min: min, max: max, onChanged: onChanged),
        ],
      );
}

class _RunReport {
  _RunReport({
    required this.native,
    required this.rawFrames,
    required this.processed,
    required this.trace,
    required this.measuredGapsMs,
    required this.discontinuity,
    required this.timingSource,
    required this.eventLayout,
    required this.settings,
  });

  final Map<String, Object?> native;
  final int rawFrames;
  final SynthesisResult processed;
  final List<StageTrace> trace;
  final List<double> measuredGapsMs;
  final double discontinuity;
  final WordTimingSource timingSource;

  /// Which onRangeStart parameter layout this engine used: `frameFirst`,
  /// `documented`, `ambiguous`, or `none`. Recorded because it varies by
  /// engine and silently corrupts timings when guessed wrong.
  final String eventLayout;

  final PipelineSettings settings;

  String render(int requestedGapMs) {
    final gaps = measuredGapsMs.isEmpty
        ? 'none'
        : measuredGapsMs.map((g) => g.toStringAsFixed(0)).join(' ');
    final events = (native['rangeEvents'] as List?)?.length ?? 0;

    return [
      'onRangeStart fired : ${native['rangeStartFired'] == true ? 'YES' : 'NO'}',
      'granularity        : ${native['granularity']} ($events events)',
      'timing source      : ${timingSource.name}',
      'event layout      : $eventLayout',
      'engine             : ${native['engineId']}',
      'voice              : ${native['voiceName'] ?? 'engine default'}',
      'speed applied by   : ${settings.speedScale == 1.0 ? 'engine' : 'DSP stub'}',
      'sample rate        : ${native['sampleRate']} Hz',
      'raw frames         : $rawFrames',
      'processed frames   : ${processed.audio.frameCount}',
      'words              : ${processed.wordTimings.length}',
      '',
      'measured gaps (ms) : $gaps',
      'requested gap (ms) : $requestedGapMs',
      'max discontinuity  : ${discontinuity.toStringAsFixed(4)}',
      '',
      'stages:',
      ...trace.map((t) => '  $t'),
    ].join('\n');
  }

  Map<String, Object?> toJson(String text) => {
        'engineId': native['engineId'],
        'deviceModel': native['deviceModel'],
        'androidVersion': native['androidVersion'],
        'text': text,
        'settings': {
          'gapMs': settings.wordGapMs,
          'speedScale': settings.speedScale,
          'sentencePauseMs': settings.sentencePauseMs,
        },
        'rangeStartFired': native['rangeStartFired'],
        'granularity': native['granularity'],
        'rangeEvents': native['rangeEvents'],
        'timingSource': timingSource.name,
        'voiceName': native['voiceName'],
        'speedAppliedBy': settings.speedScale == 1.0 ? 'engine' : 'dsp',
        'eventLayout': eventLayout,
        'sampleRate': processed.audio.sampleRate,
        'rawFrameCount': rawFrames,
        'processedFrameCount': processed.audio.frameCount,
        'measuredGapsMs': measuredGapsMs,
        'maxDiscontinuity': discontinuity,
        'stages': [
          for (final t in trace)
            {'name': t.stageName, 'in': t.framesIn, 'out': t.framesOut},
        ],
        'reportedTimings': [
          for (final t in processed.wordTimings)
            {
              'charStart': t.charStart,
              'charEnd': t.charEnd,
              'frameStart': t.frameStart,
              'frameEnd': t.frameEnd,
            },
        ],
      };
}
