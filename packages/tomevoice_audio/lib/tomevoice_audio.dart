/// Pure-Dart audio pipeline for TomeVoice.
///
/// Takes PCM plus word timings from any TTS engine and applies word-gap
/// injection, pause shaping and edge treatment, remapping the timings through
/// every stage so highlighting stays aligned with what the listener hears.
///
/// No Flutter dependency: this builds and tests with the standalone Dart SDK
/// (see docs/10 ADR-016).
library;

import 'src/pipeline.dart';
import 'src/stages/edges.dart';
import 'src/stages/pauses.dart';
import 'src/stages/stretch_stub.dart';
import 'src/stages/word_gap.dart';
import 'src/types.dart';

export 'src/analysis.dart';
export 'src/pipeline.dart';
export 'src/stages/edges.dart';
export 'src/stages/pauses.dart';
export 'src/stages/stretch_stub.dart';
export 'src/stages/word_gap.dart';
export 'src/types.dart';
export 'src/wav.dart';

/// The standard pipeline, in the one order that is correct.
///
/// Word-gap injection **must** follow time stretching. Reversed, the inserted
/// silence is scaled by the speed setting and a 120 ms gap becomes 60 ms at 2x.
/// `ordering_test.dart` pins this so a future refactor cannot quietly swap them.
Pipeline buildStandardPipeline(PipelineSettings settings) => Pipeline([
      TimeStretchStubStage(settings.speedScale),
      WordGapStage(settings),
      SentencePauseStage(settings.sentencePauseMs),
      EdgeTrimStage(enabled: settings.trimEdges),
    ]);
