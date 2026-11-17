# 13 — Testing & QA

The hard part of testing this project is that most of its value lives in two places that
resist ordinary unit tests: **document layout inference** and **audio timing**. "Does the
word gap sound right?" is not an assertion. This document is mostly about making those
two things testable.

Sections 13.1 to 13.10 are the plan of 2026-09-01, each with an **As built** note for
1.4.0. What runs today, in short:

| Where | What | Runs |
|---|---|---|
| `packages/tomevoice_audio/test/` | the pipeline at the buffer level: word gap, stage order, remap, punctuation, loudness, WSOLA, the pause aligner, WAV | CI's `dart-core` job, and locally with the plain Dart SDK |
| `packages/tomevoice_document/test/` | every format, detection, encodings, segmentation, language, navigation, notes, the reading layout; `corpus/`, real books against goldens | the same |
| `tools/` | the spike's verifier, round-tripped on synthetic runs | CI's `dart-core` job |
| `app/test/` | 71 widget and unit test files, with local WebDAV, KOReader and OPDS servers for sync and catalogues | CI's `android-apk` job, before the APK is built |
| `mobile-qa/` | Maestro flows and the Back and Recents tests on Android 14 and 16 emulators | CI, on pull requests and manual runs (13.11) |
| the developer's phone | listening, and what no emulator has: real sites, a fingerprint, the phone's own voices and natural voices at speed | by hand, before each release ([16](16-session-handoff.md)) |

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

**As built.** Both held. The pipeline is exactly that function, in a package with no
Flutter. PDF layout is Dart over the platform's text and line layout, so the corpus keeps
a PDF as the platform's output (`*.pdftext.json`) and tests it with no PDF library in the
loop.

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

