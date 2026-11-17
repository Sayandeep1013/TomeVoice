# 06 — Voice Catalog & Licensing

"Free AI TTS voices" is the easiest sentence in the brief to write and one of the
riskiest to implement. The models are free to *download*; they are not uniformly free to
*ship in a product*. This document is the audit, brought up to date with 1.4.0.

## 6.1 The rule

**Nothing enters a build without a licence entry.** Every library and font has a row in
§6.6 with its licence and a verdict, and every natural voice carries the licence of the
recordings it learned from in the catalogue, shown beside it in the app.

The first design went further: a voice with a licence that forbids commercial use would
not be offered at all. **As built, the GitHub build offers every voice, each with its
licence in plain words** (the developer's decision, 2026-10-29; TomeVoice is free and
GPL-3.0). A Play build would leave out the voices that are not open
([18](18-play-store-audit.md)).

The reason for the rule stands: discovering a licence problem after shipping costs a
takedown and a forced update; checking a licence costs ten minutes.

## 6.2 The tier model

| Tier | Engine | Download | RAM | Availability (1.4.0) |
|---|---|---|---|---|
| **0 — the phone's voices** | Android TTS engines | none | in the engine's own process (the app and Google's TTS read at about 404 MB together, against 213 MB for the app idle) | every phone; the default |
| **1 — natural** | Piper through sherpa-onnx | 25 to 125 MB a voice | a hundred MB or more a model (the app read with Kristin at 537 MB in all; [04 §4.5](04-tts-engine-contract.md#45-adapter-piper-via-sherpa-onnx)) | any phone, once chosen |
| **1 — natural, small** | Kitten through sherpa-onnx | 61 MB for eight voices | not measured | any phone, once chosen |
| **2 — natural HD** | Kokoro through sherpa-onnx | 334 MB for 29 voices | about 850 MB | phones with at least 5,200 MB of memory that pass the speed test |
| **3 — cloud** | the reader's own API key | none | none | **not built** |

Tier 0 is the default on first launch: it works at once, needs no download, costs the app
little memory, and gives word timings for free. Natural voices are off until the reader turns
to Settings → Natural voices; a warning says what they cost before anything downloads,
and "No thanks" hides them.

Tier 3 was to be strictly bring-your-own-key (Azure, Google, ElevenLabs), never
credentials of ours and never a proxy. It was not built; on-device AI is out for now too
([12](12-roadmap-and-milestones.md)).

## 6.3 Licence findings for engines and runtimes

> **Framing note.** TomeVoice is **GPL-3.0** ([ADR-014](10-decisions-adr.md#adr-014)).
> That makes GPL components compatible rather than dangerous, and removes the
> commercial-use dimension from TomeVoice's own side. It does **not** remove the voices'
> own terms: redistribution limits and CC-BY attribution bind regardless.

**sherpa-onnx — Apache-2.0. Approved, used.** The natural-voice runtime, pinned at
**1.13.8**.

> **Correction, 2026-09-01.** An earlier version of this section claimed the project
> *"deliberately removed its eSpeak-NG and `piper-phonemize` dependencies to stay
> Apache-2.0 clean"*, and used that as the main reason to choose it. **The claim was
> false.** The removal is a proposal for a future 2.0.0
> ([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08).
> The 1.13.x line still bundles eSpeak-NG — v1.13.5's notes read "Fix installing
> espeak-ng-data directory". Under GPL-3.0 this is harmless; under any other licence it
> would have been a launch-blocking discovery.

**Piper engine — GPL-3.0. Compatible, unused.** `rhasspy/piper` was MIT and was archived
in October 2025; development moved to `OHF-Voice/piper1-gpl`, which is GPL-3.0.
TomeVoice uses Piper's **ONNX model files** through sherpa-onnx: one integration instead
of two.

**eSpeak-NG — GPL-3.0. Approved and used**, inside sherpa-onnx, as the phonemiser the
Piper models were trained against ([§4.8](04-tts-engine-contract.md#48-phonemisation)).

**Kokoro-82M — Apache-2.0. Approved, used** (`kokoro-multi-lang-v1_0`). Its makers say it
learned from public-domain, openly licensed and synthetic audio.

**Kitten TTS nano 0.8 — Apache-2.0. Approved, used** (`kitten-nano-en-v0_8-fp32`).

**Coqui XTTS v2 — CPML. Excluded.** The Coqui Public Model Licence is non-commercial and
not a free-software licence; we cannot ship the weights under our own terms. Voice
cloning waits for a model with compatible terms.

**`edge-tts` and similar — cannot ship.** They call an undocumented Microsoft Edge
"Read Aloud" endpoint that is not public or endorsed; it needs short-lived anti-abuse
tokens and filters cloud IP ranges, so it is also *technically* unreliable. Excluded on
both grounds.

**Rubber Band — GPL / commercial. Not used.** It was approved for pitch and time
stretching; as built, speed is each voice's own rate, a small WSOLA stretcher in Dart
serves a book's recorded narration, and no pitch shifter was needed
([C-14](09-challenges-and-solutions.md#c-14)).

## 6.4 The per-voice trap

Even with a safe engine, **individual voices carry their own licences**, and Piper's
catalogue mixes public domain, CC0, CC-BY, MIT and several research-only or
non-commercial voices. There is no `commercial_ok` flag to filter on; the licence lives
in each voice's model card.

What still holds from the first design, and is built:

1. **Never enumerate an upstream voice list at run time and offer everything.** The app
   reads only its own catalogue (`app/assets/voices/catalog.json`), which
   `tools/voice_catalog.py` writes. A voice upstream adds next week is not offered until
   the script is run again and the change looked at (`--check` says what would change).
2. **Store the licence with the voice** and show it in the app. The script reads each
   voice's `MODEL_CARD` from `rhasspy/piper-voices` at a pinned revision (or, for the few
   that are not there, the model's own page) and records the licence's name, a note, and
   which of five kinds it is (`LicenceUse` in `neural_voices.dart`):

   | Kind | Shown as | Voices in 1.4.0 |
   |---|---|---|
   | `free` | Free for any use (public domain, CC0) | 61 |
   | `credit` | Free to use, on conditions (credit, share-alike, a notice) | 92 |
   | `noncommercial` | Non-commercial use only | 38 |
   | `restricted` | No licence granted | 2 |
   | `unclear` | Licence unclear | 24 |

   The counts are of the catalogue's 217 entries (180 Piper voices, 29 Kokoro and 8 Kitten
   speakers). Each voice row shows its licence in a word or two, coloured by what it
   allows; a tap shows the whole of it.
3. **Honour attribution.** A voice's licence note says what its card asks for ("free to
   use with credit; changes share alike"), and a voice whose card asks to be named a
   certain way is listed so: Jenny as "Jenny (Dioco)".
4. **Re-audit on catalogue update**: run the script, read what changed.

What changed: the first design was an **allowlist of audited, permissive voices only**.
As built, the GitHub build lists every full-precision voice sherpa-onnx converts and lets
the reader see each licence before downloading.

## 6.5 Voice catalogue format

The first design hosted a signed JSON catalogue and cached it. As built, the catalogue
ships inside the app (`app/assets/voices/catalog.json`, "made by
tools/voice_catalog.py; do not edit by hand"), so the voice list works offline and
changes only with a release. Its shape:

```jsonc
{
  "about": "Natural voices TomeVoice offers. Made by tools/voice_catalog.py; …",
  "version": 1,
  "sources": { "models": "…/sherpa-onnx/releases/download/tts-models/ …",
               "cards": "https://huggingface.co/rhasspy/piper-voices (revision …)" },
  "packs": [
    { "id": "kokoro-multi-lang-v1_0", "engine": "kokoro", "name": "Kokoro",
      "file": "model.onnx", "sampleRate": 24000, "bytes": 349886476,
      "minMemoryMb": 5200, "mustKeepUp": true, "licence": { … } }
  ],
  "voices": [
    { "id": "en_US-lessac-medium", "engine": "piper", "name": "Lessac", "locale": "en-US",
      "quality": "medium", "bytes": 67230653, "sampleRate": 22050, "speakers": 1,
      "sample": "https://huggingface.co/rhasspy/piper-voices/resolve/main/…/speaker_0.mp3",
      "licence": { "name": "…", "use": "noncommercial", "note": "…", "stated": "…",
                   "dataset": "…", "card": "…" } }
  ]
}
```

`use` is set when the script is run, from what the model card says, not derived from a
string at run time.

## 6.6 Licence audit table

Status as of 1.4.0 (2026-10-31). Project licence: **GPL-3.0**; compatibility is judged
against that. Upstream licences change (Piper's did), so each row is to be re-checked when
its component is upgraded.

| Component | Licence | Verdict | Notes |
|---|---|---|---|
| **TomeVoice itself** | **GPL-3.0** | — | [ADR-014](10-decisions-adr.md#adr-014); `LICENSE` in the repository |
| sherpa-onnx (`sherpa_onnx` 1.13.8) | Apache-2.0 | **Used** | Bundles ONNX Runtime (MIT) and eSpeak-NG (GPL-3.0) |
| eSpeak-NG | GPL-3.0 | **Used** | Inside sherpa-onnx; see [C-22](09-challenges-and-solutions.md#c-22) |
| Kokoro-82M weights | Apache-2.0 | **Used** | Tier 2 |
| Kitten TTS nano 0.8 | Apache-2.0 | **Used** | |
| Piper voice models | **mixed, per voice** | **Shown per voice** | §6.4 |
| Piper engine (`piper1-gpl`) | GPL-3.0 | Compatible, unused | |
| Coqui XTTS v2 | CPML (non-commercial) | **Excluded** | Not free software |
| `edge-tts` | unsanctioned endpoint | **Excluded** | Terms, and anti-abuse tokens |
| PdfBox-Android 2.0.27.0 | Apache-2.0 | **Used** | PDF text; BouncyCastle's post-quantum tables left out |
| Tesseract4Android 4.9.0 | Apache-2.0 | **Used** | Bundles Tesseract, Leptonica, libjpeg and libpng |
| tessdata_fast (OCR language data) | Apache-2.0 | **Used** | Downloaded per language, never shipped |
| jump3r 1.0.5 (LAME 3.98.4 in Java) | LGPL-2.1 or later | **Used** | MP3 when saving as audio |
| QuickJS, `flutter_qjs` (pinned by commit) | MIT | **Used** | Web-novel sources |
| cheerio, htmlparser2 and friends, dayjs, core-js; protobufjs, long, @noble/ciphers | MIT, BSD-2/3-Clause, ISC, Apache-2.0 | **Used** | Bundled for LNReader plugins; listed in `app/assets/licenses/third_party.txt` |
| LNReader plugin host conventions | MIT | **Used** | The plugins themselves are downloaded from source lists, never shipped in the APK (a new install fetches two) |
| AndroidX WorkManager | Apache-2.0 | **Used** | |
| Flutter, Dart, `archive`, `xml`, `crypto`, `scrollable_positioned_list`, `material_color_utilities` | BSD-3-Clause, MIT, Apache-2.0 | **Used** | |
| Bodoni Moda, Figtree, Newsreader, Literata, Doto | SIL OFL 1.1 | **Used** | Bundled, licence texts in `app/assets/fonts/` ([ADR-018](10-decisions-adr.md#adr-018)) |
| PDFium through `pdfrx`, miniaudio, Drift, `flutter_inappwebview`, Rubber Band, a CMUdict lexicon | various | **Not used** | Planned in the first design, not needed by what was built |

**Open items from the first design, closed or moot:**

1. The per-voice audit: done as the catalogue's licence field, shown per voice; the
   allowlist became a choice left to the reader (§6.4).
2. Reading fonts: chosen (ADR-018), all OFL.
3. Rubber Band's terms: moot, not used.
4. The GPL-3.0 `LICENSE` file: in the repository, and the source is public. Per-file
   licence headers were not added.
5. Store listing requirements for GPL-3.0: moot while there is no store build
   ([18](18-play-store-audit.md)).

## 6.7 Voice download and storage

**Downloader** (`neural_voices.dart`). From sherpa-onnx's GitHub release, resumable (a
download cut off goes on from where it stopped; a broken archive starts over), and
unpacked file by file on another isolate so memory stays small whatever the voice's
size. There is no Wi-Fi-only rule; a warning before the first download says what voices
cost.

**Storage.** In the library folder's `voices/` (the app's external files folder), one
folder per model, with the phone's speed test result beside it. **Never backed up**: a
backup leaves natural voices out, as they are a download away
([11](11-data-model-and-storage.md)).

**Size discipline.** No voice ships in the APK; the release APK was about 27 MB at
1.0.0. Remove and Remove all take voices off the phone at any time; nothing is deleted
without the reader asking.

**Preview before download.** Every voice but one (in 1.4.0) has a sample to hear first,
streamed (about 100 KB), so nobody spends 125 MB on a voice they dislike.

## 6.8 Store-facing disclosure

There is no store listing now. What the app says, and any listing should:

- Natural voices are synthetic, made on the phone by open models; their recordings'
  licences are shown.
- Natural voices send no text anywhere. The phone's own voices are the phone's: some of
  Google's need the internet, and TomeVoice says so when one cannot reach it.
- Nothing is collected: no account, no analytics. "Report a problem" shows exactly what it
  would send and opens a GitHub issue for the reader to send themselves.
