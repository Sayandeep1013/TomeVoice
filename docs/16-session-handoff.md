# 16 — Session Handoff

**As of 2026-09-06.** Everything needed to pick this up cold.

---

## 1. Where the project is

The **audio-engine spike is complete and proven on a real device.** Phase 1a — a
speakable document — is in the tree: import EPUB/TXT/Markdown, listen sentence by
sentence, keep your place. There is still no visual EPUB renderer (no WebView
pagination), no PDF, no neural voices, no Windows build.

| Layer | State |
|---|---|
| Pure-Dart audio pipeline | **Done.** Analyzer clean, tests green |
| Android TTS adapter | **Done.** Word timings captured and verified on device. Engine is now *reused* across sentences. |
| Document Model + ingest | **Done for EPUB/TXT/MD/HTML.** `packages/tomevoice_document` |
| Library + SAF import | **Done.** Copied into app storage; encrypted EPUBs refused |
| Sentence scheduler | **Done, depth 1.** Lookahead of one sentence; flush on control change |
| Reading UI (specimen design) | **Done.** Speaks the current sentence of a real book |
| Offline verifier + fixtures | **Done.** Runs in CI |
| CI (Dart + APK) | Dart core covers *audio + document*. APK job unchanged |
| Visual EPUB (WebView, CFI, pagination) | **Not started** — Phase 1b |
| Neural voices (Piper/Kokoro) | **Not started** — Phase 3 |
| Windows | **Not started** |
| Background playback / MediaSession | **Not started** — still dies with the activity |

Install from CI as before, open **Library**, tap **Specimen** to hear the pangram, or
**Import a file** and pick an EPUB / `.txt` / `.md`. The in-app mark and Android
launcher icon live at `app/assets/brand/logo.png` and
`app/android_overlay/.../res/` (adaptive + mipmap). Chrome is one language on
library and reader: gradient, capsules, Space Mono instrumentation, Ojuju for
titles only (never the page of a book). Chevrons are sentence, not section.
Paragraph pause is applied by the scheduler between blocks.

---

## 2. What was proven (spike, unchanged)

**R1 is answered** for Google TTS on the test device. See the previous handoff notes
and [§15.18](15-spike-audio-engine.md#1518-device-run-2-on-2026-09-02-all-criteria-met).
Cross-engine R1 (eSpeak etc.) is still unmeasured.

---

## 3. Four findings that will save the next person days

**1. `onRangeStart` parameters are not in the documented order.** Detect the layout
(`SpeechService.decodeTimings`). Do not "simplify" that away.

**2. Google TTS hides its sentence pause inside a word's range.** Do not assume every
gap in the audio is one we created.

**3. Stage order is load-bearing.** Edge-trim first; word-gap after stretch.
`ordering_test.dart` encodes both bugs. Architecture §2.6 now matches this; do not
restore the earlier pitch→stretch→trim sketch.

**4. A green test suite proved nothing about listenability.** Listen before claiming
success.

**5. (new) Re-init of `TextToSpeech` per sentence is unusable.** The adapter now keeps
the engine warm. Do not put `tts?.shutdown()` back at the start of `synthesise`.

---

## 4. Running it

There is **no local Flutter or Gradle** by design ([ADR-016](10-decisions-adr.md#adr-016)).

```bash
cd packages/tomevoice_audio && dart pub get && dart analyze --fatal-infos && dart test
cd packages/tomevoice_document && dart pub get && dart analyze --fatal-infos && dart test

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

Measurement sweep is unchanged (`--es batch true`).

---

## 5. Code map

```
packages/tomevoice_audio/     PURE DART. Pipeline, timings remap, presets.
packages/tomevoice_document/  PURE DART. Contract A + EPUB/TXT/MD/HTML ingest.
  lib/src/
    model.dart                Book → Section → Block → Sentence → Word
    ingest.dart               ingestBytes / ingestString
    formats/epub.dart         zip → OPF → spine → blocks
    formats/text.dart         TXT / Markdown / HTML
    segment.dart              English-first sentence splitter
    build.dart                flattenSpeakable, skip roles, cursor

app/                          FLUTTER. Only ever built in CI.
  lib/
    main.dart                 library, or batch sweep via --es batch true
    brand.dart                logo mark + TOMEVOICE lockup
    library_screen.dart       shelf + import
    library_store.dart        JSON index, copied files (not Drift yet)
    reader_screen.dart        specimen reading surface, one sentence at a time
    scheduler.dart            sentence lookahead, flush on control change
    settings_panel.dart       right-edge pop-out
    speech_service.dart       platform calls + onRangeStart layout detection
    theme.dart                Skin
  assets/brand/logo.png       in-app mark
  android_overlay/            Kotlin: TTS (reused), play-wait, SAF picker, launcher icon

tools/                        offline verifier, make_fixture, prepare_android.py
```

---

## 6. Known problems — still true

- `TimeStretchStubStage` pitch-shifts. Speed defaults to the engine. Phase 3 replaces it.
- Pitch is engine-only. Grey it out for neural voices when those exist.
- Google TTS offline voices are mediocre. Piper is the actual answer (Phase 3).
- Cross-engine R1 is unmeasured.
- Playback is in-process MediaPlayer. The app will not keep reading with the screen off
  or after swipe-away. That is Phase 2 foreground-service work, not a regression.
- EPUB CFI strings are placeholders (`epubcfi(/6/...)`), not spec-accurate. Good enough
  to address a block; not good enough to survive a WebView reflow.
- Sentence segmentation is English-first, not ICU.
- Library persistence is JSON, not Drift.

**Listen before claiming success.** Not after.

---

## 7. Decisions already locked

Unchanged: GPL-3.0, Flutter, Android primary, Dart locally / APKs in CI, synthesise-to-PCM,
specimen visual, DRM out of scope.

---

## 8. What to do next

In order.

**A. Use the APK.** Import a real EPUB you own. Listen through a chapter. That is the
acceptance test for 1a. If synthesis stalls, or a book parses empty, that is the bug.

**B. Phase 1b — the visual EPUB reader**
WebView, pagination, real CFIs, search. The Document Model is already there; do not
re-parse.

**C. Phase 2 remainder — stay-alive speech**
Foreground service, MediaSession, lock-screen controls. Without this it is a
foreground toy.

**D. Phase 3 — neural voices, and a real stretcher**
Piper first. Replace the speed stub.

### Do not do these

- Do not start with Kokoro.
- Do not "clean up" the `onRangeStart` layout detection.
- Do not reorder the pipeline stages without reading `ordering_test.dart`.
- Do not shut down `TextToSpeech` at the start of every `synthesise` call.
- Do not build a silent WebView reader that throws away the scheduler.

---

## 9. Loose ends

- Cross-engine R1 (install eSpeak from F-Droid, re-run the batch) is still cheap and undone.
- `spike-runs/` and `dist/` are gitignored; delete freely.
- The `spike/audio-engine` branch can still be deleted if it exists remotely.
