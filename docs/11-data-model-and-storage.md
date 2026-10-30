# 11 — Data Model & Storage

How TomeVoice keeps your library on the phone, as built (not as first planned: the
original plan's SQLite/Drift database, full-text index and migrations were never built;
see git history for that version of this page). Everything is plain JSON files, written
atomically, with no server and no account.

## 11.1 Where things live

**The library folder:** the app's external files folder,
`Android/data/<app id>/files/` (`app.tomevoice`, or `app.tomevoice.test` for the test
app). Readable over USB, and what a backup zips.

```
library.json            the shelf: categories, the default one, and every book's entry (with
                        its tags, its series and number, and a print of its text; see 11.7)
books/<id>/             one folder per book (id: 16 hex digits, or web- and 16 more)
  source.<ext>          the book's own file, as imported (EPUB, PDF, ...)
  parsed.json           the book read into TomeVoice's model, {"v": <parse version>, "book": ...}
  cursor.json           the place: {"cursor": {section, block, sentence}, "progress": 0..1,
                        "where": the chapter's name, "at": when it was saved}
  img/                  pictures and covers taken from the book; custom_cover_<time>.*
  novel.json            a web novel: its site, details and chapter list
  ch/                   a web novel's downloaded chapters (ch/orphaned/ for ones its site
                        no longer lists; they come back if it lists them again)
  read.json             a web novel's chapters marked read or unread by hand, by address
  ocr.json              a scanned PDF's text, read once by OCR, never read again
marks.json              quotes (with colour and note) and bookmarks, for every book; "left"
                        on those of a book removed from an open shelf (see 11.6)
stats.json              listening time per day, and the streak goal
prefs.json              listening and reading settings (voice per language and per book,
                        speeds, pauses, page, theme, sync and catalogue settings, which
                        web novels download their new chapters by themselves)
rules.json              reading rules: how words are said, lines left out of web novels
tints.json              colours taken from each book's cover
updates.json            web novels' new-chapter checks and their results; chapter counts
                        and new chapters to download that a check with the app closed
                        leaves for the app
downloads.json          the chapter download queue, so it carries on after a restart
sync_state.json         what sync last sent and saw (WebDAV, KOReader)
starter.json            what the first-launch shelf has added, so it is never added twice
app_update.json         the update check's state; names the APK to install, never backed up
.secrets.json           sync passwords and this phone's sync id; never backed up
.restore-journal.json   a library being replaced, until the swap is settled
.restore-report.txt     what the last restore did, shown once
incoming/<uuid>/<name>  a file picked or opened from another app, while it is imported;
                        swept after an hour if a crash left it
voices/                 downloaded natural voices (64 to 334 MB each); never backed up
ocr/tessdata/           OCR language data, downloaded on request; never backed up
```

**Internal storage** (`filesDir`, which no other app can read):

```
sources/                web-novel sources: repos.json (the lists), installed.json,
                        plugins/<id>.js (code, checked by SHA-256 at install and on load),
                        storage-<id>.json (each plugin's own settings), cookies per plugin,
                        index-*.json (cached lists), moved.json, restored.json
errors.jsonl            the local error log (about 50 entries), scrubbed of titles and paths
```

The `cache/tts` folder holds the voice's sentence audio while it is read; it is emptied
when the voice engine starts.

## 11.2 The book model

`packages/tomevoice_document`: a **Book** has **Sections** (chapters), a section has
**Blocks** (paragraphs, headings, footnotes, captions, pictures), a block has
**Sentences**. A sentence can hold stretches shown but not spoken (footnote markers),
and hints for how a voice should say something. **ReadingLayout** flattens a book into
the units the voice reads, in order; with `displayOnly`, footnotes and captions are
laid out where they stand without being spoken (unless the reader turns on Read notes
aloud).

A place (**ReadingCursor**) is section, block and sentence numbers. Opening a book
turns it into a unit with `unitForCursor`.

## 11.3 Writing safely

- **One write at a time per file, never half-written.** `writeSafely` writes a temp
  file beside the target (its name salted per engine) and renames it over the target.
  A crash leaves the old file or the new one, never a mix.
- **The shelf's index is read once and kept in memory** (`LibraryStore`); every change
  is applied to that copy in one step and written out. Before a change it checks
  `library.json`'s time and size against the last read or write: another engine (a
  book read with no screen, the closed-app chapter check) that wrote it in between
  makes it read the file again first, so neither writes over the other's books. Places
  this copy holds and has not written yet (11.4) are laid back over what it reads,
  unless the other engine saved a later one.
- **library.json is written as it always was** (pretty-printed, read over USB and by the
  widgets and Android Auto), but each book's part is encoded once and kept with its
  entry (`index_file.dart`): a write encodes only the books that changed since the last,
  and a large index's parts are made on a background isolate once it is read.
- **Damaged files are kept aside, not written over.** An unreadable `library.json`
  becomes `library.json.broken`; an entry of the wrong shape is passed over and a copy
  of the file kept.
