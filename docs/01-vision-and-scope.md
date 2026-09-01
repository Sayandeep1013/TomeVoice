# 01 — Vision & Scope

## 1.1 The product in one sentence

TomeVoice turns any document you own into a book you can listen to, on your phone and
on your PC, with more control over the voice than any mainstream reader gives you.

## 1.2 Why it should exist

The reading-with-TTS space splits into three groups, and each leaves a gap:

- **Ebook readers with bolted-on TTS** (Moon+ Reader, Lithium, Apple Books). Good
  readers, but TTS is an afterthought: system voice only, two sliders, no word gap, no
  pronunciation control, and PDF support is usually a separate viewer with no speech at
  all.
- **Dedicated TTS readers** (@Voice Aloud Reader, Speechify, NaturalReader). Strong on
  speech, weak on reading: the book view is secondary, the good voices are a
  subscription, and the desktop story is a browser extension.
- **Accessibility tooling** (screen readers, Read Aloud). Powerful but general-purpose;
  they read *screens*, not *books*, so they have no concept of chapters, bookmarks, or
  resuming where you left off.

Nobody in that list offers *fine-grained prosody control* (per-word spacing, punctuation
pause shaping, pitch in semitones) combined with *good free offline neural voices*
combined with *a real Windows desktop app*. That is the gap.

## 1.3 Who it is for

| Persona | Need | What they care most about |
|---|---|---|
| **The commuter** | Wants a novel read aloud on the drive, resumed on the PC at home | Background playback that never dies, Bluetooth controls, sync |
| **The student / researcher** | Wants a 400-page PDF paper read while taking notes | PDF reading order, skipping citations and figure captions, speed 1.75x |
| **The dyslexic reader** | Reads better with wide word spacing and slow, evenly-paced speech | Word gap, sentence pause, word highlighting locked to audio |
| **The blind / low-vision reader** | Needs the whole app operable without sight | Screen-reader compatibility that does not fight our own TTS |
| **The language learner** | Wants slow, clearly separated words in a second language | Word gap, per-language voice, repeat-sentence |
| **The voice tinkerer** | Wants to try open neural voices without a subscription | Voice catalogue, download management, A/B preview |

The dyslexic reader and the language learner are the two personas that justify the word
spacing requirement. They are not a niche feature request; they are the reason the
hardest part of the architecture exists.

## 1.4 Scope

### In scope for v1.0

**Formats (read + speak)**
- EPUB 2 and EPUB 3 (DRM-free)
- PDF (born-digital; text layer present)
- DOCX
- TXT, Markdown, RTF, HTML

**Reading**
- Reflowable EPUB view with font, size, spacing, margin, theme control
- PDF page view with a text-selection layer
- Table of contents, bookmarks, highlights, notes
- Resume position per book, per device

**Speech**
- System voices (Android TTS engines, Windows SAPI/WinRT) — zero download, instant
- Downloadable neural voices (Piper, Kokoro) — offline, free, permissively licensed
- Full control surface: see [05 — TTS Controls Spec](05-tts-controls-spec.md)
- Word-synchronised highlighting on every engine
- Background playback with lock-screen / media-key controls
- Sleep timer, auto-advance across chapters

**Platforms**
- Android 8.0+ (API 26+), targeting API 36
- Windows 10 1809+ / Windows 11, x64 and arm64

### In scope for v1.x (post-launch, planned)

- OCR for scanned PDFs
- MOBI / AZW3 (DRM-free only)
- Export a chapter or book to an audio file
- Cross-device sync of position, bookmarks and settings
- Per-book pronunciation dictionaries shareable as files
- Voice cloning from a user-supplied sample, if a permissively licensed model exists

### Explicitly out of scope — permanently

| Not doing | Why |
|---|---|
| **Opening DRM-protected books** (Kindle AZW/KFX, Adobe ADEPT) | Circumventing DRM is illegal in most jurisdictions and would get us removed from both stores. Non-negotiable. |
| **Readium LCP support** | The specification is open but conformance requires per-application certification and an annual fee from EDRLab. Revisit only if there is revenue to justify it. |
| **Bundling `edge-tts` or any unsanctioned cloud endpoint** | It is an undocumented Microsoft endpoint, protected by anti-abuse tokens, and using it commercially violates Microsoft's terms. It would also break without warning. |
| **A built-in bookstore or content library** | We are a reader, not a shop. Users bring their own files. |
| **Mandatory account / cloud upload of books** | Local-first is a product promise. Books never leave the device unless the user explicitly enables sync. |
| **Being a general screen reader** | We read documents, not UI. That is the OS's job and we must not fight it. |

## 1.5 Product principles

1. **Local-first.** The app is fully functional with the network off, forever, with no
   account. Anything cloud is opt-in and additive.
2. **Own the audio.** Every speech feature we promise must work identically on every
   engine. If an engine cannot do it, we do it ourselves in DSP rather than greying out
   the control. (This is the expensive principle. It is also the differentiator.)
3. **Never ship a licence we cannot defend.** Every model, voice and native library gets
   an entry in the licence audit before it enters a build.
4. **Degrade loudly, not silently.** If a voice cannot do pitch, the UI says so and
   offers the DSP fallback — it does not pretend the slider worked.
5. **The reader and the speaker are the same object.** Highlighting, scrubbing and
   "where was I" all derive from one document model, not two parallel ones.

## 1.6 What success looks like

| Measure | v1.0 target |
|---|---|
| Time to first audio, system voice | < 300 ms from tap |
| Time to first audio, neural voice (warm) | < 1.2 s |
| Word highlight drift over a 10-minute chapter | < 120 ms |
| EPUB open time, 5 MB book, mid-range Android | < 2 s to first page |
| PDF reading-order accuracy, single-column born-digital | > 99% of paragraphs in correct order |
| PDF reading-order accuracy, two-column academic | > 90% |
| Background playback survival, 8-hour session, stock Android | 100% |
| Neural voice RAM ceiling, default tier | < 350 MB peak |
| App download size, before any voice download | < 120 MB (Android AAB) |
