# Integration instructions for the repository owner

These instructions apply to upstream `cf97d77`. The contribution is two small
edits to one existing file plus three new files; there is no migration, no
storage-key change and no public API change.

## Apply

1. Copy `app/lib/premium_theme_palettes.dart` into `app/lib/`.
2. Copy `app/test/premium_themes_test.dart` and
   `app/test/premium_themes_preview_test.dart` into `app/test/`.
3. In `app/lib/theme.dart`, after the existing imports, add:

   ```dart
   part 'premium_theme_palettes.dart';
   ```

4. In `app/lib/theme.dart`, replace the single-line `Palette.all` declaration
   with:

   ```dart
   static final all = [
     forest,
     lavender,
     ocean,
     black,
     paper,
     ...designer,
     ...scenes,
     ...PremiumThemes.all,
   ];
   ```

5. Verify:

   ```sh
   cd app
   dart format lib/premium_theme_palettes.dart lib/theme.dart \
     test/premium_themes_test.dart test/premium_themes_preview_test.dart
   flutter analyze --no-pub
   flutter test --no-pub test/premium_themes_test.dart test/colours_test.dart
   ```

6. Optional, to regenerate the preview PNGs:

   ```sh
   cd app
   TOMEVOICE_PREVIEW_DIR=../contrib/premium-themes/previews \
     flutter test --no-pub test/premium_themes_preview_test.dart
   ```

   On PowerShell, set the variable first:

   ```powershell
   $env:TOMEVOICE_PREVIEW_DIR = '..\contrib\premium-themes\previews'
   flutter test --no-pub test\premium_themes_preview_test.dart
   ```

Nothing else is required. The existing Settings swatch row, `Palette.byId()`,
`prefs.json` persistence, book-cover tinting and light/dark toggle pick the new
themes up automatically.

## Why `Palette.all`, not `Palette.designer`

Adding to `Palette.all` alone makes each theme appear in the standard theme
swatch row. Adding to `Palette.designer` would also require a `designerNotes`
caption and would fold the themes into the designer sheet, which is a second
existing-file edit. The standard row is the smaller, reviewable surface and
keeps the existing designer collection untouched.

## Rollback

Remove the two lines from `app/lib/theme.dart` and delete the three new files.
No preference value needs cleanup: an unknown palette id already falls back to
`forest` in `Palette.byId()` (`theme.dart:988`), so a user who picked one of
these themes before a rollback simply sees Forest.

## Compatibility

- Dart/Flutter: matches the app's existing constraint (`sdk: ^3.5.0`) and CI
  pin (Flutter 3.47.8); no new dependency or platform channel.
- Storage: uses the existing string `palette` key; no schema or key change.
- Existing themes: all existing `Palette` constants, lists and notes are
  unchanged; the only list change is appending the seven new entries.
- Assets: none declared or loaded at runtime; `pubspec.yaml` and lockfiles are
  untouched.
