# Premium themes for TomeVoice

Seven contributor colour themes for TomeVoice 2.6.6 (`cf97d77`). They are
additions only: no screen, navigation route, business rule, audio/document
pipeline, database, API, persistence format, existing palette or bundled asset
is changed.

## What is delivered

| Path | Purpose |
| --- | --- |
| `../../app/lib/premium_theme_palettes.dart` | The seven `Palette` definitions and `PremiumThemes.all` |
| `../../app/lib/theme.dart` | Two-line registration hook (see `MODIFIED_FILES.md`) |
| `../../app/test/premium_themes_test.dart` | Registration, contrast, brightness-lock and `ThemeData` mapping checks |
| `../../app/test/premium_themes_preview_test.dart` | Opt-in renderer for the PNG previews |
| `previews/` | Rendered previews, produced through `Skin.groundFor()` and `Skin.themeFor()` |
| `architecture_report.md` | Exact theme architecture, interfaces and why the hook is minimal |
| `INTEGRATION.md` | Apply/rollback instructions for the repository owner |
| `TESTING.md` | Commands and results |
| `assets/README.md` | Why no runtime image asset is added |

## The collection

Every theme fills the full `Palette` contract: four-stop day and night grounds,
four accent tones, day/night capsules, sheets, ink tiers and danger colours.
All are wrapped in `readable()`, the same contrast-fitting step used by the
built-in designer themes, so text, icons, controls and washes keep their hue
while meeting the app's WCAG checks. The hex values in the table are the
authored accent seeds; `readable()` may move their light/dark companion tones a
little to clear a contrast threshold.

| Theme | Id | Character | Accent | Brightness |
| --- | --- | --- | --- | --- |
| Obsidian Luxe | `obsidian-luxe` | OLED black fading to graphite, champagne gold accents; a quiet evening skin | Champagne gold `#D9B45E` | Dark only |
| Midnight Sapphire | `midnight-sapphire` | Midnight navy and sapphire blue with silver surfaces; crisp and scholarly | Sapphire `#789BE0` | Light + dark |
| Royal Burgundy | `royal-burgundy` | Burgundy and wine grounds, rose gold marks, ivory paper | Rose gold `#E0A08D` | Light + dark |
| Emerald Heritage | `emerald-heritage` | Forest green and jade with muted gold and cream; a heritage-library feel | Jade `#54BFA0` | Light + dark |
| Arctic Silver | `arctic-silver` | Cool white, silver and ice blue by day; charcoal by night | Ice blue `#5FA8C9` | Light + dark |
| Mocha Atelier | `mocha-atelier` | Espresso, caramel, bronze and parchment; warm and bookish | Caramel `#C98A4B` | Light + dark |
| Amethyst Noir | `amethyst-noir` | Violet-black with amethyst and lavender, silvered surfaces | Amethyst `#B994EA` | Dark only |

### Obsidian Luxe

The dark ground begins at true black and moves through graphite to a warm
charcoal foot, so OLED screens can switch those pixels off. Champagne gold is
used only for the accent fill, selected rows and progress; the inks stay warm
ivory rather than clinical white. `only: Brightness.dark` keeps the OLED ground
from being replaced by a light one.

### Midnight Sapphire

A blue-ground theme that stays readable at both brightnesses. The light ground
runs from cool periwinkle to silver, the dark one from midnight navy to slate
blue. Sapphire controls use a deep tone for text on light surfaces and a soft
tone on dark bars; silver surfaces keep the interface calm.

### Royal Burgundy

Wine-coloured night grounds and blush-ivory day grounds frame rose gold
accents. The inks are slightly plum-tinted so they sit naturally on the warm
paper, and the rose gold never competes with read-aloud highlighting.

### Emerald Heritage

Deep forest and jade with cream day paper and a restrained muted-gold accent.
The jade accent is darkened for small text by day and softened on bars by night;
it reads as a library binding rather than a neon green.

### Arctic Silver

The brightest and coolest theme. Cool white and silver day surfaces carry ice
blue controls; the night ground becomes charcoal with the same blue kept soft.
It is the least tinted option for readers who want maximum neutrality.

### Mocha Atelier

Espresso night grounds and parchment day grounds, with caramel and bronze
accents. The warm ink tiers match coffee-toned paper, making this the most
comfortable long-session theme for low light.

### Amethyst Noir

Violet-black grounds with amethyst, lavender and silver surfaces. It is dark
only so the violet depth is preserved; the accent keeps its hue through the
contrast fit instead of collapsing into a generic purple.

## Semantic coverage

Because the app builds everything from `Palette` through `Skin.theme()`, each
theme automatically covers: scaffold and four-stop ground, capsules, sheets,
dialogs and bottom sheets, primary/secondary/faint text, buttons, selection
controls (switch, radio, checkbox), sliders and progress indicators, inputs and
focused borders, cards/borders/outlines, in-app navigation bar, snack bars and
tooltips, the audio player's dark bar, read-aloud washes, and status/navigation
bar icon brightness through ground brightness. Reading pages keep their own
`PageTone`, by design: the repository never places art or a theme ground behind
book words.

## Assets

No new runtime asset is needed. The architecture draws palette grounds and page
textures in code, and only scene themes load bundled WebP art. The PNGs in
`previews/` are documentation artefacts generated from the app's own theme APIs;
they are not declared in `pubspec.yaml` and are not bundled into the app.
