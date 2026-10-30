#!/usr/bin/env python3
"""Build the catalog of natural voices: app/assets/voices/catalog.json.

Every Piper voice that sherpa-onnx's `tts-models` release offers in full
precision (the fp16 ones crash ONNX Runtime on phones), with its language and
region, quality, download size, sample rate, a sample to hear, and the licence
of the recordings it was trained on, read from the voice's MODEL_CARD in
rhasspy/piper-voices (or, for the few voices that are not there, from the
model's own page). Then the voices of two models that hold many speakers in
one download: Kokoro (bigger, slower, better) and Kitten (small).

Nothing here is decided at run time on the phone: the app reads the file this
writes, so a voice upstream adds next week is not offered until this is run
again and its licence looked at (docs/06 section 6.4, docs/18 section 2).

    python tools/voice_catalog.py            # fetch, cache, write
    python tools/voice_catalog.py --check    # say what would change, write nothing

GITHUB_TOKEN (or GH_TOKEN), when set, raises the GitHub API's rate limit.
Downloads are cached (--cache), so a second run is quick and offline.
"""

from __future__ import annotations

import argparse
import ast
import collections
import hashlib
import json
import os
import re
import ssl
import sys
import tempfile
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "app" / "assets" / "voices" / "catalog.json"

RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
RELEASE_API = "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/tts-models"
SHERPA_GENERATOR = "scripts/piper/generate.py"
PIPER = "https://huggingface.co/rhasspy/piper-voices"
MIRROR = "https://huggingface.co/csukuangfj"  # sherpa-onnx's copy of each converted model
SAMPLES = "https://huggingface.co/csukuangfj/sherpa-onnx-tts-samples"
SAMPLES_2 = "https://huggingface.co/csukuangfj2/sherpa-onnx-tts-samples"

# Release files named for a voice that another file already offers, or that
# cannot be offered as a Piper voice: left out, and said so when this runs.
SKIP = {
    "en_GB-southern_english_female_medium": "an older copy of en_GB-southern_english_female-medium",
    "es-glados-medium": "an older copy of es_ES-glados-medium",
    "en_US-glados": "an older conversion of en_US-glados-high, with no quality in its name",
    "fa-haaniye_low": "an old Mycroft mimic3 voice, not a Piper one (no region or quality in its name)",
    "en_GB-sweetbbak-amy": "an unofficial conversion with no quality in its name and no stated licence",
}

# Release names that do not follow lang_REGION-name-quality.
ODD = {
    "fr_FR-tjiho-model1": {"locale": "fr_FR", "name": "tjiho_1"},
    "fr_FR-tjiho-model2": {"locale": "fr_FR", "name": "tjiho_2"},
    "fr_FR-tjiho-model3": {"locale": "fr_FR", "name": "tjiho_3"},
    "fa_en-rezahedayatfar-ibrahimwalk-medium": {"locale": "fa_IR", "name": "reza_ibrahim_walk", "quality": "medium"},
}

# The names the first natural voices were offered under, and what was said of
# them: kept, so a reader finds the same voice where it was.
FIRST = {
    "en_US-kristin-medium": ("Kristin", "Warm and clear"),
    "en_US-norman-medium": ("Norman", "Calm, a little deep"),
    "en_GB-alan-medium": ("Alan", "Steady British reader"),
    "en_GB-jenny_dioco-medium": ("Jenny (Dioco)", "Bright British voice"),
    "en_GB-cori-medium": ("Cori", "Soft and expressive"),
    "en_US-lessac-high": ("Lessac", "The richest, needs a faster phone"),
    "en_US-ryan-high": ("Ryan", "Deep and full, needs a faster phone"),
}

