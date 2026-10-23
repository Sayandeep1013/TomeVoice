#!/usr/bin/env python3
"""Patch the Android project that `flutter create` generates.

Run from the `app/` directory after `flutter create` and after the overlay is
copied in. The generated project cannot know about any of this:

1. **Package visibility for TTS engines.** Since Android 11 an app only sees
   packages it declares an interest in. Without a <queries> entry for the
   TTS_SERVICE intent, `TextToSpeech.getEngines()` returns almost nothing.

2. **SDK levels.** minSdk 26 (`onRangeStart`, AudioFocusRequest), targetSdk 36
   (Google Play requirement since 31 August 2026, docs/07 section 7.1).

3. **Reading with the screen off.** A mediaPlayback foreground service and the
   permissions it needs. Without it Android freezes the app seconds after the
   screen turns off and the next sentence is never synthesised.

4. **Open with / Share to TomeVoice** intent filters for document types, and a
   singleTask launch mode so a file opened from another app lands in the
   running reader instead of a second copy of it.

5. **PDF text extraction** via PdfBox-Android (Apache-2.0, GPL-3.0 compatible).

6. **A stable signing key** when TV_KEYSTORE is set, so each CI build installs
   over the last one instead of requiring an uninstall that wipes the library.

7. The launcher label, which `flutter create` sets to the project name.

Idempotent: running it twice changes nothing the second time.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

MIN_SDK = 26
TARGET_SDK = 36
PDFBOX = 'implementation("com.tom-roush:pdfbox-android:2.0.27.0")'

QUERIES_BLOCK = """    <!-- Required since Android 11 for TextToSpeech.getEngines() to see
         installed engines. -->
    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>
"""

PERMISSIONS = """    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
"""

SERVICE = """        <service
            android:name=".ReadAloudService"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback" />
"""

DOC_MIME_TYPES = [
    "application/pdf",
    "application/epub+zip",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.oasis.opendocument.text",
    "application/rtf",
    "text/rtf",
    "application/x-mobipocket-ebook",
    "application/vnd.amazon.ebook",
    "application/x-fictionbook+xml",
    "text/plain",
    "text/markdown",
    "text/html",
]


def _filters() -> str:
    data = "\n".join(
        f'                <data android:mimeType="{m}" />' for m in DOC_MIME_TYPES
    )
    return f"""            <!-- Open with TomeVoice -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
{data}
            </intent-filter>
            <!-- Share to TomeVoice -->
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
{data}
            </intent-filter>
"""


def patch_manifest(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    notes = []

    if "android.intent.action.TTS_SERVICE" not in text:
        text = text.replace("</manifest>", QUERIES_BLOCK + "</manifest>", 1)
        notes.append("TTS queries")

    if "FOREGROUND_SERVICE_MEDIA_PLAYBACK" not in text:
        text, n = re.subn(r"(<manifest\b[^>]*>\n?)", r"\1" + PERMISSIONS, text, count=1)
        if n != 1:
            raise SystemExit("manifest: no <manifest> tag")
        notes.append("permissions")

    if ".ReadAloudService" not in text:
        if "</application>" not in text:
            raise SystemExit("manifest: no </application>")
        text = text.replace("</application>", SERVICE + "    </application>", 1)
        notes.append("service")

    if "android.intent.action.SEND" not in text:
        if "</activity>" not in text:
            raise SystemExit("manifest: no </activity>")
        text = text.replace("</activity>", _filters() + "        </activity>", 1)
        notes.append("open-with filters")

    text, n = re.subn(r'android:launchMode="singleTop"', 'android:launchMode="singleTask"', text)
    if n:
        notes.append("singleTask")

    text, n = re.subn(
        r'(<application\b[^>]*?android:label=")[^"]*(")', r"\1TomeVoice\2", text, count=1
    )
    if n:
        notes.append("label")

    path.write_text(text, encoding="utf-8")
    return "manifest: " + (", ".join(notes) if notes else "already patched")


APPLICATION_ID = "app.tomevoice"

SIGNING_BLOCK = """    signingConfigs {
        create("tomevoice") {
            storeFile = file(System.getenv("TV_KEYSTORE"))
            storePassword = System.getenv("TV_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("TV_KEY_ALIAS") ?: "tomevoice"
            keyPassword = System.getenv("TV_KEYSTORE_PASSWORD")
            storeType = "pkcs12"
        }
    }

"""


def patch_gradle(path: Path, signing: bool) -> str:
    text = path.read_text(encoding="utf-8")
    original = text
    notes = []

    # The id Android knows the app by. Changed once, in 0.6, from the
    # template's app.tomevoice.tomevoice_spike; it must never change again,
    # or every install becomes a different app with an empty library.
    text, n = re.subn(r'applicationId\s*=\s*"[^"]*"', f'applicationId = "{APPLICATION_ID}"', text)
    if n:
        notes.append(f"applicationId {APPLICATION_ID}")

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

    if PDFBOX not in text:
        if path.suffix == ".kts":
            text = text.rstrip() + f"\n\ndependencies {{\n    {PDFBOX}\n}}\n"
        else:
            text = text.rstrip() + "\n\ndependencies {\n    implementation 'com.tom-roush:pdfbox-android:2.0.27.0'\n}\n"
        notes.append("pdfbox")

    if 'proguardFiles("proguard-rules.pro")' not in text and path.suffix == ".kts":
        text, n = re.subn(
            r"(\n(\s*)release \{\n)",
            lambda m: m.group(1) + m.group(2) + '    proguardFiles("proguard-rules.pro")\n',
            text,
            count=1,
        )
        if n:
            notes.append("proguard rules")

    if signing and 'create("tomevoice")' not in text:
        if path.suffix != ".kts" or "    buildTypes {" not in text:
            raise SystemExit("gradle: cannot place signingConfigs — CHECK THE TEMPLATE")
        text = text.replace("    buildTypes {", SIGNING_BLOCK + "    buildTypes {", 1)
        text, n = re.subn(
            r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
            'signingConfig = signingConfigs.getByName("tomevoice")',
            text,
        )
        if n != 1:
            raise SystemExit("gradle: release signingConfig line not found — CHECK THE TEMPLATE")
        notes.append("release signed with the TomeVoice key")

    if text != original:
        path.write_text(text, encoding="utf-8")
        return "gradle: " + ", ".join(notes)
    if not notes:
        return "gradle: nothing matched — CHECK THE TEMPLATE"
    return "gradle: already patched"


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
    keystore = os.environ.get("TV_KEYSTORE", "")
    signing = bool(keystore) and Path(keystore).exists()
    if not signing:
        print("gradle: TV_KEYSTORE not set — release APK uses the throwaway debug key")
    print(patch_gradle(gradle, signing))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
