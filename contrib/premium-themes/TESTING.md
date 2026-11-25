# Testing record

Scope: upstream `cf97d775fb3655b57fb7089b3dd85ab1b238b3e4`, the seven colour
themes, and the two later full runtime scene themes. All commands below were
run on Windows with an isolated E-drive toolchain; no C-drive work files were
created for this contribution.

## Environment and why a scratch app is used

- Contribution checkout: `E:\TomeVoice` (branch `premium-themes`; baseline was
  clean at the commit above before these changes).
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

All Flutter/Dart commands were run from the scratch app unless stated
otherwise, with `PUB_CACHE=E:\TomeVoice\_theme_work\pub-cache`, `TEMP`/`TMP`
under `E:\TomeVoice\_theme_work\scratch`, and the pinned SDK's `bin` directory
first on PATH. `TOMEVOICE_PREVIEW_DIR` was unset for normal test runs.

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
  test\premium_themes_preview_test.dart `
  test\scene_themes_preview_test.dart
```

PASS — `Formatted 4 files (0 changed) in 0.02 seconds`, exit 0. Logs:
`testing/new_files_format.log` (seven-theme files) and
`testing/scene_new_files_format.log` (final four-file check).

The pre-existing Dart files are deliberately excluded from this command. Dart
3.13's formatter rewrites many unrelated legacy lines in them, so their edits
were reduced to semantic-only diffs instead: `theme.dart` 45+/1-,
`scene.dart` 162+/9-, `brand.dart` 66+/0-, `scene_test.dart` 40+/0-. No behavior
was dropped in that reduction; the full suite below proves it.

### 3. Static analysis

```powershell
flutter analyze --no-pub
```

PASS — `No issues found! (ran in 24.5s)`, exit 0. Logs:
`testing/contribution_analyze.log` (seven themes) and
`testing/scene_analyze.log` (final scene work).

### 4. Relevant test suite

```powershell
flutter test --no-pub --reporter expanded `
  test\premium_themes_test.dart `
  test\colours_test.dart `
  test\scene_test.dart `
  test\accessibility_test.dart `
  test\widget_test.dart `
  test\premium_themes_preview_test.dart `
  test\scene_themes_preview_test.dart
```

PASS — `+213: All tests passed!`, exit 0. No test was skipped, `.only`-ed,
`xfail`-ed or commented out. Logs: `testing/contribution_tests_final.log`
(seven themes, `+198`) and `testing/scene_tests_full.log` (final, `+213`).

The count is 213 because both opt-in preview renderers register no-op tests in
the normal suite: 12 colour-theme brightness cases and 2 scene cases. They
write nothing unless `TOMEVOICE_PREVIEW_DIR` is set.

Coverage of the new behavior:

- `premium_themes_test.dart` — all seven ids registered in `Palette.all` and
  `Palette.byId()`, all semantic fields present, contrast contract clean,
  brightness locks correct, and `Skin.themeFor()` maps palettes onto the real
  `ThemeData` controls.
- `colours_test.dart` — the repository's own contrast, ink-order and
  hue-retention checks run over `Palette.all`, so every new palette is included
  automatically. Gothic's initial `accentDeep` hue drifted 13.452° from its
  accent; the palette value was changed from `0xFF8A6328` to `0xFF846626`,
  bringing the drift to 4.08° with zero unmet contrast needs. The test was not
  weakened. Log of the focused retest: `testing/scene_focused_tests.log`
  (`+99: All tests passed!`).
- `scene_test.dart` — new ids, the retired `scene-gothic` alias, dark-only
  registration order, the still-motion gate, and the absence of a `LifePainter`
  layer for Classic Renaissance while Gothic keeps its candlelight.
- `accessibility_test.dart` and `widget_test.dart` — adjacent surface
  regressions remain green with the extended registry and scenes.
- Both preview tests — no-ops during the normal suite.

### 5. Preview generation

Seven colour themes (12 brightness cases):

```powershell
$env:TOMEVOICE_PREVIEW_DIR = 'E:\TomeVoice\contrib\premium-themes\previews'
flutter test --no-pub --reporter expanded test\premium_themes_preview_test.dart
```

PASS — `+12: All tests passed!`, exit 0, exactly 12 non-empty PNGs, 720x440
each. Log: `testing/previews.log`; pixel inspection:
`testing/preview_inspection.log`.

Two runtime scene themes:

```powershell
flutter test --no-pub --reporter expanded test\scene_themes_preview_test.dart
```

PASS — `+2: All tests passed!`, exit 0. Both PNGs are 720x1080:

- `previews/scene-gothic-cathedral-dark.png` — 831,056 bytes.
- `previews/scene-classic-renaissance-dark.png` — 784,692 bytes.

Logs: `testing/scene_previews.log` and
`testing/scene_preview_inspection.log`. Unlike the colour previews, this
renderer sets `Skin.palette` to the scene palette, paints the real
`SceneGround`, waits on `sceneArtLoaded()`, and captures only after the real
WebP has decoded. Decoded pixel grids show the Gothic dark ground
`#120D09` with aged-gold `#E3C98D`, and the Renaissance ground `#16110A` with
ochre `#E2BE86`.

### 6. Runtime asset generation

```powershell
# from E:\TomeVoice
python tools\scene_art.py
```

PASS — both WebPs were generated from their credited public-domain Wikimedia
sources and decoded at 720x1600 by `app/lib/scene.dart`. Logs:
`testing/scene_art_generation.log`. Assets:

- `app/assets/scenes/gothic.webp` — 136,670 bytes.
- `app/assets/scenes/classicRenaissance.webp` — 121,896 bytes.

Both are declared by explicit path in `app/pubspec.yaml` and credited in
`app/assets/licenses/third_party.txt`.

### 7. Diff hygiene

```powershell
# from E:\TomeVoice
git diff --check
git status --short
git diff --stat
```

PASS — `git diff --check` exit 0; the only output is Git's local CRLF notice for
the contributor Markdown files, not a whitespace error. Logs:
`testing/diff_check.log`, `testing/final_status.log`, and the final
`testing/scene_diff_check.log`, `testing/scene_final_status.log`.

The final `git status --short` contains only the theme-related source, tests,
runtime assets, previews and documentation listed in `MODIFIED_FILES.md`. No
screen, navigation, business-logic, audio, document, DB or API file is touched.

## Known environment notes

- The scratch workaround is a local test harness only. The contribution adds no
  dependency and ships no stub or generated platform file. Its only pubspec
  change is two explicit WebP asset paths for the two scene backdrops.
- The seven colour themes remain asset-free: their colours live in
  `app/lib/premium_theme_palettes.dart` and their PNGs in `previews/` are
  documentation only. The two scene themes intentionally add bundled WebP
  backdrops, generated by `tools/scene_art.py` and credited in the app.