# Names read better than the file's.
NAMES = {
    "jenny_dioco": "Jenny (Dioco)",
    "hfc_female": "HFC female",
    "hfc_male": "HFC male",
    "northern_english_male": "Northern English male",
    "southern_english_female": "Southern English female",
    "southern_english_male": "Southern English male",
    "libritts": "LibriTTS",
    "libritts_r": "LibriTTS-R",
    "ljspeech": "LJ Speech",
    "arctic": "CMU Arctic",
    "l2arctic": "L2-Arctic",
    "vctk": "VCTK",
    "aru": "ARU",
    "semaine": "SEMAINE",
    "upc_ona": "Ona",
    "upc_pau": "Pau",
    "bu_tts": "BU-TTS",
    "mc_speech": "MC Speech",
    "news_tts": "News",
    "reza_ibrahim": "Reza Ibrahim",
    "reza_ibrahim_walk": "Reza and Ibrahim",
    "ganji_adabi": "Ganji (literary)",
    "serbski_institut": "Serbski Institut",
    "25hours_single": "25hours",
    "vais1000": "VAIS-1000",
    "thorsten_emotional": "Thorsten (emotional)",
    "glados": "GLaDOS",
    "glados_turret": "GLaDOS turret",
    "eva_k": "Eva K",
    "SA_miro": "Miro (Saudi)",
    "SA_miro_V2": "Miro 2 (Saudi)",
    "SA_dii": "Dii (Saudi)",
    "berfin_renas": "Berfin Renas",
    "jarvis_wg_glos": "Jarvis",
    "justyna_wg_glos": "Justyna",
    "meski_wg_glos": "Męski",
    "zenski_wg_glos": "Żeński",
    "ukrainian_tts": "Ukrainian TTS",
    "xiao_ya": "Xiao Ya",
    "talesyntese": "Talesyntese",
    "nst": "NST",
    "dfki": "DFKI",
    "upmc": "UPMC",
    "siwis": "SIWIS",
    "issai": "ISSAI",
    "tugao": "Tugão",
    "gwryw_gogleddol": "Gwryw gogleddol",
    "tjiho_1": "Tjiho 1",
    "tjiho_2": "Tjiho 2",
    "tjiho_3": "Tjiho 3",
}

# --- Licences ---------------------------------------------------------------
#
# What the recordings a voice learned from may be used for, from the most open
# to the least: free (public domain, CC0), credit (open, on conditions such as
# credit or share-alike), noncommercial, restricted (no licence granted), and
# unclear (the card does not say, or says something that does not settle it).

FREE, CREDIT, NONCOMMERCIAL, RESTRICTED, UNCLEAR = "free", "credit", "noncommercial", "restricted", "unclear"


def lic(name: str, use: str, note: str) -> dict:
    return {"name": name, "use": use, "note": note}


# Datasets whose card says only "See URL" (or names a licence page), as read
# by hand: the dataset's address, and what its terms are.
BY_DATASET = [
    ("mimic3-voices/blob/master/voices/en_UK/apope",
     lic("All rights reserved", RESTRICTED,
         "Mycroft AI's recordings, \"All Rights Reserved\": no licence is granted.")),
    ("jenny-tts-dataset",
     lic("Jenny licence", CREDIT, "Commercial use allowed; credit the voice as Jenny (Dioco).")),
    ("m-ailabs-speech-dataset",
     lic("M-AILABS licence", CREDIT, "Free to use, also commercially; keep M-AILABS's copyright notice.")),
    ("20.500.12537/104",
     lic("CC BY 4.0", CREDIT, "Talrómur corpus: free to use with credit.")),
    ("indic-tts-malayalam",
     lic("IIT Madras licence", CREDIT, "IndicTTS recordings: free to use and share; keep IIT Madras's copyright notice.")),
    ("iitm.ac.in/donlab/indictts",
     lic("IIT Madras licence", CREDIT, "IndicTTS recordings: free to use and share; keep IIT Madras's copyright notice.")),
    ("lessac_blizzard2013",
     lic("Research licence", NONCOMMERCIAL, "Blizzard Challenge 2013 recordings: research and non-commercial use only.")),
    ("festvox.org/cmu_arctic",
     lic("CMU Arctic licence", CREDIT, "Free to use; keep Carnegie Mellon's notice.")),
]

