# Test fixtures

Small real files that `test/djvu_test.dart` reads (and `app/test/djvu_import_test.dart`,
which imports the first as the app does). Everything else those tests read is built in
the test, by `test/djvu_fixture.dart`.

| File | Size | What it is | Origin | Licence |
|---|---|---|---|---|
| `game-of-comedy.djvu` | 49 KB | *A Game of Comedy: A Dramatic Sketch in One Act, from the French* (Boston: Walter H. Baker, 1902), by Sherwin Lawrence Cook, all 20 pages of the scan: a bundled DjVu (FORM:DJVM) of 20 pages, each holding only its INFO chunk and its text layer (TXTz, ABBYY's OCR with column, region, paragraph, line and word zones), byte for byte as archive.org served them on 18 November 2026. The pictures (Sjbz, FG44, BG44) and the encoder's note (CIDa) are left out, and the DIRM directory, which lists the files, was written again for what is left, with the pages' own ids, by `bundle` in `test/djvu_fixture.dart` | Internet Archive, Library of Congress collection: https://archive.org/details/gameofcomedydram00cook (`gameofcomedydram00cook.djvu`) | Public domain in the United States: published there in 1902 (works published before 1930 are). The Library of Congress "is unaware of any copyright restrictions for this item" |
| `game-of-comedy-p8.djvu` | 3 KB | Page 8 of the same scan as a one-page DjVu (FORM:DJVU): its INFO and TXTz chunks, byte for byte, and nothing else | As above | As above |

Both were cut from the archive.org file (609 KB) by a script (not kept) that copied
those chunks and nothing else. The scan has no outline (NAVM) and no metadata; the tests
build those.
