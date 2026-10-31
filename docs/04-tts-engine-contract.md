# 04 — TTS Engine Contract

Every voice, from the phone's own to Kokoro running on ONNX Runtime, enters the app the
same way: PCM plus word timings ([Contract B](02-architecture.md#25-contract-b--the-synthesis-result)).
This document says what each voice gives, what TomeVoice has to add, and what was
measured on a real phone. State as of 1.4.0, Android only.

## 4.1 The interface

The first design drew an abstract `TtsEngine` class with one adapter per engine. As
built there are three paths, each ending in the same `SynthesisResult`:

| Voice | Made by | Returns |
|---|---|---|
| **The phone's voices** (Google's, Samsung's, any installed TTS engine) | `SpeechService.synthesise` (Dart) -> `ReadingCore.kt`: one warm `TextToSpeech`, `synthesizeToFile` into the cache | A 16-bit WAV and every `onRangeStart` event, verbatim |
| **Natural voices** (Piper, Kokoro, Kitten) | `NeuralEngine` (`neural_voices.dart`) on a worker isolate: sherpa-onnx `generateWithConfig` | Float samples; no word timings |
| **A book's own narration** (EPUB 3 media overlays) | `narration.dart` with `NarrationAudio.kt`: clips decoded from the EPUB by `MediaCodec` | 16-bit samples at the file's rate; the clips' place in the text |

`SpeechService.wordTimingsFor` then gives every result its word timings: the engine's
own where it reported them, otherwise worked out from the pauses in the audio (§4.7).
The pipeline ([02 §2.6](02-architecture.md#26-the-audio-pipeline)) runs on a background
isolate and the PCM goes to the one streaming player.

Three rules no path may break:

1. **Return PCM, never play audio.** A path that plays sound has taken control away from
   the pipeline and every downstream feature breaks. Nothing calls `speak()`.
2. **Always return word timings.** If the voice does not give them, derive them, and
   mark the source honestly.
3. **Be cancellable.** A jump calls `cancelSynthesis` for the phone's voice, and stops a
   natural voice at the next piece of its sentence (§4.5).

## 4.2 Capability matrix

What each voice gives, and what TomeVoice therefore does itself.

| Capability | The phone's voices | Piper | Kokoro, Kitten | A book's narration | Windows WinRT (not built) |
|---|---|---|---|---|---|
| PCM | `synthesizeToFile` -> WAV | `generateWithConfig` | `generateWithConfig` | decoded from the EPUB | `SynthesizeTextToStreamAsync` |
| Word timings | **yes** on Google's TTS: `onRangeStart`, a word at a time, with its frame (§4.3) | none: from pauses | none: from pauses | each clip's stretch of text, from the SMIL | stream markers |
| Rate | `setSpeechRate` | the model's `speed` (a real duration change) | the model's `speed` | WSOLA in Dart, pitch kept | `Options.SpeakingRate` |
| Pitch | `setPitch`, per voice | none | none | none | `Options.AudioPitch` |
| Volume, loudness | the pipeline's gain | the pipeline's gain | the pipeline's gain | the pipeline's gain | `Options.AudioVolume` |
| Word gap | **none** | **none** | **none** | not applied | **none** |
| Voices | whatever the phone has installed | one model per voice | 29 speakers in one Kokoro model, 8 in Kitten's | the recording | installed Windows voices |
| Offline | usually; some voices need the network | yes, once downloaded | yes, once downloaded | yes | yes |

**No voice offers word-gap control, and no natural voice offers pitch.** Word gaps are
TomeVoice's own on every voice. Pitch on natural voices would need a formant-preserving
shifter in DSP; none was built, so their Fine-tune has no pitch slider
([C-14](09-challenges-and-solutions.md#c-14)).

## 4.3 Adapter: Android system TTS

The workhorse. Zero download, low memory, and the only voice that hands over word
timings for free.

**Synthesis.** `TextToSpeech.synthesizeToFile()` with a per-utterance id, writing a WAV
into the cache, read and deleted. Two things learned on the phone shape it:

- **One warm engine.** Creating a `TextToSpeech` per sentence (a service bind and a
  model load each time) was unusable. `ReadingCore.kt` keeps one, made with the Flutter
  engine, for listing engines and voices and for synthesis. Do not put a
  `shutdown()` back at the start of a sentence.
- **One sentence at a time.** Android keeps a single `UtteranceProgressListener`; two
  overlapping `synthesizeToFile` calls steal it and playback dies after one sentence.
  `SpeechService.synthesise` is strictly one at a time, and the next sentence is not
  asked for until the last has returned its PCM.

**Word timings, and the parameter order.**
`UtteranceProgressListener.onRangeStart(utteranceId, start, end, frame)` has existed since
API 26, TomeVoice's `minSdk`. The platform documents its fourth parameter as "the position
in frames in the audio of the request where this range is spoken", and warns that it is
"only called if the engine supplies timing information". Both were checked on the
developer's phone (Nothing A059, Android 16, Google's TTS) on 2026-09-02:

- **It fires a word at a time:** 17 events for a 17-word test sentence, with frame
  positions inside the 129,621-frame buffer at 24 kHz.
- **The parameters do not arrive in the documented order.** Google's TTS delivers
  `(frame, charStart, charEnd)`, the order of the engine-side
  `SynthesisCallback#rangeStart(markerInFrames, start, end)` it forwards. Read as
  documented, every word sat at frame 3, 9, 15…, all the injected silence went to the
  front of the buffer, and edge trimming removed it: the word-gap setting seemed to do
  nothing. The layout is therefore **detected, not assumed**
  (`SpeechService.decodeTimings`): character offsets are bounded by the text's length and
  frame positions are not, so whichever column runs past the text length is the frame.
  Each run records which layout it saw (`frameFirst`, `documented`, `ambiguous`), and an
  ambiguous one is marked `estimated`. Do not "simplify" this away.
- **Google's TTS hides its sentence pause inside a word.** It leaves about 360 ms after a
  sentence's full stop and reports the next range only when the pause is over, so the
  pause falls inside the last word's span. Do not assume every silence in the audio is
  one TomeVoice made.

A voice that reports no ranges at all gets its timings from the pauses in its audio,
as a natural voice does (§4.7). The phone had one TTS engine, so how other engines
report is still unmeasured (a Qualcomm speech package was installed but does not register
as a TTS engine).

**Avoid SSML.** With SSML, `start`/`end` index the SSML string, not the plain text.
TomeVoice sends plain text and does pauses itself.

**Choosing a voice.** Never force a locale: `engine.language = Locale.US` on a phone
without US English data selected a small embedded fallback voice, which is what made the
first spike sound poor. Voices are listed as the engine has them, and the language comes
first when picking one: the first fix sorted by quality and name only and chose an Arabic
voice for English text. As built: installed, then offline, then the phone's own region,
then the engine's quality (`SpeechService.pickVoice`). Google's `xx-YY-language` alias,
the same speaker as another voice, is hidden where the region lists its speakers.

**Rate and pitch.** `setSpeechRate` carries the reader's speed (0.5× to 3×). Pitch is
each voice's own (`ListeningPrefs.pitchByVoice`), because any `setPitch` other than 1.0
makes Google's TTS switch the voice to an older, rougher model (`lstm-embedded` instead of
`seanet-embedded`, seen in logcat); speech rate does not
([05 §5.2](05-tts-controls-spec.md#52-pitch)).

**Online voices.** A line with no letter or digit in any script is not sent (a Bengali
book's "।।।" dividers timed out on Google's online voice), and a network failure is tried
twice more before reading stops with a message saying the voice needs the internet.

## 4.4 Adapter: Windows WinRT

**Not built: Windows is not started** ([08](08-platform-windows.md)). The plan, kept for
if it is: `Windows.Media.SpeechSynthesis.SpeechSynthesizer` through a small C++/WinRT
plugin of TomeVoice's own, because `flutter_tts` is a play-the-text API where Contract B
needs bytes and markers ([ADR-013](10-decisions-adr.md#adr-013)).
`SynthesizeTextToStreamAsync` returns a WAV stream; with
`Options.IncludeWordBoundaryMetadata = true` its markers carry text and time offsets; rate,
pitch and volume are in `SpeechSynthesizer.Options` (since Windows 1709), and
`AppendedSilence` and `PunctuationSilence` (since 1803) could do part of the pause
shaping natively. The "natural" voices installed through Windows Settings are not always
reachable through this API; probe and report rather than promise them.

## 4.5 Adapter: Piper via sherpa-onnx

The default natural tier: one model per voice, fast enough for most phones.

**What ships.** Nothing in the APK. `tools/voice_catalog.py` builds
`app/assets/voices/catalog.json` from every Piper voice in sherpa-onnx's `tts-models`
release that comes in full precision: **180 voices in 42 languages** (as of 1.4.0), each
with its language, quality, download size (25 to 125 MB), a sample to hear and the
licence of the recordings it learned from ([06](06-voice-catalog-and-licensing.md)).
A voice is downloaded only when the reader picks it, from
`github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-<id>.tar.bz2`,
resumably, and unpacked file by file on another isolate into `voices/piper-<id>`.

**Full precision only.** The half-size (fp16) models abort ONNX Runtime on the phone
("Failed to find kernel for com.microsoft.Gelu … float16"): it has no fp16 kernel for one
of their layers on CPU.

**Synthesis.** `NeuralEngine` runs sherpa-onnx on a worker isolate that keeps the model
loaded (loading takes a second or two). It holds one model, or two on a phone with at
least 5,200 MB of memory as Linux counts it, and lets one go after 3 minutes unused. A
long sentence is made in pieces cut where it pauses anyway, so a jump stops at the next
piece instead of waiting for the whole sentence; the pieces are joined with a natural
pause and their joins become known points for the timings. A worker that dies or stops
answering fails its sentence, and reading goes on in the phone's voice (§4.9). The
worker sets its own thread and ONNX Runtime's to a lower priority when well ahead, so
scrolling and animation keep moving while a voice reads.

**Rate.** The model's `speed`: a real duration change, not resampling.

**Pitch.** Not available, and no DSP shift is built.

**Measured on the developer's phone** (Nothing A059, *Alice* at 2×, 60 s each):

| | CPU | Memory | Speed |
|---|---|---|---|
| Idle | 0.3% | 213 MB | |
| Google's voice | about 20% of a core (the app plus Google's TTS process) | about 404 MB (the app plus Google's TTS process) | |
| Kristin (Piper, medium) | 70% average, bursts to 158% | 537 MB | 10.9× real time |

Battery over a long session is not measured. After a download TomeVoice runs its own
speed test on the phone and keeps the result with the voice (`speed-test.txt`).

**Licensing.** Piper's engine moved from MIT (`rhasspy/piper`, archived) to GPL-3.0
(`OHF-Voice/piper1-gpl`); TomeVoice uses Piper's *models* through sherpa-onnx
(Apache-2.0) either way. The voices themselves carry mixed licences
([06 §6.4](06-voice-catalog-and-licensing.md#64-the-per-voice-trap)).

## 4.6 Adapter: Kokoro via sherpa-onnx

The premium tier. Kokoro-82M is a StyleTTS2-family model, Apache-2.0, with many speakers
in one model and quality close to paid commercial voices. Kitten (KittenML's nano 0.8,
Apache-2.0) is the small one: eight American English speakers in one 61 MB download.

**Why it is not the default.** Memory. Measured on an iPhone 15
([sherpa-onnx issue #2374](https://github.com/k2-fsa/sherpa-onnx/issues/2374)):

| | Package | Runtime footprint | Synthesis time |
|---|---|---|---|
| fp32 | 319 MB | 837 MB | 19.41 s |
| int8 | 103 MB | 786 MB | 39.13 s |

int8 saves download but barely any runtime memory, and doubles synthesis time
([ADR-007](10-decisions-adr.md#adr-007)).

**As built (1.4.0):** `kokoro-multi-lang-v1_0`, full precision, a 334 MB download with
29 speakers (Hindi among its languages). It holds about 850 MB while it reads, so:

- it is **offered only on a phone with at least 5,200 MB of memory** as Linux counts it
  (a 6 GB phone), `minMemoryMb` in the catalogue;
- it is **read with only once the phone's own speed test shows it keeps up**
  (at least 1.05 seconds of speech per second of work); on many phones it cannot, and
  it would leave pauses between sentences;
- it is never pre-selected, and is unloaded with the others after 3 minutes unused.

**Rate.** Native `speed`. **Pitch.** None.

**Voices.** One model, many speaker embeddings, so switching speaker is free once
loaded; the pack is downloaded, tested and removed as one.

## 4.7 Deriving word timings for neural engines

Both word highlighting and word-gap injection depend on word timings, and natural voices
give none. The first design ranked four strategies: (1) read the model's own durations,
(2) synthesise word by word, (3) forced alignment with a second model, (4) share the
sentence's length out over its words by character count, with the UI dropping to
sentence highlighting for (4).

**As built: pauses as anchors** (`PauseAligner`, `packages/tomevoice_audio/lib/src/align.dart`).

Sharing a sentence out by character count drifts: against an engine's own timings it was
271 ms out on average and 610 ms at worst, and the highlight, the word gap and the page
turns all followed it. Part of that was the engine's own silence before and after the
speech, shared out as if it were words; the rest built up word by word.

But the audio says one thing for certain: where the voice pauses. The text says where it
ought to (commas, full stops, dashes). The aligner matches the two in order, then shares
out each stretch between two pauses over its own words, so a guess that runs fast or slow
is put right at the next pause instead of carrying on to the end of the sentence. Pauses
shorter than 70 ms are not looked for (a stop consonant can be silent that long), and
quieter than −40 dB relative to the loudest moment is not voice. Where a long sentence was
made in pieces, the joins are known points too.

The words of a stretch shorter than 3.5 s are `anchored`, and highlighted word by word.
A longer stretch with no pause found keeps its words `estimated`, and the reader
highlights the sentence there rather than a confidently wrong word. The document's own
word units are used, so Chinese and Japanese, which have no spaces, align a character at
a time.

Not built: (1) needs sherpa-onnx to expose the duration predictor, which it does not;
(2) would flatten prosody; (3) would mean a second model and a second inference per
sentence.

## 4.8 Phonemisation

Neural TTS models do not consume letters; they consume phonemes. The grapheme-to-phoneme
front end Piper (and Kokoro) were trained against is **eSpeak-NG**, which is **GPL-3.0**.

An early version of this section said sherpa-onnx had "removed the eSpeak-NG and
`piper-phonemize` dependencies to stay cleanly Apache-2.0". **That was false**
(checked 2026-09-01): the removal is a proposal for a future 2.0.0
([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08),
and the 1.13.x line still bundles eSpeak-NG ("Fix installing espeak-ng-data directory",
v1.13.5's release notes). Under TomeVoice's own GPL-3.0
([ADR-014](10-decisions-adr.md#adr-014)) that is harmless.

**Our position:**

- **Use eSpeak-NG**, as shipped inside sherpa-onnx: it produces the phoneme distribution
  the models expect.
- **Pin the version.** `sherpa_onnx: 1.13.8` in `app/pubspec.yaml`. If 2.0.0 drops
  eSpeak-NG, the escape hatches are a supplied `lexicon.txt` or pre-tokenised phoneme
  strings; review deliberately before crossing that boundary
  ([recheck triggers](10-decisions-adr.md#recheck-triggers)).
- **Per-voice licences are a separate question** from the engine's, and GPL-3.0 does not
  settle them ([06](06-voice-catalog-and-licensing.md)).

There is no Piper voice for Bengali in sherpa-onnx's release, so a Bengali book uses the
phone's voice ([12](12-roadmap-and-milestones.md)).

## 4.9 Engine selection and fallback

Which voice reads a book, as built:

1. The voice the reader chose for this book on its page.
2. Else the voice they use for the book's language (a language's usual voice must speak
   that language).
3. Else the phone's best voice for the language (§4.3), or a related language's where the
   phone has none: Ukrainian, Belarusian, Bulgarian, Serbian and Macedonian in a Russian
   voice, Urdu in a Hindi one, Persian in an Arabic one.

A natural voice is used only once the reader has chosen one; nothing downloads by
itself. On top of the narrator's voice, a book can have a dialogue voice and, in English
books, a voice per character ([05 §5.10](05-tts-controls-spec.md#510-multi-voice-and-language)).

**Failure.** A natural voice that fails (a model that will not load, a worker that dies)
does not stop the book or skip sentences: the phone's voice for the book's language reads
on in its place (`fallbackVoiceOf` in `scheduler.dart`), and a failed natural voice is
not asked again in that reading. A voice that fails and cannot be replaced says so
instead of going quiet.
