# 16 — Session Handoff

**As of 2026-10-22.** Everything needed to pick this up cold.

---

## 1. Where the project is

**As of 2026-10-22** (branch `ux-speed-overhaul`): the reader was rebuilt for speed and
for being obvious to use, and it now opens nearly every document format. Speech streams
gaplessly, follows the voice word by word, and keeps going with the screen off.

| Layer | State |
|---|---|
| Pure-Dart audio pipeline | **Done.** `WavCodec.pcm16Bytes` added for the streaming player |
| Android TTS adapter | **One warm engine** for engines, voices and synthesis. Callbacks filtered by utterance id; `cancelSynthesis` aborts a sentence on seek |
| Player | **Streaming `AudioTrack`** (`PcmPlayer.kt`). Gapless, real pause/resume, position from the playback head |
| Scheduler | Keeps ~10 s queued ahead. Highlight = hardware position, not a timer. DSP on a background isolate |
| Screen off | **`ReadAloudService`** (mediaPlayback foreground service) + MediaSession: notification, lock screen, headset buttons |
| Document Model + ingest | **EPUB, PDF, DOCX, ODT, MOBI/AZW/AZW3 (PalmDOC), FB2, RTF, HTML, MD, TXT.** Script-based language detection |
| Segmentation | Multilingual (danda, CJK, Arabic stops); sentences capped at 280 chars at a clause boundary |
| Library | Import/parse/load on background isolates. Compact `parsed.json` v2 (Clown 15 MB -> 4.9 MB). Older books re-parsed once on open |
| Reading UI | Continuous scroll (`scrollable_positioned_list`), sentence + word wash, tap-to-read, follow mode with "Back to reading", contents sheet, player bar |
| Settings | One "Listening" sheet: speed, voice (for the book's language), style presets, fine-tune. **Persisted** in `prefs.json` |
| CI | **Release** APK, arm64 only, Gradle cache. Builds on `main`, PRs, or manual dispatch; docs-only changes skip |
| Visual EPUB (WebView, CFI, pagination) | **Not started** |
| Neural voices (Piper/Kokoro) | **Not started** |
| Windows | **Not started** |

Measured before this work (debug APK, Clown EPUB, Nothing A059): opening the book froze
the UI ~2.5 s; 650-760 ms of dead air *between every pair of sentences* (per-sentence WAV +
new `MediaPlayer` + a full-tree rebuild that scanned all 34k units three times); a WAV
leaked per sentence (30 found, 80 MB folder).

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
`ValueNotifier`. Persist cursor on a debounce, not every sentence. Each paragraph
widget listens for the cursor itself and rebuilds only when the spoken sentence enters,
leaves or moves within it.

**10. A debug APK is not a performance test.** Debug Flutter is unoptimised JIT with
asserts. CI builds `--release` now. Judge latency only on a release build.

**11. Never feed the player per-sentence files.** The streaming track is what makes
sentences gapless and pause possible. Queue PCM; read the playback head for "what is
audible". Do not reintroduce `play(path, wait: true)`.

**12. `Isolate.run` closures must be created in a top-level function.** A closure made
inside a method can share a context with other captured variables (callbacks holding
widget state), which cannot be sent. See `_runImport` / `_runLoad` in `library_store.dart`.

**13. `flutter analyze` treats deprecations as failures.** Check locally before pushing
(see §4); a CI round trip costs several minutes.

**15. PdfBox's paragraph marks are not paragraphs.** On the device, a simple PDF came
out one line per paragraph, which makes the voice pause at every line. `formats/pdf.dart`
reflows: a paragraph continues unless it ends a sentence or is a heading.

**14. EPUB copyright pages are untitled and long.** `_looksLikeCopyrightPage` in
`navigate.dart` skips them (Red Rising opened on "This is a work of fiction").

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

**APKs come from CI**, never locally. Pushes to `main` build automatically; for a
branch run it by hand:

```bash
gh workflow run build.yml --ref <branch>
gh run download <run-id> -n tomevoice-apk
adb install -r app-release.apk
```

**Signing.** With the repo secrets `TV_KEYSTORE_B64` and `TV_KEYSTORE_PASSWORD` set,
every release APK is signed with the same key and `adb install -r` upgrades in place,
keeping the library. Without them CI signs with a throwaway key and you must
`adb uninstall` first, which **wipes the library**. The keystore lives outside the repo
at `~/.tomevoice/` on the developer's laptop.

**Checking Dart before pushing** without installing Flutter permanently: unzip a Flutter
SDK into a temp folder, copy `app/` + `packages/` next to each other, run the same
`flutter create` as CI, then `dart analyze --fatal-infos` (Flutter's own `analyze` trips
over long Windows paths) and `flutter test`. Delete the SDK afterwards.

Maestro flows: `mobile-qa/flows/`. Do not `clearState: true` on resume tests. Selectors
use merged semantics (e.g. `Chapters\nChapter 1: Crimson\n1 OF 213`). Chapter index is
`1 OF 213`, sentence counter is `1 / 34273` — do not assert `1 /` as unique.

---

## 5. Code map

```
packages/tomevoice_audio/     PURE DART. Pipeline, timings remap, presets, PCM16 for the player.
packages/tomevoice_document/  PURE DART. Contract A + every ingest format.
  lib/src/
    model.dart                Book -> Section -> Block -> Sentence (compact JSON: 'sb')
    ingest.dart               ingestBytes / ingestPdfText, language resolved at the end
    detect.dart               magic bytes first: PDF, RTF, MOBI, zip (EPUB/DOCX/ODT/FB2)
    language.dart             script -> language (bn, hi, ar, ru, ja, ...)
    segment.dart              multilingual sentences, 280-char cap at a clause
    navigate.dart             reading sections: skip covers, TOC, copyright pages
    reading_layout.dart       units/items/chapter tables the reader uses (O(1) lookups)
    formats/epub.dart  html_blocks.dart (+ lenient tag-soup fallback)
    formats/text.dart         TXT (encodings, one-line paragraphs, chapters), Markdown
    formats/office.dart       DOCX, ODT
    formats/pdf.dart          page text -> book (headers, page numbers, outline chapters)
    formats/mobi.dart  fb2.dart  rtf.dart

app/                          FLUTTER. Built in CI; analyzed/tested locally (see 4).
  lib/
    main.dart                 library, or batch sweep via --es batch true
    library_screen.dart       shelf: Continue card, books, Add books, Open-with
    library_store.dart        JSON index; import/load on background isolates
    reader_screen.dart        BookLoader, reading list, player bar, contents sheet
    listen_sheet.dart         speed / voice / style / fine-tune
    scheduler.dart            streaming scheduler, position-driven highlight
    speech_service.dart       platform API, synth mutex, background render
    voices.dart               VoiceCatalog (shared), friendly voice names
    prefs.dart                persisted listening settings
    theme.dart  brand.dart
  android_overlay/app/
    src/main/kotlin/.../MainActivity.kt      TTS, focus, import, intents
    src/main/kotlin/.../PcmPlayer.kt         streaming AudioTrack
    src/main/kotlin/.../ReadAloudService.kt  foreground service + MediaSession
    src/main/kotlin/.../PdfText.kt           PdfBox-Android text + outline
    proguard-rules.pro                        R8 keeps for PdfBox
  test/widget_test.dart       reader, sheet, voices, store (real isolates)

tools/prepare_android.py      manifest/gradle patches: service, intents, PdfBox, signing
```

---

## 6. Known problems

- **Kotlin was reviewed, not compiled locally.** The first CI build is its compiler.
- **Scanned PDFs** (page images) are refused with a message; there is no OCR.
- **Legacy-font Bengali PDFs** (Bijoy/SutonnyMJ, not Unicode) extract as Latin
  gibberish. That is the file's encoding, not the extractor; converting it is its own job.
- **Old .doc** and **HUFF/CDIC-compressed Kindle** books are refused with a message.
- No visual EPUB pages, images or footnote links; text only.
- Highlight lead on Bluetooth: the playback head does not include headset latency, so
  the word can run ~100-200 ms ahead on Bluetooth.
- `TimeStretchStubStage` pitch-shifts; speed is always the engine's. Phase 3 replaces it.
- Google TTS offline voices are mediocre. Piper is the actual answer (Phase 3).
- Library persistence is JSON, not Drift.
- Cross-engine R1 is unmeasured.

---

## 7. Decisions already locked

Unchanged: GPL-3.0, Flutter, Android primary, Dart locally / APKs in CI, synthesise-to-PCM,
specimen *visual language* (Ojuju titles, serif page — not a Specimen book on home),
DRM out of scope.

---

## 8. What to do next

**A. Listen on the device.** Chapter-long listen with the screen off; pause from the lock
screen; a phone call mid-sentence; headphones unplugged. Open a PDF and a DOCX.

**B. Phase 1b — the visual EPUB reader** (WebView, CFIs, images). The reading layout
and scheduler are reusable; do not re-parse.

**C. Phase 3 — neural voices and a real time-stretcher.** Piper first.

### Do not do these

- Do not start with Kokoro.
- Do not "clean up" the `onRangeStart` layout detection.
- Do not reorder the pipeline stages without reading `ordering_test.dart`.
- Do not shut down `TextToSpeech` per call; one warm engine serves everything.
- Do not start n+1 `synthesizeToFile` before n has returned (or been cancelled).
- Do not go back to a file + MediaPlayer per sentence.
- Do not build a debug APK to judge speed.

---

## 9. Loose ends

- Cross-engine R1 (install eSpeak from F-Droid, re-run the batch) is still cheap and undone.
- `spike-runs/` and `dist/` are gitignored; delete freely. Do not commit APKs.
- The `spike/audio-engine` branch can still be deleted if it exists remotely.
- QA leftovers: `mobile-qa/scratch/`, `report.xml`, incomplete flows
  `import-clown.yaml` / `import-pdf.yaml` / `tap-clown.yaml` are untracked on purpose.
- User books live on the laptop at `E:\stories\` (Clown EPUB, Crime EPUB, PDFs, audio).
  Do not delete those. Device copies were under `/sdcard/Download/`.