# Voices whose card, or whose lack of one, needs a word of its own.
BY_VOICE = {
    # The card names a Malayalam corpus, which cannot be this voice's.
    "id_ID-news_tts-medium": lic("Not stated", UNCLEAR,
                                 "The model card names a Malayalam corpus, not an Indonesian one."),
    "en_US-amy-low": lic("Not stated", UNCLEAR, "The model card points to Mycroft's voices, which do not list her."),
    "en_US-amy-medium": lic("Not stated", UNCLEAR, "The model card points to Mycroft's voices, which do not list her."),
    "en_US-danny-low": lic("Not stated", UNCLEAR, "The model card points to Mycroft's voices, which do not list him."),
    "sv_SE-lisa-medium": lic("Not stated", UNCLEAR, "The model card names no dataset and no licence."),
}

# Voices from outside rhasspy/piper-voices, from the model's own page.
OUTSIDE = {
    "miro": lic("CC BY-NC-SA 4.0", NONCOMMERCIAL, "OpenVoiceOS voice: non-commercial use only, share alike."),
    "dii": lic("CC BY-NC-SA 4.0", NONCOMMERCIAL, "OpenVoiceOS voice: non-commercial use only, share alike."),
    "glados": lic("Not settled", UNCLEAR,
                  "Learned from a game character's lines (Portal, by Valve); their rights are not settled."),
    "wg_glos": lic("MIT", CREDIT,
                   "The model is MIT and names no recordings. It started from the Lessac voice, whose "
                   "recordings are for research only."),
    "tjiho": lic("AGPL 3.0", CREDIT, "Free to use; changes must be shared under the AGPL."),
    "southern_english": lic("Apache 2.0", CREDIT, "The model page says Apache 2.0 and names no recordings."),
}

# A voice fine-tuned from another starts from that voice's model: said, where
# the other's recordings are less open than its own.
BASES = {
    "lessac": " It started from the Lessac voice, whose recordings are for research only.",
    "ryan": " It started from the Ryan voice, whose recordings are non-commercial.",
}


def classify_stated(stated: str, dataset: str) -> dict | None:
    """The licence from a card's own words, or None when they settle nothing."""
    s = stated.lower()
    for key, entry in BY_DATASET:
        if key.lower() in s or key.lower() in dataset.lower():
            return dict(entry)
    if re.search(r"public domain|unlicense", s):
        return lic("Public domain", FREE, "The recordings are public domain: free for any use.")
    if "cc0" in s:
        return lic("CC0", FREE, "The recordings are given to the public domain (CC0): free for any use.")
    v3 = "3.0" in s
    if re.search(r"by-nc-sa|nc-sa|by nc sa", s):
        return lic(f"CC BY-NC-SA {'3.0' if v3 else '4.0'}", NONCOMMERCIAL, "Non-commercial use only, with credit, share alike.")
    if re.search(r"by-nc|by nc|cc-by-nc|non-?commercial", s):
        name = "CC BY-NC 4.0" if re.search(r"by-nc|by nc|cc-by-nc", s) else "Non-commercial"
        return lic(name, NONCOMMERCIAL, "Non-commercial use only.")
    if re.search(r"by-sa|sharealike|share-alike", s):
        return lic(f"CC BY-SA {'3.0' if v3 else '4.0'}", CREDIT, "Free to use with credit; changes share alike.")
    if re.search(r"cc[- ]?by|attribution|creativecommons\.org/licenses/by/", s):
        return lic(f"CC BY {'3.0' if v3 else '4.0'}", CREDIT, "Free to use with credit.")
    if "apache" in s:
        return lic("Apache 2.0", CREDIT, "Free to use; keep the licence notice.")
    if re.search(r"\bmit\b", s):
        return lic("MIT", CREDIT, "Free to use; keep the licence notice.")
    if "agpl" in s:
        return lic("AGPL 3.0", CREDIT, "Free to use; changes must be shared under the AGPL.")
    if "gpl" in s:
        return lic("GPL 2.0", CREDIT, "Free to use; changes must be shared under the GPL.")
    if "openrail" in s or "open rail" in s:
        return lic("OpenRAIL-D", CREDIT, "Free to use within the licence's use restrictions.")
    return None


