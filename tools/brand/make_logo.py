#!/usr/bin/env python3
"""Draw the TomeVoice logo and write every size the project uses.

The mark: a page of text on the left becomes a voice waveform on the right,
joined by an amber spine. Text turning into speech is the whole product.
Flat, two colours plus one accent, so it holds up at 48 px on a launcher.

    python tools/brand/make_logo.py          # from the repo root

Writes the in-app mark, the README icon, the Android adaptive icon layers
(foreground, monochrome for themed icons, background colour) and the legacy
square and round launcher icons. Needs Pillow.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "app/android_overlay/app/src/main/res"

INK = (20, 30, 25, 255)        # deep forest ink: the app's night ground
CREAM = (242, 234, 218, 255)   # Skin.nightInk
AMBER = (224, 123, 57, 255)    # Skin.amber
CLEAR = (0, 0, 0, 0)

SS = 4  # supersampling factor


def _mark(size: int, scale: float, page: tuple, spine: tuple) -> Image.Image:
    """The mark on a transparent square of [size] px. [scale] is the mark's
    size relative to the 1024 design grid it was drawn on."""
    n = size * SS
    im = Image.new("RGBA", (n, n), CLEAR)
    d = ImageDraw.Draw(im)
    k = n / 1024 * scale
    # Design-grid centre of the mark, moved to the canvas centre.
    cx, cy = 516, 534

    def p(x, y):
        return ((x - cx) * k + n / 2, (y - cy) * k + n / 2)

    def pill(x0, y0, x1, y1, fill):
        a, b = p(x0, y0), p(x1, y1)
        r = min(b[0] - a[0], b[1] - a[1]) / 2
        d.rounded_rectangle([a[0], a[1], b[0], b[1]], radius=r, fill=fill)

    # Left: the page, its top and bottom edges gently curved like an open book.
    pts = []
    steps = 60
    for i in range(steps + 1):
        t = i / steps
        pts.append(p(496 + (214 - 496) * t, 352 + (300 - 352) * t - 26 * math.sin(math.pi * t)))
    for i in range(steps + 1):
        t = 1 - i / steps
        pts.append(p(496 + (214 - 496) * t, 742 + (702 - 742) * t - 16 * math.sin(math.pi * t)))
    d.polygon(pts, fill=page)

    # Lines of text, cut out of the page.
    for i, y in enumerate((404, 464, 524, 584, 644)):
        pill(268, y, 452 if i != 4 else 362, y + 24, CLEAR)

    # Right: the same page as sound. Bars sit inside the page outline, their
    # heights following a spoken phrase.
    for x, e in zip((570, 632, 694, 756, 812), (0.94, 0.6, 0.84, 0.46, 0.66)):
        t = (x - 528) / (812 - 528)
        top = 352 + (300 - 352) * t - 26 * math.sin(math.pi * t)
        bot = 742 + (702 - 742) * t - 16 * math.sin(math.pi * t)
        mid, half = (top + bot) / 2, (bot - top) / 2 * e
        pill(x - 21, mid - half, x + 21, mid + half, page)

    # The spine: where text becomes voice.
    pill(497, 316, 527, 772, spine)
    return im.resize((size, size), Image.LANCZOS)


def _squircle(size: int, radius: float, color) -> Image.Image:
    n = size * SS
    im = Image.new("RGBA", (n, n), CLEAR)
    ImageDraw.Draw(im).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius * n, fill=color)
    return im.resize((size, size), Image.LANCZOS)


def _circle(size: int, color) -> Image.Image:
    n = size * SS
    im = Image.new("RGBA", (n, n), CLEAR)
    ImageDraw.Draw(im).ellipse([0, 0, n - 1, n - 1], fill=color)
    return im.resize((size, size), Image.LANCZOS)


def icon(size: int, *, round_: bool = False, scale: float = 1.08) -> Image.Image:
    """The full icon: mark on the ink tile."""
    tile = _circle(size, INK) if round_ else _squircle(size, 0.225, INK)
    tile.alpha_composite(_mark(size, scale, CREAM, AMBER))
    return tile


def main() -> None:
    brand = ROOT / "app/assets/brand"
    brand.mkdir(parents=True, exist_ok=True)
    icon(1024).save(brand / "icon.png")          # README and stores
    icon(512).save(brand / "logo.png")           # in-app BrandMark

    # Adaptive icon: 108 dp canvas, the launcher masks to roughly the inner
    # 66 dp, so the mark sits inside that safe circle.
    for folder, px in (("drawable", 324), ("drawable-xxxhdpi", 432)):
        out = RES / folder
        out.mkdir(parents=True, exist_ok=True)
        _mark(px, 0.74, CREAM, AMBER).save(out / "ic_launcher_foreground.png")
        # Themed icons (Android 13+) tint this single-colour layer.
        _mark(px, 0.74, (255, 255, 255, 255), (255, 255, 255, 255)).save(
            out / "ic_launcher_monochrome.png"
        )

    for folder, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        out = RES / f"mipmap-{folder}"
        out.mkdir(parents=True, exist_ok=True)
        icon(px).save(out / "ic_launcher.png")
        icon(px, round_=True, scale=0.90).save(out / "ic_launcher_round.png")

    hexcol = "#{:02X}{:02X}{:02X}".format(*INK[:3])
    (RES / "values/ic_launcher_colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{hexcol}</color>\n</resources>\n',
        encoding="utf-8",
    )
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
        "</adaptive-icon>\n"
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (RES / "mipmap-anydpi-v26" / name).write_text(adaptive, encoding="utf-8")
    print("logo written")


if __name__ == "__main__":
    main()
