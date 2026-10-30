#!/usr/bin/env python3
"""Patch the Android project that `flutter create` generates.

Run from the `app/` directory after `flutter create` and after the overlay is
copied in. The generated project cannot know about any of this:

1. **Package visibility for TTS engines.** Since Android 11 an app only sees
   packages it declares an interest in. Without a <queries> entry for the
   TTS_SERVICE intent, `TextToSpeech.getEngines()` returns almost nothing.
   The same goes for the dictionary and translate apps a held word goes to.

2. **SDK levels.** minSdk 26 (`onRangeStart`, AudioFocusRequest), targetSdk 36
   (Google Play requirement since 31 August 2026, docs/07 section 7.1).

3. **Reading with the screen off.** A mediaPlayback foreground service and the
   permissions it needs. Without it Android freezes the app seconds after the
   screen turns off and the next sentence is never synthesised.

4. **Open with / Share to TomeVoice** intent filters for document types, and a
   singleTask launch mode so a file opened from another app lands in the
   running reader instead of a second copy of it.

5. **PDF text extraction** via PdfBox-Android (Apache-2.0, GPL-3.0 compatible),
   without BouncyCastle's post-quantum tables, which it drags in and no PDF
   needs.

6. **A stable signing key** when TV_KEYSTORE is set, so each CI build installs
   over the last one instead of requiring an uninstall that wipes the library.
   TV_KEYSTORE names the file; CI decodes it only for the build steps, so it
   need not exist yet when this runs.

7. The launcher label, which `flutter create` sets to the project name.

8. **The app's identity:** applicationId app.tomevoice, labelled "TomeVoice".
   TV_APP_ID and TV_APP_LABEL, when set, name a separate test app instead (CI
   builds app.tomevoice.test, "TomeVoice Test", with variant=test): it installs
   beside the real one with a library of its own, so a risky build never
   touches the reader's books.

9. **Reading from outside the app.** The reading service is a media browser
   (exported, with the MediaBrowserService filter), so the system's resume
   card (Android 11+) and Android Auto can list the books and start one; the
   meta-data names TomeVoice a media app to Android Auto
   (res/xml/automotive_app_desc.xml in the overlay).

Idempotent: running it twice changes nothing the second time.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

# The id Android knows the app by, and its name on the launcher. The id was
# changed once, in 0.6, from the template's app.tomevoice.tomevoice_spike; it
# must never change again, or every install becomes a different app with an
# empty library. TV_APP_ID / TV_APP_LABEL replace both only for the test app.
APPLICATION_ID = "app.tomevoice"
APP_LABEL = "TomeVoice"

MIN_SDK = 26
TARGET_SDK = 36
PDFBOX = 'implementation("com.tom-roush:pdfbox-android:2.0.27.0")'

QUERIES_BLOCK = """    <!-- Required since Android 11 for TextToSpeech.getEngines() to see
         installed engines. -->
    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
        <!-- The dictionary and translate apps a held word or sentence goes
             to (MainActivity processText): invisible without these. -->
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT" />
            <data android:mimeType="text/plain" />
        </intent>
        <intent>
            <action android:name="android.intent.action.TRANSLATE" />
        </intent>
    </queries>
"""

PERMISSIONS = """    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
    <uses-permission android:name="android.permission.USE_BIOMETRIC" />
"""

# Exported for the media browser: System UI binds to it for the resume card,
# Android Auto to list and play the books. ReadAloudService decides who sees
# what (onGetRoot); its other starts are its own notification's, widgets' and
# media buttons'.
SERVICE = """        <service
            android:name=".ReadAloudService"
            android:exported="true"
            android:foregroundServiceType="mediaPlayback">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
"""

# Android Auto: a media app, with the TomeVoice mark on its notifications.
AUTO = """        <meta-data
            android:name="com.google.android.gms.car.application"
            android:resource="@xml/automotive_app_desc" />
        <meta-data
            android:name="com.google.android.gms.car.notification.SmallIcon"
            android:resource="@drawable/ic_stat_tomevoice" />
"""

# The home-screen widgets (Widgets.kt) and the screen that picks a widget's book.
WIDGETS = """        <receiver
            android:name=".PlayerWidget"
            android:exported="true"
            android:label="Now reading">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_player_small_info" />
        </receiver>
        <receiver
            android:name=".PlayerStampWidget"
            android:exported="true"
            android:label="Now reading (stamp)">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_player_stamp_info" />
        </receiver>
        <receiver
            android:name=".PlayerWidgetWide"
            android:exported="true"
            android:label="Now reading (wide)">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_player_wide_info" />
        </receiver>
        <receiver
            android:name=".StreakWidget"
            android:exported="true"
            android:label="Streak">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_streak_small_info" />
        </receiver>
        <receiver
            android:name=".StreakWidgetWide"
            android:exported="true"
            android:label="Streak (wide)">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
            </intent-filter>
            <meta-data
                android:name="android.appwidget.provider"
                android:resource="@xml/widget_streak_wide_info" />
        </receiver>
        <activity
            android:name=".WidgetConfigActivity"
            android:exported="true"
            android:label="Show on the widget"
            android:theme="@android:style/Theme.DeviceDefault.Dialog">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_CONFIGURE" />
            </intent-filter>
        </activity>
