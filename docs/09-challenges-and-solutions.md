# 09 — Challenges & Solutions

Every known blocker, risk and hard problem, with severity and the chosen mitigation, as
registered before the build (2026-09-01). Each entry now ends with how it turned out in
1.4.0 (**As built**), and the summary table has a status column. The register's plans are
kept as written: where the build went another way, the note says so.

**Severity scale**

| | |
|---|---|
| **S1 — Blocker** | Shapes the architecture or removes scope. Must be resolved before building. |
| **S2 — Major** | Significant engineering cost or a visible quality ceiling. Needs a plan. |
| **S3 — Moderate** | Real work, well-understood solution. |
| **S4 — Watch** | Not a problem yet; could become one. |

## Summary

| ID | Challenge | Severity | Status (1.4.0) |
|---|---|---|---|
| [C-01](#c-01) | PDF reading order | S1 | Partly solved: PdfBox's order, cleaned up in Dart; no manual fixing |
| [C-02](#c-02) | PDF hyphenation and line joining | S3 | Built, without the lexicon check |
| [C-03](#c-03) | PDF running headers, footers, page numbers | S3 | Built (dropped, not kept as roles) |
| [C-04](#c-04) | Scanned PDFs need OCR | S2 | Built (1.4.0): Tesseract on the phone |
| [C-05](#c-05) | EPUB is arbitrary HTML | S2 | Built, drawn with Flutter text, not a WebView |
| [C-06](#c-06) | Text-to-render anchor stability | S2 | Solved another way: the place is a sentence |
| [C-07](#c-07) | DRM-protected books | S1 (scope) | Refused with a message, as decided |
| [C-08](#c-08) | MOBI / AZW3 support | S3 | Built (0.2.0) |
| [C-09](#c-09) | DOCX complexity | S3 | Built, with ODT |
| [C-10](#c-10) | Very large documents | S2 | Built: parsed once and kept; web novels in windows |
| [C-11](#c-11) | Sentence segmentation quality | S3 | Built: TomeVoice's own segmenter |
| [C-12](#c-12) | **No engine supports word gap** | **S1** | **Solved**: the word gap is TomeVoice's own, on every voice |
| [C-13](#c-13) | **No word timings from neural engines** | **S1** | **Solved** with pause anchors |
| [C-14](#c-14) | No pitch control on neural engines | S3 | Not built: natural voices have no pitch |
| [C-15](#c-15) | Speed quality degradation | S3 | Avoided: speed is always the voice's own |
| [C-16](#c-16) | **Kokoro memory footprint** | **S1** | Gated on memory and a speed test |
| [C-17](#c-17) | Time to first audio | S2 | Mitigated; not measured against the targets |
| [C-18](#c-18) | Loudness mismatch between voices | S3 | Built |
| [C-19](#c-19) | Text normalisation is unsolved by default | S2 | Left to the voice, plus the reader's rules |
| [C-20](#c-20) | Multilingual books | S3 | One language per book |
| [C-21](#c-21) | Homographs | S3 | Left to the voice and the reader's rules |
| [C-22](#c-22) | eSpeak-NG GPL contamination — **CLOSED** | — | Closed |
| [C-23](#c-23) | Piper per-voice licences (engine issue closed) | S3 | Each voice's licence shown; not an allowlist |
| [C-24](#c-24) | XTTS and edge-tts unusable | S2 (scope) | Excluded; bring-your-own-key cloud not built |
| [C-25](#c-25) | Voice model download size | S2 | Opt-in downloads, a sample first |
| [C-26](#c-26) | Android background playback survival | S1 | Built; the voice outlives the app (1.4.0) |
| [C-27](#c-27) | Audio focus, routing, Bluetooth latency | S3 | Built; highlight timing per route |
| [C-28](#c-28) | Android 16 KB pages, target SDK, memory limits | S2 | Target 36; alignment checked in CI |
| [C-29](#c-29) | Windows TTS plugin gap | S2 | Windows not started |
| [C-30](#c-30) | Windows signing and SmartScreen | S3 | Windows not started |
| [C-31](#c-31) | Cross-platform file access | S3 | Android only: books are copied in |
| [C-32](#c-32) | Binary size budget | S2 | One APK per CPU; size printed, no threshold |
| [C-33](#c-33) | Battery drain from neural synthesis | S2 | Mitigated; battery not measured |
| [C-34](#c-34) | Screen reader vs our own TTS | S2 | TalkBack reads and turns pages; no ducking |
| [C-35](#c-35) | Cross-device sync | S3 | Built (1.4.0): WebDAV or KOReader, opt-in |
| [C-36](#c-36) | Testing audio output | S2 | Buffer-level tests, the verifier, emulator flows |
| [C-37](#c-37) | Store policy and AI disclosure | S3 | Moot while there is no store build |
| [C-38](#c-38) | Scope creep — the app is three apps | S2 | Android only; Windows not started |

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

**As built (1.4.0).** PdfBox-Android gives each page's text in its own reading order, with
each line's position; `formats/pdf.dart` then reads two columns one after the other, takes
notes from a page's foot, drops running heads and page numbers, and starts a paragraph at
an indent ([§3.3](03-document-pipeline.md#33-pdf-the-hard-one)). There is no overlay, no
region editing and no column-count override, and accuracy is not measured per category;
the test corpus checks real PDFs against goldens instead ([13](13-testing-and-qa.md)).

### C-02
**PDF hyphenation and line joining** — S3

Lines end mid-word with a hyphen; naive extraction produces "hyphen- ation". But
blindly removing every terminal hyphen turns "well-being" into "wellbeing" and
"co-operate" into "cooperate", corrupting the author's text.

**Solution.** Join when: the line ends with `-`, the next line begins lowercase, and the
joined form is in the language lexicon while the hyphenated form is not. Keep the hyphen
otherwise. Where both forms are valid words, prefer keeping the hyphen — a wrongly kept
hyphen is nearly inaudible; a wrongly removed one changes a word.

**As built (1.4.0).** No lexicon: a hyphen at a line's end is joined when a letter stands
before it and the next line starts in lower case, in any script with lower case
(`joinWrappedLines`, `formats/text.dart`); a soft hyphen always is. So "well-/being" broken
at a line's end becomes "wellbeing".

### C-03
**PDF running headers, footers, page numbers** — S3

Every page injects the book title and a page number into the middle of the audio stream.

**Solution.** Text repeating at a consistent y-position across many pages is furniture.
Cluster candidate strings by normalised content and position across the document; a
cluster covering more than ~30% of pages in a header/footer band is classified as
`runningHeader` or `pageNumber`. Classified, not deleted, so the setting can restore
them.

**As built (1.4.0).** Running heads (on nearby pages too) and page numbers are found and
**dropped**, not kept as roles, so there is nothing to turn back on.

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

**As built (1.4.0).** Built. A PDF that is mostly pictures says so and offers OCR:
Tesseract on the phone, a page at a time at about 300 dpi, in the languages the reader
picks (their data downloaded on first use), in a foreground service that goes on with
the screen off and resumes after any stop. The text then goes through the PDF clean-up
like any PDF's ([§3.3](03-document-pipeline.md#33-pdf-the-hard-one)). OCR errors still
reach the voice as they are.

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

**As built (1.4.0).** No WebView: the book is drawn with Flutter text from TomeVoice's own
model, in a scroll or in pages ([ADR-005](10-decisions-adr.md#adr-005)). Inline runs and
drop caps are joined, notes taken out of the flow, right-to-left books set and turned right
to left, and pictures shown in the text. Fixed-layout EPUBs get no special handling; a zip
that is mostly pictures (a comic) is refused.

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

**As built (1.4.0).** Solved another way. The place is section, block and sentence
numbers, which no reflow moves, and the highlight is drawn by the same Flutter text that
lays the page out. When a better parser renumbers a book, the saved sentence is found
again by its words ([02 §2.4](02-architecture.md#24-contract-a-the-document-model)). Turning
the phone or changing the text size keeps the sentence on the page.

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

**As built.** As decided: an encrypted EPUB (anything but font obfuscation in
`encryption.xml`), an encrypted Kindle book and a password-protected PDF are refused with
a plain message. A DRM-free EPUB with obfuscated fonts, once refused by mistake, opens
(1.3.0). The README says it in "What it deliberately does not do".

### C-08
**MOBI / AZW3 support** — S3

No maintained Dart library exists for these formats, and Amazon's newer KFX is both
proprietary and usually DRM'd.

**Solution.** v1.x. Write a focused parser for the DRM-free subset — PalmDB container,
PalmDOC/HUFF-CDIC decompression, then the embedded HTML which flows into the existing
EPUB path. A contained, well-documented format; roughly a week of work, but not v1.

**As built.** In the first release (0.2.0), PalmDOC only: HUFF/CDIC-compressed books are
refused with a message. A KF8 book (AZW3) is rebuilt into its parts and opened by its
chapters (1.3.0).

### C-09
**DOCX complexity** — S3

Tracked changes, comments, footnotes, tables, text boxes, fields, and text in shapes
that lives outside the main flow.

**Solution.** Explicit handling per construct, detailed in
[§3.4](03-document-pipeline.md#34-docx). Default to reading the accepted document
(insertions in, deletions out), exclude comments, and append floating text-box content
at the end of its section rather than interleaving it unpredictably.

**As built.** Mostly as planned, with ODT read the same way; a text box's paragraph is a
block of its own where it stands, notes are shown and not read, and a table of data is
read a row at a time ([§3.4](03-document-pipeline.md#34-docx)).

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

**As built (1.4.0).** A book is parsed once, at import, on a background isolate, and kept
as `parsed.json`; big books import in less than half the memory they took before 1.3.0.
The reader builds one layout of the whole book with constant-time lookups. A web novel is
laid out a window of chapters at a time (Shadow Slave has more than 3,200), and long lists
have a fast-scroll thumb.

### C-11
**Sentence segmentation quality** — S3

"Dr. Smith went to Washington." must be one sentence. `"Stop!" he said.` must be one.
Chinese and Japanese have no spaces. Bad segmentation produces audible errors: pauses
mid-sentence and run-on sentences with no breath.

**Solution.** ICU break iteration as the base, plus per-language abbreviation exception
lists, plus post-rules for quotes and brackets. A hard ceiling (default 240 characters)
splits over-long sentences at clause boundaries to bound synthesis latency.

**As built.** TomeVoice's own segmenter, not ICU, with abbreviation and title lists and
the stops of other scripts; the ceiling is 280 characters
([§3.6](03-document-pipeline.md#36-sentence-and-word-segmentation)).

---

## Speech

### C-12
**No engine supports word gap** — S1, and the reason the architecture looks as it does

Word separation is an explicit product requirement, driven by the dyslexic-reader and
language-learner personas. **No TTS API we can use exposes it.** Not Android's
`TextToSpeech`. Not Windows `SpeechSynthesizer`. Not Piper. Not Kokoro. It exists in
eSpeak's `-g` flag and essentially nowhere else — and that flag is not reachable through
any of those APIs (eSpeak-NG's licence was settled by [C-22](#c-22); it ships inside
sherpa-onnx only as the phonemiser).

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

**As built.** Solved, and proven before anything else was built: the audio spike
(2026-09-01 and 02) measured the gap on the phone's real audio. A 120 ms gap measured
115 to 125 ms at every boundary, at 1.0x and at 2.0x, inserted exactly (46,080 frames for
120 ms), with the splices smoother than the speech around them. The arithmetic passing was
not enough: the first listening test failed, for reasons no measurement had covered
([13 §13.13](13-testing-and-qa.md#1313-the-audio-spike)). Today the gap is 0 to 500 ms on
every voice, and focus, ducking, interruption, the media session and the player are all
TomeVoice's own ([07](07-platform-android.md)).

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

**As built.** The system-voice half was the spike's open question (R1), and the answer was
the best case: Google's TTS reports every word with its frame (17 events for 17 words on
the developer's phone), though not in the documented parameter order, which TomeVoice now
detects ([§4.3](04-tts-engine-contract.md#43-adapter-android-system-tts)). Only one TTS
engine was on that phone, so other engines are unmeasured. For natural voices, strategy (4)
was replaced by **pause anchors**: the pauses found in the audio are matched to the
punctuation in the text, and each stretch between two is shared over its own words
(`PauseAligner`). Character-count sharing had drifted 271 ms on average and 610 ms at
worst; anchored words are highlighted one by one, and only a stretch of more than 3.5 s
with no pause falls back to the sentence
([§4.7](04-tts-engine-contract.md#47-deriving-word-timings-for-neural-engines)). (1), (2)
and (3) were not built.

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

**As built (1.4.0).** Not built. Natural voices speak at their own pitch, and their
Fine-tune says so instead of showing a slider. The phone's voices take pitch through
`setPitch`, each voice its own (on Google's voices any pitch but 0 switches to an older,
rougher model, [05 §5.2](05-tts-controls-spec.md#52-pitch)). The one stretcher built, WSOLA
in Dart, keeps pitch while changing speed, for a book's recorded narration.

### C-15
**Speed quality degradation** — S3

Engine-native rate sounds natural but degrades outside a band. DSP time-stretching works
at any factor but smears transients, most audibly below 0.7x and above 2.5x.

**Solution.** Hybrid, with the engine doing as much as it can well and DSP taking the
residual, plus a user-facing "prefer natural / prefer smooth" preference for those who
disagree with our crossover on their device. See
[§5.1](05-tts-controls-spec.md#51-speed).

**As built.** Avoided rather than solved: speed is always the voice's own rate, 0.5x to
3x, with no DSP share. The spike learned why the hard way: its resampling stub, wired to
the speed slider, raised the voice nearly an octave at 2x.

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

**As built (1.4.0).** Kokoro ships as an opt-in, full-precision pack (334 MB, 29
speakers). It is offered only on phones with at least 5,200 MB of memory (about 850 MB
while it reads), and read with only once the phone's own speed test shows it keeps up.
Natural voices are let go after 3 minutes unused, and one that fails hands the book to the
phone's voice instead of stopping ([§4.6](04-tts-engine-contract.md#46-adapter-kokoro-via-sherpa-onnx)).
No int8 option is offered.

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

**As built (1.4.0).** A natural voice is loaded, and run once unheard, as a book opens; a
sentence is made at full priority when the queue runs short; a long one is made in pieces
cut at its pauses; about 10 s stays queued. Not built: splitting only the first sentence,
pre-synthesis on focus, caching the next chapter's opening. The targets were not measured
as such. A jump with a natural voice waits for the piece being made, 0.3 to 1.7 s, longer
with Kokoro ([12](12-roadmap-and-milestones.md)).

### C-18
**Loudness mismatch between voices** — S3

Open models are trained on different corpora and differ by more than 10 dB. Switching
voices at night is unpleasant; mixed-language books switching voices mid-chapter are
worse.

**Solution.** Integrated-loudness measurement per sentence with a smoothed gain toward a
−16 LUFS target, plus a limiter, plus a per-voice manual trim. On by default.

**As built.** "Even out loudness", on by default: each sentence measured, its gain moved
half way from the last one's, with a limiter (1.3.0: levelled by measure, without
distortion). The per-voice trim has no control of its own.

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

**As built.** The rule set was not built: numbers, dates and abbreviations are left to the
voice. What TomeVoice changes is narrower (links said as their site, citations skipped,
silent note markers, skip presets) plus the reader's own respellings, made by pressing
and holding a word ([§3.7](03-document-pipeline.md#37-text-normalisation-for-speech)).
There is no "read wrong" report; About → Report a problem is general.

### C-20
**Multilingual books** — S3

A Latin epigraph, quoted French dialogue, a bilingual edition. Reading French with an
English voice is unpleasant; flapping between voices every other block is worse.

**Solution.** Per-block detection with hysteresis — switch voice only when consecutive
blocks agree — plus a per-language voice mapping and a fallback voice. Language spans
shorter than a threshold are read in the current voice.

**As built.** One language per book, from its metadata or, better, its script
([§3.8](03-document-pipeline.md#38-language-detection)), with a voice remembered per
language. No switching within a book.

### C-21
**Homographs** — S3

"I read the book" vs "I will read the book". Also lead, live, bow, tear, wind, close,
minute. Neural models trained on plain text usually guess from context; phoneme-based
front ends often do not.

**Solution.** v1: frequency-based defaults plus the user-editable pronunciation
dictionary, which handles the cases that matter to a given book. v1.x: a small POS
tagger to disambiguate the common set, which is a well-bounded improvement.

**As built.** Left to the voice, with the reader's own "say this as that" rules for the
cases that matter to a book. No POS tagger.

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

**As built.** Pinned at 1.13.8 (`app/pubspec.yaml`); see the
[recheck triggers](10-decisions-adr.md#recheck-triggers).

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

**As built (1.4.0).** The catalogue is TomeVoice's own, made by `tools/voice_catalog.py`
and shipped in the app, never read from upstream at run time, and each voice carries the
licence its model card states, shown beside it. It is not an allowlist: the GitHub build
offers non-commercial and unlicensed voices too, saying so (the developer's decision,
2026-10-29); a Play build would leave them out ([18](18-play-store-audit.md)).

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

**As built.** Both still excluded. Bring-your-own-key cloud voices were not built.

### C-25
**Voice model download size** — S2

Piper voices run 20–130 MB each; Kokoro is ~90–330 MB. Users on metered connections or
low-storage devices will be unhappy if this is handled carelessly.

**Solution.** Nothing pre-bundled. Wi-Fi-only by default with an explicit mobile-data
confirmation. Resumable, hash-verified downloads. **Hosted preview clips so nobody
downloads a voice they will dislike** — the highest-value item in the Voice Store UI.
LRU eviction *suggestions* when storage is low, never automatic deletion.

**As built (1.4.0).** Nothing pre-bundled; voices are off until chosen, with a warning
first. Piper voices are 25 to 125 MB, Kitten 61 MB, Kokoro 334 MB. Downloads resume;
nearly every voice has a sample to hear first; Remove and Remove all take them off. There
is no Wi-Fi-only rule and no eviction suggestion
([§6.7](06-voice-catalog-and-licensing.md#67-voice-download-and-storage)).

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

**As built (1.4.0).** A `mediaPlayback` foreground service with a MediaSession from the
first release, and since 1.4.0 the voice belongs to a cached Flutter engine that outlives
the activity: swiped from Recents, the book reads on; with the app closed, the resume card
and a headset's Play pick it up ([§7.2](07-platform-android.md#72-background-playback)).
The place is written to the book's own file at every save, about a sentence apart. OEM
help is a row in Settings → Listening (Android's battery question and a link to the
maker's page on dontkillmyapp.com), not a one-time card.

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

**As built.** Calls and other apps' sound pause the voice and give it back (1.3.0);
headphones coming out pause it. Highlight timing is a slider, −200 to +400 ms, kept per
route (Bluetooth, and everything else).

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

**As built.** Target 36 from the start. There is no native code of TomeVoice's own; CI
checks each APK's 64-bit libraries with `tools/check_16kb.py` (OCR's must be aligned,
others are warned about). The emulator job runs Android 14 and 16 images, not a 16 KB-page
one.

### C-29
**Windows TTS plugin gap** — S2

`flutter_tts` nominally supports Windows but has a history of `MissingPluginException` on
core methods there, and it is a *play the text* API when we need *bytes plus markers*.

**Solution.** Write a focused C++/WinRT plugin — a few hundred lines around
`SpeechSynthesizer`, `SynthesizeTextToStreamAsync`, and word-boundary metadata. Removes a
dependency we would otherwise be fighting and gives us exactly Contract B. See
[§8.2](08-platform-windows.md#82-speech-on-windows).

**As built.** Windows is not started; nothing here was built.

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

**As built.** Windows is not started. (The Android APKs are signed with one release key
kept as a CI secret; CI refuses to release an APK signed with any other.)

### C-31
**Cross-platform file access** — S3

Android requires SAF with revocable URIs; Windows has plain paths. A shared codebase
must abstract this without leaking Android's model into the desktop experience or vice
versa.

**Solution.** A `BookSource` abstraction with `copied` and `linked` variants. Default to
copying into app storage on import — SAF URIs get revoked, files move, and re-parsing a
900-page PDF because the user tidied their Downloads folder is a bad experience. Offer
linking for large-library users with a clear warning about its fragility.

**As built.** Android only, and every book is copied into the library folder; there is no
linked variant ([§7.5](07-platform-android.md#75-file-access)).

### C-32
**Binary size budget** — S2

ONNX Runtime, PDFium, the Flutter engine, miniaudio and our DSP core, times three ABIs.

**Solution.** A ~120 MB base budget before any voice download. Per-ABI AAB splits. No
pre-bundled voices. Consider Play Feature Delivery for the neural runtime itself, so
Tier 0-only users never download ONNX Runtime. **Track binary size in CI with a failing
threshold**, because size regressions arrive quietly through dependency updates.

**As built.** One APK per CPU (64-bit and 32-bit), each with only its CPU's native code,
stored compressed: about 27 MB at 1.0.0, 4 MB smaller in 1.3.0, before OCR and the MP3
encoder came in 1.4.0. CI prints each APK's size beside the latest release's; there is no
failing threshold, and ONNX Runtime ships to everyone.

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

**As built.** The work is bursty already (about 10 s queued, then idle), made at a lower
priority when well ahead, and nothing runs while paused (1.4.0); models are let go after
3 minutes unused. Measured on the developer's phone: a Piper voice takes about 70% of a
core against about 20% for Google's voice. The app warns before any natural voice that it
works the phone harder. Battery per hour was never measured, and there is no battery
saver mode.

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

**As built (1.4.0).** TalkBack reads the pages and turns them (1.3.0), and the controls are
labelled. The collision itself is not handled: the book is not ducked or paused during
TalkBack's announcements, and no release is gated on a TalkBack pass.

### C-35
**Cross-device sync** — S3

"Read on the phone, continue on the PC" is a headline benefit of shipping both platforms,
and it conflicts with the local-first, no-account promise.

**Solution.** v1.x, and opt-in. Sync only small state — position, bookmarks, highlights,
settings, pronunciation dictionaries — never book files. Offer a file-based backend the
user already has (a synced folder) before building any service of our own. Position sync
needs conflict resolution: last-write-wins on a per-book basis with a "you were further
ahead on your phone — jump there?" prompt rather than silent overwriting.

**As built (1.4.0).** Opt-in, with nothing of TomeVoice's own in between: places, quotes,
bookmarks and listening time through a WebDAV folder the reader names, or a book's place
through a KOReader sync server (`sync.dart`, `kosync.dart`). Book files never go, nor
anything of a book on a shut secret shelf; passwords stay in a file no backup carries.

### C-36
**Testing audio output** — S2

Most of the value lives in DSP and timing, which unit tests cover poorly. "Does the word
gap sound right?" is not an assertion.

**Solution.** Make the audio pipeline deterministic and testable at the buffer level —
golden-file comparisons on PCM output for fixed inputs, assertions on measured silence
durations at word boundaries, drift measurement between reported and actual timings over
long passages. Detail in [13 — Testing & QA](13-testing-and-qa.md).

**As built.** The pipeline is pure Dart and tested at the buffer level (word gap, order of
stages, timing remap, loudness, the WSOLA stretch, the pause aligner); an offline verifier
checks exported audio and is itself checked in CI. No golden PCM files and no long-passage
drift measurement. On devices, Maestro flows run on Android 14 and 16 emulators in CI, and
a person listens on the phone before a release: no test captures the phone's audio
([13](13-testing-and-qa.md)). The QuickJS plugin host is tested in CI; real web-novel
sites, the hidden web view and the NovelDokusha import are checked by hand on a phone.

### C-37
**Store policy and AI disclosure** — S3

Both stores increasingly expect clarity about AI-generated content and data handling.

**Solution.** State plainly that neural voices are synthetic and generated on-device,
that no text leaves the device in the default configuration, and that cloud voices are
opt-in with the user's own key. Declare the cloud-voice exception in Data Safety. Ship
an attribution page covering CC-BY voices and open-source components. Detail in
[§7.8](07-platform-android.md#78-play-store-compliance-checklist).

**As built.** Moot while TomeVoice is published only on GitHub. The app shows each natural
voice's licence and lists its open-source licences in About; [18](18-play-store-audit.md)
holds the audit for a Play build.

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

**As built.** The order changed once and then held. The audio pipeline went first, as a
spike on the phone (2026-09-01 and 02), because it was the part no document could prove;
then a speakable document with the phone's voices, every format, the reader, web novels,
and natural voices last (1.0.0), Kokoro later still (1.4.0). The other half of the
protection was scope: Android only, with Windows not started. 0.2.0 to 1.4.0 shipped in
ten days, 22 to 31 October 2026.
