# 18 — Play Store Audit

> **No Play build is planned for now** (the developer's decision, 31 October 2026).
> This audit is kept for the day that changes. It was made on 2026-10-29, against 1.2;
> the rows below have been brought up to 1.4.0 where the app changed, but the features
> added in 1.3.0 and 1.4.0 (sync, OPDS catalogues, OCR, saving as audio, signing in to a
> source's site, reading shared links) have **not** been audited against Play's policies.

**As of 2026-10-29.** What the GitHub build has that a Google Play build cannot ship,
why, and what the Play build does instead. Policies were read from Google's own pages
on that date. Re-read them before the first upload: they change.

The plan: the open-source GitHub build stays as it is. A second build, for Play only,
leaves out everything in §1, changes About (§3), and gets its updates from Play. Nothing
is removed from the GitHub build for Play's sake.

---

## 1. Must go from the Play build

| # | Feature | Where in the code | Policy | Why |
|---|---|---|---|---|
| 1 | **Web novels: Browse, Sources, novel pages, chapter Updates, the site browser check** | `browse_screen`, `sources_screen`, `novel_screen`, `web_reader`, `updates`, `updates_screen`, `browser_check` (+ `BrowserCheck.kt`), `sources/` (QuickJS + LNReader plugins), entry points in `home_shell`, `library_screen`, `settings_screen`; since 1.4.0 also `background_check` (+ `NovelCheckWorker.kt`), `download_queue` and `auto_download` (+ `DownloadService.kt`), `novel_move`, `read_marks`, the web novel's EPUB export (`epub_export`), the NovelUpdates link (`novel_updates`) and `SourcesBridge.kt` | [Intellectual Property](https://support.google.com/googleplay/android-developer/answer/9888072): "We don't allow apps that induce or encourage copyright infringement"; [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379): no accessing a service "in a manner that violates its terms of service" | LNReader's list is ~300 sites, many of them aggregators of translations with no licence to publish. Scraping them is against most sites' terms, and passing their Cloudflare checks makes that look worse. The plugins are JavaScript run in QuickJS, so the rule against downloading executable code has an interpreter exception, but that does not cure the rest. Apps of this kind (Tachiyomi/Mihon, LNReader itself) are not on Play for this reason. |
| 2 | **NovelDokusha import** | `noveldokusha_import.dart`, `NovelDokushaImport.kt`, Settings | Same as 1 | It brings in a web-novel library tied to its sources. Without sources it is half a feature. |
| 3 | **Self-update from GitHub** | `app_update.dart`, `update_flow.dart`, `installApk` in `MainActivity.kt`, "Tell me about new versions", About > Check for updates / Releases | [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379): an app "may not modify, replace, or update itself using any method other than Google Play's update mechanism" | Play updates the app. The Play In-App Updates API can prompt for a new version if wanted. |
| 4 | **`REQUEST_INSTALL_PACKAGES` permission** | `tools/prepare_android.py` (`PERMISSIONS`) | [Use of the REQUEST_INSTALL_PACKAGES permission](https://support.google.com/googleplay/android-developer/answer/12085295) | Only allowed when installing packages is core to the app (browsers, file managers, backup...). It exists only for the self-updater. |
| 5 | **Support by UPI** | Gone from the app: the QR and its sheet were removed in 1.2.2, the About row and the platform code (the `upi` query, `payUpi`, `saveImage`) in 1.3.0. Nothing left to leave out | [Payments](https://support.google.com/googleplay/android-developer/answer/9858738): "apps may not lead users to a payment method other than Google Play's billing system", including "buttons, links, messaging" | Still the rule if support comes back. The exceptions are physical goods, peer-to-peer payments and *tax-exempt* donations; money to the developer is none of them. If support is wanted on Play: a "tip" in-app product through Play Billing. |
| 6 | **Natural voices whose recordings are not open**: in 1.4.0, 38 non-commercial, 2 with no licence and 24 with an unclear one, Alan, Lessac and Ryan among them | each voice's `licence.use` in `app/assets/voices/catalog.json` (`tools/voice_catalog.py`) | Licences, not a Play rule (see §2) | Alan's dataset is "All Rights Reserved" (Mycroft AI), Lessac's is a research-only licence, Ryan's is CC BY-NC-SA 4.0 (non-commercial). |
| 7 | **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`** (Settings > Listening > Keep reading with the screen off: Android's one-tap "let it run in the background?") | `tools/prepare_android.py` (`BATTERY`), `openBatterySettings` in `ReadingCore.kt` | [Use of the REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission](https://developer.android.com/training/monitoring-device-state/doze-standby#exemption-cases) and Play's review of it | Play allows it only when the app's core function cannot work otherwise; a reading app with a mediaPlayback foreground service is not an accepted case. The Play build leaves the permission out and opens the list of apps (`ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`, no permission needed) instead: drop the request from `openBatterySettings` too, since without the permission Android's question opens and closes at once. The dontkillmyapp.com line can stay. |

## 2. The natural voices: where they come from

Natural voices are [Piper](https://github.com/rhasspy/piper) models (VITS, ONNX), plus
Kokoro and Kitten since 1.4.0, made into speech on the phone by sherpa-onnx. Nothing is
in the APK: a voice is downloaded when the reader picks it, from sherpa-onnx's GitHub
releases (`k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-<id>.tar.bz2`). Its
preview is a sample from Hugging Face (Piper's own in `rhasspy/piper-voices`, or
sherpa-onnx's). The models are data, not code, so downloading them is allowed on Play.

Each voice carries the licence of the recordings it was trained on, read by
`tools/voice_catalog.py` from each voice's `MODEL_CARD` in `rhasspy/piper-voices`, and
sorted into five kinds ([06 §6.4](06-voice-catalog-and-licensing.md#64-the-per-voice-trap)).
In 1.4.0 the catalogue's 217 entries (180 Piper voices, 29 Kokoro and 8 Kitten speakers)
come to 61 free for any use, 92 free on conditions, 38 non-commercial, 2 with no licence
granted and 24 unclear. A Play build keeps the first two kinds and leaves out the rest.

The first seven voices (1.0.0) show the kinds:

| Voice | Trained on | Licence | Play build |
|---|---|---|---|
| Kristin | LibriVox | Public domain | Keep |
| Norman | LibriVox | Public domain | Keep |
| Cori | LibriVox | Public domain | Keep |
| Jenny (Dioco) | Jenny (Dioco) dataset | Commercial use allowed; **credit the voice as "Jenny (Dioco)"**, which the catalogue now does | Keep |
| Alan | Mycroft mimic3 `apope` | "Copyright 2022 Mycroft AI, All Rights Reserved". No licence granted | **Remove** |
| Lessac | Blizzard 2013, Lessac Technologies | Research licence | **Remove** |
| Ryan | RyanSpeech | CC BY-NC-SA 4.0 | **Remove** |

**The GitHub build keeps every voice** (the developer's decision, 2026-10-29), each with
its licence shown; only a Play build would leave voices out. Several open voices in the
catalogue are high quality, so a Play build would not be without HD voices; check each
model card before relying on one.

The phone's own voices (Google, Samsung and other TTS engines) are the phone's, used
through Android's TextToSpeech API. Nothing to change.

## 3. About in the Play build

- No "Check for updates", "Releases" or "Tell me about new versions". Play updates it.
- No Support section (there is none now; see §1.5), unless a Play Billing tip is added.
- "Source code" can stay: GPL-3.0 on Play is fine. But a reviewer once rejected an app
  for a GitHub link whose page explained donations, so keep any donation details off the
  README's first screen, or drop the link.
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
- **Android Auto.** The app declares itself a media app for Auto
  (`com.google.android.gms.car.application`, `res/xml/automotive_app_desc.xml`).
  On Play it shows in Auto only after opting in under Release > Advanced settings >
  Form factors and passing Google's review against the
  [car app quality guidelines](https://developer.android.com/docs/quality-guidelines/car-app-quality)
  (media apps: a browse tree, playback controls, no distraction). The GitHub APK needs
  Android Auto's developer setting **Unknown sources** to show at all.

## 6. How the Play build is made (proposed)

1. A compile-time flag: `--dart-define=TV_STORE=play`, read as
   `const playBuild = bool.fromEnvironment(...)`. Screens hide entry points behind it,
   and Dart tree-shakes the code they reach.
2. A `tools/prepare_play.py` step in CI, for the Play job only: drop `flutter_qjs`
   from `pubspec.yaml` and swap `sources/qjs_runtime.dart` for a stub, so the QuickJS
   library is not in the bundle at all; leave out `REQUEST_INSTALL_PACKAGES` and
   `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; leave out the voices whose `licence.use` is
   `noncommercial`, `restricted` or `unclear`. (None of this exists yet.)
3. A `play` job in `.github/workflows/build.yml` that builds `appbundle --release`
   with these, beside the existing APK.

**Decisions for the developer before building it:**

- **Application ID.** The same `app.tomevoice` (one app; Play can update a GitHub
  install only if Play App Signing uses the same key) or `app.tomevoice.play` (both can
  be installed side by side, with separate libraries).
- **Support on Play.** None, or a Play Billing tip.
- **Voices.** Which open voices to offer, and whether Kokoro (Apache-2.0) stays.
