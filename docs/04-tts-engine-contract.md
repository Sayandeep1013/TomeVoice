# 04 — TTS Engine Contract

Every voice, from the free Android system voice to Kokoro running on ONNX Runtime,
enters the app through one interface. This document specifies it and explains what each
adapter has to do to satisfy it.

## 4.1 The interface

```dart
abstract class TtsEngine {
  EngineId get id;

  /// What this engine can do natively. Drives UI affordances and the DSP fallback
  /// decisions in the audio pipeline.
  EngineCapabilities get capabilities;

  Future<void> initialise(EngineConfig config);
  Future<List<Voice>> listVoices();
  Future<void> loadVoice(VoiceId id);

  /// The whole contract. One sentence in, PCM plus word timings out.
  /// Must be cancellable: a seek or a settings change discards in-flight work.
  Future<SynthesisResult> synthesise(SynthesisRequest req, CancellationToken token);

  Future<void> dispose();
}

class EngineCapabilities {
  final bool nativeRate;        final ({double min, double max}) rateRange;
  final bool nativePitch;       final ({double min, double max}) pitchRange;
  final bool nativeVolume;
  final bool ssml;
  final WordTimingSource timingSource;
  final bool streaming;         // can emit PCM before the sentence is finished
  final int sampleRate;
  final int approxPeakMemoryMb; // used for device gating
}
```

Three rules that adapters may not break:

1. **Return PCM, never play audio.** An adapter that plays sound has taken control away
   from the pipeline and every downstream feature breaks.
2. **Always return word timings.** If the engine does not provide them, derive them, and
   mark the source honestly.
3. **Be cancellable within ~100 ms.** Seeking in a book is common; a 6-second
   uncancellable synthesis makes the app feel broken.

## 4.2 Capability matrix

What each engine actually gives us, and what we must therefore build ourselves.

| Capability | Android system TTS | Windows WinRT | Piper (sherpa-onnx) | Kokoro (sherpa-onnx) |
|---|---|---|---|---|
| PCM output | `synthesizeToFile` -> WAV | `SynthesizeTextToStreamAsync` | native | native |
| Word timings | **yes** — `onRangeStart` gives char range **and frame position** | **yes** — stream markers with time offsets | no | no |
| Rate | `setSpeechRate`, engine-dependent quality | SSML `prosody rate` / `Options.SpeakingRate` | `length_scale` | `speed` |
| Pitch | `setPitch` (~0.5–2.0) | SSML `prosody pitch` / `Options.AudioPitch` | **none** | **none** |
| Volume | via SSML / stream gain | `Options.AudioVolume` | none (gain in DSP) | none (gain in DSP) |
| SSML | engine-dependent; Google TTS honours `break`, most others partially | SSML 1.1 supported | none | none |
| Word gap | **none** | **none** | **none** | **none** |
| Appended / punctuation silence | none | **yes** — `AppendedSilence`, `PunctuationSilence` | none | none |
| Voice count | whatever the user has installed | installed Windows voices | ~1 model per voice | 50+ voices in one model |
| Offline | yes (usually) | yes | yes | yes |
| Peak RAM | tens of MB | tens of MB | ~50–150 MB | **several hundred MB** |
| Quality | fair to good | fair | good, audibly synthetic | very good |

The two empty columns tell the story: **no engine offers word-gap control**, and **no
neural engine offers pitch**. Both promised features must be built in DSP. That is the
justification for the entire audio pipeline.

## 4.3 Adapter: Android system TTS

The workhorse. Zero download, low memory, and the only engine that hands us word timings
for free.

**Synthesis.** `TextToSpeech.synthesizeToFile()` with a per-utterance ID, writing to a
temp WAV, then read and delete. (`AudioTrack`-style direct playback via `speak()` is
what we are deliberately avoiding.)

**Word timings.** `UtteranceProgressListener.onRangeStart(String utteranceId, int start,
int end, int frame)`, available since **API 26** — exactly our `minSdk`. The fourth
parameter is documented verbatim as "The position in frames in the audio of the request
where this range is spoken": precisely what we need to map a character range onto a PCM
offset, with no estimation.

