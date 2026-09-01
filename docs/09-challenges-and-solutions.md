# 09 — Challenges & Solutions

Every known blocker, risk and hard problem, with severity and the chosen mitigation.

**Severity scale**

| | |
|---|---|
| **S1 — Blocker** | Shapes the architecture or removes scope. Must be resolved before building. |
| **S2 — Major** | Significant engineering cost or a visible quality ceiling. Needs a plan. |
| **S3 — Moderate** | Real work, well-understood solution. |
| **S4 — Watch** | Not a problem yet; could become one. |

## Summary

| ID | Challenge | Severity |
|---|---|---|
| [C-01](#c-01) | PDF reading order | S1 |
| [C-02](#c-02) | PDF hyphenation and line joining | S3 |
| [C-03](#c-03) | PDF running headers, footers, page numbers | S3 |
| [C-04](#c-04) | Scanned PDFs need OCR | S2 |
| [C-05](#c-05) | EPUB is arbitrary HTML | S2 |
| [C-06](#c-06) | Text-to-render anchor stability | S2 |
| [C-07](#c-07) | DRM-protected books | S1 (scope) |
| [C-08](#c-08) | MOBI / AZW3 support | S3 |
| [C-09](#c-09) | DOCX complexity | S3 |
| [C-10](#c-10) | Very large documents | S2 |
| [C-11](#c-11) | Sentence segmentation quality | S3 |
| [C-12](#c-12) | **No engine supports word gap** | **S1** |
| [C-13](#c-13) | **No word timings from neural engines** | **S1** |
| [C-14](#c-14) | No pitch control on neural engines | S3 |
| [C-15](#c-15) | Speed quality degradation | S3 |
| [C-16](#c-16) | **Kokoro memory footprint** | **S1** |
| [C-17](#c-17) | Time to first audio | S2 |
| [C-18](#c-18) | Loudness mismatch between voices | S3 |
| [C-19](#c-19) | Text normalisation is unsolved by default | S2 |
| [C-20](#c-20) | Multilingual books | S3 |
| [C-21](#c-21) | Homographs | S3 |
| [C-22](#c-22) | eSpeak-NG GPL contamination — **CLOSED** | — |
| [C-23](#c-23) | Piper per-voice licences (engine issue closed) | S3 |
| [C-24](#c-24) | XTTS and edge-tts unusable | S2 (scope) |
| [C-25](#c-25) | Voice model download size | S2 |
| [C-26](#c-26) | Android background playback survival | S1 |
| [C-27](#c-27) | Audio focus, routing, Bluetooth latency | S3 |
| [C-28](#c-28) | Android 16 KB pages, target SDK, memory limits | S2 |
| [C-29](#c-29) | Windows TTS plugin gap | S2 |
| [C-30](#c-30) | Windows signing and SmartScreen | S3 |
| [C-31](#c-31) | Cross-platform file access | S3 |
| [C-32](#c-32) | Binary size budget | S2 |
| [C-33](#c-33) | Battery drain from neural synthesis | S2 |
| [C-34](#c-34) | Screen reader vs our own TTS | S2 |
| [C-35](#c-35) | Cross-device sync | S3 |
| [C-36](#c-36) | Testing audio output | S2 |
| [C-37](#c-37) | Store policy and AI disclosure | S3 |
| [C-38](#c-38) | Scope creep — the app is three apps | S2 |

---

## Document ingestion

### C-01
**PDF reading order** — S1

A PDF stores glyphs at coordinates, not paragraphs. Two-column papers come out
interleaved line by line; sidebars inject themselves mid-sentence; footnotes appear in
the middle of the body; figure captions land between paragraphs. Read aloud, the result
is incomprehensible — far worse than on screen, because a reader's eye skips what their
ear cannot.

This is the largest single engineering cost in the document pipeline and it is never
100% solved. Commercial products with decades of investment still get complex layouts
wrong.

**Solution.** Full geometric layout analysis rather than a "get page text" call:
glyph clustering into words and lines, vertical band segmentation, whitespace-gutter
column detection per band, then ordering. Full detail in
[§3.3](03-document-pipeline.md#33-pdf-the-hard-one).

**Accepting imperfection, visibly.** Because we will get some pages wrong, the product
must let the user fix it rather than pretending:

- A **reading-order overlay** showing the detected order as numbered regions.
- **Manual region editing** — drag to reorder, mark a region as "skip". Per book,
  persisted, and applied to structurally similar pages.
- A **column-count override** (auto / 1 / 2 / 3) which fixes the majority of failures in
  one tap.

Targets: >99% paragraph accuracy on single-column born-digital PDFs, >90% on two-column
academic papers, with manual correction available for the rest.

### C-02
**PDF hyphenation and line joining** — S3

Lines end mid-word with a hyphen; naive extraction produces "hyphen- ation". But
blindly removing every terminal hyphen turns "well-being" into "wellbeing" and
"co-operate" into "cooperate", corrupting the author's text.

**Solution.** Join when: the line ends with `-`, the next line begins lowercase, and the
joined form is in the language lexicon while the hyphenated form is not. Keep the hyphen
otherwise. Where both forms are valid words, prefer keeping the hyphen — a wrongly kept
hyphen is nearly inaudible; a wrongly removed one changes a word.

### C-03
**PDF running headers, footers, page numbers** — S3

Every page injects the book title and a page number into the middle of the audio stream.

**Solution.** Text repeating at a consistent y-position across many pages is furniture.
Cluster candidate strings by normalised content and position across the document; a
cluster covering more than ~30% of pages in a header/footer band is classified as
`runningHeader` or `pageNumber`. Classified, not deleted, so the setting can restore
them.

### C-04
**Scanned PDFs need OCR** — S2

A large fraction of the PDFs people own — especially older books and academic scans —
have no text layer at all. To us they are blank.

**Solution.** v1 detects the condition (near-zero glyphs plus a full-page image) and
says so plainly with an explanation, rather than opening an empty book. v1.x adds
on-device OCR. That is a substantial subproject: a Tesseract or ONNX OCR model,
per-page processing time, a progress UI, and OCR errors flowing into speech (an OCR'd
"rn" read as "m" sounds wrong in a way it does not look wrong).

Not attempting OCR in v1 is a deliberate scope decision. Doing it badly is worse than
not doing it.

### C-05
**EPUB is arbitrary HTML** — S2

An EPUB is a website in a zip. Real books contain broken markup, `<span>`-per-word
output from bad converters, drop caps split across elements, footnotes inline in the
flow, MathML, ruby annotations, right-to-left text, vertical Japanese writing, fixed-
layout comics, and embedded fonts with unusual glyph coverage.

**Solution.** Render pixels in a WebView (an HTML+CSS document deserves an HTML+CSS
engine) but build the Document Model with our own parser. The block builder must join
adjacent inline runs *before* sentence segmentation, or every drop cap becomes its own
sentence. Fixed-layout EPUBs are detected and offered as page images with a note that
speech is unavailable — that is a scanned comic, not a book we can read aloud.

### C-06
**Text-to-render anchor stability** — S2

Highlighting requires mapping "word 7 of sentence 3 of block 12" onto pixels on screen.
But the reader reflows constantly — font size, margins, window resize, device rotation,
theme. If anchors are positional, every reflow breaks both highlighting and the saved
reading position.

**Solution.** Format-native structural anchors. EPUB CFIs are structural and survive
reflow by design. PDF anchors are page plus quads and survive zoom. DOCX/TXT are
character offsets into immutable text. We never store a scroll offset as a reading
position.

For the WebView, a small injected script resolves a CFI to a DOM range and returns
client rects; the Flutter side draws the highlight overlay from those. Rects are
re-queried on reflow rather than cached.

### C-07
**DRM-protected books** — S1, resolved as a scope decision

Kindle books (AZW/KFX) and Adobe ADEPT EPUBs are encrypted. Circumventing that is
illegal in most jurisdictions and would get the app removed from both stores.

**Resolution.** Permanently out of scope. Detect encryption (`META-INF/encryption.xml`,
PDF `/Encrypt`) and show a clear, non-judgemental message explaining that the file is
protected and cannot be opened, without suggesting workarounds.

Readium LCP is technically implementable but requires per-application certification and
an annual fee from EDRLab; revisit only with revenue justifying it.

This is a real reduction in addressable content and should be stated plainly in the
store listing so users are not disappointed after installing.

### C-08
**MOBI / AZW3 support** — S3

No maintained Dart library exists for these formats, and Amazon's newer KFX is both
proprietary and usually DRM'd.

**Solution.** v1.x. Write a focused parser for the DRM-free subset — PalmDB container,
PalmDOC/HUFF-CDIC decompression, then the embedded HTML which flows into the existing
EPUB path. A contained, well-documented format; roughly a week of work, but not v1.

### C-09
**DOCX complexity** — S3

Tracked changes, comments, footnotes, tables, text boxes, fields, and text in shapes
that lives outside the main flow.

**Solution.** Explicit handling per construct, detailed in
[§3.4](03-document-pipeline.md#34-docx). Default to reading the accepted document
(insertions in, deletions out), exclude comments, and append floating text-box content
at the end of its section rather than interleaving it unpredictably.

### C-10
**Very large documents** — S2

A 900-page PDF, a 40 MB EPUB, a technical manual with 12,000 blocks. Full layout
analysis on open would take minutes; holding the whole model in memory on a 3 GB phone
alongside a neural TTS model is not viable.

**Solution.** Lazy, windowed and cached:

- Parse structure (spine, TOC, page count) eagerly; parse content per section on demand.
- Analyse the current PDF page plus a window around it; promote to whole-document
  analysis in the background at low priority.
- Persist everything, keyed by content hash, so the cost is paid once per book.
- Keep a bounded LRU of hydrated sections in memory.
- Show honest progress for the first-open analysis rather than an indeterminate spinner.

### C-11
**Sentence segmentation quality** — S3

"Dr. Smith went to Washington." must be one sentence. `"Stop!" he said.` must be one.
Chinese and Japanese have no spaces. Bad segmentation produces audible errors: pauses
mid-sentence and run-on sentences with no breath.

**Solution.** ICU break iteration as the base, plus per-language abbreviation exception
lists, plus post-rules for quotes and brackets. A hard ceiling (default 240 characters)
splits over-long sentences at clause boundaries to bound synthesis latency.

---

## Speech

### C-12
**No engine supports word gap** — S1, and the reason the architecture looks as it does

Word separation is an explicit product requirement, driven by the dyslexic-reader and
language-learner personas. **No TTS API we can use exposes it.** Not Android's
`TextToSpeech`. Not Windows `SpeechSynthesizer`. Not Piper. Not Kokoro. It exists in
eSpeak's `-g` flag and essentially nowhere else — and eSpeak is excluded on licence
grounds ([C-22](#c-22)).

**Solution.** Own the PCM. Synthesise to a buffer instead of calling `speak()`, then
insert silence at word boundaries ourselves. This single requirement is what forces
synthesise-to-buffer, which in turn forces our own player, our own scheduler, and the
whole audio pipeline. It is also what makes every *other* control (pitch on neural
voices, arbitrary speed, pause shaping, precise scrubbing) possible, so the cost buys a
great deal.

Implementation detail, rejected alternatives and preset values are in
[§5.3](05-tts-controls-spec.md#53-word-separation-word-gap).

**Consequence to accept:** we lose the "just works" simplicity of `speak()`, including
its handling of audio focus, ducking and interruption. We have to implement all of that
ourselves. This is the single largest architectural cost in the project, and it is
unavoidable given the requirement.

### C-13
**No word timings from neural engines** — S1

Android system TTS gives us word ranges *and frame positions* free via `onRangeStart`.
Windows WinRT gives us stream markers. Piper and Kokoro through sherpa-onnx give us
nothing but samples. Both word highlighting and word-gap injection need those timings.

**Solution.** A four-tier strategy, described fully in
[§4.7](04-tts-engine-contract.md#47-deriving-word-timings-for-neural-engines):

1. Model duration output — VITS and StyleTTS2 both have duration predictors; Kokoro
   exposes token timings in its Python API. Requires surfacing them through sherpa-onnx
   (upstream contribution, or running the graph ourselves).
2. Per-word synthesis — exact, but flattens prosody. Used only for the maximum-separation
   accessibility preset.
3. Forced alignment with a small CTC model — accurate, engine-agnostic, costs a second
   model and a second inference.
4. Proportional estimation — always available, fine for gap injection, drifts visibly
   for highlighting.

**Shipping plan.** v1: (4) with sentence-level highlighting on neural voices, word-level
on system voices, plus (2) behind the accessibility preset. v1.1: (1), upgrading neural
voices to word-level highlighting.

Promising word-perfect highlighting on neural voices in v1 would be a promise we could
not keep, so we should not make it in the store listing.

### C-14
**No pitch control on neural engines** — S2

Piper and Kokoro expose speed but not pitch. Users expect a pitch slider that works on
every voice.

**Solution.** Formant-preserving pitch shift in DSP, applied only when
`capabilities.nativePitch` is false. Exposed in semitones so the setting means the same
thing on every engine.

**Resolved 2026-09-01 — downgraded S2 to S3.** This entry used to carry a licence trap:
Rubber Band, the best-known pitch/time library, is GPL/commercial dual-licensed and would
have required either a paid licence or our own phase-vocoder implementation. It was an
open audit item that could have blocked Phase 3.

[ADR-014](10-decisions-adr.md#adr-014) adopted GPL-3.0, so **GPL stretchers are now
usable**. What remains is ordinary engineering: choose one, integrate it, tune quality at
the edges of the pitch range. No licence work outstanding.

### C-15
**Speed quality degradation** — S3

Engine-native rate sounds natural but degrades outside a band. DSP time-stretching works
at any factor but smears transients, most audibly below 0.7x and above 2.5x.

**Solution.** Hybrid, with the engine doing as much as it can well and DSP taking the
residual, plus a user-facing "prefer natural / prefer smooth" preference for those who
disagree with our crossover on their device. See
[§5.1](05-tts-controls-spec.md#51-speed).

### C-16
**Kokoro memory footprint** — S1

Kokoro is the best-sounding permissively licensed model available and it is too heavy for
a large share of Android devices. Android gives each app a heap ceiling that varies by
device RAM, and Android 17 adds explicit per-app memory limits.

Measured on iPhone 15
([sherpa-onnx issue #2374](https://github.com/k2-fsa/sherpa-onnx/issues/2374)):

| | Package | Runtime footprint | Synthesis time |
|---|---|---|---|
| fp32 | 319 MB | 837 MB | 19.41 s |
| int8 | 103 MB | **786 MB** | **39.13 s** |

Loading Kokoro alongside a parsed 900-page PDF on a 3 GB phone is an OOM kill.

**Solution.** Tiering and honest gating:

- **Kokoro is never the default.** Tier 0 (system) is the out-of-box experience; Tier 1
  (Piper) is the recommended neural upgrade.
- **Gate Tier 2** on measured available memory, total device RAM, and
  `ActivityManager.isLowRamDevice()`. On devices that fail the gate, Kokoro is shown as
  unavailable *with the reason stated*, not hidden.
- **Ship fp32, not int8. Revised 2026-09-01.** An earlier draft of this entry said "ship
  int8 only on mobile". The table above refutes it: int8 saves 216 MB of *download* but
  only 51 MB of *runtime* memory — it barely moves the number the gate actually cares
  about — while **doubling synthesis time**. Since the gate already excludes devices that
  cannot hold ~800 MB, int8 spends the [C-17](#c-17) latency budget on precisely the
  weakest devices that pass. Offer int8 as an explicit "smaller download, slower speech"
  choice rather than a default. These figures are iOS; re-measure on Android reference
  devices in Phase 3.
- **Aggressive lifecycle** — unload the model when playback stops for more than a short
  idle period; reload on resume, accepting the reload latency.
- **Reduce the peer load** — evict hydrated document sections while a Tier 2 voice is
  loaded.
- **Handle the OOM** — catch allocation failure at model load, fall back to Tier 1 or 0,
  and tell the user what happened rather than crashing.

**Accept the outcome:** the very best voice will not be available to every user. That is
a physical constraint, not a bug, and the UI should communicate it as such.

### C-17
**Time to first audio** — S2

Neural synthesis takes real time. Kokoro at ~0.45 RTF on a mid-range SoC needs ~4.5 s of
compute for 10 s of audio, and is slower than real time on weaker hardware. A user
tapping play and waiting three seconds concludes the app is broken.

**Solution.**

- **Split the first sentence.** Synthesise only the first clause of the first sentence to
  get audio out fast, then continue. Perceived latency collapses.
- **Adaptive lookahead** driven by measured RTF; see
  [§2.7](02-architecture.md#27-the-lookahead-scheduler).
- **Warm the model** at reader open, not at play, so the first tap does not pay model
  load.
- **Pre-synthesise on hover/focus** where the intent is visible.
- **Cache the next chapter's opening** so chapter transitions are seamless.
- **Show real progress** on genuinely slow first loads instead of an unexplained delay.

Targets: <300 ms for system voices, <1.2 s for warm neural voices.

### C-18
**Loudness mismatch between voices** — S3

Open models are trained on different corpora and differ by more than 10 dB. Switching
voices at night is unpleasant; mixed-language books switching voices mid-chapter are
worse.

**Solution.** Integrated-loudness measurement per sentence with a smoothed gain toward a
−16 LUFS target, plus a limiter, plus a per-voice manual trim. On by default.

### C-19
**Text normalisation is unsolved by default** — S2

Every engine handles numbers, abbreviations, dates and symbols differently, and most
handle them badly. "1996" as "one thousand nine hundred ninety six" in a novel is
jarring. URLs read character by character are unbearable. Roman numerals in chapter
headings become nonsense.

**Solution.** Normalise ourselves, before the engine ever sees the text, with a rule set
per language and a source-range-preserving edit model so highlighting still aligns. Full
table in [§3.7](03-document-pipeline.md#37-text-normalisation-for-speech). This is
ongoing work — the rule set grows with real-world reports — so it needs a fast feedback
path: "this was read wrong" from the reader view, capturing the sentence and the voice.

### C-20
**Multilingual books** — S3

A Latin epigraph, quoted French dialogue, a bilingual edition. Reading French with an
English voice is unpleasant; flapping between voices every other block is worse.

**Solution.** Per-block detection with hysteresis — switch voice only when consecutive
blocks agree — plus a per-language voice mapping and a fallback voice. Language spans
shorter than a threshold are read in the current voice.

### C-21
**Homographs** — S3

"I read the book" vs "I will read the book". Also lead, live, bow, tear, wind, close,
minute. Neural models trained on plain text usually guess from context; phoneme-based
front ends often do not.

**Solution.** v1: frequency-based defaults plus the user-editable pronunciation
dictionary, which handles the cases that matter to a given book. v1.x: a small POS
tagger to disambiguate the common set, which is a well-bounded improvement.

### C-22
**eSpeak-NG GPL contamination** — **CLOSED 2026-09-01** (was S1)

Neural TTS needs phonemes, and the standard front end for both Piper and Kokoro is
eSpeak-NG, which is **GPL-3.0**. Linking it into a distributed closed-source application
would propagate GPL obligations to the entire application.

**Two corrections to the original entry.**

*The mitigation rested on a false premise.* The original text claimed sherpa-onnx
"removed eSpeak-NG and `piper-phonemize` precisely to remain Apache-2.0 clean".
**It has not.** That is a proposal for a future 2.0.0
([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08).
The shipping 1.13.x line still bundles it — v1.13.5's release notes read "Fix installing
espeak-ng-data directory". Anyone using sherpa-onnx today ships eSpeak-NG whether they
intended to or not.

*The escape hatch is no longer needed.* [ADR-014](10-decisions-adr.md#adr-014) adopted
**GPL-3.0** on 2026-09-01, so eSpeak-NG's licence now matches our own.

**Resolution: use eSpeak-NG deliberately.** It is what Piper and Kokoro were trained
against, so it produces the phoneme distribution the models expect — a
lexicon-plus-rules substitute would have been more work *and* worse output. Language
coverage widens substantially, and we consume sherpa-onnx 1.13.x exactly as shipped with
no custom build.

**Residual risk — S4.** If sherpa-onnx 2.0.0 drops eSpeak-NG, we either supply it
ourselves or use the documented escape hatches: a `lexicon.txt`, or passing pre-tokenised
phoneme strings through `GenerationConfig`. A migration, not a blocker. Pin the
sherpa-onnx version and review deliberately before crossing the 2.0 boundary.

### C-23
**Piper per-voice licences** — S3 (was S1, downgraded 2026-09-01)

Originally two problems.

**The first is closed.** The Piper *engine* moved from MIT (`rhasspy/piper`, archived
October 2025) to GPL-3.0 (`OHF-Voice/piper1-gpl`), which was a blocker only while our own
licence was undecided. Under [ADR-014](10-decisions-adr.md#adr-014) we may link it
freely. We still reach Piper models through sherpa-onnx because that is simpler, not
because we are forced to.

**The second stands.** Piper *voices* carry mixed licences — CC0, CC-BY, MIT, Apache and
several research-only — with no machine-readable flag to filter on. GPL-3.0 removes the
*commercial-use* dimension, but not the rest: some voices restrict redistribution
outright, and CC-BY requires attribution regardless of how we license our own code.

**Solution.** Maintain our own audited allowlist rather than enumerating an upstream
catalogue at runtime. Store each voice's licence with the voice, surface it in the UI,
and honour CC-BY attribution on a dedicated page. Re-audit on every catalogue update as a
release checklist item. See
[§6.4](06-voice-catalog-and-licensing.md#64-the-per-voice-trap).

### C-24
**XTTS and edge-tts unusable** — S2, resolved as scope

Coqui XTTS v2 offers voice cloning under CPML, which is **non-commercial**. `edge-tts`
offers excellent free voices via an undocumented Microsoft endpoint that is not public or
endorsed, whose commercial use conflicts with Microsoft's terms, and which now requires
short-lived anti-abuse tokens and filters cloud IP ranges.

**Resolution.** Both excluded. Voice cloning is deferred until a permissively licensed
model exists that is good enough; premium cloud voices are available through
bring-your-own-key (Tier 3) where the user's own agreement with the provider governs.

Worth stating clearly because both are tempting: shipping either would give a short-term
quality win and a long-term legal and reliability problem.

### C-25
**Voice model download size** — S2

Piper voices run 20–130 MB each; Kokoro is ~90–330 MB. Users on metered connections or
low-storage devices will be unhappy if this is handled carelessly.

**Solution.** Nothing pre-bundled. Wi-Fi-only by default with an explicit mobile-data
confirmation. Resumable, hash-verified downloads. **Hosted preview clips so nobody
downloads a voice they will dislike** — the highest-value item in the Voice Store UI.
LRU eviction *suggestions* when storage is low, never automatic deletion.

---

## Platform

### C-26
**Android background playback survival** — S1

The defining failure mode for this app category. If reading stops when the screen locks
or the app is backgrounded, the product does not work. Beyond correct implementation,
several major OEMs aggressively kill background processes that stock Android would keep
alive.

**Solution.** Correct implementation first — `mediaPlayback` foreground service type
with the matching permission, a persistent notification, MediaSession, and a partial wake
lock held only while synthesising. Then OEM mitigation: manufacturer detection, a
one-time explanatory card with a deep link to battery settings, and an opt-in battery
optimisation exemption request.

**The real defence is making death harmless:** persist playback position every sentence,
so being killed costs the user one sentence, not one chapter. Full detail in
[§7.4](07-platform-android.md#74-oem-battery-management).

Note that "resume reading on boot" is not implementable — Android 15+ forbids
`BOOT_COMPLETED` receivers from starting `mediaPlayback` foreground services — so it must
not be designed into the product.

### C-27
**Audio focus, routing, Bluetooth latency** — S3

Calls, notifications, other media apps, headphones unplugged, Bluetooth reconnecting,
default device changes. And because we run our own player, none of it is handled for us.

**Solution.** An explicit focus and routing policy, tabulated in
[§7.3](07-platform-android.md#73-audio-focus-and-routing) and
[§8.4](08-platform-windows.md#84-audio-output). The subtle one is **Bluetooth latency**:
A2DP adds 150–250 ms, so word highlighting visibly leads the audio. Per-route stored
offsets plus a user-facing calibration slider solve it far better than any attempt at
automatic correction.

### C-28
**Android 16 KB pages, target SDK, memory limits** — S2

Three platform requirements arriving together. Target API 36 is required for new apps as
of 31 August 2026. Native libraries must be 16 KB page-aligned for Android 16 devices —
and we ship four of them (ONNX Runtime, PDFium, miniaudio, our DSP core). Android 17 adds
per-app memory limits.

**Solution.** Target API 36 from the first commit. Build every native library with 16 KB
alignment and **verify it in CI** with an automated alignment check, because this fails
at runtime on real devices rather than at build time. Test on a 16 KB-page emulator image
in CI. Treat the memory limits as a design input to the Tier 2 gate ([C-16](#c-16)).

### C-29
**Windows TTS plugin gap** — S2

`flutter_tts` nominally supports Windows but has a history of `MissingPluginException` on
core methods there, and it is a *play the text* API when we need *bytes plus markers*.

**Solution.** Write a focused C++/WinRT plugin — a few hundred lines around
`SpeechSynthesizer`, `SynthesizeTextToStreamAsync`, and word-boundary metadata. Removes a
dependency we would otherwise be fighting and gives us exactly Contract B. See
[§8.2](08-platform-windows.md#82-speech-on-windows).

### C-30
**Windows signing and SmartScreen** — S3

Unsigned binaries trigger SmartScreen warnings that lose a large share of first-time
users.

**Solution.** OV certificate (~$200–300/year). **Not EV** — Microsoft removed EV's
instant-SmartScreen-reputation behaviour in 2024, so EV now costs more for no benefit
outside kernel drivers. Note the 458-day validity cap effective 1 March 2026 and the
hardware-token/cloud-HSM key storage requirement, both of which shape the CI signing
flow. A parallel Microsoft Store listing gives users a warning-free path while
certificate reputation accrues.

### C-31
**Cross-platform file access** — S3

Android requires SAF with revocable URIs; Windows has plain paths. A shared codebase
must abstract this without leaking Android's model into the desktop experience or vice
versa.

**Solution.** A `BookSource` abstraction with `copied` and `linked` variants. Default to
copying into app storage on import — SAF URIs get revoked, files move, and re-parsing a
900-page PDF because the user tidied their Downloads folder is a bad experience. Offer
linking for large-library users with a clear warning about its fragility.

### C-32
**Binary size budget** — S2

ONNX Runtime, PDFium, the Flutter engine, miniaudio and our DSP core, times three ABIs.

**Solution.** A ~120 MB base budget before any voice download. Per-ABI AAB splits. No
pre-bundled voices. Consider Play Feature Delivery for the neural runtime itself, so
Tier 0-only users never download ONNX Runtime. **Track binary size in CI with a failing
threshold**, because size regressions arrive quietly through dependency updates.

### C-33
**Battery drain from neural synthesis** — S2

Continuous neural inference is CPU-heavy. An hour of Kokoro is meaningfully more
expensive than an hour of system TTS, and "this app drains my battery" is a review-killer
in a category whose sessions are measured in hours.

**Solution.** Synthesise ahead in bursts and idle, rather than running continuously —
bursty CPU use lets the SoC return to low-power states. Cap lookahead depth. Use NNAPI or
the available accelerator where it is actually faster (measure; it often is not for small
models). Expose an honest per-voice battery indicator in the Voice Store, and offer a
"battery saver" mode that pins Tier 0. Measure battery per voice tier as a tracked
release metric.

### C-34
**Screen reader vs our own TTS** — S2

A core audience uses TalkBack or Narrator. Their screen reader and our book narration
share one audio output. Two voices at once is unusable, and this is precisely the
audience least able to work around it.

**Solution.** Detect the active screen reader and coordinate explicitly: duck or pause
our output during screen-reader announcements, keep our own control labels terse to
shorten the collision window, and ensure every playback control is operable without
sighted interaction. Test the whole reading flow with TalkBack and Narrator on as a
release gate, not as an afterthought.

### C-35
**Cross-device sync** — S3

"Read on the phone, continue on the PC" is a headline benefit of shipping both platforms,
and it conflicts with the local-first, no-account promise.

**Solution.** v1.x, and opt-in. Sync only small state — position, bookmarks, highlights,
settings, pronunciation dictionaries — never book files. Offer a file-based backend the
user already has (a synced folder) before building any service of our own. Position sync
needs conflict resolution: last-write-wins on a per-book basis with a "you were further
ahead on your phone — jump there?" prompt rather than silent overwriting.

### C-36
**Testing audio output** — S2

Most of the value lives in DSP and timing, which unit tests cover poorly. "Does the word
gap sound right?" is not an assertion.

**Solution.** Make the audio pipeline deterministic and testable at the buffer level —
golden-file comparisons on PCM output for fixed inputs, assertions on measured silence
durations at word boundaries, drift measurement between reported and actual timings over
long passages. Detail in [13 — Testing & QA](13-testing-and-qa.md).

### C-37
**Store policy and AI disclosure** — S3

Both stores increasingly expect clarity about AI-generated content and data handling.

**Solution.** State plainly that neural voices are synthetic and generated on-device,
that no text leaves the device in the default configuration, and that cloud voices are
opt-in with the user's own key. Declare the cloud-voice exception in Data Safety. Ship
an attribution page covering CC-BY voices and open-source components. Detail in
[§7.8](07-platform-android.md#78-play-store-compliance-checklist).

### C-38
**Scope creep — this is three apps** — S2

An ebook reader, a PDF reader, and a TTS engine are each a substantial product. Building
all three at once, on two platforms, is how this project dies — not from any single
blocker above, but from being 60% done everywhere and shippable nowhere.

**Solution.** The phased plan in
[12 — Roadmap & Milestones](12-roadmap-and-milestones.md), whose ordering is deliberate:
**EPUB + system TTS end-to-end on both platforms first**, because that is the shortest
path to a genuinely useful app and it exercises every architectural contract. PDF, then
neural voices, then everything else. Each phase has exit criteria, and no phase starts
before the previous one meets them.

The temptation will be to start with Kokoro because it is the exciting part. Resist it:
Kokoro is worthless without the document pipeline and the audio pipeline underneath it,
and both of those are proven faster and more cheaply with system TTS.
