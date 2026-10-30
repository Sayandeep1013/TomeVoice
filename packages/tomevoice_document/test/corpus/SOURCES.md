# Where the corpus comes from

Every file here is public domain, CC0, or written for this corpus. Downloaded
files are kept byte for byte as they were served on 30 October 2026
(`.gitattributes` keeps git from touching their line endings).

## Downloaded

| File | Size | What it is | Origin | Licence |
|---|---|---|---|---|
| `edwin-a-abbott_flatland.epub` | 983 KB | *Flatland* (1884), Edwin A. Abbott: endnotes, two parts holding 22 chapters, figures with descriptions and a list of them, a dedication, a half-title, an imprint, a colophon and an "Uncopyright" | Standard Ebooks, "compatible epub": https://standardebooks.org/ebooks/edwin-a-abbott/flatland | Text and illustrations public domain (Abbott died 1926); Standard Ebooks' production CC0 1.0, as the book's Uncopyright page says |
| `kahlil-gibran_the-madman.epub` | 577 KB | *The Madman* (1918), Kahlil Gibran: a collection of 34 parables, a file each, two titles in quotes | Standard Ebooks, "compatible epub": https://standardebooks.org/ebooks/kahlil-gibran/the-madman | Text public domain (Gibran died 1931); production CC0 1.0 |
| `pg932-images-3.epub` | 219 KB | *The Fall of the House of Usher* (1839), Edgar Allan Poe: Gutenberg's header and licence, a footnote, an epigraph in French, a poem set as a table | Project Gutenberg eBook #932, EPUB3: https://www.gutenberg.org/ebooks/932.epub3.images | Text public domain (Poe died 1849); the file carries the Project Gutenberg License, kept as it is |
| `pg932-images-kf8.mobi` | 314 KB | The same book as Gutenberg's Kindle file: KF8 (AZW3), though named `.mobi`, made by calibre | Project Gutenberg eBook #932, "Kindles (kf8)": https://www.gutenberg.org/ebooks/932.kf8.images | As above; licence kept in the file |
| `pg932.txt` | 62 KB | The same book as Gutenberg's plain text: UTF-8, CRLF, hard-wrapped paragraphs of twenty lines and more, the header and licence around it | Project Gutenberg eBook #932, plain text: https://www.gutenberg.org/ebooks/932.txt.utf-8 | As above; licence kept in the file |

## Generated for the corpus

Written by a script (not kept) as the program named would write the file,
from public-domain text or text written for the corpus. Text written for the
corpus is part of TomeVoice, under its licence (GPL-3.0).

| File | Size | What it is | Text from | Licence |
|---|---|---|---|---|
| `gen-aesop.docx` | 10 KB | Word 2016 document: Title and Subtitle paragraphs, a TOC field in a contents control, Heading 1 for each fable, runs split by revision ids, a footnote and an endnote, hidden text, a tracked deletion and insertion, a text box stored twice (mc:Choice and mc:Fallback), page breaks, a table, a bulleted list, a header and a footer | Five fables of Townsend's translation (1867), from Project Gutenberg eBook #21 (https://www.gutenberg.org/ebooks/21) without Gutenberg's header, licence or name; the notes, the aside, the table and the list written for the corpus | Public domain; the rest GPL-3.0 |
| `gen-madman.odt` | 5 KB | LibreOffice Writer document: Title and Subtitle paragraphs, a generated table of contents, Heading 1 for each parable, a picture with a title and a description, a footnote and an endnote, soft page breaks, a list and a table | Five parables of Standard Ebooks' *The Madman*; the notes and the last section written for the corpus | Public domain and CC0; the rest GPL-3.0 |
| `gen-aesop.rtf` | 4 KB | RTF as Word 2003 saves it: font, colour and style tables, an info group, a header and a footer, a footnote, a picture in hex, a HYPERLINK field, `\'hh` bytes, `\uN` escapes, and a line in a Cyrillic font (`\fcharset204`) | Four fables of Townsend's translation (Gutenberg #21); the footnote, the proverb line and the Greek line written for the corpus | Public domain; the rest GPL-3.0 |
| `gen-mayak.fb2` | 4 KB | FictionBook 2 as FictionBook Editor saves it, in windows-1251: a description with a cover, the book's own title and epigraph before its sections, two-line chapter titles, a poem, a cite, an empty line, a subtitle of asterisks, a note link, a notes body and the cover as base64 | A short story in Russian, *Маяк на Белом мысу*, written for the corpus | GPL-3.0 |
| `gen-parables.html` | 6 KB | A standalone HTML5 page as pandoc writes one (`--toc`): a title block, a contents nav, a block quote, a scene break of asterisks, a figure with a caption, endnotes with back links, a style and a script | Four parables of Standard Ebooks' *The Madman*; the introduction, the caption and the notes written for the corpus | Public domain and CC0; the rest GPL-3.0 |
| `gen-coast-path.md` | 2 KB | Markdown: YAML front matter, setext headings, ATX headings, emphasis, a footnote, a block quote, bulleted and numbered lists, a rule of asterisks, a table, a link, a fenced code block, a picture and an HTML comment | Walking notes written for the corpus | GPL-3.0 |
| `gen-clockmaker-utf16.txt` | 3 KB | Notepad's "Unicode": UTF-16 little-endian with a byte order mark, CRLF, a paragraph a line; a title line, "CHAPTER I." lines with subtitles, German, French and Greek words | A short story written for the corpus | GPL-3.0 |
| `gen-aesop-cp1252.txt` | 4 KB | An "ANSI" text: windows-1252 (curly quotes, Æ), CRLF, lines wrapped at 70, titles in capitals, rows of asterisks between fables, THE END | Six fables of Townsend's translation (Gutenberg #21) | Public domain |