**The caveat that defines the risk.** The platform documentation states it is *"Only
called if the engine supplies timing information by calling
`SynthesisCallback#rangeStart(int, int, int)`"*. Engines are not obliged to. Some report
per word, some per utterance, some never. **Which engines on a given device actually
supply it is the primary unknown the Phase 2 spike exists to measure** — see
[C-13](09-challenges-and-solutions.md#c-13).

Also note `onAudioAvailable(String utteranceId, byte[] audio)`, which delivers generated
audio directly and fires "as soon as the audio is generated" rather than when playback is
expected to begin. It is worth measuring as an alternative to the
`synthesizeToFile`-then-read path, since it could remove a file round-trip from the hot
loop.

Details that will bite:

- Callbacks do **not** run on the main thread. Marshal to the Dart isolate carefully.
- Range granularity is engine-dependent. Google's engine reports words; some third-party
  engines report only whole utterances. Probe at first use with a known sentence and
  record the real granularity in `EngineCapabilities`.
- If SSML is used, `start`/`end` index into the **SSML string**, not the plain text.
  Since we need plain-text offsets, we either avoid SSML on this engine or maintain a
  second alignment map. **Decision: avoid SSML here** — we get more precise control from
  DSP anyway.
- Engine availability varies wildly by OEM. Enumerate installed engines, let the user
  pick, and handle "no engine installed" with a link to install one.

**Rate and pitch.** `setSpeechRate` and `setPitch` are applied natively when they are
inside the range where quality holds. Beyond that we clamp and let DSP take the rest.

## 4.4 Adapter: Windows WinRT

`Windows.Media.SpeechSynthesis.SpeechSynthesizer`, reached through a small C++/WinRT FFI
plugin of our own.

**Why our own plugin.** `flutter_tts` nominally supports Windows but has a track record
of `MissingPluginException` on core methods there, and — decisively — it exposes
`speak()`-style playback rather than the stream plus markers we need. Writing ~400 lines
of C++/WinRT gives us exactly Contract B. See [ADR-013](10-decisions-adr.md#adr-013).

**Synthesis.** `SynthesizeTextToStreamAsync` (or `SynthesizeSsmlToStreamAsync`) returns
a `SpeechSynthesisStream` — a WAV stream we decode to PCM.

**Word timings.** Set `Options.IncludeWordBoundaryMetadata = true` and read the stream's
markers, which carry text offsets and time offsets. Convert time to frames using the
stream's sample rate.

**Rate, pitch, volume.** Available both through `SpeechSynthesizer.Options`
(`SpeakingRate`, `AudioPitch`, `AudioVolume`) and through SSML 1.1 `<prosody>`. Prefer
`Options` — same effect, and it keeps the input plain text so word-boundary offsets stay
in plain-text space.

**Voice inventory.** `SpeechSynthesizer.AllVoices`. Note that the modern "natural"
Windows voices installed through Settings are not always exposed to this API on all
builds; the mobile-quality legacy voices always are. Probe and report honestly rather
than promising voices we cannot reach.

## 4.5 Adapter: Piper via sherpa-onnx

The default *neural* tier: small, fast, runs acceptably on cheap hardware.

**Model shape.** One ONNX model per voice. Sizes run from roughly 20–28 MB for the
`x_low` tier, around 63 MB for `low` and `medium`, and up to ~130 MB for `high`. Each
voice is a separate download.

**Synthesis.** `sherpa_onnx` Dart FFI; `OfflineTts.generate(text, sid, speed)` returns
float samples plus the sample rate.

**Rate.** Native, via the `speed` / `length_scale` parameter. This is a genuine duration
change in the model, not resampling, so it stays natural over a wider range than DSP
time-stretching — prefer it up to about 1.6x.

**Pitch.** Not available. DSP.

**Word timings.** Not returned by the API. See §4.7.

**Licensing.** Two separate traps, covered in
[06 — Voice Catalog & Licensing](06-voice-catalog-and-licensing.md): the Piper *engine*
moved from MIT (archived `rhasspy/piper`) to GPL-3.0 (`OHF-Voice/piper1-gpl`), and
individual *voices* carry mixed licences including non-commercial ones. We consume Piper
**models** through sherpa-onnx (Apache-2.0) rather than linking the GPL engine, and we
ship only an audited allowlist of voices.

## 4.6 Adapter: Kokoro via sherpa-onnx

The premium tier. Kokoro-82M is a StyleTTS2-family model, Apache-2.0 licensed, with
50-plus voices across several languages in a single model, and quality that is close to
paid commercial TTS.

**Why it is not the default.** Memory. Measured on iPhone 15
([issue #2374](https://github.com/k2-fsa/sherpa-onnx/issues/2374)):

| | Package | Runtime footprint | Synthesis time |
|---|---|---|---|
| fp32 | 319 MB | 837 MB | 19.41 s |
| int8 | 103 MB | 786 MB | 39.13 s |

On a 3 GB Android device either variant is an out-of-memory risk, and Android 17's
explicit per-app memory limits make it worse. See
[C-16](09-challenges-and-solutions.md#c-16).

**Note the quantisation trap.** int8 is the obvious mobile choice and it is the wrong
one: it saves 216 MB of download but only 51 MB of runtime memory, while **doubling**
synthesis time. Ship fp32 by default and offer int8 as an explicit "smaller download,
slower speech" option. Re-measure on Android reference devices in Phase 3 — these
figures are iOS.

**Therefore:** Kokoro is offered only on devices that pass a gate (measured available
memory and `isLowRamDevice() == false`), is never pre-selected, and unloads aggressively
when playback stops.

**Rate.** Native `speed` parameter. **Pitch.** None — DSP.

**Voices.** One model, many speaker embeddings, so switching voice is free once loaded.
This is a real advantage over Piper's one-model-per-voice for users who want to compare
voices.

## 4.7 Deriving word timings for neural engines

This is the hardest engineering problem in the speech layer, and both word highlighting
and word-gap injection depend on it. Four strategies, in descending order of quality:

**1. Model duration output (preferred).** VITS-family models (Piper) and StyleTTS2
(Kokoro) both contain an explicit duration predictor: internally they know how many
frames each phoneme occupies. Kokoro's Python API exposes per-token timing fields
directly. sherpa-onnx does not surface this today, so this route requires either an
upstream contribution to expose durations from the C++ API, or running the ONNX graph
ourselves with the duration tensor as an extra output. Accuracy: essentially exact.

**2. Per-word synthesis and measure.** Synthesise each word alone and concatenate.
Timings become trivially exact, but prosody is destroyed — every word gets
sentence-final intonation — and it is far slower. Useful only as the implementation of
an extreme "maximum word separation" accessibility preset, where flat prosody is
acceptable and arguably desirable.

**3. Forced alignment.** Run a small CTC acoustic model over the synthesised audio
against the known text. Accurate and engine-agnostic, but it means shipping a second
model and paying a second inference cost per sentence. Reserve for a "precise
highlighting" opt-in.

**4. Proportional estimation (fallback).** Distribute the sentence duration across words
weighted by character count, with adjustments for punctuation and syllable estimates.
Cheap and always available. Good enough for gap injection at boundaries; visibly drifts
for highlighting, so the UI degrades to sentence-level highlighting when this is the
source.

**Shipping plan.** v1 ships (4) with sentence-level highlighting for neural voices and
word-level highlighting for system voices, plus (2) behind the accessibility preset.
v1.1 targets (1) via an upstream duration-output contribution, which upgrades neural
voices to word-level highlighting.

This is an honest, staged answer to a genuinely hard problem. Promising word-perfect
highlighting on neural voices in v1 would be a promise we could not keep.

## 4.8 Phonemisation

Neural TTS models do not consume letters; they consume phonemes. The standard
grapheme-to-phoneme front end for both Piper and Kokoro is **eSpeak-NG**, which is
**GPL-3.0**.

**Revised 2026-09-01.** An earlier version of this section said sherpa-onnx "removed the
eSpeak-NG and `piper-phonemize` dependencies to stay cleanly Apache-2.0", and built a
whole avoidance strategy on top of that. **The claim was false.** The removal is a
proposal for a future 2.0.0
([issue #3731](https://github.com/k2-fsa/sherpa-onnx/issues/3731), opened 2026-07-08);
the shipping 1.13.x line still bundles eSpeak-NG, and v1.13.5's release notes read "Fix
installing espeak-ng-data directory".

The point is moot in our favour. [ADR-014](10-decisions-adr.md#adr-014) adopted
**GPL-3.0** for the project, so eSpeak-NG's licence matches our own.

**Our position:**

- **Use eSpeak-NG.** It is the front end both Piper and Kokoro were trained against, so
  it produces the phoneme distribution those models expect. A lexicon-plus-rules
  substitute would have been more work and worse output.
- **Take sherpa-onnx 1.13.x as shipped.** No custom build, no excluded components.
- **Pin the version.** If 2.0.0 removes eSpeak-NG, the documented escape hatches are a
  supplied `lexicon.txt` or pre-tokenised phoneme strings passed through
  `GenerationConfig`. Review deliberately before crossing that boundary rather than
  taking the upgrade automatically.
- **Per-voice licences still need auditing** — that is a separate concern from the
  engine, and GPL-3.0 does not dissolve it. See
  [06 - Voice Catalog & Licensing](06-voice-catalog-and-licensing.md).

## 4.9 Engine selection and fallback

Order of preference when the user has expressed no choice:

1. The voice they last used for this book.
2. Their default voice for the book's language.
3. A downloaded neural voice matching the language, if the device passes the memory gate.
4. The system voice for that language.
5. Any system voice, with a warning that the language does not match.

Failure handling: a neural model that fails to load (corrupt download, OOM, missing ABI)
falls back to the system voice **and tells the user why**, rather than silently
switching voice mid-chapter, which is disorienting.
