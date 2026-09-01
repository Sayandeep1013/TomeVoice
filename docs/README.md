# TomeVoice — Documentation

A cross-platform (Android + Windows) reader for EPUB, PDF, DOCX and other document
formats, with a deeply controllable text-to-speech engine and downloadable neural
("AI") voices.

This directory is the project's source of truth. It is written to be read in order,
but each file stands alone.

## Read in this order

| # | Document | What it answers |
|---|---|---|
| 01 | [Vision & Scope](01-vision-and-scope.md) | What we are building, for whom, and explicitly what we are not building |
| 02 | [Architecture](02-architecture.md) | Layers, module boundaries, data flow, the two contracts everything hangs off |
| 03 | [Document Pipeline](03-document-pipeline.md) | How EPUB/PDF/DOCX/TXT become one uniform readable+speakable model |
| 04 | [TTS Engine Contract](04-tts-engine-contract.md) | The adapter every voice engine must satisfy, and the audio pipeline behind it |
| 05 | [TTS Controls Spec](05-tts-controls-spec.md) | Every knob: speed, pitch, word spacing, pauses, pronunciation, skip rules |
| 06 | [Voice Catalog & Licensing](06-voice-catalog-and-licensing.md) | Which AI voices ship, their licences, sizes, and the ones we must refuse |
| 07 | [Platform: Android](07-platform-android.md) | Background playback, memory limits, store deadlines, OEM battery killers |
| 08 | [Platform: Windows](08-platform-windows.md) | WinRT speech, packaging, signing, audio device handling |
| 09 | [Challenges & Solutions](09-challenges-and-solutions.md) | **Every known blocker**, its severity, and the chosen mitigation |
| 10 | [Decision Log (ADRs)](10-decisions-adr.md) | Every architectural decision, with the alternatives we rejected and why |
| 11 | [Data Model & Storage](11-data-model-and-storage.md) | Schemas, library, reading state, caches |
| 12 | [Roadmap & Milestones](12-roadmap-and-milestones.md) | Phased plan with exit criteria per phase |
| 13 | [Testing & QA](13-testing-and-qa.md) | How we prove the pipeline is correct, including the hard-to-test audio parts |
| 14 | [Verification Log](14-verification-log.md) | Every load-bearing claim, its primary source, and what failed checking |
| 15 | [Spike Spec: Audio Engine](15-spike-audio-engine.md) | The first build — what we are proving, and how we measure it |

## The one-paragraph summary

The idea is sound and buildable. There is no blocker that kills the project. There are
five that shape the architecture, and if you ignore them you will build the wrong thing
and have to restart:

1. **No system TTS engine can control the gap between words.** Neither Android's
   `TextToSpeech` nor Windows' `SpeechSynthesizer` exposes it. Word spacing — an
   explicit requirement — is only achievable if we own the audio buffer. This forces
   *synthesize-to-PCM* instead of fire-and-forget `speak()`, which in turn dictates the
   whole playback architecture. See [ADR-003](10-decisions-adr.md#adr-003).
2. **Neural voices give no word timings.** System TTS hands us word boundaries for free;
   Kokoro and Piper do not. Word highlighting and word-gap injection both depend on
   them, so we must derive them. See [C-13](09-challenges-and-solutions.md#c-13).
3. **The best-sounding open model is too heavy for cheap Android phones.** Kokoro-82M's
   measured runtime footprint is several hundred MB. It cannot be the default. See
   [C-16](09-challenges-and-solutions.md#c-16).
4. **The open TTS ecosystem is a licensing minefield — and we defused it by choosing
   GPL-3.0.** eSpeak-NG (the phonemiser both Kokoro and Piper depend on) is GPL-3.0,
   Piper's engine relicensed to GPL-3.0, and the best pitch/time library is GPL. Under a
   permissive or closed licence each was a blocker; under
   [GPL-3.0](10-decisions-adr.md#adr-014) all three become usable, and three register
   entries closed at once. What survives: XTTS is GPL-incompatible, `edge-tts` is an
   unsanctioned endpoint, and **every Piper voice still needs an individual audit**. See
   [Voice Catalog & Licensing](06-voice-catalog-and-licensing.md).
5. **PDF is not a text format.** It is a description of ink on a page. Extracting a
   correct *reading order* is the single largest engineering cost in the document
   pipeline, and it is never 100% solved. See
   [C-01](09-challenges-and-solutions.md#c-01).

DRM'd books (Kindle AZW, Adobe ADEPT) are out of scope permanently — that is a legal
boundary, not a technical one.

## Verification status

These documents have been fact-checked once, on 2026-09-01. Two claims were **wrong** and
were corrected — including one that had been used as the rationale for an architectural
decision. See the [Verification Log](14-verification-log.md) for what was checked, what
failed, and what is still deliberately unverified.

Treat any claim not listed in that log as unverified.

## Decisions already made

| | |
|---|---|
| Licence | **GPL-3.0**, public repository ([ADR-014](10-decisions-adr.md#adr-014)) |
| Framework | Flutter; Android primary, Windows second ([ADR-001](10-decisions-adr.md#adr-001)) |
| Toolchain | Dart SDK locally, APKs built in CI ([ADR-016](10-decisions-adr.md#adr-016)) |
| Visual direction | The "specimen" aesthetic ([ADR-017](10-decisions-adr.md#adr-017)) |
| First build | The audio-engine spike ([15](15-spike-audio-engine.md)) |
