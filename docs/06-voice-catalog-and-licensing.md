# 06 — Voice Catalog & Licensing

"Free AI TTS voices" is the easiest sentence in the brief to write and one of the
riskiest to implement. The models are free to *download*; they are not uniformly free to
*ship in a product*. This document is the audit.

## 6.1 The rule

**Nothing enters a build without a licence entry.** Every model, every voice, every
native library gets a row in §6.6 with its licence, its source URL, and a verdict. A
voice with an unverified licence is not shipped, however good it sounds.

The reason is asymmetric risk: shipping a non-commercial voice for a year and then
discovering it costs a takedown, a forced app update, a store review, and possibly a
claim. Checking a licence costs ten minutes.

## 6.2 The tier model

| Tier | Engine | Download | Quality | RAM | Availability |
|---|---|---|---|---|---|
| **0 — System** | Android TTS / Windows WinRT | none | fair–good | tens of MB | every device |
| **1 — Neural (default)** | Piper via sherpa-onnx | 20–130 MB per voice | good | ~50–150 MB | most devices |
| **2 — Neural HD** | Kokoro via sherpa-onnx | ~90–330 MB total | very good | several hundred MB | gated on device capability |
| **3 — Cloud (optional)** | user's own API key | none | excellent | none | opt-in, never bundled |

Tier 0 is the default on first launch: it works instantly, needs no download, uses
almost no memory, and gives us word timings for free. Tiers 1 and 2 are discovered
through a Voice Store screen.

Tier 3 is deliberately **bring-your-own-key**. If a user has an Azure, Google or
ElevenLabs key, we let them use it. We never bundle credentials, never proxy through our
own servers, and never make cloud a requirement. This keeps the local-first promise and
keeps us out of the business of paying per-character for other people's reading.

## 6.3 Licence findings for engines and runtimes

