# 12 — Roadmap & Milestones

## The ordering principle

This is three products in a trench coat — an ebook reader, a PDF reader and a TTS engine
— on two platforms. Built in the wrong order, the project ends up 60% done everywhere and
shippable nowhere ([C-38](09-challenges-and-solutions.md#c-38)).

So the order is deliberate: **prove the architecture end-to-end on the easiest format
with the easiest engine first.** EPUB plus system TTS exercises every contract in the
system — the Document Model, the engine adapter, the audio pipeline, the scheduler,
background playback, both platforms — using the format that hands us structure for free
and the engine that hands us word timings for free.

Everything hard after that (PDF layout, neural voices, derived timings) plugs into
contracts that are already proven, instead of being designed against a moving target.

The temptation will be to start with Kokoro because it is the exciting part. Resist it.
Kokoro is worthless without the pipeline underneath it, and that pipeline is proven
faster and more cheaply with a system voice.

---

## Phase 0 — Foundations
*Target: 2 weeks*

Project skeleton, CI, and the decisions that are expensive to change later.

- Flutter project targeting Android (API 36) and Windows
- CI: build both platforms, run tests, **check native library 16 KB alignment**, **track
  binary size against a failing threshold**
- Drift database with the initial schema and a migration test harness
- Domain model: Document Model and engine contract as pure Dart, no implementations
- Logging, crash reporting (opt-in), a feature-flag mechanism
- **Decide [ADR-014](10-decisions-adr.md#adr-014): the project's licence** — it gates
  the phonemiser choice and therefore the language roadmap

**Exit criteria.** Both platforms build in CI from a clean checkout. The alignment and
size checks are live and can fail the build. The licence decision is recorded.

---

## Phase 1 — EPUB reader, no speech
*Target: 4 weeks*

A genuinely good silent reader. If this is not pleasant to use, no amount of TTS saves
it.

- EPUB parsing: container, OPF, spine, NCX/nav, metadata, cover
- Document Model construction with block roles and CFI anchors
- WebView renderer with pagination, font/size/spacing/margin/theme controls
- Library: import via SAF and Windows file picker, grid/list, collections, sorting
- Navigation: TOC, progress, bookmarks, full-text search
- Reading position persistence across reflow, rotation, restart
- Sentence and word segmentation with the ICU-based tokeniser

**Exit criteria.** Open 20 real-world EPUBs from varied sources without a crash or a
layout failure. Reading position survives font-size change, rotation and app restart.
5 MB book opens to first page in under 2 s on a mid-range Android device.

---

## Phase 2 — Speech with system voices
*Target: 5 weeks* — **the architectural proof**

The whole speech architecture, using the engine that is easiest to get right.

- Android system TTS adapter: `synthesizeToFile` plus `onRangeStart` frame positions
- Windows WinRT speech plugin (C++/WinRT): stream plus word-boundary markers
- Audio pipeline: ring buffer, miniaudio output, **word-gap injection**, pause insertion,
  loudness normalisation
- Lookahead scheduler with cancellation
- Word-synchronised highlighting with auto-scroll and the timing-offset calibration
- Playback controls, per-book speed, presets
- Android foreground service, MediaSession, audio focus, `BECOMING_NOISY`
- Windows SMTC, media keys, device-change handling
- Text normalisation v1 and the pronunciation dictionary
- Skip rules driven by block roles

**Exit criteria.** An 8-hour continuous background session on stock Android with the
screen off, with no interruption and no position loss. Word gap audibly and measurably
correct at 0/60/120/250 ms. Highlight drift under 120 ms over a 10-minute chapter.
Media keys and lock-screen controls work on both platforms.

This phase is the risk retirement. If word-gap injection and timing remapping work here,
the rest of the project is execution rather than discovery.

---

## Phase 3 — Neural voices
*Target: 5 weeks*

- sherpa-onnx integration, Android and Windows, all target ABIs
- Piper adapter (Tier 1) with native speed
- Kokoro adapter (Tier 2) with the device memory gate
- DSP: formant-preserving pitch shift, WSOLA time stretch — **with the permissively
  licensed implementation chosen and audited** ([C-14](09-challenges-and-solutions.md#c-14))
- Word timing derivation: proportional estimation, plus per-word synthesis for the
  accessibility preset
- Voice Store: catalogue, previews, resumable hash-verified downloads, licence display,
  attribution page
- Voice licence audit completed and the allowlist published

**Exit criteria.** Piper plays on a 3 GB Android device without OOM. Kokoro loads on a
gated device and degrades with a clear message on an ungated one. Every shipped voice has
an `approved` licence verdict with a recorded audit date. Time to first audio under 1.2 s
on a warm neural voice.

---

## Phase 4 — PDF
*Target: 6 weeks* — the long one

- PDFium integration and page rendering
- Glyph extraction, word and line clustering
- Vertical band segmentation and column detection
- Reading-order construction and paragraph merging
- Running header/footer and page-number classification
- Hyphenation repair with lexicon checking
- Footnote detection and separation
- Text-selection overlay and quad-based highlighting
- **Reading-order overlay, manual region editing, column-count override**
- Scanned-PDF detection with an honest message
- Windowed analysis with background promotion and persistent caching

**Exit criteria.** Above 99% paragraph-order accuracy on a corpus of single-column
born-digital PDFs; above 90% on two-column academic papers. A 900-page PDF opens to a
readable first page in under 3 s. Manual correction persists and generalises to
structurally similar pages.

---

## Phase 5 — Remaining formats and polish
*Target: 3 weeks*

- DOCX, TXT, Markdown, HTML, RTF
- Encoding detection for plain text
- Windows desktop affordances: mini player, sidebar, two-page spread, keyboard shortcuts
- Accessibility pass with TalkBack and Narrator as a release gate
- Localisation scaffolding
- Onboarding

**Exit criteria.** All v1 formats open and read correctly. The full reading flow is
operable with a screen reader active without audio collision.

---

## Phase 6 — Release preparation
*Target: 3 weeks*

- Windows OV code signing through a cloud HSM in CI; MSIX and portable builds
- Play Console: Data Safety, foreground-service justification, AI disclosure
- Microsoft Store submission
- Battery and memory profiling per voice tier, published in the Voice Store
- Crash-free-session target above 99.5% in beta
- Store listings, screenshots, privacy policy, attribution page
- Beta with real users on a spread of Android OEMs — specifically including
  known-aggressive ones ([C-26](09-challenges-and-solutions.md#c-26))

**Exit criteria.** Both stores accept the build. No S1 or S2 open defects. Background
playback verified on at least four OEM Android skins.

---

## Total: roughly 28 weeks to v1.0

For a solo developer, treat that as a floor and expect 35–40 weeks with real life in it.
Phase 4 is the most likely to overrun; PDF layout analysis has a long tail of
special cases and no natural stopping point, which is exactly why it sits behind a
shippable milestone rather than in front of one.

---

## After v1.0

| Version | Contents |
|---|---|
| **v1.1** | Model-duration word timings via a sherpa-onnx contribution -> word-level highlighting on neural voices ([C-13](09-challenges-and-solutions.md#c-13)) |
| **v1.2** | OCR for scanned PDFs |
| **v1.3** | Cross-device sync (opt-in, state only, file-backend first) |
| **v1.4** | MOBI/AZW3 (DRM-free), export chapter to audio |
| **v1.5** | POS-based homograph disambiguation; expanded language coverage |
| **v2.0** | Per-character dialogue voices; spoken mathematics; voice cloning if a permissively licensed model exists |

---

## Things deliberately not on the roadmap

Recorded so they are re-proposed with knowledge of why they were excluded:

- DRM support ([ADR-010](10-decisions-adr.md#adr-010))
- Bundled cloud TTS ([C-24](09-challenges-and-solutions.md#c-24))
- A bookstore or content catalogue
- Mandatory accounts
- iOS and macOS — plausible later given Flutter, but it triples QA surface and is not a
  v1 conversation
- Being a general-purpose screen reader
