import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tomevoice_audio/tomevoice_audio.dart';

const int kRate = 24000;

/// Synthetic "speech": a run of tone bursts, one per word.
///
/// [enveloped] shapes each burst with a raised-cosine attack and release, which
/// makes the source waveform smooth. Use it when measuring introduced clicks,
/// so any discontinuity in the output is unambiguously ours.
///
/// Leave it off for gap-duration measurement: flat bursts butted directly
/// together mean the only silence in the buffer is silence we inserted.
({AudioBuffer audio, List<WordTiming> timings}) syntheticSpeech({
  int words = 5,
  double wordMs = 200,
  double naturalGapMs = 0,
  bool enveloped = false,
  int sampleRate = kRate,
  double frequency = 220,
  double amplitude = 0.7,
}) {
  final wordFrames = (wordMs * sampleRate / 1000).round();
  final gapFrames = (naturalGapMs * sampleRate / 1000).round();
  final stride = wordFrames + gapFrames;
  final total = words * stride - gapFrames;

  final samples = Float32List(total);
  final timings = <WordTiming>[];
  final envFrames = (5 * sampleRate / 1000).round();

  for (var w = 0; w < words; w++) {
    final start = w * stride;
    for (var i = 0; i < wordFrames; i++) {
      final t = i / sampleRate;
      var value = amplitude * math.sin(2 * math.pi * frequency * t);

      if (enveloped) {
        if (i < envFrames) {
          value *= 0.5 * (1 - math.cos(math.pi * i / envFrames));
        } else if (i >= wordFrames - envFrames) {
          final k = wordFrames - 1 - i;
          value *= 0.5 * (1 - math.cos(math.pi * k / envFrames));
        }
      }
      samples[start + i] = value;
    }

    timings.add(WordTiming(
      charStart: w * 5,
      charEnd: w * 5 + 4,
      frameStart: start,
      frameEnd: start + wordFrames,
      source: WordTimingSource.engineReported,
    ));
  }

  return (audio: AudioBuffer(samples, sampleRate), timings: timings);
}

/// A buffer that is silent except for single-sample impulses at each word
/// boundary.
///
/// This is how remap correctness is tested without a real engine: run the
/// pipeline, then check that every reported frame position still lands on an
/// impulse. If the remap arithmetic is wrong the impulses and the reported
/// positions drift apart, whatever the audio content happens to be.
({AudioBuffer audio, List<WordTiming> timings, List<int> impulses})
    impulseMarked({
  int words = 6,
  double wordMs = 100,
  int sampleRate = kRate,
}) {
  final wordFrames = (wordMs * sampleRate / 1000).round();
  final total = words * wordFrames;

  final samples = Float32List(total);
  final timings = <WordTiming>[];
  final impulses = <int>[];

  for (var w = 0; w < words; w++) {
    final start = w * wordFrames;
    samples[start] = 1.0;
    impulses.add(start);

    timings.add(WordTiming(
      charStart: w * 5,
      charEnd: w * 5 + 4,
      frameStart: start,
      frameEnd: start + wordFrames,
      source: WordTimingSource.engineReported,
    ));
  }

  return (
    audio: AudioBuffer(samples, sampleRate),
    timings: timings,
    impulses: impulses,
  );
}

SynthesisResult resultOf(AudioBuffer audio, List<WordTiming> timings) =>
    SynthesisResult(
      audio: audio,
      wordTimings: timings,
      engineId: 'test.synthetic',
    );

/// Settings that make the pipeline arithmetically exact: no snapping, no fades,
/// no trimming. Used where a test asserts on precise frame positions.
const PipelineSettings exactSettings = PipelineSettings(
  snapSearchMs: 0,
  crossfadeMs: 0,
  sentencePauseMs: 0,
  trimEdges: false,
);
