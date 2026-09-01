# 10 — Decision Log (ADRs)

Each record: the decision, the alternatives considered, why they were rejected, and what
it costs us. Decisions are dated and may be superseded, never silently edited.

Status values: **Accepted** · **Proposed** · **Superseded** · **Open**

---

## ADR-001
**Flutter as the application framework** — Accepted, 2026-09-01

**Context.** One codebase must produce a good Android app and a good Windows desktop
app, both able to load native libraries for neural inference and DSP.

**Decision.** Flutter, with C/C++ via FFI for inference and audio.

**Alternatives rejected.**

- *React Native + React Native Windows.* Windows support is real but second-class:
  community/Microsoft-maintained rather than first-party-stable, with a thinner
  ecosystem for desktop. For an app whose desktop half is a first-class deliverable,
  that is the wrong asymmetry.
- *.NET MAUI.* Excellent Windows story, weaker Android polish, and no comparable path to
  the on-device neural TTS ecosystem we depend on.
- *Electron plus a separate mobile app.* Two codebases, and Electron's footprint is
  poor value for a reading app.
- *Native Kotlin + native WinUI.* Best possible result per platform, roughly double the
  work, and every feature in [05](05-tts-controls-spec.md) would be implemented twice.

**Consequences.** Flutter's desktop targets are stable but less battle-tested than
mobile; expect to write more platform plugins than a mobile-only app would
([ADR-013](#adr-013)). Text rendering for the EPUB view goes through a WebView rather
than Flutter widgets ([ADR-005](#adr-005)).

---

## ADR-002
**Tiered TTS: system voices by default, neural voices as an upgrade** — Accepted, 2026-09-01

**Context.** Neural voices are the headline feature, but they cost hundreds of megabytes
of download and RAM, and the best one does not fit on a large share of Android devices
([C-16](09-challenges-and-solutions.md#c-16)).

**Decision.** Four tiers — system, Piper, Kokoro, optional bring-your-own-key cloud.
System is the default; neural is discovered and downloaded deliberately.

**Alternatives rejected.**

- *Neural-only.* Enormous first-run download, excludes low-end devices, and throws away
  the free word timings system engines provide.
- *Bundle one neural voice.* Adds 60–130 MB to the base download for a voice most users
  will replace, and complicates per-ABI packaging.

**Consequences.** First-run quality is only as good as the user's installed system voice,
which varies. Mitigated by making the Voice Store prominent and the first neural download
a single tap.

---

## ADR-003
**Synthesise to PCM and run our own player; never call `speak()`** — Accepted, 2026-09-01

**The pivotal decision.**

**Context.** The product promises word-gap control, pitch on every voice, arbitrary
speed, pause shaping and precise scrubbing. Platform "speak this text" APIs offer none of
that beyond a rate and pitch slider.

**Decision.** Every engine returns PCM plus word timings
([Contract B](04-tts-engine-contract.md)). We own the audio pipeline and the player.

**Alternatives rejected.**

- *Use `speak()` and expose only what the platform supports.* Simplest by far, and it
  makes the differentiating features impossible. Word gap does not exist on any engine
  ([C-12](09-challenges-and-solutions.md#c-12)).
- *SSML for everything.* Only partially supported, absent entirely from Piper and Kokoro,
  destroys prosody when used per word, and breaks Android's `onRangeStart` offsets by
  changing the indexed string.

**Consequences.** Significant. We must implement audio focus, ducking, interruption,
device changes, buffering and the media session ourselves — everything `speak()` would
have handled. This is the largest architectural cost in the project. It is also what
makes the product distinctive, and it is unavoidable given the requirements.

---

## ADR-004
**One Document Model for all formats** — Accepted, 2026-09-01

**Context.** Four-plus input formats times two consumers (renderer, speech engine) is a
combinatorial mess if handled directly.

**Decision.** All formats normalise to Book → Section → Block → Sentence → Word with
format-native anchors. Parsers know nothing about speech; engines know nothing about
formats.

**Consequences.** Some format-specific richness is flattened. Fixed-layout EPUBs and
complex PDF tables do not fit the model well and get special handling. Worth it: every
feature in [05](05-tts-controls-spec.md) is written once.

---

## ADR-005
**EPUB rendered in a WebView; PDF rendered natively via PDFium** — Accepted, 2026-09-01

**Context.** An EPUB is HTML and CSS. A PDF is a page-description format. They want
different renderers.

**Decision.** WebView (`flutter_inappwebview`) with a controlled epub.js-style renderer
for EPUB; PDFium via `pdfrx` for PDF, with our own text overlay.

**Alternatives rejected.**

- *Render EPUB with Flutter widgets.* Full control and better integration, but it means
  reimplementing enough of CSS to survive real books. Fidelity losses show up immediately
  on anything with a designed layout.
- *Render PDF in the WebView with PDF.js.* Slower, heavier, and it hides the glyph
  geometry that reading-order analysis needs ([C-01](09-challenges-and-solutions.md#c-01)).

**Consequences.** Two rendering paths and two highlighting implementations — an injected
script resolving CFIs to client rects for EPUB, a quad overlay for PDF. Both feed the
same Document Model, so the layer above is shared.

---

## ADR-006
**sherpa-onnx as the neural TTS runtime** — Accepted, 2026-09-01

**Context.** We need Piper and Kokoro on Android and Windows from Dart.

**Decision.** sherpa-onnx via its published Dart/Flutter FFI bindings.

**Why it wins.** It is Apache-2.0; it covers Piper, VITS, Kokoro and Matcha behind one
API; and it has published, actively maintained Android and Windows Flutter packages
(v1.13.7, released 2026-09-01).

**Correction, 2026-09-01.** An earlier draft of this ADR claimed sherpa-onnx had
"deliberately removed its eSpeak-NG and `piper-phonemize` dependencies to stay Apache-2.0
clean". **That was wrong.** The removal is a *proposal* for a future 2.0.0
([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08); the
shipping 1.13.x line still bundles eSpeak-NG — v1.13.5's release notes read "Fix
installing espeak-ng-data directory". Using sherpa-onnx today means shipping GPL-3.0
eSpeak-NG.

Under [ADR-014](#adr-014) (GPL-3.0) that is harmless, and in fact welcome — see
[ADR-008](#adr-008). The choice of runtime stands unchanged. Had we gone permissive or
closed, this finding would have forced either a custom sherpa-onnx build with eSpeak-NG
excluded, or a wait for 2.0.0.

**Alternatives rejected.**

- *ONNX Runtime directly.* More control, but we would rebuild tokenisation,
  phonemisation and model plumbing per architecture for no gain.
- *Per-engine native libraries.* Piper's engine is GPL-3.0, which under
  [ADR-014](#adr-014) is now permitted — so this stays available as a fallback if
  sherpa-onnx ever blocks us, rather than being ruled out.

**Consequences.** We depend on an upstream project for a core capability. The known gap
is word timings ([C-13](09-challenges-and-solutions.md#c-13)); the plan is an upstream
contribution to expose model durations, with proportional estimation until then.

---

## ADR-007
**Kokoro is device-gated and never the default** — Accepted, 2026-09-01

**Context.** Measured runtime footprint is several hundred megabytes; Android heap
ceilings vary by device and Android 17 adds explicit per-app limits.

**Decision.** Tier 2 is offered only on devices passing a memory gate, unloads
aggressively when idle, and falls back gracefully with an explanation on load failure.

**Quantisation: ship fp32, not int8. Revised 2026-09-01.** An earlier draft said "ship
int8 only on mobile". The measurements say otherwise
([issue #2374](https://github.com/k2-fsa/sherpa-onnx/issues/2374), iPhone 15):

| | Package | Runtime footprint | Synthesis time |
|---|---|---|---|
| fp32 | 319 MB | 837 MB | **19.41 s** |
| int8 | 103 MB | 786 MB | **39.13 s** |

int8 saves 216 MB on disk but only **51 MB of runtime memory** — it does not move the
number the memory gate actually cares about — while **doubling synthesis time**. Since
the gate already excludes devices that cannot hold ~800 MB, int8 buys download size at
the cost of the latency budget in [C-17](09-challenges-and-solutions.md#c-17), on exactly
the weakest devices that pass.

So: **fp32 by default on both platforms**, with int8 offered as an explicit
"smaller download, slower speech" choice for storage-constrained users who have the RAM.
Re-measure on Android reference devices during Phase 3 — these figures are iOS and may
not transfer.

**Consequences.** The best voice is unavailable to some users, and it is a larger
download than it needed to be. We state both reasons rather than hiding the option: a
visible "your device does not have enough memory for this voice" is more respectful than
an unexplained absence.

---

## ADR-008
**No eSpeak-NG in the shipped binary** — **Superseded by [ADR-014](#adr-014)**, 2026-09-01

**Original context.** eSpeak-NG is the default grapheme-to-phoneme front end for both
Piper and Kokoro and is GPL-3.0. Linking it propagates GPL to the whole application,
which was unacceptable while the project licence was undecided.

**Original decision.** Ship no eSpeak-NG; use a licence-clean front end plus permissive
lexicons and rule-based out-of-vocabulary fallback.

**Why it is superseded.** The project adopted GPL-3.0 on 2026-09-01. eSpeak-NG's licence
is now aligned with our own, so the constraint disappears entirely.

**Replacement decision.** **Use eSpeak-NG as the grapheme-to-phoneme front end.** It is
what both Piper and Kokoro were trained against, so it produces the phoneme distribution
the models expect — a lexicon-plus-rules substitute would have been both more work and
worse. It also brings far wider language coverage, and lets us consume sherpa-onnx's
1.13.x line exactly as shipped rather than maintaining a custom build.

**Consequence.** The language roadmap widens considerably, and
[C-22](09-challenges-and-solutions.md#c-22) is closed rather than mitigated. If
sherpa-onnx 2.0.0 later drops eSpeak-NG, the documented escape hatches — supplying a
`lexicon.txt`, or passing pre-tokenised phoneme strings — make that a migration rather
than a blocker.

---

## ADR-009
**Permissively licensed voices only, from an audited allowlist** — Accepted, 2026-09-01

**Context.** Piper's voice catalogue mixes CC0, CC-BY, MIT, Apache and non-commercial
licences with no machine-readable commercial-use flag.

**Decision.** We host our own signed catalogue containing only voices with a human
`verdict: approved`. Never enumerate an upstream list at runtime. Store each licence with
its voice, surface it in the UI, honour CC-BY attribution.

**Consequences.** Manual audit work per voice, and re-audit on catalogue updates. Fewer
voices at launch than a "just list everything upstream has" approach. This is the correct
trade.

---

## ADR-010
**No DRM support, ever** — Accepted, 2026-09-01

**Context.** Kindle and Adobe ADEPT books are encrypted. Readium LCP is implementable but
requires paid per-application certification.

**Decision.** Out of scope permanently. Detect encryption and explain clearly, without
suggesting workarounds.

**Consequences.** A real reduction in addressable content. State it in the store listing
so users learn it before installing, not after.

---

## ADR-011
**Local-first, no account required** — Accepted, 2026-09-01

**Decision.** The app is fully functional offline, forever, with no account. Books never
leave the device. Sync, when it arrives, is opt-in and carries state only — never book
files. Cloud voices are bring-your-own-key.

**Consequences.** No server costs and a strong privacy story, at the cost of the
frictionless sync a cloud-first product would have. Given the audience — people reading
their own files, often books they care about privately — this is the right side of the
trade.

---

## ADR-012
**SQLite via Drift for all local state** — Accepted, 2026-09-01

**Decision.** One database for library, reading state, settings, dictionaries, the voice
catalogue cache and the parsed-document cache. Files (books, voice models, covers) live
on disk and are referenced by path.

**Alternatives rejected.** Key-value stores lack the querying the library view needs;
a document store adds a dependency for no gain over SQLite's JSON support.

---

## ADR-013
**Our own Windows speech plugin instead of `flutter_tts`** — Accepted, 2026-09-01

**Context.** `flutter_tts` claims Windows support but has a documented history of
`MissingPluginException` on core methods there, and it is a *play the text* API where we
need *bytes plus word markers*.

**Decision.** A focused C++/WinRT plugin around `SpeechSynthesizer`,
`SynthesizeTextToStreamAsync` and word-boundary metadata.

**Consequences.** A few hundred lines of C++ to maintain, and we own its bugs. In
exchange we get exactly Contract B and drop a dependency we would otherwise be fighting.
The Android side may still use platform channels to the system `TextToSpeech` API
directly, for the same reason.

---

## ADR-014
**Project licence: GPL-3.0** — Accepted, 2026-09-01

**Context.** The licence is not a formality here. It determines whether eSpeak-NG is
usable (and therefore our language coverage), whether GPL DSP libraries are available,
and whether the per-voice non-commercial filter constrains the voice catalogue.

**Decision.** **TomeVoice is licensed GPL-3.0.** The repository is public.

**What this unlocks — three previously open problems close at once:**

| Was | Now |
|---|---|
| [C-22](09-challenges-and-solutions.md#c-22) eSpeak-NG is GPL-3.0, S1 blocker | Use it. Best-matched G2P for Piper and Kokoro, widest language coverage |
| [C-23](09-challenges-and-solutions.md#c-23) Piper engine relicensed to GPL-3.0, S1 | Link it directly if it ever beats going through sherpa-onnx |
| [C-14](09-challenges-and-solutions.md#c-14) GPL/commercial pitch-shift libraries, S2 open audit | Use a GPL stretcher. No custom DSP implementation needed to unblock Phase 3 |

**Secondary benefit.** A public repository gets free, unmetered GitHub Actions on
standard runners, which is what makes the no-local-toolchain workflow in
[ADR-016](#adr-016) viable at zero cost.

**Alternatives rejected.**

- *Permissive (MIT/Apache-2.0).* Keeps every GPL constraint while giving up copyleft.
  We would have to write our own G2P and lexicon, our own pitch/time stretcher, and
  either wait for sherpa-onnx 2.0.0 or maintain a custom eSpeak-NG-free build —
  several weeks of work and narrower language coverage at launch, bought for a
  permissiveness the project has no commercial need for.
- *Closed source.* All of the above, plus a per-voice commercial-use audit that would
  exclude part of the Piper catalogue.

**Consequences.** Source must be published, and no closed commercial fork is possible.
Both stores accept GPL-3.0 applications. The per-voice licence audit
([ADR-009](#adr-009)) still applies for attribution and for voices whose terms restrict
redistribution, but the non-commercial filter no longer constrains us.

---

## ADR-015
**Word timings are a first-class contract field with an honest provenance flag** — Accepted, 2026-09-01

**Context.** Timing quality varies enormously by engine, and estimated timings are good
enough for gap injection but visibly wrong for highlighting.

**Decision.** `WordTiming.source` records how the timing was obtained. The UI degrades
highlighting granularity automatically when the source is `estimated`.

**Consequences.** Word-level highlighting is available on system voices at launch but
only sentence-level on neural voices until the duration-output work lands. That
difference must be visible in the voice picker so users are not confused by it — and it
must not be promised in marketing before it exists.

---

## ADR-016
**No local Flutter toolchain; Dart SDK locally, APKs built in CI** — Accepted, 2026-09-01

**Context.** The developer does not want a local Flutter/Gradle/Android SDK installation,
citing repeated Gradle friction, and normally builds through hosted CI.

**Decision.**

| Layer | Where |
|---|---|
| Audio pipeline, document model, all logic and tests | **Local, standalone Dart SDK** (no Flutter, no Gradle) |
| APK and Windows builds | **GitHub Actions**, public repository |
| Install and listen | **`adb install`** onto a physical device |

This works because the intellectually risky code is pure Dart. The audio pipeline is
`(Float32List, List<WordTiming>, Settings) -> (Float32List, List<WordTiming>)` — it has
no Flutter dependency, so `dart test` gives millisecond feedback with no Gradle present.
Only the platform adapters (Kotlin/JNI, C++/WinRT) and the UI need a real build, and
those are small, stable surfaces that change rarely.

The GPL-3.0 decision ([ADR-014](#adr-014)) makes the repository public, and public
repositories get free unmetered GitHub Actions on standard runners — so the CI half costs
nothing.

**Alternatives rejected.**

- *Full local Flutter install.* Fastest iteration, including hot reload, but it is exactly
  the Gradle friction the developer asked to avoid. Deferred, not forbidden — revisit at
  Phase 1 when UI iteration begins.
- *Pure CI, nothing local.* Zero footprint, but every "did that gap land at 120 ms?"
  becomes a five-minute wait. Unusable for DSP work.
- *Switch to React Native + Expo EAS.* The developer's familiar toolchain, but it does not
  survive contact with the requirements: `expo-speech` exposes neither PCM nor word
  boundaries, so a custom native module is needed either way — and Expo Go cannot load
  custom native modules, so EAS dev builds carry the same round-trip cost. Meanwhile
  `sherpa_onnx` ships maintained Dart FFI bindings with no React Native equivalent, so we
  would hand-write JSI bindings for two platforms. EAS's advantage cancels out and the
  neural tier gets harder. [ADR-001](#adr-001) stands.

**Consequences.** No hot reload, and a 5–15 minute round trip for anything device-side.
Acceptable during the audio spike, where iteration is local and only finished work is
pushed to the device. It becomes a real cost in Phase 1; mitigation is either installing
Flutter at that point or prototyping UI as static HTML/CSS locally before translating to
widgets once.

---

## ADR-017
**Visual direction: the "specimen" aesthetic** — Accepted, 2026-09-01

**Context.** The developer supplied a reference screenshot — a font-specimen application
(72pt.app displaying the *Ojuju* typeface) — as the visual direction for the Android app.

**Decision.** Adopt that visual language: a soft gradient ground, floating capsule/pill
controls over content rather than fixed bars, rounded chips for secondary actions,
monospace uppercase metadata labels, oversized display type as the focal element, and
very little chrome.

**Why it fits beyond taste.** A font specimen and a reading app share a job: present
type as the subject rather than as the interface. Floating controls that sit over the
page suit a reader where the text should dominate and controls should recede. The
monospace metadata treatment maps naturally onto the technical readouts this app has —
voice name, speed, word gap, position — and gives them a place to live that is
visually distinct from book content.

**Constraints this imposes.** Content typography must be independently controlled by the
user (size, spacing, theme) and cannot inherit the specimen's display face — so the
aesthetic governs *chrome*, not the book text. Floating controls must not occlude text
being read; they need an auto-hide policy tied to playback state. Contrast on a gradient
ground needs verification against accessibility targets in both themes.

**Scope.** Applies from Phase 1, when there is real UI. The audio spike is deliberately
unstyled.
