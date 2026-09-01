# 13 — Testing & QA

The hard part of testing this project is that most of its value lives in two places that
resist ordinary unit tests: **document layout inference** and **audio timing**. "Does the
word gap sound right?" is not an assertion. This document is mostly about making those
two things testable.

## 13.1 The testable-by-construction rule

Both hard areas become testable if they are built as **pure functions over data**:

- Layout analysis is `List<Glyph> -> List<Block>`. No PDFium calls inside the algorithm;
  glyph extraction is a separate, thin, mockable step. That makes reading order testable
  from a JSON fixture with no PDF library in the loop.
- The audio pipeline is `(Float32List, List<WordTiming>, Settings) -> (Float32List,
  List<WordTiming>)`. No device, no playback, no threads. That makes word-gap injection
  testable by measuring the output buffer.

If either is built with the I/O tangled in, it becomes untestable and stays untested.
This is the single most consequential testing decision in the project, and it is an
architectural one, not a QA one.

## 13.2 Document pipeline tests

**Fixture corpus.** A versioned set of real documents with expected outputs, committed to
the repo (or an LFS-tracked companion) and grown from every bug report.

```
test/fixtures/
  epub/  simple/ dropcaps/ footnotes-inline/ rtl/ vertical-jp/
         span-per-word/ mathml/ fixed-layout/ broken-markup/
  pdf/   single-column/ two-column-academic/ three-column-magazine/
         mixed-bands/ footnotes/ running-headers/ hyphenated/
         scanned/ rotated-pages/ tables/
  docx/  tracked-changes/ footnotes/ tables/ textboxes/ fields/
  text/  utf8/ utf16le/ latin1/ no-bom-cp1252/
```

**Reading-order tests.** Each PDF fixture ships an `expected-order.json` listing block
IDs in the correct reading order. The test asserts on the produced sequence and reports a
**percentage match**, not a boolean — because reading order is graded, not binary, and a
94% result on a hard three-column magazine is a pass while 94% on a single-column novel
is a regression.

Thresholds are per-category and enforced in CI:

| Category | Minimum paragraph-order accuracy |
|---|---|
| Single-column born-digital | 99% |
| Two-column academic | 90% |
| Three-column magazine | 75% |
| Mixed bands with figures | 85% |

**Hyphenation tests.** A table-driven fixture of line pairs with expected joins, covering
both directions of the failure: "hyphen-/ation" must join, "well-/being" must not.

