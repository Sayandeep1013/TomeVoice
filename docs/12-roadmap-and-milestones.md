# 12 — Roadmap & Milestones

Where TomeVoice stands and what comes next, as of 31 October 2026. The original plan
(a 28-week, two-platform roadmap, Android and Windows, phases 0 to 6) is in git history;
what actually shipped is in the [changelog](../CHANGELOG.md).

## Shipped

0.2 to 1.4.0, between 22 and 31 October 2026: the reader, the owned audio pipeline,
system and natural voices, ten formats, web novels, widgets, stats, secret shelves and
backups; with 1.3.0 the fixes from the full review of 30 October
([docs/review-2026-10-30.html](review-2026-10-30.html)); and with 1.4.0 everything that
review asked for and every idea it listed that was chosen, from saving as audio, a voice
for each character and an EPUB's own narration to sync, OCR, organising the library,
reader comforts and your own colours. The [changelog](../CHANGELOG.md) has each release.

Before 1.4.0 went out, a second review of all its new code found 47 problems; all were
fixed, and an emulator crash in the reader (a fade drawn through a following layer) was
found on CI and fixed.

## Next

1. **A second full review** of the whole app, as the first one was done.
2. **Dusk's saved quotes:** a quote's colour under the Dusk page tone reads at about
   4.2:1 (3:1 under the sentence being read), short of AA; it needs a design call on
   Dusk's ink or the quote colours.
3. **Smaller things left from 1.4.0:** the upright player's scrubber reaches 39 dp, not
   48 (more would mean a taller player); Pause pressed in the moment a web novel rolls
   into its next chapters is ignored; a shared Wikipedia page's notes in other sections'
   names may still be read.

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
