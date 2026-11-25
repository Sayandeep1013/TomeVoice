# Premium themes for TomeVoice

Seven contributor colour themes and two full runtime scene themes for
TomeVoice 2.6.6 (`cf97d77`). They are additions only: no screen, navigation
route, business rule, audio/document pipeline, database, API, persistence
format or existing palette is changed. The two scene themes add their own
bundled WebP backdrops; the seven colour themes add none.

## What is delivered

| Path | Purpose |
| --- | --- |
| `../../app/lib/premium_theme_palettes.dart` | The seven `Palette` definitions and `PremiumThemes.all` |
| `../../app/lib/theme.dart` | Palette registration plus the two scene palettes (see `MODIFIED_FILES.md`) |
| `../../app/lib/scene.dart` | Scene enum entries, art loading, custom scene glyphs and the still-motion gate |
| `../../app/lib/brand.dart` | Custom icon rims for the two scenes |
| `../../app/assets/scenes/gothic.webp` | Gothic cathedral backdrop |
| `../../app/assets/scenes/classicRenaissance.webp` | Still Renaissance interior backdrop |
| `../../app/test/premium_themes_test.dart` | Registration, contrast, brightness-lock and `ThemeData` mapping checks |
| `../../app/test/premium_themes_preview_test.dart` | Opt-in renderer for the seven colour PNG previews |
| `../../app/test/scene_themes_preview_test.dart` | Opt-in renderer for the two scene PNGs, loading the real WebPs |
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
| Gothic cathedral | `scene-gothic-cathedral` | A public-domain cathedral painting behind aged-gold stone, lancet icons and candlelight | Aged gold `#C9A85A` | Dark only |
| Classic Renaissance | `scene-classic-renaissance` | A still late-Renaissance church interior in parchment and laurel, with no moving life layer | Ochre gold `#C79A5B` | Dark only |

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

### Gothic cathedral

A full scene theme, not just a colour palette. Its backdrop is Paul Vredeman
de Vries's public-domain "Interior of a Gothic Cathedral", cropped and graded
for a phone screen by `tools/scene_art.py`. It reuses the dungeon's stone
panels and buttons, turned towards aged gold and oxblood, but has its own
lancet-arch empty state, crest, foot ornament and divider. The icon rim is a
four-rivet aged-gold edge with small lancet arches. Candlelife moves as in the
dungeon; nothing about the dungeon itself is changed.

### Classic Renaissance

A full scene theme built to be still. Its backdrop is Anthonie Palamedesz.'s
public-domain-marked late-Renaissance church interior, cropped and graded by
the same generator. The palette is parchment and laurel, the icon rim carries
small laurel sprigs, and the ornaments are period leaves and an open book.
`Scene.classicRenaissance.still` keeps `_SceneLifeState` from building a timer
or a life layer at all, so its only motion is the app's normal navigation.

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

The seven colour themes need no runtime asset: their grounds and page textures
are drawn in code. The two scene themes add two public-domain WebP backdrops,
generated reproducibly by `tools/scene_art.py`, declared explicitly in
`app/pubspec.yaml` and credited in `app/assets/licenses/third_party.txt`. The
PNG files in `previews/` are documentation artefacts from the opt-in preview
tests; they are not declared in `pubspec.yaml` and are not bundled into the
app. See `assets/README.md` for source and licence details.
