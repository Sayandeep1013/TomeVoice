# Integration instructions for the repository owner

These instructions apply to upstream `cf97d77`. The contribution adds seven
colour palettes and two full runtime scene themes. There is no migration, no
storage-key change and no public API change; the retired `scene-gothic` id still
maps to the dungeon.

## Apply

1. Copy `app/lib/premium_theme_palettes.dart` into `app/lib/`.
2. Copy `app/test/premium_themes_test.dart`,
   `app/test/premium_themes_preview_test.dart` and
   `app/test/scene_themes_preview_test.dart` into `app/test/`.
3. Copy `app/assets/scenes/gothic.webp` and
   `app/assets/scenes/classicRenaissance.webp` into `app/assets/scenes/`.
4. Apply the edits in `app/lib/theme.dart`, `app/lib/scene.dart`,
   `app/lib/brand.dart`, `app/pubspec.yaml`,
   `app/assets/licenses/third_party.txt`, `tools/scene_art.py` and
   `app/test/scene_test.dart` from the branch diff. They are all additive.
5. Verify:

   ```sh
   cd app
   dart format lib/premium_theme_palettes.dart \
     test/premium_themes_test.dart test/premium_themes_preview_test.dart \
     test/scene_themes_preview_test.dart
   flutter analyze --no-pub
   flutter test --no-pub test/premium_themes_test.dart test/colours_test.dart \
     test/scene_test.dart test/accessibility_test.dart test/widget_test.dart \
     test/premium_themes_preview_test.dart test/scene_themes_preview_test.dart
   ```

6. Optional, to regenerate the preview PNGs:

   ```sh
   cd app
   TOMEVOICE_PREVIEW_DIR=../contrib/premium-themes/previews \
     flutter test --no-pub test/premium_themes_preview_test.dart \
       test/scene_themes_preview_test.dart
   ```

   On PowerShell, set the variable first:

   ```powershell
   $env:TOMEVOICE_PREVIEW_DIR = '..\contrib\premium-themes\previews'
   flutter test --no-pub test\premium_themes_preview_test.dart test\scene_themes_preview_test.dart
   ```

Nothing else is required. The existing Settings swatch row, `Palette.byId()`,
`prefs.json` persistence, book-cover tinting and light/dark toggle pick the new
themes up automatically. Both scene themes are dark-only and appear in the
scene list from `Palette.scenes`.

## Why `Palette.all`, not `Palette.designer`

Adding the seven colour themes to `Palette.all` alone makes each appear in the
standard theme swatch row. Adding them to `Palette.designer` would also require
a `designerNotes` caption and would fold them into the designer sheet, which is
a second existing-file edit. The standard row is the smaller, reviewable
surface and keeps the existing designer collection untouched.

The two scene themes are registered in `Palette.scenes` instead, matching the
existing forest/solar/dungeon scenes. They are not colour palettes and need the
scene's painting, panels and motion behavior.

## Rollback

Remove the added palettes, scene entries, icon cases, asset lines and tests from
the existing files; delete the new Dart files, tests and two WebP assets. No
preference value needs cleanup: an unknown palette id already falls back to
`forest` in `Palette.byId()` (`app/lib/theme.dart`), and the retired
`scene-gothic` id remains mapped to `scene-dungeon`.

## Compatibility

- Dart/Flutter: matches the app's existing constraint (`sdk: ^3.5.0`) and CI
  pin (Flutter 3.47.8); no new dependency or platform channel.
- Storage: uses the existing string `palette` key; no schema or key change.
- Existing themes: all existing `Palette` constants, lists and notes are
  unchanged; the only list change is appending the seven colour entries and
  two scene entries.
- Assets: exactly two new WebP files, declared by explicit path in
  `pubspec.yaml`; no folder wildcard, no lockfile change and no new dependency.
