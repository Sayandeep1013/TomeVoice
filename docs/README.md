# TomeVoice — Documentation

An Android reader that reads aloud: EPUB, PDF (scanned ones too, by OCR), Word, Kindle and
other formats, web pages and web novels, in the phone's own voices or natural voices made
on the phone, with more control over the voice than mainstream readers give. GPL-3.0.

## Where it stands

**1.4.0 was released on 31 October 2026.** Android only: Windows is not started (maybe
later) and there is no Play Store build for now. What comes next is in
[12 — Roadmap](12-roadmap-and-milestones.md); what each release changed is in the
[changelog](../CHANGELOG.md).

**Picking this up cold? Start at [16 — Start Here](16-session-handoff.md):** how to check,
build and release it, how to check it on a phone, and the findings that cost days.

These documents began as the design written before the first line of code (2026-09-01).
They describe 1.4.0: where the build went another way than the design, the document says
so in an **As built** or status note and keeps the design's reasoning beside it.

## The documents

| # | Document | What it answers |
|---|---|---|
| 01 | [Vision & Scope](01-vision-and-scope.md) | What we are building, for whom, and explicitly what we are not building |
| 02 | [Architecture](02-architecture.md) | Layers, the two contracts everything hangs off, the pipeline and scheduler as built, where the code is |
| 03 | [Document Pipeline](03-document-pipeline.md) | How every format, a web page and a web novel's chapter become one readable and speakable model; OCR; the NovelDokusha import |
| 04 | [TTS Engine Contract](04-tts-engine-contract.md) | The phone's voices, natural voices and a book's own narration; word timings; what was measured on the phone |
| 05 | [TTS Controls Spec](05-tts-controls-spec.md) | Every knob as specified, and as built: speed, pitch, word gap, pauses, pronunciation, what is skipped |
| 06 | [Voice Catalog & Licensing](06-voice-catalog-and-licensing.md) | The natural voices on offer, their recordings' licences, and every library's licence |
| 07 | [Platform: Android](07-platform-android.md) | Background playback, the media session and browser, battery killers, files, size, accessibility |
| 08 | [Platform: Windows](08-platform-windows.md) | **Not started.** The research, kept for if it comes |
| 09 | [Challenges & Solutions](09-challenges-and-solutions.md) | **Every known risk**, its severity, the chosen mitigation, and how it turned out |
| 10 | [Decision Log (ADRs)](10-decisions-adr.md) | Every architectural decision, what superseded it, and what to re-check when upstream changes |
| 11 | [Data Model & Storage](11-data-model-and-storage.md) | The files on the phone, writing safely, places, backups, secret shelves, tags and series |
| 12 | [Roadmap & Milestones](12-roadmap-and-milestones.md) | What shipped, what is next, what is not planned, and the known limits |
| 13 | [Testing & QA](13-testing-and-qa.md) | What is tested where, the emulator job, reproducible builds, and the audio spike's measurements |
| 16 | [Start Here](16-session-handoff.md) | **Start here if picking this up cold.** Checks, builds, releases, phone checks, gotchas |
| 18 | [Play Store Audit](18-play-store-audit.md) | What a Play build would have to leave out, should one ever be made |

Numbers 14, 15 and 17 are retired: the verification log of September 2026, the audio
spike's specification and build log, and the step-back review of v0.4.0 were finished
history, as were the HTML plans for 1.0 and for web novels and the NovelDokusha research.
What still holds from them is in [03](03-document-pipeline.md),
[04](04-tts-engine-contract.md), [09](09-challenges-and-solutions.md),
[10](10-decisions-adr.md), [12](12-roadmap-and-milestones.md) and
[13](13-testing-and-qa.md); the originals are in git history, as of the tag `v1.4.0`
(`git show v1.4.0:docs/15-spike-audio-engine.md`). `docs/images/` holds the README's
screenshots.

## The five problems that shaped it

There was no blocker that killed the project. There were five that shaped the
architecture, and ignoring any of them would have meant building the wrong thing:

1. **No system TTS engine can control the gap between words.** Neither Android's
   `TextToSpeech` nor Windows' `SpeechSynthesizer` exposes it, so TomeVoice synthesises to
   PCM and owns the audio ([ADR-003](10-decisions-adr.md#adr-003)). *As built:* a gap of 0
   to 500 ms on every voice, measured on the phone's real audio before anything else was
   built.
2. **Neural voices give no word timings.** Highlighting and the word gap both need them
   ([C-13](09-challenges-and-solutions.md#c-13)). *As built:* they are worked out from
   the pauses in the audio, so natural voices are highlighted word by word too, and only a
   long stretch with no pause falls back to the sentence.
3. **The best-sounding open model is too heavy for cheap phones**
   ([C-16](09-challenges-and-solutions.md#c-16)). *As built:* Kokoro is offered only on
   phones with at least 5,200 MB of memory that pass a speed test; Piper voices serve the
   rest, and the phone's own voices are the default.
4. **The open TTS ecosystem is a licensing minefield, defused by choosing GPL-3.0**
   ([ADR-014](10-decisions-adr.md#adr-014)): eSpeak-NG, Piper's engine and GPL DSP
   libraries all became usable. What survived: XTTS is GPL-incompatible, `edge-tts` is an
   unsanctioned endpoint, and every Piper voice has a licence of its own. *As built:* each
   natural voice shows the licence of the recordings it learned from
   ([06](06-voice-catalog-and-licensing.md)).
5. **PDF is not a text format.** It describes ink on a page, and reading order is never
   fully solved ([C-01](09-challenges-and-solutions.md#c-01)). *As built:* PdfBox extracts
   the text, Dart cleans it up for listening, and scanned PDFs are read by OCR on the phone.

DRM'd books (Kindle AZW/KFX, Adobe ADEPT) are out of scope permanently — that is a legal
boundary, not a technical one.

## Verification

The load-bearing claims about other people's APIs, licences and store rules were checked
against primary sources on 2026-09-01 (two were wrong and corrected, one of them the stated
reason for a decision) and on a real phone on 2026-09-02, where one claim checked against
the documentation still turned out wrong. Sources are cited where each claim is made. What
can change upstream, and what rests on it, is in the
[recheck triggers](10-decisions-adr.md#recheck-triggers).

## Decisions already made

| | |
|---|---|
| Licence | **GPL-3.0**, public repository ([ADR-014](10-decisions-adr.md#adr-014)) |
| Framework | Flutter; Android only for now ([ADR-001](10-decisions-adr.md#adr-001)) |
| Toolchain | Dart SDK locally, APKs built in CI ([ADR-016](10-decisions-adr.md#adr-016)) |
| Look | A fashion-magazine type set over the "specimen" ground ([ADR-018](10-decisions-adr.md#adr-018), [ADR-017](10-decisions-adr.md#adr-017)) |
| Natural voices | sherpa-onnx, pinned at 1.13.8: Piper, Kokoro, Kitten ([ADR-006](10-decisions-adr.md#adr-006)) |
| Web novels | LNReader's source plugins in QuickJS; TomeVoice ships no scrapers ([ADR-019](10-decisions-adr.md#adr-019)) |
| Storage | Plain JSON files, no database ([11](11-data-model-and-storage.md)) |
