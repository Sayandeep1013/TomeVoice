// Offline verifier for spike runs exported from a device.
//
// Usage:
//   cd tools && dart pub get
//   dart run bin/measure.dart ../spike-runs/tomevoice-spike-<timestamp>
//
// Pass the run prefix without an extension; the .wav and .json beside it are
// read together.
//
// Checks the spike's success criteria (docs/15 section 15.3) against the
// *audio*, not against what the app believed it did. It deliberately does not
// re-run the pipeline — measuring with the same code that produced the result
// would let a bug certify itself. It uses only the analysis helpers, which are
// independently unit-tested and are not part of the pipeline.

import 'dart:convert';
import 'dart:io';

import 'package:tomevoice_audio/tomevoice_audio.dart';

const double kGapToleranceMs = 5.0;
const double kDiscontinuityLimit = 0.1;
const int kBoundaryToleranceMs = 25;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run bin/measure.dart <run-prefix> '
        '[--baseline <gap-0-run-prefix>]');
    stderr.writeln('  e.g. dart run bin/measure.dart '
        '../spike-runs/files/tomevoice-spike-tts-gap120-speed1_0 \\');
    stderr.writeln('         --baseline '
        '../spike-runs/files/tomevoice-spike-tts-gap0-speed1_0');
    stderr.writeln('');
    stderr.writeln('  The baseline is the same engine and speed with gap=0. It '
        'tells S4 how many');
    stderr.writeln('  silences the engine produces on its own, so its natural '
        'pauses are not');
    stderr.writeln('  mistaken for gaps we inserted.');
    exit(64);
  }

  final baselineIndex = args.indexOf('--baseline');
  final baselinePrefix = baselineIndex >= 0 && baselineIndex + 1 < args.length
      ? args[baselineIndex + 1].replaceAll(RegExp(r'\.(wav|json)$'), '')
      : null;

  final prefix = args.first.replaceAll(RegExp(r'\.(wav|json)$'), '');
  final wavFile = File('$prefix.wav');
  final jsonFile = File('$prefix.json');

  for (final f in [wavFile, jsonFile]) {
    if (!f.existsSync()) {
      stderr.writeln('missing: ${f.path}');
      exit(66);
    }
  }

  final report =
      jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
  final audio = WavCodec.decode(await wavFile.readAsBytes());

  _printHeader(report, audio);

  // How many silences the engine produces unprompted. Google TTS, for instance,
  // leaves ~360 ms after a sentence-final full stop, and reports it *inside* the
  // preceding word's range rather than at a boundary - so without this, its own
  // pause looks like a gap of ours that landed in the wrong place.
  int? naturalSilences;
  if (baselinePrefix != null) {
    final bWav = File('$baselinePrefix.wav');
    if (bWav.existsSync()) {
      final bAudio = WavCodec.decode(await bWav.readAsBytes());
      naturalSilences = AudioAnalysis.interiorSilences(bAudio).length;
      stdout.writeln('  baseline   $naturalSilences natural interior silences '
          '(from ${bWav.uri.pathSegments.last})');
    } else {
      stdout.writeln('  baseline   NOT FOUND at $baselinePrefix.wav');
    }
  }

  final checks = <_Check>[
    _checkEngineReport(report),
    _checkStageArithmetic(report),
    _checkGapsAcoustically(report, audio),
    _checkDiscontinuity(report, audio),
    _checkTimings(report, audio, naturalSilences),
  ];

  stdout
    ..writeln('')
    ..writeln('-' * 70);
  var failed = 0;
  for (final c in checks) {
    stdout.writeln(c);
    if (!c.passed) failed++;
  }
  stdout.writeln('-' * 70);

  if (failed == 0) {
    stdout.writeln('PASS  all ${checks.length} criteria met');
    exit(0);
  }
  stdout.writeln('FAIL  $failed of ${checks.length} criteria not met');
  exit(1);
}

