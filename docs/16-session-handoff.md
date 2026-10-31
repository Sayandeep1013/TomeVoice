# 16 — Start Here

Everything needed to pick TomeVoice up cold: where it stands, how to check, build and
release it, how to check it on a phone, and the findings that cost days. As of 1.4.0
(31 October 2026). The session-by-session checkpoints this page used to hold are in its
git history (`git show v1.4.0:docs/16-session-handoff.md`); what each release changed is
in the [changelog](../CHANGELOG.md).

## Where things stand

- **1.4.0** is the latest release (31 October 2026). `main` is the last release; work
  happens on `next`, which carries the fixes listed under "Unreleased" in the changelog,
  and goes to `main` by pull request.
- **Android only.** Windows is not started ([08](08-platform-windows.md)); there is no Play
  build ([18](18-play-store-audit.md)).
- **What is next**, what was turned down and the known limits: [12](12-roadmap-and-milestones.md).
- **How it is built:** [02](02-architecture.md); where the files are on the phone:
  [11](11-data-model-and-storage.md); why it is built so: [10](10-decisions-adr.md).

## Checking code locally

There is **no local Flutter or Gradle** by design ([ADR-016](10-decisions-adr.md#adr-016)).
The two packages and the tools need only the Dart SDK:

```bash
cd packages/tomevoice_audio    && dart pub get && dart analyze --fatal-infos && dart test
cd packages/tomevoice_document && dart pub get && dart analyze --fatal-infos && dart test

cd tools && dart pub get
dart run bin/make_fixture.dart /tmp/fx 120 1.0
dart run bin/measure.dart /tmp/fx
```

What the parser makes of a book, without Flutter:

```bash
cd packages/tomevoice_document
dart run tool/dump_book.dart "path/to/book.epub"     # metadata, sections, first sentences, blocks by role
dart run tool/inspect_file.dart "path/to/book.epub"  # title, kind, counts, first sentence
```

The test corpus's goldens are rewritten on purpose with
`TOMEVOICE_UPDATE_GOLDENS=1 dart test test/corpus_test.dart`
([13 §13.2](13-testing-and-qa.md#132-document-pipeline-tests)).

**App code** is checked before a push with a scratch Flutter SDK, then deleted to keep the
PC light:

1. Unzip the Flutter that CI pins (3.47.8, in `build.yml`'s `env`) to a short path such as
   `D:/tvchk/flutter`: under the temp folder the SDK's own files pass Windows' path limit.
2. Copy `app/` and `packages/` beside each other and run the same `flutter create` as CI
   (`--platforms=android --project-name tomevoice_spike --org app.tomevoice`).
3. QuickJS cannot be built on Windows without MSVC: swap `lib/sources/qjs_runtime.dart`
   for a stub, drop `flutter_qjs` from the copy's `pubspec.yaml`, and `flutter pub get`.
   CI (Linux) builds and tests the real engine; the engine test in
   `test/sources_test.dart` skips itself where the engine is missing.
4. `dart analyze --fatal-infos` (Flutter's own `analyze` trips over long Windows paths; CI
   runs `flutter analyze`, which fails on deprecations too) and `flutter test`.
   `backup_test`'s "paths are pointed..." fails on Windows only (backslashes in JSON).

The Kotlin in `app/android_overlay` is never compiled locally: CI is its first compiler.

**The LNReader libraries bundle** (`app/assets/js/lnreader_libs.js`, and
`lnreader_extra.js` for the plugins that need protobufjs or AES) is committed. To rebuild
it after changing versions: `cd tools/lnreader_libs && npm install && npm run build`
(and `npm run build:extra`). Node only; CI does not need it. Smoke-test it in QuickJS
before committing.

**The voice catalogue** (`app/assets/voices/catalog.json`) is made by
`python tools/voice_catalog.py`; `--check` says what would change. Read each new voice's
licence before committing ([06 §6.4](06-voice-catalog-and-licensing.md#64-the-per-voice-trap)).

## Building

**APKs come from CI, never locally** (`.github/workflows/build.yml`). Pushes to `main` and
pull requests build; changes to docs and Markdown alone do not. Pull requests and manual
runs also run the emulator job ([13 §13.11](13-testing-and-qa.md#1311-device-flows-and-the-emulator-job)).
For a branch, by hand:

```bash
gh workflow run build.yml --ref <branch>
gh run download <run-id> -n tomevoice-apk          # tomevoice-apk-32bit for 32-bit phones
adb install -r app-release.apk
```

- **The test app**, beside the real one with a library of its own:
  `-f variant=test`, artifact `tomevoice-test-apk` ([13 §13.12](13-testing-and-qa.md#1312-reproducible-builds)).
- **After changing a `pubspec.yaml`** or the pinned SDKs: `-f relock=true`, then
  `gh run download <run-id> -n pubspec-locks` from the repository root, and commit the
  lockfiles. Until then the build stops at "Resolve dependencies (locked)".
- **Signing.** With the secrets `TV_KEYSTORE_B64` and `TV_KEYSTORE_PASSWORD`, every APK is
  signed with the TomeVoice key and `adb install -r` upgrades in place, keeping the
  library. `TV_CERT_SHA256` in `build.yml` is that key's certificate; a release run
  refuses an APK signed with anything else. Without the secrets CI signs with a throwaway
  key, and installing that APK needs an uninstall first, which **wipes the library**. The
  keystore lives outside the repository, on the developer's laptop; keep it and its
  password safe offline too, or no update can ever install over the last.
- **The overlay check.** CI generates the Android scaffolding on every build and copies
  `app/android_overlay` over it ([its README](../app/android_overlay/README.md)), then
  greps the result for what must not be lost (the activities, the services, permissions
  such as `USE_BIOMETRIC`, the TTS and text-processing queries). A new load-bearing
  manifest entry gets a grep there too.

## Releasing

1. On `next`: bump `version:` in `app/pubspec.yaml` (`X.Y.Z+N`, the build number one
   up), move "Unreleased" in `CHANGELOG.md` under the new version in the voice of the
   releases before it, and update `README.md` and [12](12-roadmap-and-milestones.md) if
   what the app does changed.
2. Merge `next` into `main` by pull request. Read its emulator job's results: a failure
   there fails the job but blocks no APK.
3. Make a draft GitHub release for the tag `vX.Y.Z`, its notes the changelog's section.
4. `gh workflow run build.yml --ref main -f release_tag=vX.Y.Z`. CI builds both APKs,
   checks each one's app id, signing certificate and 16 KB alignment, attaches
   `TomeVoice-X.Y.Z.apk` and `TomeVoice-X.Y.Z-32bit.apk`, and publishes the release as
   Latest. Installed apps find it within a few hours (About → Check for updates at once).

Never name a branch exactly like a tag (`v1.0.1`): deleting it became ambiguous with the
tag behind a published release. Use `rel-1.0.2`, `feat-…`, `fix-…`.

## Checking on a phone

The developer's phone is a Nothing A059 (Android 16), on adb. It holds the developer's own
library: do not reorganise it, never re-add a book they removed, and do risky checks (a
restore, secret shelves, imports, Maestro flows) on the test app, removed afterwards. There
is no Android 14 or 15 phone: those are checked on CI's emulators.

- **Drive it by what is on screen.** Find each tap by its label in a `uiautomator dump`,
  re-read the screen before every tap, and stop when a target is missing instead of tapping
  where it used to be: the phone may be in use or turned meanwhile. Match labels exactly
  (`^Play (`, not `Play`, which also finds "Open Now Playing"). No swipes from the screen's
  edges, which open Home or the shade.
- **A step is done when evidence shows it**: a screenshot looked at
  (`adb exec-out screencap -p > shot.png`), or state read back (the version, a file). A
  script that printed "tapped" proves nothing. Say "unconfirmed" when it is.
- **Portrait.** Test in portrait unless the change is about landscape, and take README
  screenshots in portrait. Lock the rotation with `adb shell cmd window user-rotation lock 0`
  (and `free` after); `settings put system user_rotation` does nothing on this phone.
- **Launch with `am start`**, never `monkey`, which turns auto-rotate back on:
  `adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n app.tomevoice/app.tomevoice.tomevoice_spike.MainActivity`
  (the activity keeps the template's package, whatever the app id).
- **Sound cannot be recorded** from the phone on the developer's PC (scrcpy writes empty
  files). Check audio changes by their code path and by a person listening, and say plainly
  when something was not checked by ear. Screen video works:
  `adb shell screenrecord --time-limit 4 --size 540x1196 /sdcard/x.mp4` (full resolution
  fails). Frame pacing: `dumpsys SurfaceFlinger --latency` on the app's layer, polled, as it
  keeps only about 127 frames.
- **A fingerprint or PIN prompt screenshots black** (a secure window): use the
  `uiautomator dump`'s text and logcat (`onAuthenticated(true)`) as evidence.
- **Google's TTS:** `adb logcat | grep -E "Synthesis request|TTS dispatch"` names the model
  each sentence is read with. The `flutter` tag says when a natural voice ran dry and how
  long its last sentence took.
- **Fast drags:** adb's synthetic drags that move too fast do not move the fast-scroll
  thumb; paced ones (about 80 ms apart) do.
- **Sync** is checked against a WebDAV or KOReader server on the PC, reached from the phone
  through `adb reverse`: no outside accounts.
- **Android Auto** lists a sideloaded APK only with Android Auto's developer setting
  **Unknown sources** on (tap the version in its settings ten times, then the menu >
  Developer settings).
- **Git Bash on Windows** turns `/sdcard/...` into a Windows path unless
  `MSYS_NO_PATHCONV=1` is set.

## Findings that cost days

Each of these is in the code for a reason; do not undo them without reading why.

1. **`onRangeStart`'s parameters are not in the documented order** on Google's TTS:
   `(frame, charStart, charEnd)`. The layout is detected (`SpeechService.decodeTimings`);
   do not "simplify" it away ([04 §4.3](04-tts-engine-contract.md#43-adapter-android-system-tts)).
2. **Google's TTS hides its sentence pause inside a word's range.** Not every silence in the
   audio is one TomeVoice made.
3. **Stage order is load-bearing:** edge trim first, word gap after the stretch.
   `ordering_test.dart` encodes both bugs ([02 §2.6](02-architecture.md#26-the-audio-pipeline)).
4. **A green test suite proved nothing about listening.** Listen before claiming success
   ([13 §13.13](13-testing-and-qa.md#1313-the-audio-spike)).
5. **One warm `TextToSpeech`, one sentence at a time.** Re-creating it per sentence was
   unusable; two overlapping `synthesizeToFile` calls steal its single progress listener and
   playback dies after one sentence.
6. **One streaming `AudioTrack`**, fed PCM, its playback head the clock for the highlight.
   Never go back to a file and a `MediaPlayer` per sentence (600 to 750 ms of dead air
   between sentences, and no pause).
7. **The voice belongs to the cached Flutter engine** (`ReadingCore.kt`), not to
   `MainActivity`: a change to the voice, the player, audio focus or the media session goes
   in `ReadingCore.kt` ([07 §7.2](07-platform-android.md#72-background-playback)).
8. **Do not rebuild the reader on every word.** The word is a `ValueListenable<WordMark>`,
   and each paragraph listens for the sentence itself.
9. **A debug APK is not a performance test** (unoptimised JIT with asserts). CI builds
   `--release`; judge speed only there.
10. **Closures sent to `Isolate.run`** must be made in a top-level function: one made in a
    method can capture widget state, which cannot be sent. Hand an isolate paths, not
    objects that hold notifiers.
11. **Natural voices: full precision only.** The fp16 models abort ONNX Runtime on phones.
    Keep `sherpa_onnx` pinned at 1.13.8 ([recheck triggers](10-decisions-adr.md#recheck-triggers)).
12. **The file picker takes `*/*` with no MIME extra:** Android labels `.epub` as zip or
    octet-stream, and a filtered picker hid them.
13. **An EPUB's spine is not its chapter list.** Covers, contents pages, copyright pages and
    part dividers are passed over (`navigate.dart`), and chapters follow the book's contents.
14. **PdfBox's paragraph marks are not paragraphs:** a simple PDF came out a paragraph per
    line. `formats/pdf.dart` reflows.
15. **Cloudflare can refuse the app's own requests and let the web view in.** Requests use
    the web view's User-Agent; a challenged page is loaded in a hidden web view
    (`BrowserCheck.kt`). Test sites from the phone's network, never the PC's.
16. **LNReader plugins need the real cheerio** (1.0.0-rc.12, with htmlparser2 and dayjs);
    Mangayomi's Dart re-implementation breaks whole plugin families.
17. **A green line round the whole screen** was Android's keyboard-focus outline after one
    key press; `MainActivity.onPostResume` turns it off.
18. **A painted fade band never matches the diagonal ground.** Fade the content itself
    (`ShaderMask` with `dstIn`).
19. **`MarkStore.reset()` between widget tests:** a save inside one test's fake clock left
    the write queue waiting, and every later save timed out.
20. **Maestro selectors** use Flutter's merged semantics (a tile reads
    `Pride and Prejudice\nPride and Prejudice\nJane Austen\n…`); never `clearState: true` in a
    flow that tests resuming ([13 §13.11](13-testing-and-qa.md#1311-device-flows-and-the-emulator-job)).

## Housekeeping

- `spike-runs/`, `dist/` and `mobile-qa/scratch/` are git-ignored; delete freely. Never
  commit an APK.
- The developer keeps the PC light (no local JDK, Android SDK, Gradle or emulator):
  remove scratch SDKs, preview pages and downloaded browsers when done with them.
