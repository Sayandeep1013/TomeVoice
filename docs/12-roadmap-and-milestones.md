# 12 — Roadmap & Milestones

Where TomeVoice stands and what comes next, as of 31 October 2026. The original plan
(a 28-week, two-platform roadmap, Android and Windows, phases 0 to 6) is in git history;
what actually shipped is in the [changelog](../CHANGELOG.md).

## Shipped

0.2 to 1.3.0, between 22 and 30 October 2026: the reader, the owned audio pipeline,
system and natural voices, ten formats, web novels, widgets, stats, secret shelves,
backups, and with 1.3.0 the fixes from the full review of 30 October
([docs/review-2026-10-30.html](review-2026-10-30.html)).

## Next release (on the `next` branch, waiting for a phone check)

Save as audio (M4B), reading from outside the app (swipe-away, the media card, a
headset, Android Auto), battery help, web novels that look after themselves (checks
with the app closed, a download queue, sandboxed plugins checked by SHA-256), reading a
shared link or text, highlights with Markdown export, Read notes aloud, OPDS
catalogues, automatic backups, WebDAV and KOReader sync, OCR for scanned PDFs, natural
voices in 42 languages, PDF pages that zoom and go dark, accessibility and contrast, an
error log with Report a problem, and thirteen reading fixes found by a corpus of real
books.

## The pass after it

1. **Split `reader_screen.dart`** (3,500 lines; scroll and pages copy each other, which
   caused the tone bug): a reader controller for the place, playback and media card,
   one page style for every view. On its own, before anything else touches the file,
   with the full checks and a phone check, since it can break the reader.
2. **Fixes found along the way:**
   - PDF dialogue that still runs together, which needs the extractor's raw output from
     a phone;
   - footnotes in KF8 files being read;
   - a PDF footnote's number being said;
   - Russian dialogue dashes splitting a sentence;
   - chips and the chapter scrubber under 48 dp;
   - small type in the app's light palettes below AA;
   - no margin crop for a PDF's pages;
   - a save to audio stopping on swipe-away;
   - the closed-app chapter check skipping while the app sits in the background;
   - a gap at the reader page's window edge;
   - MP3 export;
   - small document leftovers (transcriber's notes, RTF footnotes, Word tables, a
     Gutenberg text's title);
   - quotes left by secret books removed before 1.4.
3. **`library.json` written about once a sentence:** measured on a phone with a large
   library first, then places kept in `cursor.json` with the index written on a debounce,
   off the UI thread.
4. **Reader comforts:** brightness and warmth in the reader, auto-scroll, Material You
   colours, a first-run guide, an EPUB's own narration (Media Overlays), and colours the
   reader picks alongside the themes.
5. **A second full review** of the whole app.

## Undecided (ask first)

Shareable pronunciation lists and skip presets; character voices; organising the
library (tags, series, filters, sort by author); web-novel comforts (moving a novel
between sources, logins, EPUB export, NovelUpdates, auto-download, read marks).

## Not planned

| | |
|---|---|
| The interface in other languages | The app's language stays English; books in any language are read in their own voice. |
| On-device AI | Kept out to keep the app light. An optional feature with the reader's own API key may be considered later. |
| A Play Store build | Not planned for now ([docs/18](18-play-store-audit.md) holds the audit, should that change). |
| Windows | Android only for now; maybe in the near future. |

## Known limits, and what could lift them

| Limit | Why | What could lift it |
|---|---|---|
| A jump with a natural voice waits for the clause being made (0.3 to 1.7 s, longer with Kokoro) | sherpa-onnx makes a sentence in one model run and cannot stop part-way | A streaming synthesiser that yields audio as it goes, or smaller pieces at a cost to intonation |
| No natural voice for Bengali | sherpa-onnx has not converted rhasspy's `bn_BD-google-medium` Piper voice | Convert it with sherpa-onnx's Piper export scripts, check its espeak-ng Bengali front end, then judge it by ear |
| Android Auto untested | No car with Android Auto | Google's Desktop Head Unit emulator on a PC (it needs Android SDK tools), or a friend's car |
