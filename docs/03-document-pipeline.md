# 03 — Document Pipeline

How an arbitrary file on disk becomes something we can both render and speak.

```
file  ->  detect  ->  parse  ->  classify  ->  segment  ->  normalise  ->  index
                       |            |             |             |
                    structure     roles       sentences +    speech text
                    + raw text   (skip?)        words      (per sentence)
```

Two text streams come out of this, and keeping them distinct is essential:

- **Display text** — what the reader shows. Preserves the author's characters exactly.
- **Speech text** — what goes to the synthesiser. "Dr." becomes "Doctor", "1996" becomes
  "nineteen ninety-six", "§" becomes "section", a bare URL becomes its domain.

They must stay **aligned by character range**, because word highlighting happens in
display space while word timings arrive in speech space. Every normalisation rule
therefore emits an edit with its source range, and the pipeline keeps a mapping table.
A rule that cannot report its source range is not allowed into the normaliser.

## 3.1 Format detection

Extension first, then magic bytes, then content sniffing. Never trust the extension
alone — a `.epub` that is actually a zip of images is a scanned book, not an EPUB, and
must be routed to the OCR path rather than failing with a parse error.

| Signature | Format |
|---|---|
| `PK\x03\x04` + `mimetype` = `application/epub+zip` | EPUB |
| `PK\x03\x04` + `word/document.xml` | DOCX |
| `%PDF-` | PDF |
| `BOOKMOBI` / `TPZ` at offset 60 | MOBI / AZW (v1.x) |
| `\x3C\x68\x74\x6D\x6C` etc. | HTML |
| BOM / UTF-8 validity | TXT, MD |

