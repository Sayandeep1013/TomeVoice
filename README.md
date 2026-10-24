<p align="center">
  <img src="app/assets/brand/icon.png" width="128" alt="TomeVoice logo: a page of text turning into a voice waveform">
</p>

<h1 align="center">TomeVoice</h1>

<p align="center">
  <a href="https://github.com/Sayandeep1013/TomeVoice/actions/workflows/build.yml"><img src="https://github.com/Sayandeep1013/TomeVoice/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="License: GPL-3.0"></a>
  <img src="https://img.shields.io/badge/platform-Android-3DDC84.svg" alt="Platform: Android">
</p>

Any book, read aloud. Open an EPUB, a PDF, a Word file or plain text, press play, and
it reads to you — sentence by sentence, the spoken word highlighted, on the device,
with the screen off if you like.

<p align="center">
  <img src="docs/images/library.png" width="240" alt="The library's Later shelf as cover tiles, each with its format, language and progress, and the book being read waiting at the bottom with a play button">
  &nbsp;
  <img src="docs/images/book.png" width="240" alt="Alice in Wonderland's page in the colours of its cover: Find a chapter and the book's menu at the top, Continue and Read, the voice chosen for this book, and its chapters with the current one marked">
  &nbsp;
  <img src="docs/images/reader.png" width="240" alt="Reading Shadow Slave aloud: the spoken sentence and word highlighted, the chapter and 2000/3224 at the top, and the player">
</p>
<p align="center">
  <img src="docs/images/novel.png" width="240" alt="Shadow Slave's page: the web novel's site, status and 3224 chapters, the place reached, Continue and Read, and the chapters with the downloaded ones ticked">
  &nbsp;
  <img src="docs/images/find-chapter.png" width="240" alt="Find a chapter: typing shadow narrows Shadow Slave's 3224 chapters to those with it in their title">
  &nbsp;
  <img src="docs/images/settings.png" width="240" alt="Settings: five colour themes, colours from book covers, and the reading type, size, spacing and margins">
</p>

No account. No cloud. Your books never leave the phone.