def card_fields(card: str) -> dict:
    """What a MODEL_CARD says of the recordings: licence, dataset, base voice."""
    stated = ""
    m = re.search(r"(?im)^\s*[*-]?\s*\**license\**\s*:\**\s*(.+)$", card)
    if m:
        stated = m.group(1).strip()
    if not stated:
        # A "## License" heading with the licence below it.
        m = re.search(r"(?ims)^#+\s*license\s*$\s*(.+?)$", card)
        if m:
            stated = m.group(1).strip()
    if not stated:
        m = re.search(r"(?i)released under ([^,.\n]+)", card)
        if m:
            stated = m.group(1).strip()
    dataset = ""
    m = re.search(r"(?im)^\s*[*-]?\s*URL:\s*(\S+)", card)
    if m:
        dataset = m.group(1).strip()
    base = ""
    # "Finetuned from U.S. English lessac voice": the stops in U.S. are not the sentence's end.
    m = re.search(r"(?i)fine-?tuned from[^\n]*?\b(lessac|ryan|amy|libritts|kristin|talesyntese|ganji|amir|davefx|xiao ya|bryce)\b", card)
    if m:
        base = m.group(1).lower()
    return {"stated": stated, "dataset": dataset, "base": base}


def licence_for(vid: str, name: str, card: str, outside: dict | None) -> dict:
    fields = card_fields(card)
    stated, dataset = fields["stated"], fields["dataset"]
    entry = None
    if vid in BY_VOICE:
        entry = dict(BY_VOICE[vid])
    elif outside is not None:
        entry = dict(outside)
    if entry is None:
        entry = classify_stated(stated, dataset)
    if entry is None:
        if re.search(r"(?i)unknown", stated):
            entry = lic("Unknown", UNCLEAR, "The model card says the licence is unknown.")
        else:
            entry = lic("Not stated", UNCLEAR, "The model card does not state a licence; see the dataset's site.")
    base = BASES.get(fields["base"])
    if base and entry["use"] in (FREE, CREDIT):
        entry["note"] += base
    # A model page's words are kept only where they name a licence (a
    # packaging README's heading is followed by anything).
    if outside is not None and classify_stated(stated, dataset) is None:
        stated = ""
    entry["stated"] = stated
    entry["dataset"] = dataset
    return entry


# --- Kokoro and Kitten ------------------------------------------------------
#
# sherpa-onnx 1.13.8 runs both (OfflineTtsKokoroModelConfig with a language
# for espeak-ng, OfflineTtsKittenModelConfig). Kokoro v1.0's speakers, in the
# order of its voices.bin (sherpa-onnx scripts/kokoro/v1.0/generate_voices_bin.py),
# with the grade its makers give each (hexgrad/Kokoro-82M VOICES.md). Voices
# graded D or below are left out; Japanese and Chinese need a reader (misaki)
# that sherpa-onnx 1.13.8 does not have, so they are left out too.
KOKORO_SPEAKERS = [
    # sid, speaker, locale, espeak language, grade
    (3, "af_heart", "en_US", "en-us", "A"),
    (2, "af_bella", "en_US", "en-us", "A-"),
    (6, "af_nicole", "en_US", "en-us", "B-"),
    (1, "af_aoede", "en_US", "en-us", "C+"),
    (5, "af_kore", "en_US", "en-us", "C+"),
    (9, "af_sarah", "en_US", "en-us", "C+"),
    (14, "am_fenrir", "en_US", "en-us", "C+"),
    (16, "am_michael", "en_US", "en-us", "C+"),
    (18, "am_puck", "en_US", "en-us", "C+"),
    (0, "af_alloy", "en_US", "en-us", "C"),
    (7, "af_nova", "en_US", "en-us", "C"),
    (10, "af_sky", "en_US", "en-us", "C-"),
    (21, "bf_emma", "en_GB", "en-gb", "B-"),
    (22, "bf_isabella", "en_GB", "en-gb", "C"),
    (25, "bm_fable", "en_GB", "en-gb", "C"),
    (26, "bm_george", "en_GB", "en-gb", "C"),
    (28, "ef_dora", "es_ES", "es", ""),
    (29, "em_alex", "es_ES", "es", ""),
    (53, "em_santa", "es_ES", "es", ""),
    (30, "ff_siwis", "fr_FR", "fr-fr", "B-"),
    (31, "hf_alpha", "hi_IN", "hi", "C"),
    (32, "hf_beta", "hi_IN", "hi", "C"),
    (33, "hm_omega", "hi_IN", "hi", "C"),
    (34, "hm_psi", "hi_IN", "hi", "C"),
    (35, "if_sara", "it_IT", "it", "C"),
    (36, "im_nicola", "it_IT", "it", "C"),
    (42, "pf_dora", "pt_BR", "pt-br", ""),
    (43, "pm_alex", "pt_BR", "pt-br", ""),
    (44, "pm_santa", "pt_BR", "pt-br", ""),
]

