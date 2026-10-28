# 16 — Session Handoff

**As of 2026-10-28.** Everything needed to pick this up cold.

---

## 0+++. Checkpoint (2026-10-28): a tap puts the bars away (1.1.1)

Branch `hide-bars-on-tap`, released as **1.1.1**. Asked for by readers who read by
scrolling and want the page alone.

- **A tap on the scrolling text folds the top bar and the player away**
  (`_scrollBars`, `_fold`, `_tapForBars` in `reader_screen.dart`); another brings them
  back. The paragraphs take no tap of their own (a tap used to send the voice there and
  was removed), so the tap is free; pictures keep theirs, and long-press is unchanged.
- **A tap that stops a fling is ignored:** the scroll moved within 150 ms of the
  pointer going down (`_lastMove`, set on every `ScrollUpdateNotification`).
- The bars fold into their edges (`AnimatedAlign` heightFactor) and the text grows into
  their place; on a phone on its side the docked player slides away (`_overBar(shownBy:)`).
  A PDF's real pages keep the bars. Switching scroll/pages shows them again. Snacks
  sit at the foot while the bars are away (`_barLift` is 0).
- Pages already did this with a tap in the middle (`_chrome`).
- **Verified on the phone by the user** (scroll mode); CI analyze + tests passed.

## 0++. Checkpoint (2026-10-27, evening): phone voices as Google plays them (1.1)

Branch `phone-voices-and-language`, released as **1.1** (1.1.0).

- **Why Google's Bengali voice sounded worse in TomeVoice than in Google's settings.**
  Same voice name (`bn-in-x-bnd-local`), same downloaded pack, but logcat
  (`GoogleTTSServiceImpl`: "TTS dispatch") showed TomeVoice's sentences going to
  `bn-in-x-bnd-lstm-embedded` and Google's sample to `...-seanet-embedded`. The cause is
  pitch: any `setPitch` but 1.0 makes Google use the older lstm model, for every language
  (proved in Android's own TTS settings with `settings put secure tts_default_pitch`,
  restarting Settings so it rereads it). Speech rate does not. The reader had -7.4 st set,
  shared by every voice. See docs/05 §5.2.
- **Pitch is each voice's own** (`ListeningPrefs.pitchByVoice`, `settingsFor(voice)`),
  0 unless set; the old shared pitch is dropped on load. The dialogue voice gets its own
  (`PlaybackScheduler.pitchOf`, `speakWithDialogue(dialoguePitch:)`). Natural voices never
  took pitch, so their Fine-tune has no slider.
- **A web novel's language is its chapters' script** (`webNovelBook` ->
  `withResolvedLanguage`; with no chapter fetched, the title and summary). Source labels
  the app does not know (`languageCodeOf`) are null, not English. `loadLayout` brings the
  library entry's language into line.
- **A language's usual voice must speak it** (`ListenController.voiceName`/`chooseVoice`).
- **Google's `xx-YY-language` alias is hidden** where the region lists its speakers
  (`VoiceCatalog._withoutAliases`), unless it is the voice in use.
- **Debugging Google TTS on the phone:** `adb logcat | grep -E "Synthesis request|TTS dispatch"`
  names the model each sentence is read with.

## 0+. Checkpoint (2026-10-27): reading without the voice, motion part two

Branch `reader-mode-and-motion` (not merged or released yet).

- **A novel's chapter order is kept** (`ListeningPrefs.newestFirstByNovel`, and
  `newestFirst` for novels not turned yet). It was the page's own state.