**Segmentation tests.** A corpus of sentences with known boundaries per language,
including the abbreviation, quote and bracket cases from
[§3.6](03-document-pipeline.md#36-sentence-and-word-segmentation).

**Normalisation tests.** Table-driven input/output pairs for every rule in
[§3.7](03-document-pipeline.md#37-text-normalisation-for-speech), each also asserting
that the **source-range mapping is preserved** — the alignment map is what keeps
highlighting correct, and a rule that breaks it silently breaks the feature.

## 13.3 Audio pipeline tests

All of these operate on buffers, with no audio device.

**Word gap.** Synthesise (or load a fixture PCM) with known word timings, apply a gap of
*N* ms, then **measure** the silence at each boundary in the output. Assert within ±5 ms.
Repeat across gap values, sample rates and speeds.

**Order of operations.** The classic bug is inserting gaps before time-stretching, so
that a 120 ms gap becomes 60 ms at 2x speed. There is an explicit test: apply speed 2.0
and gap 120 ms together, then measure that the boundary silences are 120 ms, not 60.

**Timing remapping.** After each pipeline stage, assert that the returned word timings
still point at the same audio content. Practical form: mark word boundaries in a
synthetic input signal with impulses, run the pipeline, and check the reported frame
indices land on the impulses.

**Pitch shift.** Feed a known sine tone, shift by *N* semitones, FFT the output, assert
the fundamental moved by the right ratio. Then assert on a speech fixture that the
spectral envelope (formants) has moved *less* than the fundamental — that is what
distinguishes a formant-preserving shift from resampling.

**Loudness normalisation.** Feed fixtures at known integrated loudness levels, assert the
output converges to the target and that the limiter prevents clipping.

**Click detection.** After gap injection and pause insertion, scan for discontinuities
above a threshold. Splicing silence without a cross-fade produces clicks, and a numeric
test catches them long before a human notices.

**Golden files.** For the whole chain, PCM golden files for fixed inputs and settings.
Regenerated deliberately, reviewed by listening when they change. Golden files catch
"something changed"; the measurement tests above explain *what*.

## 13.4 Engine adapter tests

Every adapter runs the same **conformance suite**, which is how we keep Contract B
honest:

1. Returns non-empty PCM for a known sentence.
2. Returns word timings whose count matches the tokeniser's word count.
3. Timings are monotonic, non-overlapping, and inside the buffer.
4. `frameEnd` of the last word is within tolerance of the buffer length.
5. Cancellation returns within 100 ms.
6. Reported `appliedNatively` matches observable behaviour — if it claims native pitch,
   the output pitch actually changed.
7. Repeated identical requests produce identical output (determinism, where the engine
   offers it).
8. Empty, whitespace-only, single-character, and 240-character inputs are all handled.

A new engine is integrated by making it pass this suite. Nothing else in the app needs to
know it exists.

## 13.5 Timing drift measurement

The metric users feel most directly. Automated form:

1. Synthesise a long passage (10+ minutes) through the full pipeline.
2. At each reported word boundary, extract a short window from the output audio.
3. Run a lightweight aligner offline (test-only, not shipped) over the audio and text.
4. Report the distribution of `reported − actual` offsets.

Assert median drift under 50 ms and 95th percentile under 120 ms. Track the numbers over
time; drift regressions arrive gradually and are invisible without a trend.

## 13.6 Platform and integration tests

**Android**

| Test | Method |
|---|---|
| 8-hour background playback | Automated overnight run on physical devices, screen off, asserting continuous progress |
| Foreground service compliance | Instrumented test asserting the correct type and notification |
| Audio focus | Simulated call, notification, other media app; assert duck/pause/resume |
| `BECOMING_NOISY` | Broadcast the intent; assert playback pauses |
| Process death | Force-stop mid-sentence; assert resume within one sentence |
| 16 KB page alignment | CI check on every `.so`, plus a 16 KB emulator smoke run |
| Low-memory device | Run on a 2–3 GB device or emulator; assert the Tier 2 gate holds and no OOM |
| OEM matrix | Manual, on real devices from the known-aggressive manufacturers |

**Windows**

| Test | Method |
|---|---|
| Default device change | Switch default output mid-playback; assert seamless continuation |
| Device removal | Unplug a USB DAC; assert fallback without a crash |
| Sleep/resume | Suspend and wake; assert the device rebuilds and playback continues |
| Media keys | Assert SMTC handlers fire |
| Per-monitor DPI | Move the window between monitors at 100/150/200% |
| Portable mode | Assert no writes outside the app directory |

## 13.7 Accessibility testing

A release gate, not a checklist item, because a meaningful share of the audience depends
on it.

- Full reading flow with TalkBack active, and separately with Narrator.
- **Assert the collision behaviour explicitly**: with a screen reader active, starting
  playback must duck or pause our output during announcements
  ([C-34](09-challenges-and-solutions.md#c-34)).
- Every control reachable and operable by keyboard and D-pad.
- Contrast ratios verified for all themes, including the reading themes.
- Touch targets at least 48 dp.

## 13.8 Performance budgets

Enforced in CI where measurable, tracked as trends otherwise. A budget that is not
measured is a wish.

| Metric | Budget |
|---|---|
| Cold start to library | < 1.5 s |
| EPUB open to first page (5 MB, mid-range Android) | < 2 s |
| PDF open to first page (900 pages) | < 3 s |
| Time to first audio, system voice | < 300 ms |
| Time to first audio, neural voice (warm) | < 1.2 s |
| Highlight drift, median / p95 | < 50 ms / < 120 ms |
| Memory, Tier 1 playback | < 350 MB |
| Base AAB size | < 120 MB |
| Battery, 1 hour Tier 0 playback | < 4% on a reference device |
| Battery, 1 hour Tier 1 playback | < 9% on a reference device |
| Crash-free sessions | > 99.5% |

## 13.9 Manual QA passes

Some things only a human ear catches. Before each release:

- **Listen to a full chapter** at 1.0x, 1.5x and 2.5x, on each voice tier. Listen for
  clicks, robotic artefacts, wrong pauses and mispronunciations.
- **Word-gap sanity** at 120 ms and 250 ms — does it help comprehension or just sound
  broken?
- **The dyslexia and language-learning presets**, ideally with a user from those groups.
- **A book with real footnotes**, checking each skip-rule setting.
- **A multilingual book**, checking voice switching does not flap.
- **A two-column paper**, listening for interleaved columns — this failure is obvious by
  ear and easy to miss by eye.

## 13.10 Feedback loop

Text normalisation and pronunciation are permanently incomplete
([C-19](09-challenges-and-solutions.md#c-19)), so the app needs a fast path from "that
was read wrong" to a fixture:

- A **"report mispronunciation"** action in the reader that captures the sentence, the
  voice, the normalised speech text and the settings.
- Reports become table-driven test cases, so each fix is permanent.
- Users can convert their own report into a local pronunciation entry in the same
  gesture, so they get an immediate fix whether or not we ever ship one.
