# 05 — TTS Controls Spec

The complete control surface. For each control: range, default, where it is applied, and
what happens on engines that cannot do it natively.

Legend for **Applied at**:
`E` = engine-native · `D` = our DSP pipeline · `T` = text layer (before synthesis) ·
`S` = scheduler (between sentences)

---

## 5.1 Speed

| | |
|---|---|
| Range | 0.25x – 4.0x, continuous |
| Default | 1.0x |
| Applied at | `E` inside the engine's good range, `D` outside it |
| Presets | 0.75, 1.0, 1.25, 1.5, 2.0, 3.0 |

Speed is deliberately hybrid, because the two mechanisms fail in opposite directions.

**Engine-native rate** is a real duration change — a VITS/StyleTTS2 duration predictor
producing genuinely faster speech, or a concatenative engine selecting different units.
It sounds natural but degrades outside a band: system engines get robotic past ~2x, and
neural models drift out of their training distribution.

**DSP time-stretching** (WSOLA, pitch-preserving) works at any factor but introduces
transient smearing on plosives, most audible in the 0.5x–0.7x range and above ~2.5x.

Policy: apply natively within `capabilities.rateRange` and hand the remainder to DSP.
At 3.0x with an engine good to 2.0x, the engine does 2.0x and DSP does the residual
1.5x. A "prefer natural / prefer smooth" toggle in advanced settings lets the user shift
the crossover if they disagree with our judgement on their device's voices.

**Per-book speed memory.** Speed is stored per book, not globally — people read fiction
at 1.0x and skim reports at 2.5x. A global default seeds new books.

---

## 5.2 Pitch

| | |
|---|---|
| Range | −12 to +12 semitones |
| Default | 0 |
| Applied at | `E` on system engines, `D` on all neural engines |

Exposed in **semitones**, not the meaningless 0.5–2.0 multiplier that platform APIs use.
Semitones are perceptually linear and let the setting transfer between voices and
engines, which a multiplier does not.

Neural models expose no pitch parameter at all, so pitch there is a **formant-preserving
pitch shift** in DSP. Naive resampling would work but makes voices sound like chipmunks
or giants; preserving formants keeps the timbre and just moves the pitch, which is what
users actually want. Shift beyond about ±6 semitones is audible as processing on any
algorithm — the UI marks that region.

