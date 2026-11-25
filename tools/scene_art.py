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

from PIL import Image, ImageEnhance, ImageFilter

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
        'local': 'scene_sources/blackRose.png',
        'credit': 'Made for TomeVoice with ChatGPT image generation (OpenAI). Cropped and colour-graded.',
        'across': 0.5, 'brightness': 0.8, 'contrast': 1.08, 'colour': 0.9, 'tint': (0.96, 0.97, 1.04),
    },
    'dragonSlate': {
        'local': 'scene_sources/dragonSlate.png',
        'credit': 'Made for TomeVoice with ChatGPT image generation (OpenAI). Cropped and colour-graded.',
        'across': 0.5, 'brightness': 0.8, 'contrast': 1.08, 'colour': 0.85, 'tint': (0.98, 0.98, 1.0),
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


def grade(img, spec):
    img = ImageEnhance.Color(img).enhance(spec['colour'])
    img = ImageEnhance.Contrast(img).enhance(spec['contrast'])
    img = ImageEnhance.Brightness(img).enhance(spec['brightness'])
    r, g, b = img.split()
    tr, tg, tb = spec['tint']
    img = Image.merge('RGB', (r.point(lambda v: v * tr), g.point(lambda v: v * tg), b.point(lambda v: v * tb)))
    # The finest canvas cracks and the scan's noise, softened: at a phone's
    # size they read as dirt, not paint.
    return img.filter(ImageFilter.SMOOTH)


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
        img = grade(crop_tall(src, spec['across']), spec)
        path = os.path.join(OUT, f'{name}.webp')
        img.save(path, 'WEBP', quality=80, method=6)
        print(f'{path}: {os.path.getsize(path) // 1024} KB')
        print('  credit:', spec['credit'])


if __name__ == '__main__':
    main(sys.argv[1:] or list(SCENES))