**As built.** One test file per format and per stage in `packages/tomevoice_document/test/`,
and a **corpus** of real files (`test/corpus/`: EPUB, KF8, TXT in several encodings, DOCX,
ODT, RTF, FB2, HTML, Markdown, and PDFs as the platform's extracted text), each with a
golden of what the parser made of it and the whole spoken text. `corpus_test.dart` fails
on any change in what is read and names the first line that changed; checks written by
hand cover what a listener would notice (front matter not read, notes shown and not read,
chapters in the order of the contents). Goldens are rewritten on purpose with
`TOMEVOICE_UPDATE_GOLDENS=1 dart test test/corpus_test.dart`; the corpus README says how
and where each file came from. There are no reading-order percentages per category.

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

**As built.** In `packages/tomevoice_audio/test/`: `word_gap_test` (gaps measured within
±5 ms, zero gap bit-identical, no discontinuity added), `ordering_test` (stretch then gap
gives 120 ms at 2x, gap then stretch 60 ms: the bug encoded so a refactor cannot bring it
back; edge trim first), `remap_test` (the impulse trick: a signal silent but for an
impulse at each word boundary, every reported boundary landing on its impulse ±2 frames),
`pauses_test`, `punctuation_test`, `loudness_test`, `stretch_test` (WSOLA keeps a tone's
pitch within 3% while the stub moves it),
`align_test` (the pause aligner), `analysis_test` and `wav_roundtrip_test`. No pitch-shift
tests (there is no shifter) and no PCM golden files.

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

**As built.** No shared conformance suite. The pieces that can be tested without a device
are: the `onRangeStart` layout detection, the voice picking order, natural voices on a
stand-in worker (`natural_voices_test`, `voices_test`), and the spike's verifier for
exported device audio (13.13). The real engines are heard on the phone.

## 13.5 Timing drift measurement

The metric users feel most directly. Automated form:

1. Synthesise a long passage (10+ minutes) through the full pipeline.
2. At each reported word boundary, extract a short window from the output audio.
3. Run a lightweight aligner offline (test-only, not shipped) over the audio and text.
4. Report the distribution of `reported − actual` offsets.

Assert median drift under 50 ms and 95th percentile under 120 ms. Track the numbers over
time; drift regressions arrive gradually and are invisible without a trend.

**As built.** Not built as a long-passage measurement. When the pause aligner was made,
sharing a sentence out by character count was measured against an engine's own timings
(271 ms out on average, 610 ms at worst), which is why it was replaced
([04 §4.7](04-tts-engine-contract.md#47-deriving-word-timings-for-neural-engines)).

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

**As built.** Android: the emulator job (13.11) covers Back, a swipe from Recents (reading
and paused) and a headset's Play with the app closed, on Android 14 and 16, plus a crash
check; the 16 KB check runs on every APK. Audio focus, Bluetooth, process death, low-memory
phones and the OEM matrix are checked by hand on the developer's phone, where at all.
Windows: not started.

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

**As built.** `accessibility_test` and `tap_targets_test` in `app/test/`; contrast is
computed (`contrast.dart`, WCAG 2.2) and every palette, the reader's own colours included,
is kept readable by construction. TalkBack reads and turns the pages (1.3.0). A TalkBack
pass is not a release gate, and the collision with TalkBack is not handled
([C-34](09-challenges-and-solutions.md#c-34)).

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

**As built.** None of these is enforced in CI. What has been measured: a saved place's
cost on the UI thread with 1,000 books (`place_writes_test`,
[11 §11.4](11-data-model-and-storage.md#114-places)), CPU and memory per voice on the
developer's phone ([04 §4.5](04-tts-engine-contract.md#45-adapter-piper-via-sherpa-onnx)),
and frame pacing on the phone (`dumpsys SurfaceFlinger --latency`) while scrolling. There
is no crash reporting: errors go to a log on the phone that the reader can read and send
([16](16-session-handoff.md)).

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

**As built.** Each release is checked on the developer's phone (a Nothing A059, Android
16) before it goes out: what changed, by tapping through it, with screenshots as proof,
and by ear. Android 14 and 15 behaviour is checked only on CI's emulators. Risky checks
(a restore, secret shelves, imports) use the separate test app (13.12), never the
developer's own library.

## 13.10 Feedback loop

Text normalisation and pronunciation are permanently incomplete
([C-19](09-challenges-and-solutions.md#c-19)), so the app needs a fast path from "that
was read wrong" to a fixture:

- A **"report mispronunciation"** action in the reader that captures the sentence, the
  voice, the normalised speech text and the settings.
- Reports become table-driven test cases, so each fix is permanent.
- Users can convert their own report into a local pronunciation entry in the same
  gesture, so they get an immediate fix whether or not we ever ship one.

**As built.** The local fix exists (press and hold a word, "Fix how it's said"); the report
does not. About → Report a problem shows the recent errors from the phone's error log (no
titles, no text) and opens a filled-in GitHub issue for the reader to send.

## 13.11 Device flows and the emulator job

Maestro flows live in `mobile-qa/flows/`. They drive the app by what is on screen, its
visible text and Flutter's semantics (labels, button tooltips), never by coordinates, and
none of them clears the app's data.

| Flow | What it checks |
|---|---|
| `library-starter.yaml` | The shelf shows the starter book, Pride and Prejudice (a new install) |
| `open-reader.yaml` | The book's page opens, and **Read** opens the reader with its top bar |
| `rotate-reader.yaml` | Landscape and back: the reader is still showing, nothing crashed |
| `contents-sheet.yaml` | The title in the reader's bar opens the contents; Back closes them |
| `reading-settings.yaml` | **Reading settings** opens; its Listen tab shows speed and the sleep timer |
| `listen-from-home.yaml` | Opened from the launcher, **Listen**, then the app's own Back buttons to the shelf: where the Back test starts |
| `listen-to-library.yaml` | The same, TomeVoice opened by another app (Maestro) instead of the launcher |

`common/` holds the subflows they share: launch to the shelf (`library`, which waits for
the starter book), skip the first-run guide (`skip-guide`), wait for the starter's two web
novels to arrive and take their places so no tap lands where a book just was
(`settled-shelf`), open from the launcher's list of apps (`from-home`), the shelf to the
book's page (`open-book`, `book-page`), and Listen then back to the shelf
(`listen-and-return`).

Writing selectors:

- Maestro matches a selector as a whole-string, case-insensitive regular expression against
  an element's text, hint or content description.
- Flutter merges a widget's texts into one description, joined by newlines. The shelf tile
  reads `Pride and Prejudice\nPride and Prejudice\nJane Austen\n…` and the reader's title bar
  `Contents\nPride and Prejudice\n…`, hence `.*Pride and Prejudice.*Jane Austen.*`, which
  also tells the shelf tile from the Continue dock (no author there).
- A button with a tooltip and no label is described by its tooltip: `Back to library`,
  `Reading settings`, `Add books`.
- Buttons that wait for something (the book page's Listen and Read wait for the book's
  layout) are matched with `enabled: true`.

### Running them on a phone

With the phone on adb and TomeVoice installed:

```bash
maestro test mobile-qa/flows/open-reader.yaml
```

They run on the library on that phone: they open Pride and Prejudice (`library-starter`
passes only while it is still on the shelf), the two `listen-` flows read it aloud and so
move its place, and `rotate-reader` turns auto-rotate off. To keep the real library out of
it, install the test app (§13.12) and add `-e APP_ID=app.tomevoice.test`.

The Back test by hand, after `listen-from-home`:

```bash
adb shell input keyevent KEYCODE_BACK
adb shell dumpsys activity activities | grep -A12 "tomevoice_spike.MainActivity"
```

No record: MainActivity was destroyed. `state=STOPPED ... finishing=false`: it only moved
to the back. (The activity's class keeps the template's package,
`app.tomevoice.tomevoice_spike`, whatever the app id.)

### The emulator job

On pull requests and manual runs (not on pushes to main), `build.yml` builds the app for an
x86_64 emulator and runs it on Android 14 and Android 16:

- `emulator-apk` builds exactly as the release job does (the pinned Flutter, the
  scaffolding, the overlay, the lockfile) with `TV_ABIS=x86_64` and
  `--target-platform android-x64`, signed with the throwaway debug key. It never sees a
  secret and is never published.
- `emulator-test` boots API 34 and API 36 (`google_apis` x86_64 images, Pixel 6 profile,
  KVM) with reactivecircus/android-emulator-runner, installs Maestro (a pinned release,
  checked against its SHA-256) and runs `mobile-qa/ci/emulator-tests.sh`:
  1. installs the APK and records which text-to-speech engines the image has;
  2. runs each flow above on a cleared app (`pm clear`, as if just installed); the
     landscape screenshot from `rotate-reader` must be wider than tall;
  3. runs the Back test after each `listen-` flow, and the Recents test after the first;
  4. fails if TomeVoice shows up in the crash log.

  A loaded CI emulator can put a system app's "isn't responding" dialog over everything
  (the Pixel Launcher did once, and every flow failed behind it), so the script sets
  `hide_error_dialogs` (Android then kills a process that stops responding instead of
  asking; a TomeVoice hang still fails its flow) and closes system dialogs before each flow.

Each check is a row in the run's summary. The `emulator-results-api-NN` artifact holds
screenshots, Maestro's output (a screenshot before every step, the view hierarchy on a
failure), the dumpsys snapshots and logcat. A failed check fails the job, but nothing waits
for it: the release APKs build and release whatever it says.

### The Back test

Back on the library leaves the app, and must never stop the book being read. Before 1.3.0
it did: whatever finished MainActivity on the way out stopped the reading too, as its
`onDestroy` ended the reading service, the player and TTS.

- **Android 15 and older.** Flutter answered that Back with `SystemNavigator.pop()`, which
  calls `Activity.finish()` on a `FlutterActivity`.
- **Android 16** (an app targeting SDK 36 gets predictive back). With nothing in Flutter to
  pop, Flutter's back callback is unregistered and the activity's own system callback takes
  the Back. Android then moves the task to the back only if the home screen launched the
  activity (`ActivityClientController.shouldMoveTaskToBack` asks for
  `LAUNCH_SOURCE_TYPE_HOME` and a main intent); otherwise it finishes it. Opened from the
  launcher, TomeVoice kept reading, which is why the developer's phone never showed the
  bug; started any other way (seen when another app starts it), it stopped as on
  Android 14.

**The fix (1.3.0).** `MainActivity.popSystemNavigator` moves the task to the
back instead of finishing it, and on Android 13 and later the activity registers its own
back callback that does the same, so Android's predictive back puts TomeVoice behind
however it was opened. Since 1.4.0 the reading belongs to the cached Flutter engine, not the
activity, so even a finished activity no longer stops it ([07 §7.2](07-platform-android.md#72-background-playback)).
The test stays, to keep it that way.

The test runs twice per Android version, from the shelf with the book being read aloud
(the images have Google's TTS engine): after `listen-from-home` (the reader's way in, the
asserted one) and after `listen-to-library` (opened by another app, reported as a warning,
not a failure). It presses Back, then decides from `logcat -b events` (`wm_finish_activity`,
`wm_destroy_activity` for MainActivity) and `dumpsys activity activities` (its record and
state) whether MainActivity was destroyed or moved to the back, and logs the media session
and the reading service before and after. It reports one line, such as
`BACK TEST: activity destroyed on API 34`, and a destroyed activity fails the job.

What it found on the main of 2026-10-30 (1.2.2), before the fix, reading aloud with
Google's TTS (build run 41073818634):

| | Opened from the launcher | Opened by another app |
|---|---|---|
| Android 14 (API 34) | destroyed: `wm_finish_activity … app-request`, `wm_destroy_activity`; reading stops | destroyed, the same |
| Android 16 (API 36) | kept: `wm_pause_activity … pauseBackTasks`, `wm_stop_activity`, no finish; the media session stays `PLAYING(3)` and the service runs | destroyed: `wm_finish_activity … app-request`; the session and service are gone |

On API 36 the window's top back callback at that moment was the activity's system one
(`mPriority=-1` in `CoreBackPreview`), not Flutter's (`mPriority=0`, registered only
while a route could pop): the system, not Flutter, made each call.

### The Recents test

Since 1.4.0 the voice is the cached Flutter engine's (`ReadingCore`), which
outlives MainActivity while a book is read ([07 §7.2](07-platform-android.md#72-background-playback)). Right after the Back test from
the launcher, with the book still reading and TomeVoice behind, the script runs three
checks, each with `dumpsys` snapshots (`swipe-*`, `swipe-paused-*`, `headset-*`):

| Check | How | Expected | On failure |
|---|---|---|---|
| `SWIPE TEST` | TomeVoice's task removed with `am stack remove <task>` (the `removeTask` a swipe in Recents calls; the task from `am stack list`, else `dumpsys activity recents`) | The process alive and the media session still `PLAYING(3)` | Fail (a warning if it was not reading before) |
| `SWIPE TEST, paused` | Opened again with `am start` (the activity rejoins the running engine), `KEYCODE_MEDIA_PAUSE`, the task removed | The paused book put away: `ReadAloudService` no longer in the foreground, the session neither playing nor paused | Warning |
| `HEADSET PLAY, app closed` | `KEYCODE_MEDIA_PLAY` (dispatched by the system as a headset's is), 20 s | Reading again (`PLAYING(3)` or `BUFFERING(6)`): the session's media button receiver started the service, which started the engine at `backgroundMain` | Warning |

A crash anywhere on these paths (a foreground service not started in time, say) fails
the run's crash check.

## 13.12 Reproducible builds

- CI pins Flutter 3.47.8 and Dart 3.13.7 (the Dart inside that Flutter) in `build.yml`'s
  `env`, and every action by commit, its release in a comment.
- All four `pubspec.lock` files are committed, and every `pub get` in CI is
  `--enforce-lockfile`: the lockfile is the resolution, and each download is checked against
  its hash. `flutter_qjs`, a git package, resolves to the commit its lockfile names.
- After changing a `pubspec.yaml` or the pinned SDKs, re-resolve with the pinned SDKs (the
  app needs Flutter, which only CI has) and commit what comes back. Until then the build
  stops at "Resolve dependencies (locked)".

  ```bash
  gh workflow run build.yml --ref <branch> -f relock=true
  gh run download <run-id> -n pubspec-locks   # from the repository root
  ```

- After the build, "Check the APKs" prints each APK's id, size (and the latest release's)
  and signing certificate. An APK with `org/bouncycastle/pqc/` entries fails it, and so does,
  on a release run, an APK not signed with the TomeVoice key (`TV_CERT_SHA256`): it would
  not install over the last version.

### The test app

```bash
gh workflow run build.yml --ref <branch> -f variant=test
gh run download <run-id> -n tomevoice-test-apk
adb install -r TomeVoice-test.apk
```

A 64-bit APK of a separate app, `app.tomevoice.test` ("TomeVoice Test"), signed with the
same key so each test build installs over the last. It sits beside TomeVoice with a library
of its own (the starter book arrives on its first launch), so a risky build or a flow never
touches the reader's books. It is never attached to a release.

## 13.13 The audio spike

The first thing built (2026-09-01 and 02) was not the reader but the part nothing on paper
could prove: that owning the PCM ([ADR-003](10-decisions-adr.md#adr-003)) works on a real
phone. It set out three risks. **R1**: does Android's `onRangeStart` deliver per-word frame
positions on real engines? **R2**: does splicing silence into speech sound acceptable, or
click and smear? **R3**: do the timings survive every stage, so the highlight stays on the
word?

**The criteria, measured, not judged**, as they stood after the build corrected them:

| | Criterion | Threshold |
|---|---|---|
| **S1a** | The gap stage inserts exactly what was asked | inserted frames == boundaries × gap frames, exactly |
| **S1b** | That silence is in the audio | every silence between words at least the gap, less 5 ms |
| **S2** | The gap survives a speed change | 120 ms at 2.0x still measures 120 ms, not 60 |
| **S3** | No splice artefacts | discontinuity at the gap edges no worse than the buffer's own |
| **S4** | The timings match the processed audio | ordered, in range, every inserted silence on a word boundary |
| **S5** | What the engine reports is known | a report naming the engine, whether `onRangeStart` fired, and how often |
| **S6** | It sounds right | a person listens at 0, 120 and 250 ms and hears separated speech, not damaged speech |

Three were reworded during the build, each because a test or the verifier showed the first
wording was wrong. Real speech already has silence between words, so 120 ms of gap beside
30 ms of natural spacing measures 150 ms: S1 became an exact frame count plus an "at least"
check on the audio. A single discontinuity threshold blamed the resampling stub's own
roughness on the splices (a run with no gap at all "failed"): S3 now compares the gap edges
with the rest of the buffer. Natural and injected silence merge, so run edges sit off the
exact splice: S4 asks only that a boundary lies within the silence.

**The verifier.** `tools/bin/measure.dart` checks an exported run (a WAV and its JSON
report) against S1 to S5 from the *audio*, not from what the app believed it did, and
shares no code with the pipeline it checks, so a bug cannot certify itself. Silence is RMS
over a 5 ms window below −50 dB relative to the buffer's peak, in runs of 20 ms or more.
`--baseline` takes the same engine's 0 ms run, to allow for silences the engine makes
itself. `tools/bin/make_fixture.dart` makes synthetic runs, and CI round-trips the verifier
on them (120 ms at 1x and 2x, 250 ms, 0 ms) to guard the measuring instrument itself. One
bug found while building it: `Future<int> main` does not set a process exit code, so it
printed FAIL and exited 0, which in CI would have been a green build over a failed
measurement; it calls `exit()`.

```bash
cd tools && dart pub get
dart run bin/make_fixture.dart /tmp/fx 120 1.0
dart run bin/measure.dart /tmp/fx
dart run bin/measure.dart <run> --baseline <the same engine's 0 ms run>
```

**On the phone.** The app still has the sweep (`BatchScreen` in `app/lib/main.dart`):
started with `--es batch true`, it makes one fixed text once per engine and speed mode,
runs it through each gap setting, and writes a WAV and JSON pair per configuration and a
`BATCH-COMPLETE.txt`, for `adb pull` and the verifier. It runs only in a debug build
(`!kReleaseMode`), and CI builds release APKs only.

**Results on 2026-09-02** (Nothing A059, Android 16, Google's TTS, the only engine on it):

| Criterion | Result |
|---|---|
| S1a | 46,080 frames inserted for 120 ms, 96,000 for 250 ms, 0 for 0 ms: exact |
| S1b | 120 ms asked: 115 to 125 ms at every boundary; 250 ms: 245 to 265 ms |
| S2 | at 2.0x, still 115 to 125 ms |
| S3 | gap edges 0.0507 against 0.2555 for the speech around them: five times smoother |
| S4 | 17 timings, ordered and in range, every gap on a word boundary |
| S5 | `onRangeStart` fired a word at a time, 17 events, its frame first ([04 §4.3](04-tts-engine-contract.md#43-adapter-android-system-tts)) |

The run before found what no Dart test could: the parameter order, and the edge trim
running last, where it took the injected silence for lead-in and cut it (46,204 frames
trimmed just after 46,080 were inserted). The per-stage frame counts turned "the word-gap
setting does nothing" into a five-minute diagnosis. Edge trim now runs first.

**S6 failed while S1 to S5 passed.** The listener found the voice poor and the settings
apparently dead. Four causes, none of which any criterion measured:

1. Play replayed the first export it had made (a cached path never cleared), whatever the
   sliders said.
2. The speed slider went through the resampling stub, raising the voice nearly an octave
   at 2x. Speed moved to the engine's own rate, which kept the pitch.
3. Forcing `Locale.US` selected a small embedded fallback voice on a phone without US
   English data.
4. The fix for 3 picked an Arabic voice for English text (it sorted by quality and name,
   and `ar-` sorts first). The language became the first key.

**The lesson kept:** a criteria suite that can be fully green on broken output is
under-specified. The arithmetic said nothing about whether a control was wired to the thing
it names, whether the voice matched the text, or whether it was pleasant to hear. Listening
comes before claiming success, not after.
