import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

// Real files and the text a voice reads from each. What every file is and
// where it comes from: test/corpus/SOURCES.md. What the goldens hold and how
// to change one on purpose: test/corpus/README.md.

const _dir = 'test/corpus';

/// Set (to 1) to write the goldens from what the parser does now instead of
/// checking them. Every change it makes is to be read before it is kept.
final _update = Platform.environment['TOMEVOICE_UPDATE_GOLDENS'] == '1';

final _sayable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// A corpus file read as the app reads it: parsed, laid out with notes,
/// captions and pictures' words shown but not spoken (notes are not read
/// aloud unless the reader asks), and opened where a new book opens.
class _Reading {
  _Reading(this.file, this.book) : layout = ReadingLayout.build(book, displayOnly: true) {
    start = layout.unitForCursor(ReadingCursor.zero);
  }

  final String file;
  final Book book;
  final ReadingLayout layout;
  late final int start;

  /// What the voice is given for [unit]: its text without its silent
  /// stretches (note marks), or null when that has nothing to say ("* * *"),
  /// which the scheduler passes over.
  static String? said(Speakable unit) {
    final text = spokenText(unit.text, unit.silent).text;
    return _sayable.hasMatch(text) ? text : null;
  }

  /// What the voice says, a sentence an entry, from where a new book opens
  /// to the end.
  late final List<String> spoken = [
    for (final u in layout.units.skip(start))
      if (said(u) case final s?) s,
  ];

  /// [spoken] as one text, to look for words in.
  late final String text = spoken.join('\n');

  /// Chapter titles, as the app lists them.
  List<String> get chapters => [for (var c = 0; c < layout.chapters.length; c++) layout.chapterTitle(c)];

  /// Titles of the sections the layout leaves out: front and back matter,
  /// notes alone, pictures alone.
  List<String> get notRead => [
        for (final s in book.sections)
          if (!layout.chapters.contains(s.index)) s.displayTitle,
      ];

  List<Block> get blocks => [for (final s in book.sections) ...s.blocks];

  /// Blocks shown on the page and never spoken: notes, captions, the words
  /// of a picture.
  List<Block> get displayOnly => [
        for (final b in blocks)
          if (ReadingLayout.displayOnlyRoles.contains(b.role) && b.text.isNotEmpty) b,
      ];

  List<String> displayOnlyOf(BlockRole role) => [
        for (final b in displayOnly)
          if (b.role == role) b.text,
      ];

  /// The golden's facts about the book.
  Map<String, Object?> get facts => {
        'file': file,
        'source': book.source.name,
        'title': book.metadata.title,
        'authors': book.metadata.authors,
        'language': book.metadata.language,
        'sections': [for (final s in book.sections) s.displayTitle],
        'chapters': chapters,
        'notRead': notRead,
        'blocks': {
          for (final role in BlockRole.values)
            if (blocks.where((b) => b.role == role).length case final n when n > 0) role.name: n,
        },
        'displayOnly': [for (final b in displayOnly) '${b.role.name}: ${_short(b.text)}'],
        'sentencesBeforeOpening': start,
        'first': spoken.take(5).toList(),
        'last': spoken.skip(math.max(0, spoken.length - 5)).toList(),
        'sentences': spoken.length,
        'words': book.wordCount,
        'spokenSha256': sha256.convert(utf8.encode(text)).toString(),
      };

  /// The golden text: each chapter's title as the app lists it (marked
  /// "## ", not spoken), then what the voice says in it, a sentence a line.
  String get spokenGolden {
    final out = StringBuffer()
      ..writeln('# $file: what a voice reads, a sentence a line, from where a new book opens.')
      ..writeln('# Written by test/corpus_test.dart; see test/corpus/README.md before changing it.');
    var chapter = -1;
    for (var u = start; u < layout.units.length; u++) {
      final c = layout.chapterOfUnit(u);
      if (c != chapter) {
        chapter = c;
        out.writeln('## ${layout.chapterTitle(c)}');
      }
      if (said(layout.units[u]) case final s?) out.writeln(s);
    }
    return out.toString();
  }
}

String _short(String s) => s.length <= 100 ? s : '${s.substring(0, 99)}…';

