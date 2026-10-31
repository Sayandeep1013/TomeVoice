# android_overlay

Our Android sources, kept separately from a generated `android/` directory.

## Why it works this way

There is no local Flutter install ([ADR-016](../../docs/10-decisions-adr.md#adr-016)),
so nobody here can run `flutter create` to produce and commit an `android/` tree. Instead
CI generates the scaffolding on every build and copies this directory over it:

```bash
flutter create --no-pub --platforms=android --project-name tomevoice_spike --org app.tomevoice .
cp -r android_overlay/. android/
python3 ../tools/prepare_android.py .
```

(CI keeps `lib/`, `test/`, `pubspec.yaml` and `pubspec.lock` aside while `flutter create`
runs, puts them back, and fails if it changed any of them.)

Two useful consequences: no generated Gradle boilerplate in version control, and the
project self-heals when the Flutter template changes rather than drifting against a
committed copy from whenever the project started.

The trade is that a template change could silently drop something we depend on, so the
workflow asserts the overlay landed (the "Verify the overlay landed" step in
`.github/workflows/build.yml`: the Kotlin files present, the method channel named, and the
manifest's services, permissions and queries in place) and fails the build if not.

The Kotlin package stays `app.tomevoice.tomevoice_spike`, from the template's project name;
the application id, set by `prepare_android.py`, is `app.tomevoice`.

## What is in here

| Path | Purpose |
|---|---|
| `app/src/main/kotlin/.../ReadingCore.kt` | The cached Flutter engine and what reading needs with or without an activity: one warm `TextToSpeech`, the player, audio focus, the media session's calls |
| `.../MainActivity.kt` | The activity: pickers, the window, prompts, Back; asks `ReadingCore` first |
| `.../OpenActivity.kt` | Where Open with and Share land; hands them to the TomeVoice already open |
| `.../PcmPlayer.kt` | One streaming `AudioTrack` fed PCM16 |
| `.../ReadAloudService.kt` | The `mediaPlayback` foreground service, MediaSession and media browser (resume card, Android Auto) |
| `.../PdfText.kt`, `PdfPages.kt` | A PDF's text (PdfBox-Android) and its pages as pictures (`PdfRenderer`) |
| `.../Ocr.kt` | Scanned pages read by Tesseract, in a data-sync service |
| `.../AudioExport.kt` | Saving a book as audio (AAC in MP4, or MP3) |
| `.../NarrationAudio.kt` | Decoding an EPUB's recorded narration |
| `.../NovelCheckWorker.kt`, `DownloadService.kt`, `SourcesBridge.kt`, `BrowserCheck.kt` | Web novels: the check for new chapters with the app closed, downloads, platform calls, the hidden web view |
| `.../NovelDokushaImport.kt` | Reading a NovelDokusha backup's database |
| `.../LibraryBackup.kt`, `ShareProvider.kt`, `ErrorLog.kt` | Backups, files handed to other apps, Android-side crashes |
| `.../Widgets.kt`, `WidgetConfigActivity.kt` | The home-screen widgets |
| `app/src/main/res/` | Launcher icon, notification and speed icons, widget layouts and previews, `xml/` (widget info, `automotive_app_desc.xml`) |

## What `prepare_android.py` adds

What the generated project cannot know about; the script's own docstring lists each with
its reason. Among them:

- **`<queries>` for `android.intent.action.TTS_SERVICE`** (and `PROCESS_TEXT`). Since
  Android 11, package visibility is restricted and `TextToSpeech.getEngines()` returns
  almost nothing without it.
- **`minSdk 26`, `targetSdk 36`.** `onRangeStart` arrived in API 26; API 36 has been
  required for new Play submissions since 31 August 2026.
- **The application id** `app.tomevoice` and the label (or the test app's, with
  `TV_APP_ID` / `TV_APP_LABEL`), and the signing key when `TV_KEYSTORE` is set.
- **The services, permissions and intent filters**: reading with the screen off, Open with
  and Share, the media browser, battery optimisation, OCR, saving as audio, web-novel
  downloads.
- **Dependencies**: PdfBox-Android (without BouncyCastle's post-quantum tables),
  WorkManager, Tesseract4Android, jump3r; and only the CPU's own native code (`TV_ABIS`),
  stored compressed.
