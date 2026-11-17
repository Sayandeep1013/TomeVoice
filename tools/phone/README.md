# Phone and local-check helpers

Small scripts used to check TomeVoice on a real phone over adb, and to run the app's tests on this PC. None of them ship with the app.

## Local check: `sync_check.sh`

Mirrors `app/lib`, `app/test`, `app/assets` and `packages/` into a scratch Flutter project, and stubs QuickJS, which can't be built on Windows (see docs/16, "Checking code locally").

One-time setup of the scratch project:
1. Unzip the Flutter SDK that CI pins (`FLUTTER_VERSION` in `.github/workflows/build.yml`) to `D:/tvchk/flutter`.
2. Make `D:/tvchk/w/app`. Copy `app/pubspec.yaml` and `app/pubspec.lock` into it, and remove the `flutter_qjs` dependency from that copy.
3. In that folder, run `flutter create --no-pub --platforms=android --project-name tomevoice_spike --org app.tomevoice .`.
4. Run `sh tools/phone/sync_check.sh`, then `flutter pub get`.

After that, each check is:

```sh
sh tools/phone/sync_check.sh
cd D:/tvchk/w/app && export PATH="/d/tvchk/flutter/bin:$PATH"
dart analyze --fatal-infos lib test && flutter test -r failures-only
```

Two tests fail on Windows only and pass on CI: `backup_test` "paths are pointed…" (backslashes) and `voice_download_test` "a damaged archive…" (a Windows file lock). Under full-suite load on this PC a few timing tests can fail now and then; rerun them alone, as CI on Linux is the judge.

## Driving the phone: `ui.py`

`python -I -X utf8 tools/phone/ui.py list [regex]` lists the labelled elements on screen. `tap REGEX [n]` taps an element by its label. `tapmid REGEX` taps the match nearest the middle of the screen.

It **refuses to tap** unless the window in front is the test app (`app.tomevoice.test`; change it with `TV_PKG`). The real app and the test app look identical, and pressing Back out of the test app brings the user's real TomeVoice forward. Labels read `text | content-desc`, so match buttons as `"^\| Play$"`.

## Frame pacing: `frames.py`

`python -I -X utf8 tools/phone/frames.py SECONDS action...`, where each action is `tap:REGEX`, `tapmid:REGEX` or `sleep:S`.

It polls SurfaceFlinger's `--latency` for the test app's surface every 0.4 s while the actions run. It prints the frame-interval spread in display frames (8.33 ms at 120 Hz).

When reading the numbers:
- The voice's glow draws every 4 frames on purpose.
- Android 17 runs app animations at 60 Hz (2-frame intervals) unless a finger is down: its "normal" frame rate category is 60.
