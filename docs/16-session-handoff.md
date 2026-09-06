# 16 — Session Handoff

**As of 2026-09-07.** Everything needed to pick this up cold.

---

## 1. Where the project is

The **audio-engine spike is complete and proven on a real device.** Phase 1a is in the
tree and on-device: import EPUB/TXT/Markdown, skip EPUB covers, swipe/skip chapters,
listen sentence-by-sentence, keep your place. There is still no visual EPUB renderer
(no WebView pagination), no PDF speech, no neural voices, no Windows build.

| Layer | State |
|---|---|
| Pure-Dart audio pipeline | **Done.** Analyzer clean, tests green |
| Android TTS adapter | **Done.** Word timings captured. Engine *reused*. One `synthesizeToFile` at a time |
| Document Model + ingest | **Done for EPUB/TXT/MD/HTML.** `packages/tomevoice_document` |
| Library + SAF import | **Done.** `*/*` picker (no MIME whitelist). Encrypted EPUBs refused. PDF/DOCX throw a clear next-phase message |
| Sentence scheduler | **Done, depth 1.** Lookahead starts *after* n is on disk, while n plays from WAV |
| Reading UI | **Done.** Chapter chrome + searchable TOC. Chevrons = sentence. Skip/swipe = chapter |
| Place | **Done.** `books/{id}/cursor.json`. Tap a sentence = play from here |
| Offline verifier + fixtures | **Done.** Runs in CI |
| CI (Dart + APK) | Dart core + Flutter APK. `flutter analyze` fails on deprecations (e.g. `ListView.cacheExtent`) |
| Visual EPUB (WebView, CFI, pagination) | **Not started** — Phase 1b |
| Neural voices (Piper/Kokoro) | **Not started** — Phase 3 |
| Windows | **Not started** |
| Background playback / MediaSession | **Not started** — still dies with the activity |

Install from CI, open **Library**, **Import a file**, pick an EPUB / `.txt` / `.md`.
There is **no Specimen card** on the home screen. The in-app mark and Android launcher
icon live at `app/assets/brand/logo.png` and `app/android_overlay/.../res/`. Chrome:
gradient, capsules, Space Mono instrumentation, Ojuju for titles only (never the page
of a book). Chevrons are sentence, not chapter. Paragraph pause is applied by the
scheduler between `blockId`s (`sentencePauseMs: 0` in the pipeline so it does not stack).

Latest green APK as of this handoff: GitHub Actions run `34054606167`
(`feat`/`fix` on `main` through `bee9bc2`). CI mints a **new debug key each run** —
`adb uninstall` before `adb install`.

---

## 2. What was proven (spike, unchanged)