# Kitten nano 0.8's speakers, in the order of its voices.bin (sherpa-onnx
# scripts/kitten-tts/v0_8/generate_voices_bin.py), by the names KittenML gives
# them (the model's config.json, voice_aliases).
KITTEN_SPEAKERS = [
    (0, "expr-voice-2-m", "Jasper"),
    (1, "expr-voice-2-f", "Bella"),
    (2, "expr-voice-3-m", "Bruno"),
    (3, "expr-voice-3-f", "Luna"),
    (4, "expr-voice-4-m", "Hugo"),
    (5, "expr-voice-4-f", "Rosie"),
    (6, "expr-voice-5-m", "Leo"),
    (7, "expr-voice-5-f", "Kiki"),
]

PACKS = [
    {
        "id": "kokoro-multi-lang-v1_0",
        "engine": "kokoro",
        "name": "Kokoro",
        "blurb": "Bigger, slower and often more natural. Needs a fast phone.",
        "file": "model.onnx",
        "sampleRate": 24000,
        # Kokoro holds about 850 MB while it reads (measured on an iPad with
        # the same model); below a 6 GB phone it is not offered.
        "minMemoryMb": 5200,
        # Offered for reading only once this phone's speed test shows it keeps up.
        "mustKeepUp": True,
        "licence": dict(lic("Apache 2.0", CREDIT,
                            "Kokoro-82M by hexgrad. Its makers say it learned from public-domain, openly "
                            "licensed and synthetic audio."),
                        stated="Apache-2.0", dataset="https://huggingface.co/hexgrad/Kokoro-82M",
                        card="https://huggingface.co/hexgrad/Kokoro-82M"),
    },
    {
        "id": "kitten-nano-en-v0_8-fp32",
        "engine": "kitten",
        "name": "Kitten",
        "blurb": "Small and quick: eight American English voices in one download.",
        "file": "model.fp32.onnx",
        "sampleRate": 24000,
        "minMemoryMb": 0,
        "mustKeepUp": False,
        "licence": dict(lic("Apache 2.0", CREDIT, "Kitten TTS nano 0.8 by KittenML."),
                        stated="Apache-2.0", dataset="https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32",
                        card="https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32"),
    },
]


# --- Fetching ---------------------------------------------------------------

try:
    import certifi  # fuller root certificates than some systems have (api.github.com failed without)

    TLS = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    TLS = None