**Status: Android app — download the APK from [Releases](https://github.com/Sayandeep1013/TomeVoice/releases/latest). Windows is planned.**

---

## What it does

- **Opens almost anything.** EPUB, PDF, DOCX, ODT, MOBI / AZW3, FB2, RTF, HTML, Markdown
  and TXT. Pictures and maps in ebooks are shown in the text; PDFs can be read as text
  or shown as their real pages; chapters are found even when a file does not list them.
- **Reads it aloud** with the voices already on your phone, picking one in the book's
  language — a Bengali book gets a Bengali voice.
- **Natural voices, if you want them.** Seven English voices that sound like people
  (Piper), made on the phone with no internet once downloaded. They are off unless you
  choose one: each is a 64 MB download (110 MB for HD) and works the phone harder, about
  three times the processor of a built-in voice, so TomeVoice says so before anything
  downloads, tests how fast your phone runs it, and removes them all with one tap.
- **Dialogue in a second voice.** Pick one, and words inside quotation marks are read
  by it while the narrator reads the rest.
- **Follows along.** The sentence being read is marked and the word under the voice is
  highlighted, timed from the audio itself.
- **Keeps going with the screen off.** Pause and resume from the lock screen,
  notification or headset; it stops for calls and when headphones come out. The media
  player in the notification shade shows the book's cover in its colours, a bar through
  the chapter you can drag, a speed button, and skips by chapter.
- **Starts where you stopped**, with a sleep timer for listening in bed.
- **Now Playing.** Swipe the player up for the cover and the words going by like song
  lyrics. Every book takes its colours from its cover, here and on its pages. Turned on
  its side, the text keeps the screen and the player floats beneath it.
- **Find and keep.** Find a chapter by its number or title (type 2000 in a 3,000-chapter
  web novel and it is the only one left), or find a passage, a line you remember, in the
  chapter or the whole book. Press and hold a line to save
  it as a quote, bookmark it, copy it, or share it as a picture in the book's colours
  (with Undo if you saved by mistake); they wait in **Saved**. Fix how a name is said,
  for one book or all, and in web novels leave out site notices and credits.
- **Listening stats and streaks.** Your week, the last twenty weeks as dots, and a streak
  for every day you listen for five minutes.
- **Home-screen widgets.** The book you are reading, its cover in a ring that fills as you
  go, with play (and chapter skips on the wider ones); and your streak. Every size, in the
  book's colours.
- **Your library in one file.** Back it up to Downloads or Drive and restore it on a new
  phone, adding to what is there or replacing it. TomeVoice also tells you when a new
  version is out, and installs it for you (Android asks you to confirm).
- **A shelf you can organise.** Cover tiles with format, length and progress on each;
  your own categories (Reading, Later, or any you make), swiped between; the books you are
  in the middle of waiting at the bottom with a play button.
- **A page for every book:** its cover (the book's own, one you pick, or a plain title
  cover), description, chapters, and the voice it is read in, with a sample to hear first.
  Play carries on where you stopped; any chapter opens right there.
- **Web novels too.** Install sites from LNReader's source list (there from the start) or
  bring your own list, search every site you installed at once,
  add a novel to your library and listen to it like a book: chapters are fetched as you go,
  new ones are checked for, and sites behind Cloudflare are read through the phone's own
  browser engine. Download single chapters or whole novels to listen offline. Your
  NovelDokusha library can be imported from its backup
  ([ADR-019](docs/10-decisions-adr.md#adr-019)).
- **Never an empty shelf.** A new install starts with *Pride and Prejudice* (public
  domain, with its 1894 peacock cover) and two popular web novels, *Shadow Slave* and
  *Lord of the Mysteries*, ready to play. Remove them like any other book.
- **Five colour themes:** Forest, Lavender, Ocean, Black for OLED screens, and Paper.
- **Gives you the voice controls readers don't:** speed, pitch, the gap between words,
  and pauses at commas, sentences and paragraphs.

## What it deliberately does not do

DRM-protected books (Kindle, Adobe), scanned PDFs with no text in them (no OCR), and
anything that needs an account or a server.

## Install (Android)

1. Download `TomeVoice-<version>.apk` from the latest
   [Release](https://github.com/Sayandeep1013/TomeVoice/releases/latest). On an older or
   Android Go phone that says *App not installed*, take `TomeVoice-<version>-32bit.apk`
   instead.
2. Open it on your phone and allow installs from your browser or file manager when asked.
   If Play Protect calls it an unknown app, tap **More details → Install anyway**:
   TomeVoice isn't in the Play Store, so Google hasn't scanned it. (Or
   `adb install -r TomeVoice-<version>.apk`.) Updates install over the old version and
   keep your library. From 1.0 TomeVoice offers each new version itself: tap **Install**,
   then confirm Android's prompt.
3. Open it. A few books are already on the shelf; tap **Add books** to add your own, or
   open a book from any file manager with TomeVoice.

**Coming from 0.5 or earlier?** From 0.6 TomeVoice has its permanent app id, so Android
installs it as a new app beside the old one. In the old app, update to 0.5.1 and use
**Settings → Back up library**. Install the new version, tap **Restore** when it offers
(or Settings → Restore a backup), check your books, then uninstall the old one.

Every push to `main` also builds an APK in
[Actions](https://github.com/Sayandeep1013/TomeVoice/actions/workflows/build.yml).

## How it is built

The hard part of the idea is the voice, not the reader. No text-to-speech engine lets
you control the gap between words, so TomeVoice synthesises each sentence to PCM, runs
it through its own pipeline (word gaps, pauses, loudness) and streams it to a player
it owns. That is also what makes playback gapless and the highlighting accurate.

| Part | Where |
|---|---|
| Audio pipeline (pure Dart, tested without a phone) | [`packages/tomevoice_audio`](packages/tomevoice_audio) |
| Every document format to one readable model | [`packages/tomevoice_document`](packages/tomevoice_document) |
| The Flutter app | [`app/lib`](app/lib) |
| Android: TTS engine, streaming player, screen-off service, PDF | [`app/android_overlay`](app/android_overlay) |

There is deliberately no local Flutter or Gradle requirement
([ADR-016](docs/10-decisions-adr.md#adr-016)): the Dart packages test with the plain Dart
SDK, and APKs are built by GitHub Actions.

The full design is in [`docs/`](docs/README.md); picking the project up cold, start at
the [session handoff](docs/16-session-handoff.md). Every decision and the alternatives
it rejected: [decision log](docs/10-decisions-adr.md).

## Licence

**GPL-3.0.** It is what lets the planned offline neural voices (Piper, eSpeak-NG) be
ordinary dependencies rather than licensing problems. See
[ADR-014](docs/10-decisions-adr.md#adr-014).
