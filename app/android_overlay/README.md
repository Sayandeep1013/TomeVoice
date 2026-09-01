# android_overlay

Our Android sources, kept separately from a generated `android/` directory.

## Why it works this way

There is no local Flutter install ([ADR-016](../../docs/10-decisions-adr.md#adr-016)),
so nobody here can run `flutter create` to produce and commit an `android/` tree. Instead
CI generates the scaffolding on every build and copies this directory over it:

```bash
flutter create --platforms=android --project-name tomevoice_spike --org app.tomevoice .
cp -r android_overlay/. android/
python3 ../tools/prepare_android.py .
```

Two useful consequences: no generated Gradle boilerplate in version control, and the
project self-heals when the Flutter template changes rather than drifting against a
committed copy from whenever the project started.

The trade is that a template change could silently drop something we depend on, so the
workflow asserts the overlay landed — MainActivity present, method channel name present,
manifest `<queries>` present, SDK levels patched — and fails the build if not.

## What is in here

| Path | Purpose |
|---|---|
| `app/src/main/kotlin/app/tomevoice/tomevoice_spike/MainActivity.kt` | The TTS adapter. Overwrites the generated stub at the same path. |

## What `prepare_android.py` adds

Two things the generated project cannot know about:

- **`<queries>` for `android.intent.action.TTS_SERVICE`.** Since Android 11, package
  visibility is restricted and `TextToSpeech.getEngines()` returns almost nothing without
  it. The spike exists to compare engines, so this is load-bearing rather than cosmetic.
- **`minSdk 26`, `targetSdk 36`.** `onRangeStart` arrived in API 26 and the spike depends
  on it; API 36 has been required for new Play submissions since 31 August 2026.
