# TomeVoice

A document reader with a serious text-to-speech engine, for **Android and Windows**.

Read EPUB, PDF, DOCX and plain formats — and have any of them read aloud with far more
control over the voice than a normal reader gives you: speed, pitch in semitones,
punctuation pause shaping, and **word separation**, on every voice including free
on-device neural ones.

## Idea

- **Any document.** EPUB 2/3, PDF, DOCX, TXT, Markdown, HTML, RTF. MOBI/AZW3 later.
- **Real TTS control.** Speed, pitch, per-word gap, comma/sentence/paragraph/heading
  pauses, loudness normalisation, pronunciation dictionaries, skip rules for footnotes,
  page numbers and captions.
- **Free AI voices.** Offline neural TTS via Piper and Kokoro, downloaded on demand.
  No subscription, no account, nothing leaves the device.
- **Word-synchronised highlighting** tied to the audio, not to a timer.
- **Both platforms properly.** A `.apk` that keeps reading with the screen off, and a
  real Windows `.exe` with media keys and a mini player.

## Status

**Design complete and fact-checked; first build starting.**

The full specification lives in [`docs/`](docs/). It was verified against primary sources
on 2026-09-01 — two claims were wrong and were corrected, one of them load-bearing. The
[Verification Log](docs/14-verification-log.md) records what was checked and what is still
deliberately unverified.

The first thing being built is not the reader. It is the
[audio-engine spike](docs/15-spike-audio-engine.md): proving that word-gap injection and
word-timing capture actually work on a real Android device, because everything else
depends on them.

## Documentation

Start at [`docs/README.md`](docs/README.md). The two documents that matter most if you
only read two:

- [09 — Challenges & Solutions](docs/09-challenges-and-solutions.md) — every known
  blocker, its severity, and the chosen mitigation.
- [10 — Decision Log](docs/10-decisions-adr.md) — every architectural decision, with the
  alternatives rejected and what each one costs.

## The short version of what's hard

The idea is buildable. Five findings shape the architecture:

1. **No TTS engine on either platform can control the gap between words.** Not Android,
   not Windows, not Piper, not Kokoro. Since word separation is a core requirement, we
   must own the audio buffer — which means synthesising to PCM rather than calling
   `speak()`, and building our own player, scheduler and DSP chain. That one requirement
   determines most of the architecture.
2. **Neural voices return no word timings.** System voices hand them to us for free;
   Piper and Kokoro return only samples. Highlighting and word-gap injection both depend
   on them, so they have to be derived — in stages, honestly labelled.
3. **The best-sounding open model is too heavy for cheap phones.** Kokoro's measured
   runtime footprint is several hundred MB, so it is device-gated and never the default.
4. **The open TTS ecosystem is a licensing minefield — so we chose GPL-3.0 and defused
   most of it.** eSpeak-NG (the phonemiser both Piper and Kokoro depend on) is GPL-3.0,
   Piper's engine relicensed to GPL-3.0, and the best pitch/time library is GPL. Matching
   their licence turns all three from blockers into dependencies. What remains: XTTS is
   GPL-incompatible, `edge-tts` is an unsanctioned endpoint, and every Piper voice still
   needs an individual audit.
5. **PDF is not a text format.** Reconstructing reading order from glyph positions is the
   single largest engineering cost in the document pipeline, and it is never perfect —
   so the product lets users correct it.

DRM-protected books (Kindle, Adobe ADEPT) are permanently out of scope.

## Licence

**GPL-3.0.** This was not a formality — it was the decision that unblocked the neural
voice tier. Matching the licence of eSpeak-NG, the Piper engine and the best pitch/time
libraries turned three separate blockers into ordinary dependencies. See
[ADR-014](docs/10-decisions-adr.md#adr-014).

## Building

There is deliberately no local Flutter or Gradle requirement
([ADR-016](docs/10-decisions-adr.md#adr-016)):

| | |
|---|---|
| Logic, audio pipeline, tests | Standalone **Dart SDK** — `dart test`, no Gradle |
| APK and Windows builds | **GitHub Actions** — free and unmetered on this public repo |
| Install and listen | **`adb install`** onto a physical device |
