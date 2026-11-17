# 03 — Document Pipeline

How a file on the phone, a web page or a web novel's chapter becomes something TomeVoice
can both render and speak, as of 1.4.0. Everything here is pure Dart in
`packages/tomevoice_document` unless it names a Kotlin file; the entry point is
`ingestBytes` (`ingest.dart`), and for PDFs `ingestPdfText`, since only the platform can
pull a PDF's text.

```
file  ->  detect  ->  parse  ->  classify  ->  segment  ->  speech text  ->  parsed.json
                       |            |             |             |
                    structure     roles       sentences +    what the voice
                    + raw text   (skip?)        words        is given
```

Two text streams come out of this, and keeping them distinct is essential:

- **Display text** — what the reader shows. Preserves the author's characters exactly.
- **Speech text** — what goes to the voice: a footnote's marker left out, a long link
  said as its site, a bracketed citation skipped, a name respelled by the reader's own
  rule.

They stay **aligned by character range**, because word highlighting happens in display
space while word timings arrive in speech space. Every change to the speech text carries
its source range (`SpokenText` in `speech.dart`; the app's `Respelled` for pronunciation
rules), and a word the voice reports is mapped back through them onto the page.

## 3.1 Format detection

Magic bytes first, then the file's name, then its MIME type (`detect.dart`). Phones hand
over EPUBs as `.zip`, `.bin` or with no name at all, so the extension alone is never
trusted.

| Signature | Format |
|---|---|
| `%PDF-` | PDF |
| `{\rtf` | RTF |
| `BOOKMOBI` / `TEXtREAd` in the PalmDB header | MOBI / AZW / AZW3 / PRC |
| zip with `mimetype` = `application/epub+zip`, or `META-INF/container.xml` | EPUB |
| zip with `word/document.xml` | DOCX |
| zip with the OpenDocument text `mimetype` | ODT |
| zip holding a `.fb2`, or `<FictionBook` | FB2 |
| `<html` and the like | HTML |
| anything else that is text | TXT or Markdown, by name |

