# 18 — Play Store Audit

**As of 2026-10-29.** What the GitHub build has that a Google Play build cannot ship,
why, and what the Play build does instead. Policies were read from Google's own pages
on that date. Re-read them before the first upload: they change.

The plan: the open-source GitHub build stays as it is. A second build, for Play only,
leaves out everything in §1, changes About (§3), and gets its updates from Play.

---

## 1. Must go from the Play build

| # | Feature | Where in the code | Policy | Why |
|---|---|---|---|---|
| 1 | **Web novels: Browse, Sources, novel pages, chapter Updates, the site browser check** | `browse_screen`, `sources_screen`, `novel_screen`, `web_reader`, `updates`, `updates_screen`, `browser_check` (+ `BrowserCheck.kt`), `sources/` (QuickJS + LNReader plugins), entry points in `home_shell`, `library_screen`, `settings_screen` | [Intellectual Property](https://support.google.com/googleplay/android-developer/answer/9888072): "We don't allow apps that induce or encourage copyright infringement"; [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379): no accessing a service "in a manner that violates its terms of service" | LNReader's list is ~300 sites, many of them aggregators of translations with no licence to publish. Scraping them is against most sites' terms, and passing their Cloudflare checks makes that look worse. The plugins are JavaScript run in QuickJS, so the rule against downloading executable code has an interpreter exception, but that does not cure the rest. Apps of this kind (Tachiyomi/Mihon, LNReader itself) are not on Play for this reason. |
| 2 | **NovelDokusha import** | `noveldokusha_import.dart`, `NovelDokushaImport.kt`, Settings | Same as 1 | It brings in a web-novel library tied to its sources. Without sources it is half a feature. |
| 3 | **Self-update from GitHub** | `app_update.dart`, `update_flow.dart`, `installApk` in `MainActivity.kt`, "Tell me about new versions", About > Check for updates / Releases | [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379): an app "may not modify, replace, or update itself using any method other than Google Play's update mechanism" | Play updates the app. The Play In-App Updates API can prompt for a new version if wanted. |
| 4 | **`REQUEST_INSTALL_PACKAGES` permission** | `tools/prepare_android.py` (`PERMISSIONS`) | [Use of the REQUEST_INSTALL_PACKAGES permission](https://support.google.com/googleplay/android-developer/answer/12085295) | Only allowed when installing packages is core to the app (browsers, file managers, backup...). It exists only for the self-updater. |
| 5 | **Support by UPI (QR, Pay with UPI, UPI ID)** | `support.dart`, `payUpi`/`saveImage` in `MainActivity.kt`, the `upi` query in the manifest | [Payments](https://support.google.com/googleplay/android-developer/answer/9858738): "apps may not lead users to a payment method other than Google Play's billing system", including "buttons, links, messaging" | The exceptions are physical goods, peer-to-peer payments and *tax-exempt* donations. Money to the developer is none of them. If support is wanted on Play: a "tip" in-app product through Play Billing. |
| 6 | **Three natural voices: Alan, Lessac, Ryan** | `neuralVoices` in `neural_voices.dart` | Licences, not a Play rule (see §2) | Alan's dataset is "All Rights Reserved" (Mycroft AI), Lessac's is a research-only licence, Ryan's is CC BY-NC-SA 4.0 (non-commercial). |

## 2. The natural voices: where they come from

Natural voices are [Piper](https://github.com/rhasspy/piper) models (VITS, ONNX), made
into speech on the phone by sherpa-onnx. Nothing is in the APK: a voice is downloaded
when the reader picks it, from sherpa-onnx's GitHub releases
(`k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-<id>.tar.bz2`). Its
preview is Piper's own sample from Hugging Face (`rhasspy/piper-voices`). The models are
data, not code, so downloading them is allowed on Play.

Each voice carries the licence of the recordings it was trained on (each voice's
`MODEL_CARD` in `rhasspy/piper-voices`, read 2026-10-29):

| Voice | Trained on | Licence | Play build |
|---|---|---|---|
| Kristin | LibriVox | Public domain | Keep |
| Norman | LibriVox | Public domain | Keep |
| Cori | LibriVox | Public domain | Keep |
| Jenny | Jenny (Dioco) dataset | Commercial use allowed. **Attribution required:** call the voice "Jenny (Dioco)" where practical | Keep, rename to "Jenny (Dioco)" or credit it on the voice screen |
| Alan | Mycroft mimic3 `apope` | "Copyright 2022 Mycroft AI, All Rights Reserved". No licence granted | **Remove** |
| Lessac (HD) | Blizzard 2013, Lessac Technologies | Research licence | **Remove** |
| Ryan (HD) | RyanSpeech | CC BY-NC-SA 4.0 | **Remove** |

**The GitHub build keeps all seven** (the developer's decision, 2026-10-29); only the
Play build leaves these three out.

Removing Lessac and Ryan leaves no HD voice. Piper has replacements on open licences,
for example `en_US-libritts_r-medium` (LibriTTS-R, CC BY 4.0). Check each model card
before adding one.

The phone's own voices (Google, Samsung and other TTS engines) are the phone's, used
through Android's TextToSpeech API. Nothing to change.

## 3. About in the Play build

- No "Check for updates", "Releases" or "Tell me about new versions". Play updates it.
- No Support section (see §1.5), unless a Play Billing tip is added.
- "Source code" can stay: GPL-3.0 on Play is fine. But a reviewer once rejected an app
  for a GitHub link whose page explained donations. Keep the UPI QR off the README's
  first screen (a separate SUPPORT.md or the releases page), or drop the link.
- Text: "Reads EPUB, PDF, Word, MOBI and more aloud..." already avoids web novels.

## 4. Fine as it is

Local books (all formats, Open with/Share to), the starter book (*Pride and Prejudice*,
public domain), phone voices, natural voices from §2's keep list, pages and the curl,
secret shelves (biometric, FLAG_SECURE), widgets, backups, stats, reading rules,
bookmarks, sleep timer, the media notification, fonts (OFL), and the GPL-3.0 licence
(we hold the copyright, so publishing on Play is allowed).

## 5. Play Console requirements (not code)

- **Foreground service declaration.** `FOREGROUND_SERVICE_MEDIA_PLAYBACK`: declare the
  mediaPlayback type in App content, with a short video of reading with the screen off.
- **Privacy policy URL**, required for every app. TomeVoice collects nothing; the page
  says so and names the downloads it makes (voices from GitHub, previews from Hugging
  Face).
- **Data safety form:** no data collected or shared.
- **Content rating** questionnaire; target audience 13+ or 18+ (users bring their own
  books).
- **New personal developer accounts** must run a closed test with at least 12 testers
  for 14 days before production access.
- **16 KB page size.** Apps targeting Android 15+ must have their native libraries
  aligned for 16 KB pages. Check sherpa-onnx's `.so` files in the release bundle
  (`zipalign -c -P 16 -v 4`).
- **Upload an AAB**, not an APK, signed with an upload key and Play App Signing.

## 6. How the Play build is made (proposed)

1. A compile-time flag: `--dart-define=TV_STORE=play`, read as
   `const playBuild = bool.fromEnvironment(...)`. Screens hide entry points behind it,
   and Dart tree-shakes the code they reach.
2. A `tools/prepare_play.py` step in CI, for the Play job only: drop `flutter_qjs`
   from `pubspec.yaml` and swap `sources/qjs_runtime.dart` for a stub, so the QuickJS
   library is not in the bundle at all; leave out `REQUEST_INSTALL_PACKAGES` and the
   `upi` query; take Alan, Lessac and Ryan out of `neuralVoices`.
3. A `play` job in `.github/workflows/build.yml` that builds `appbundle --release`
   with these, beside the existing APK.

**Decisions for the developer before building it:**

- **Application ID.** The same `app.tomevoice` (one app; Play can update a GitHub
  install only if Play App Signing uses the same key) or `app.tomevoice.play` (both can
  be installed side by side, with separate libraries).
- **Support on Play.** None, or a Play Billing tip.
- **HD voices.** Leave the Play build without them, or add replacements on open
  licences first.
