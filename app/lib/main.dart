import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'reader_screen.dart';
import 'speech_service.dart';
import 'theme.dart';

void main() => runApp(const SpikeApp());

/// Entry point.
///
/// Two modes. Normally this is the reader. Launched with `--es batch true` it
/// runs the measurement sweep instead, so a device run is one adb command
/// rather than a person tapping sliders into the same positions twice:
///
///     adb shell am start -n app.tomevoice.tomevoice_spike/.MainActivity \
///         --es batch true
class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TomeVoice',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: Skin.cream,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Skin.nightBottom,
        ),
        home: const _ModeGate(),
      );
}

class _ModeGate extends StatefulWidget {
  const _ModeGate();

  @override
  State<_ModeGate> createState() => _ModeGateState();
}

class _ModeGateState extends State<_ModeGate> {
  bool? _batch;

  @override
  void initState() {
    super.initState();
    const SpeechService().launchArgs().then((args) {
      if (mounted) setState(() => _batch = args['batch'] == 'true');
    });
  }

  @override
  Widget build(BuildContext context) => switch (_batch) {
        null => const Scaffold(body: SizedBox.shrink()),
        true => const BatchScreen(),
        false => const ReaderScreen(),
      };
}

/// The measurement sweep.
///
/// Synthesises once per (engine, speed-mode) and processes that audio through
/// every gap setting, so configurations differ only in our own pipeline
/// settings. Writes a WAV plus JSON pair per configuration and a
/// BATCH-COMPLETE.txt sentinel, which is what `adb pull` and
/// `tools/measure.dart` consume.
class BatchScreen extends StatefulWidget {
  const BatchScreen({super.key});

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  static const _text =
      'The quick brown fox jumps over the lazy dog. '
      'Pack my box with five dozen liquor jugs.';

  static const _configs = <({int gap, double speed, bool viaEngine})>[
    (gap: 0, speed: 1.0, viaEngine: false),
    (gap: 120, speed: 1.0, viaEngine: false),
    (gap: 250, speed: 1.0, viaEngine: false),
    (gap: 120, speed: 2.0, viaEngine: false),
    (gap: 120, speed: 2.0, viaEngine: true),
  ];

  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    const svc = SpeechService();
    void note(String s) {
      if (mounted) setState(() => _log.add(s));
    }

    final engines = await svc.engines();
    final voices = await svc.voices(engines.firstOrNull?['name']);
    final voice = SpeechService.pickVoice(voices, 'en');
    final voiceName = voice?['name'] as String?;

    final matching = voices
        .where((v) =>
            (v['locale'] as String? ?? '').toLowerCase().startsWith('en'))
        .length;
    note('voices: ${voices.length} total, $matching match "en", '
        'chosen="$voiceName"');

    final dir = await svc.outputDir();

    for (final engine in engines) {
      final id = engine['name']!;
      final short = id.split('.').last;

      for (final c in _configs) {
        try {
          final native = await svc.synthesise(
            text: _text,
            engineId: id,
            voiceName: voiceName,
            rate: c.viaEngine ? c.speed : 1.0,
          );

          if (c == _configs.first) {
            note('$short: onRangeStart=${native['rangeStartFired']} '
                'events=${(native['rangeEvents'] as List?)?.length ?? 0} '
                'granularity=${native['granularity']}');
          }

          final settings = PipelineSettings(
            wordGapMs: c.gap,
            speedScale: c.viaEngine ? 1.0 : c.speed,
            sentencePauseMs: 350,
            text: _text,
          );
          final out = await svc.process(native, settings);

          final tag = '${c.viaEngine ? 'eng' : 'dsp'}'
              '${c.speed.toStringAsFixed(1).replaceAll('.', '_')}';
          final label = '$short-gap${c.gap}-$tag';

          if (dir != null) {
            await File('$dir/tomevoice-spike-$label.wav')
                .writeAsBytes(WavCodec.encodePcm16(out.audio));
            await File('$dir/tomevoice-spike-$label.json')
                .writeAsString(encodeReport(out.toJson(_text, settings)));
          }
          note('  gap=${c.gap} speed=${c.speed}x ${c.viaEngine ? 'eng' : 'dsp'}'
              ' -> $label');
        } catch (e) {
          note('  gap=${c.gap} speed=${c.speed}x FAILED: $e');
        }
      }
    }

    if (dir != null) {
      await File('$dir/BATCH-COMPLETE.txt').writeAsString(_log.join('\n'));
    }
    note('BATCH COMPLETE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Skin.dark,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: ListView(
              children: [
                Text('BATCH',
                    style: Skin.meta(context, color: Skin.amber, size: 12)),
                const SizedBox(height: 12),
                for (final l in _log)
                  Text(l,
                      style: Skin.meta(context,
                          color: Skin.cream.withValues(alpha: 0.85),
                          size: 10.5)),
              ],
            ),
          ),
        ),
      );
}