String _lf(String s) => s.replaceAll('\r\n', '\n');

/// [file] read as the app reads it. A .pdftext.json file is a recorded PDF
/// extraction (see SOURCES.md), handed over as the app hands the platform's,
/// changed first by [extracted] when given.
_Reading _read(String file, {Map<String, Object?> Function(Map<String, Object?> pdf)? extracted}) {
  final bytes = File('$_dir/$file').readAsBytesSync();
  if (!file.endsWith('.pdftext.json')) return _Reading(file, ingestBytes(bytes, filename: file));
  var pdf = Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
  if (extracted != null) pdf = extracted(pdf);
  final book = ingestPdfText(
    id: bookIdOf(bytes),
    pages: (pdf['text'] as String? ?? '').split(String.fromCharCode(0x0C)),
    outline: pdfOutlineFromPlatform(pdf['outline']),
    layout: pdfLayoutFromPlatform(pdf['layout']),
    title: pdf['title'] as String?,
    author: pdf['author'] as String?,
    filename: file.replaceAll('.pdftext.json', '.pdf'),
  );
  return _Reading(file, resectionPdf(book));
}

/// [pdf] with paragraph marks where PDFBox also puts them when it sees
/// indents (PDFTextStripper.isParagraphSeparation, by its defaults: set in
/// by more than two spaces, a space taken as a quarter of an em): at a line
/// set in after a line that did not start a paragraph, and at a line back
/// at the edge after one that did not. The recorded marks (the top of a
/// page, a drop) stay. A font with a narrow space makes the extractor mark
/// a book so; with a wide one it marks only the drops, as recorded.
Map<String, Object?> _withIndentMarks(Map<String, Object?> pdf) {
  final mark = String.fromCharCode(0x2029);
  final layout = pdfLayoutFromPlatform(pdf['layout'])!;
  final pages = (pdf['text'] as String).split(String.fromCharCode(0x0C));
  final out = <String>[];
  for (var p = 0; p < pages.length; p++) {
    final lines = <({String text, bool start})>[];
    final chunks = pages[p].split(mark);
    for (var c = 0; c < chunks.length; c++) {
      // Each mark starts a paragraph at the line after it.
      var first = c > 0;
      for (final l in chunks[c].split('\n')) {
        if (l.isEmpty) continue;
        lines.add((text: l, start: first));
        first = false;
      }
    }
    final at = p < layout.length ? layout[p] : const <int>[];
    final starts = <bool>[];
    for (var i = 0; i < lines.length; i++) {
      var start = lines[i].start;
      if (!start && i > 0 && at.length == lines.length * 5) {
        final space = at[i * 5 + 3] / 10 / 4;
        final gap = at[i * 5] - at[(i - 1) * 5];
        if (gap > 2 * space || gap < -space) start = !starts[i - 1];
      }
      starts.add(start);
    }
    out.add([for (var i = 0; i < lines.length; i++) '${starts[i] ? mark : ''}${lines[i].text}'].join('\n'));
  }
  return {...pdf, 'text': out.join(String.fromCharCode(0x0C))};
}

/// Check [r] against its goldens, or write them when updating.
void _golden(_Reading r) {
  final json = File('$_dir/golden/${r.file}.json');
  final txt = File('$_dir/golden/${r.file}.txt');
  final facts = jsonDecode(jsonEncode(r.facts)) as Map<String, Object?>;
  if (_update) {
    json.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(facts)}\n');
    txt.writeAsStringSync(r.spokenGolden);
    return;
  }
  const how = 'If the change is meant, write the goldens again and read the diff: test/corpus/README.md.';
  expect(json.existsSync() && txt.existsSync(), isTrue, reason: 'No golden for ${r.file}. $how');
  // The spoken text first: the line where it changed says the most.
  final want = _lf(txt.readAsStringSync()).split('\n');
  final got = r.spokenGolden.split('\n');
  String? changed;
  for (var i = 0; changed == null && (i < want.length || i < got.length); i++) {
    final a = i < want.length ? want[i] : '(end of the golden)';
    final b = i < got.length ? got[i] : '(end of the text)';
    if (a != b) changed = 'line ${i + 1} of golden/${r.file}.txt\n  golden: $a\n  now:    $b';
  }
  expect(changed, isNull, reason: 'What a voice reads from ${r.file} changed. $how');
  final golden = jsonDecode(_lf(json.readAsStringSync())) as Map<String, Object?>;
  for (final key in {...golden.keys, ...facts.keys}) {
    expect(facts[key], golden[key], reason: '"$key" of ${r.file} changed. $how');
  }
}

