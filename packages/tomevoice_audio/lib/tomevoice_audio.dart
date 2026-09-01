/// Pure-Dart audio pipeline for TomeVoice.
///
/// Takes PCM plus word timings from any TTS engine and applies word-gap
/// injection, punctuation and sentence pauses, gain and loudness levelling,
/// remapping the timings through every stage so highlighting stays aligned with
/// what the listener hears.
///
/// No Flutter dependency: this builds and tests with the standalone Dart SDK
/// (see docs/10 ADR-016).
library;

import 'src/pipeline.dart';
import 'src/stages/edges.dart';
import 'src/stages/gain.dart';
import 'src/stages/pauses.dart';
import 'src/stages/punctuation.dart';
import 'src/stages/stretch_stub.dart';
import 'src/stages/word_gap.dart';
import 'src/types.dart';

export 'src/analysis.dart';
export 'src/pipeline.dart';
export 'src/stages/edges.dart';
export 'src/stages/gain.dart';
export 'src/stages/pauses.dart';
export 'src/stages/punctuation.dart';
export 'src/stages/stretch_stub.dart';
export 'src/stages/word_gap.dart';
export 'src/types.dart';
export 'src/wav.dart';

/// The standard pipeline, in the one order that is correct.
///
/// Three ordering constraints, all learned the hard way:
///
/// 1. **Edge trimming first.** It finds the engine's lead-in silence by looking
///    for the first audible sample. Run it after anything that inserts silence
///    and it cannot tell ours from the engine's — it deletes the gaps. That is
///    exactly what the first device run did.
///
/// 2. **Word gap after time stretching.** Reversed, the inserted silence is
///    scaled by the speed setting and a 120 ms gap becomes 60 ms at 2x.
///
/// 3. **Gain last.** Loudness levelling should see the finished buffer, not an
///    intermediate one.
///
/// Punctuation pauses sit after the word gap so the two are additive: a comma
/// gets the word gap *and* the comma pause, which is what a user adjusting both
/// expects.
///
/// `ordering_test.dart` pins these so a refactor cannot quietly undo them.
Pipeline buildStandardPipeline(PipelineSettings settings) => Pipeline([
      EdgeTrimStage(enabled: settings.trimEdges),
      TimeStretchStubStage(settings.speedScale),
      WordGapStage(settings),
      PunctuationPauseStage(
        text: settings.text,
        pauses: settings.punctuation,
        crossfadeMs: settings.crossfadeMs,
      ),
      SentencePauseStage(settings.sentencePauseMs),
      GainStage(
        volume: settings.volume,
        trimDb: settings.trimDb,
        normalise: settings.normaliseLoudness,
        compression: settings.compression,
      ),
    ]);

/// Named starting points, so the full control surface is optional rather than
/// mandatory. Most people should never need to open the panel.
///
/// Values come from docs/05 section 5.11.
class SpeechPreset {
  const SpeechPreset(this.id, this.label, this.description, this.settings);

  final String id;
  final String label;
  final String description;
  final PipelineSettings settings;

  static const natural = SpeechPreset(
    'natural',
    'Natural',
    'How the voice was meant to sound',
    PipelineSettings(),
  );

  static const audiobook = SpeechPreset(
    'audiobook',
    'Audiobook',
    'Longer breaths, gentle levelling',
    PipelineSettings(
      sentencePauseMs: 500,
      paragraphPauseMs: 900,
      punctuation: PunctuationPauses(commaMs: 200, clauseMs: 160),
      compression: Compression.light,
    ),
  );

  static const study = SpeechPreset(
    'study',
    'Study',
    'Slower, with room to take notes',
    PipelineSettings(
      speedScale: 0.9,
      wordGapMs: 60,
      sentencePauseMs: 600,
      punctuation: PunctuationPauses(commaMs: 220, clauseMs: 180, colonMs: 300),
    ),
  );

  static const skim = SpeechPreset(
    'skim',
    'Skim',
    'Fast, minimal pauses',
    PipelineSettings(
      speedScale: 2.0,
      sentencePauseMs: 200,
      punctuation: PunctuationPauses(commaMs: 60, clauseMs: 50, colonMs: 80),
    ),
  );

  /// Wide word spacing and slow, even pacing. This preset is the reason the
  /// word-gap feature exists at all.
  static const dyslexia = SpeechPreset(
    'dyslexia',
    'Dyslexia',
    'Wide word spacing, even pacing',
    PipelineSettings(
      speedScale: 0.85,
      wordGapMs: 150,
      sentencePauseMs: 700,
      punctuation: PunctuationPauses(commaMs: 250, clauseMs: 200),
    ),
  );

  static const language = SpeechPreset(
    'language',
    'Learning',
    'Very slow, words clearly separated',
    PipelineSettings(
      speedScale: 0.7,
      wordGapMs: 250,
      sentencePauseMs: 900,
      punctuation: PunctuationPauses(commaMs: 350, clauseMs: 300, colonMs: 400),
    ),
  );

  static const night = SpeechPreset(
    'night',
    'Night',
    'Quieter, evened out, no sharp peaks',
    PipelineSettings(
      speedScale: 0.95,
      sentencePauseMs: 400,
      trimDb: -6,
      compression: Compression.strong,
    ),
  );

  static const all = <SpeechPreset>[
    natural,
    audiobook,
    study,
    skim,
    dyslexia,
    language,
    night,
  ];
}