Sound and pictures are refused by what they are, whatever they are called ("That is
already audio"), and so is a zip that is mostly pictures (a comic). An old `.doc` is
refused with a message.

**Protected books are refused, never opened** ([C-07](09-challenges-and-solutions.md#c-07)):
an EPUB whose `META-INF/encryption.xml` encrypts anything but fonts (font obfuscation
alone is not DRM; such books were once refused by mistake), an encrypted Kindle book,
and a password-protected PDF each get a plain message.

## 3.2 EPUB

EPUB is the easy format, which is why it was the reference implementation
(`formats/epub.dart`, `formats/html_blocks.dart`).

**Parse.** `META-INF/container.xml` -> the OPF. From the OPF: metadata (title, authors,
language, description, `calibre:series` or EPUB 3 `belongs-to-collection`), the
manifest and the **spine**. Chapters follow the book's own contents (the EPUB 3 nav, or
the NCX), not the spine: a whole book in one file with a contents of anchors still opens
by its chapters.

**Extract for speech.** Each spine item's XHTML is walked into blocks. The
element-to-role mapping does most of the classification:

| Element / attribute | Role |
|---|---|
| `h1`–`h6` | `heading` |
| `p`, `div` with text | `paragraph` |
| `li` | `listItem` |
| `blockquote` | `quote` |
| `figcaption`, `epub:type="caption"` | `caption` |
| `epub:type="footnote" \| "rearnote" \| "note"`, `role="doc-footnote"` | `footnote` |
| `epub:type="pagebreak"` | `pageNumber` |
| `table` | `table` |
| `pre`, `code` | `code` |
| `math`, MathML | `math` |
| `img` | `figure`: the picture stored under `books/<id>/img/` and shown in the text, never spoken |

**What is not read.** Covers, picture-only sections, contents pages, copyright pages,
Project Gutenberg's header and licence, and transcribers' notes are found and passed over
(`navigate.dart`, `html_blocks.dart`), so a book opens on its first chapter. Notes stay on
the page in small type and are not read unless the reader turns on Read notes aloud;
their markers are shown and silent (`Sentence.silent`).

**Hard parts.** Real books break rules: `<span>`-per-word markup from bad converters,
notes inline in the flow, drop caps split across elements
(`<span class="dropcap">O</span>nce upon`), right-to-left text. Adjacent inline runs are
joined and drop caps rejoined to their word before segmentation, or every drop cap
would become its own sentence. Right-to-left books (Arabic, Hebrew, Persian) are set and
turned right to left.

**A book's own narration.** An EPUB 3 with media overlays (SMIL) is read into clips of
audio, each with the stretch of text it says (`formats/media_overlays.dart`,
`narration.dart`); `NarrationAudio.kt` decodes the clips straight from the EPUB's bytes.
The reader can play the recording instead of a voice, its words lit as they are said.

**Anchors.** The first design gave each block an EPUB CFI so reflow could never lose the
place. As built, the place is section, block and sentence numbers (`ReadingCursor`),
which reflow cannot move either ([02 §2.4](02-architecture.md#24-contract-a-the-document-model)).

## 3.3 PDF: the hard one

A PDF does not contain paragraphs. It contains instructions to draw glyphs at
coordinates. Everything above that — words, lines, columns, reading order — is inferred.
It is never perfect.

**As built, the work is split in two.**

- **`PdfText.kt` (PdfBox-Android 2.0.27.0)** does the glyph work: fonts, ToUnicode maps,
  reading order within a page. It returns each page's text (paragraphs marked with
  U+2029, every page ended by a form feed, an empty page too), the line layout (each
  line's x, baseline, width and font size) and the runs set raised and smaller than
  their line (a note's mark), plus the PDF's bookmarks.
- **`formats/pdf.dart`** does the listening clean-up from that text and layout:
  - running heads and footers, and page numbers, are dropped (the first design kept
    them as roles to be turned back on; as built they are removed);
  - words broken by a hyphen at a line's end are mended ([C-02](09-challenges-and-solutions.md#c-02));
  - a paragraph split by a page break is joined;
  - notes at a page's foot become footnote blocks, shown and not read;
  - two columns are read one after the other;
  - lines set in by an indent start paragraphs, so two speakers' lines are two
    paragraphs;
  - a note's raised mark is not said (a power such as m² still is).

**Chapters.** The bookmarks are the chapter list: nested bookmarks are flattened, a lone
top bookmark (the book's own title) is unwrapped, and bookmarks named after pictures
("DSC01139.tif", "scan0001"), as image-to-PDF tools make them, are not chapters. A PDF
with no bookmarks takes its chapters from headings found in the text (three or more),
else one entry per ten pages.

**Re-reading.** `pdfParserVersion` (now 8) is stored with each PDF; when the clean-up
improves, a stored PDF is extracted again from its file the next time it opens, and the
place is carried across by the sentence's words.

**Not built from the first design:** glyph-level geometry, column detection by
whitespace gutters across bands, the reading-order overlay and manual region editing,
and per-category accuracy targets ([C-01](09-challenges-and-solutions.md#c-01)).

**The real pages.** A PDF can also be shown as its pages (`PdfPages.kt`, Android's
`PdfRenderer`) while the voice reads the extracted text: zoom, a dark page at night, and
Crop margins, which finds where each page's print lies and cuts the margins away
(`page_crop.dart`).

**Scanned PDFs.** A PDF whose pages are mostly pictures says so and offers OCR
([C-04](09-challenges-and-solutions.md#c-04)). `Ocr.kt` draws each page with
`PdfRenderer` at about 300 dpi, makes it grey and reads it with Tesseract
(Tesseract4Android, Apache-2.0), one page at a time on one background thread, in a
data-sync foreground service with Stop in its notification, so a 300-page scan goes on
with the screen off. The language data (`tessdata_fast`, one file per language) is
downloaded only when a scan in that language is first read. Each page's text is kept as
soon as it is read, so a stop of any kind goes on from the first page without one. What
Tesseract read is given the shape of a PDF's own text and goes through `formats/pdf.dart`
like any PDF (`ocr.dart`); the result is kept in the book's `ocr.json` and never read
again.

**Kinds of PDF, in practice.** Born-digital text reads cleanly. Scans that come with an
OCR text layer (Internet Archive's "Text PDF") read with the scanner's typos. Legacy-font
Bengali PDFs (Bijoy, SutonnyMJ: not Unicode) extract as Latin gibberish; that is the
file's encoding, and converting it is a job of its own.

## 3.4 DOCX

A zip of XML (`formats/office.dart`, which reads ODT the same way). `word/document.xml`
holds the body; `styles.xml` maps style IDs to names, which is how a heading is told from
a paragraph (`Heading1`..`Heading9`), and `footnotes.xml` / `endnotes.xml` hold the notes.

As built:

- **Tracked changes.** The *accepted* document is read: insertions in, deleted text
  (`w:delText`) out. There is no setting to flip it.
- **Comments** live outside the body and are not read.
- **Notes.** Shown after the paragraph that points at them (endnotes at the end), not
  read, their marks shown and not said.
- **Tables.** A table of data is read a row at a time; there is no "row 3, column 2"
  prefix.
- **Fields.** Field codes (`w:instrText`) are skipped, so a field's result text is read,
  not its code.
- **Hidden text** (`w:vanish`) is left out.
- **Text boxes.** A paragraph nested in a text box becomes a block of its own.

## 3.5 Other formats

- **MOBI / AZW / AZW3** (`formats/mobi.dart`): PalmDOC-compressed or uncompressed text;
  a KF8 book (AZW3, or the KF8 half of a joint `.mobi`) is rebuilt into its HTML parts
  and opened by its chapters, through the same HTML-to-blocks code as an EPUB; its notes
  are shown, not read. HUFF/CDIC-compressed books and anything encrypted get a clear
  message instead of garbage; a cut-short file says so.
- **FB2** (`formats/fb2.dart`): plain XML, often declared as windows-1251 or KOI8-R; its
  `sequence` gives the series.
- **RTF** (`formats/rtf.dart`): a small tokeniser that keeps the text, paragraph breaks
  and escaped characters, drops font tables, pictures and headers, and shows notes after
  their paragraph without reading them.
- **TXT, Markdown, HTML** (`formats/text.dart`): hard-wrapped lines joined into
  paragraphs, chapters found from their headings, a Project Gutenberg text named by its
  header and read without its header and licence. Markdown's marks are not read, its
  tables are read a row at a time, and fenced code is left out.
- **Encodings.** BOM, then UTF-8, then the rest: a text in an East Asian legacy encoding
  (GBK, Big5, Shift_JIS, EUC-JP/KR) is decoded by Android's own charsets through the app
  (`encoding.dart`), and Windows code pages read as written.

## 3.6 Sentence and word segmentation

Sentence boundaries are not "split on period". The segmenter must survive `Dr. Smith`,
`e.g.`, `U.S.A.`, `3.14`, `Fig. 4`, ellipses, quotes closing after the terminator
(`"Stop!" he said.`), and languages that do not use spaces between words.

As built, it is TomeVoice's own (`segment.dart`), not ICU: lists of abbreviations and of
titles that stand before a name ("Capt. Smith", "Mt. Everest"), decimals kept whole,
the sentence ends of other scripts (the danda, CJK and Arabic stops), and quotes and
brackets closing after a stop. Russian and Ukrainian dialogue is not cut after "!" or
"?" inside it.

A sentence longer than **280 characters** is split at a clause boundary
(`maxSentenceChars`), because one synthesis call for a 900-character sentence means a
long stall before the first audio and a large buffer to discard on a jump. Chinese and
Japanese words are given their own units, so the highlight and the pause aligner know
where words fall.

## 3.7 Text normalisation for speech

The first design had TomeVoice expand numbers, dates, abbreviations, units and Roman
numerals itself before the voice saw them, with a table of rules. **That was not built.**
Numbers, dates and abbreviations are left to the voice, which reads them in its own
language.

What TomeVoice does change, each change with its source range:

| Kind | What happens | Where |
|---|---|---|
| A footnote's marker | shown, not said | `Sentence.silent` |
| A web address | said as its site ("example dot com"), not letter by letter (on by default) | `speech.dart`, Reading rules |
| A bracketed citation, `[12]`, `[1, 3]` | skipped | `speech.dart` |
| Rows of symbols, `***`, `o0o0o0o` | skipped, if chosen | `skip_presets.dart` |
| Authors' and translators' notes in web novels (`A/N:`, `[TL: …]`) | skipped, if chosen | `skip_presets.dart` |
| A chapter's title said twice | the repeat skipped, if chosen | `skip_presets.dart` |
| A word the reader respelled ("Zorian" as "Zor-ee-an") | said as respelled, for one book or every book | `reading_rules.dart` |
| A line the reader chose not to hear in web novels | left out, for one site or every site | `reading_rules.dart` |

None of these takes anything off the page: the page, the highlight and every saved place
stay as they were. Pronunciation lists can be shared as a file and taken in
(`pronunciation_list.dart`). Homographs (`read`, `lead`, `wind`) are left to the voice
and the reader's own rules ([C-21](09-challenges-and-solutions.md#c-21)).

## 3.8 Language detection

A book's language comes from its metadata (EPUB `dc:language`) where it has one. It is
often wrong (EPUBs ship `en` on Bengali novels) and TXT, PDF and DOCX carry none, so the
text's script decides wherever it can (`language.dart`): Bengali, Devanagari, Arabic
(and Persian and Urdu by their own letters), Cyrillic, CJK with kana for Japanese, and
more. A Latin-script book keeps its metadata's language. A web novel's language is its
chapters' script, not the site's label.

There is no per-block switching: a book is read in one language's voice, with a
dialogue voice and character voices on top ([05 §5.10](05-tts-controls-spec.md#510-multi-voice-and-language)).

## 3.9 Indexing and caching

After ingestion the book is kept as `books/<id>/parsed.json`, `{"v": <parse version>,
"book": ...}`, beside the original file ([11](11-data-model-and-storage.md)).
Re-opening a book is then a read, not a re-parse. When reading improves enough
(`_parsedVersion` in `library_store.dart`, `pdfParserVersion` for PDFs), stored books are
parsed again from their own file the next time they open, and the place is carried
across by the sentence's words.

Not built from the first design: a full-text search index (search runs over the reading
layout on a background isolate instead) and a separate alignment map on disk.

## 3.10 Web pages, web novels, catalogues and imports

**Web novels.** Sources are LNReader plugins run in QuickJS ([ADR-019](10-decisions-adr.md#adr-019)).
A chapter arrives as the site's HTML and becomes a section through the same HTML-to-blocks
code as an EPUB (`formats/web.dart`), with site furniture dropped: "Read the latest
chapters at…" watermarks, translator and editor credits, Previous/Next links, rows of
dashes. A web novel is a book whose sections are its chapters. The reader lays out a
window of them (up to ten downloaded chapters before the place and thirty from it,
`webWindow`), joins the next ones on as the voice reaches the end, and fetches three
ahead (`web_reader.dart`). Chapters are kept by their address on the site, so a site
that re-files its list does not move downloads, places or quotes.

**Shared links and words** (`shared_text.dart`, `article.dart`). A link shared from a
browser, or pasted, becomes an article: the page read the forgiving way a browser reads
it (`html_tree.dart`), its menus, ads and comments left out, then made into an HTML
document the documents package reads like any book, on the Articles shelf. A Wikipedia
page is kept whole without its lists of sources. A link to a book file imports the book;
any other shared words become a book named from their first line.

**Catalogues** (`opds.dart`, `catalogues_screen.dart`). OPDS 1.2 feeds, searched through
OpenSearch. Project Gutenberg and Standard Ebooks are built in; a Calibre content server
on the same network, or any other OPDS catalogue, can be added. A book downloaded from
one is imported like any file.

**NovelDokusha import.** Settings → Library → Import from NovelDokusha takes the zip
that NovelDokusha's own Settings → Backup writes.

- `NovelDokushaImport.kt` unpacks its Room database (`database.sqlite3`, tables `Book`,
  `Chapter`, `ChapterBody`) into the cache and reads the books in its library
  (`inLibrary = 1`): title, address, cover, description and last chapter read; each
  book's chapters in order, with their read marks; and each downloaded chapter's text. It
  writes them as JSON lines, one book's list and one chapter's text at a time, so neither
  side holds the whole library in memory.
- `noveldokusha_import.dart` matches each novel to an installed or listed source by its
  site's host and rewrites its addresses the way that plugin writes its paths, so the
  next check for new chapters finds them. Downloaded chapters (plain paragraphs separated
  by blank lines) become HTML paragraphs and are kept, readable offline at once. The
  place is the last chapter read, else the first unread one.
- NovelDokusha's local books (EPUBs imported into it, `local://`) come back as EPUBs made
  from the chapter text in the backup.

Its limits:

- Only the chapter is carried, not the place inside it.
- Read marks only choose the place; they do not become TomeVoice's read marks.
- Pictures in chapter text are left out.
- A novel whose site no source list knows is still imported and reads from the chapters
  that came with it, but gets no new chapters; the import names such novels, and
  "Move to another source" on the novel's page can join one to a source later.
- A database that unpacks to more than 2 GB, or would leave less than 256 MB free, is
  refused.

NovelDokusha (GPL-3.0, unmaintained) hard-codes 26 Kotlin scrapers, one per site; half
of its English sites were dead or hijacked by October 2026. That is why TomeVoice's own
sources are LNReader plugins, which their community keeps working
([ADR-019](10-decisions-adr.md#adr-019)).
