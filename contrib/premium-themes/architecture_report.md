# TomeVoice theme architecture report

Scope: upstream `main` at `cf97d775fb3655b57fb7089b3dd85ab1b238b3e4`.
Line references below are from that unmodified checkout; the contribution's
additions to `app/lib/theme.dart`, `app/lib/scene.dart` and `app/lib/brand.dart`
are described at the end.

## 1. Definition layer

`app/lib/theme.dart` is the single source of truth.

- `Skin` (`theme.dart:29`) is the visual-language facade. It owns the current `Palette` (`theme.dart:35`), resolves scoped overrides (`theme.dart:54-55`), and exposes semantic getters: grounds (`:72-75`), ink tiers (`:82-84`, `:128-130`, `:177-179`), accents (`:112-116`), capsules/sheets (`:105`, `:131-134`), outlines (`:194-195`) and dark bars/snack bars (`:186-191`).
- `Palette` (`theme.dart:631-655`) is the complete semantic interface contributed themes must implement:

  | Group | Fields |
  | --- | --- |
  | Identity | `id`, `label` |
  | Ground | `day[4]`, `night[4]` |
  | Accent | `accent`, `accentSoft`, `accentDeep`, `onAccent` |
  | Surfaces | `dayCapsule`, `nightCapsule`, `daySheet`, `nightSheet` |
  | Brightness | `only` (optional lock), `modeFor()` (`:1076-1080`) |
  | Type | `dayInk`, `dayInkSoft`, `dayInkFaint`, `nightInk`, `nightInkSoft`, `nightInkFaint` |
  | Status | `dayDanger`, `nightDanger` |
  | Art | `scene` (only for scene themes; `scene.dart:22-31`) |

- `Skin.themeFor(Palette, Brightness)` (`theme.dart:352-377`) caches one `ThemeData` per `paletteId/brightness`. `Skin.theme(Brightness)` (`theme.dart:379-621`) is the only production `ColorScheme`/`ThemeData` constructor; it maps the palette onto text selection, dividers, sliders, switches, radios, checkboxes, progress indicators, bottom sheets, dialogs, snack bars, popup menus, inputs, the in-app `NavigationBar`, filled/text/outlined/icon buttons, list tiles, the drawer, tooltips and page transitions. A palette therefore covers every semantic surface the app draws without any screen-level edits.
- `readable()` (`app/lib/contrast.dart:251-299`) fits ink tiers and accent tones to the palette's own grounds/surfaces while preserving hue. Designer and scene palettes are wrapped in it (`theme.dart:784-901`, `:921-982`); the new themes follow the same pattern.
- Runtime-generated palettes exist but are not named presets: `OwnColours` (`own_colours.dart:15-181`) and wallpaper colours (`wallpaper_colours.dart:81-99`) resolve through `chosenPalette()` (`own_colours.dart:187-191`). Book-cover tinting is `Palette.withTint()` (`theme.dart:1007-1022`).

## 2. Registration

There is no plugin registry, `registerTheme()` API or theme enum. Registration is by literal list in `app/lib/theme.dart`:

- `Palette.designer` (`:905`) and `Palette.designerNotes` (`:908-917`) drive the designer sheet.
- `Palette.scenes` (`:984`) drives scene themes (a closed `Scene` enum in `scene.dart:22-31`).
- `Palette.all` (`:986`) is the canonical registry; `Palette.byId()` (`:988`) looks up only this list and falls back to `forest`.

Consequence: a named, persisted theme cannot be added with zero edits to existing code. The smallest safe hook is to append an isolated palette list to `Palette.all`.

## 3. Selection and persistence

- Settings → Appearance → Theme builds swatches from `Palette.all` minus designer/scene palettes (`settings_screen.dart:909-914`). Each swatch draws `Skin.groundFor(b, p)` with the palette's ink and accent (`:944-1016`) and calls `onPick(p.id)` (`:954-956`).
- Designer/scene pickers read `Palette.designer` and `Palette.scenes` (`settings_screen.dart:1021-1422`). No switch hard-codes a theme id.
- Saving a pick writes `ListeningPrefs.paletteId`; the JSON file is `$libraryDir/prefs.json` with keys `'palette'` and `'themeMode'` (`prefs.dart:605-609`, read back at `:731-756`). `save()` bumps a revision notifier (`prefs.dart:548-561`), which rebuilds `SpikeApp` (`main.dart:143-157`).
- Resolution on startup: `chosenPalette(prefs)` (`own_colours.dart:187-191`) → `Palette.byId(id)` → `Palette.all` → `Skin.palette` → `Skin.themeFor()`.
- Ids are plain strings; there is no enum validation or migration table to extend. Retired ids are remapped in `theme.dart:992-999`, which the new ids do not touch.

## 4. Preview and system UI

