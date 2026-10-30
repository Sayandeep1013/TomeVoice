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
library.json            the shelf: categories, the default one, and every book's entry
books/<id>/             one folder per book (id: 16 hex digits, or web- and 16 more)
  source.<ext>          the book's own file, as imported (EPUB, PDF, ...)
  parsed.json           the book read into TomeVoice's model, {"v": <parse version>, "book": ...}
  cursor.json           the place: {"cursor": {section, block, sentence}, "progress": 0..1}
  img/                  pictures and covers taken from the book; custom_cover_<time>.*
  novel.json            a web novel: its site, details and chapter list
  ch/                   a web novel's downloaded chapters (ch/orphaned/ for ones its site
                        no longer lists; they come back if it lists them again)
  ocr.json              a scanned PDF's text, read once by OCR, never read again
marks.json              quotes (with colour and note) and bookmarks, for every book
stats.json              listening time per day, and the streak goal
prefs.json              listening and reading settings (voice per language and per book,
                        speeds, pauses, page, theme, sync and catalogue settings)
rules.json              reading rules: how words are said, lines left out of web novels
tints.json              colours taken from each book's cover
updates.json            web novels' new-chapter checks and their results
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
  makes it read the file again first, so neither writes over the other's books.
- **Damaged files are kept aside, not written over.** An unreadable `library.json`
  becomes `library.json.broken`; an entry of the wrong shape is passed over and a copy
  of the file kept.

## 11.4 Places

- `cursor.json` holds a book's place; `library.json` keeps a copy for the shelf (where
  you are, progress). The place is saved about once a sentence while listening. Whether
  writing the whole index that often costs anything noticeable is still to be measured
  on a phone with a large library.
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
  (books you lack; for books in both, the further place; quotes, stats and rules merged;
  the backup's settings only if asked) or **replaces** (a journaled swap that a crash can
  finish or undo; this phone's voices and update choice stay). Restored sources are
  installed again from their lists; plugin code inside a backup is never run.
- **Automatic backups** write the same zip into a folder the reader picked, daily or
  weekly, keeping the newest five.

## 11.6 Secret shelves

A category can be secret. Its books are left out of everything shown (shelves, search,
Saved, stats, widgets, the media session, Android Auto) until it is opened with the
phone's lock, and it shuts again when the app is left. Removing a book from a secret
shelf removes its quotes and bookmarks with it.
