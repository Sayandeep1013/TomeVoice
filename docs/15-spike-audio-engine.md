# 15 — Spike Spec: Audio Engine

**The first thing we build.** Not the reader — the part that everything else depends on
and that nothing in the documentation can prove.

## 15.1 Why this first

[ADR-003](10-decisions-adr.md#adr-003) commits the whole architecture to owning the PCM:
synthesise to a buffer, run our own pipeline, run our own player. That decision was
forced by one requirement — word-gap control, which no engine offers
([C-12](09-challenges-and-solutions.md#c-12)) — and it is expensive. It costs us audio
focus, ducking, interruption, device handling and buffering, all of which `speak()` would
have given us free.

If that architecture does not work, we want to know in week 3, not week 12.

Building the EPUB reader first (the order in
[12 — Roadmap](12-roadmap-and-milestones.md)) is defensible on product grounds — an
unpleasant reader cannot be rescued by good TTS. But it puts the *unknown* at week 7.
This spike inverts that. The reader is well-understood work; the audio pipeline is not.

## 15.2 The three risks

| | Risk | Why it is unknown | If it fails |
|---|---|---|---|
| **R1** | Does Android's `onRangeStart` actually deliver per-word frame positions on real engines? | Verified in the API contract, but the docs state it is *"Only called if the engine supplies timing information"*. Engines are not obliged to, and OEM engines vary | Word-level highlighting on system voices is off the table; everything falls back to estimation and [C-13](09-challenges-and-solutions.md#c-13) escalates from S1 to project-shaping |
| **R2** | Does PCM-level gap injection sound acceptable, or does it click and smear? | Splicing silence into speech at arbitrary points is not obviously artefact-free | The headline feature degrades. We would need per-word synthesis, which flattens prosody |
| **R3** | Does timing remapping survive the pipeline so highlighting stays aligned? | Each stage changes the frame count; composing the remaps correctly is easy to get subtly wrong | Highlighting drifts whenever a setting changes — the classic bug this architecture exists to avoid |

R1 is the genuine unknown. R2 and R3 are engineering we expect to succeed but must verify.

## 15.3 Success criteria

The spike succeeds when all of these are true, **measured, not judged**:

| # | Criterion | Threshold |
|---|---|---|
| **S1a** | The gap stage inserts exactly what was asked | Inserted frames == `boundaries × gapFrames`, **exactly** |
| **S1b** | That silence is genuinely in the audio | Every inter-word silence ≥ the requested gap, less a 5 ms tolerance |
| S2 | Gap survives a simultaneous speed change | 120 ms gap at 2.0× still measures 120 ms of *injected* silence, **not 60** |
| S3 | No splice artefacts introduced | Discontinuity **at the gap edges** no worse than the buffer's own baseline |
| S4 | Reported word timings match the processed audio | Timings ordered, in range, and every inserted silence coincides with a word boundary |
| S5 | We know what the engine actually reports | A machine-readable report naming the engine, whether `onRangeStart` fired, and at what granularity |
| S6 | It is audibly correct | A human listens to 0 / 120 / 250 ms gap and confirms it sounds like separated speech, not damaged speech |

**S1 is split, and S3 and S4 are looser than first drafted — all three because the first
formulations were wrong.** Implementation showed why; see the build log in §15.16.

S6 is deliberately subjective and deliberately last. S1–S5 can all pass while the result
sounds wrong; only listening settles it.

## 15.4 Scope

**In:**
- Pure-Dart audio pipeline: gap injection, pause insertion, timing remap, WAV I/O,
  silence measurement
- A stub time-stretch (resampling, pitch-shifting — *not* the real WSOLA) purely to prove
  stage ordering and remap composition
- Android system TTS adapter in Kotlin: `synthesizeToFile` + `onRangeStart`, plus an
  `onAudioAvailable` variant to compare
- A one-screen Flutter app with a fixed sentence, sliders, play, and a debug readout
- WAV + JSON export for off-device measurement
- GitHub Actions building a debug APK

**Out:**
- EPUB, PDF, any document handling
- Neural voices, sherpa-onnx, model downloads
- Real time-stretch or pitch-shift (Phase 3)
- Windows, the library, settings persistence, background playback
- Any visual design — the [specimen aesthetic](10-decisions-adr.md#adr-017) starts at
  Phase 1. **This screen is deliberately ugly.**

## 15.5 Repository layout

```
tomevoice/
  packages/
    tomevoice_audio/            PURE DART. No Flutter. This is where the work is.
      lib/
        tomevoice_audio.dart
        src/
          types.dart            AudioBuffer, WordTiming, SynthesisResult
          pipeline.dart         Stage interface, composition, remap chaining
          stages/
            word_gap.dart       THE feature
            pauses.dart         punctuation + sentence silence
            stretch_stub.dart   naive resample, ordering proof only
            edges.dart          trim + fade
          wav.dart              read/write 16-bit and float WAV
          analysis.dart         silence detection, discontinuity scan, RMS
      test/
        fixtures.dart           synthetic speech + impulse-marked buffers
        word_gap_test.dart      analysis_test.dart
        remap_test.dart         pauses_test.dart
        ordering_test.dart      wav_roundtrip_test.dart
      pubspec.yaml
  app/                          FLUTTER. Only ever built in CI.
    lib/main.dart               the one screen
    android_overlay/            our Android sources, laid over the generated
      app/src/main/kotlin/app/tomevoice/tomevoice_spike/MainActivity.kt
    pubspec.yaml
  tools/
    bin/measure.dart            offline verifier for adb-pulled artefacts
    bin/make_fixture.dart       synthetic runs, to test the verifier itself
    prepare_android.py          patches the generated manifest and gradle
    pubspec.yaml
  .github/workflows/build.yml
  docs/
```

The split is load-bearing: `packages/tomevoice_audio` has no Flutter dependency, so it
builds and tests with the standalone Dart SDK and no Gradle
([ADR-016](10-decisions-adr.md#adr-016)).

## 15.6 Core types

```dart
class AudioBuffer {
  final Float32List samples;   // mono, -1.0..1.0
  final int sampleRate;
  int get frameCount => samples.length;
  Duration get duration =>
      Duration(microseconds: frameCount * 1000000 ~/ sampleRate);
}

enum WordTimingSource { engineReported, modelDurations, aligned, estimated }

class WordTiming {
  final int charStart, charEnd;   // into the request text
  final int frameStart, frameEnd; // into the buffer
  final WordTimingSource source;
}

class SynthesisResult {
  final AudioBuffer audio;
  final List<WordTiming> wordTimings;
  final Set<Capability> appliedNatively;
  final String engineId;
}
```

## 15.7 The pipeline contract

Every stage returns its output **and** a function mapping old frame positions to new
ones. Composing those functions is what keeps highlighting honest
([§2.6](02-architecture.md#26-the-audio-pipeline)).

```dart
typedef FrameRemap = int Function(int oldFrame);

class StageResult {
  final AudioBuffer audio;
  final FrameRemap remap;
}

abstract class PipelineStage {
  String get name;
  StageResult process(AudioBuffer input, List<WordTiming> timings);
}

/// Applies stages in order and remaps timings through every one of them.
class Pipeline {
  final List<PipelineStage> stages;

  SynthesisResult run(SynthesisResult input) {
    var audio = input.audio;
    var timings = input.wordTimings;
    for (final stage in stages) {
      final r = stage.process(audio, timings);
      audio = r.audio;
      timings = timings.map((t) => WordTiming(
        charStart: t.charStart, charEnd: t.charEnd,
        frameStart: r.remap(t.frameStart),
        frameEnd:   r.remap(t.frameEnd),
        source: t.source,
      )).toList();
    }
    return SynthesisResult(audio: audio, wordTimings: timings, /* ... */);
  }
}
```

**Stage order is fixed and tested** — see criterion S2:

```
stretch (stub)  ->  word gap  ->  pauses  ->  edges
```

Gap injection must come **after** stretching. Reversed, a 120 ms gap becomes 60 ms at 2×
speed. `ordering_test.dart` exists specifically to catch a future refactor from
reordering them.

## 15.8 Word-gap algorithm

```
for each boundary between word[i] and word[i+1]:
    1. candidate = word[i].frameEnd
    2. snap: search +/- 5 ms for the lowest-energy frame, preferring a
       zero crossing. Never move past word[i+1].frameStart.
    3. copy source up to the snap point
    4. apply a 4 ms fade-out on the tail
    5. append gapMs of silence
    6. apply a 4 ms fade-in to the resumed audio
    7. accumulate the offset for the remap function
```

Three details that matter:

- **Zero-crossing snap** prevents the click that a hard splice produces. Cheap, and it
  removes most of R2 on its own.
- **The fades are short and symmetric.** Longer fades sound like the speech is being
  ducked rather than separated.
- **Never insert inside a word.** With `estimated` timings a boundary can land
  mid-phoneme; the snap window is clamped so it cannot cross into the next word.

## 15.9 The Kotlin adapter

The only part that needs a device, and the only part that answers R1.

```kotlin
// Returns a WAV path plus every range event the engine reported.
fun synthesise(
    text: String,
    engineId: String?,
    rateScale: Float,
    pitchScale: Float
): SynthesisReport

data class RangeEvent(val start: Int, val end: Int, val frame: Int)

data class SynthesisReport(
    val wavPath: String,
    val engineId: String,
    val rangeEvents: List<RangeEvent>,
    val rangeStartFired: Boolean,
    val granularity: String,   // "word" | "utterance" | "none"
    val sampleRate: Int,
    val frameCount: Int
)
```

Implementation notes:

- Use `synthesizeToFile` with a per-utterance ID. Register an
  `UtteranceProgressListener` and capture **every** `onRangeStart` callback verbatim —
  we are measuring the engine, not trusting it.
- Callbacks do **not** run on the main thread. Collect into a thread-safe list, publish
  on `onDone`.
- **Do not use SSML.** With SSML, `start`/`end` index the SSML string rather than the
  plain text, which would corrupt the character mapping
  ([§4.3](04-tts-engine-contract.md#43-adapter-android-system-tts)).
- Enumerate installed engines via `TextToSpeech.getEngines()` and let the UI switch
  between them — **R1 is a per-engine question**, so testing exactly one engine answers
  nothing.
- Also implement an `onAudioAvailable` path behind a toggle, to see whether it removes
  the file round-trip.

## 15.10 The measurement protocol

This is what makes the spike a measurement rather than a demo.

The app writes two files per run into app-external storage:

```
tomevoice-spike-<timestamp>.wav     the fully processed output
tomevoice-spike-<timestamp>.json    what happened
```

```jsonc
{
  "engineId": "com.google.android.tts",
  "deviceModel": "...",
  "androidVersion": 36,
  "text": "The quick brown fox jumps over the lazy dog.",
  "settings": { "gapMs": 120, "speedScale": 2.0, "sentencePauseMs": 350 },
  "rangeStartFired": true,
  "granularity": "word",
  "rangeEvents": [ { "start": 0, "end": 3, "frame": 0 }, /* ... */ ],
  "timingSource": "engineReported",
  "sampleRate": 24000,
  "rawFrameCount": 48000,
  "processedFrameCount": 52640,
  "expectedInsertedFrames": 4640,
  "reportedTimings": [ { "charStart": 0, "charEnd": 3,
                         "frameStart": 0, "frameEnd": 5200 }, /* ... */ ]
}
```

Then, on the development machine:

```bash
adb pull /sdcard/Android/data/.../files/ ./spike-runs/
dart run tools/measure.dart ./spike-runs/tomevoice-spike-<ts>
```

`measure.dart` reads both files and asserts S1–S4 independently of the app's own belief
about what it did. **It must not share code with the pipeline it is checking** — a shared
bug would validate itself.

Silence detection: RMS over a 5 ms sliding window, threshold at −50 dBFS relative to the
buffer peak; contiguous runs above a 20 ms floor are gaps.

## 15.11 Test plan

Pure Dart, run locally, no device:

**47 test cases across six files**, all passing.

| File | Asserts |
|---|---|
| `word_gap_test` | Gaps of 60/120/250/400 ms each measured within ±5 ms; zero gap is bit-identical; exact output length; no discontinuity introduced; snapping recovers from 8 ms-late timings; corrupt timings cannot produce an invalid buffer; splits stay strictly increasing when words collapse |
| `ordering_test` | **stretch→gap gives 120 ms at 2×; gap→stretch gives 60 ms.** Encodes the bug so a refactor cannot silently reintroduce it. Also pins the shipped stage order, and checks 0.75/1.5/2.0/3.0× |
| `remap_test` | Impulse-marked signal: every reported boundary lands on an impulse ±2 frames, through the gap stage and through the full pipeline. Composition equals manual chaining. Insertion remap boundary conditions. Monotonicity and in-range |
| `pauses_test` | Sentence silence appended, existing frames unmoved, samples preserved exactly; edge trim removes lead-in but keeps a 5 ms run-up |
| `wav_roundtrip_test` | float32 lossless; pcm16 within half an LSB; clamping on overshoot; unknown chunks skipped; stereo downmix; clear rejection of non-WAV |
| `analysis_test` | Silence detector finds known-length silences; ignores sub-minimum runs; relative threshold makes loud and quiet voices agree; discontinuity and RMS behave on constructed signals |

Plus a **verifier round-trip** in CI: `make_fixture.dart` builds a synthetic run and
`measure.dart` checks it, at 120 ms/1×, 120 ms/2×, 250 ms/1× and 0 ms/1×. This guards the
measuring instrument — if it regresses, every result it later certifies is worthless.

The **impulse trick** for `remap_test`: build a signal that is silent except for
single-sample impulses at each word boundary. Run the pipeline. Every reported boundary
frame should land on an impulse. This tests remap correctness without needing real speech
or a real engine.

## 15.12 CI

```yaml
name: build
on: [push, pull_request]

jobs:
  dart-core:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
        working-directory: packages/tomevoice_audio
      - run: dart analyze --fatal-infos
        working-directory: packages/tomevoice_audio
      - run: dart test
        working-directory: packages/tomevoice_audio

  android-apk:
    runs-on: ubuntu-latest
    needs: dart-core
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
        working-directory: app
      - run: flutter build apk --debug
        working-directory: app
      - uses: actions/upload-artifact@v4
        with:
          name: tomevoice-spike-apk
          path: app/build/app/outputs/flutter-apk/app-debug.apk
```

`dart-core` runs in well under a minute and is the gate that matters day to day. The APK
job only runs after it passes, so a broken pipeline never produces an installable build.

Free and unmetered because the repository is public
([ADR-014](10-decisions-adr.md#adr-014)).

## 15.13 The app screen

One screen, no design:

```
+------------------------------------------+
|  [ engine v ]  Google TTS                |
|                                          |
|  Text: "The quick brown fox jumps over   |
|         the lazy dog."                   |
|                                          |
|  Word gap      [=====O--------]  120 ms  |
|  Speed         [======O-------]  1.00 x  |
|  Sentence pause[===O----------]  350 ms  |
|                                          |
|         [ SYNTHESISE ]  [ PLAY ]         |
|                                          |
|  --- report -------------------------    |
|  onRangeStart fired   : YES              |
|  granularity          : word (9 events)  |
|  timing source        : engineReported   |
|  raw frames           : 48000            |
|  processed frames     : 52640            |
|  measured gaps (ms)   : 121 119 120 120  |
|                         118 121 120 119  |
|  max discontinuity    : 0.031            |
|                                          |
|  [ EXPORT WAV + JSON ]                   |
+------------------------------------------+
```

The report panel is the point. The sliders exist to generate cases for it.

## 15.14 Pre-registered decisions

What we do with each R1 outcome, decided **now**, before we have a result — so the answer
is not rationalised after the fact.

| Outcome | Meaning | Action |
|---|---|---|
| **Word granularity on Google TTS and at least one other engine** | Best case | Proceed as documented. Word-level highlighting on system voices in v1 |
| **Word granularity on Google TTS only** | Workable | Proceed, but the highlighting promise becomes engine-conditional. UI must show which engines support it. Update [C-13](09-challenges-and-solutions.md#c-13) |
| **Utterance granularity only** | Timings are useless for gaps | Gap injection falls back to estimation everywhere. Highlighting drops to sentence level on *all* voices. **Re-open [ADR-015](10-decisions-adr.md#adr-015)** and consider promoting forced alignment from "opt-in later" to "required in v1" |
| **`onRangeStart` never fires** | Contract B has no free source anywhere | Escalate C-13 to project-shaping. Either ship estimation-only and drop word-level highlighting from the product promise entirely, or commit to a CTC aligner in v1 — a materially bigger project. **Stop and re-decide with the user** |

The last row is why this spike goes first.

## 15.15 Definition of done

- [ ] `packages/tomevoice_audio` passes `dart analyze --fatal-infos` and `dart test`
- [ ] All nine tests in §15.11 written and passing
- [ ] CI green on both jobs; APK downloadable as an artifact
- [ ] APK installs on a physical device via `adb install`
- [ ] At least **three** TTS engines exercised, results recorded per engine
- [ ] WAV + JSON exported and pulled for at least: 0 ms, 120 ms, 250 ms gap at 1.0×, and
      120 ms at 2.0×
- [ ] `tools/measure.dart` confirms S1–S4 on every exported run
- [ ] S6 satisfied — a human has listened and signed off
- [ ] Findings written up in [14 — Verification Log](14-verification-log.md) as Pass 2,
      including the R1 outcome and which pre-registered branch we are on
- [ ] Any documentation invalidated by the results is corrected

The last two are not optional. The spike's output is **knowledge**, and knowledge that
does not reach the documents is knowledge we will lose.

---

## 15.16 Build log — 2026-09-01

The pure-Dart core, the verifier and CI are complete. **S1–S4 are proven in Dart**;
S5 and S6 need a device.

### What implementation changed about the spec

Four things were wrong in the first draft. Each was caught by a test or by running the
verifier, not by re-reading the document.

**1. The gap measurement conflated two kinds of silence.** Real speech already has
silence between words, and injected silence merges with it. A 120 ms gap in a fixture
with 30 ms of natural spacing measures **150 ms** — correct output, failing an
equality check. Split into S1a (exact frame arithmetic from the stage trace, immune to
natural silence) and S1b (acoustic, asserting the silence is *at least* what was asked).

**2. S3 was measuring the wrong signal.** A global discontinuity threshold conflates a
click we introduced with roughness the signal already had. Diagnosed by generating a run
with **gap = 0 at 2× speed — no splices at all** — which still measured 0.1017 and
"failed". The roughness was entirely the naive resampling stretch stub. S3 now compares
discontinuity *at the gap edges* against the buffer's own baseline. At 2× the splices
measure 0.0742 against a 0.1017 baseline: they are **smoother than the surrounding
audio**, which is what zero-crossing snapping and short fades should produce.

**3. S4's alignment test was too strict** for the same merged-silence reason: a combined
natural-plus-injected run has edges that sit outside the exact splice point. It now
asserts a word boundary lies within the silence run rather than exactly on its edge.

**4. `Future<int> main` does not set a process exit code.** The verifier printed
`FAIL` and exited **0**. In CI that would have been a green build over a failing
measurement — the worst possible failure mode for a measuring instrument. Now uses
`exit()`.

### Bugs found in our own code

| Where | Bug | How it surfaced |
|---|---|---|
| `word_gap.dart` | Fade-in applied to the destination *before* `setRange` copied audio over it, so it scaled silence and was then overwritten | Spotted while re-reading the splice loop; fades are now applied after the copy |
| `wav.dart` | Encoder scaled positives by 32767, decoder divided by 32768 — a systematic 1.5 LSB round-trip loss | `wav_roundtrip_test` failed by 3.6e-5 against a 3.05e-5 tolerance. Made symmetric |

### The stretch stub's roughness is expected

The naive linear-resampling stub aliases at high speed factors — 0.1017 discontinuity at
2×, against 0.0510 at 1×. This is the stub's known deficiency, not a pipeline defect, and
it is why Phase 3 replaces it with a proper pitch-preserving stretcher. GPL-licensed
libraries are available to us under [ADR-014](10-decisions-adr.md#adr-014), so this is
ordinary integration work rather than the open problem it used to be
([C-14](09-challenges-and-solutions.md#c-14)).

### Current state against §15.15

| Item | Status |
|---|---|
| `dart analyze --fatal-infos` clean | **Done** — core and tools |
| Nine tests written and passing | **Exceeded** — 47 cases across six files |
| Verifier proves S1–S4 | **Done** on synthetic runs at 1× and 2× |
| CI green on both jobs | **Written, not yet run** — needs the first push |
| APK installs on a device | **Pending** |
| Three engines exercised | **Pending — this is R1** |
| Exports pulled and measured | **Pending** |
| S6 human listen | **Pending** |

Everything remaining needs a physical Android device. The Dart half is finished and
self-verifying.