> **Framing note.** TomeVoice is **GPL-3.0** ([ADR-014](10-decisions-adr.md#adr-014)).
> That makes GPL components compatible rather than dangerous, and removes the
> commercial-use dimension from the per-voice audit. It does **not** remove the audit —
> redistribution restrictions and CC-BY attribution still bind us regardless of our own
> licence.

**sherpa-onnx — Apache-2.0. Approved.** Our neural runtime, v1.13.7.

> **Correction, 2026-09-01.** An earlier version of this section claimed the project
> *"deliberately removed its eSpeak-NG and `piper-phonemize` dependencies to stay
> Apache-2.0 clean"*, and used that as the main reason to choose it. **The claim was
> false.** The removal is a proposal for a future 2.0.0
> ([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08).
> Shipping 1.13.x still bundles eSpeak-NG — v1.13.5's notes read "Fix installing
> espeak-ng-data directory". Under GPL-3.0 this is harmless; under any other licence it
> would have been a launch-blocking discovery.

**Piper engine — GPL-3.0. Compatible.** `rhasspy/piper` was MIT and was archived in
October 2025; development moved to `OHF-Voice/piper1-gpl`, which is GPL-3.0. Under our
own GPL-3.0 licence we may link it. In practice we still consume Piper's **ONNX model
files** through sherpa-onnx because that is one integration instead of two — a
convenience choice now, not a licence constraint.

**eSpeak-NG — GPL-3.0. Approved and used deliberately.** The grapheme-to-phoneme front
end both Piper and Kokoro were trained against, so it yields the phoneme distribution
those models expect. Its language coverage is far wider than any lexicon-plus-rules
substitute we would have written. See
[§4.8](04-tts-engine-contract.md#48-phonemisation).

**Kokoro-82M — Apache-2.0. Safe.** Weights released under Apache-2.0, which permits
commercial deployment without restriction. The best licence-to-quality ratio available
today, and the reason Tier 2 exists at all.

**Coqui XTTS v2 — CPML. Still excluded.** The Coqui Public Model Licence is
non-commercial. GPL-3.0 removes our own commercial ambitions from the equation, but CPML
is not a free-software licence and is incompatible with GPL-3.0 redistribution — we
cannot ship the weights under our own terms. Voice cloning waits for a model with
compatible terms.

**`edge-tts` and similar — cannot ship.** These call an undocumented Microsoft Edge
"Read Aloud" endpoint that is not public or endorsed. Microsoft sells the same voices
through Azure. Beyond the terms-of-service exposure, the endpoint now requires
short-lived anti-abuse tokens and filters cloud IP ranges, so it is also *technically*
unreliable — it would break in the field without warning. Excluded on both grounds.

**Rubber Band Library — GPL / commercial dual. Approved.** The best-known pitch/time
library. Its GPL arm is exactly what our own licence permits, so it is available at no
cost and with no custom DSP work. Confirm the specific version's terms at integration
time in Phase 3.

## 6.4 The per-voice trap

Even with a safe engine, **individual voices carry their own licences**, and Piper's
catalogue mixes CC0, CC-BY 4.0, MIT, Apache-2.0 and several research-only /
non-commercial voices. There is no `commercial_ok` flag in the catalogue metadata to
filter on; the licence lives in each voice's model card.

Consequences for implementation, and these are not optional:

1. **Never enumerate an upstream voice list at runtime and offer everything.** That
   would ship whatever licence upstream added last week.
2. **Maintain our own allowlist**, audited once per voice, stored as a signed catalogue
   file we host.
3. **Store the licence with the voice** and show it in the UI — voice detail screen,
   and an aggregated "Voice licences" page in About.
4. **Honour attribution.** CC-BY voices require credit; that page is how we give it.
5. **Re-audit on catalogue update**, as part of the release checklist.

## 6.5 Voice catalogue format

Hosted as a signed JSON document, cached locally, with the app shipping a fallback copy
so the Voice Store works offline-first.

```jsonc
{
  "catalogueVersion": 7,
  "voices": [
    {
      "id": "piper-en_GB-alba-medium",
      "engine": "piper",
      "displayName": "Alba",
      "language": "en-GB",
      "gender": "female",
      "quality": "medium",
      "sampleRate": 22050,
      "files": [
        { "url": "...", "sha256": "...", "bytes": 63438080, "role": "model" },
        { "url": "...", "sha256": "...", "bytes": 4821,     "role": "config" }
      ],
      "totalBytes": 63442901,
      "approxPeakMemoryMb": 90,
      "minTier": 1,
      "licence": { "spdx": "CC-BY-4.0",
                   "attribution": "...",
                   "sourceUrl": "...",
                   "auditedAt": "2026-09-01",
                   "verdict": "approved" },
      "previewUrl": "..."
    }
  ]
}
```

`verdict` is an explicit human decision — `approved`, `rejected`, or `pending` — not
something derived from the SPDX string at runtime. Only `approved` voices are listed.

## 6.6 Licence audit table

Status as of 2026-09-01. **Every row must be re-verified against its source before the
first release build**, because upstream licences change — as Piper's did.

Project licence: **GPL-3.0**. Compatibility below is judged against that.

| Component | Licence | Verdict | Notes |
|---|---|---|---|
| **TomeVoice itself** | **GPL-3.0** | — | [ADR-014](10-decisions-adr.md#adr-014), public repo |
| sherpa-onnx | Apache-2.0 | **Approved** | v1.13.7. GPL-3.0-compatible. Bundles eSpeak-NG today |
| ONNX Runtime | MIT | **Approved** | Via sherpa-onnx |
| Kokoro-82M weights | Apache-2.0 | **Approved** | Tier 2 |
| Piper voice models | **mixed, per voice** | **Per-voice audit** | Commercial-use dimension now moot; redistribution + CC-BY attribution still bind |
| Piper engine (`piper1-gpl`) | GPL-3.0 | **Approved, unused** | Compatible; we go via sherpa-onnx for simplicity |
| eSpeak-NG | GPL-3.0 | **Approved, used** | G2P front end. Was excluded; see [C-22](09-challenges-and-solutions.md#c-22) |
| Rubber Band | GPL / commercial | **Approved** | GPL arm. Was excluded |
| Coqui XTTS v2 | CPML (non-commercial) | **Excluded** | Not free software; GPL-incompatible |
| `edge-tts` | unsanctioned endpoint | **Excluded** | ToS + anti-abuse tokens make it fragile |
| PDFium (via `pdfrx`) | BSD-3-Clause / MIT | **Approved** | `pdfrx` 2.5.0 is MIT; verified 2026-09-01 |
| miniaudio | public domain / MIT-0 | **Approved** | |
| CMUdict-derived lexicon | BSD-style | **Approved** | Optional now that eSpeak-NG is in |
| Flutter, Dart, Drift | BSD-3 / MIT | **Approved** | |
| `flutter_inappwebview` | Apache-2.0 | **Approved** | |
| Fonts shipped for reading | *not yet chosen* | **Pending** | Open-licence only; check embedding rights |

**Open items to close before release:**

1. Complete the per-voice Piper audit and publish the initial allowlist. *(The only
   item that survived the GPL-3.0 decision unchanged.)*
2. Choose the reading fonts and verify their embedding terms.
3. Confirm the specific Rubber Band version's GPL terms at integration time.
4. Add the GPL-3.0 `LICENSE` file, per-file headers, and the written-offer / source
   availability notice required for distributed binaries.
5. Verify Google Play and Microsoft Store listing requirements for GPL-3.0 applications
   — both accept them, but the Store's own terms need a read against copyleft
   distribution.

## 6.7 Voice download and storage

**Downloader.** Resumable, background-capable, Wi-Fi-only by default with an explicit
"download on mobile data" confirmation. SHA-256 verified on completion; a failed hash
deletes and retries once, then reports honestly rather than leaving a corrupt model that
crashes at load.

**Storage.** Voices live outside the app bundle, in app-private storage on Android and
`%LOCALAPPDATA%` on Windows. They are never backed up to cloud backup services — they
are re-downloadable and would waste the user's backup quota.

**Size discipline.** The base app must stay under ~120 MB before any voice download.
That means ONNX Runtime and PDFium are the only large natives in the base build, and no
neural voice ships pre-installed.

**Eviction.** An LRU suggestion when storage runs low — never automatic deletion. A
user's downloaded voices are theirs; silently removing a 300 MB download they made on
Wi-Fi last month is hostile.

**Preview before download.** Every voice has a short hosted preview clip, so nobody
spends 130 MB on a voice they dislike. This is the single highest-value item in the
Voice Store UI.

## 6.8 Store-facing disclosure

Both stores increasingly expect clarity about AI features. We should state plainly, in
the listing and in the app:

- Neural voices are synthetic, generated on-device by open models.
- No text is sent anywhere for Tier 0/1/2. Synthesis is entirely local.
- Cloud voices (Tier 3) send text to a service the user configures with their own key,
  and the app says so at the point of enabling it.

That last point is the one that matters for the Data Safety declaration: the honest
answer is "no data collected" for the default configuration, with a documented exception
for user-configured cloud voices.
