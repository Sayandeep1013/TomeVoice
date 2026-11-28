"""Scene art: the backdrops of the scene themes, made from public-domain art.

Run once, by hand, when an artwork or its grade changes (not in CI):

    python tools/scene_art.py            # every scene
    python tools/scene_art.py forest     # one

Each source is fetched from Wikimedia Commons (its licence read from the
Commons API and checked, so a file whose licence changed is not used),
cropped to a tall phone screen, graded (darker, its colours moved toward
the scene's), and written as app/assets/scenes/<scene>.webp at 1080x2400.
The app draws the vignette, the panels and the moving light over it.

Needs Pillow (with WebP). The download is held in memory, not kept.
"""
import io
import json
import os
import sys
import urllib.parse
import urllib.request

from PIL import Image, ImageChops, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'app', 'assets', 'scenes')
UA = 'TomeVoice-build/1.0 (scene art; https://github.com/Sayandeep1013/TomeVoice)'
W, H = 1080, 2400

# Each scene: the Commons file, the licences accepted for it, where the
# crop sits across the picture (0 left, 1 right), and the grade.
SCENES = {
    'forest': {
        'file': 'In_the_Woods_MET_C_034R4.jpg',
        'credit': 'Asher B. Durand, "In the Woods" (1855). The Metropolitan Museum of Art, '
                  'Open Access (CC0). Cropped and colour-graded.',
        'licences': {'CC0', 'Public domain'},
        'across': 0.42,
        # The photograph's edge (frame shadow, the canvas's border) cut off.
        'trim': 0.012,
        'brightness': 0.62,
        'contrast': 1.12,
        'colour': 0.85,
        # Multiplied into each channel: a cool, mossy green.
        'tint': (0.86, 1.0, 0.9),
    },
    'dungeon': {
        'file': 'The_Dungeon_at_Castillo_de_San_Cristóbal.jpg',
        'credit': '"The Dungeon at Castillo de San Cristóbal" by Eric Pancer (vxla), '
                  'https://www.flickr.com/photos/vxla/5299369390/, CC BY 2.0 '
                  '(https://creativecommons.org/licenses/by/2.0/). Cropped and colour-graded.',
        'licences': {'CC BY 2.0'},
        'across': 0.5, 'brightness': 0.5, 'contrast': 1.15, 'colour': 0.75, 'tint': (1.0, 0.86, 0.74),
    },
    'solar': {
        'file': 'A_burst_of_solar_material_leaps_off_the_left_side_of_the_sun_in_what' + chr(0x2019)
                + 's_known_as_a_prominence_eruption.jpg',
        'credit': 'Image: NASA/SDO/AIA (2013). Public domain. Cropped and colour-graded.',
        'licences': {'Public domain'},
        'across': 0.0, 'brightness': 0.6, 'contrast': 1.15, 'colour': 1.0, 'tint': (1.0, 0.86, 0.6),
    },
    'silverWitch': {
        'file': 'John_Atkinson_Grimshaw_-_A_moonlit_lane.jpg',
        'credit': 'John Atkinson Grimshaw, "A Moonlit Lane" (1874). Public domain. Cropped and colour-graded.',
        'licences': {'Public domain'},
        'across': 0.25, 'trim': 0.01, 'brightness': 0.68, 'contrast': 1.12, 'colour': 0.3, 'tint': (0.82, 0.92, 1.1),
    },
    # Made for TomeVoice with an image model (the owner's own account), from
    # a brief of the scene; the original kept under tools/scene_sources.
    'blackRose': {
        'local': 'scene_sources/blackRose.webp',
        'credit': 'Made for TomeVoice with ChatGPT image generation (OpenAI). Cropped and colour-graded.',
        'across': 0.45, 'brightness': 0.95, 'contrast': 1.06, 'colour': 0.95, 'tint': (0.97, 0.98, 1.04),
    },
    'silverDragon': {
        'local': 'scene_sources/silverDragon.webp',
        'credit': 'Made for TomeVoice with ChatGPT image generation (OpenAI). Cropped and colour-graded.',
        'across': 0.5, 'brightness': 0.9, 'contrast': 1.08, 'colour': 0.85, 'tint': (0.98, 0.98, 1.0),
    },
    'oldTome': {
        'local': 'scene_sources/oldTome.webp',
        'credit': 'Made for TomeVoice with ChatGPT image generation (OpenAI). Cropped and colour-graded.',
        # A book's cover: its borders and corners kept whole, made taller
        # by two of its plain bands mirrored, not cut at the sides.
        'grow': [(0.24, 0.42), (0.58, 0.76)],
        'across': 0.5, 'brightness': 0.8, 'contrast': 1.08, 'colour': 0.9, 'tint': (1.0, 0.97, 0.92),
    },
    # The light scenes: graded paler, not darker, and washed toward their
    # paper ('wash', how much of it), so dark type reads over them.
    'morris': {
        'file': 'Willow Bough MET DP306734.jpg',
        'credit': 'William Morris (Morris & Co.), "Willow Bough" wallpaper (1887). The Metropolitan Museum '
                  'of Art, Open Access (CC0). Cropped and colour-graded.',
        'licences': {'CC0', 'Public domain'},
        # The sheet's printed margin and the maker's mark at the right cut off.
        'trim': 0.035, 'across': 0.35,
        'brightness': 1.04, 'contrast': 0.86, 'colour': 0.82, 'tint': (1.0, 1.0, 0.98),
        'wash': (246, 241, 228), 'washed': 0.34,
    },
    'botanical': {
        'file': 'Redoute - Rosa centifolia foliacea.jpg',
        'credit': 'Pierre-Joseph Redouté, "Rosa centifolia foliacea", from Les Roses (1817-1824). Public '
                  'domain. Placed on paper and colour-graded.',
        'licences': {'Public domain'},
        # The plate laid on warm paper at the top of the screen (its white
        # taken for the paper), its engraved caption left off.
        # A second sprig, mirrored, rising from the lower left: the two frame
        # the screen corner to corner.
        'onto': {'paper': (248, 241, 230), 'crop': (0.0, 0.0, 1.0, 0.88), 'width': 1.12, 'top': -0.03, 'left': 0.16,
                 'again': {'width': 0.95, 'top': 0.6, 'left': -0.3, 'mirror': True}},
        'brightness': 1.0, 'contrast': 0.92, 'colour': 0.86, 'tint': (1.0, 0.99, 0.97),
        'wash': (248, 241, 230), 'washed': 0.2,
    },
    'ukiyoe': {
        'file': 'Katsushika Hokusai - Fine Wind, Clear Morning (Gaifū kaisei) - Google Art Project.jpg',
        'credit': 'Katsushika Hokusai, "Fine Wind, Clear Morning" (Red Fuji), from Thirty-six Views of Mount '
                  'Fuji (c. 1830-1832). Public domain. Cropped and colour-graded.',
        'licences': {'Public domain'},
        'trim': 0.01, 'across': 0.74,
        'brightness': 1.08, 'contrast': 0.84, 'colour': 0.8, 'tint': (1.0, 0.98, 0.94),
        'wash': (244, 238, 224), 'washed': 0.36,
    },
}