- **Natural voices: priority by urgency** (`neural_voices.dart`). 1.0.7 lowered every
  sentence to nice 10, the first after Play too, and set it on whichever Dart VM pool
  thread ran the worker, which kept it for later isolates. Now the scheduler marks a
  sentence urgent when less than 3 s is queued. The worker sets its own thread and the
  ONNX Runtime threads (found by diffing `/proc/self/task` around the engine's creation)
  to nice 0 for it, or 10 when ahead, and gives the pool thread back at 0. The reader
  loads the voice and runs it once, unheard, 1.2 s after opening (`NeuralEngine.warm`).
  Logcat (`flutter` tag) says when the voice runs dry and how long the last sentence
  took. **Not reproduced:** the report was a lag "for some time" on a Snapdragon 8 Gen 5
  that the developer's 7s Gen 3 does not show; running sherpa-onnx's own CLI on the
  phone was not allowed, so the cause is not measured. Ask for that phone's logcat.
- **The place follows the reader** (`_placeFromEyes`, `_onPage`). With nothing read
  aloud, a scroll or a turned page moves the place to the sentence at the top of what is
  read (a line 12% down); while listening (or paused) a scroll is still a look around.
  The wash (`_marked`) is off once the reader reads on, and back with Play or a jump.
- **Pages** (`paged_view.dart`, `ListeningPrefs.pages`): a chapter is cut into pages of
  whole lines when reached, measured and painted with the same `TextPainter`s (so the
  cut lines are exact), with the sentence and word washed from `getBoxesForSelection`.
  The place is a sentence, not a page. The row of pages is the last page of the chapter
  before, this chapter's and the first of the next; settling on an edge moves chapter
  by a new `PageController` keyed into a new `PageView` (a jump on the old one showed
  the wrong page for a frame). Neighbouring chapters are cut 60 ms apart after a page
  settles. Taps: left 28% back, right 28% on, the middle shows the top bar and player
  over the page. Volume keys are caught in `MainActivity.dispatchKeyEvent` only while
  `volumeKeysTurnPages` is on (pages, nothing playing).
- **Also:** Back to where you were (after Contents or a search, while reading), indented
  paragraphs (`indentedAt`, a placeholder span 1.6 em wide, offsets shifted by one), full
  screen (`immersiveSticky`), Aa in the reader (the sheet's Read tab; the old tune button
  went, the player's voice and speed chips open the same sheet), and a change of size or
  font keeps the paragraph at the top in place (`_keepAnchor`).
- **Reader motion:** the web-novel reader keeps the page up until the next is ready
  (the wait shows after 250 ms); `BookLoader` waits for the route's slide before the
  reader's first frame and fades it in; Now Playing puts the last sentence back where it
  was when its window is set out afresh; the player's chapter name rises, and its bar
  starts a new chapter at once.
- **Motion, the rest of the app** (merged from a parallel pass): place saves bump
  `LibraryStore.placeChanges`, not `changes`, so the shelf, History, Updates and a
  novel's page no longer re-read everything behind the reader every 1.5 s; screens
  covered by another catch up when shown again (`WhenShown` in `ui.dart`).
  `downloadedChapters` is cached per novel (it listed thousands of files on the UI
  thread). The app's colour follows a new book once the reader closes. The glow draws on
  a display frame 26 ms after the last (a 33 ms timer beat against 60/90/120 Hz). Shelves
  start on the default category, tiles are keyed by book, sort and view changes fade, a
  far category jumps with a fade, the dock has no blur. Browse keeps the old feed until
  the new one arrives. Updates, History, Saved, Sources and Categories fade and fold.
  Browse, Updates and History build on first visit. PDF pages fade in. The book page
  waits for its slide before its chapters. Sheets and dialogs use `sheetMotion`;
  `Motion.follow` (360 ms) and `Motion.travel` (520 ms) replace hard-coded glides.
  Left: a Saved group's header still vanishes after its last row goes, and Browse's
  "install sources" state can flash for a frame (gating it broke a test sharing `Net`).
- **Later the same day, from the developer's and readers' feedback:**
  - **Curl** (`page_curl.dart`, now the default `pageTurn`): a flat fold on the line
    halfway between the held corner and where it is. The leaf is clipped to the hinge
    side, the folded part is the leaf mirrored across the fold (`_reflection`), and
    shadows fall along the fold and from the flap. A turn back is the turn on from the
    item before, run the other way. Leaves are the page widgets themselves, so the text
    stays sharp. Verified on the phone frame by frame (screenrecord).
  - **Spread**: wider than 600 and wider than tall gives two pages, cut at half the
    width; the right leaf turns over the spine, and its back is the next left page
    (drawn through reflection after a spine mirror, so it lands the right way round).
    The crease (`Crease`) is in the page tone's ink, black on dark pages.
  - **PDF real pages** turn the same way when Pages is on (`PdfPagesView.turn`), each
    leaf the PDF's own page shape.
  - **Page tones** (`page_tone.dart`): app, Ink, Papyrus, Dusk. They apply to the page
    only (`toned()` overrides the accent through `TintScope` and the text colour), and
    the status bar icons follow (`AnnotatedRegion`).
  - **Online voices**: lines with no letter or digit in any script are skipped (a Bengali
    book's "।।।" dividers sent to Google's online voice timed out with code -7, Android's
    network timeout). A network failure is retried twice before it counts, and the stop
    message says the voice needs the internet.
  - **Voice search** in the voice picker: languages and the voices of every language.
  - **Reading on after leaving** (`listening_session.dart`, `prefs.keepReading`, on by
    default): `BackgroundReading` adopts the reader's scheduler on Back (only when the
    route pops, via PopScope) and keeps the place, card, sleep, stats, focus and a web
    novel's next chapters. Reopening the book takes the scheduler back
    (`takeBack`). `PlaybackScheduler.beforePlay` stops it before anything else plays,
    and an idle scheduler no longer stops the stream when disposed.
    `readingScheduler()` builds the scheduler for the reader and the background alike.
- **1.0.8 released** (PR #14). **Then, for 1.0.9:** in pages the pills (Back to reading,
  the way back, search matches) show only with the bars. Bookmarks from the top bar's
  button (Contents moved to the title, with a chevron): the page, a spread's two pages, a
  PDF's page, or the paragraph read; a ribbon in the page's corner or beside the
  paragraph; hold the button for the list (`_openBookmarks`). A page owns its sentences up
  to the next page's first (`_endOf`), so a bookmark is on one page. A jump while paused
  keeps the way back. `MarkStore.reset()` between widget tests: a save inside one test's
  fake clock left the write queue waiting and every later save timed out.
- **Local checks:** a scratch Flutter (3.47.8) at `D:/tvchk/flutter` (short path: the
  SDK's own files pass Windows' path limit under the temp folder). `backup_test`'s
  "paths are pointed..." fails on Windows only (backslashes in JSON); CI is Linux.
- **Not verified on the phone yet:** all of the above.


## 0. Checkpoint (2026-10-24, night): 1.0.1 released

**1.0.0 and 1.0.1 are released** (1.0.1 is Latest). 1.0.1 added widening a quote and a
note on it (`quote_sheet.dart`), Saved on each book's and novel's page
(`BookSavedSection`), hearing a natural voice's Piper sample before downloading it
(`NeuralVoice.sampleUrl`, native `playUrl`), and the fixes from three audits (security,
bugs, UI). **Installing an update from inside the app was verified on the phone,
1.0.0 to 1.0.1**: the offer, the download, Android's one-time "Allow from this source",
the installer, a Play Protect scan ("looks safe"), and the app reopening on 1.0.1 with
the library intact.

- **New safeguards:** user data files are written beside and renamed over, one write at
  a time (`safe_file.dart`); restored book ids must look like book ids
  (`LibraryStore.isBookId`); `app_update.json` is never backed up or restored, only
  APKs from this repository's releases are offered, and `installApk` refuses an APK that
  is not this package (and this key, when Android can read it).
- **Audit findings not fixed yet (next):**
  - The library, including `sources/cookies.json` and plugin JS, is on external app
    storage. Android 11+ isolates it, but on 8-10 an app with storage permission could
    read cookies or change plugins. Move `sources/` and `app_update.json` to `filesDir`.
  - CI supply chain: commit `pubspec.lock` and use `--enforce-lockfile`, pin actions
    by SHA, give the token `contents: read` except for releasing, and decode the
    signing key just before `flutter build`.
  - Web-novel plugins share one QuickJS context and one cookie jar, with no host
    limits. Isolate them per plugin, send cookies only to their site, and block
    private addresses.
  - Library index mutations are serialised per write but not per read-modify-write,
    so a lost update is still possible in a narrow race.
  - Minor UI: edge-fade ShaderMasks over whole lists (scroll cost), the Undo snack
    over Now Playing's scrubber, the shelf's scroll key including the book count, and
    week bars at very large text.

## 0-. Earlier the same day: 1.0 merged, release after the last phone checks

Released since v0.5.0: **0.5.1** (backup and restore, update check), **0.6.0** (the
permanent app id `app.tomevoice`, a 32-bit APK), **0.7.0** (book colours from covers,
Now Playing, landscape), **0.8.0** (search, Saved quotes and bookmarks with share cards,
pronunciation fixes, skip-line rules). **0.9 and 1.0 are merged into `main`** (PR #1) but
not yet tagged: stats and streaks, home-screen widgets, natural voices, dialogue voice,
and the fixes below. All other branches were merged and deleted; work continues on
`v1.0-release`. The plan with every decision is [road-to-1.0.html](road-to-1.0.html).

- **Natural voices** (`neural_voices.dart`, `neural_screen.dart`): Piper models through
  sherpa_onnx **1.13.8** (2.0 drops espeak; keep the pin). Use the **full-precision**
  archives (`vits-piper-<id>.tar.bz2`, 64 MB, 110 MB for HD): the fp16 ones abort ONNX
  Runtime on the phone (`Failed to find kernel for com.microsoft.Gelu ... float16`).
  Voices live in `files/voices/piper-<id>`; anything else there is cleared on start.
  Unpacking streams bz2 to a tar beside it and then file by file (24 MB at most; reading
  it whole took 184 MB). Only path strings may cross into `Isolate.run`: a closure that
  holds the ChangeNotifier fails to send. Off unless chosen: a warning before any
  download, a speed test after, Remove and Remove all.
- **Measured on the developer's phone** (Nothing A059, *Alice* at 2×, 60 s): idle 0.3% CPU
  and 213 MB; Google voice about 20% of a core (app plus Google's TTS process) and about
  404 MB together; **Kristin 70% average (bursts to 158%) and 537 MB**, at 10.9× real
  time. Battery over a long session is not measured.
- **Widgets** (`Widgets.kt`): drawn as one bitmap per face, to the design in
  road-to-1.0.html, in the design's own units (the 176-unit 2 × 2, the 360 × 176 card)
  scaled as one piece. The Nothing launcher's 2 × 2 is **136 dp**, its 4 × 3 about 210 dp
  (the large layout starts at 190). Numbers and labels in **Doto** (bundled, OFL). The
  accent is the app's own: `tints.json` now carries `accents` per book (tone 66 and its
  ink for dark faces, tone 40 and white for light; `widgetAccents` in `book_tint.dart`).
  Tap targets are moved over the drawn buttons with `setViewLayout*` (Android 12+). The
  wide and large players have chapter back and next (`ACTION_PREV/NEXT` to the service).
  Picker previews in `drawable-nodpi` were drawn from the same code.
- **APK size:** about 27 MB. One CPU's native code per APK (`TV_ABIS` in CI, jniLibs
  excludes in `prepare_android.py`; `abiFilters` alone was ignored) and compressed native
  libraries (`useLegacyPackaging`).
- **Since 0.8, also:** Undo on every save and a Remove button in Saved; press and hold in
  Now Playing opens the reader's menu; a book's and a novel's page keep Back, Search and
  the menu pinned (`PinnedBar` in `ui.dart`); landscape puts the player in a floating
  dock over the text (`_PlayerBar.dock`), with the text capped at a 720 dp line; Now
  Playing's sentence change pushes up instead of cross-fading; a choice row too wide to
  fit scrolls inside a pill that keeps its round ends; updates install from the app
  (`update_flow.dart`: downloads the release's APK for the phone's CPU into cache/share,
  opens Android's installer through `ShareProvider`; `REQUEST_INSTALL_PACKAGES`).
- **Verified on the phone:** the media card, backup and restore, the move to the new app
  id, book colours and Now Playing, search, Saved, pronunciation, the rules screen,
  Stats, the player widget (play, pause, progress, the new design), and a natural voice
  (download, speed test, reading, CPU and memory).
- **Not yet verified on the phone (next):** the build from `main` with Undo, Now Playing's
  menu, the pinned bars, the landscape dock and the pill rows; the dialogue voice; the
  streak widget; installing an update (needs a release newer than the one installed, so
  after 1.0 is out).
- **Then:** tag and release **v1.0.0** (notes drafted), and delete `/sdcard/ui.xml` on
  the phone (left by the UI dumps).
- **On the phone:** the old app `app.tomevoice.tomevoice_spike` is still installed and
  can be uninstalled. TomeVoice's notification permission was denied once; it asks again
  when reading starts.

## 0a. Earlier checkpoint (2026-10-23, evening): v0.5.0

Everything is on `main` and released as **v0.5.0**. The `media-card` branch was merged
and deleted.

- **Media card** (the shade's and lock screen's player, Android 13+), drawn from the
  MediaSession by the system (`ReadAloudService.kt`):
  - the TomeVoice mark top left (`ic_stat_tomevoice`). The old small icon was a play or
    pause sign the wrong way round, and it read as a second button.
  - the cover as its picture; the system takes the card's colours from it. Decoded once
    per book, at most 480 px on its long side, RGB_565 (the session crosses processes).
  - a seek bar through the chapter, estimated from words at 165 wpm and the speed (the
    same estimate as "time left" under the player). Dragging maps back to a sentence.
  - a speed button (custom action) stepping through `speedPresets` (0.75 to 2x). Its
    icons are the numbers, drawn from Figtree into `drawable-*dpi/ic_speed_*.png`;
    other speeds show the Material speed icon.
  - previous/next by chapter. Previous restarts the chapter after its first 3 seconds.
  - moving from the card while paused stops the player, but the card stays up, paused,
    at the new place (`_parked` in `reader_screen.dart`).
  - a new sentence only updates the playback state; the notification is rebuilt only
    when what it shows changes. The notification permission is asked once per launch.
- **Verified on the phone:** all of the card except dragging its seek bar; per-chapter
  download, long-press multi-select, batch download with progress and Stop, and removing
  picked downloads.
- **Fixed from that testing:** a novel whose source is not installed (there: Deep Sea
  Embers, from ReadNovelFull) showed a raw `PathNotFoundException` when pulled to check.
  The novel page now raises `MissingSourceException`, and checks and downloads say so
  with an Install button (`installMissingSource` in `browser_check.dart`). The chapter
  pick bar's button no longer reads "Dow...".
- **Still not verified on a device:** the fresh-install shelf (`starter.dart`).
- **Next:** the ideas and priorities in [17-step-back-review.md](17-step-back-review.md).

## 0b. Earlier checkpoint (2026-10-23, v0.4.0)

**Stopped here on purpose** (the developer needed the machine). Everything was on `main`
and released as **v0.4.0**; `m1-new-look` equalled `main`.

- **On the developer's phone** (Nothing A059, adb `00158351M001200`): v0.4.0 installed. Their
  library is their own; do not reorganise it, and never re-add "Reborn In A World of Chastity
  Reversal" (they removed it).
- **Verified on the phone this session:**
  - adding LNReader's list (319 sources)
  - installing NovelBin and Royal Road
  - global search
  - novel page; add to library
  - listening, with chapters fetched ahead and next-chapter past what is downloaded
  - Royal Road through the hidden WebView (finding 20)
  - Updates
  - NovelDokusha import of 8 novels with covers and places
  - one-tap install of a missing source
  - the Sources language row
- **README screenshots** were retaken (public-domain books only, via the library search
  "alice"), cropped to the app and framed by `mockup.py`. That script lived in the scratchpad
  and is gone; any PIL rounded-rectangle frame will do.
- **Not verified on a device:**
  - first-run seeding (`starter.dart`), which needs a fresh install and could not be tested
    without wiping the phone; the bundled EPUB import is unit-tested
  - chapter multi-select and per-chapter downloads on the real phone (widget-tested;
    since verified, see section 0)
- **Open, next session:**
  1. Check the fresh-install shelf on a second device or an emulator.
  2. The priorities in [17-step-back-review.md](17-step-back-review.md), starting with the
     application id.
- **Local machine:** the scratch Flutter SDK and workspaces were deleted at the end of the
  session (PC kept light). To check locally again, rebuild them as in section 5 (or rely on
  CI: `gh workflow run build.yml --ref <branch>`).

## 1. Where the project is

**As of 2026-10-23, evening** (v0.5.0): the media card above, and the fixes from testing
on the phone.

**As of 2026-10-23** (v0.4.0, branch `m1-new-look`, merged to `main` for the release): a
full interface pass, web novels from LNReader sources, and new-chapter updates, on top of
everything below. The plan these follow is `docs/roadmap.html`.

| Area | State |
|---|---|
| Look | Bodoni Moda titles, Figtree interface, Newsreader/Literata page ([ADR-018](10-decisions-adr.md#adr-018)). One `ThemeData` from `Skin`; spacing `Gap`, corners `Radii`, motion `Motion`; shared widgets in `ui.dart`. Five palettes (Forest, Lavender, Ocean, Black, Paper) |
| Shell | Drawer: Library, Browse, Updates, History; Categories, Sources, Settings, About |
| Library | Cover tiles with a translucent info band (list view optional); categories as swipeable pages; long-press multi-select, move, remove; a continue dock at the bottom |
| Book page | Details, description (EPUB `dc:description`, parsed v5), category, per-book voice with a sample, chapters |
| Reader | Listen/Read settings sheet; voice picker with readable names and spoken samples; fades under the bars; ornament pictures drawn in the page's ink; keep screen on |
| First run | A new install starts with Pride and Prejudice (bundled, public domain), ReadNovelFull and Royal Road installed, and Shadow Slave and Lord of the Mysteries added from ReadNovelFull (`starter.dart`) |
| Web novels | LNReader plugins in QuickJS ([ADR-019](10-decisions-adr.md#adr-019)): Sources (LNReader's list built in, own lists addable, install/update), Browse (global search, per-source feeds), novel page (pull to check for new chapters, per-chapter and batch downloads), reading with chapters fetched ahead |
| Updates | New chapters checked on app open (off/12 h/daily/2 days/weekly) and from the Updates screen. Not yet a background job |
| Import | NovelDokusha backup zip (SQLite read in Kotlin) -> web novels with downloaded chapters and place |
| Animation | Fade-through transitions with predictive back, cover hero, staggered entrances, sliding choices, theme cross-fade |

### Earlier state (2026-10-22)

**As of 2026-10-22** (branch `ux-speed-overhaul`): the reader was rebuilt for speed and
for being obvious to use, and it now opens nearly every document format. Speech streams
gaplessly, follows the voice word by word, and keeps going with the screen off.

| Layer | State |
|---|---|
| Pure-Dart audio pipeline | **Done.** `WavCodec.pcm16Bytes` added for the streaming player |
| Android TTS adapter | **One warm engine** for engines, voices and synthesis. Callbacks filtered by utterance id; `cancelSynthesis` aborts a sentence on seek |
| Player | **Streaming `AudioTrack`** (`PcmPlayer.kt`). Gapless, real pause/resume, position from the playback head |
| Scheduler | Keeps ~10 s queued ahead. Highlight = hardware position, not a timer. DSP on a background isolate |
| Screen off | **`ReadAloudService`** (mediaPlayback foreground service) + MediaSession: notification, lock screen, headset buttons. Since v0.5.0 the media card has the cover, a chapter seek bar and a speed button |
| Document Model + ingest | **EPUB, PDF, DOCX, ODT, MOBI/AZW/AZW3 (PalmDOC), FB2, RTF, HTML, MD, TXT.** Script-based language detection |
| Segmentation | Multilingual (danda, CJK, Arabic stops); sentences capped at 280 chars at a clause boundary |
| Library | Import/parse/load on background isolates. Compact `parsed.json` v2 (Clown 15 MB -> 4.9 MB). Older books re-parsed once on open |
| Reading UI | Continuous scroll (`scrollable_positioned_list`), sentence + word wash, tap-to-read, follow mode with "Back to reading", contents sheet, player bar |
| Settings | One "Listening" sheet: speed, voice (for the book's language), style presets, fine-tune. **Persisted** in `prefs.json` |
| CI | **Release** APK, arm64 only, Gradle cache. Builds on `main`, PRs, or manual dispatch; docs-only changes skip |
| Pictures | EPUB images (incl. SVG covers, `<p><img>`) stored at import under `books/<id>/img/`, shown inline at natural size, tap to zoom, never spoken. Picture-only sections (maps, covers) lead into the next chapter. Library shows covers |
| PDF page view | Text / Page toggle for PDFs: real pages via platform `PdfRenderer` (`PdfPages.kt`), current page outlined and followed; tap a page to read from it |
| Visual EPUB (WebView, CFI, pagination) | **Not started** |
| Neural voices (Piper/Kokoro) | **Not started** |
| Windows | **Not started** |

Measured before this work (debug APK, Clown EPUB, Nothing A059): opening the book froze
the UI ~2.5 s; 650-760 ms of dead air *between every pair of sentences* (per-sentence WAV +
new `MediaPlayer` + a full-tree rebuild that scanned all 34k units three times); a WAV
leaked per sentence (30 found, 80 MB folder).

## 2. What was proven (spike, unchanged)

**R1 is answered** for Google TTS on the test device. See the previous handoff notes
and [§15.18](15-spike-audio-engine.md#1518-device-run-2-on-2026-09-02-all-criteria-met).
Cross-engine R1 (eSpeak etc.) is still unmeasured.

Device-checked in this slice (Nothing A059, serial `00158351M001200`):

- Import *Lord of Mysteries* (`Clown - LotM Vol. 1.epub` from the user's `E:\stories\`)
  → opens on **Chapter 1: Crimson**, `1 OF 213`, not a cover `Image`.
- Chapter skip → **Chapter 2: Situation**.
- Resume + tap-to-start-here on the old Specimen book (before it was removed from home).
- *Crime and Punishment* (Z-Lib EPUB) ingest works (14799 sentences) but the **file is
  OCR-garbled** (`he house`, `pervent`). That is the source, not the reader.

Playback-through-a-chapter after the TTS-overlap fix was **installed** (`bee9bc2`) but
not listened through. **Listen before claiming that bug is gone.**

---

## 3. Findings that will save the next person days

**1. `onRangeStart` parameters are not in the documented order.** Detect the layout
(`SpeechService.decodeTimings`). Do not "simplify" that away.

**2. Google TTS hides its sentence pause inside a word's range.** Do not assume every
gap in the audio is one we created.

**3. Stage order is load-bearing.** Edge-trim first; word-gap after stretch.
`ordering_test.dart` encodes both bugs. Architecture §2.6 now matches this; do not
restore the earlier pitch→stretch→trim sketch.

**4. A green test suite proved nothing about listenability.** Listen before claiming
success.

**5. Re-init of `TextToSpeech` per sentence is unusable.** The adapter keeps the engine
warm. Do not put `tts?.shutdown()` back at the start of `synthesise`.

**6. Android TTS has one progress listener.** Two overlapping `synthesizeToFile` calls
steal it; playback then dies after the first sentence. Lookahead must start **after** n
has finished synthesising, while n *plays from WAV*. `SpeechService.synthesise` is also
single-flight. Do not kick n+1 TTS before n's callback.

**7. EPUB spine is not a chapter list.** Covers, `Image` alt text, TOC sheets, and `●`
part dividers are not chapters. `readingSectionIndexes` / `readingToc` in
`packages/tomevoice_document/lib/src/navigate.dart` skip them. `BlockRole.figure` is in
`defaultSkippedRoles`.

**8. SAF `EXTRA_MIME_TYPES` hides EPUBs.** Android often labels `.epub` as zip /
octet-stream. Picker is `*/*` with no MIME extra.

**9. Do not rebuild the whole reader on every word.** Word highlight is a
`ValueNotifier`. Persist cursor on a debounce, not every sentence. Each paragraph
widget listens for the cursor itself and rebuilds only when the spoken sentence enters,
leaves or moves within it.

**10. A debug APK is not a performance test.** Debug Flutter is unoptimised JIT with
asserts. CI builds `--release` now. Judge latency only on a release build.

**11. Never feed the player per-sentence files.** The streaming track is what makes
sentences gapless and pause possible. Queue PCM; read the playback head for "what is
audible". Do not reintroduce `play(path, wait: true)`.

**12. `Isolate.run` closures must be created in a top-level function.** A closure made
inside a method can share a context with other captured variables (callbacks holding
widget state), which cannot be sent. See `_runImport` / `_runLoad` in `library_store.dart`.

**13. `flutter analyze` treats deprecations as failures.** Check locally before pushing
(see §4); a CI round trip costs several minutes.

**15. PdfBox's paragraph marks are not paragraphs.** On the device, a simple PDF came
out one line per paragraph, which makes the voice pause at every line. `formats/pdf.dart`
reflows: a paragraph continues unless it ends a sentence or is a heading.

**16. A green line round the whole screen was Android's keyboard-focus outline.**
One key press (keyboard, D-pad, `adb shell input keyevent`) puts Android in keyboard
navigation and it outlines the focused view, which for Flutter is the full screen.
`MainActivity.onPostResume` turns `defaultFocusHighlightEnabled` off.

**17. Kinds of PDF.** Born-digital (text) reads cleanly. Scans with an OCR text layer
(Internet Archive "Text PDF") read with the scanner's typos. Image-only scans are
refused; there is no OCR, by choice.

**18. "Chapters skipping" in PDFs was one section per page.** Without bookmarks every
page was a chapter and near-empty pages (plates, blanks) were hidden, so the list read
5, 10, 11, 13. `sectionsWithoutOutline` now uses chapter headings found in the text
(three or more), else ten pages per entry; `resectionPdf` fixes PDFs stored earlier.
`chapterLine` requires a number after the keyword: "book of rules for..." is prose.

**19. Covers.** `LibraryEntry.coverMode`: auto (the book's own, or drawn from the title),
custom (the user's picture, copied under `img/custom_cover_<time>`; a new name each time
because the image cache keys on the path) or plain.

**14. EPUB copyright pages are untitled and long.** `_looksLikeCopyrightPage` in
`navigate.dart` skips them (Red Rising opened on "This is a work of fiction").

**15. The release manifest had no INTERNET permission.** Nothing used the network before
web novels; every source request failed "host lookup". `tools/prepare_android.py` adds it.

**16. QuickJS cannot be built on this Windows PC.** flutter_qjs compiles C through a
native-assets hook that wants MSVC, and the scratch Flutter SDK lacks `gen_kernel_aot`.
Local checks swap `lib/sources/qjs_runtime.dart` for a stub and drop the dependency
(the scratchpad `sync.sh`); CI (Linux) builds and tests the real engine. The engine test in
`test/sources_test.dart` skips itself where the engine is missing.

**17. Mangayomi's Dart re-implementation of cheerio breaks the common plugin families**
(`.length` as a method, no `$(this)`, no `.attribs`). TomeVoice bundles the real cheerio
1.0.0-rc.12 + htmlparser2 + dayjs (tools/lnreader_libs, esbuild) and bridges only fetch and
storage. Verified with RoyalRoad, NovelBin and a madara site end to end.

**18. A painted fade band never matches the diagonal ground.** It read as a "bar" above the
home indicator. Fade the content itself (`ShaderMask` + `dstIn`) instead.

**19. `Skin.amber` and the ground colours are palette getters now**, so they cannot appear
inside `const` expressions.

**20. Cloudflare can refuse the app's HTTP client while letting the web view in.** From the
phone's network Royal Road answered every Dart (and phone curl) request with "Just a moment"
(403, `cf-mitigated: challenge`), while the PC's curl and the phone's WebView got the site
with no check at all, so no `cf_clearance` cookie is ever issued and cookies alone cannot
help. Plugins parsed the check page as "no results". Now: requests use the WebView's own
User-Agent; a challenged GET is loaded in a hidden one-pixel WebView (`BrowserCheck.fetch`,
called from worker isolates via `RootIsolateToken`) and its HTML goes to the plugin; if
even that is still a check, the UI shows "Open the check" (visible WebView dialog). Test
from the phone's network, not the PC's.

---

## 4. Running it

There is **no local Flutter or Gradle** by design ([ADR-016](10-decisions-adr.md#adr-016)).

```bash
cd packages/tomevoice_audio && dart pub get && dart analyze --fatal-infos && dart test
cd packages/tomevoice_document && dart pub get && dart analyze --fatal-infos && dart test

cd tools && dart pub get
dart run bin/make_fixture.dart /tmp/fx 120 1.0
dart run bin/measure.dart /tmp/fx
```

Inspect a real EPUB without Flutter:

```bash
cd packages/tomevoice_document
dart run tool/dump_book.dart "E:\stories\some-book.epub"
```

**APKs come from CI**, never locally. Pushes to `main` build automatically; for a
branch run it by hand:

```bash
gh workflow run build.yml --ref <branch>
gh run download <run-id> -n tomevoice-apk
adb install -r app-release.apk
```

**Signing.** With the repo secrets `TV_KEYSTORE_B64` and `TV_KEYSTORE_PASSWORD` set,
every release APK is signed with the same key and `adb install -r` upgrades in place,
keeping the library. Without them CI signs with a throwaway key and you must
`adb uninstall` first, which **wipes the library**. The keystore lives outside the repo
at `~/.tomevoice/` on the developer's laptop.

**Checking Dart before pushing** without installing Flutter permanently: unzip a Flutter
SDK into a temp folder, copy `app/` + `packages/` next to each other, run the same
`flutter create` as CI, then `dart analyze --fatal-infos` (Flutter's own `analyze` trips
over long Windows paths) and `flutter test`. Delete the SDK afterwards.

**The LNReader libraries bundle** (`app/assets/js/lnreader_libs.js`) is committed. To
rebuild it after changing versions: `cd tools/lnreader_libs && npm install && npm run
build` (Node only; CI does not need it). Smoke-test it in QuickJS before committing.

Maestro flows: `mobile-qa/flows/`. Do not `clearState: true` on resume tests. Selectors
use merged semantics (e.g. `Chapters\nChapter 1: Crimson\n1 OF 213`). Chapter index is
`1 OF 213`, sentence counter is `1 / 34273` — do not assert `1 /` as unique.

---

## 5. Code map

```
packages/tomevoice_audio/     PURE DART. Pipeline, timings remap, presets, PCM16 for the player.
packages/tomevoice_document/  PURE DART. Contract A + every ingest format.
  lib/src/
    model.dart                Book -> Section -> Block -> Sentence (compact JSON: 'sb')
    ingest.dart               ingestBytes / ingestPdfText, language resolved at the end
    detect.dart               magic bytes first: PDF, RTF, MOBI, zip (EPUB/DOCX/ODT/FB2)
    language.dart             script -> language (bn, hi, ar, ru, ja, ...)
    segment.dart              multilingual sentences, 280-char cap at a clause
    navigate.dart             reading sections: skip covers, TOC, copyright pages
    reading_layout.dart       units/items/chapter tables the reader uses (O(1) lookups)
    formats/epub.dart  html_blocks.dart (+ lenient tag-soup fallback)
    formats/text.dart         TXT (encodings, one-line paragraphs, chapters), Markdown
    formats/office.dart       DOCX, ODT
    formats/pdf.dart          page text -> book (headers, page numbers, outline chapters)
    formats/mobi.dart  fb2.dart  rtf.dart

app/                          FLUTTER. Built in CI; analyzed/tested locally (see 4).
  lib/
    main.dart                 library, or batch sweep via --es batch true
    library_screen.dart       shelf: Continue card, books, Add books, Open-with
    library_store.dart        JSON index; import/load on background isolates
    reader_screen.dart        BookLoader, reading list, player bar, contents sheet
    listen_sheet.dart         speed / voice / style / fine-tune
    scheduler.dart            streaming scheduler, position-driven highlight
    speech_service.dart       platform API, synth mutex, background render
    voices.dart               VoiceCatalog (shared), friendly voice names
    prefs.dart                persisted listening settings
    theme.dart  brand.dart    Skin, Palette, Gap, Radii, Motion, ThemeData; the logo
    ui.dart                   shared widgets (ChoiceRow, SettingRow, SearchField, ...)
    home_shell.dart           drawer and places (Library, Browse, Updates, History)
    book_screen.dart          a book's page;  book_actions.dart: cover, move, remove
    categories_screen.dart  history_screen.dart  settings_screen.dart (+ About)
    sources/                  web novels: net.dart, models.dart, source_store.dart,
                              plugin_host.dart (bridges), qjs_runtime.dart (QuickJS),
                              source_engine.dart (isolate pool)
    sources_screen.dart  browse_screen.dart  novel_screen.dart  web_reader.dart
    updates.dart  updates_screen.dart  noveldokusha_import.dart
  assets/js/                  lnreader_libs.js (bundle), lnreader_shim.js (require, fetch, storage)
  android_overlay/app/
    src/main/kotlin/.../MainActivity.kt      TTS, focus, import, intents
    src/main/kotlin/.../PcmPlayer.kt         streaming AudioTrack
    src/main/kotlin/.../ReadAloudService.kt  foreground service + MediaSession
    src/main/kotlin/.../PdfText.kt           PdfBox-Android text + outline
    src/main/kotlin/.../NovelDokushaImport.kt reads a NovelDokusha backup's SQLite
    proguard-rules.pro                        R8 keeps for PdfBox
  test/widget_test.dart       reader, sheet, voices, store (real isolates)

tools/prepare_android.py      manifest/gradle patches: service, intents, PdfBox, signing
```

---

## 6. Known problems

- **Kotlin was reviewed, not compiled locally.** The first CI build is its compiler.
- **Scanned PDFs** (page images) are refused with a message; there is no OCR.
- **Legacy-font Bengali PDFs** (Bijoy/SutonnyMJ, not Unicode) extract as Latin
  gibberish. That is the file's encoding, not the extractor; converting it is its own job.
- **Old .doc** and **HUFF/CDIC-compressed Kindle** books are refused with a message.
- No visual EPUB pages, images or footnote links; text only.
- Highlight lead on Bluetooth: the playback head does not include headset latency, so
  the word can run ~100-200 ms ahead on Bluetooth.
- `TimeStretchStubStage` pitch-shifts; speed is always the engine's. Phase 3 replaces it.
- Google TTS offline voices are mediocre. Piper is the actual answer (Phase 3).
- Library persistence is JSON, not Drift.
- Cross-engine R1 is unmeasured.

---

## 7. Decisions already locked

Unchanged: GPL-3.0, Flutter, Android primary, Dart locally / APKs in CI, synthesise-to-PCM,
DRM out of scope. New: the type set of ADR-018 replaces Ojuju/Space Mono; web novels run
LNReader plugins and TomeVoice ships no list of sites (ADR-019).

---

## 8. What to do next

**Web novels, next steps.** (1) A background update job (WorkManager) with a notification,
so updates happen with the app closed. (2) Cloudflare is handled (finding 20); a
POST behind a check still fails. (3) Per-plugin settings and filters (`pluginSettings`, `filters`) in the source screen.
(4) Download queue screen.

**Earlier list, still open:**

**A. Listen on the device.** Chapter-long listen with the screen off; pause from the lock
screen; a phone call mid-sentence; headphones unplugged. Open a PDF and a DOCX.

**B. Phase 1b — the visual EPUB reader** (WebView, CFIs, images). The reading layout
and scheduler are reusable; do not re-parse.

**C. Phase 3 — neural voices and a real time-stretcher.** Piper first.

### Do not do these

- Do not start with Kokoro.
- Do not "clean up" the `onRangeStart` layout detection.
- Do not reorder the pipeline stages without reading `ordering_test.dart`.
- Do not shut down `TextToSpeech` per call; one warm engine serves everything.
- Do not start n+1 `synthesizeToFile` before n has returned (or been cancelled).
- Do not go back to a file + MediaPlayer per sentence.
- Do not build a debug APK to judge speed.

---

## 9. Loose ends

- Cross-engine R1 (install eSpeak from F-Droid, re-run the batch) is still cheap and undone.
- `spike-runs/` and `dist/` are gitignored; delete freely. Do not commit APKs.
- The `spike/audio-engine` branch can still be deleted if it exists remotely.
- QA leftovers: `mobile-qa/scratch/`, `report.xml`, incomplete flows
  `import-clown.yaml` / `import-pdf.yaml` / `tap-clown.yaml` are untracked on purpose.
- User books live on the laptop at `E:\stories\` (Clown EPUB, Crime EPUB, PDFs, audio).
  Do not delete those. Device copies were under `/sdcard/Download/`.
