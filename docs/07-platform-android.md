# 07 — Platform: Android

## 7.1 Targets and deadlines

| | |
|---|---|
| Minimum SDK | 26 (Android 8.0) |
| Target SDK | **36 (Android 16)** |
| ABIs | arm64-v8a (the main APK), armeabi-v7a (`TomeVoice-<version>-32bit.apk`); x86_64 only for CI's emulator |
| Distribution | APKs on GitHub Releases, signed with one key so each update installs over the last; the app offers new versions itself. No Play build for now ([18](18-play-store-audit.md)) |
| Application id | `app.tomevoice` since 0.6 (never to change again); the Kotlin package is still `app.tomevoice.tomevoice_spike` |

**The target-SDK deadline has already passed.** As of 31 August 2026, new apps and
updates on Google Play must target Android 16 (API 36); existing apps must target at
least API 35. An extension route to 1 November 2026 exists but does not apply to a new
app. There is no version of this project that ships targeting anything older, so API 36
is a starting constraint rather than a migration task — which is a small mercy.

**16 KB page alignment is mandatory.** Android 16 supports devices with a 16 KB memory
page size, and every native library we ship must be aligned to 16 KB boundaries. It is a
build-flag problem, not a code problem, but it fails at *runtime on real devices* rather
than at build time, so it needs an explicit automated check. See
[C-28](09-challenges-and-solutions.md#c-28).

*As built:* the native libraries come in through packages (Flutter's engine, sherpa-onnx
with ONNX Runtime, QuickJS, Tesseract with Leptonica, libjpeg and libpng); there is no
native code of TomeVoice's own. CI's "Check the APKs" step runs `tools/check_16kb.py` on
each APK: OCR's libraries must be aligned (a failure stops the run), and any other 64-bit
library that is not is warned about. 32-bit phones have 4 KB pages only.

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
  - *As built (v0.5.0):* on Android 13+ the card in the shade is drawn from the
    MediaSession, not from the notification's actions. Its controls are the
    PlaybackState's: play/pause, previous/next (by chapter), a seek bar through the
    chapter (`ACTION_SEEK_TO` plus `METADATA_KEY_DURATION`), and up to two custom actions
    (here, speed and Save). The picture is `METADATA_KEY_ALBUM_ART`, and the card takes its colours
    from it. The notification's small icon is drawn top left, so it must be the app's
    mark, not a state. The notification's own actions (with Stop) still serve Android 12
    and older.

**MediaSession.** A `MediaSession` gives us lock-screen controls, Bluetooth headset
buttons, Android Auto, Wear, and the system media output switcher. It also makes the
system treat us as a real media app for audio-focus arbitration. This is not optional
polish; without it, headset play/pause simply will not work.

Metadata should read like an audiobook: book title as album, chapter as track, author as
artist, cover as artwork, and duration/position from the scheduler's estimate so the
scrubber works.

**As built (1.4.0): the voice outlives the activity.** Reading is Dart's
(the scheduler, `BackgroundReading`), so the Flutter engine must outlive `MainActivity`:

- **One engine.** `ReadingCore.kt` keeps a single `FlutterEngine` in
  `FlutterEngineCache` (`"tomevoice"`). `MainActivity.provideFlutterEngine` returns it;
  `ReadAloudService` makes it when there is no activity and runs `backgroundMain()`
  (`lib/main.dart`) on it: the library is opened and the book read, nothing drawn. When
  an activity attaches to an engine already running Dart, `MainActivity` sends a
  `shown` event and Dart builds the app if it only read (`backgroundMain`) and applies
  edge to edge to the new window (each activity has its own `PlatformPlugin`); a
  widget's request is re-sent, and Back goes to Flutter until it next reports
  whether it can pop (`setFrameworkHandlesBack(true)`: it reported to the old
  activity).
- **Reading's calls are the engine's.** The voice (one warm `TextToSpeech`), the
  `PcmPlayer`, audio focus and the noisy receiver (on the application context), and the
  card live in `ReadingCore`, which answers `listEngines`, `synthesise`, `player*`,
  `requestFocus`, `session` and the new calls with or without an activity
  (`ReadingCore.handle`). `MainActivity` puts its own handler on the channel while
  attached (asking `ReadingCore` first) and answers pickers, the window and prompts;
  with no activity `ReadingCore.alone` answers what needs no screen (`outputDir`,
  `webUserAgent`, `refreshWidgets`...) and quietly turns down the rest.
- **The engine goes** when an activity that is finishing lets go with nothing being
  read (`shouldDestroyEngineWithHost`, decided in `cleanUpFlutterEngine`), or 3 s after
  a reading ends with no activity (`ReadingCore.idle`). The next opening starts afresh,
  as before.
- **One library.** `openLibrary()` (`home_shell.dart`) opens the store, prefs, sources,
  rules, marks, stats and natural voices once per folder: the shelves and a book read
  with no screen share one `LibraryStore` (two would write over each other's
  `library.json`).

| Path | What happens |
|---|---|
| App opened | A new engine runs `main()`; or the cached one is shown (`shown`: built if needed, edge to edge again) |
| Back at the root | `moveTaskToBack` (unchanged): the activity is kept, the voice reads on |
| Home | The activity stops, stays attached; the voice reads on |
| Swiped from Recents, playing | The process is kept (a foreground service); the activity finishes but keeps the engine; `onTaskRemoved` leaves the reading alone. A reader page left open keeps reading in the engine |
| Swiped from Recents, paused | `onTaskRemoved` sends `stop`: the place is saved, the service leaves the foreground 2 s later and stops, the engine goes 3 s after; the card becomes the resume card |
| Swiped, nothing read | The activity takes the engine with it (and Android kills a process with no foreground service on a swipe): a fresh start next time |
| Android closes the activity | The engine stays; the next activity shows the app as it was |
| Process killed | Everything goes; the place was saved every 1.5 s; Android 11+ keeps a resume card |
| Resume card's Play | System UI binds with `EXTRA_RECENT` and calls `prepare`/`play`; nothing reading: the service goes foreground at once with the book (buffering), `ReadingCore.play` starts the engine at `backgroundMain` if none, Dart takes the request (`MediaRequests`) and reads it from its place (`BackgroundReading.playFromOutside`) |
| Headset Play, app closed | The session's media button receiver (a `getForegroundService` PendingIntent to the service, kept by Android across reboots) starts the service with the key: Play, as above |
| Android Auto | Binds to the browser: "Continue" (the book read last) and "Recent", playable, with covers and progress; a book picked carries on if it is the one on the card, else Dart switches (a page reading another book stops) |
| Open with, Share | `OpenActivity` hands the file to MainActivity in TomeVoice's own task (1.3.0); with a book reading and no activity, that MainActivity rejoins the engine and imports it (`openFile`, or `pendingOpen` once the shelf is built) |
| A widget's play | With a reading on the card, to the service (play or pause); otherwise it opens the app and plays, as before |
| Restore, in-app update | The process ends (unchanged) |

**Media browser.** `ReadAloudService` is a framework `MediaBrowserService` (its session was
already a framework `MediaSession`), exported with the `MediaBrowserService` filter.
`onGetRoot`: System UI's `EXTRA_RECENT` request gets the `recent` root (one item, the
book Play would read: the resume card shows the first); Android Auto, Wear, the
Assistant and system apps get the full root; any other app an empty one. Items are
read from `library.json` in Kotlin (`Shelf`), as the widgets read it. **Books on a
secret shelf are never listed or played from outside the app**, open or not: only the
app knows whether the shelf is open (Dart refuses one too, if asked). A secret book
that was reading shows "TomeVoice" on the card; after the process dies its resume
card's Play reads the last ordinary book instead.