- There is no standalone preview route. Previews are the list-driven swatches (`settings_screen.dart:944-1016`), designer cards (`:1314-1421`), scene previews (`scene.dart:2239-2269`) and the "Your own" card (`own_colours_sheet.dart:157-234`). The theme change also cross-fades the Settings screen (`settings_screen.dart:225-239`).
- `MaterialApp` installs `Skin.themeFor(palette, light)` and `Skin.themeFor(palette, dark)` plus `palette.modeFor(prefs.themeMode)` (`main.dart:165-170`).
- Status bar and system navigation bars follow ground brightness through an `AnnotatedRegion<SystemUiOverlayStyle>` (`main.dart:178-197`); the reader overrides it for its own page tone (`reader_screen.dart:2245-2264`). A palette controls this indirectly through its grounds and `only` field.
- The in-app bottom navigation bar is themed in `theme.dart:536-558`, using the ground foot (`Skin.groundFoot`, `:171-173`).

## 5. Assets

- Assets are declared as explicit paths in `app/pubspec.yaml:59-89`; a folder wildcard is deliberately not used. Adding a bundled image or font would require a pubspec edit and a CI lockfile relock (`.github/workflows/build.yml:747-798`).
- Colour themes need no bundled asset: grounds are four-stop gradients (`Skin.groundFor`, `theme.dart:142-150`) and page textures are drawn in code (`page_tone.dart:224`). Only scene themes load WebP backdrops (`scene.dart:145`, `pubspec.yaml:81-86`); `_withArt` decides which scenes use one.
- The seven new colour palettes add no runtime asset. The two new scene themes add `gothic.webp` and `classicRenaissance.webp`, generated by `tools/scene_art.py`, declared by explicit path and credited in `assets/licenses/third_party.txt`. Their PNGs in `previews/` remain documentation generated from the app's own theme APIs, not bundled resources.

## 6. Safest implementation strategy

1. Add one isolated `part` file, `app/lib/premium_theme_palettes.dart`, defining seven `readable(const Palette(...))` values and `PremiumThemes.all`. Every semantic field is declared explicitly; no hardcoded colour appears outside this file.
2. In `app/lib/theme.dart`, add only:
   - `part 'premium_theme_palettes.dart';` after the imports;
   - `...PremiumThemes.all,` inside the `Palette.all` list.
3. Do not touch screens, navigation, business logic, audio, documents, databases, APIs, persistence code, existing palettes or page tones.
4. Register the colour palettes in `Palette.all` (not `designer`) so the existing Settings swatch row picks them up with no second existing-file edit and no caption map requirement.
5. Use `only: Brightness.dark` only where the design requires it (Obsidian Luxe, Amethyst Noir); the existing `modeFor()` behaviour then hides the light/dark picker for those two, with no new code.

This is the least invasive route the architecture permits for colour themes. A
zero-edit theme plugin is not supported; any alternative would require adding a
registry API to existing code, which would be more invasive than the hook used
here.

### Runtime scene themes

The later request for a Gothic scene with custom background/icons and a still
Classic Renaissance scene supersedes the original "no runtime asset" boundary
for these two themes only. The implementation follows the architecture's own
scene seams:

1. Append `Scene.gothic` and `Scene.classicRenaissance` after `Scene.dungeon` so
   `Scene.values` still matches `Palette.scenes` order. Both use
   `kin: Scene.dungeon`, their own `hue`/`saturation`, and a new `still` flag on
   Classic Renaissance.
2. Add the two palettes to `Palette.scenes`, with fresh ids; the retired
   `scene-gothic` alias is left mapping to `scene-dungeon`.
3. Add the two explicit WebP entries to `pubspec.yaml` and `_withArt`, and
   generate the images with `tools/scene_art.py` from public-domain sources.
4. Add exhaustive `Skin.heading` and `LifePainter.paint` cases. For the still
   scene, `_SceneLifeState` is gated earlier: `sceneLifeMovesFor(scene)` keeps
   the timer and life layer from being built at all.
5. Add custom empty/ornament/divider art and brand rims keyed on the new scenes.
   Existing scenes fall through to their unchanged cases.

## 7. Verification surfaces

- Contrast contract: `app/test/colours_test.dart:146-189` iterates `Palette.all`, so every new palette is automatically checked on every surface, for book-cover tinting and for ink order/hue retention.
- Registration/integration: `app/test/premium_themes_test.dart` (added) checks all seven ids are in `Palette.all`/`Palette.byId()` and that `Skin.themeFor()` maps each palette onto the real `ThemeData` fields.
- Rendered previews: `app/test/premium_themes_preview_test.dart` (added, opt-in via `TOMEVOICE_PREVIEW_DIR`) draws each colour theme with `Skin.groundFor()` and `Skin.themeFor()` and writes the PNGs in `previews/`.
- Scene contracts: `app/test/scene_test.dart` checks the new ids, the retired alias, the still-motion gate and that no life layer is built for Classic Renaissance.
- Rendered scene previews: `app/test/scene_themes_preview_test.dart` (added, opt-in) sets `Skin.palette`, paints the real `SceneGround`, waits for `sceneArtLoaded()` and captures `720x1080` PNGs from the actual WebPs.
