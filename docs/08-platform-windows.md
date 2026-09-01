# 08 — Platform: Windows

## 8.1 Targets

| | |
|---|---|
| Minimum | Windows 10 1809 (build 17763) |
| Primary | Windows 11 |
| Architectures | x64, arm64 |
| Distribution | MSIX installer (signed), portable ZIP, and optionally the Microsoft Store |

Windows 10 1809 is the floor because it is where the WinRT speech and media-transport
APIs we rely on are dependable, and because Flutter's Windows embedder targets that
range.

## 8.2 Speech on Windows

Windows offers two speech stacks and they are not equivalent.

| | `System.Speech` (SAPI 5) | `Windows.Media.SpeechSynthesis` (WinRT) |
|---|---|---|
| Voices | Legacy desktop voices | Modern "mobile" voices, plus most SAPI voices |
| Word boundaries | Yes, via events | Yes, via stream markers |
| PCM to stream | Yes | Yes (`SynthesizeTextToStreamAsync`) |
| SSML | SSML 1.0 | SSML 1.1 |
| Availability | Desktop only | Desktop and packaged apps |

**We use WinRT.** Its `SpeechSynthesisStream` plus word-boundary metadata is the cleanest
match for Contract B, it exposes rate/pitch/volume through `SpeechSynthesizer.Options`
without forcing us into SSML, and it enumerates the broader voice set.

**We write our own plugin.** `flutter_tts` claims Windows support but has a documented
history of `MissingPluginException` on `speak`, `setSpeechRate` and
`awaitSpeakCompletion` there — and, more fundamentally, it is a *play the text* API when
we need a *give me the bytes and the markers* API. A focused C++/WinRT plugin of a few
hundred lines gives us exactly the contract and removes a dependency we would be
fighting. See [ADR-013](10-decisions-adr.md#adr-013).

```
windows/
  runner/
  tomevoice_speech/
    speech_plugin.cpp        // FFI surface: init, list_voices, synthesise, cancel
    synth_session.cpp        // SpeechSynthesizer + stream + marker collection
    wav_decode.cpp           // SpeechSynthesisStream -> float PCM
```

**Marker caveat.** Enable `Options.IncludeWordBoundaryMetadata` before synthesis;
markers carry text offsets and time offsets, which we convert to frame indices using the
stream's sample rate. If a given voice reports no markers, the adapter must fall back to
estimated timings and say so through `WordTimingSource` rather than silently producing
timings of `0`.

**Voice availability caveat.** The high-quality "natural" voices a user installs through
Windows Settings are not consistently exposed to this API across builds. Enumerate what
is actually reachable and present that; do not advertise voices we cannot drive. Where
a user has natural voices installed but unreachable, a short explanatory note in the
voice picker is better than an unexplained absence.

## 8.3 Media transport controls

`SystemMediaTransportControls` is the Windows counterpart to Android's MediaSession. It
provides:

- Keyboard media keys (play/pause/next/previous) on any keyboard that has them
- The Windows 11 media flyout above the volume OSD
- Metadata display: book title, chapter, author, cover art
- Position and duration for the scrubber

Without it, media keys do nothing and the app feels un-Windows-like. Wire it to the same
playback session the Android MediaSession uses, so the behaviour is identical on both
platforms.

## 8.4 Audio output

We use one audio backend (`miniaudio`) on both platforms specifically so that device
handling is one implementation, not two.

Windows-specific behaviours to handle:

| Event | Behaviour |
|---|---|
| Default output device changes | Rebuild the device, keep the ring buffer, resume seamlessly |
| Device disappears (USB DAC unplugged) | Fall back to the new default, do not crash |
| Exclusive-mode app takes the device | Pause and report, rather than silently failing |
| Sleep / resume | Rebuild the device on wake; the buffer survives |
| Bluetooth output | Same latency-offset handling as Android |

The "default device changed" case is the one that most often produces a silent failure:
audio keeps "playing" into a device that no longer exists. Subscribe to device
notifications and rebuild rather than trusting the initial device handle.

## 8.5 Packaging and distribution

**MSIX** is the primary format: clean install/uninstall, per-user by default, automatic
update support, and required for the Microsoft Store.

**Portable ZIP** as a secondary channel, because a meaningful part of this audience runs
apps from a USB stick or without admin rights. It must be genuinely portable — settings
and library in a local folder, not `%APPDATA%` — when launched in portable mode.

**Microsoft Store** listing is worth doing: it sidesteps SmartScreen entirely and gives
a trusted install path. It also constrains us to the packaged-app sandbox, which is
mostly fine; file access via the file picker with broad file-type declarations works.

### Code signing

Unsigned executables trigger SmartScreen warnings that will lose a large fraction of
first-time users. Signing is not optional for a serious desktop release.

| | |
|---|---|
| OV certificate | roughly $200–300/year |
| EV certificate | roughly $300–500/year |
| **EV no longer bypasses SmartScreen** | Microsoft removed the instant-reputation behaviour for EV in 2024; EV-signed binaries now build reputation the same way OV ones do |
| Validity cap | From 1 March 2026, publicly trusted code-signing certificates are capped at 458 days, so this is an annual renewal task |
| Key storage | Hardware token or cloud HSM is now required by CA/B rules — plan the CI signing flow around a cloud signing service, not a local `.pfx` |

**Recommendation: OV.** EV costs more and, since the 2024 change, buys nothing for a
user-mode application. Budget for reputation building — the first few weeks after a new
certificate will still show warnings until download volume accrues. A Microsoft Store
listing running in parallel gives users a warning-free path in the meantime.

## 8.6 File association and shell integration

- Register `.epub`, `.pdf` (never as the default — do not steal PDF from the user's
  chosen viewer without asking), `.docx`, `.txt`, `.md`, `.rtf`, `.html`.
- Offer association during first run as an explicit choice, defaulting to `.epub` only.
- "Open with" verb, drag-and-drop onto the window, and command-line file arguments.
- Jump list with recent books.

## 8.7 Windows-specific reading UX

The desktop is not a big phone, and the differences worth honouring:

- **Keyboard shortcuts throughout** — space to play/pause, arrows for sentence
  navigation, `[`/`]` for speed, `Ctrl+F` for search, `F11` full screen.
- **Window layouts** — a two-page spread for EPUB on wide windows, and a sidebar for
  TOC/bookmarks/notes that a phone cannot afford.
- **Mini player** — a small always-on-top window for listening while working, which is a
  distinctly desktop use case and one of the strongest reasons to have a Windows app at
  all.
- **Multi-window** — a second book in a second window.
- **Mouse-wheel and trackpad** scrolling that feels native, not mobile-ported.

## 8.8 Windows checklist

- WinRT speech plugin built for x64 and arm64.
- SMTC wired to the shared playback session.
- Audio device change and sleep/resume handled and tested.
- MSIX signed with an OV certificate from a cloud HSM in CI.
- Portable build verified with no registry or `%APPDATA%` writes.
- High-DPI and multi-monitor DPI changes handled.
- Per-monitor scaling verified at 100/125/150/200%.
- Light/dark theme following the system setting.