**Android Auto.** The manifest carries `com.google.android.gms.car.application`
(`res/xml/automotive_app_desc.xml`: `<uses name="media"/>`). A sideloaded build (the
GitHub APK) shows in Android Auto only with its developer settings' **Unknown sources**
on (tap the version in Android Auto's settings ten times, then the menu > Developer
settings).

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

*As built (1.4.0):* Settings > Listening > **Keep reading with the screen
off** says whether Android's battery optimisation leaves TomeVoice alone
(`PowerManager.isIgnoringBatteryOptimizations`) and opens Android's own question
(`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, which needs the
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission: a Play concern, [18](18-play-store-audit.md)), else the
list of apps, else the app's settings page. On Xiaomi (Redmi, POCO), Samsung, OPPO,
realme, OnePlus, vivo (iQOO), Huawei and Honor a line under it links to the maker's
page on dontkillmyapp.com (Honor's is the Huawei page; there is none for Nothing,
which behaves as Android does). It is a row, not the one-time card of point 2: no hint
pops up after a first listen with the screen off.

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

*As built (1.4.0):* Add books opens `ACTION_OPEN_DOCUMENT` for any type (`*/*`), several
files at once, with no MIME filter: Android often labels an `.epub` as a zip or
octet-stream, and a filtered picker hid them. Every book is **copied** into the library
folder (`books/<id>/source.<ext>`, [11](11-data-model-and-storage.md)); there is no
"link without copying" and no watched folder. Open with and Share to TomeVoice go through
`OpenActivity`, which hands the file (or the shared link or words) to the TomeVoice
already open. A folder is picked with `ACTION_OPEN_DOCUMENT_TREE` only for automatic
backups. No `MANAGE_EXTERNAL_STORAGE`.

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

*As built (1.4.0):* no AAB. Each release has one APK per CPU, built with only that CPU's
native code (`TV_ABIS` in CI; `abiFilters` alone was ignored, so `prepare_android.py`
excludes the rest at packaging) and with native libraries stored compressed
(`useLegacyPackaging`). The APK was about 27 MB at 1.0.0 and has carried OCR and an MP3
encoder since; CI prints each APK's size beside the latest release's. No voice is in the
APK.

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

*As built (1.4.0):* TalkBack reads the pages and turns them (1.3.0), with the page turns
and the bars as accessibility actions. Small type, icons and controls meet WCAG AA contrast
in every theme, the word being read included (`contrast.dart`). The player's chips and
scrubber take taps in a band around them, though the upright player's scrubber reaches
39 dp, not 48 ([12](12-roadmap-and-milestones.md)). Not built: ducking or pausing the book
during TalkBack's own announcements.

## 7.8 Play Store compliance checklist

No Play build is planned for now. [18 — Play Store Audit](18-play-store-audit.md) lists
what a Play build would have to leave out; this checklist is kept for that day.

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
