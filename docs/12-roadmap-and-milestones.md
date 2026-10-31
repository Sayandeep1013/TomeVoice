# 12 — Roadmap & Milestones

Where TomeVoice stands and what comes next, as of 31 October 2026. The original plan
(a 28-week, two-platform roadmap, Android and Windows, phases 0 to 6) is in this file's
git history; the plan for web novels and the new look (`docs/roadmap.html`) and the road
to 1.0 (`docs/road-to-1.0.html`), both of 23 October, are at the tag `v1.4.0`. What
actually shipped is in the [changelog](../CHANGELOG.md).

## Shipped

0.2 to 1.4.0, between 22 and 31 October 2026, Android only: the reader, the owned audio
pipeline, system and natural voices, ten formats, web novels, widgets, stats, secret
shelves and backups; with 1.3.0 the fixes from a full review of the app on 30 October
(its report is kept outside the repository); and with 1.4.0 everything that review asked
for and every idea it listed that was chosen, from saving as audio, a voice for each
character and an EPUB's own narration to sync, OCR, organising the library, reader
comforts and your own colours. The [changelog](../CHANGELOG.md) has each release.

Before 1.4.0 went out, a second review of all its new code found 47 problems; all were
fixed, and an emulator crash in the reader (a fade drawn through a following layer) was
found on CI and fixed.

Since 1.4.0, on `next` and not yet released: the fixes listed under "Unreleased" in the
changelog.

## Next

1. **A second full review** of the whole app, as the first one was done.
2. **Dusk's saved quotes:** a quote's colour under the Dusk page tone reads at about
   4.2:1 (3:1 under the sentence being read), short of AA; it needs a design call on
   Dusk's ink or the quote colours.
3. **Smaller things left from 1.4.0:** the upright player's scrubber reaches 39 dp, not
   48 (more would mean a taller player); Pause pressed in the moment a web novel rolls
   into its next chapters is ignored; a shared Wikipedia page's notes in other sections'
   names may still be read.

## From the earlier plans, not built

Ideas the plans of 23 October (web novels and the new look, the road to 1.0, and the
step-back review of v0.4.0) listed that were never built nor turned down. None is
scheduled.

| Idea | Where it came from | Today |
|---|---|---|
| Check for new chapters only while charging, only for chosen categories, and skip novels not started | the web-novel plan | The check with the app closed runs on Wi-Fi with the battery not low, and skips a novel the site marks completed once it has been read to the end; nothing else narrows it |
| "Always ask" which shelf a new book goes to | the web-novel plan | New books go to the default category |
| A web novel's link shared from the browser opens its novel page in the matching source | the web-novel plan | A shared link becomes an article |
| On a tablet, the library and a book's page side by side | the road to 1.0 | Landscape gives the book page two columns; no two-pane layout |
| Shake the phone to add time to the sleep timer | the step-back review | The timer fades out over 30 s; no shake |
| A CI flow through web novels: add a source, search, read a chapter through a plugin | the step-back review | The QuickJS host is unit-tested in CI; real sites are checked by hand |

## Not planned

| | |
|---|---|
| The interface in other languages | The app's language stays English; books in any language are read in their own voice. |
| On-device AI | Kept out to keep the app light. An optional feature with the reader's own API key may be considered later. |
| A Play Store build | Not planned for now ([18](18-play-store-audit.md) holds the audit, should that change). |
| Windows | Not started. Android only for now; maybe later ([08](08-platform-windows.md)). |

## Known limits, and what could lift them

| Limit | Why | What could lift it |
|---|---|---|
| A jump with a natural voice waits for the clause being made (0.3 to 1.7 s, longer with Kokoro) | sherpa-onnx makes a sentence in one model run and cannot stop part-way | A streaming synthesiser that yields audio as it goes, or smaller pieces at a cost to intonation |
| No natural voice for Bengali | sherpa-onnx has not converted rhasspy's `bn_BD-google-medium` Piper voice | Convert it with sherpa-onnx's Piper export scripts, check its espeak-ng Bengali front end, then judge it by ear |
| Android Auto untested | No car with Android Auto | Google's Desktop Head Unit emulator on a PC (it needs Android SDK tools), or a friend's car |
| Old Word `.doc` and HUFF/CDIC-compressed Kindle books are refused | No parser for either | A parser for each, as for MOBI's PalmDOC |
| Bengali PDFs set in legacy fonts (Bijoy, SutonnyMJ) read as Latin gibberish | The file's text is not Unicode | A conversion from those fonts' encodings to Unicode |
| Natural voices have no pitch control | No pitch shifter was built ([C-14](09-challenges-and-solutions.md#c-14)) | A formant-preserving shift in DSP |
| How TTS engines other than Google's report word timings is unmeasured | The test phone had only Google's | Measure on a phone with another engine (Samsung's, eSpeak's) |