class Fetch:
    """HTTP GETs, cached on disk by URL."""

    def __init__(self, cache: Path, refresh: bool):
        self.cache = cache
        self.refresh = refresh
        cache.mkdir(parents=True, exist_ok=True)

    def _path(self, url: str) -> Path:
        # Short: Windows paths stop at 260 characters.
        tail = re.sub(r"[^A-Za-z0-9._-]+", "_", url)[-48:]
        return self.cache / f"{hashlib.sha1(url.encode()).hexdigest()[:12]}-{tail}"

    def text(self, url: str, *, headers: dict | None = None, missing_ok: bool = False) -> str | None:
        p = self._path(url)
        if p.exists() and not self.refresh:
            t = p.read_text(encoding="utf-8")
            return None if t == "\0missing" else t
        req = urllib.request.Request(url, headers={"User-Agent": "tomevoice-voice-catalog", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=60, context=TLS) as r:
                t = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if missing_ok and e.code in (401, 403, 404):
                p.write_text("\0missing", encoding="utf-8")
                return None
            raise
        p.write_text(t, encoding="utf-8")
        return t

    def json(self, url: str, **kw):
        t = self.text(url, **kw)
        return None if t is None else json.loads(t)


def github_headers() -> dict:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    h = {"Accept": "application/vnd.github+json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def release_assets(fetch: Fetch) -> dict[str, int]:
    """Every file in the tts-models release, with its size in bytes."""
    release = fetch.json(RELEASE_API, headers=github_headers())
    out = {}
    page = 1
    while True:
        batch = fetch.json(f"https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/{release['id']}/assets"
                           f"?per_page=100&page={page}", headers=github_headers())
        if not batch:
            break
        for a in batch:
            out[a["name"]] = a["size"]
        page += 1
    return out


def sherpa_piper_models(fetch: Fetch) -> tuple[dict, str]:
    """sherpa-onnx's own list of the Piper models it converts, by voice id:
    where each came from (url) and what its packaging says of its licence
    (cmd). Read from the source without running it."""
    commits = fetch.json(f"https://api.github.com/repos/k2-fsa/sherpa-onnx/commits?path={SHERPA_GENERATOR}&per_page=1",
                         headers=github_headers())
    sha = commits[0]["sha"]
    src = fetch.text(f"https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/{sha}/{SHERPA_GENERATOR}")
    tree = ast.parse(src)

    def calls(node):
        return [c for c in ast.walk(node) if isinstance(c, ast.Call) and getattr(c.func, "id", None) == "PiperModel"]

    def const(node):
        return node.value if isinstance(node, ast.Constant) else None

    out = {}
    for fn in tree.body:
        if not (isinstance(fn, ast.FunctionDef) and fn.name.startswith("get_") and fn.name.endswith("_models")):
            continue
        lists = collections.defaultdict(list)
        langs = {}
        for node in ast.walk(fn):
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                lists[node.targets[0].id] += calls(node.value)
            elif isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name):
                lists[node.target.id] += calls(node.value)
            elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                  and node.func.attr in ("extend", "append") and isinstance(node.func.value, ast.Name)):
                for a in node.args:
                    lists[node.func.value.id] += calls(a)
            elif isinstance(node, ast.For) and isinstance(node.iter, ast.Name):
                for b in node.body:
                    if (isinstance(b, ast.Assign) and isinstance(b.targets[0], ast.Attribute)
                            and b.targets[0].attr == "lang" and const(b.value)):
                        langs[node.iter.id] = const(b.value)
        for var, cs in lists.items():
            if var not in langs:
                continue
            for c in cs:
                kw = {k.arg: const(k.value) for k in c.keywords}
                if not kw.get("name") or not kw.get("kind"):
                    continue
                out[f"{langs[var]}-{kw['name']}-{kw['kind']}"] = {
                    "sr": kw.get("sr"), "ns": kw.get("ns"), "url": kw.get("url") or "", "cmd": kw.get("cmd") or "",
                }
    return out, sha


def hf_files(fetch: Fetch, repo_url: str) -> tuple[list[str], str]:
    """The files in a Hugging Face model repository, and its revision."""
    info = fetch.json(repo_url.replace("https://huggingface.co/", "https://huggingface.co/api/models/"), missing_ok=True)
    if info is None:
        return [], ""
    return [s["rfilename"] for s in info.get("siblings", [])], info.get("sha", "")


def fold(s: str) -> str:
    """tugão -> tugao."""
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


# --- Building ---------------------------------------------------------------

ID = re.compile(r"^(?P<lang>[a-z]{2,3})_(?P<region>[A-Z]{2})-(?P<name>.+)-(?P<quality>x_low|low|medium|high)$")


def display_name(name: str) -> str:
    if name in NAMES:
        return NAMES[name]
    words = name.split("_")
    return " ".join([words[0][:1].upper() + words[0][1:]] + words[1:])