void _printHeader(Map<String, dynamic> report, AudioBuffer audio) {
  final settings = (report['settings'] as Map?) ?? const {};
  stdout
    ..writeln('TomeVoice spike run')
    ..writeln('  device     ${report['deviceModel'] ?? '?'} '
        '(Android ${report['androidVersion'] ?? '?'})')
    ..writeln('  engine     ${report['engineId'] ?? '?'}')
    ..writeln('  text       "${report['text'] ?? ''}"')
    ..writeln('  settings   gap=${settings['gapMs']}ms  '
        'speed=${settings['speedScale']}x  '
        'sentencePause=${settings['sentencePauseMs']}ms')
    ..writeln('  audio      ${audio.frameCount} frames @ '
        '${audio.sampleRate} Hz = '
        '${(audio.duration.inMilliseconds / 1000).toStringAsFixed(2)}s');
}

/// S5 — we must know what the engine reported, whatever it was.
///
/// This criterion is about *knowing*, not about the answer being good. An
/// engine that supplies no timings still satisfies S5, as long as it said so.
_Check _checkEngineReport(Map<String, dynamic> report) {
  final fired = report['rangeStartFired'] == true;
  final granularity = report['granularity'] as String? ?? 'unknown';
  final events = (report['rangeEvents'] as List?)?.length ?? 0;
  final source = report['timingSource'] as String? ?? 'unknown';

  final known = granularity != 'unknown' && source != 'unknown';

  final note = switch (granularity) {
    'none' => '  <-- R1: this engine supplies no timings',
    'utterance' => '  <-- R1: utterance-level only, unusable for gap placement',
    _ => '',
  };

  return _Check(
    'S5 engine timing reported',
    known,
    'onRangeStart=${fired ? 'YES' : 'no'}  granularity=$granularity  '
        'events=$events  source=$source$note',
  );
}

/// S1 exactly — the word-gap stage must have inserted precisely
/// `boundaries x gapFrames`.
///
/// Frame arithmetic rather than acoustics: unambiguous, and independent of how
/// much natural silence the engine left between words.
_Check _checkStageArithmetic(Map<String, dynamic> report) {
  final settings = (report['settings'] as Map?) ?? const {};
  final gapMs = (settings['gapMs'] as num?)?.toDouble() ?? 0;
  final sampleRate = (report['sampleRate'] as num?)?.toInt() ?? 0;
  final wordCount = (report['reportedTimings'] as List?)?.length ?? 0;
  final stages = (report['stages'] as List?) ?? const [];

  if (sampleRate == 0 || stages.isEmpty) {
    return const _Check(
        'S1 gap arithmetic', false, 'no stage trace in the report');
  }

  final gapStage = stages.cast<Map<String, dynamic>>().firstWhere(
        (s) => s['name'] == 'word_gap',
        orElse: () => <String, dynamic>{},
      );
  if (gapStage.isEmpty) {
    return const _Check(
        'S1 gap arithmetic', false, 'word_gap stage missing from trace');
  }

  final actualInserted =
      (gapStage['out'] as num).toInt() - (gapStage['in'] as num).toInt();
  final gapFrames = (gapMs * sampleRate / 1000).round();
  final boundaries = wordCount > 1 ? wordCount - 1 : 0;
  final expected = boundaries * gapFrames;

  return _Check(
    'S1 gap arithmetic',
    actualInserted == expected,
    'word_gap inserted $actualInserted frames, expected $expected '
        '($boundaries boundaries x $gapFrames frames)',
  );
}