## Recorded PDF extractions

PDFs are read by the platform (PDFBox, in `PdfText.kt`) before Dart sees
them, so a PDF case is that extraction, not a PDF. These two are **recorded
fixtures, not live extraction**: built by the same script, not captured from
a device. Each is the map `PdfText.extract` returns: `text` (pages ended by a
form feed, U+2029 where the extractor found a paragraph, lines split by a
newline), `title`, `author`, `outline` (bookmarks with page and level) and
`layout` (x, baseline y, width, size in tenths of a point and length, for
each line). Lines are placed as a typesetter would place them; paragraph
marks go where the extractor was seen to put them on a device, at the top of
a page and after a drop of more than 2.5 line heights, so paragraphs set in
by an indent are run together, as Pride and Prejudice's dialogue was. Each
file's `_note` says the same.

| File | Size | What it is | Text from | Licence |
|---|---|---|---|---|
| `pride-and-prejudice.pdftext.json` | 33 KB | Chapters I to III of *Pride and Prejudice* (1813) as a small printed book, 14 pages: an 1813-style title page, a contents page, chapters opening on a new page with the folio at the foot, running heads with folios (the book on left-hand pages, the chapter on right-hand ones), dialogue set in by an em, words broken at line ends, and an editor's footnote | Standard Ebooks' text of the chapters (https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice); the footnote written for the corpus | Public domain and CC0; the note GPL-3.0 |
| `selected-fables.pdftext.json` | 22 KB | Seventeen fables as a two-column booklet with bookmarks, 4 pages: a cover, a running head across both columns, folios at the foot ("- 2 -"), titles set larger with little space under them, and one page drawn right column first | Townsend's translation (Gutenberg #21); the cover lines written for the corpus | Public domain; the cover lines GPL-3.0 |

A scan has no text of its own: the app reads its pages with OCR
(Tesseract, in `Ocr.kt`) and keeps what it read with the book, in the same
map, as `ocrPdfText` (`app/lib/ocr.dart`) makes it: each page as Tesseract
reads one (its paragraphs opened by U+2029, its lines kept, page numbers and
running heads included), an empty layout for every page, the scan's own
bookmarks, and `ocr` and `ocrPages` for the languages and pages read. Also
built by a script, not captured from a device.

| File | Size | What it is | Text from | Licence |
|---|---|---|---|---|
| `kheya-ghat-scan.pdftext.json` | 5 KB | A short story in Bengali as OCR reads a scan of it, 8 pages: a title page, three chapters each opening on a page with its title under "প্রথম পরিচ্ছেদ" and the like, a running head and Bengali page numbers on the others, a sentence cut by a page, and the bookmarks an image-to-PDF tool writes, one a page named after its picture ("DSC01139.tif") | *খেয়াঘাট* (The Ferry Landing), written for the corpus | GPL-3.0 |