def fetch_json(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fetch_bytes(url):
    # The file's address can hold characters a URL may not (a curly '...').
    url = urllib.parse.quote(url, safe=':/?&=%')
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def source(spec):
    if 'local' in spec:
        path = os.path.join(HERE, spec['local'])
        print(f"{spec['local']}: made for TomeVoice")
        return Image.open(path).convert('RGB')
    api = ('https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo'
           '&iiprop=url|size|extmetadata&iiextmetadatafilter=LicenseShortName&titles='
           + urllib.parse.quote('File:' + spec['file']))
    page = next(iter(fetch_json(api)['query']['pages'].values()))
    info = page['imageinfo'][0]
    licence = info.get('extmetadata', {}).get('LicenseShortName', {}).get('value', '')
    if licence not in spec['licences']:
        sys.exit(f"{spec['file']}: licence is now {licence!r}, not one of {sorted(spec['licences'])}; not used")
    print(f"{spec['file']}: {info['width']}x{info['height']}, {licence}")
    return Image.open(io.BytesIO(fetch_bytes(info['url']))).convert('RGB')


def grow_tall(img, bands):
    """[img] at the full width, made W:H by repeating [bands] (top and foot,
    as fractions of its height), each followed by its mirror image."""
    w, h = img.size
    img = img.resize((W, round(h * W / w)), Image.LANCZOS)
    h = img.height
    need = H - h
    if need <= 0:
        return crop_tall(img, 0.5)
    each = need // len(bands)
    parts, at = [], 0
    for i, (a, b) in enumerate(bands):
        top, foot = round(a * h), round(b * h)
        add = each if i < len(bands) - 1 else need - each * (len(bands) - 1)
        parts.append(img.crop((0, at, W, foot)))
        band = img.crop((0, top, W, foot))
        flip = band.transpose(Image.FLIP_TOP_BOTTOM)
        extra, k = [], 0
        while sum(p.height for p in extra) < add:
            extra.append(flip if k % 2 == 0 else band)
            k += 1
        joined = Image.new('RGB', (W, sum(p.height for p in extra)))
        y = 0
        for p in extra:
            joined.paste(p, (0, y))
            y += p.height
        parts.append(joined.crop((0, 0, W, add)))
        at = foot
    parts.append(img.crop((0, at, W, h)))
    out = Image.new('RGB', (W, H))
    y = 0
    for p in parts:
        if p.height:
            out.paste(p, (0, y))
            y += p.height
    return out


def crop_tall(img, across):
    """The widest W:H window of [img], placed [across] its width."""
    w, h = img.size
    if w / h > W / H:
        cw = round(h * W / H)
        x = round((w - cw) * across)
        img = img.crop((x, 0, x + cw, h))
    else:
        ch = round(w * H / W)
        img = img.crop((0, (h - ch) // 2, w, (h - ch) // 2 + ch))
    return img.resize((W, H), Image.LANCZOS)


def onto_paper(img, spec):
    """[img] cropped to spec['onto']['crop'] and laid on a sheet of paper
    W x H at its 'width' (of W), 'left' and 'top' (of W and H): its white
    taken for the paper (multiplied onto it)."""
    o = spec['onto']
    w, h = img.size
    l, t, r, b = o['crop']
    img = img.crop((round(w * l), round(h * t), round(w * r), round(h * b)))
    pw = round(W * o['width'])
    img = img.resize((pw, round(img.height * pw / img.width)), Image.LANCZOS)
    paper = Image.new('RGB', (W, H), o['paper'])
    layer = Image.new('RGB', (W, H), (255, 255, 255))
    layer.paste(img, (round(W * o['left']) - (pw - W) // 2, round(H * o['top'])))
    out = ImageChops.multiply(paper, layer)
    again = o.get('again')
    if again:
        aw = round(W * again['width'])
        second = img.resize((aw, round(img.height * aw / img.width)), Image.LANCZOS)
        if again.get('mirror'):
            second = second.transpose(Image.FLIP_LEFT_RIGHT)
        layer = Image.new('RGB', (W, H), (255, 255, 255))
        layer.paste(second, (round(W * again['left']), round(H * again['top'])))
        out = ImageChops.multiply(out, layer)
    return out


def grade(img, spec):
    img = ImageEnhance.Color(img).enhance(spec['colour'])
    img = ImageEnhance.Contrast(img).enhance(spec['contrast'])
    img = ImageEnhance.Brightness(img).enhance(spec['brightness'])
    r, g, b = img.split()
    tr, tg, tb = spec['tint']
    img = Image.merge('RGB', (r.point(lambda v: v * tr), g.point(lambda v: v * tg), b.point(lambda v: v * tb)))
    # The finest canvas cracks and the scan's noise, softened: at a phone's
    # size they read as dirt, not paint.
    img = img.filter(ImageFilter.SMOOTH)
    if 'wash' in spec:
        img = Image.blend(img, Image.new('RGB', img.size, spec['wash']), spec['washed'])
    return img


def main(names):
    # File names with accents print on any console.
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    os.makedirs(OUT, exist_ok=True)
    for name in names:
        spec = SCENES[name]
        src = source(spec)
        t = spec.get('trim', 0)
        if t:
            w, h = src.size
            src = src.crop((round(w * t), round(h * t), round(w * (1 - t)), round(h * (1 - t))))
        if 'onto' in spec:
            tall = onto_paper(src, spec)
        elif 'grow' in spec:
            tall = grow_tall(src, spec['grow'])
        else:
            tall = crop_tall(src, spec['across'])
        img = grade(tall, spec)
        path = os.path.join(OUT, f'{name}.webp')
        img.save(path, 'WEBP', quality=80, method=6)
        print(f'{path}: {os.path.getsize(path) // 1024} KB')
        print('  credit:', spec['credit'])


if __name__ == '__main__':
    main(sys.argv[1:] or list(SCENES))