def piper_voices(fetch: Fetch, assets: dict[str, int], sherpa: dict) -> tuple[list[dict], list[tuple[str, str]], str]:
    # Cards and configs as they are at one revision, so a run can be repeated.
    _, piper_rev = hf_files(fetch, PIPER)
    at = f"{PIPER}/resolve/{piper_rev or 'main'}"
    index = fetch.json(f"{at}/voices.json")
    by_fold = {fold(k): k for k in index}
    sample_files, _ = hf_files(fetch, SAMPLES)
    samples = set(sample_files)

    voices, skipped = [], []
    ids = sorted(m.group(1) for name in assets
                 if (m := re.fullmatch(r"vits-piper-(.+)\.tar\.bz2", name))
                 and not m.group(1).endswith(("-fp16", "-int8")))
    for vid in ids:
        if vid in SKIP:
            skipped.append((vid, SKIP[vid]))
            continue
        odd = ODD.get(vid, {})
        m = ID.match(vid)
        if m:
            locale, name, quality = f"{m['lang']}_{m['region']}", m["name"], m["quality"]
        elif odd:
            locale, name, quality = odd["locale"], odd["name"], odd.get("quality", "")
        else:
            skipped.append((vid, "its name is not lang_REGION-name-quality"))
            continue
        key = index.get(vid) and vid or by_fold.get(vid)
        outside = None
        if key:
            files = index[key]["files"]
            card_path = next(p for p in files if p.endswith("MODEL_CARD"))
            config_path = next(p for p in files if p.endswith(".onnx.json"))
            folder = card_path.rsplit("/", 1)[0]
            card = fetch.text(f"{at}/{urllib.parse.quote(card_path)}") or ""
            config = fetch.json(f"{at}/{urllib.parse.quote(config_path)}")
            sample = f"{PIPER}/resolve/main/{urllib.parse.quote(folder)}/samples/speaker_0.mp3"
            card_url = f"{PIPER}/blob/main/{urllib.parse.quote(card_path)}"
        else:
            # Not one of Piper's own: sherpa-onnx's copy says where it came from.
            mirror = f"{MIRROR}/vits-piper-{vid}"
            files, _ = hf_files(fetch, mirror)
            card = ""
            for f in ("MODEL_CARD", "README.md", "README"):
                if f in files:
                    card += (fetch.text(f"{mirror}/resolve/main/{f}") or "") + "\n"
            config = None
            if f"{vid}.onnx.json" in files:
                config = fetch.json(f"{mirror}/resolve/main/{vid}.onnx.json")
            source = sherpa.get(vid, {})
            for k, entry in OUTSIDE.items():
                if k in name or k in vid:
                    outside = entry
                    break
            mp3 = f"piper/mp3/{locale}/vits-piper-{vid}/0.mp3"
            sample = f"{SAMPLES}/resolve/main/{mp3}" if mp3 in samples else ""
            card_url = source.get("url") or mirror
        audio = (config or {}).get("audio", {})
        rate = audio.get("sample_rate") or sherpa.get(vid, {}).get("sr")
        if rate == 22500:
            rate = 22050  # as sherpa-onnx's add_meta_data.py corrects it
        if not rate:
            skipped.append((vid, "no sample rate found"))
            continue
        if quality not in ("x_low", "low", "medium", "high"):
            quality = audio.get("quality") if audio.get("quality") in ("x_low", "low", "medium", "high") else "medium"
        speakers = (config or {}).get("num_speakers") or sherpa.get(vid, {}).get("ns") or 1
        lexicon = (config or {}).get("phoneme_type") == "pinyin"
        licence = licence_for(vid, name, card, outside)
        licence["card"] = card_url
        title, blurb = FIRST.get(vid, (display_name(name), ""))
        voice = {
            "id": vid,
            "engine": "piper",
            "name": title,
            "locale": locale.replace("_", "-"),
            "quality": quality,
            "bytes": assets[f"vits-piper-{vid}.tar.bz2"],
            "sampleRate": rate,
            "speakers": speakers,
            "sample": sample,
            "licence": licence,
        }
        if blurb:
            voice["blurb"] = blurb
        if lexicon:
            # Chinese read through a lexicon and rules, not espeak-ng.
            voice["frontend"] = "lexicon"
        voices.append(voice)
    return voices, skipped, piper_rev