**R1 is answered** for Google TTS on the test device. See the previous handoff notes
and [§15.18](15-spike-audio-engine.md#1518-device-run-2-on-2026-09-02-all-criteria-met).
Cross-engine R1 (eSpeak etc.) is still unmeasured.

Device-checked in this slice (Nothing A059, serial `00158351M001200`):

- Import *Lord of Mysteries* (`Clown - LotM Vol. 1.epub` from the user's `E:\stories\`)
  → opens on **Chapter 1: Crimson**, `1 OF 213`, not a cover `Image`.
- Chapter skip → **Chapter 2: Situation**.
- Resume + tap-to-start-here on the old Specimen book (before it was removed from home).
- *Crime and Punishment* (Z-Lib EPUB) ingest works (14799 sentences) but the **file is
  OCR-garbled** (`he house`, `pervent`). That is the source, not the reader.

Playback-through-a-chapter after the TTS-overlap fix was **installed** (`bee9bc2`) but
not listened through. **Listen before claiming that bug is gone.**

---

## 3. Findings that will save the next person days

**1. `onRangeStart` parameters are not in the documented order.** Detect the layout
(`SpeechService.decodeTimings`). Do not "simplify" that away.

**2. Google TTS hides its sentence pause inside a word's range.** Do not assume every
gap in the audio is one we created.

**3. Stage order is load-bearing.** Edge-trim first; word-gap after stretch.
`ordering_test.dart` encodes both bugs. Architecture §2.6 now matches this; do not
restore the earlier pitch→stretch→trim sketch.

**4. A green test suite proved nothing about listenability.** Listen before claiming
success.

**5. Re-init of `TextToSpeech` per sentence is unusable.** The adapter keeps the engine
warm. Do not put `tts?.shutdown()` back at the start of `synthesise`.

**6. Android TTS has one progress listener.** Two overlapping `synthesizeToFile` calls
steal it; playback then dies after the first sentence. Lookahead must start **after** n
has finished synthesising, while n *plays from WAV*. `SpeechService.synthesise` is also
single-flight. Do not kick n+1 TTS before n's callback.

**7. EPUB spine is not a chapter list.** Covers, `Image` alt text, TOC sheets, and `●`
part dividers are not chapters. `readingSectionIndexes` / `readingToc` in
`packages/tomevoice_document/lib/src/navigate.dart` skip them. `BlockRole.figure` is in
`defaultSkippedRoles`.

**8. SAF `EXTRA_MIME_TYPES` hides EPUBs.** Android often labels `.epub` as zip /
octet-stream. Picker is `*/*` with no MIME extra.

**9. Do not rebuild the whole reader on every word.** Word highlight is a
`ValueNotifier`. Persist cursor on a 2 s debounce, not every sentence. Lock chapter
`PageView` physics while speaking so a tap does not change chapter.

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

Inspect a real EPUB without Flutter:

```bash
cd packages/tomevoice_document
dart run tool/dump_book.dart "E:\stories\some-book.epub"
```

**APKs come from CI**, never locally. Push, wait ~4 minutes, then:

```bash
gh run download <run-id> -n tomevoice-spike-apk
adb uninstall app.tomevoice.tomevoice_spike   # required: CI mints a new debug key each run
adb install app-debug.apk
```

Uninstall **wipes the library**. Re-import from `/sdcard/Download/` (Clown and Crime
were pushed there). Measurement sweep is unchanged (`--es batch true`).

Maestro flows: `mobile-qa/flows/`. Do not `clearState: true` on resume tests. Selectors
use merged semantics (e.g. `Chapters\nChapter 1: Crimson\n1 OF 213`). Chapter index is
`1 OF 213`, sentence counter is `1 / 34273` — do not assert `1 /` as unique.

---

## 5. Code map

```
packages/tomevoice_audio/     PURE DART. Pipeline, timings remap, presets.
packages/tomevoice_document/  PURE DART. Contract A + EPUB/TXT/MD/HTML ingest.
  lib/src/
    model.dart                Book → Section → Block → Sentence → Word
    ingest.dart               ingestBytes / ingestString
    formats/epub.dart         zip → OPF → spine → blocks
    formats/html_blocks.dart  XHTML → blocks (drop-cap spans join)
    formats/text.dart         TXT / Markdown / HTML
    segment.dart              English-first sentence splitter
    build.dart                flattenSpeakable, skip roles, cursor
    navigate.dart             reading sections, skip covers, readingToc
  test/navigate_test.dart
  tool/dump_book.dart         title, sections, first real chapter
  tool/inspect_file.dart      one-line ingest summary
  tool/emit_qa_epub.dart      writes the fox-book fixture

app/                          FLUTTER. Only ever built in CI.
  lib/
    main.dart                 library, or batch sweep via --es batch true
    brand.dart                logo mark + TOMEVOICE lockup
    library_screen.dart       YOUR BOOKS + import (no Specimen)
    library_store.dart        JSON index, copied files (not Drift yet)
    reader_screen.dart        chapter PageView, searchable TOC, sentence list
    scheduler.dart            depth-1 lookahead, no overlapping TTS
    settings_panel.dart       right-edge pop-out
    speech_service.dart       platform calls, onRangeStart layout, synth mutex
    theme.dart                Skin
  assets/brand/logo.png       in-app mark
  android_overlay/            Kotlin: TTS (reused), play-wait, SAF picker, launcher icon
  test/widget_test.dart       pumps ReaderScreen with specimenBook() as a fixture only

tools/                        offline verifier, make_fixture, prepare_android.py
mobile-qa/                    Maestro config + flows
```

---

## 6. Known problems — still true, plus what the user still feels

- Playback can still **stop after one line** or hitch; the overlap fix is in tree and
  installed, **not listened through a chapter**. That is the first thing next session.
- The reader still **lags on tap** on a 200-chapter EPUB (34k speakable units in RAM,
  JSON `parsed.json`, DSP on the UI isolate). Word-highlight setState is gone; the rest
  is not.
- SAF DocumentsUI is still a hunt (Recent vs Downloads). Import works; the picker UX
  does not.
- Large EPUB import is slow (Clown ~13 MB, ~34k sentences).
- Z-Lib *Crime and Punishment* is a bad OCR copy. Use Clown / Gutenberg-quality files
  to judge the reader.
- PDF/DOCX are refused with a message. Speaking PDFs is Phase 4.
- `TimeStretchStubStage` pitch-shifts. Speed defaults to the engine. Phase 3 replaces it.
- Pitch is engine-only. Grey it out for neural voices when those exist.
- Google TTS offline voices are mediocre. Piper is the actual answer (Phase 3).
- Cross-engine R1 is unmeasured.
- Playback is in-process MediaPlayer. The app will not keep reading with the screen off
  or after swipe-away. That is Phase 2 foreground-service work, not a regression.
- EPUB CFI strings are placeholders (`epubcfi(/6/...)`), not spec-accurate.
- Sentence segmentation is English-first, not ICU.
- Library persistence is JSON, not Drift. Uninstall wipes it.
- TOC can list duplicate titles (`I`, `II` per part) because that is the spine.

**Listen before claiming success.** Not after.

---

## 7. Decisions already locked

Unchanged: GPL-3.0, Flutter, Android primary, Dart locally / APKs in CI, synthesise-to-PCM,
specimen *visual language* (Ojuju titles, serif page — not a Specimen book on home),
DRM out of scope.

---

## 8. What to do next

In order.

**A. Listen.** Open Clown on the phone, Play from Chapter 1, and stay through several
sentences and a chapter skip. If it still dies after one line, grab `adb logcat` for
`TTS_QUEUE` / `TTS_ERROR` and the scheduler status chip. Do not add features until that
is honest.

**B. Then the remaining 1a pain:** import picker, open-book jank, huge-book memory.

**C. Phase 1b — the visual EPUB reader**
WebView, pagination, real CFIs, search. The Document Model is already there; do not
re-parse.

**D. Phase 2 remainder — stay-alive speech**
Foreground service, MediaSession, lock-screen controls.

**E. Phase 3 — neural voices, and a real stretcher**
Piper first. Replace the speed stub.

### Do not do these

- Do not start with Kokoro.
- Do not "clean up" the `onRangeStart` layout detection.
- Do not reorder the pipeline stages without reading `ordering_test.dart`.
- Do not shut down `TextToSpeech` at the start of every `synthesise` call.
- Do not start n+1 `synthesizeToFile` before n has returned PCM.
- Do not put Specimen back on the library home.
- Do not make the sentence chevrons skip chapters.
- Do not build a silent WebView reader that throws away the scheduler.

---

## 9. Loose ends

- Cross-engine R1 (install eSpeak from F-Droid, re-run the batch) is still cheap and undone.
- `spike-runs/` and `dist/` are gitignored; delete freely. Do not commit APKs.
- The `spike/audio-engine` branch can still be deleted if it exists remotely.
- QA leftovers: `mobile-qa/scratch/`, `report.xml`, incomplete flows
  `import-clown.yaml` / `import-pdf.yaml` / `tap-clown.yaml` are untracked on purpose.
- User books live on the laptop at `E:\stories\` (Clown EPUB, Crime EPUB, PDFs, audio).
  Do not delete those. Device copies were under `/sdcard/Download/`.