If the file is encrypted (`META-INF/encryption.xml` in an EPUB, `/Encrypt` in a PDF
trailer with a non-empty owner password), we stop and show a clear message. See
[C-07](09-challenges-and-solutions.md#c-07).

## 3.2 EPUB

EPUB is the easy format, which is why it is the reference implementation.

**Parse.** Read `META-INF/container.xml` -> OPF path. From the OPF take metadata, the
manifest, and the **spine** (reading order — the format hands it to us, unlike PDF).
Read the NCX (EPUB 2) or the nav document (EPUB 3) for the table of contents.

**Extract for speech.** For each spine item, parse the XHTML and walk it into `Block`s.
The element-to-role mapping does most of the classification work for free:

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
| `img` with `alt` | `figure` (alt text spoken only if the setting is on) |

**Anchor.** Each block gets an EPUB CFI. CFIs are structural, not positional, so they
survive font-size changes, theme changes and re-pagination — which is exactly why we do
not use scroll offsets.

**Hard parts.** Real books break rules: `<span>`-per-word markup from bad converters,
footnotes inline in the flow rather than at the end, drop caps split across elements
(`<span class="dropcap">O</span>nce upon`), ruby annotations, and right-to-left or
vertical-writing books. The block builder must join adjacent inline runs before sentence
segmentation, or every drop cap becomes its own sentence.

## 3.3 PDF: the hard one

A PDF does not contain paragraphs. It contains instructions to draw glyphs at
coordinates. Everything above that — words, lines, columns, reading order — is inferred.
This is the largest single engineering cost in the project and it is never perfect.

**Stage 1 — glyph extraction.** PDFium gives per-character boxes, font and size. Do not
use a "get page text" convenience call; it discards the geometry we need.

*Verified 2026-09-01:* `pdfrx` 2.5.0 (MIT, PDFium-backed) exposes `PdfPageText.charRects`
— per-character `PdfRect`s aligned to `fullText` — plus `fragments` for logical grouping.
The geometry this stage depends on is available through the package we already chose; no
custom PDFium binding is needed.

**Stage 2 — words and lines.** Cluster glyphs into words by inter-character gap relative
to the font's average advance width; cluster words into lines by baseline proximity with
a tolerance for superscripts and subscripts.

**Stage 3 — column detection.** Project line bounding boxes onto the x-axis and look for
vertical whitespace gutters that persist down the page. A gutter that survives most of
the page height splits the page into columns. Handle the common academic case (two
columns, full-width title and abstract at the top, full-width figures interrupting the
columns) by segmenting the page vertically first, then detecting columns per band.

**Stage 4 — reading order.** Within a band, order columns left-to-right (or
right-to-left for RTL scripts); within a column, order lines top-to-bottom. Then merge
lines into paragraphs using indentation, line-spacing changes and terminal punctuation.

**Stage 5 — furniture removal.** Text that repeats at the same y-position across many
pages is a running header or footer. Numbers alone in a header/footer band are page
numbers. Both get roles rather than deletion, so the user can turn them back on.

**Stage 6 — hyphenation repair.** A line ending in `-` where the next line starts
lowercase, and where the joined form is in the language's lexicon, is a soft hyphen:
join it. Where the joined form is *not* in the lexicon, keep the hyphen — "well-being"
at a line break must not become "wellbeing", and "co-operate" must not become
"cooperate" if the book's own spelling is hyphenated.

**Stage 7 — footnote separation.** Footnotes sit at the bottom of a column, usually in a
smaller font, often after a rule. Detect by font-size drop plus position, and give them
their own blocks so they can be skipped or read after the paragraph — the user's choice.

**Scanned PDFs.** If a page yields almost no glyphs but has a large image, it is
scanned. v1 detects this and says so honestly; OCR arrives in v1.x
([C-04](09-challenges-and-solutions.md#c-04)).

**Cost control.** Full analysis of a 900-page PDF is far too slow to do on open. We
analyse the current page plus a window around it, promote to background analysis of the
whole document, and persist the result so it is a one-time cost per book.

## 3.4 DOCX

A zip of XML. `word/document.xml` holds the body; `styles.xml` maps style IDs to names,
which is how we distinguish a heading from a paragraph (`Heading1`..`Heading9`), and
`footnotes.xml` / `endnotes.xml` hold the notes.

Handled explicitly:

- **Tracked changes.** `w:ins` and `w:del` runs. Default is to read the *accepted*
  document: include insertions, exclude deletions. A setting can flip this.
- **Comments.** Excluded from speech by default.
- **Tables.** Read cell by cell, row by row, with an optional "row 3, column 2" spoken
  prefix for accessibility.
- **Fields.** Page numbers, cross-references and TOC fields expand to their cached
  result text, not their field code.
- **Text boxes and shapes.** Their text lives outside the main flow; append at the end of
  the containing section rather than interleaving it randomly.

## 3.5 Plain formats

TXT, Markdown, HTML and RTF. Cheap, but two details matter:

- **Encoding detection** for TXT. BOM, then UTF-8 validation, then a statistical guess
  with the user able to override. Getting this wrong garbles the whole book.
- **Markdown and HTML** map to roles directly; code fences become `code` blocks, which
  are skipped by default (reading a code block aloud is almost never wanted, and when it
  is, it needs entirely different normalisation).

## 3.6 Sentence and word segmentation

Sentence boundaries are not "split on period". The segmenter must survive `Dr. Smith`,
`e.g.`, `U.S.A.`, `3.14`, `Fig. 4`, ellipses, quotes closing after the terminator
(`"Stop!" he said.`), and languages that do not use spaces between words.

Approach: ICU sentence break iteration (available through Dart's `intl` / platform ICU)
as the base, plus a per-language exception list for abbreviations, plus post-rules for
the quote and bracket cases. Word segmentation likewise uses ICU word break iteration so
that Chinese, Japanese and Thai — which have no spaces — still produce word units for
highlighting and gap injection.

Very long sentences are split further on clause boundaries at a configurable ceiling
(default 240 characters), because a single synthesis call for a 900-character sentence
means a long stall before first audio and a large buffer to discard on seek.

## 3.7 Text normalisation for speech

Applied to speech text only, each rule emitting a source range for the alignment map.

| Category | Example in | Example out |
|---|---|---|
| Cardinal numbers | `1,024 items` | `one thousand and twenty-four items` |
| Years | `in 1996` | `in nineteen ninety-six` |
| Ordinals | `3rd` | `third` |
| Decimals / currency | `$4.50` | `four dollars fifty` |
| Times / dates | `14:30`, `12/03/2026` | locale-aware expansion |
| Abbreviations | `Dr.`, `St.`, `vs.`, `approx.` | `Doctor`, `Saint`/`Street` (context), `versus`, `approximately` |
| Units | `10 km`, `5 kg` | `ten kilometres`, `five kilograms` |
| Roman numerals in headings | `Chapter XIV` | `Chapter fourteen` |
| Symbols | `&`, `%`, `§`, `#` | `and`, `percent`, `section`, `number` |
| URLs and emails | `https://example.com/a/b` | `example dot com` (configurable: full / domain / skip) |
| Repeated punctuation | `!!!`, `---` | collapsed |
| Emoji | any | name, or skipped (setting) |
| Bare initials | `J. R. R. Tolkien` | letter-by-letter, not "Jay period" |

Two rules are genuinely context-dependent and get their own handling:

- **`St.`** — "Saint" before a capitalised name, "Street" after one.
- **Homographs** — `read`, `lead`, `live`, `bow`, `tear`, `wind`. See
  [C-21](09-challenges-and-solutions.md#c-21). v1 ships a frequency-based default plus a
  user-editable pronunciation dictionary; a small POS-tagging model is a v1.x option.

## 3.8 Language detection

Book-level language comes from metadata (EPUB `dc:language`, DOCX `w:lang`). It is
frequently wrong or absent, so we verify it with an n-gram classifier over the first few
thousand characters.

Block-level detection matters for multilingual books — a Latin epigraph, quoted French
dialogue, a bilingual edition. Detection runs per block, but only *switches voice* when
a run of blocks agrees, because single-block flapping between voices sounds far worse
than reading one foreign sentence in the wrong accent.

## 3.9 Indexing and caching

After ingestion we persist, keyed by a content hash of the source file:

- The Document Model (blocks, roles, sentence and word offsets, anchors)
- The display-to-speech alignment map
- A full-text search index
- PDF layout analysis results (the expensive part)
- Cover art and metadata

Re-opening a book is then a database read, not a re-parse. The cache is invalidated by
content hash, so replacing the file with a different edition rebuilds it, and the schema
version, so a parser improvement rebuilds it too.