**Licence note, resolved 2026-09-01.** This used to be an open audit item: Rubber Band,
the obvious library, is GPL/commercial dual-licensed and would have needed a paid licence
or a hand-written replacement. [ADR-014](10-decisions-adr.md#adr-014) adopted GPL-3.0, so
GPL stretchers are now available to us. Choosing and tuning one is ordinary engineering
work in Phase 3 — see [C-14](09-challenges-and-solutions.md#c-14).

---

## 5.3 Word separation (word gap)

**The headline feature, and the one nothing else does properly.**

| | |
|---|---|
| Range | 0 – 500 ms, 5 ms steps |
| Default | 0 ms |
| Applied at | `D` — always, on every engine |

No mainstream TTS API exposes inter-word spacing. Android's `TextToSpeech` has no such
setting; neither does Windows `SpeechSynthesizer`; neither do Piper or Kokoro. It exists
in eSpeak's command line (`-g`) and essentially nowhere else.

We implement it by **owning the PCM**. Given `wordTimings` from Contract B, insert *N*
milliseconds of silence at every word boundary inside the sentence buffer.

```
raw:      [The][quick][brown][fox]
          |---|-----|------|-----|

+120ms:   [The]...[quick]...[brown]...[fox]
          |---|===|-----|===|------|===|-----|
```

Implementation requirements:

1. **Insert after time-stretching**, never before, or the gaps get scaled by the speed
   setting and a 120 ms gap becomes 60 ms at 2x.
2. **Cross-fade the boundaries** (3–5 ms) rather than splicing silence in hard, or every
   gap gets a click.
3. **Do not insert inside a word.** With `estimated` timings the boundary can land
   mid-phoneme; snap to the nearest zero-crossing in a low-energy region within a small
   search window.
4. **Remap the timings** so highlighting still lands on the right word afterwards.

Why the alternatives were rejected:

- *SSML `<break time="120ms"/>` between every word* — only works where SSML is honoured
  (not on Piper or Kokoro at all), makes each word its own prosodic unit so the sentence
  loses all intonation, and on Android breaks the `onRangeStart` offsets by changing the
  string being indexed.
- *Synthesise each word separately* — exact, but destroys prosody and is many times
  slower. Kept only as the implementation of the extreme accessibility preset (§5.11).

**Presets.** `Off (0)`, `Subtle (60 ms)`, `Clear (120 ms)`, `Learning (250 ms)`,
`Maximum (400 ms)`.

---

## 5.4 Pause shaping

Separate, independently adjustable pauses. Applied at `D` (within a sentence) and `S`
(between units).

| Control | Range | Default | Notes |
|---|---|---|---|
| Comma pause | 0 – 800 ms | 150 ms | also `;` `:` and dashes, each with a multiplier |
| Clause pause | 0 – 800 ms | 100 ms | parentheses, em-dash asides |
| Sentence pause | 0 – 2000 ms | 350 ms | after `.` `!` `?` |
| Paragraph pause | 0 – 3000 ms | 700 ms | between blocks |
| Heading pause | 0 – 4000 ms | 1000 ms | before and after headings |
| Section/chapter pause | 0 – 5000 ms | 1500 ms | plus optional chime |
| Quote pause | 0 – 500 ms | 0 ms | entering/leaving quoted speech |

**One engine can do some of this natively.** Windows `SpeechSynthesizerOptions` exposes
`PunctuationSilence` and `AppendedSilence` (Windows 10 1803+), which set punctuation and
trailing silence inside the synthesiser. We still apply pauses in our own pipeline so
behaviour is identical across engines, but these are worth benchmarking against the DSP
path on Windows — native insertion may sound more natural than spliced silence.

Pauses are specified in absolute milliseconds and are **not** scaled by the speed
setting by default, because at 2.5x an auto-scaled sentence pause vanishes and the text
becomes an undifferentiated stream. A "scale pauses with speed" toggle exists for users
who prefer the opposite.

Sentence and paragraph pauses are inserted by the **scheduler** as silent frames between
buffers, not baked into either sentence, so changing them takes effect immediately
without re-synthesis.

---

## 5.5 Volume, gain and loudness

| Control | Range | Default | Applied at |
|---|---|---|---|
| Master volume | 0 – 100% | 100% | `D` (plus OS volume) |
| Per-voice gain trim | −12 to +12 dB | 0 dB | `D` |
| Loudness normalisation | on/off, target −16 LUFS | on | `D` |
| Dynamic range compression | off / light / strong | light | `D` |

Loudness normalisation is not a luxury. Open TTS models are trained on different corpora
and differ by more than 10 dB in output level; without normalisation, switching from a
quiet Piper voice to a loud Kokoro voice at night is a genuinely unpleasant experience.
We measure integrated loudness per sentence with a short look-back window and apply
smoothed gain, with a limiter to catch peaks.

Compression helps enormously for listening in a car or on a noisy train, which is a
primary use case.

---

## 5.6 Pronunciation control

**Pronunciation dictionary.** Three scopes, each overriding the one below: per-book,
per-language, global.

| Field | Meaning |
|---|---|
| Match | literal string, whole word, or regex |
| Case sensitive | bool |
| Replacement | plain text substitution, or |
| Phonemes | IPA / engine phoneme string, where the engine supports it |
| Scope | book / language / global |

Plain-text replacement works on every engine and is what most users need
("Hermione" -> "Her-my-oh-nee", "SQL" -> "sequel", "GIF" -> whichever side of that
argument you are on). Phoneme override is more precise but engine-dependent, so the UI
offers it as an advanced field with a live preview button.

**Fast capture.** Long-press a word in the reader -> "Fix pronunciation" -> type the
respelling -> preview -> save. Adding an entry mid-chapter flushes the lookahead buffer
from the next sentence so the fix is heard immediately.

**Import/export** as a plain file, so a book club or a class can share a dictionary for
a specific book.

**Acronym handling.** A global policy (spell out / say as word / auto by heuristic) plus
per-entry overrides. The heuristic: all-caps tokens without vowels are spelled out;
pronounceable ones (NASA, NATO) are said as words; anything ambiguous defers to the
dictionary.

---

## 5.7 Skip rules — what gets read at all

Each row is an independent toggle, driven by `BlockRole` from the Document Model rather
than by pattern matching at speech time.

| Element | Default | Notes |
|---|---|---|
| Headings | read | with a distinct pause; optional pitch/rate offset |
| Page numbers | skip | PDF/EPUB `pagebreak` |
| Running headers & footers | skip | detected in PDF layout analysis |
| Footnotes & endnotes | skip | alternatives: read inline, or read at end of paragraph |
| Footnote reference markers | skip | the superscript numbers in the body text |
| Figure captions | read | |
| Image alt text | skip | |
| Tables | read | with optional cell coordinates |
| Code blocks | skip | |
| Math / MathML | skip | v1; spoken maths is a v2 project of its own |
| URLs | domain only | full / domain / skip |
| Citations `[12]`, `(Smith 2019)` | skip | |
| Front matter (copyright, ToC) | skip | |
| Bracketed content | read | |

Because these are role filters over the model, the reader can *visually* dim skipped
content while reading aloud, which makes the setting self-explanatory instead of
mysterious.

---

## 5.8 Playback and navigation controls

| Control | Behaviour |
|---|---|
| Play / pause | Pause completes the current word, not the current sentence — abrupt mid-word cuts feel broken |
| Rewind on resume | 0 / 1 / 2 / 5 seconds, or "back one sentence". Default: 1 sentence. Essential after a pause, because listeners lose the thread |
| Previous / next sentence | |
| Previous / next paragraph | |
| Previous / next chapter | |
| Seek bar | Scoped to the chapter, showing estimated time from measured RTF and current speed |
| Repeat sentence | Single tap replays the last sentence without moving the cursor |
| A-B repeat | Loop a range — for language learners |
| Continuous / stop at chapter end | |
| Sleep timer | 5/10/15/30/45/60 min, "end of chapter", "end of current sentence"; 30-second fade-out |
| Shake to extend | Optional; extends the sleep timer by 5 minutes without unlocking |

---

## 5.9 Highlighting

| Setting | Options | Default |
|---|---|---|
| Granularity | word / sentence / paragraph / off | word where available, else sentence |
| Word style | background / underline / bold / colour | background |
| Sentence style | background tint / none | tint |
| Auto-scroll | keep the spoken line centred / near the bottom / off | centred |
| Timing offset | −500 to +500 ms | 0 |

The **timing offset** exists because different engines have different latency between
"the buffer says word N starts here" and "the user hears it", and headphone latency —
especially Bluetooth, where 150–250 ms is normal — adds to it. Users notice drift long
before they can articulate its cause, so a single calibration slider with a live
preview sentence is worth far more than any amount of internal correction.

Granularity degrades automatically: if `WordTimingSource` is `estimated`, word-level
highlighting is disabled in favour of sentence-level, with a note explaining that
precise highlighting needs a different voice. Better an honest coarse highlight than a
confident wrong one.

---

## 5.10 Multi-voice and language

| Setting | Purpose |
|---|---|
| Voice per language | Auto-select the right voice when a book switches language |
| Auto language switching | on/off; requires agreement across consecutive blocks before switching |
| Heading voice | Optionally read headings with a pitch/rate offset, or a different voice |
| Quote voice | Optionally read quoted dialogue with a pitch offset — a light "narrated" feel |
| Fallback voice | Used when no voice matches the detected language |

Per-character voices for dialogue are explicitly a v2 idea; doing it well needs speaker
attribution, which is a research problem, not a settings toggle.

---

## 5.11 Presets

Presets set many controls at once and are the primary way most users will ever touch
this surface. The full control panel exists for the people who want it; nobody should
have to use it.

| Preset | Speed | Pitch | Word gap | Sentence pause | Other |
|---|---|---|---|---|---|
| **Natural** | 1.0x | 0 | 0 ms | 350 ms | default |
| **Audiobook** | 1.0x | 0 | 0 ms | 500 ms | paragraph 900 ms, light compression |
| **Study** | 0.9x | 0 | 60 ms | 600 ms | footnotes read at end of paragraph |
| **Skim** | 2.0x | 0 | 0 ms | 200 ms | skip captions and tables |
| **Dyslexia-friendly** | 0.85x | 0 | 150 ms | 700 ms | word highlighting on, auto-scroll centred |
| **Language learning** | 0.7x | 0 | 250 ms | 900 ms | A-B repeat available, per-word synthesis for maximum clarity |
| **Night** | 0.95x | 0 | 0 ms | 400 ms | strong compression, −6 dB, sleep timer 30 min |

Presets are editable and users can save their own.

---

## 5.12 Settings persistence and scope

| Scope | What lives here |
|---|---|
| Global | default voice per language, presets, pronunciation dictionary (global), highlight style, timing offset |
| Per book | speed, voice, skip rules, per-book pronunciation entries, reading position, sleep-timer preference |
| Per device | audio output preferences, downloaded voices, memory tier |

Per-book overrides are the important nuance: a user who reads novels at 1.0x and papers
at 2.0x should never have to change the setting twice, and per-device scoping means a
phone and a PC can have different downloaded voices without fighting each other during
sync.
