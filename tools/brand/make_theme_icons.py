#!/usr/bin/env python3
"""The launcher icon in each theme's colours, for "Icon follows the theme".

    python tools/brand/make_theme_icons.py      # from the repo root

The mark is the logo's (make_logo.py): a page, its lines and sound bars in
one colour, the spine in the accent, on a ground. Here it is cut into two
white layers, drawn once (drawable-xxxhdpi/ic_launcher_page.png and
ic_launcher_spine.png, a few KB each), and every theme's icon is those two
layers tinted in XML on a colour of its own, so forty icons weigh a few KB
more than one. Each theme in app/lib/theme.dart gets:

    values/theme_icon_colours.xml        its ground, page and spine colours
    drawable/ic_fg_t_<key>.xml           the two layers, tinted
    mipmap-anydpi-v26/ic_launcher_t_<key>.xml   the adaptive icon

<key> is the palette's id with '-' as '_', and _day or _night for a palette
that has both brightnesses. tools/prepare_android.py makes one launcher
activity-alias for each mipmap file it finds; lib/launcher_icon.dart picks
one by the same key.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_logo import CLEAR, RES, ROOT, _mark  # noqa: E402

THEME = ROOT / "app/lib/theme.dart"
WHITE = (255, 255, 255, 255)

# Skin's type colours, for palettes that keep the defaults.
INK = "14170F"
NIGHT_INK = "F8EFDF"


def palettes() -> list[dict]:
    text = THEME.read_text(encoding="utf-8")
    out = []
    for m in re.finditer(r"Palette\(\s*\n\s*id: '([^']+)',(.*?)\n  \)\)?;", text, re.S):
        pid, body = m.group(1), m.group(2)

        def colours(field):
            f = re.search(rf"\b{field}: \[([^\]]*)\]", body)
            return re.findall(r"0xFF([0-9A-Fa-f]{6})", f.group(1)) if f else None

        def colour(field, default=None):
            f = re.search(rf"\b{field}: Color\(0x[0-9A-Fa-f]{{2}}([0-9A-Fa-f]{{6}})\)", body)
            return f.group(1).upper() if f else default

        only = re.search(r"only: Brightness\.(light|dark)", body)
        out.append({
            "id": pid,
            "day": colours("day"),
            "night": colours("night"),
            "accent": colour("accent"),
            "accentDeep": colour("accentDeep"),
            "dayInk": colour("dayInk", INK),
            "nightInk": colour("nightInk", NIGHT_INK),
            "only": only.group(1) if only else None,
        })
    return out


def _lum(hexcol: str) -> float:
    def ch(v):
        c = int(v, 16) / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(hexcol[i:i + 2]) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a: str, b: str) -> float:
    x, y = sorted((_lum(a), _lum(b)), reverse=True)
    return (x + 0.05) / (y + 0.05)


def icons() -> dict[str, tuple[str, str, str]]:
    """key -> (ground, page, spine)."""
    out = {}
    for p in palettes():
        base = p["id"].replace("-", "_")
        both = p["only"] is None
        for b in ("day", "night"):
            if p["only"] and p["only"] != ("light" if b == "day" else "dark"):
                continue
            if b == "night":
                ground = p["night"][1] if p["id"] != "black" else "000000"
                page = p["nightInk"]
                spine = p["accent"]
            else:
                ground = p["day"][0]
                page = p["dayInk"]
                # The accent, unless it is too pale to see on the ground.
                spine = p["accent"] if _contrast(p["accent"], ground) >= 2.2 else p["accentDeep"]
            out[f"{base}_{b}" if both else base] = (ground.upper(), page.upper(), spine.upper())
    return out


def main() -> None:
    found = icons()
    if len(found) < 30:
        raise SystemExit(f"only {len(found)} theme icons found in theme.dart: has its layout changed?")

    # The two white layers, cut from the logo's mark at its adaptive size.
    out = RES / "drawable-xxxhdpi"
    _mark(432, 0.74, WHITE, CLEAR).save(out / "ic_launcher_page.png", optimize=True)
    _mark(432, 0.74, CLEAR, WHITE).save(out / "ic_launcher_spine.png", optimize=True)

    # Last run's files go, so a theme taken away leaves no icon behind.
    for old in list((RES / "drawable").glob("ic_fg_t_*.xml")) + list((RES / "mipmap-anydpi-v26").glob("ic_launcher_t_*.xml")):
        old.unlink()

    lines = ['<?xml version="1.0" encoding="utf-8"?>', "<!-- Written by tools/brand/make_theme_icons.py. -->", "<resources>"]
    for key, (ground, page, spine) in sorted(found.items()):
        lines += [
            f'    <color name="ic_t_{key}_ground">#{ground}</color>',
            f'    <color name="ic_t_{key}_page">#{page}</color>',
            f'    <color name="ic_t_{key}_spine">#{spine}</color>',
        ]
        (RES / "drawable" / f"ic_fg_t_{key}.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
            "    <item>\n"
            f'        <bitmap android:src="@drawable/ic_launcher_page" android:tint="@color/ic_t_{key}_page" />\n'
            "    </item>\n"
            "    <item>\n"
            f'        <bitmap android:src="@drawable/ic_launcher_spine" android:tint="@color/ic_t_{key}_spine" />\n'
            "    </item>\n"
            "</layer-list>\n",
            encoding="utf-8",
        )
        (RES / "mipmap-anydpi-v26" / f"ic_launcher_t_{key}.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            f'    <background android:drawable="@color/ic_t_{key}_ground" />\n'
            f'    <foreground android:drawable="@drawable/ic_fg_t_{key}" />\n'
            '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
            "</adaptive-icon>\n",
            encoding="utf-8",
        )
    lines.append("</resources>")
    (RES / "values" / "theme_icon_colours.xml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    for key, c in sorted(found.items()):
        print(key, *c)
    print(len(found), "theme icons written")


if __name__ == "__main__":
    main()