- **One engine writes the library at a time.** The check for new chapters made with the
  app closed starts an engine of its own only while the app's is down; while it is up
  (TomeVoice open, left in the background, or reading with no screen), the worker asks
  that engine to check instead (SourcesBridge's "runCheck") and posts what it found. The
  check's own engine writes no `library.json`, stops before each write once the app
  opens (its leftovers wait in `updates.json`), and the app waits for it to end.
- **A web novel moved to another source** has its new folder made whole first (each
  download moved to its chapter's place there, one that matches none to `ch/orphaned/`),
  then its entry swapped in one write; the old folder goes last.

## 11.4 Places

- `cursor.json` holds a book's place and is what a book opens at (`cursorFor`);
  `library.json` keeps a copy for the shelf, History, sync, the widgets and Android Auto
  (where you are, progress, when). The place is saved about once a sentence while
  listening, and each save wrote the whole index again on the UI thread.
- **Now `saveCursor`** writes `cursor.json` at once, every time, and the copy of the index
  in memory, which every page reads. `library.json` takes the first place in a while at
  once; places saved within five seconds of it wait and are written together at the end
  of that window (`placeWindow`). They are written at once when reading pauses (every
  player's pause), a screen is left (the app's navigator), the app is put away, before a
  backup, and before a restore adds to the library.
- **No place is lost if the app is stopped in between:** the place is in `cursor.json`,
  and the next run, on first reading the index, takes in every `cursor.json` written
  after `library.json` whose own time is later than the entry's (a large library is
  looked through on a background isolate). An older build's `cursor.json`, with no time
  in it, is taken only when it holds another place, and never moves a book up the shelf.
- Measured with a synthetic library of 1,000 books (750 KB `library.json`) on a desktop
  in the tests' debug mode (`app/test/place_writes_test.dart`): a saved place kept the UI
  thread busy for a median 22.9 ms before and 2.1 ms after; forty of them, 918 ms
  before, 90 ms after plus 8.6 ms to write them together. Encoding the index: 14.6 ms
  for every entry, 3.1 ms with one changed. On a phone (AOT, slower storage) the
  proportions should hold; the absolute numbers are still to be taken there.
- **Books read again.** When reading improves, stored books are parsed again from their
  own file the next time they are opened: `_parsedVersion` in `library_store.dart` (in
  `parsed.json`'s `"v"`), and for PDFs `pdfParserVersion` (stored on the entry), since a
  PDF's text needs the platform. The place is carried across by the sentence's own
  words (`relocateCursor`), so a re-read book opens where you were.

## 11.5 Backup and restore

- **A backup** is one zip of the library folder, `manifest.json` first, streamed so a
  large library never sits in memory. Left out: imports in flight, temp files, the
  update check, natural voices, OCR data, sync secrets, cached source lists, site
  cookies, and downloaded chapters unless chosen. The web-novel sources' lists,
  installed list and settings are added from internal storage. A backup holding a secret
  shelf says so before it is made.
- **Restore** unpacks into a staging folder and checks every entry, then either **adds**
  (books you lack; for books in both, the further place, both phones' tags, this
  phone's series unless it has none (then the backup's), and a print of the text from
  whichever has one; quotes, stats and rules merged; the backup's settings only if
  asked) or **replaces** (a journaled swap that a crash can finish or undo; this phone's
  voices and update choice stay). Restored sources are installed again from their lists;
  plugin code inside a backup is never run.
- **Automatic backups** write the same zip into a folder the reader picked, daily or
  weekly, keeping the newest five.

## 11.6 Secret shelves

A category can be secret. Its books are left out of everything shown (shelves, search,
Saved, stats, widgets, the media session, Android Auto) until it is opened with the
phone's lock, and it shuts again when the app is left. Removing a book from a secret
shelf removes its quotes and bookmarks with it. Notifications (new chapters, downloads)
never name a novel on a secret shelf, open or not, as they stay once the app is left;
exporting one as an EPUB asks for the lock first, and the NovelUpdates link is not
offered for one while the shelf is shut.

- **Tags, series, filters and copies** are worked out from the books a page is given,
  which leave a shut shelf's out: no tag, series, format, language or count of its books
  is offered, a filter on one of its tags is dropped, a tag typed never takes its
  spelling from one of its books, renaming or removing a tag leaves its books' alone, and
  a book added that looks like one of its books is not named as a copy.
- **Quotes of removed books.** Before 1.4 a secret book's quotes stayed when it was
  removed, and they cannot be told from any other removed book's. So with a secret shelf
  shut, Saved and quote exports leave out the marks of every book no longer in the
  library, except those known to have left from an open shelf: from now on a removed
  open book's marks are stamped `left`. With the shelf open, or no secret shelf at all,
  they all show, and Saved offers to clear them together (Undo brings them back); with it
  shut it offers only those it shows. Hiding them is the safe side: a reader with a secret
  shelf sees an old removed book's quotes once the shelf is open, where showing them shut
  could put a secret line on screen.

## 11.7 Tags, series and copies

- **Tags** (`tags` on an entry): as many as a book needs, each once (case and spacing do
  not make another), set on its page, on several selected books, renamed or removed from
  the filter. **A series** (`series`, `seriesIndex`) comes from an EPUB's
  `calibre:series` or EPUB 3 `belongs-to-collection`, an FB2's `sequence`, or a title that
  names one ("A Song of Ice and Fire 3", "Mistborn, Book Two", "Leviathan Wakes (The
  Expanse #1)"; not "Fahrenheit 451"); `series: ""` is a book the reader took out of one,
  not looked for again. An entry with no `series` key (written before) has its title
  asked when it is read.
- **Orders and filters:** Sort by Author (family names, "Le Guin", "de la Mare"), by
  Series (each in its order), as well as the earlier ones; a series stands in its order
  under every sort. The View menu's Filter narrows every shelf to progress (not
  started, in progress, finished), format, language, tag and series; it is not kept past
  the app's closing.
- **Copies:** a print of each book's text (`print`: the 16 smallest hashes of its runs
  of five words, as base64; `text_print.dart`) is made on import, and on the first
  opening for a book imported before. Two books are offered as copies when their prints
  are alike, or their titles and authors are the same and their prints do not say they
  differ (two volumes of a series never are). Offered after an import and from Find
  duplicates; a copy is only ever removed by the reader.
