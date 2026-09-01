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

  double _gapMs = 120;
  double _speed = 1.0;
  double _sentencePauseMs = 350;

  bool _busy = false;
  String _status = 'Ready.';
  _RunReport? _report;
  String? _lastOutputPath;

  @override
  void initState() {
    super.initState();
    _loadEngines();
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
    } on PlatformException catch (e) {
      setState(() => _status = 'Could not list engines: ${e.message}');
    }
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _status = 'Synthesising...';
      _report = null;
    });

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'synthesise',
        {
          'text': _textController.text,
          'engineId': _engineId,
          'rate': 1.0, // Speed is applied in our pipeline, not by the engine,
          'pitch': 1.0, // so the spike measures our own arithmetic.
        },
      );
      if (raw == null) throw Exception('No report returned');

      final report = await _process(raw);
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

  /// Turns the engine's report into a [SynthesisResult], runs the pipeline, and
  /// measures the outcome from the audio itself.
  Future<_RunReport> _process(Map<String, Object?> native) async {
    final wavPath = native['wavPath'] as String;
    final raw = WavCodec.decode(await File(wavPath).readAsBytes());

    final events = [
      for (final e in (native['rangeEvents'] as List? ?? const []))
        (
          start: (e as Map)['start'] as int,
          end: e['end'] as int,
          frame: e['frame'] as int,
        ),
    ];

    final timings = events.isNotEmpty
        ? _timingsFromEvents(events, raw.frameCount)
        : _estimatedTimings(_textController.text, raw.frameCount);

    final settings = PipelineSettings(
      wordGapMs: _gapMs.round(),
      speedScale: _speed,
      sentencePauseMs: _sentencePauseMs.round(),
    );

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
      minDurationMs: _gapMs > 0 ? _gapMs * 0.5 : 20,
    );

    return _RunReport(
      native: native,
      rawFrames: raw.frameCount,
      processed: out,
      trace: traced.trace,
      measuredGapsMs: silences.map((s) => s.durationMs).toList(),
      discontinuity: AudioAnalysis.maxDiscontinuity(out.audio.samples),
      timingSource: events.isNotEmpty
          ? WordTimingSource.engineReported
          : WordTimingSource.estimated,
      settings: settings,
    );
  }

  /// The engine reports a frame position per range. A range's audio runs until
  /// the next range begins, so ends come from the following event.
  List<WordTiming> _timingsFromEvents(
    List<({int start, int end, int frame})> events,
    int totalFrames,
  ) =>
      [
        for (var i = 0; i < events.length; i++)
          WordTiming(
            charStart: events[i].start,
            charEnd: events[i].end,
            frameStart: events[i].frame,
            frameEnd:
                i + 1 < events.length ? events[i + 1].frame : totalFrames,
            source: WordTimingSource.engineReported,
          ),
      ];

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
    final path = _lastOutputPath ?? await _export(silent: true);
    if (path == null) return;
    try {
      await _channel.invokeMethod<void>('play', {'path': path});
    } on PlatformException catch (e) {
      setState(() => _status = 'Playback failed: ${e.message}');
    }
  }

  Future<String?> _export({bool silent = false}) async {
    final report = _report;
    if (report == null) return null;

    final dir = await _channel.invokeMethod<String>('outputDir');
    if (dir == null) return null;

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '')
        .substring(0, 15);
    final prefix = '$dir/tomevoice-spike-$stamp';

    await File('$prefix.wav')
        .writeAsBytes(WavCodec.encodePcm16(report.processed.audio));
    await File('$prefix.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report.toJson(
        _textController.text,
      )),
    );

    _lastOutputPath = '$prefix.wav';
    if (!silent) {
      setState(() => _status = 'Exported to $prefix.{wav,json}');
    }
    return _lastOutputPath;
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
              onChanged: (v) => setState(() => _engineId = v),
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
              onPressed: _report == null ? null : () => _export(),
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
    required this.settings,
  });

  final Map<String, Object?> native;
  final int rawFrames;
  final SynthesisResult processed;
  final List<StageTrace> trace;
  final List<double> measuredGapsMs;
  final double discontinuity;
  final WordTimingSource timingSource;
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
      'engine             : ${native['engineId']}',
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
