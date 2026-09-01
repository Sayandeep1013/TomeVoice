# 16 — Session Handoff

**As of 2026-09-02.** Everything needed to pick this up cold.

---

## 1. Where the project is

The **audio-engine spike is complete and proven on a real device**, and the reading UI
has been built to the supplied visual reference. There is no reader yet — no EPUB, no
PDF, no library. That is deliberate: the spike existed to prove the architecture before
building on it, and it did.

| Layer | State |
|---|---|
| Pure-Dart audio pipeline | **Done.** 64 tests, analyzer clean |
| Android TTS adapter | **Done.** Word timings captured and verified on device |
| Offline verifier + fixtures | **Done.** Runs in CI |
| Reading UI (specimen design) | **Done.** Renders on device |
| Settings surface | **Done.** Every control drives real DSP |
| CI (Dart + APK) | **Green** |
| Document pipeline (EPUB/PDF/DOCX) | **Not started** — this is Phase 1 |
| Neural voices (Piper/Kokoro) | **Not started** — Phase 3 |
| Windows | **Not started** |

Last commit on `main`: `0dd9931`.

---

## 2. What was proven

**R1 is answered.** Google TTS on Android 16 supplies **per-word** `onRangeStart` with
frame positions — 17 events for a 17-word utterance. This is the best case in the
pre-registered table ([§15.14](15-spike-audio-engine.md#1514-pre-registered-decisions)).

All five measurement criteria pass on real device audio
([§15.18](15-spike-audio-engine.md#1518-device-run-2-on-2026-09-02-all-criteria-met)):

| | Result |
|---|---|
| Gap inserted exactly | 46,080 frames for 120 ms, 96,000 for 250 ms |
| Gap present in audio | 120 ms measures 115–125 ms per boundary |
| **Gap survives speed** | **At 2.0× still 115–125 ms, not 60** |
| No splice artefacts | Edges 0.0507 vs 0.2555 baseline — smoother than the speech |
| Timings match audio | Ordered, in range, every gap on a word boundary |

The third row is the one that matters: it is the property that justified
[ADR-003](10-decisions-adr.md#adr-003) and the whole synthesise-to-PCM architecture.

---

## 3. Four findings that will save the next person days

**1. `onRangeStart` parameters are not in the documented order.** The platform documents
`(utteranceId, start, end, frame)`. Google TTS delivers **`(frame, charStart, charEnd)`**,
matching the engine-side `SynthesisCallback#rangeStart(markerInFrames, start, end)` it
forwards from. The code *detects* the layout rather than assuming either
(`SpeechService.decodeTimings`). Do not "simplify" that away.

**2. Google TTS hides its sentence pause inside a word's range.** It reports the next
range only after the pause, so `'dog'` spans 880 ms for one syllable. Anything reasoning
about silence must not assume every gap is one it created — hence `measure.dart
--baseline`.

**3. Stage order is load-bearing, twice over.** Edge-trim must run *first* (it cannot
distinguish inserted silence from engine padding) and word-gap must run *after* time
stretch (or a 120 ms gap becomes 60 ms at 2×). `ordering_test.dart` encodes both bugs as
well as both fixes.

**4. A green test suite proved nothing about listenability.** S1–S5 all passed on output
that was unusable. See §6.

---

## 4. Running it

There is **no local Flutter or Gradle** by design ([ADR-016](10-decisions-adr.md#adr-016)).

```bash
# Dart SDK is at (winget install path):
#   %LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.DartSDK_.../dart-sdk/bin
# A new terminal picks it up from PATH automatically.

# The part that matters day to day — milliseconds, no Gradle:
cd packages/tomevoice_audio && dart pub get && dart analyze --fatal-infos && dart test

# The verifier, and a synthetic run to exercise it without a device:
cd tools && dart pub get
dart run bin/make_fixture.dart /tmp/fx 120 1.0
dart run bin/measure.dart /tmp/fx
```

**APKs come from CI**, never locally. Push, wait ~4 minutes, then:

```bash
gh run download <run-id> -n tomevoice-spike-apk
adb uninstall app.tomevoice.tomevoice_spike   # required: CI mints a new debug key each run
adb install app-debug.apk
```

**Measurement sweep** (five configurations, exported for offline checking):

```bash
adb shell am start -n app.tomevoice.tomevoice_spike/.MainActivity --es batch true
# wait for BATCH-COMPLETE.txt, then:
adb pull /sdcard/Android/data/app.tomevoice.tomevoice_spike/files/ ./spike-runs/
cd tools
dart run bin/measure.dart ../spike-runs/files/tomevoice-spike-tts-gap120-dsp1_0 \
  --baseline ../spike-runs/files/tomevoice-spike-tts-gap0-dsp1_0
```

> **Git Bash gotcha:** `adb` paths get mangled into `D:/git/Git/sdcard/...`. Prefix with
> `MSYS_NO_PATHCONV=1`. But **unset it before running `git`**, or Windows git cannot
> resolve `/tmp/...` paths.

---

## 5. Code map

```
packages/tomevoice_audio/     PURE DART. No Flutter. Where the real work is.
  lib/src/
    types.dart                AudioBuffer, WordTiming, PipelineSettings
    pipeline.dart             Stage interface + the frame-remap composition
    stages/
      edges.dart              trim engine lead-in            (runs 1st)
      stretch_stub.dart       naive resampler — SEE §6       (runs 2nd)
      word_gap.dart           THE feature                    (runs 3rd)
      punctuation.dart        comma/clause/colon/dash/…      (runs 4th)
      pauses.dart             sentence pause                 (runs 5th)
      gain.dart               volume, trim, levelling, limit (runs 6th)
    wav.dart                  RIFF read/write
    analysis.dart             silence detection, discontinuity, RMS
  lib/tomevoice_audio.dart    buildStandardPipeline() + the 7 presets

app/                          FLUTTER. Only ever built in CI.
  lib/
    main.dart                 entry; reader, or batch sweep via --es batch true
    reader_screen.dart        the reading surface
    settings_panel.dart       the right-edge pop-out
    speech_service.dart       platform calls + onRangeStart layout detection
    theme.dart                Skin: colours, type, Capsule, RoundButton
  android_overlay/            our Kotlin, laid over CI-generated scaffolding
  assets/fonts/               Ojuju + Space Mono, bundled (SIL OFL)

tools/bin/
  measure.dart                offline verifier (does NOT reuse the pipeline)
  make_fixture.dart           synthetic runs, so the verifier is itself testable
tools/prepare_android.py      patches the generated manifest + gradle
```

---

## 6. Known problems — read before building on this

### The speed control has a placeholder in it

`TimeStretchStubStage` is a **naive decimating resampler**. It shifts pitch with speed:
median F0 goes 233 Hz at 1.0× to 436 Hz at 2.0×, an octave up.

It is **not** what the user hears — speed goes through the engine's own rate control by
default, measured at ratio 0.99 (pitch preserved). The stub survives only because S2
needs it to prove stage ordering, and it is labelled *"pitch-shifts!"* in the UI.

**Phase 3 replaces it with a real pitch-preserving stretcher.** GPL libraries are
available to us under [ADR-014](10-decisions-adr.md#adr-014), so this is integration
work, not research ([C-14](09-challenges-and-solutions.md#c-14)).

### Pitch is engine-only

`PipelineSettings.pitchSemitones` is passed to Android's `setPitch`. **Neural voices
expose no pitch control at all**, so this control will do nothing for Piper or Kokoro
until the DSP shifter lands. The UI should grey it out when a neural voice is selected —
it does not yet.

### Voice quality is mediocre and unresolved

The user's verdict on the voices was *"aren't the best ones"*, and that is still open.
Current selection is language-first, then offline, then quality — which fixed a genuinely
bad bug (it was picking an **Arabic** voice for English text) but does not make Google
TTS's offline voices good. Realistic options:

1. Let network voices be chosen when the user opts in — they score materially higher.
2. Ship Piper (Phase 3). This is the actual answer.
3. Surface `Voice.getQuality()` in the picker so the choice is informed.

### Cross-engine variation is unmeasured

The test device registers exactly **one** TTS engine. R1's "does this hold across
engines" half is unanswered. Installing eSpeak TTS from F-Droid and re-running the batch
would settle it in minutes.

### The lesson worth carrying forward

**S1–S5 passed while the app was unusable.** They measured arithmetic and said nothing
about whether a control was wired to the thing it names, whether the voice matched the
text, or whether the result was pleasant to hear. Four defects hid behind green checks —
detailed in [§15.20](15-spike-audio-engine.md#1520-s6-causes-in-full-2026-09-02).

**Listen before claiming success.** Not after.

---

## 7. Decisions already locked

| | |
|---|---|
| Licence | **GPL-3.0**, public repo ([ADR-014](10-decisions-adr.md#adr-014)) — this unlocked eSpeak-NG, the Piper engine, and GPL DSP libraries in one move |
| Framework | Flutter; **Android primary**, Windows second |
| Toolchain | Dart SDK local, APKs in CI ([ADR-016](10-decisions-adr.md#adr-016)) |
| Architecture | Synthesise to PCM, never `speak()` ([ADR-003](10-decisions-adr.md#adr-003)) |
| Visual direction | The specimen aesthetic ([ADR-017](10-decisions-adr.md#adr-017)) |
| DRM | Out of scope, permanently ([ADR-010](10-decisions-adr.md#adr-010)) |

**Still open:** which fonts beyond Ojuju/Space Mono, and the per-voice Piper licence audit
(the only item from [§6.6](06-voice-catalog-and-licensing.md#66-licence-audit-table) that
survived the GPL-3.0 decision unchanged).

---

## 8. What to do next

In order. The first is small and closes a real gap; the second is the actual product.

**A. Settle cross-engine R1** *(~30 minutes)*
Install a second TTS engine, re-run the batch, record the result as Pass 3 in
[14](14-verification-log.md). Cheap, and it either confirms or complicates a decision
already made.

**B. Phase 1 — the EPUB reader** *(~4 weeks,
[roadmap](12-roadmap-and-milestones.md))*
This is the real next step. The spike proved the speech half; the reader half is
well-understood work. Build the Document Model
([§2.4](02-architecture.md#24-contract-a-the-document-model)) and the EPUB parser
([§3.2](03-document-pipeline.md#32-epub)) first — the UI already exists and expects
sentences.

**C. Sentence-by-sentence playback**
The spike speaks one blob of text. The real scheduler
([§2.7](02-architecture.md#27-the-lookahead-scheduler)) synthesises ahead by sentence
so playback never waits. Needed before any document longer than a paragraph.

**D. Phase 3 — neural voices, and a real stretcher**
Piper first (small, fast), Kokoro device-gated. This is also where the speed stub gets
replaced and where voice quality finally gets fixed.

### Do not do these

- Do not start with Kokoro because it is the exciting part. It is worthless without the
  document pipeline and scheduler underneath it.
- Do not "clean up" the `onRangeStart` layout detection into the documented order.
- Do not reorder the pipeline stages without reading `ordering_test.dart` first.

---

## 9. Loose ends from this session

- **The test phone was left in light mode.** I ran `adb shell cmd uimode night no` to
  photograph the light theme and the device disconnected before I could restore it.
  Restore with `adb shell cmd uimode night yes`, or Settings → Display → Dark theme.
- `spike-runs/` and `dist/` are gitignored working directories; delete freely.
- The `spike/audio-engine` branch is pushed and identical to `main` up to `e74b6e7`; it
  can be deleted.