/// A check of one thing a reader would notice, written by hand from reading
/// the file; [skip] says why one that fails today is not yet fixed.
typedef _Check = ({String name, void Function(_Reading r) check, String? skip});

_Check _check(String name, void Function(_Reading r) check, {String? skip}) =>
    (name: name, check: check, skip: skip);

/// The sentences of [r] that hold [words].
Iterable<String> _with(_Reading r, String words) => r.spoken.where((s) => s.contains(words));

final _corpus = <String, List<_Check>>{
  // Standard Ebooks: endnotes, parts holding chapters, figures, and the
  // pages about the edition every Standard Ebooks book has.
  'edwin-a-abbott_flatland.epub': [
    _check('opens on the preface: title page, imprint, dedication and half-title are not read', (r) {
      expect(r.spoken.first, 'Preface to the Second and Revised Edition, 1884');
      expect(r.notRead, containsAll(['Flatland', 'Imprint', 'Section 3']));
    }),
    _check('chapters follow the contents, each with its part', (r) {
      expect(r.chapters, hasLength(23));
      expect(r.chapters[1], 'Part I: This World · I: Of the Nature of Flatland');
      expect(r.chapters[12], 'Part I: This World · XII: Of the Doctrine of Our Priests');
      expect(r.chapters[13], 'Part II: Other Worlds · XIII: How I Had a Vision of Lineland');
      expect(r.chapters.last, startsWith('Part II: Other Worlds · XXII:'));
    }),
    _check('the list of illustrations, colophon and Uncopyright are not read', (r) {
      expect(r.chapters, isNot(contains('List of Illustrations')));
      expect(r.text, isNot(contains('Standard Ebooks')));
      expect(r.spoken.last, 'appear no better than the offspring of a diseased imagination, or the baseless fabric of a dream.');
    }),
    _check('endnotes are shown, not read, and their marks are not said', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), hasLength(7));
      expect(r.text, isNot(contains('The author desires me to add')));
      expect(r.spoken, contains('Rarely—in proportion to the vast numbers of Isosceles births—is a genuine and certifiable '
          'Equal-Sided Triangle produced from Isosceles parents.'));
    }),
    _check("figures' descriptions are shown, not read", (r) {
      expect(r.displayOnlyOf(BlockRole.figure), contains(startsWith('A diagram of three triangles, points downwards.')));
      expect(_with(r, 'A diagram of three triangles'), isEmpty);
    }),
  ],

  // A collection: thirty-four parables, a file each, two titles in quotes.
  'kahlil-gibran_the-madman.epub': [
    _check('opens on the prologue: title page and imprint are not read', (r) {
      expect(r.spoken.first, 'You ask me how I became a madman.');
      expect(r.notRead, ['The Madman', 'Imprint', 'Colophon', 'Uncopyright']);
    }),
    _check('every parable is a chapter, in the order of the contents', (r) {
      expect(r.chapters, hasLength(35));
      expect(r.chapters.take(4), ['Prologue', 'God', 'My Friend', 'The Scarecrow']);
      expect(r.chapters, containsAllInOrder(['“Defeat”', 'Night and the Madman', '“The Perfect World”']));
      expect(r.spoken.last, 'Why am I here, O God of lost souls, thou who art lost amongst the gods?');
    }),
    _check('a dash joined to its word has no space before it', (r) {
      expect(_with(r, 'my masks were stolen—the seven masks'), hasLength(1));
      expect(r.text, isNot(contains(' —')));
    }),
  ],

  // Project Gutenberg's EPUB: its header and licence, a footnote, an
  // epigraph in French and a poem set as a table.
  'pg932-images-3.epub': [
    _check("Gutenberg's header and licence are not read", (r) {
      expect(r.text, isNot(contains('Gutenberg')));
      expect(r.spoken.first, 'THE FALL OF THE HOUSE OF USHER');
    }),
    _check('the footnote is shown, not read, and its mark is not said', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), [startsWith('* Watson, Dr. Percival, Spallanzani')]);
      expect(_with(r, 'for other men have thought thus'), hasLength(1));
      expect(r.text, isNot(contains('men*')));
    }),
    _check('the epigraph and the poem are read', (r) {
      expect(r.spoken, contains('Son cœur est un luth suspendu; Sitôt qu’on le touche il résonne.'));
      expect(_with(r, 'In the greenest of our valleys'), hasLength(1));
    }),
  ],

  // The same book as Gutenberg's Kindle file (KF8): calibre renames every
  // class, and stores links as kindle:pos.
  'pg932-images-kf8.mobi': [
    _check("Gutenberg's header and licence are not read", (r) {
      expect(r.text, isNot(contains('Gutenberg')));
      expect(r.text, isNot(contains('Release date')));
      expect(r.spoken.first, 'THE FALL OF THE HOUSE OF USHER');
      expect(r.chapters, ['THE FALL OF THE HOUSE OF USHER']);
    }),
    _check(
      'says what the EPUB says',
      (r) => expect(r.spoken, _read('pg932-images-3.epub').spoken),
      skip: 'Known bug: a KF8 book\'s footnotes are read aloud and their marks said ("for other men* have '
          'thought thus", then "* Watson, Dr. Percival..." in the flow). Its links are stripped from the HTML '
          '(kindle:pos targets are not resolved), so markers and notes cannot be found.',
    ),
  ],

  // The same book as Gutenberg's plain text: UTF-8, CRLF, hard-wrapped
  // paragraphs of twenty lines and more, the header and licence around it.
  'pg932.txt': [
    _check("Gutenberg's header and licence are not read", (r) {
      expect(r.text, isNot(contains('Gutenberg')));
      expect(r.spoken.first, 'The Fall of the House of Usher');
    }),
    _check('paragraphs are joined from their lines, not read a line at a time', (r) {
      expect(r.blocks.length, lessThan(70));
      expect(r.spoken, contains(startsWith('During the whole of a dull, dark, and soundless day in the autumn of the year, '
          'when the clouds hung oppressively low in the heavens')));
    }),
  ],

  // Word: a title page, a contents field, a footnote and an endnote, hidden
  // text, a tracked change, a text box stored twice, a table and a list.
  'gen-aesop.docx': [
    _check('opens on the first fable: the title page is passed over, the contents not read', (r) {
      expect(r.start, greaterThan(0));
      expect(r.spoken.first, 'The Lion And The Mouse');
      expect(r.text, isNot(contains('Contents')));
      expect(r.chapters.first, 'Fables of Aesop');
    }),
    _check('the footnote and the endnote are shown, not read; their marks are not said', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), hasLength(2));
      expect(r.text, isNot(contains('La Fontaine')));
      expect(r.text, isNot(contains('¹')));
    }),
    _check('hidden text and a deleted word are not read; an inserted word is', (r) {
      expect(r.text, isNot(contains('check this against the Greek')));
      expect(_with(r, 'Sirrah, last year you sorely insulted me.'), hasLength(1));
      expect(r.text, isNot(contains('grossly')));
    }),
    _check('a text box is read once', (r) {
      expect(_with(r, 'In some tellings the race is run between a fox and a snail.'), hasLength(1));
    }),
  ],

  // LibreOffice: a generated table of contents, a picture with a title and
  // a description, a footnote and an endnote, a list and a table.
  'gen-madman.odt': [
    _check('the table of contents and the picture\'s description are not read', (r) {
      expect(r.text, isNot(contains('Table of Contents')));
      expect(r.text, isNot(contains('A scarecrow in a field')));
      expect(r.spoken.first, 'The Scarecrow');
      expect(r.spoken[1], 'Once I said to a scarecrow, “You must be tired of standing in this lonely field.”');
    }),
    _check('the footnote and the endnote are shown, not read', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), ['¹ Gibran wrote these parables in English, in New York.', 'i Ninavah is Nineveh, on the Tigris.']);
      expect(_with(r, 'lived a woman and her daughter, who walked in their sleep.'), hasLength(1));
    }),
  ],

  // Word's RTF: font, colour and style tables, info, header and footer, a
  // footnote, a picture, a field, \'hh, \uN and a Cyrillic font.
  'gen-aesop.rtf': [
    _check('the header, footer, footnote, picture and field code are not read', (r) {
      expect(r.text, isNot(contains('Fables of Aesop')));
      expect(r.text, isNot(contains('Townsend has the Wolf')));
      expect(r.text, isNot(contains('89504e47')));
      expect(r.text, isNot(contains('HYPERLINK')));
      expect(r.spoken.first, 'FABLES OF AESOP');
    }),
    _check('text in a Cyrillic font and in \\u escapes is read as written', (r) {
      expect(r.spoken, contains('The same lesson is a Russian proverb: Тише едешь — дальше будешь.'));
      expect(r.spoken.last, 'The Greek for a fable is μῦθος, and the fables are online at Project Gutenberg.');
    }),
  ],

  // FictionBook in windows-1251: a book-level epigraph, two-line titles, a
  // poem, a cite, a subtitle of asterisks, a note.
  'gen-mayak.fb2': [
    _check('windows-1251 is read as Russian, with no stray characters', (r) {
      expect(r.book.metadata.title, 'Маяк на Белом мысу');
      expect(r.book.metadata.language, 'ru');
      expect(r.text, isNot(contains(String.fromCharCode(0xFFFD))));
    }),
    _check('the epigraph is kept, on a title page that a new book passes over', (r) {
      expect(r.chapters.first, 'Маяк на Белом мысу');
      expect(r.layout.units.take(r.start).map((u) => u.text),
          ['Маяк на Белом мысу', 'Горит огонь над чёрною водой,', 'И кто-то ждёт, и кто-то будет дома.', 'Песня смотрителей']);
      expect(r.spoken.take(2), ['Глава первая', 'Смотритель']);
    }),
    _check('abbreviations and initials do not end a sentence', (r) {
      expect(r.spoken, contains(startsWith('Маяк на Белом мысу построили в 1868 г., т. е. ровно за сто лет')));
      expect(_with(r, 'начальник порта А. П. Гриневский, пожимая руку.'), hasLength(1));
      expect(_with(r, 'и т. д., и т. п., — думал он с улыбкой.'), hasLength(1));
    }),
    _check('the note is shown, not read; its mark is not said; "* * *" is passed over', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), contains(startsWith('Камни у Белого мыса')));
      expect(_with(r, 'маленькое судно шло прямо на камни.'), hasLength(1));
      expect(r.text, isNot(contains('* * *')));
    }),
    _check(
      "a dash after an exclamation, then the speaker's words, is one sentence",
      (r) => expect(r.spoken, contains('— Огонь держать до утра! — крикнул Андреич коту, хотя кот, конечно, ничего не понял.')),
    ),
  ],

  // pandoc's HTML5: a contents nav, a scene break of asterisks, a figure
  // with a caption, endnotes, a style and a script.
  'gen-parables.html': [
    _check('the contents nav, the style and the script are not read', (r) {
      expect(r.spoken.take(4), ['Four Parables', 'from The Madman (1918)', 'Kahlil Gibran', 'Four of the thirty-four parables in Gibran’s first book in English.']);
      expect(r.text, isNot(contains('readingTime')));
      expect(r.text, isNot(contains('max-width')));
    }),
    _check('the endnotes and the figure are shown, not read; the marks are not said', (r) {
      expect(r.displayOnly.map((b) => b.role), [BlockRole.figure, BlockRole.caption, BlockRole.footnote, BlockRole.footnote]);
      expect(r.spoken, contains('Once there ruled in the distant city of Wirani a king who was both mighty and wise.'));
      expect(r.text, isNot(contains('Wirani is not on any map')));
      expect(r.text, isNot(contains('* * *')));
    }),
  ],

  // Markdown: front matter, setext headings, a footnote, a table, lists, a
  // code block, a picture, a comment and a rule of asterisks.
  'gen-coast-path.md': [
    _check('headings underlined with = or - are chapters, their underlines not read', (r) {
      expect(r.chapters, ['A Week on the Coast Path', 'Day One: Lantern Cove', 'Day Two: The Salt Road', 'Day Three: Gull Point']);
      expect(r.text, isNot(contains('==')));
      expect(r.text, isNot(contains('---')));
    }),
    _check('front matter, code, the comment and the picture are not read', (r) {
      expect(r.text, isNot(contains('draft:')));
      expect(r.text, isNot(contains('Grid reference')));
      expect(r.text, isNot(contains('TODO')));
      expect(r.displayOnlyOf(BlockRole.figure), ["A sketch map of the second day's walk"]);
    }),
    _check('the footnote is shown, not read; its mark is not said', (r) {
      expect(r.text, isNot(contains('[^')));
      expect(r.spoken, contains('By noon we could see Lantern Cove below us, its harbour wall curled like a hand around six small boats.'));
      expect(r.displayOnlyOf(BlockRole.footnote), ['¹ The tide tables were an hour out all week; nobody knew why.']);
    }),
  ],

  // Notepad's "Unicode": UTF-16 little-endian with a byte order mark, CRLF.
  'gen-clockmaker-utf16.txt': [
    _check('UTF-16 is read, accents and Greek included', (r) {
      expect(_with(r, 'came to Zürich with one letter'), hasLength(1));
      expect(_with(r, 'someone had written Αθήνα'), hasLength(1));
    }),
    _check('chapter lines are chapters; the title line is passed over', (r) {
      expect(r.chapters, ['CHAPTER I.', 'CHAPTER II.', 'CHAPTER III.']);
      expect(r.spoken.first, 'CHAPTER I.');
    }),
  ],

  // An "ANSI" text: windows-1252 with curly quotes and Æ, CRLF, lines of 70.
  'gen-aesop-cp1252.txt': [
    _check('windows-1252 is read as written', (r) {
      expect(r.spoken.first, 'ÆSOP’S FABLES');
      expect(_with(r, '“What a selfish Dog!”'), hasLength(1));
      expect(r.text, isNot(contains(String.fromCharCode(0xFFFD))));
    }),
    _check('rows of asterisks between fables are passed over', (r) {
      expect(r.text, isNot(contains('*')));
      expect(r.spoken.last, 'THE END');
    }),
  ],

  // Recorded PDF extraction: a small printed book with a title page and a
  // contents page, running heads with folios, a footnote, dialogue set in.
  'pride-and-prejudice.pdftext.json': [
    _check('opens on chapter one: the title and contents pages are not read', (r) {
      expect(r.chapters, ['Chapter I', 'Chapter II', 'Chapter III']);
      expect(r.spoken.first, 'CHAPTER I.');
      expect(r.text, isNot(contains('EGERTON')));
    }),
    _check('running heads and page numbers are not read', (r) {
      expect(r.text, isNot(contains('PRIDE AND PREJUDICE')));
      expect(r.spoken.where((s) => RegExp(r'^\d+$').hasMatch(s)), isEmpty);
      expect(r.spoken.where((s) => s.startsWith('CHAPTER')), ['CHAPTER I.', 'CHAPTER II.', 'CHAPTER III.']);
    }),
    _check('dialogue the extractor ran together is a paragraph a speaker', (r) {
      final texts = r.blocks.map((b) => b.text).toList();
      expect(texts, containsAllInOrder([
        '“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”',
        'Mr. Bennet replied that he had not.',
        '“But it is,” returned she; “for Mrs. Long has just been here, and she told me all about it.”',
        'Mr. Bennet made no answer.',
      ]));
    }),
    _check('the same paragraphs when the extractor marks a paragraph at each indent', (r) {
      // Marked so, two speakers' lines set in one after the other ("How so?
      // how can it affect them?" and "My dear Mr. Bennet," replied his wife)
      // were a paragraph of their own, with no line at the edge, and read
      // as one. (The title page's centred lines are marked apart too.)
      final indents = _read('pride-and-prejudice.pdftext.json', extracted: _withIndentMarks);
      List<String> read(_Reading x) => [
            for (final c in x.layout.chapters)
              for (final b in x.book.sections[c].blocks) b.text,
          ];
      expect(read(indents), read(r));
      expect(indents.spoken, r.spoken);
    }),
    _check('the footnote is shown, not read', (r) {
      expect(r.displayOnlyOf(BlockRole.footnote), [startsWith('1 Michaelmas: the feast of St Michael')]);
      expect(r.text, isNot(contains('quarter day')));
    }),
    _check(
      "the footnote's mark is not said",
      (r) => expect(r.text, isNot(contains('Michaelmas,1'))),
      skip: 'Known bug: in a PDF a note\'s mark is a digit after a word ("before Michaelmas,1 and"), read aloud. '
          'The line layout gives one size a line, so the raised digit cannot be told from the text.',
    ),
  ],

  // Recorded PDF extraction: a two-column booklet with bookmarks, a running
  // head across both columns, folios at the foot, one page drawn right
  // column first.
  'selected-fables.pdftext.json': [
    _check('each bookmark is a chapter, in order; the cover is not read', (r) {
      expect(r.chapters, hasLength(17));
      expect(r.chapters.first, 'The Shepherd’s Boy and the Wolf');
      expect(r.chapters.last, 'The Old Man and Death');
      expect(r.spoken.first, 'The Shepherd’s Boy and the Wolf');
      expect(r.text, isNot(contains('Seventeen fables')));
    }),
    _check('the running head and the folios are not read', (r) {
      expect(r.text, isNot(contains('SELECTED FABLES')));
      expect(r.text, isNot(contains('- 2 -')));
    }),
    _check('columns are read left, then right, even on the page drawn right first', (r) {
      // Read out of order, a fable would open or close mid-sentence: each
      // opens with its title, then words in capitals ("A CROW perishing"),
      // and ends a sentence.
      for (final c in r.layout.chapters) {
        final section = r.book.sections[c];
        final first = section.blocks[1].text.split(' ').first;
        expect(section.blocks.first.text, section.title);
        expect(first, first.toUpperCase(), reason: section.blocks[1].text);
        expect(section.blocks.last.text, matches(RegExp('[.!?”]\$')), reason: section.blocks.last.text);
      }
    }),
  ],

  // Recorded OCR output: a scan in Bengali as Tesseract read it, kept as
  // the app keeps it, with the bookmarks the image-to-PDF tool wrote: one a
  // page, named after the page's picture.
  'kheya-ghat-scan.pdftext.json': [
    _check("the pictures' names in the bookmarks are not chapters; the printed chapters are", (r) {
      expect(r.chapters, ['প্রথম পরিচ্ছেদ: হরিপদ মাঝি', 'দ্বিতীয় পরিচ্ছেদ: বর্ষার রাত', 'তৃতীয় পরিচ্ছেদ: ভোরের নৌকা']);
      expect(r.text, isNot(contains('DSC')));
      expect(r.chapters, everyElement(isNot(contains('.tif'))));
    }),
    _check('opens on the first chapter; the running head and page numbers are not read', (r) {
      expect(r.spoken.first, 'প্রথম পরিচ্ছেদ');
      expect(r.spoken, isNot(contains('খেয়াঘাট')));
      expect(r.spoken.where((s) => RegExp('^[০-৯]+\$').hasMatch(s)), isEmpty);
    }),
    _check('read as Bengali; a sentence a page break cut is whole', (r) {
      expect(r.book.metadata.language, 'bn');
      expect(r.spoken, contains('হাটের দিনে ঘাটে ভিড় হতো খুব বেশি।'));
    }),
  ],
};

void main() {
  test('every corpus file has its checks, and nothing else is in the corpus', () {
    const notes = {'README.md', 'SOURCES.md', '.gitattributes'};
    final files = [
      for (final f in Directory(_dir).listSync())
        if (f is File && !notes.contains(f.uri.pathSegments.last)) f.uri.pathSegments.last,
    ]..sort();
    expect(files, [..._corpus.keys]..sort());
  });

  for (final MapEntry(key: file, value: checks) in _corpus.entries) {
    group(file, () {
      late final _Reading r;
      setUpAll(() => r = _read(file));

      test(_update ? 'golden written' : 'what it says matches its golden', () => _golden(r));
      for (final c in checks) {
        test(c.name, () => c.check(r), skip: c.skip);
      }
    });
  }
}
