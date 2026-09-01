#!/usr/bin/env python3
"""Patch the Android project that `flutter create` generates.

Run from the `app/` directory after `flutter create`. Two changes are needed
that the generated project cannot know about:

1. **Package visibility for TTS engines.** Since Android 11, an app can only
   see other packages it declares an interest in. Without a <queries> entry for
   the TTS_SERVICE intent, `TextToSpeech.getEngines()` returns almost nothing —
   and the spike's whole purpose is comparing engines, so this is not optional.

2. **SDK levels.** minSdk 26, because `onRangeStart` was added in API 26 and the
   spike depends on it. targetSdk 36, because Google Play has required it for new
   apps since 31 August 2026 (docs/07 section 7.1).

Idempotent: running it twice changes nothing the second time.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MIN_SDK = 26
TARGET_SDK = 36

QUERIES_BLOCK = """    <!-- Required since Android 11 for TextToSpeech.getEngines() to see
         installed engines. Without this the spike can only test the default
         engine, which would not answer the per-engine question it exists for. -->
    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>
"""


def patch_manifest(path: Path) -> str:
    text = path.read_text(encoding="utf-8")

    if "android.intent.action.TTS_SERVICE" in text:
        return "manifest: already has TTS queries"

    if "</manifest>" not in text:
        raise SystemExit(f"manifest: no closing tag in {path}")

    text = text.replace("</manifest>", QUERIES_BLOCK + "</manifest>", 1)
    path.write_text(text, encoding="utf-8")
    return "manifest: added <queries> for TTS_SERVICE"


def patch_gradle(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    original = text
    notes = []

    # Kotlin DSL uses `minSdk = flutter.minSdkVersion`, Groovy uses
    # `minSdkVersion flutter.minSdkVersion`. Handle both, plus already-numeric
    # values from a previous run or a newer template.
    patterns = [
        (r"minSdk(?:Version)?\s*=\s*[\w.]+", f"minSdk = {MIN_SDK}"),
        (r"minSdkVersion\s+[\w.]+", f"minSdkVersion {MIN_SDK}"),
        (r"targetSdk(?:Version)?\s*=\s*[\w.]+", f"targetSdk = {TARGET_SDK}"),
        (r"targetSdkVersion\s+[\w.]+", f"targetSdkVersion {TARGET_SDK}"),
    ]
    for pattern, replacement in patterns:
        text, count = re.subn(pattern, replacement, text)
        if count:
            notes.append(f"{replacement} ({count})")

    if text != original:
        path.write_text(text, encoding="utf-8")
        return "gradle: " + ", ".join(notes)
    return "gradle: nothing matched — CHECK THE TEMPLATE"


def main() -> int:
    app_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()

    manifest = app_dir / "android/app/src/main/AndroidManifest.xml"
    if not manifest.exists():
        raise SystemExit(f"not found: {manifest} (run flutter create first)")
    print(patch_manifest(manifest))

    gradle_candidates = [
        app_dir / "android/app/build.gradle.kts",
        app_dir / "android/app/build.gradle",
    ]
    gradle = next((p for p in gradle_candidates if p.exists()), None)
    if gradle is None:
        raise SystemExit("no android/app/build.gradle[.kts] found")
    print(patch_gradle(gradle))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
