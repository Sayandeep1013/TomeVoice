# TomeVoice: a step back (2026-10-23, v0.4.0)

A look at the whole app after three days of building, written to steer what comes next.
The checkpoint for resuming the work is [16-session-handoff.md](16-session-handoff.md).

## What it is now

An Android reader that reads aloud: local books (EPUB, PDF, DOCX, ODT, MOBI/AZW3, FB2, RTF,
HTML, Markdown, TXT) and web novels from about 300 sites, with the spoken word highlighted
and the voice shaped by TomeVoice's own audio pipeline. About 22,000 lines (app 14,800 Dart,
document model 4,200, audio 1,500, Android 1,600), 50 app tests plus 63 package tests, built
and signed in CI.

## What is genuinely strong

- **The voice pipeline is the moat.** Synthesising each sentence to PCM, then setting word
  gaps, pauses and loudness itself, is what no other TTS reader does. It also makes playback
  gapless and the highlighting accurate. Most competitors only call `speak()`.
- **Breadth without owning scrapers.** Running LNReader's real plugins (real cheerio, not a
  re-implementation) gives 300 maintained sources for the cost of a JS engine and a
  shim. When a site changes, LNReader's community fixes the plugin and TomeVoice picks it up.
- **Cloudflare is handled the robust way.** A page challenged for the app's own client is
  read through a hidden WebView. That was found by testing on the real phone's network;
  the PC never saw the problem.
- **One design system.** Type, spacing, corners, motion and five palettes all come from one
  place, so new screens look finished by default.

## Where it is weak or at risk (most important first)

1. **The application id is still `app.tomevoice.tomevoice_spike`.** Android treats a new
   id as a different app, so changing it later forces every user to reinstall and lose their
   library. It is cheap now and expensive after the first real users. **Do this before
   sharing the APK more widely.**
2. **No backup of the TomeVoice library.** A new phone or a reinstall loses progress,
   categories, downloads and covers. NovelDokusha users can come *in*, but nobody can get
   *out*. An export/import zip (`library.json`, cursors, `sources/`) is small work and stops
   that loss.
3. **Background work does not exist yet.** New chapters are checked only when the app
   opens, and a "Download all" stops if Android kills the app. A WorkManager job with a
   notification is needed for both updates and downloads.
4. **Testing stops at the edge of Flutter.** QuickJS, the WebView fallback, the Kotlin
   import and first-run seeding are only exercised by hand on one phone (and the seeding
   could not be, without wiping it). An Android emulator job in CI running a few Maestro
   flows (fresh install, add source, search, listen) would cover the risky seams.
5. **Very long web novels.** Shadow Slave has more than 3,000 chapters. The reader builds one
   layout over every downloaded chapter and rebuilds it when more arrive. That is fine at tens
   of chapters; it needs measuring at hundreds, and probably a window of chapters around the
   cursor instead.
6. **The voices are the phone's.** On many phones the system TTS sounds robotic, and that is
   the first impression of a read-aloud app. Offline neural voices (Piper / sherpa-onnx,
   already planned and GPL-compatible) are the biggest single quality lift.
7. **Legal posture changed on purpose.** LNReader's list is now built in and two web novels
   are pre-added. That is the developer's call (ADR-019), and it is documented. Keep
   the app free of any bundled site content, and keep the README free of copyrighted covers.
8. **Big files.** `reader_screen.dart` (1,560 lines), `library_screen.dart` (1,130) and
   `library_store.dart` (1,000) now carry several responsibilities each. Split them before
   the next feature lands in them.
9. **Smaller UX debts:**
   - the player bar fills half the screen in landscape
   - the same novel can exist twice under two sources, and there is no "migrate source"
     as in Mihon
   - TalkBack is untested

## What I would do next, in order

1. Rename the application id (one release, documented as "reinstall once").
2. Library backup and restore.
3. Background updates and a download queue (WorkManager + notification).
4. Emulator integration tests in CI, starting with the fresh-install shelf.
5. Neural voices.
6. Long-novel layout windowing, source migration, file splits.