/// S1/S2 acoustically — the silence must genuinely be in the audio, and must
/// not shrink when the speed changes.
///
/// Injected silence merges with whatever natural silence the engine already
/// left between words, so measured runs are *at least* the requested gap rather
/// than exactly it. Asserting equality here would fail on correct output; the
/// exact figure is covered by [_checkStageArithmetic].
_Check _checkGapsAcoustically(Map<String, dynamic> report, AudioBuffer audio) {
  final settings = (report['settings'] as Map?) ?? const {};
  final requestedGap = (settings['gapMs'] as num?)?.toDouble() ?? 0;
  final speed = (settings['speedScale'] as num?)?.toDouble() ?? 1.0;
  final wordCount = (report['reportedTimings'] as List?)?.length ?? 0;

  if (requestedGap <= 0) {
    final natural = AudioAnalysis.interiorSilences(audio);
    return _Check(
      'S1/S2 word gap present',
      true,
      'no gap requested; ${natural.length} natural interior silences '
          '(baseline for comparison)',
    );
  }

  final expectedCount = wordCount > 1 ? wordCount - 1 : 0;
  final silences = AudioAnalysis.interiorSilences(
    audio,
    minDurationMs: requestedGap * 0.5,
  );

  final measured = silences.map((s) => s.durationMs).toList();
  final tooShort =
      measured.where((d) => d < requestedGap - kGapToleranceMs).toList();

  final passed = silences.length >= expectedCount && tooShort.isEmpty;

  final rendered = measured.isEmpty
      ? 'none'
      : measured.map((d) => d.toStringAsFixed(0)).join(' ');
  final natural = measured.isEmpty
      ? 0.0
      : measured.reduce((a, b) => a < b ? a : b) - requestedGap;

  return _Check(
    'S1/S2 gap >= ${requestedGap.toStringAsFixed(0)}ms at ${speed}x',
    passed,
    'found ${silences.length} of $expectedCount expected; '
        '${tooShort.length} shorter than requested\n'
        '        measured (ms): $rendered\n'
        '        implied natural silence: ~${natural.toStringAsFixed(0)}ms '
        'per boundary',
  );
}

/// S3 — splicing must not introduce clicks.
///
/// Measured *locally at the splices*, not globally. A global threshold conflates
/// two unrelated things: a click we introduced, and roughness the signal already
/// had. The naive resampling stretch stub, for instance, measures 0.10 at 2x
/// speed with **zero** splices present — failing a global check while the
/// splicing was blameless. (That roughness is the stub's known deficiency and is
/// why Phase 3 replaces it; see docs/09 C-14.)
///
/// So: compare the discontinuity in a window around each gap edge against the
/// buffer's own baseline. A click is a local outlier, and that is what we test
/// for.
_Check _checkDiscontinuity(Map<String, dynamic> report, AudioBuffer audio) {
  final settings = (report['settings'] as Map?) ?? const {};
  final requestedGap = (settings['gapMs'] as num?)?.toDouble() ?? 0;
  final global = AudioAnalysis.maxDiscontinuity(audio.samples);

  if (requestedGap <= 0) {
    return _Check(
      'S3 no splice artefacts',
      true,
      'no gaps requested, so no splices to check; '
          'buffer baseline ${global.toStringAsFixed(4)}',
    );
  }

  final silences = AudioAnalysis.interiorSilences(
    audio,
    minDurationMs: requestedGap * 0.5,
  );
  if (silences.isEmpty) {
    return const _Check(
        'S3 no splice artefacts', false, 'gap requested but no silence found');
  }

  final window = audio.msToFrames(3);
  final samples = audio.samples;

  // Mark the neighbourhood of every gap edge.
  final nearEdge = List<bool>.filled(samples.length, false);
  for (final run in silences) {
    for (final edge in [run.startFrame, run.endFrame]) {
      final lo = (edge - window).clamp(0, samples.length - 1);
      final hi = (edge + window).clamp(0, samples.length - 1);
      for (var i = lo; i <= hi; i++) {
        nearEdge[i] = true;
      }
    }
  }

  var edgeWorst = 0.0;
  var baseline = 0.0;
  for (var i = 1; i < samples.length; i++) {
    final delta = (samples[i] - samples[i - 1]).abs();
    if (nearEdge[i]) {
      if (delta > edgeWorst) edgeWorst = delta;
    } else {
      if (delta > baseline) baseline = delta;
    }
  }

  // A splice is clean when it is no rougher than the signal around it. The
  // absolute floor keeps the test meaningful on very smooth material, where a
  // near-zero baseline would otherwise make any edge look like an outlier.
  final allowed = (baseline * 1.2).clamp(0.02, kDiscontinuityLimit);
  final passed = edgeWorst <= allowed;

  return _Check(
    'S3 no splice artefacts',
    passed,
    'at gap edges ${edgeWorst.toStringAsFixed(4)}, '
        'elsewhere ${baseline.toStringAsFixed(4)}, '
        'allowed ${allowed.toStringAsFixed(4)}\n'
        '        (global max ${global.toStringAsFixed(4)} — includes any '
        'roughness the stretch stub adds, which is not a splice defect)',
  );
}

