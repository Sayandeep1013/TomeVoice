// Produces a synthetic spike run (WAV + JSON) in the exact shape the app
// exports, so `measure.dart` can be exercised without a device.
//
// Usage:
//   dart run bin/make_fixture.dart ../spike-runs/synthetic [gapMs] [speed]
//
// This is a test harness for the verifier, not a substitute for a real run.
// It cannot answer R1 — only a device and a real engine can do that.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tomevoice_audio/tomevoice_audio.dart';

const int _rate = 24000;
const String _text = 'The quick brown fox jumps over the lazy dog';

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bin/make_fixture.dart <out-prefix> '
        '[gapMs] [speed]');
    return 64;
  }

  final prefix = args.first;
  final gapMs = args.length > 1 ? int.parse(args[1]) : 120;
  final speed = args.length > 2 ? double.parse(args[2]) : 1.0;

  final words = _text.split(' ');
  final built = _buildSpeech(words);

  final settings = PipelineSettings(
    wordGapMs: gapMs,
    speedScale: speed,
    sentencePauseMs: 350,
  );

  final traced = buildStandardPipeline(settings).runTraced(
    SynthesisResult(
      audio: built.audio,
      wordTimings: built.timings,
      engineId: 'synthetic.fixture',
    ),
  );
  final out = traced.result;

  final silences = AudioAnalysis.interiorSilences(
    out.audio,
    minDurationMs: gapMs > 0 ? gapMs * 0.5 : 20,
  );

  await Directory(File(prefix).parent.path).create(recursive: true);
  await File('$prefix.wav')
      .writeAsBytes(WavCodec.encodePcm16(out.audio));

  final report = <String, Object?>{
    'engineId': 'synthetic.fixture',
    'deviceModel': 'synthetic',
    'androidVersion': 36,
    'text': _text,
    'settings': {
      'gapMs': gapMs,
      'speedScale': speed,
      'sentencePauseMs': 350,
    },
    'rangeStartFired': true,
    'granularity': 'word',
    'rangeEvents': [
      for (final t in built.timings)
        {'start': t.charStart, 'end': t.charEnd, 'frame': t.frameStart},
    ],
    'timingSource': 'engineReported',
    'sampleRate': out.audio.sampleRate,
    'rawFrameCount': built.audio.frameCount,
    'processedFrameCount': out.audio.frameCount,
    'measuredGapsMs': silences.map((s) => s.durationMs).toList(),
    'maxDiscontinuity': AudioAnalysis.maxDiscontinuity(out.audio.samples),
    'stages': [
      for (final t in traced.trace)
        {'name': t.stageName, 'in': t.framesIn, 'out': t.framesOut},
    ],
    'reportedTimings': [
      for (final t in out.wordTimings)
        {
          'charStart': t.charStart,
          'charEnd': t.charEnd,
          'frameStart': t.frameStart,
          'frameEnd': t.frameEnd,
        },
    ],
  };

  await File('$prefix.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));

  stdout.writeln('wrote $prefix.wav and $prefix.json '
      '(gap ${gapMs}ms, speed ${speed}x, ${words.length} words)');
  return 0;
}

/// Enveloped tone bursts, one per word, with a short natural gap between them —
/// close enough in shape to real speech for the verifier's purposes.
({AudioBuffer audio, List<WordTiming> timings}) _buildSpeech(
  List<String> words,
) {
  const wordMs = 260.0;
  const naturalGapMs = 30.0;

  final wordFrames = (wordMs * _rate / 1000).round();
  final gapFrames = (naturalGapMs * _rate / 1000).round();
  final stride = wordFrames + gapFrames;
  final total = words.length * stride - gapFrames;

  final samples = Float32List(total);
  final timings = <WordTiming>[];
  final envFrames = (8 * _rate / 1000).round();

  var charCursor = 0;

  for (var w = 0; w < words.length; w++) {
    final start = w * stride;
    // Vary pitch per word so the buffer is not a single continuous tone.
    final freq = 180.0 + (w % 4) * 40.0;

    for (var i = 0; i < wordFrames; i++) {
      var value = 0.65 * math.sin(2 * math.pi * freq * i / _rate);
      if (i < envFrames) {
        value *= 0.5 * (1 - math.cos(math.pi * i / envFrames));
      } else if (i >= wordFrames - envFrames) {
        final k = wordFrames - 1 - i;
        value *= 0.5 * (1 - math.cos(math.pi * k / envFrames));
      }
      samples[start + i] = value;
    }

    timings.add(WordTiming(
      charStart: charCursor,
      charEnd: charCursor + words[w].length,
      frameStart: start,
      frameEnd: start + wordFrames,
      source: WordTimingSource.engineReported,
    ));
    charCursor += words[w].length + 1;
  }

  return (audio: AudioBuffer(samples, _rate), timings: timings);
}