def pack_voices(fetch: Fetch, assets: dict[str, int]) -> tuple[list[dict], list[dict]]:
    packs, voices = [], []
    old_samples, _ = hf_files(fetch, SAMPLES)
    new_samples, _ = hf_files(fetch, SAMPLES_2)
    for p in PACKS:
        archive = f"{p['id']}.tar.bz2"
        if archive not in assets:
            print(f"warning: {archive} is not in the release; {p['name']} left out", file=sys.stderr)
            continue
        packs.append({**p, "bytes": assets[archive]})
        if p["engine"] == "kokoro":
            for sid, speaker, locale, lang, grade in KOKORO_SPEAKERS:
                mp3 = f"kokoro/v1.0/mp3/{sid}-{speaker}.mp3"
                licence = dict(p["licence"])
                if speaker == "ff_siwis":
                    licence["note"] = "Kokoro is Apache 2.0; this voice learned from the SIWIS recordings (CC BY 4.0)."
                voices.append({
                    "id": f"{p['id']}:{speaker}",
                    "engine": "kokoro",
                    "pack": p["id"],
                    "sid": sid,
                    "lang": lang,
                    "name": speaker.split("_", 1)[1].capitalize(),
                    "gender": "female" if speaker[1] == "f" else "male",
                    "grade": grade,
                    "locale": locale.replace("_", "-"),
                    "quality": "high",
                    "sampleRate": p["sampleRate"],
                    "sample": f"{SAMPLES}/resolve/main/{mp3}" if mp3 in old_samples else "",
                    "licence": licence,
                })
        else:
            for sid, speaker, name in KITTEN_SPEAKERS:
                mp3 = f"kitten/nano-v0_8-fp32/mp3/{sid}-{speaker}.mp3"
                voices.append({
                    "id": f"{p['id']}:{speaker}",
                    "engine": "kitten",
                    "pack": p["id"],
                    "sid": sid,
                    "name": name,
                    "gender": "female" if speaker.endswith("-f") else "male",
                    "locale": "en-US",
                    "quality": "medium",
                    "sampleRate": p["sampleRate"],
                    "sample": f"{SAMPLES_2}/resolve/main/{mp3}" if mp3 in new_samples else "",
                    "licence": dict(p["licence"]),
                })
    return packs, voices


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "tomevoice-voice-catalog")
    ap.add_argument("--refresh", action="store_true", help="fetch everything again")
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--check", action="store_true", help="report only; write nothing")
    args = ap.parse_args()

    fetch = Fetch(args.cache, args.refresh)
    assets = release_assets(fetch)
    sherpa, sherpa_rev = sherpa_piper_models(fetch)
    piper, skipped, piper_rev = piper_voices(fetch, assets, sherpa)
    packs, pack_speakers = pack_voices(fetch, assets)

    order = {"high": 0, "medium": 1, "low": 2, "x_low": 3}
    piper.sort(key=lambda v: (v["locale"], v["name"].lower(), order.get(v["quality"], 9)))
    catalog = {
        "about": "Natural voices TomeVoice offers. Made by tools/voice_catalog.py; do not edit by hand.",
        "version": 1,
        "sources": {
            "models": f"{RELEASE}/ (GitHub release tts-models, full precision only)",
            "cards": f"{PIPER} (revision {piper_rev})",
            "sherpaGenerator": f"https://github.com/k2-fsa/sherpa-onnx/blob/{sherpa_rev}/{SHERPA_GENERATOR}",
        },
        "packs": packs,
        "voices": piper + pack_speakers,
    }
    text = json.dumps(catalog, ensure_ascii=False, indent=1) + "\n"

    uses = collections.Counter(v["licence"]["use"] for v in piper)
    langs = collections.Counter(v["locale"].split("-")[0] for v in piper)
    print(f"{len(piper)} Piper voices in {len(langs)} languages; "
          f"{len(pack_speakers)} more in {len(packs)} models ({', '.join(p['name'] for p in packs)})")
    print("Piper licences: " + ", ".join(f"{k} {uses[k]}" for k in (FREE, CREDIT, NONCOMMERCIAL, RESTRICTED, UNCLEAR)))
    for vid, why in skipped:
        print(f"left out {vid}: {why}")
    if args.check:
        old = args.out.read_text(encoding="utf-8") if args.out.exists() else ""
        print("unchanged" if old == text else f"{args.out} would change")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {args.out.relative_to(REPO) if args.out.is_relative_to(REPO) else args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