/// S4 — reported timings must describe the processed audio.
///
/// Checks that timings are ordered and in range, and that every silence we
/// created coincides with a word boundary rather than falling mid-word. The
/// coincidence test allows a window, because injected silence merges with the
/// engine's own inter-word silence and the combined run's edges therefore sit
/// outside the exact splice point.
_Check _checkTimings(
  Map<String, dynamic> report,
  AudioBuffer audio,
  int? naturalSilences,
) {
  final raw = (report['reportedTimings'] as List?) ?? const [];
  if (raw.isEmpty) {
    return const _Check('S4 timings match audio', false, 'no timings reported');
  }

  final starts = <int>[];
  final ends = <int>[];
  for (final e in raw) {
    final m = e as Map;
    starts.add((m['frameStart'] as num).toInt());
    ends.add((m['frameEnd'] as num).toInt());
  }

  final problems = <String>[];
  final unexplained = <SilenceRun>[];
  var note = '';

  for (var i = 1; i < starts.length; i++) {
    if (starts[i] < starts[i - 1]) {
      problems.add('word $i starts before word ${i - 1}');
    }
  }
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] < 0 || ends[i] > audio.frameCount) {
      problems.add('word $i is outside the buffer '
          '(${starts[i]}..${ends[i]} of ${audio.frameCount})');
    }
  }

  final settings = (report['settings'] as Map?) ?? const {};
  final requestedGap = (settings['gapMs'] as num?)?.toDouble() ?? 0;

  if (requestedGap > 0) {
    final tolerance = audio.msToFrames(kBoundaryToleranceMs);
    final silences = AudioAnalysis.interiorSilences(
      audio,
      minDurationMs: requestedGap * 0.5,
    );

    for (final run in silences) {
      // A boundary anywhere inside the silence, or just outside either edge,
      // means the cut landed between words rather than through one.
      final coincides = ends.any(
            (e) => e >= run.startFrame - tolerance &&
                e <= run.endFrame + tolerance,
          ) ||
          starts.any(
            (s) => s >= run.startFrame - tolerance &&
                s <= run.endFrame + tolerance,
          );
      if (!coincides) unexplained.add(run);
    }

    // Silences the engine made itself are allowed to sit anywhere, including
    // inside a reported word range. Google TTS puts its sentence pause there:
    // it reports the next range only after the pause, so the preceding word's
    // span swallows it.
    //
    // Without a baseline we cannot tell those apart from a misplaced gap, so we
    // report them rather than failing, and say the check was weakened.
    final allowance = naturalSilences ?? 0;
    if (unexplained.length > allowance) {
      for (final run in unexplained.take(4)) {
        problems.add('silence at frame ${run.startFrame} '
            '(${run.durationMs.toStringAsFixed(0)}ms) is at no word boundary');
      }
      if (naturalSilences == null) {
        problems.add('(no --baseline given, so engine-natural pauses cannot '
            'be excluded)');
      }
    } else if (unexplained.isNotEmpty) {
      note = ', ${unexplained.length} engine-natural silence(s) excluded via '
          'baseline';
    }
  }

  return _Check(
    'S4 timings match audio',
    problems.isEmpty,
    problems.isEmpty
        ? '${starts.length} timings ordered, in range, every inserted gap on a '
            'word boundary$note'
        : problems.take(5).join('\n        '),
  );
}

class _Check {
  const _Check(this.name, this.passed, this.detail);

  final String name;
  final bool passed;
  final String detail;

  @override
  String toString() => '${passed ? 'PASS' : 'FAIL'}  $name\n        $detail';
}