"""

# Serves pictures made to share (quote cards) to the app they are shared with.
PROVIDER = """        <provider
            android:name=".ShareProvider"
            android:authorities="${applicationId}.share"
            android:exported="false"
            android:grantUriPermissions="true" />
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


def patch_manifest(path: Path, label: str = APP_LABEL) -> str:
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

    if "com.google.android.gms.car.application" not in text:
        text = text.replace("</application>", AUTO + "    </application>", 1)
        notes.append("Android Auto")

    if ".PlayerWidget" not in text:
        text = text.replace("</application>", WIDGETS + "    </application>", 1)
        notes.append("widgets")

    if ".ShareProvider" not in text:
        text = text.replace("</application>", PROVIDER + "    </application>", 1)
        notes.append("share provider")

    if "android.intent.action.SEND" not in text:
        if "</activity>" not in text:
            raise SystemExit("manifest: no </activity>")
        text = text.replace("</activity>", _filters() + "        </activity>", 1)
        notes.append("open-with filters")

    text, n = re.subn(r'android:launchMode="singleTop"', 'android:launchMode="singleTask"', text)
    if n:
        notes.append("singleTask")

    text, n = re.subn(
        r'(<application\b[^>]*?android:label=")[^"]*(")',
        lambda m: m.group(1) + escape(label, {'"': "&quot;"}) + m.group(2),
        text,
        count=1,
    )
    if n:
        notes.append(f"label {label}")

    path.write_text(text, encoding="utf-8")
    return "manifest: " + (", ".join(notes) if notes else "already patched")


# Native code for the CPU this APK is for (TV_ABIS, set per build in CI),
# stored compressed: about half the download. And no BouncyCastle
# post-quantum data: PdfBox-Android brings the whole provider, whose SIKE and
# Picnic tables (org/bouncycastle/pqc/, 4.1 MB of Java resources, a seventh of
# the APK) no PDF uses. R8 shrinks code, not Java resources like these.
PACKAGING = """

android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
            val keep = (System.getenv("TV_ABIS") ?: "arm64-v8a,armeabi-v7a").split(",")
            excludes += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
                .filter { it !in keep }
                .map { "lib/$it/**" }
        }
        resources {
            excludes += "org/bouncycastle/pqc/**"
        }
    }
}
"""

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


def patch_gradle(path: Path, signing: bool, app_id: str = APPLICATION_ID) -> str:
    text = path.read_text(encoding="utf-8")
    original = text
    notes = []

    # The id Android knows the app by (see APPLICATION_ID). Only the
    # applicationId: the namespace, and so the Kotlin package and class
    # names, stay the same for the test app.
    text, n = re.subn(r'applicationId\s*=\s*"[^"]*"', f'applicationId = "{app_id}"', text)
    if n:
        notes.append(f"applicationId {app_id}")

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

    # Each APK carries native code for its own CPU only: plugins such as
    # sherpa-onnx ship all four, which made the 64-bit APK 101 MB. CI sets
    # TV_ABIS per build. Native libraries are stored compressed: a download
    # of about half the size (Android unpacks them when installing).
    if "TV_ABIS" not in text and path.suffix == ".kts":
        # Excluded at packaging: ndk.abiFilters alone left the plugins' other
        # CPUs in the APK (checked in a CI build).
        text = text.rstrip() + PACKAGING
        notes.append("one CPU per APK, compressed native libraries, no BouncyCastle PQC data")

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

    # Unset or empty: the real app.
    app_id = os.environ.get("TV_APP_ID") or APPLICATION_ID
    label = os.environ.get("TV_APP_LABEL") or APP_LABEL
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", app_id):
        raise SystemExit(f"TV_APP_ID {app_id!r} is not an application id")
    if app_id != APPLICATION_ID:
        print(f"variant: {app_id} ({label}), a separate app beside {APPLICATION_ID}")

    manifest = app_dir / "android/app/src/main/AndroidManifest.xml"
    if not manifest.exists():
        raise SystemExit(f"not found: {manifest} (run flutter create first)")
    print(patch_manifest(manifest, label))

    gradle_candidates = [
        app_dir / "android/app/build.gradle.kts",
        app_dir / "android/app/build.gradle",
    ]
    gradle = next((p for p in gradle_candidates if p.exists()), None)
    if gradle is None:
        raise SystemExit("no android/app/build.gradle[.kts] found")
    # The path is enough: CI names it here and writes the key there only for
    # the two build steps, deleting it straight after. Gradle reads it when it
    # signs, and fails loudly if it is missing then.
    keystore = os.environ.get("TV_KEYSTORE", "")
    signing = bool(keystore)
    if not signing:
        print("gradle: TV_KEYSTORE not set — release APK uses the throwaway debug key")
    elif not Path(keystore).exists():
        print(f"gradle: {keystore} is written just before the build")
    print(patch_gradle(gradle, signing, app_id))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
