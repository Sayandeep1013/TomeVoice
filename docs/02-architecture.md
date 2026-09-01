# 02 — Architecture

## 2.1 The two contracts

Almost every hard problem in this project dissolves if two interfaces are defined
correctly and everything else is written against them. Get these wrong and the codebase
becomes a per-format, per-engine combinatorial mess.

**Contract A — the Document Model.** Every input format is normalised into one linear,
addressable stream of text with stable anchors back into the rendered view. The reader
renders it. The speech engine consumes it. Neither knows what a PDF is.

**Contract B — the Synthesis Result.** Every speech engine returns raw PCM *plus word
timings*, never "fire and forget playback". Everything the product promises —
highlighting, word gaps, pause shaping, scrubbing, repeat-sentence — is a pure function
of those two things.

If you remember nothing else from this document: **we never call
`TextToSpeech.speak()`**. We call `synthesizeToFile()` / `SynthesizeTextToStreamAsync()`
/ sherpa-onnx `generate()`, get bytes back, and run our own player. See
[ADR-003](10-decisions-adr.md#adr-003) for why this is not optional.

## 2.2 Layer diagram

```
+----------------------------------------------------------------------+
|  PRESENTATION            Flutter widgets, shared Android + Windows    |
|  Library - Reader view - Player bar - Voice manager - Settings        |
+---------------+--------------------------------+---------------------+
                |                                |
+---------------v--------------+  +--------------v---------------------+
|  READER DOMAIN               |  |  SPEECH DOMAIN                     |
|  - Pagination / scroll state |<>|  - Reading cursor                  |
|  - Highlight overlay         |  |  - Lookahead scheduler             |
|  - Navigation (TOC, search)  |  |  - Playback session + MediaSession |
+---------------+--------------+  +--------------+---------------------+
                |                                |
                |        +-----------------------v---------------------+
                |        |  AUDIO PIPELINE  (all DSP lives here)       |
                |        |  pitch shift -> time stretch -> gap inject  |
                |        |  -> pauses -> loudness -> ring buffer       |
                |        +-----------------------+---------------------+
                |                                |
                |        +-----------------------v---------------------+
                |        |  ENGINE ADAPTERS   (Contract B)             |
                |        |  AndroidSystem - WindowsWinRT - Piper -     |
                |        |  Kokoro - (future: cloud, BYO key)          |
                |        +---------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  DOCUMENT MODEL   (Contract A)                                       |
|  Book -> Section -> Block -> Sentence -> Word, + Anchor <-> render    |
+---------------+------------------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  INGESTION      EPUB - PDF - DOCX - TXT/MD/HTML/RTF  parsers         |
|                 + text normaliser + language detector                |
+---------------+------------------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  PLATFORM       File access (SAF / Win32) - SQLite - Model store -   |
|                 Audio output - Foreground service / background task  |
+----------------------------------------------------------------------+
```

## 2.3 Technology choices

| Concern | Choice | Rationale (full reasoning in [ADRs](10-decisions-adr.md)) |
|---|---|---|
| App framework | **Flutter** | Only mainstream framework with first-party, stable Windows *and* Android from one codebase. React Native Windows is functional but second-class; MAUI has no comparable neural-TTS story; Electron + a mobile wrapper doubles the runtime cost on phones. |
| Language | Dart, with C/C++ via FFI for DSP and inference | |
| Neural TTS runtime | **sherpa-onnx** (`sherpa_onnx` + `sherpa_onnx_windows` on pub.dev) | Ships Dart FFI bindings (v1.13.7, Apache-2.0), supports Piper/VITS/Kokoro/Matcha behind one API, and covers Android arm64/arm32/x86_64 plus Windows. Note it still bundles GPL-3.0 eSpeak-NG — fine under our own GPL-3.0 licence, and see [ADR-006](10-decisions-adr.md#adr-006) for a correction to an earlier claim that it had been removed. |
| PDF render + text | **PDFium** via `pdfrx` | The engine Chrome uses; gives us glyph positions, not just a text blob, which is what reading-order reconstruction needs. |
| EPUB render | **WebView** (`flutter_inappwebview`) hosting a controlled epub.js-style renderer | An EPUB *is* HTML + CSS. Reimplementing a CSS engine in Flutter widgets loses fidelity on every real-world book. |
| EPUB parse (metadata, spine, text for TTS) | Dart, in-process | We parse the OPF/NCX/XHTML ourselves for the Document Model; the WebView is only for pixels. |
| DOCX | Dart OOXML parsing | DOCX is a zip of XML; no native dependency needed. |
| Persistence | SQLite via Drift | Typed queries, migrations, identical on both targets. |
| Audio output | `miniaudio` via FFI (one backend, both platforms) | Avoids two different platform players with two different latency and device-change behaviours. |
| DSP (pitch/time) | Small C++ core around a GPL stretcher (e.g. Rubber Band) | Under our own GPL-3.0 licence the best-in-class libraries are available, so no custom phase-vocoder work is needed. See [C-14](09-challenges-and-solutions.md#c-14). |

## 2.4 Contract A — the Document Model

```dart
class Book {
  final BookId id;
  final BookMetadata metadata;      // title, authors, language, cover, identifiers
  final List<Section> sections;     // EPUB spine items / PDF page groups / DOCX body
  final TableOfContents toc;
  final SourceKind source;          // epub | pdf | docx | text | html
}

class Section {
  final SectionId id;
  final int index;
  final List<Block> blocks;
}

/// The unit of layout AND the unit of "should this be spoken at all".
class Block {
  final BlockId id;
  final BlockRole role;             // heading | paragraph | listItem | quote | caption
                                    // | footnote | table | code | pageNumber
                                    // | runningHeader | figure | math
  final String text;                // normalised, whitespace-collapsed
  final List<Sentence> sentences;
  final String? language;           // BCP-47, may differ from the book language
  final Anchor anchor;              // -> where this lives in the rendered view
}

class Sentence {
  final int startOffset;            // char offset within Block.text
  final int endOffset;
  final List<WordSpan> words;       // char ranges, already tokenised
}

/// The bridge between "text we speak" and "pixels we highlight".
sealed class Anchor {}
class EpubAnchor   extends Anchor { final String cfi; }        // EPUB CFI
class PdfAnchor    extends Anchor { final int page; final List<Rect> quads; }
class OffsetAnchor extends Anchor { final int start, end; }    // DOCX / TXT
```

Three properties matter more than the exact field names:

1. **Roles drive skip rules.** `runningHeader`, `pageNumber`, `footnote` and `caption`
   are classified *at ingestion time*, so "skip page numbers" is a filter over the model
   rather than a regex hack buried in the speech layer.
2. **Anchors are format-native.** We do not invent a universal coordinate system. An
   EPUB anchor is a CFI (survives font-size changes and reflow); a PDF anchor is a page
   plus quads (survives zoom). Reflow must never invalidate reading position.
3. **Sentences are pre-tokenised.** Sentence segmentation is expensive and
   language-dependent; doing it once at ingestion makes the speech scheduler trivial.

## 2.5 Contract B — the Synthesis Result

```dart
class SynthesisRequest {
  final String text;                // ONE sentence, already normalised for speech
  final VoiceId voice;
  final EngineParams params;        // rate/pitch/volume the ENGINE will apply natively
  final String? language;
}

class SynthesisResult {
  final Float32List pcm;            // mono
  final int sampleRate;
  final List<WordTiming> wordTimings;
  final Set<Capability> appliedNatively;  // what the engine actually honoured
}

class WordTiming {
  final int charStart, charEnd;     // into SynthesisRequest.text
  final int frameStart, frameEnd;   // into pcm
  final WordTimingSource source;    // engineReported | modelDurations | aligned | estimated
}
```

`appliedNatively` is the mechanism behind principle 4 ("degrade loudly"). If the adapter
did not honour pitch, the pipeline knows it must pitch-shift in DSP, and the UI knows to
show a "software pitch" indicator.

`WordTimingSource` is the honesty field. `estimated` timings (the
proportional-to-character fallback) are good enough for gap injection but will visibly
drift in highlighting, so the UI falls back to sentence-level highlighting rather than
confidently highlighting the wrong word.

## 2.6 The audio pipeline

This is where the promised control surface is actually implemented.

```
SynthesisResult (pcm + wordTimings)
        |
        +-- 1. Pitch shift          if pitch requested and NOT appliedNatively
        |                           (formant-preserving; timings unchanged)
        |
        +-- 2. Time stretch         if rate is outside the engine's good range
        |                           (WSOLA; timings scaled by the stretch factor)
        |
        +-- 3. Word gap injection   insert N ms of silence at every word boundary
        |                           MUST run after (2), or the gaps get stretched too
        |
        +-- 4. Punctuation pauses   comma / clause / sentence / paragraph / heading
        |
        +-- 5. Loudness normalise   target LUFS, so switching voices never blasts the user
        |
        +-- 6. Fades and trim       trim leading/trailing silence, 5 ms edge fades
        |
        +--> ring buffer -> miniaudio output
```

Every stage returns a **timing remap function** alongside its output buffer. The
scheduler composes them so the final word timings — the ones highlighting uses — refer
to the *post-processed* audio, not the raw synth output. Forgetting this is the single
most likely source of "highlighting drifts after I change the speed" bugs.

## 2.7 The lookahead scheduler

Neural synthesis is not instant. Kokoro on a mid-range Android SoC has been measured at
roughly 0.45 real-time factor — about 4.5 s of compute for 10 s of audio — and on weaker
hardware Kokoro runs *slower* than real time. Playback must therefore never wait on
synthesis except for the very first sentence.

```
cursor --> [ sentence n   ] playing
           [ sentence n+1 ] synthesised, in buffer
           [ sentence n+2 ] synthesising now      <-- worker isolate
           [ sentence n+3 ] queued
           [ sentence n+4 ] text prepared, not queued
```

Rules:

- Lookahead depth is **adaptive**: measured RTF decides how many sentences stay
  buffered — deeper for slow engines, shallower to save memory on system voices.
- Synthesis runs in a **worker isolate** with its own FFI engine handle. The UI isolate
  never blocks.
- Any control change that invalidates audio (voice, rate, pitch, gap) **flushes from
  n+1 onward** and lets sentence *n* finish, so the change is audible at the next
  sentence instead of causing a glitch.
- On seek, the buffer is dropped and re-primed from the target sentence.

## 2.8 Module layout

```
lib/
  app/                    bootstrap, routing, DI, theming
  domain/
    document/             Document Model, anchors, roles
    speech/               engine contract, params, capability model
    library/              books, collections, reading state
  data/
    ingest/
      epub/  pdf/  docx/  text/      one parser per format
      normalise/                     text normalisation, sentence + word tokenisers
      classify/                      block-role classification (headers, footnotes...)
    persistence/          Drift database, migrations, file store
    voices/               catalogue, downloader, integrity check, licence metadata
  engine/
    adapters/
      android_system/  windows_winrt/  sherpa_piper/  sherpa_kokoro/
    audio/              pipeline stages, ring buffer, output device
    scheduler/          lookahead, cursor, session
  ui/
    library/  reader/  player/  voices/  settings/
  platform/
    android/            foreground service, MediaSession, audio focus, SAF
    windows/            SMTC, device change, file association, packaging hooks
native/
  dsp/                  C++ pitch/stretch/gap, built for android-arm64/x86_64,
                        win-x64/arm64
```

The dependency rule is one-directional: `ui -> domain <- data`, and `engine` depends
only on `domain`. No parser ever imports an engine; no engine ever imports a parser.
