# File manifest

## Existing files modified

| File | Change | Why |
| --- | --- | --- |
| `app/lib/theme.dart` | Registered `PremiumThemes.all`; added two scene palettes and their heading switch cases | No theme-registry API exists; these are the smallest registration hooks. Existing palettes are untouched. |
| `app/lib/scene.dart` | Added `Scene.gothic`/`Scene.classicRenaissance`, the still-motion gate, art-state helpers and custom empty/ornament/divider art | Full runtime scene themes need their own enum entries, loading and icon work. |
| `app/lib/brand.dart` | Added custom aged-gold and laurel icon rims | The two scenes have distinctive icon work without changing existing rims. |
| `app/pubspec.yaml` | Declared the two new WebP files explicitly | The app uses explicit asset paths; scene art must be bundled to load at runtime. |
| `app/assets/licenses/third_party.txt` | Credited the two public-domain paintings | Required provenance for bundled art. |
| `tools/scene_art.py` | Added reproducible entries for both backdrops | Keeps the generated WebPs reproducible and attributable. |
| `app/test/scene_test.dart` | Added scene-id, still-motion and no-life-layer contracts | Guards the new behavior and the retired `scene-gothic` alias. |

## Existing files deliberately untouched

- `app/lib/prefs.dart`, `app/lib/own_colours.dart`, `app/lib/main.dart` — selection and persistence are id-driven and need no change.
- `app/lib/settings_screen.dart` — swatches and scene lists are generated from `Palette.all` and `Palette.scenes`.
- `app/lib/contrast.dart`, `app/lib/page_tone.dart` — existing semantic contracts are reused, not changed.
- All files under `app/lib/` that implement screens, navigation, audio, documents, databases or APIs.

## New files

| File | Purpose |
| --- | --- |
| `app/lib/premium_theme_palettes.dart` | Seven complete `Palette` definitions plus `PremiumThemes.all` |
| `app/test/premium_themes_test.dart` | Registration, contrast, brightness-lock and `ThemeData` mapping contract |
| `app/test/premium_themes_preview_test.dart` | Opt-in PNG renderer for the seven colour themes |
| `app/test/scene_themes_preview_test.dart` | Opt-in renderer for the two scene themes, loading the real WebPs |
| `app/assets/scenes/gothic.webp` | Gothic cathedral runtime backdrop |
| `app/assets/scenes/classicRenaissance.webp` | Classic Renaissance runtime backdrop |
| `contrib/premium-themes/README.md` | Theme-by-theme design notes |
| `contrib/premium-themes/architecture_report.md` | Architecture trace and safest-strategy rationale |
| `contrib/premium-themes/INTEGRATION.md` | Apply, verify and rollback instructions |
| `contrib/premium-themes/MODIFIED_FILES.md` | This manifest |
| `contrib/premium-themes/TESTING.md` | Commands, environment and results |
| `contrib/premium-themes/assets/README.md` | Source and licence notes for the runtime assets |
| `contrib/premium-themes/previews/*.png` | Theme previews generated from the real theme system |
