# 07 — Platform: Android

## 7.1 Targets and deadlines

| | |
|---|---|
| Minimum SDK | 26 (Android 8.0) |
| Target SDK | **36 (Android 16)** |
| ABIs | arm64-v8a (primary), armeabi-v7a, x86_64 |
| Distribution | Google Play (AAB), plus a direct APK for sideloaders |

**The target-SDK deadline has already passed.** As of 31 August 2026, new apps and
updates on Google Play must target Android 16 (API 36); existing apps must target at
least API 35. An extension route to 1 November 2026 exists but does not apply to a new
app. There is no version of this project that ships targeting anything older, so API 36
is a starting constraint rather than a migration task — which is a small mercy.

**16 KB page alignment is mandatory.** Android 16 supports devices with a 16 KB memory
page size, and every native library we ship must be aligned to 16 KB boundaries. We ship
several: ONNX Runtime, PDFium, miniaudio, our DSP core. Every one must be built with
16 KB alignment and verified in CI — this is a build-flag problem, not a code problem,
but it fails at *runtime on real devices* rather than at build time, so it needs an
explicit automated check. See [C-28](09-challenges-and-solutions.md#c-28).

**Memory limits are tightening.** Android 17 introduces explicit per-app memory limits.
Combined with Kokoro's several-hundred-megabyte runtime footprint, this makes device
gating for Tier 2 voices a correctness requirement, not an optimisation.

## 7.2 Background playback

This is where TTS reader apps most often fail, and users judge them entirely on it. An
app that stops reading when the screen locks is not a usable audiobook app.

**Foreground service.** Since Android 14, every foreground service must declare a type
and hold the matching permission. We use `mediaPlayback`, which is permitted to run
indefinitely provided a persistent notification is shown.

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name=".playback.TomeVoicePlaybackService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="false" />
```

Constraints to respect:

- The service must be started **from the foreground** (a user tapping play), then it may
  continue in the background. Background-initiated starts throw
  `ForegroundServiceStartNotAllowedException`.
- On Android 15+, a `BOOT_COMPLETED` receiver **may not** launch a `mediaPlayback`
  foreground service. "Resume reading on boot" is therefore not implementable and should
  not be designed.
- The notification must be genuinely useful — title, chapter, play/pause, ±30 s or
  ±sentence, and a close action.

**MediaSession.** A `MediaSession` gives us lock-screen controls, Bluetooth headset
buttons, Android Auto, Wear, and the system media output switcher. It also makes the
system treat us as a real media app for audio-focus arbitration. This is not optional
polish; without it, headset play/pause simply will not work.

Metadata should read like an audiobook: book title as album, chapter as track, author as
artist, cover as artwork, and duration/position from the scheduler's estimate so the
scrubber works.

**Wake locks.** A partial wake lock while synthesising, released when the buffer is
full. Neural synthesis is CPU-heavy and can be throttled or suspended by the system
mid-sentence otherwise. Do not hold it continuously — that is a battery complaint
waiting to happen.

## 7.3 Audio focus and routing

| Event | Behaviour |
|---|---|
| Transient focus loss (notification) | Duck to ~20% |
| Transient focus loss, no duck (call) | Pause; resume on focus return if the user had not manually paused |
| Permanent focus loss (other media app) | Pause, do not auto-resume |
| Headphones unplugged / Bluetooth disconnect (`ACTION_AUDIO_BECOMING_NOISY`) | Pause immediately |
| Bluetooth reconnect | Do not auto-resume |
| Output device change | Rebuild the audio device; keep the buffer |

**Bluetooth latency** deserves specific attention. A2DP adds 150–250 ms between the
buffer and the ear, and more on some codecs. Word highlighting will visibly lead the
audio. Detect the output route, apply a stored per-route offset, and expose the
calibration slider described in [§5.9](05-tts-controls-spec.md#59-highlighting).

## 7.4 OEM battery management

Stock Android behaves. Several large OEMs do not: aggressive background-process killers
on Xiaomi/MIUI, Samsung, Huawei, OPPO, vivo and OnePlus terminate foreground services
that stock Android would keep alive. This is the single most common source of
one-star "stops playing randomly" reviews for apps in this category, and it is not a bug
we can fix in code.

Mitigation, in order:

1. Do everything correctly — proper FGS type, MediaSession, notification — so we are as
   protected as the platform allows.
2. Detect the manufacturer and, on known-aggressive OEMs, show a **one-time**,
   dismissible card explaining how to exempt the app from battery optimisation, with a
   deep link to the right settings screen.
3. Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only when the user opts in from that
   card. Requesting it unprompted is a Play policy risk.
4. Persist playback position **continuously** (every sentence), so that if we are killed
   anyway, reopening resumes exactly where the audio stopped rather than where the last
   checkpoint was.

Point 4 is the real defence: we cannot always prevent being killed, but we can make
being killed nearly harmless.

## 7.5 File access

Android's Storage Access Framework is the only sanctioned route to user files.

- **Import** via `ACTION_OPEN_DOCUMENT`, taking a **persistable** URI permission so the
  book is still readable after a reboot.
- **Copy into app storage** on import, by default. SAF URIs can be revoked, the source
  file can move or be deleted, and re-parsing a 900-page PDF because the user tidied
  their Downloads folder is a bad experience. Offer "link without copying" for users
  managing large libraries, with a clear warning.
- **Folder watching** via `ACTION_OPEN_DOCUMENT_TREE` for users with an existing library
  folder.
- **Do not request** `MANAGE_EXTERNAL_STORAGE`. It requires a Play policy declaration
  and review for a use case SAF already covers; asking for it is a rejection risk with
  no benefit.
- **Share target.** Register for the relevant MIME types so "Open with TomeVoice" works
  from any file manager, email client or browser download.

## 7.6 Size and delivery

The base AAB must stay small. The large contributors are ONNX Runtime, PDFium, and the
Flutter engine itself.

- Per-ABI splits via the AAB, so a device downloads one architecture.
- No neural voice pre-bundled; everything downloads on demand.
- Consider Play Feature Delivery for the neural runtime itself, so users who never leave
  Tier 0 never download ONNX Runtime at all. This is a meaningful saving and worth
  measuring.
- Play's compressed download limit for an AAB is 200 MB before additional delivery
  mechanisms are needed; our budget of ~120 MB leaves headroom.

## 7.7 Accessibility

The product's audience includes screen-reader users, so this needs care beyond the
usual.

- Every control labelled for TalkBack, with meaningful state announcements.
- **The conflict:** TalkBack speaks the UI while we speak the book, through the same
  output. Two voices at once is unusable. Handle it explicitly — when TalkBack is active
  and playback starts, duck or pause our output during TalkBack announcements, and keep
  our own controls terse so the collision window is short.
- Full keyboard/D-pad navigation; the app must be operable on a TV or with a physical
  keyboard.
- Respect system font scale in the UI (not necessarily in the book view, which has its
  own size control).
- Minimum touch targets 48 dp; the play/pause target should be considerably larger.

## 7.8 Play Store compliance checklist

- Target API 36; native libraries 16 KB aligned.
- Foreground service type declared, with a Play Console justification for
  `mediaPlayback`.
- Data Safety: no data collected in the default configuration; declare the cloud-voice
  exception.
- Notification permission requested in context, not on first launch.
- No `MANAGE_EXTERNAL_STORAGE`, no `QUERY_ALL_PACKAGES`.
- AI-generated voice disclosure in the listing.
- Content rating: the app has no content of its own; users supply files.
- Attribution page listing every CC-BY voice and open-source component.
