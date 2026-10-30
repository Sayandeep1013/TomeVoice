import 'dart:math' as math;

import 'package:tomevoice_document/tomevoice_document.dart';

/// What the voice can be told to pass over, each switched on in Reading
/// rules for every book or for one: notes from a web novel's author or its
/// translator, rows of symbols, a chapter's title said twice, and links
/// (said as their site). Never taken off the page, only out of what is
/// said, as a footnote's marker is (Sentence.silent): the page, the
/// highlight and every saved place stay as they were.
enum SkipPreset {
  authorNotes(
    title: 'Authors’ notes',
    detail: 'A/N and Author’s note lines in web novels, and (A/N: …) in a sentence',
    example: ['A/N: Sorry this one is late, exams ate my week!', 'The gate of the Iron Keep opened at dawn.'],
  ),
  translatorNotes(
    title: 'Translators’ notes',
    detail: 'TL note, T/N and Translator’s note lines, and [TL: …] in a sentence',
    example: ['“Senior Brother [TL: shixiong, an older disciple] is back!”', 'TL note: Qi is the inner energy cultivators refine.'],
  ),
  symbols(
    title: 'Symbols and separators',
    detail: 'Rows of symbols between scenes, runs of them in a line, and marks at a word’s edge',
    example: ['o0o0o0o', '~~~ Part Two ~~~', '“Senpai~,” she called. *Sigh.* *** Then she ran.'],
  ),
  chapterTitles(
    title: 'Chapter titles said twice',
    detail: 'A title the text repeats under its chapter’s heading',
    example: ['# Chapter 12: The Iron Keep', 'Chapter 12: The Iron Keep', 'The gate opened at dawn.'],
  ),
  links(
    title: 'Links said as their site',
    detail: 'A web address said by its site, not letter by letter',
    example: ['Art by Mira: https://www.artstation.com/mira/gallery?id=42'],
    byDefault: true,
  );

  const SkipPreset({required this.title, required this.detail, required this.example, this.byDefault = false});

  final String title;
  final String detail;

  /// Paragraphs that show what it leaves out ("# " opens a heading).
  final List<String> example;

  /// On before the reader chooses: links have always been said as their
  /// site; everything else is read until it is switched on.
  final bool byDefault;

  static SkipPreset? byName(Object? name) => values.where((p) => p.name == name).firstOrNull;
}

/// The presets on before the reader chooses (see [SkipPreset.byDefault]).
const defaultPresets = {SkipPreset.links};

/// The presets that leave stretches of text unsaid; links are said, as
/// their site (see respellUnit).
const _quietKinds = {SkipPreset.authorNotes, SkipPreset.translatorNotes, SkipPreset.symbols, SkipPreset.chapterTitles};

/// What [on] leaves unsaid in [unit], a sentence of [book], as stretches of
/// the unit's own text, in order: the notes, rows of symbols and titles
/// said twice that the presets pass over, found with the chapter around it
/// (a note's heading and the paragraphs under it; the title above). [skipped]:
/// the roles the layout does not speak.
List<TextStretch> quietStretches(
  Book book,
  Speakable unit,
  Set<SkipPreset> on, {
  Set<BlockRole> skipped = defaultSkippedRoles,
}) {
  if (!on.any(_quietKinds.contains) || unit.text.isEmpty) return const [];
  final section = _sectionOf(book, unit.sectionIndex);
  if (section == null || unit.blockIndex < 0 || unit.blockIndex >= section.blocks.length) return const [];
  final block = section.blocks[unit.blockIndex];
  if (unit.sentenceIndex < 0 || unit.sentenceIndex >= block.sentences.length) return const [];
  final sentence = block.sentences[unit.sentenceIndex];
  if (sentence.startOffset < 0 || sentence.endOffset > block.text.length || sentence.isEmpty) return const [];
  final raw = sentence.of(block.text);
  // Not the sentence it was found in (a book parsed again since): better
  // nothing left out than the wrong words.
  if (raw.trim() != unit.text) return const [];
  final length = unit.text.length;
  if (on.contains(SkipPreset.symbols) && _decorates(unit.text)) return [(start: 0, end: length)];
  final start = sentence.startOffset + raw.length - raw.trimLeft().length;
  final end = start + length;
  return [
    for (final r in _quietOf(section, on, skipped)[unit.blockIndex])
      if (r.end > start && r.start < end) (start: math.max(r.start, start) - start, end: math.min(r.end, end) - start),
  ];
}

