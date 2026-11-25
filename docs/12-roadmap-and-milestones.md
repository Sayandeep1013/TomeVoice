# 12 — Roadmap & Milestones

Where TomeVoice stands and what comes next, as of 1.6.0 (18 November 2026). The original
plan (a 28-week, two-platform roadmap, Android and Windows, phases 0 to 6) is in this file's
git history; the plan for web novels and the new look (`docs/roadmap.html`) and the road
to 1.0 (`docs/road-to-1.0.html`), both of 23 October, are at the tag `v1.4.0`. What
actually shipped is in the [changelog](../CHANGELOG.md).

## Shipped

0.2 to 1.4.0, between 22 and 31 October 2026, Android only: the reader, the owned audio
pipeline, system and natural voices, eleven formats, web novels, widgets, stats, secret
shelves and backups; with 1.3.0 the fixes from a full review of the app on 30 October
(its market notes are kept privately); and with 1.4.0 everything that review asked
for and every idea it listed that was chosen, from saving as audio, a voice for each
character and an EPUB's own narration to sync, OCR, organising the library, reader
comforts and your own colours. The [changelog](../CHANGELOG.md) has each release.

Before 1.4.0 went out, a second review of all its new code found 47 problems; all were
fixed, and an emulator crash in the reader (a fade drawn through a following layer) was
found on CI and fixed.

1.4.1 (31 October) and 1.4.2 (18 November) fixed what the first weeks of daily use
found: web novels opening the chapter asked for, at once, and reading on past a chapter
the site would not give. 1.5.0 (18 November) made a chapter picked while a book is
listened to only looked at, read "..." and commas as people do, and was smoother and
lighter on the battery.

**1.6.0 was released on 18 November 2026**: the reading journal and its notebook; the
Notebook paper and coloured part tabs in Contents; type weight, letter spacing and your
own font; replacing a book's file; your own chapters for a TXT book; Project Gutenberg's
new OPDS 2 catalogue and any OPDS 2 feed; and DjVu books, read by their hidden text. The
[changelog](../CHANGELOG.md) has the details.

**2.0.0 was released on 19 November 2026**: an AI reading companion. It brings no AI of
its own: it works with API keys the reader brings, and adds:

- a memory of the story, kept for each book as it is read;
- talking about the book;
- who's who in the story;
- a memory graph.

How it works: [14 — AI Companion](14-ai-companion.md). Before release it was tried on the owner's own phone with a 3,250-chapter web novel and a 213-chapter book, which found and fixed the name mix-ups the cast tidy now puts right.

## Also open

1. **A second full review** of the whole app, as the first one was done.
2. **Dusk's saved quotes:** a quote's colour under the Dusk page tone reads at about
   4.2:1 (3:1 under the sentence being read), short of AA; it needs a design call on
   Dusk's ink or the quote colours.
3. **Smaller things left from 1.4.0:** the upright player's scrubber reaches 39 dp, not
   48 (more would mean a taller player); Pause pressed in the moment a web novel rolls
   into its next chapters is ignored; a shared Wikipedia page's notes in other sections'
   names may still be read.

## To build: what older readers have and TomeVoice does not yet

Found on 25 November 2026 by checking a comparison with Librera Reader, KOReader and
@Voice Aloud against the code (most of what it said was missing is built: pronunciations,
running heads and page numbers left out, two-column order, OCR, DjVu, OPDS, sorting and
filters, Markdown export, audiobook export). What is truly missing, to be built:

| To build | Today |
|---|---|
| Find-and-replace rules for the voice, with regular expressions | A pronunciation (`SayRule`) matches a whole word as plain text, any case |
| "Don't read lines like this" rules for every book | The reader's own skip rules work in web novels; books get the built-in skips (notes, rows of symbols, titles said twice) |
| The reader's own margins and column choice on PDF pages | Margins are cropped and two columns ordered automatically (`page_crop.dart`, `pdf.dart` `_readingOrder`) |
| Contrast for faint scans | Real pages only invert for the night |
| OCR for picture-only DjVu | Refused with a message (`djvu.dart`) |
| Comics: CBZ, CBR, CBT | A zip that is mostly pictures is refused on purpose |
| An offline dictionary (StarDict) and translation in the app | A word goes to the phone's dictionary app, its sentence to the translate app |
| Exporting bookmarks; plain-text exports | Quotes and the journal export as Markdown |
| WAV export; legacy Word .doc | M4B, M4A and MP3; DOCX and ODT |

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
| On-device AI | Kept out to keep the app light. The 2.0 companion uses an AI service through the reader's own API keys instead. |
| Windows | Not started. Android only for now; maybe later ([08](08-platform-windows.md)). |

## Known limits, and what could lift them

| Limit | Why | What could lift it |
|---|---|---|
| A jump with a natural voice waits for the clause being made (0.3 to 1.7 s, longer with Kokoro) | sherpa-onnx makes a sentence in one model run and cannot stop part-way | A streaming synthesiser that yields audio as it goes, or smaller pieces at a cost to intonation |
| No natural voice for Bengali | sherpa-onnx has not converted rhasspy's `bn_BD-google-medium` Piper voice | Convert it with sherpa-onnx's Piper export scripts, check its espeak-ng Bengali front end, then judge it by ear |
| Android Auto untested | No car with Android Auto | Google's Desktop Head Unit emulator on a PC (it needs Android SDK tools), or a friend's car |
| Old Word `.doc` and HUFF/CDIC-compressed Kindle books are refused | No parser for either | A parser for each, as for MOBI's PalmDOC |
| A DjVu with no text layer, and one kept as a file a page ("indirect"), are refused | DjVu is read by its hidden text only: its pictures (IW44, JB2) are not decoded, so OCR cannot run on them; an indirect book is many files and the app opens one | A JB2 and IW44 decoder feeding the OCR scanned PDFs get; for indirect books, picking the folder |
| Bengali PDFs set in legacy fonts (Bijoy, SutonnyMJ) read as Latin gibberish | The file's text is not Unicode | A conversion from those fonts' encodings to Unicode |
| Natural voices have no pitch control | No pitch shifter was built ([C-14](09-challenges-and-solutions.md#c-14)) | A formant-preserving shift in DSP |
| How TTS engines other than Google's report word timings is unmeasured | The test phone had only Google's | Measure on a phone with another engine (Samsung's, eSpeak's) |
| Opening a book on a 120 Hz phone can drop a few frames in its first moment | The phone lets its GPU slow down after a second or two at rest, and the first 150–300 ms of an animation are drawn on the slow GPU ([C-39](09-challenges-and-solutions.md#c-39)) | A steady 60 Hz while the app is in front (measured: about 1 hitch an opening instead of about 4), as a setting |
