# Testing record

Scope: upstream `cf97d775fb3655b57fb7089b3dd85ab1b238b3e4`. All commands below
were run on Windows with an isolated E-drive toolchain; no C-drive work files
were created for this contribution.

## Environment and why a scratch app is used

- Contribution checkout: `E:\TomeVoice` (branch `main`, clean baseline at the
  commit above before these changes).
- Pinned SDK: `E:\TomeVoice\_theme_work\sdk` — Flutter 3.47.8 / Dart 3.13.7,
  matching `.github/workflows/build.yml`. Package cache:
  `E:\TomeVoice\_theme_work\pub-cache`.
- The machine's system Flutter is 3.22.2 / Dart 3.4.3 and cannot resolve the
  repository's existing `sdk: ^3.5.0`; `pubspec.yaml` was **not** weakened.
- A direct `flutter test` in the real checkout cannot build the Windows host
  artifacts because `flutter_qjs` requires a Visual Studio C++ toolchain that is
  not installed (`No Visual Studio installation found ... x64`). CI builds that
  dependency on its own runner.

Therefore verification uses `E:\TomeVoice\_theme_work\scratch\app`: a temporary
Flutter project containing byte-for-byte copies of `app/lib`, `app/test` and
`app/assets`, plus the repository `packages/` folder. Its `pubspec.yaml` omits
only the `flutter_qjs` git dependency, and
`lib/sources/qjs_runtime.dart` is replaced by a local stub that throws
`UnsupportedError`. No scratch change is copied into the contribution; the
scratch pubspec, stub and generated platform folders are not part of the diff.

## Commands and results

All commands were run from the scratch app unless stated otherwise, with
`PUB_CACHE=E:\TomeVoice\_theme_work\pub-cache` and the pinned SDK's `bin`
directory first on `PATH`.

### 1. Baseline before changing code

```powershell
# baseline lib/test copied in from E:\TomeVoice\_theme_work\baseline\app
flutter test --no-pub --reporter expanded test\colours_test.dart
```

PASS — 51/51 tests. Log: `testing/baseline_colours_test_scratch.log`. This
confirms the contrast suite was green before any palette was added.

### 2. Format check

```powershell
dart format --output=none --set-exit-if-changed `
  lib\premium_theme_palettes.dart `
  test\premium_themes_test.dart `
  test\premium_themes_preview_test.dart
```

PASS — `Formatted 3 files (0 changed in 0.04 seconds)`, exit 0. Log:
`testing/new_files_format.log`.

`app/lib/theme.dart` is deliberately excluded from this command. Its only edit
is the two-line hook; running Dart 3.13's formatter over the whole pre-existing
file would create an unrelated 398-insertion/119-deletion rewrite, so the
original formatting was preserved.

### 3. Static analysis

```powershell
flutter analyze --no-pub
```

PASS — `No issues found! (ran in 42.1s)`, exit 0. Log:
`testing/contribution_analyze.log`.

### 4. Relevant test suite

```powershell
flutter test --no-pub --reporter expanded `
  test\premium_themes_test.dart `
  test\colours_test.dart `
  test\scene_test.dart `
  test\accessibility_test.dart `
  test\widget_test.dart `
  test\premium_themes_preview_test.dart
```

PASS — `+198: All tests passed!`, exit 0, no skipped or expected-failure tests.
Log: `testing/contribution_tests_final.log`.

The count is 198 rather than the earlier 187 because the opt-in preview
renderer now registers one test per supported theme brightness (12 tests)
instead of a single no-op; all 12 are no-ops when `TOMEVOICE_PREVIEW_DIR` is
unset, so the normal suite still writes nothing.

Coverage of the new behavior:

- `premium_themes_test.dart` — all seven ids registered in `Palette.all` and
  `Palette.byId()`, all semantic fields present, contrast contract clean,
  brightness locks correct, and `Skin.themeFor()` maps palettes onto the real
  `ThemeData` controls.
- `colours_test.dart` — the repository's own contrast/ink-order checks run over
  `Palette.all`, so every new palette is included automatically.
- `scene_test.dart`, `accessibility_test.dart`, `widget_test.dart` — adjacent
  surface regression checks remain green with the extended registry.
- `premium_themes_preview_test.dart` — no-op during the normal suite.

### 5. Preview generation

```powershell
$env:TOMEVOICE_PREVIEW_DIR = 'E:\TomeVoice\contrib\premium-themes\previews'
flutter test --no-pub --reporter expanded test\premium_themes_preview_test.dart
```

PASS — `+12: All tests passed!`, exit 0, exactly 12 non-empty PNGs. Log:
`testing/previews.log`. The renderer uses `Skin.themeFor()` and
`Skin.groundFor()`; `toImage()`/`toByteData()` are awaited through
`tester.runAsync()` so the Flutter test binding does not leave pending real
async work at teardown.

Decoded pixel inspection (2 px grid) confirmed both brightness families:

- `arctic-silver-light.png`: `#F5F8FA` sheet, `#101820` ink, `#3C4A56` soft ink,
  `#5FA8C9` accent.
- `obsidian-luxe-dark.png`: `#080808` sheet, `#FBF4E5` ink, `#C6BCAB` soft ink,
  `#D9B45E` accent.

Log: `testing/preview_inspection.log`. The images are 720x440 each. Direct
image viewing was unavailable in the agent model, so the inspection used
`System.Drawing.Bitmap` pixel decoding rather than a visual guess.

### 6. Diff hygiene

```powershell
# from E:\TomeVoice
git diff --check
git status --short
git diff --stat
```

PASS — `git diff --check` exit 0. `git status --short` shows only:

```
 M app/lib/theme.dart
?? app/lib/premium_theme_palettes.dart
?? app/test/premium_themes_preview_test.dart
?? app/test/premium_themes_test.dart
?? contrib/
```

`git diff --stat` for the tracked existing file is `12 insertions(+), 1
deletion(-)`. Logs: `testing/diff_check.log`, `testing/final_status.log`.

## Known environment notes

- The scratch workaround is a local test harness only. The contribution adds no
  dependency, changes no pubspec/lockfile, and ships no stub or generated
  platform file.
- All new runtime colors live in `app/lib/premium_theme_palettes.dart`; the
  previews in `contrib/premium-themes/previews/` are documentation only.