/// [stretches] in order, those that overlap or touch made one.
List<TextStretch> mergeStretches(Iterable<TextStretch> stretches) {
  final sorted = [
    for (final s in stretches)
      if (s.end > s.start) s,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final out = <TextStretch>[];
  for (final s in sorted) {
    if (out.isNotEmpty && s.start <= out.last.end) {
      if (s.end > out.last.end) out.last = (start: out.last.start, end: s.end);
    } else {
      out.add(s);
    }
  }
  return out;
}

Section? _sectionOf(Book book, int index) {
  if (index >= 0 && index < book.sections.length && book.sections[index].index == index) return book.sections[index];
  return book.sections.where((s) => s.index == index).firstOrNull;
}

/// What each block of [s] leaves unsaid, found once for a chapter and the
/// presets and roles it was asked with.
final _found = Expando<({int key, List<List<TextStretch>> blocks})>('quiet');

List<List<TextStretch>> _quietOf(Section s, Set<SkipPreset> on, Set<BlockRole> skipped) {
  var key = 0;
  for (final p in on) {
    if (_quietKinds.contains(p)) key |= 1 << p.index;
  }
  for (final r in skipped) {
    key |= 1 << (16 + r.index);
  }
  final known = _found[s];
  if (known != null && known.key == key) return known.blocks;
  final blocks = _find(s, on, skipped);
  _found[s] = (key: key, blocks: blocks);
  return blocks;
}

List<List<TextStretch>> _find(Section s, Set<SkipPreset> on, Set<BlockRole> skipped) {
  final found = [for (final _ in s.blocks) <TextStretch>[]];
  final spoken = [
    for (var i = 0; i < s.blocks.length; i++)
      if (s.blocks[i].text.isNotEmpty && !s.blocks[i].isImage && !skipped.contains(s.blocks[i].role)) i,
  ];
  void whole(int b) => found[b].add((start: 0, end: s.blocks[b].text.length));

  final notes = {
    if (on.contains(SkipPreset.authorNotes)) _Note.author,
    if (on.contains(SkipPreset.translatorNotes)) _Note.translator,
  };
  if (notes.isNotEmpty) {
    // Whether the story has begun: a note's heading after it is the note
    // at the chapter's end, which may run to that end.
    var story = false;
    for (var k = 0; k < spoken.length; k++) {
      final b = spoken[k];
      final block = s.blocks[b];
      final text = block.text;
      for (final note in notes) {
        for (final m in [..._inline[note]!.allMatches(text), ..._inlineCaps[note]!.allMatches(text)]) {
          found[b].add((start: m.start, end: m.end));
        }
      }
      final note = _noteAt(text, notes);
      if (note == null) {
        // A paragraph that is all a note in brackets is no more story.
        final inBrackets = mergeStretches(found[b]);
        final allNote = inBrackets.length == 1 && inBrackets.single.start == 0 && inBrackets.single.end == text.length;
        if (block.role != BlockRole.heading && !_decorates(text) && !allNote) story = true;
        continue;
      }
      whole(b);
      if (!note.bare) continue;
      // A note's heading alone ("Author's Note:"): its paragraphs follow.
      final body = _noteBody(s, spoken, k, notes, toEnd: story);
      for (final j in body) {
        whole(j);
      }
      k += body.length;
    }
  }

  if (on.contains(SkipPreset.symbols)) {
    for (final b in spoken) {
      final text = s.blocks[b].text;
      if (_decorates(text)) {
        whole(b);
        continue;
      }
      // A web address keeps its marks ("example.com/~ann"): it is said
      // as its site, or as written.
      final addresses = [
        for (final h in speechHints(text))
          if (h.kind == SpeechHintKind.url || h.kind == SpeechHintKind.email) h,
      ];
      bool inAddress(Match m) => addresses.any((h) => m.start < h.end && m.end > h.start);
      for (final m in _markRun.allMatches(text)) {
        // "word———word": a run that joins two words stays, or they would run together.
        if (inAddress(m) ||
            (m.start > 0 &&
                m.end < text.length &&
                _letterOrDigit.hasMatch(text[m.start - 1]) &&
                _letterOrDigit.hasMatch(text[m.end]))) {
          continue;
        }
        found[b].add((start: m.start, end: m.end));
      }
      for (final m in _wordMarks.allMatches(text)) {
        if (!inAddress(m)) found[b].add((start: m.start, end: m.end));
      }
    }
  }

  if (on.contains(SkipPreset.chapterTitles)) _titlesSaidTwice(s, spoken, found);
  return [for (final f in found) mergeStretches(f)];
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

// ------------------------------------------------------------------ notes

enum _Note { author, translator }

/// What may stand before a note's label: "**A/N:**", "~Author's Note~",
/// "— TL Note —", and brackets ("(A/N: …)"), which [_noteAt] leaves to
/// [_inline].
final _lead = RegExp(r'^[\s(\[{（【〔<«*_~=#•·\-–—]*');

/// The brackets [_inline] closes a note at.
final _bracket = RegExp(r'[(\[（【〔]');

/// Abbreviations: they may run on with a space alone ("A/N sorry for…").
const _authorShort = r'a\s*/\s*n';
const _translatorShort = r't\s*/\s*[nl]|tl\s*/\s*n|tln|e\s*/\s*n|ed\s*/\s*n';

/// Words: a colon or a dash must follow, or "Author's notes were found…"
/// would be a note.
const _authorLong = r"authors?['’`]?s?\s+(?:notes?|thoughts?|comments?|words?)"
    r'|(?:a\s+)?(?:notes?|words?)\s+from\s+(?:the\s+)?author';
const _translatorLong = r"tl['’`]?s?\s*notes?|translat(?:or|ion)s?['’`]?s?\s+(?:notes?|comments?|thoughts?)"
    r"|(?:a\s+)?notes?\s+from\s+(?:the\s+)?translator|editors?['’`]?s?\s+notes?";

/// In capitals only, with a colon: a name could be one ("Ed: hello").
const _authorCaps = r'AN';
const _translatorCaps = r'TLN|TL|TN|ED';

final _short = {
  _Note.author: RegExp('(?:$_authorShort)(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true),
  _Note.translator: RegExp('(?:$_translatorShort)(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true),
};
final _long = {
  _Note.author: RegExp('(?:$_authorLong)(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true),
  _Note.translator: RegExp('(?:$_translatorLong)(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true),
};
final _caps = {
  _Note.author: RegExp('(?:$_authorCaps)(?![\\p{L}\\p{N}])', unicode: true),
  _Note.translator: RegExp('(?:$_translatorCaps)(?![\\p{L}\\p{N}])', unicode: true),
};

/// After a label: nothing but its marks and a colon ("Author's Note:"), so
/// it heads the paragraphs after it.
final _bareRest = RegExp(r'^[\s*_~)\]}】〕>»=#•·:：\-–—.!]*$');

/// After a label: a colon or a dash once its marks are passed
/// ("**A/N**: …").
final _dashRest = RegExp(r'^[\s*_~)\]}】〕>»]*[:：\-–—]');
final _colonRest = RegExp(r'^[\s*_~)\]}】〕>»]*[:：]');

/// "(A/N: …)" and "[TL: …]" inside a sentence, with the space before
/// them, to the closing bracket (or the paragraph's end, left open).
RegExp _inlineIn(String short, String long, {bool caseSensitive = false}) {
  final label = [
    if (short.isNotEmpty) '(?:$short)(?![\\p{L}\\p{N}])(?:\\s*[:：\\-–—]|\\s)',
    if (long.isNotEmpty) '(?:$long)\\s*[:：\\-–—]',
  ].join('|');
  String within(String open, String close) => '$open\\s*(?:$label)[^$close]*(?:$close|\$)';
  return RegExp(
    '\\s?(?:${within('\\(', '\\)')}|${within('\\[', '\\]')}|${within('（', '）')}|${within('【', '】')}'
    '|${within('〔', '〕')})',
    caseSensitive: caseSensitive,
    unicode: true,
  );
}

final _inline = {
  _Note.author: _inlineIn(_authorShort, _authorLong),
  _Note.translator: _inlineIn(_translatorShort, _translatorLong),
};
final _inlineCaps = {
  _Note.author: _inlineIn('', _authorCaps, caseSensitive: true),
  _Note.translator: _inlineIn('', _translatorCaps, caseSensitive: true),
};

/// [text] as a paragraph a note is: of which kind, and whether it is the
/// note's heading alone ([bare]). Null when it is not one, or when it opens
/// with a bracket (the note is then what the brackets hold; see [_inline]).
({_Note kind, bool bare})? _noteAt(String text, Set<_Note> kinds) {
  final lead = _lead.firstMatch(text);
  final at = lead?.end ?? 0;
  if (lead != null && _bracket.hasMatch(lead[0]!)) return null;
  for (final kind in kinds) {
    if (_short[kind]!.matchAsPrefix(text, at) case final m?) {
      final rest = text.substring(m.end);
      if (_bareRest.hasMatch(rest)) return (kind: kind, bare: true);
      if (_dashRest.hasMatch(rest) || rest.startsWith(' ')) return (kind: kind, bare: false);
    }
    if (_long[kind]!.matchAsPrefix(text, at) case final m?) {
      final rest = text.substring(m.end);
      if (_bareRest.hasMatch(rest) && text.length <= 80) return (kind: kind, bare: true);
      if (_dashRest.hasMatch(rest)) return (kind: kind, bare: false);
    }
    if (_caps[kind]!.matchAsPrefix(text, at) case final m?) {
      final rest = text.substring(m.end);
      if (_colonRest.hasMatch(rest)) return (kind: kind, bare: _bareRest.hasMatch(rest));
    }
  }
  return null;
}

/// The most paragraphs a note under its own heading is taken to have.
const _longestNote = 10;

/// The paragraphs of the note whose heading is [spoken] block [k] of [s]:
/// those after it, up to a divider, a heading, a chapter's title or another
/// note, or (when [toEnd]: the note comes after the story) to the chapter's
/// end, when that comes within [_longestNote] paragraphs. None when it comes
/// later, or not at all: a heading alone, with the story going on after it.
List<int> _noteBody(Section s, List<int> spoken, int k, Set<_Note> kinds, {required bool toEnd}) {
  final body = <int>[];
  for (var j = k + 1; j < spoken.length; j++) {
    final b = s.blocks[spoken[j]];
    if (b.role == BlockRole.heading || _decorates(b.text) || looksLikeChapterLine(b.text) || _noteAt(b.text, kinds) != null) {
      return body;
    }
    if (body.length == _longestNote) return const [];
    body.add(spoken[j]);
  }
  return toEnd ? body : const [];
}

// ---------------------------------------------------------------- symbols

/// A mark that only decorates: not a letter, a digit, a space or the
/// punctuation sentences are made of.
const _mark = r'''[^\p{L}\p{N}\s.,!?;:'"’‘“”«»„…()\[\]{}¿¡、。，！？；：「」『』【】〔〕（）]''';

/// Three marks or more in a row, spaces between them or not: "***",
/// "~ ~ ~", "=====".
final _markRun = RegExp('$_mark(?:\\s*$_mark){2,}', unicode: true);
final _markRe = RegExp(_mark, unicode: true);

/// Marks at a word's edge, read out by some voices as their names: the
/// stars and lines of *emphasis* and _this_, and the tilde of "Senpai~".
/// Not one between two letters or digits ("snake_case", "5*3").
final _wordMarks = RegExp(
  r'(?<![\p{L}\p{N}])[*_~]{1,2}(?=[\p{L}\p{N}])'
  r'''|(?<=[\p{L}\p{N}.,!?…'’"”])[*_~]+(?![\p{L}\p{N}])''',
  unicode: true,
);

/// The letters a row is made of ("o0o0o", "-x-x-", "°º¤ø,¸¸,ø¤º°").
const _rowLetters = 'oO0xXøØºª';
final _row = RegExp('^(?:[$_rowLetters]|$_mark)+\$', unicode: true);
final _space = RegExp(r'\s+');

/// A line that only decorates: nothing but symbols ("* * *", "◆◆◆"), or the
/// letters o and x made into a row ("o0o0o", "-x-x-", "xXx"). "Oooo" is a
/// sound and "000" a number: a row has marks in it, or turns from one of
/// its letters to another and back.
bool _decorates(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (!_letterOrDigit.hasMatch(t)) return true;
  final bare = t.replaceAll(_space, '');
  if (bare.length < 3 || !_row.hasMatch(bare)) return false;
  if (_markRe.hasMatch(bare)) return true;
  var turns = 0;
  String? last;
  for (final c in bare.split('')) {
    if (last != null && c != last) turns++;
    last = c;
  }
  return turns >= 2;
}

// --------------------------------------------------------- chapter titles

/// How far into a chapter a title said again is looked for, in paragraphs.
const _titleWindow = 6;

/// The longest a title is.
const _longestTitle = 160;

/// Words a title's number goes with, left out when titles are compared
/// ("Chapter 12" says what "12." does).
const _chapterWords = {'chapter', 'chap', 'ch'};

final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// A line that ends as a sentence does, which a title rarely does.
final _endsSentence = RegExp(r'[.!?…"”’»]\s*$');

typedef _Token = ({String word, int start, int end});

/// [text]'s words, lowercase, numbers without their leading zeros (044 is
/// 44), the chapter words left out.
List<_Token> _tokens(String text) => [
      for (final m in _word.allMatches(text))
        if (!_chapterWords.contains(m[0]!.toLowerCase())) (word: _norm(m[0]!), start: m.start, end: m.end),
    ];

String _norm(String w) {
  final n = int.tryParse(w);
  return n == null ? w.toLowerCase() : '$n';
}

/// Whether [later] says nothing that [earlier] did not: every word of it
/// among earlier's.
bool _repeats(List<String> later, List<String> earlier) {
  if (later.isEmpty) return false;
  final left = [...earlier];
  for (final w in later) {
    if (!left.remove(w)) return false;
  }
  return true;
}

/// Where the words [later] repeats from [earlier] end: later opens with all
/// of earlier's ("Chapter 12" then "Chapter 12: The Iron Keep") and says
/// more, which starts there. Null when it does not.
int? _repeatedOpening(List<_Token> later, List<String> earlier) {
  if (earlier.isEmpty || later.length <= earlier.length) return null;
  for (var i = 0; i < earlier.length; i++) {
    if (later[i].word != earlier[i]) return null;
  }
  return later[earlier.length].start;
}

/// A chapter's title said again under it: a line in its first paragraphs
/// that repeats a heading (or a chapter's title) heard before it, left out
/// whole; or, when it is a fuller title that opens with the one before
/// ("Chapter 12" then "Chapter 12: The Iron Keep"), the part it repeats.
/// The first saying is kept. A line that repeats words as a sentence ("Not
/// again." under "Chapter 9: Not Again") is the story's, and stays.
void _titlesSaidTwice(Section s, List<int> spoken, List<List<TextStretch>> found) {
  final heard = <List<String>>[];
  for (final b in spoken.take(_titleWindow)) {
    final block = s.blocks[b];
    final text = block.text;
    if (text.length > _longestTitle) continue;
    final tokens = _tokens(text);
    final words = [for (final t in tokens) t.word];
    if (words.isEmpty) continue;
    final heading = block.role == BlockRole.heading;
    final chapterLine = looksLikeChapterLine(text);
    final titleLike = heading || chapterLine || (words.length <= 10 && !_endsSentence.hasMatch(text));
    if (titleLike && heard.any((t) => _repeats(words, t))) {
      found[b].add((start: 0, end: text.length));
      continue;
    }
    if (chapterLine) {
      for (final t in heard) {
        if (_repeatedOpening(tokens, t) case final end?) {
          found[b].add((start: 0, end: end));
          break;
        }
      }
    }
    if (heading || chapterLine || sameChapterTitle(text, s.title)) heard.add(words);
  }
}
