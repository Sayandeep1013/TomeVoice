# The test corpus

Real files, and what a voice reads from each. `test/corpus_test.dart` reads
every file here as the app reads it and checks two things:

1. **Its golden.** `golden/<file>.json` holds what the parser made of the
   file: the section titles, the chapters as the app lists them, the
   sections it does not read, block counts by role, the blocks shown but
   never spoken (notes, captions, pictures' words), the first and last five
   sentences, how many sentences and words, and a SHA-256 of the whole
   spoken text. `golden/<file>.txt` is that spoken text, a sentence a line,
   under its chapter titles (the lines starting "## ", which are not
   spoken). Any change in what is read fails the test, which names the
   first line or fact that changed.
2. **Checks written by hand** for what a listener would notice: front
   matter not read, notes shown and not read, "* * *" passed over, chapters
   in the order of the contents, encodings read right. A check that fails
   today is skipped, with the reason: each is a known bug.

What a voice reads is what the app reads from a book opened for the first
time: `ReadingLayout.build(book, displayOnly: true)` from
`unitForCursor(ReadingCursor.zero)` to the end, each sentence without its
silent stretches (`spokenText`), and lines with nothing to say passed over,
as the scheduler passes them. The app's own respelling (web addresses,
citations, the reader's rules) is not applied. Where every file comes from,
and its licence: `SOURCES.md`.

## Changing a golden on purpose

A golden changes when the parser changes what it reads. That can be the
point of the change, or a regression: read the difference before keeping it.

1. Run the test. A failure says which file changed, and where.
2. Write the goldens again from the parser as it is now, from
   `packages/tomevoice_document`:

       TOMEVOICE_UPDATE_GOLDENS=1 dart test test/corpus_test.dart

   (in PowerShell: `$env:TOMEVOICE_UPDATE_GOLDENS=1; dart test test/corpus_test.dart`,
   then `Remove-Item Env:TOMEVOICE_UPDATE_GOLDENS`).
3. Read `git diff test/corpus/golden/`. Every changed line should be one you
   meant: a sentence no longer cut in two, a note no longer read. Anything
   else is a bug to fix, not a golden to keep.
4. Run the test again without the variable, and commit the goldens with the
   change that moved them, saying in the message what changed and why.

Never edit a golden by hand. When a known bug is fixed, take the `skip` off
its check in `corpus_test.dart` as well.

## Adding a file

Keep it small and its licence clean (public domain, CC0, or written for the
corpus), add it to `SOURCES.md`, give it an entry with its checks in
`corpus_test.dart`, write its goldens, and read them through before
committing: a golden written from a bug blesses the bug.
