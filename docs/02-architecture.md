# 02 — Architecture

How TomeVoice is put together as of 1.4.0, Android only. Where the build differs from
the first design (2026-09-01), the table in 2.3 says so; the reasoning behind each choice
is in the [decision log](10-decisions-adr.md).

## 2.1 The two contracts

Almost every hard problem in this project dissolves if two interfaces are defined
correctly and everything else is written against them. Get these wrong and the codebase
becomes a per-format, per-engine combinatorial mess.

**Contract A — the Document Model.** Every input format is normalised into one linear,
addressable stream of text. The reader renders it. The speech engine consumes it.
Neither knows what a PDF is.

**Contract B — the Synthesis Result.** Every voice returns raw PCM *plus word
timings*, never "fire and forget playback". Everything the product promises —
highlighting, word gaps, pause shaping, scrubbing, page turns that follow the voice — is
a pure function of those two things.

If you remember nothing else from this document: **we never call
`TextToSpeech.speak()`**. The phone's voices go through `synthesizeToFile()`, natural
voices through sherpa-onnx's `generate()`, and a book's own recorded narration is
decoded from its audio files; each gives bytes back, and TomeVoice runs its own player.
See [ADR-003](10-decisions-adr.md#adr-003) for why this is not optional.

## 2.2 Layer diagram

```
+----------------------------------------------------------------------+
|  APP  (Flutter, app/lib)                                             |
|  Library - book page - reader (scroll, pages, a PDF's pages) -       |
|  player - Now Playing - voices - web novels - Saved, Stats, Settings |
+---------------+--------------------------------+---------------------+
                |                                |
+---------------v--------------+  +--------------v---------------------+
|  READING                     |  |  LISTENING                         |
|  ReadingLayout, places,      |<>|  PlaybackScheduler (~10 s ahead),  |
|  pages, highlight            |  |  listening session, media session  |
+---------------+--------------+  +--------------+---------------------+
                |                                |
                |        +-----------------------v---------------------+
                |        |  AUDIO PIPELINE  (packages/tomevoice_audio) |
                |        |  edge trim -> stretch -> word gap ->        |
                |        |  punctuation -> sentence pause -> gain      |
                |        +-----------------------+---------------------+
                |                                |
                |        +-----------------------v---------------------+
                |        |  VOICES   (Contract B)                      |
                |        |  the phone's TTS (ReadingCore.kt) -         |
                |        |  natural voices (sherpa-onnx, worker        |
                |        |  isolate) - a book's narration (SMIL clips) |
                |        +---------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  DOCUMENT MODEL   (Contract A, packages/tomevoice_document)          |
|  Book -> Section -> Block -> Sentence; ReadingCursor                 |
+---------------+------------------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  INGESTION    EPUB - PDF (text from PdfText.kt) - DOCX/ODT -         |
|               MOBI/AZW3 - FB2 - RTF - HTML/MD/TXT - web chapters     |
+---------------+------------------------------------------------------+
                |
+---------------v------------------------------------------------------+
|  ANDROID  (app/android_overlay, Kotlin)                              |
|  ReadingCore (the cached Flutter engine, TTS, player, audio focus) - |
|  PcmPlayer (AudioTrack) - ReadAloudService (foreground service,      |
|  MediaSession, media browser) - PdfText/PdfPages - Ocr - AudioExport |
|  - widgets - WorkManager and data-sync services - JSON files on disk |
+----------------------------------------------------------------------+
```

## 2.3 Technology choices

| Concern | First design (2026-09-01) | Built (1.4.0) |
|---|---|---|
| App framework | Flutter, Android and Windows | Flutter (3.47.8, Dart 3.13.7 in CI), **Android only**; Windows not started ([08](08-platform-windows.md)) |
| Language | Dart, C/C++ through FFI for DSP and inference | Dart, Kotlin on the Android side. No C/C++ of our own: native code comes in through packages (sherpa-onnx, QuickJS, Tesseract) |
| Natural voices | sherpa-onnx | sherpa-onnx's Dart package, pinned at **1.13.8**: Piper, Kokoro and Kitten models ([04 §4.5](04-tts-engine-contract.md#45-adapter-piper-via-sherpa-onnx)) |
| PDF text | PDFium through `pdfrx`, glyph geometry | **PdfBox-Android** 2.0.27.0 (`PdfText.kt`): text, paragraphs and each line's position; the clean-up is Dart (`formats/pdf.dart`) |
| PDF pages | PDFium through `pdfrx` | Android's own `PdfRenderer` (`PdfPages.kt`), no library |
| EPUB rendering | A WebView with an epub.js-style renderer | **Flutter text** drawn from the Document Model: the scrolling page (`reader_text.dart`) and pages cut from the same `TextPainter`s (`paged_view.dart`). No WebView ([ADR-005](10-decisions-adr.md#adr-005)) |
| EPUB, DOCX parsing | Dart, in-process | As planned, plus ODT, MOBI/AZW3, FB2 and RTF, all Dart |
| Persistence | SQLite through Drift | **JSON files**, written atomically ([11](11-data-model-and-storage.md), [ADR-012](10-decisions-adr.md#adr-012)) |
| Audio output | `miniaudio` through FFI | One streaming `AudioTrack` (`PcmPlayer.kt`) fed PCM16, gapless, its playback head the clock for the highlight |
| Pitch and time | A C++ core around a GPL stretcher | Speed is the voice's own rate. A WSOLA stretcher in Dart (`stages/stretch.dart`) serves only a book's recorded narration. No pitch shifter: natural voices have no pitch control |
| Web novels | not planned | LNReader's source plugins in QuickJS (`flutter_qjs`), in a pool of background isolates ([ADR-019](10-decisions-adr.md#adr-019)) |
| OCR | v1.x | Tesseract4Android 4.9.0 on the phone (`Ocr.kt`) |
| Saving as audio | v1.x | AAC in MP4 by Android's encoder and muxer, MP3 by jump3r 1.0.5 (LAME in Java) (`AudioExport.kt`); chapter marks written by Dart |
| Background work | not specified | WorkManager 2.10.0 for the check for new chapters (`NovelCheckWorker.kt`); data-sync foreground services for downloads, OCR and saving as audio |

## 2.4 Contract A: the Document Model

`packages/tomevoice_document/lib/src/model.dart`, simplified:

```dart
class Book {
  final String id;
  final BookMetadata metadata;      // title, authors, language, cover, description, series
  final List<Section> sections;     // EPUB spine items, a PDF's chapters, a web novel's chapters
  final List<TocEntry> toc;
  final SourceKind source;          // epub | text | markdown | html | pdf | docx | rtf | odt
                                    // | fb2 | mobi | web
  final Narration? narration;       // an EPUB 3's media overlays, when it has them
}

class Section {
  final String id;
  final int index;
  final String? title;
  final List<Block> blocks;
}

/// The unit of layout AND the unit of "should this be spoken at all".
class Block {
  final String id;
  final BlockRole role;             // heading | paragraph | listItem | quote | caption
                                    // | footnote | table | code | pageNumber
                                    // | runningHeader | figure | math
  final String text;                // whitespace-collapsed
  final List<Sentence> sentences;
  final String? language;
  final Anchor anchor;              // EpubAnchor | PageAnchor (a PDF page) | OffsetAnchor
  final String? image;              // a picture block's file, with its size
}

class Sentence {
  final int startOffset, endOffset; // within Block.text
  final List<WordSpan> words;       // already tokenised
  final List<TextStretch> silent;   // shown but not spoken: a footnote's marker
}

/// A place in a book: what is saved, synced and carried across re-parses.
class ReadingCursor { final int sectionIndex, blockIndex, sentenceIndex; }
```

Three properties matter more than the exact field names:

1. **Roles drive skip rules.** `runningHeader`, `pageNumber`, `footnote`, `caption` and
   `figure` are classified *at ingestion time*, so "do not read footnotes" is a filter over
   the model (`defaultSkippedRoles`, Read notes aloud) rather than a regex hack in the
   speech layer.
2. **A place is a sentence, not a scroll offset.** The first design made anchors
   format-native (an EPUB CFI, PDF quads) so reflow could never lose the place. As built,
   the place is section, block and sentence numbers (`ReadingCursor`). Reflow cannot move
   it, and when a better parser renumbers a book, `relocateCursor` finds the saved
   sentence again by its words ([11 §11.4](11-data-model-and-storage.md#114-places)).
   Anchors are still recorded (an EPUB block's file and element, a PDF block's page) but
   nothing depends on them being CFIs.
3. **Sentences are pre-tokenised.** Segmentation is done once at ingestion, so the
   scheduler never has to; `ReadingLayout` (`reading_layout.dart`) flattens a book into
   the units the voice reads, with constant-time lookups between units, items and
   chapters.

## 2.5 Contract B — the Synthesis Result

`packages/tomevoice_audio/lib/src/types.dart`:

```dart
class SynthesisResult {
  final AudioBuffer audio;               // mono float PCM and its sample rate
  final List<WordTiming> wordTimings;
  final String engineId;
  final Set<Capability> appliedNatively; // what the engine honoured itself
}

class WordTiming {
  final int charStart, charEnd;          // into the text the voice was given
  final int frameStart, frameEnd;        // into the audio
  final WordTimingSource source;         // engineReported | modelDurations | aligned
                                         // | anchored | estimated
}
```

`appliedNatively` is the mechanism behind "degrade loudly": the pipeline knows what it
must still do itself.

`WordTimingSource` is the honesty field. The phone's voices report each word
(`engineReported`). Natural voices report none, so their timings are worked out from
the pauses in the audio (`anchored`, [04 §4.7](04-tts-engine-contract.md#47-deriving-word-timings-for-neural-engines));
a long stretch with no pause in it stays `estimated`, and the reader then highlights the
sentence rather than confidently highlighting the wrong word. `modelDurations` and
`aligned` are in the enum for routes not built.

What the voice is given is not always the page's text: a footnote marker is silent, a
long link is said as its site, the reader's pronunciation rules respell words. Each
change carries its source range (`SpokenText`, `speech.dart`), so a word the voice reports
is highlighted on the page's own words.

## 2.6 The audio pipeline

This is where the promised control surface is actually implemented
(`buildStandardPipeline` in `packages/tomevoice_audio/lib/tomevoice_audio.dart`).

Stage order is load-bearing. Device measurement (2026-09-02) and
`packages/tomevoice_audio/test/ordering_test.dart` pin it. Do not restore the
earlier "pitch then stretch then trim" sketch — that deleted injected gaps and
halved them at 2×.

```
SynthesisResult (pcm + wordTimings)
        |
        +-- 1. Edge trim            engine lead-in/tail silence
        |                           MUST run first: later stages insert silence
        |                           the trimmer cannot distinguish from padding
        |
        +-- 2. Time stretch         the resampling stub; reading gives it 1.0,
        |                           because speed is the voice's own rate
        |
        +-- 3. Word gap injection   insert N ms of silence at every word boundary
        |                           MUST run after (2), or the gaps get stretched too
        |
        +-- 4. Punctuation pauses   comma / clause / colon / dash
        |
        +-- 5. Sentence pause       0 when reading: the scheduler appends the pause
        |                           after each sentence (sentence or paragraph) as
        |                           silent frames when the PCM is encoded
        |
        +-- 6. Gain                 volume, trim, loudness levelling, compression,
        |                           limiter
        |
        +--> PCM16 -> PcmPlayer (one streaming AudioTrack)
```

The pipeline runs on a background isolate (`renderInBackground`, `speech_service.dart`):
on the UI isolate it cost a dropped frame per sentence. A book's recorded narration runs
its clips through `TimeStretchStage` (WSOLA, pitch kept) instead of the stub, since a
recording has no rate of its own to set (`narration.dart`).

Every stage returns a **timing remap function** alongside its output buffer. The
pipeline composes them so the final word timings — the ones highlighting uses — refer
to the *post-processed* audio, not the raw synth output. Forgetting this is the single
most likely source of "highlighting drifts after I change the speed" bugs.

## 2.7 The lookahead scheduler

Synthesis is not instant: a natural voice makes a sentence in a fraction of its length
on the developer's phone (Kristin, a Piper voice, at about 10.9 times real time), but
Kokoro keeps up only on fast phones. Playback must therefore never wait on synthesis
except for the very first sentence.

```
cursor --> [ sentence n   ] playing
           [ sentence n+1 ] in the AudioTrack's queue
           [ sentence n+2 ] in the queue          (about 10 s queued in all)
           [ sentence n+3 ] being made            <-- one at a time
```

As built (`PlaybackScheduler`, `scheduler.dart`):

- **About 10 seconds of audio stay queued** ahead of what is audible. The highlight is the
  player's hardware position, not a timer.
- **One sentence is made at a time.** Android's `TextToSpeech` has a single
  `UtteranceProgressListener`: two overlapping `synthesizeToFile` calls steal it and
  playback dies after one sentence, so `SpeechService` is strictly one at a time.
- **Natural voices run on a worker isolate** that keeps the model loaded (one model, or
  two on a phone with at least 5,200 MB of memory) and lets it go after 3 minutes unused.
  A sentence is made at full priority when little is queued for the time it will take
  (less than twice that, plus 1.5 s), at a lower one when well ahead, so the screen keeps
  moving. A long sentence is made in pieces cut where it pauses anyway, so a jump waits
  for one piece, not the whole sentence. The voice is loaded, and run once unheard, as a
  book opens.
- **A change that invalidates audio** (voice, speed, pitch, gap, a pronunciation rule)
  drops what is queued and goes on from the sentence being read.
- **On a jump** the queue is dropped and refilled from the target sentence.
- **A natural voice that fails** reads on in the phone's voice for the book's language
  rather than stopping ([04 §4.9](04-tts-engine-contract.md#49-engine-selection-and-fallback)).

## 2.8 Module layout

The first design drew one `lib/` tree with `domain/`, `data/`, `engine/` and `ui/`. The
repository is two pure-Dart packages, the Flutter app with its Android sources, and the
tools:

```
packages/tomevoice_audio/      Contract B and the pipeline. Pure Dart, tested with the
                               plain Dart SDK: stages/, align.dart (word timings from
                               pauses), analysis.dart, wav.dart, resample.dart
packages/tomevoice_document/   Contract A and every format. Pure Dart: model.dart,
                               ingest.dart, detect.dart, segment.dart, language.dart,
                               navigate.dart, reading_layout.dart, speech.dart,
                               narration.dart, formats/ (epub, html_blocks, pdf, office,
                               mobi, fb2, rtf, text, web, media_overlays);
                               test/corpus/ (real books with goldens); tool/ (dump_book)
app/lib/                       The Flutter app, a mostly flat folder (about 130 files): the
                               library (library_store.dart, library_screen.dart), the
                               reader (reader_*.dart, paged_view.dart, pages_view.dart),
                               listening (scheduler.dart, listening_session.dart,
                               speech_service.dart, neural_voices.dart), web novels
                               (sources/, browse_, novel_, updates_, web_reader.dart),
                               and the rest by feature
app/android_overlay/           Kotlin and resources laid over the scaffolding that
                               `flutter create` makes in CI (its README says how)
app/assets/                    fonts, the starter book, the voice catalogue, the bundled
                               JavaScript for LNReader plugins
tools/                         prepare_android.py (manifest and Gradle patches),
                               voice_catalog.py, check_16kb.py, the spike's verifier
                               (bin/measure.dart, bin/make_fixture.dart), lnreader_libs/
mobile-qa/                     Maestro flows and the CI emulator script
```

The dependency rule held: the two packages depend on neither Flutter nor each other. No
parser imports a voice; no voice imports a parser. The app is the only place both meet.
