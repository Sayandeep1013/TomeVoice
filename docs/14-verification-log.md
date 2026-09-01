# 14 — Verification Log

Every load-bearing factual claim in these documents, checked against a primary source,
with the result. A claim is "load-bearing" if being wrong about it would change a
decision.

**Method.** Prefer official vendor documentation; then the project's own repository,
issues and release notes; then package registries. Secondary reporting is used only to
locate a primary source, never as evidence. Every row records the source actually
consulted.

**Re-verification policy.** The whole table is re-run before each release build. Upstream
licences and platform requirements change — Piper's licence did, and it invalidated a
design decision. Rows marked **Recheck** carry a specific trigger.

---

## Pass 1 — 2026-09-01

Run in response to "recheck and reverify all the source docs". 18 claims checked, of
which **2 were wrong** and **1 was materially incomplete**.

### Failed verification

| # | Claim as written | Reality | Impact |
|---|---|---|---|
| 1 | "sherpa-onnx **removed** its eSpeak-NG and `piper-phonemize` dependencies to stay Apache-2.0 clean" — used as the primary rationale in ADR-006, §4.8, §6.3 and C-22 | **False.** A *proposal* for 2.0.0 ([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08). Shipping line is 1.13.7; v1.13.5 notes read "Fix installing espeak-ng-data directory" | **High.** The stated mitigation for an S1 blocker did not exist. Under a permissive or closed licence this would have been a launch-blocking discovery. Rewrote ADR-006, ADR-008, §4.8, §6.3, C-22 |
| 2 | "Ship int8 only on mobile; keep fp32 for Windows" (C-16, ADR-007, §4.6) | **Wrong recommendation.** iPhone 15 measurements ([issue #2374](https://github.com/k2-fsa/sherpa-onnx/issues/2374)): int8 saves 216 MB download but only **51 MB runtime**, and **doubles** synthesis time (39.13 s vs 19.41 s) | **Medium.** Would have spent the C-17 latency budget on the weakest devices for a saving that does not help the memory gate. Reversed to fp32-default |

### Materially incomplete

| # | Gap | Correction |
|---|---|---|
| 3 | The Windows capability matrix omitted `AppendedSilence` and `PunctuationSilence` (`SpeechSynthesizerOptions`, Windows 10 1803+) | Added to §4.2 and §5.4. Windows can do part of our pause shaping natively; worth benchmarking against the DSP path |

### Verified correct

| # | Claim | Source | Result |
|---|---|---|---|
| 4 | `onRangeStart(String, int, int, int)`; 4th param is a frame position in the request's audio | [Android API reference (via .NET binding docs)](https://learn.microsoft.com/en-us/dotnet/api/android.speech.tts.utteranceprogresslistener.onrangestart) | ✅ Verbatim: *"The position in frames in the audio of the request where this range is spoken."* `ApiSince=26`, matching our `minSdk` exactly |
| 5 | Word timings are engine-dependent, not guaranteed | same | ✅ **Sharpened.** *"Only called if the engine supplies timing information by calling `SynthesisCallback#rangeStart(int, int, int)`."* This is now the precise statement of spike risk R1 |
| 6 | Windows exposes word-boundary metadata | [SpeechSynthesizerOptions](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizeroptions) | ✅ `IncludeWordBoundaryMetadata` and `IncludeSentenceBoundaryMetadata` both present |
| 7 | Windows exposes native rate / pitch / volume | same | ✅ `SpeakingRate`, `AudioPitch`, `AudioVolume`, all added in Windows 1709 (SDK 16299) — below our 1809 floor |
| 8 | PDFium gives per-character geometry through `pdfrx` | [`PdfPageText`](https://pub.dev/documentation/pdfrx/latest/pdfrx/PdfPageText-class.html) | ✅ `charRects` (per-character `PdfRect`s aligned to `fullText`) plus `fragments`. The PDF layout plan in §3.3 is viable with the package already chosen |
| 9 | `pdfrx` is current, permissive, and covers our platforms | [pub.dev](https://pub.dev/packages/pdfrx) | ✅ v2.5.0, **MIT**, Android + iOS + Windows + macOS + Linux + Web, PDFium-backed |
| 10 | `sherpa_onnx` is current, Apache-2.0, covers our platforms via FFI | [pub.dev](https://pub.dev/packages/sherpa_onnx) | ✅ v1.13.7 (2026-09-01), Apache-2.0, Android + Windows + more, `dart:ffi` |
| 11 | sherpa-onnx exposes no word-timing API | pub.dev docs + release notes review | ✅ Confirmed absent. **C-13 stands as the second-largest technical risk** |
| 12 | Kokoro-82M weights are Apache-2.0 | [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | ✅ Apache-2.0, unrestricted commercial use |
| 13 | Piper engine relicensed MIT → GPL-3.0 | `rhasspy/piper` archived Oct 2025; [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) | ✅ Confirmed. Now compatible with our own licence rather than a blocker |
| 14 | Piper voices carry mixed licences with no machine-readable commercial flag | Piper voices repository / model cards | ✅ Confirmed. Per-voice audit requirement stands |
| 15 | Play requires target API 36 for new apps from 31 Aug 2026 | [Play target SDK requirements](https://developer.android.com/google/play/requirements/target-sdk) | ✅ Exact. New apps and updates → API 36; existing apps → API 35; extension to 1 Nov 2026. Deadline already passed, so API 36 from the first commit |
| 16 | GitHub Actions is free and unmetered for public repositories | [GitHub billing docs](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions) | ✅ Standard runners on public repos remain free and unmetered in 2026. Underpins [ADR-016](10-decisions-adr.md#adr-016) |
| 17 | EAS Build is not a Flutter path | [EAS Build docs](https://docs.expo.dev/build/introduction/) | ✅ React Native / Expo pipeline. A newer "Expo Launch" claims Flutter support but EAS Build proper does not target it |
| 18 | `edge-tts` uses an unsanctioned endpoint now requiring anti-abuse tokens | Vendor Q&A + project discussions | ✅ Confirmed. Remains excluded on both legal and reliability grounds |

---

## Pass 2 on 2026-09-02 (device)

First run on real hardware: Nothing A059, Android 16 (API 36), Google TTS. Full detail
in [15.17](15-spike-audio-engine.md#1517-device-run-1-on-2026-09-02).

| # | Claim | Result |
|---|---|---|
| 19 | `onRangeStart` fires with per-word granularity on Google TTS | **Confirmed.** 17 events for a 17-word utterance. R1 lands on the best-case branch for this engine |
| 20 | The documented **parameter order** `onRangeStart(utteranceId, start, end, frame)` | **WRONG on this device.** Google TTS delivers `(frameInAudio, charStart, charEnd)`, matching the engine-side `SynthesisCallback#rangeStart(markerInFrames, start, end)` it forwards from. Pass 1 row 4 verified what the parameters *mean* from the documentation; it did not, and could not, verify the order they actually arrive in |
| 21 | Android system TTS returns usable PCM via `synthesizeToFile` | **Confirmed.** 129,621 frames at 24 kHz, decoded cleanly by our WAV reader |
| 22 | A device offers several selectable TTS engines | **Not true here.** Only `com.google.android.tts` is installed, so per-engine variation is still unmeasured |

**What this says about the method.** Row 20 is the one that matters: it was *verified
against primary documentation in Pass 1 and still wrong in practice*. Documentation
review establishes what an API promises, not what an implementation does. Anything a
device can settle should be settled on a device before code is built on top of it.

It also vindicates the stage trace. The symptom was "the word-gap setting does nothing";
the per-stage frame counts showed edge-trim removing 46,204 frames immediately after
word-gap inserted 46,080, which turned an open-ended hunt into a five-minute diagnosis.

---

## Claims deliberately **not** yet verified

Recorded so their status is not mistaken for verified fact.

| Claim | Where | Why deferred | Verify by |
|---|---|---|---|
| Piper voice sizes (20–28 / 63 / ~130 MB by quality tier) | §4.5, C-25 | Secondary sources only; does not change any decision | Phase 3, from actual model files |
| Kokoro RTF ~0.45 on a mid-range Android SoC | §2.7, C-17 | Secondary source; iOS figures in row 2 are the primary evidence | Phase 3, on Android reference devices |
| Piper peak RAM ~50–150 MB | §4.2 | Secondary; the memory gate is calibrated by measurement anyway | Phase 3 |
| `flutter_tts` Windows `MissingPluginException` | §4.4, C-29, ADR-013 | Issue exists, but the decision rests on API *shape* (play-vs-bytes), not the bug | Not needed — rationale does not depend on it |
| Rubber Band's exact current terms | §5.2, C-14 | GPL arm is sufficient for us; version-specific check is cheap and late-binding | Phase 3, at integration |
| OEM background-kill behaviour (Xiaomi, Samsung, OPPO, vivo) | §7.4, C-26 | Not verifiable from documentation; only real devices settle it | Phase 6 beta, on physical devices |
| Android 17 per-app memory limits, exact thresholds | §7.1, C-16 | Announced; specifics still moving | Before Phase 3 gate calibration |
| Windows "natural" voices not always reachable via WinRT | §4.4, §8.2 | Build-dependent; must be probed at runtime regardless | Phase 2, on real Windows builds |
| EV certificates no longer bypass SmartScreen (2024) | §8.5, C-30 | Secondary sources agree, but it is a Phase 6 concern | Phase 6 |
| 458-day code-signing validity cap from 1 Mar 2026 | §8.5 | Same | Phase 6 |

---

## Recheck triggers

| Watch | Trigger | Consequence if it fires |
|---|---|---|
| sherpa-onnx **2.0.0** | Major version release | eSpeak-NG removed. Migrate to a supplied `lexicon.txt` or pre-tokenised phonemes. **Pin the version; do not auto-upgrade across 2.0** |
| sherpa-onnx word timings | Any release exposing model durations | Upgrades neural voices from sentence- to word-level highlighting (C-13). Actively wanted |
| Piper voice catalogue | Any voice added to our allowlist | Fresh per-voice licence audit (C-23) |
| Play target SDK | Annual, ~August | Bump `targetSdk` |
| Android memory limits | Android 17 stable | Recalibrate the Tier 2 gate (C-16) |
| Kokoro licence | Any upstream change | Would affect Tier 2 viability |

---

## What this pass changed

| Document | Change |
|---|---|
| [ADR-006](10-decisions-adr.md#adr-006) | Rationale corrected; runtime choice unchanged |
| [ADR-007](10-decisions-adr.md#adr-007) | int8 → fp32 default, with the measurement table |
| [ADR-008](10-decisions-adr.md#adr-008) | Superseded; eSpeak-NG now used deliberately |
| [ADR-014](10-decisions-adr.md#adr-014) | Resolved: GPL-3.0 |
| [ADR-016](10-decisions-adr.md#adr-016) | **New** — Dart SDK local, APKs in CI |
| [ADR-017](10-decisions-adr.md#adr-017) | **New** — the "specimen" visual direction |
| [§3.3](03-document-pipeline.md#33-pdf-the-hard-one) | `pdfrx.charRects` citation added |
| [§4.2](04-tts-engine-contract.md#42-capability-matrix) | Windows silence options added |
| [§4.3](04-tts-engine-contract.md#43-adapter-android-system-tts) | `onRangeStart` caveat quoted; `onAudioAvailable` noted as an alternative |
| [§4.6](04-tts-engine-contract.md#46-adapter-kokoro-via-sherpa-onnx) | Quantisation table and the int8 trap |
| [§4.8](04-tts-engine-contract.md#48-phonemisation) | Retitled and rewritten |
| [§5.2](05-tts-controls-spec.md#52-pitch) | Licence note resolved |
| [§5.4](05-tts-controls-spec.md#54-pause-shaping) | Windows native silence noted |
| [§6.3](06-voice-catalog-and-licensing.md#63-licence-findings-for-engines-and-runtimes) | Rewritten against GPL-3.0 |
| [§6.6](06-voice-catalog-and-licensing.md#66-licence-audit-table) | Table and open items rewritten |
| [C-14](09-challenges-and-solutions.md#c-14), [C-22](09-challenges-and-solutions.md#c-22), [C-23](09-challenges-and-solutions.md#c-23) | Downgraded or closed |
| [C-16](09-challenges-and-solutions.md#c-16) | Measurement table; int8 recommendation reversed |

**Net effect on the register:** three S1 entries closed or downgraded, one S2 downgraded,
one S1 correction that made a risk *sharper* rather than smaller (C-13). The GPL-3.0
decision did most of that work; the verification pass caught the rest.
