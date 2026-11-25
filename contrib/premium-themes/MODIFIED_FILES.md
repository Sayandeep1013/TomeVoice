# File manifest

## Existing files modified

| File | Change | Why |
| --- | --- | --- |
| `app/lib/theme.dart` | Added `part 'premium_theme_palettes.dart';` after imports; appended `...PremiumThemes.all` to `Palette.all` | The architecture has no theme-registry API; this is the smallest possible registration hook. No existing palette, note, scene or method is edited. |

## Existing files deliberately untouched

- `app/pubspec.yaml` and lockfiles — no new runtime asset or dependency.
- `app/lib/prefs.dart`, `app/lib/own_colours.dart`, `app/lib/main.dart` — selection and persistence are id-driven and need no change.
- `app/lib/settings_screen.dart` — swatches are generated from `Palette.all`.
- `app/lib/contrast.dart`, `app/lib/page_tone.dart`, `app/lib/scene.dart` — existing semantic contracts reused, not changed.
- All files under `app/lib/` that implement screens, navigation, audio, documents, databases or APIs.

## New files

| File | Purpose |
| --- | --- |
| `app/lib/premium_theme_palettes.dart` | Seven complete `Palette` definitions plus `PremiumThemes.all` |
| `app/test/premium_themes_test.dart` | Registration, contrast, brightness-lock and `ThemeData` mapping contract |
| `app/test/premium_themes_preview_test.dart` | Opt-in PNG renderer using the app's own theme APIs |
| `contrib/premium-themes/README.md` | Theme-by-theme design notes |
| `contrib/premium-themes/architecture_report.md` | Architecture trace and safest-strategy rationale |
| `contrib/premium-themes/INTEGRATION.md` | Apply, verify and rollback instructions |
| `contrib/premium-themes/MODIFIED_FILES.md` | This manifest |
| `contrib/premium-themes/TESTING.md` | Commands, environment and results |
| `contrib/premium-themes/assets/README.md` | Note on runtime assets |
| `contrib/premium-themes/previews/*.png` | Theme previews generated from the real theme system |
