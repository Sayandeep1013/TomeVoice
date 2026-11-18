import 'dart:typed_data';

import '../build.dart';
import '../encoding.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

/// [chapters]: how a plain-text book (not Markdown or HTML) is cut into
/// chapters; see [TextChapters].
Book parseText(
  Uint8List bytes, {
  required String id,
  String? filename,
  SourceKind kind = SourceKind.text,
  LegacyDecoder? legacy,
  TextChapters chapters = const TextChapters.auto(),
}) =>
    parseTextString(
      decodeText(bytes, legacy: legacy, markup: kind == SourceKind.html),
      id: id,
      filename: filename,
      kind: kind,
      chapters: chapters,
    );

/// A plain-text file's text as its chapters are cut from it: decoded as
/// [parseText] decodes it, without Project Gutenberg's header and licence.
/// What [previewTextChapters] is given.
String plainTextOf(Uint8List bytes, {LegacyDecoder? legacy}) =>
    _withoutGutenbergLicence(_normalised(decodeText(bytes, legacy: legacy)).replaceAll(_ownMarks, ''));

String _normalised(String raw) => raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// What a chapter rule is: TomeVoice's own finding, lines the reader names,
/// or a count of words.
enum TextChapterKind { auto, lines, words }

/// How a plain-text book is cut into chapters.
///
/// TomeVoice finds chapter lines it knows ("Chapter 12", "第12章", "XII"),
/// and cuts a long text with none into parts of about 4,000 words. Web
/// novels saved as one TXT file often head their chapters some other way
/// ("#12 The Gate", "Ep. 12"), and are then read as parts that start in
/// the middle of a chapter. The reader can name the lines instead: what
/// they start with, or (for those who know them) a regular expression;
/// or have the book cut every so many words.
class TextChapters {
  const TextChapters.auto()
      : kind = TextChapterKind.auto,
        pattern = '',
        regex = false,
        words = 0;

  /// Chapters start at lines beginning with [pattern] (capitals or not),
  /// or with [regex], at lines the regular expression [pattern] matches.
  const TextChapters.lines(this.pattern, {this.regex = false})
      : kind = TextChapterKind.lines,
        words = 0;

  /// A chapter every [words] words or so, cut where a paragraph ends (or a
  /// sentence, in a paragraph longer than that).
  const TextChapters.words(this.words)
      : kind = TextChapterKind.words,
        pattern = '',
        regex = false;

  final TextChapterKind kind;
  final String pattern;
  final bool regex;
  final int words;

  /// The fewest words a chapter rule of words may ask for.
  static const fewestWords = 200;

  bool get isAuto => kind == TextChapterKind.auto;

  /// Why this rule cannot be used, in plain words; null when it can. A
  /// book is never cut by a rule that cannot: it keeps TomeVoice's own
  /// chapters instead.
  String? get problem {
    switch (kind) {
      case TextChapterKind.auto:
        return null;
      case TextChapterKind.words:
        return words < fewestWords ? 'A chapter needs at least $fewestWords words.' : null;
      case TextChapterKind.lines:
        if (pattern.trim().isEmpty) return 'Say what a chapter’s first line starts with.';
        if (regex && _compile(pattern) == null) {
          return 'TomeVoice can’t read this pattern. Check its brackets and backslashes.';
        }
        return null;
    }
  }

  /// Whether [line] (one line, or a paragraph) starts a chapter by this
  /// rule; null for a rule that is not of lines, or cannot be used.
  bool Function(String line)? get lineTest {
    if (kind != TextChapterKind.lines || problem != null) return null;
    if (regex) {
      final re = _compile(pattern)!;
      return (line) {
        final t = line.trim();
        return t.isNotEmpty && t.length <= _longestTitle && re.hasMatch(t);
      };
    }
    final start = collapseWhitespace(pattern).toLowerCase();
    return (line) {
      final t = collapseWhitespace(line);
      return t.isNotEmpty && t.length <= _longestTitle && t.toLowerCase().startsWith(start);
    };
  }

  /// [pattern] as a regular expression, capitals or not; null when it is
  /// not one. With \p{...} and the like where it can, as JavaScript reads
  /// them; written for the older rules (an escaped "_"), as those read it.
  static RegExp? _compile(String pattern) {
    for (final unicode in const [true, false]) {
      try {
        return RegExp(pattern, caseSensitive: false, unicode: unicode);
      } on FormatException {
        // Tried the other way, then given up.
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => switch (kind) {
        TextChapterKind.auto => {'kind': 'auto'},
        TextChapterKind.lines => {'kind': 'lines', 'pattern': pattern, if (regex) 'regex': true},
        TextChapterKind.words => {'kind': 'words', 'words': words},
      };

  /// The rule [json] holds; TomeVoice's own for anything else.
  static TextChapters fromJson(Object? json) {
    if (json is! Map) return const TextChapters.auto();
    switch (json['kind']) {
      case 'lines':
        final p = json['pattern'];
        return p is String ? TextChapters.lines(p, regex: json['regex'] == true) : const TextChapters.auto();
      case 'words':
        final n = json['words'];
        return n is num ? TextChapters.words(n.toInt()) : const TextChapters.auto();
    }
    return const TextChapters.auto();
  }

  @override
  bool operator ==(Object other) =>
      other is TextChapters &&
      other.kind == kind &&
      other.pattern == pattern &&
      other.regex == regex &&
      other.words == words;

  @override
  int get hashCode => Object.hash(kind, pattern, regex, words);
}

/// A line longer than this is a paragraph, whatever it starts with.
const _longestTitle = 100;

/// Fewer characters than this are not a chapter (see isReadingSection).
const _slightest = 80;

/// What [rule] makes of [text] (see [plainTextOf]): how many chapters, the
/// titles of the first [titles] of them ([fallbackTitle] for the text
/// before the first chapter line), and whether the rule cut them (false
/// when it cannot be used, or no line is as it says: the book then keeps
/// TomeVoice's own chapters). Quick enough to follow each letter typed: no
/// block is made and no sentence found, except to cut a paragraph longer
/// than a rule of words.
({int count, List<String> titles, bool ruled}) previewTextChapters(
  String text,
  TextChapters rule, {
  String fallbackTitle = 'Opening',
  int titles = 5,
}) {
  final plan = _plan(text, rule);
  // A piece with next to nothing in it (the title line before the first
  // chapter) is not listed as a chapter by the reader (isReadingSection),
  // and is not counted here.
  final p = plan.paragraphs;
  final cuts = [
    for (var c = 0; c < plan.cuts.length; c++)
      if (p
              .sublist(plan.cuts[c].at, c + 1 < plan.cuts.length ? plan.cuts[c + 1].at : p.length)
              .fold<int>(0, (n, x) => n + x.length + 1) >=
          _slightest)
        plan.cuts[c],
  ];
  final shown = cuts.isEmpty ? plan.cuts : cuts;
  return (
    count: shown.length,
    titles: [for (final c in shown.take(titles)) c.title ?? fallbackTitle],
    ruled: plan.ruled,
  );
}

/// Noncharacters TomeVoice uses inside its own pipeline; never book text.
final _ownMarks = RegExp('[${String.fromCharCode(0xFDD0)}-${String.fromCharCode(0xFDD2)}]');

/// [title] and [author], when given, name the book (an RTF file's \info
/// does). With [marked], [raw] is a parser's text, its silent stretches
/// marked (see [silentMark]); any other text is the book's own, and the
/// marks are taken out of it.
Book parseTextString(
  String raw, {
  required String id,
  String? filename,
  SourceKind kind = SourceKind.text,
  String? title,
  String? author,
  bool marked = false,
  TextChapters chapters = const TextChapters.auto(),
}) {
  raw = _normalised(raw);
  if (!marked) raw = raw.replaceAll(_ownMarks, '');
  // A Gutenberg file names its book in its header: its name is a number.
  final header = kind == SourceKind.text ? _gutenbergHeader(raw) : null;
  if (kind == SourceKind.text) raw = _withoutGutenbergLicence(raw);
  resetBlockIds();
  title ??= header?.title ?? titleFromFilename(filename) ?? _firstLineTitle(raw.replaceAll(_ownMarks, '')) ?? 'Untitled';
  author ??= header?.author;
  final metadata = BookMetadata(title: title, authors: author == null ? const [] : [author]);

  if (kind == SourceKind.markdown) {
    return _markdown(id, metadata, raw, filename);
  }
  if (kind == SourceKind.html) {
    return assembleBook(
      id: id,
      metadata: metadata,
      sections: [(title: title, blocks: blocksFromHtml(raw))],
      source: SourceKind.html,
      filename: filename,
    );
  }
  return assembleBook(
    id: id,
    metadata: metadata,
    sections: sectionsFromPlainText(
      raw,
      fallbackTitle: title,
      chapters: kind == SourceKind.text ? chapters : const TextChapters.auto(),
    ),
    source: kind,
    filename: filename,
  );
}

/// Project Gutenberg's lines around the book in its text files: "*** START
/// OF THE PROJECT GUTENBERG EBOOK THE RAVEN ***", and the same with END
/// (THIS for THE, and no spaces, in older files).
final _gutenbergStart = RegExp(
  r'^[ \t]*\*{3}\s*START OF (?:THE|THIS) PROJECT GUTENBERG E-?BOOK.*$',
  multiLine: true,
  caseSensitive: false,
);
final _gutenbergEnd = RegExp(
  r'^[ \t]*\*{3}\s*END OF (?:THE|THIS) PROJECT GUTENBERG E-?BOOK.*$',
  multiLine: true,
  caseSensitive: false,
);

/// The title and author Project Gutenberg's header gives its book, before
/// the "*** START" line: "Title: The Fall of the House of Usher", "Author:
/// Edgar Allan Poe". A title can go on over indented lines (a subtitle),
/// joined with a colon. Null without the header; either may be null.
({String? title, String? author})? _gutenbergHeader(String raw) {
  final start = _gutenbergStart.firstMatch(raw);
  if (start == null) return null;
  final lines = raw.substring(0, start.start).split('\n');
  String? field(RegExp name) {
    for (var i = 0; i < lines.length; i++) {
      final m = name.firstMatch(lines[i]);
      if (m == null) continue;
      final parts = [m.group(1)!.trim()];
      while (i + 1 < lines.length && _indented.hasMatch(lines[i + 1])) {
        parts.add(lines[++i].trim());
      }
      final value = collapseWhitespace(parts.where((p) => p.isNotEmpty).join(': '));
      return value.isEmpty ? null : value;
    }
    return null;
  }

  return (title: field(_titleField), author: field(_authorField));
}

final _titleField = RegExp(r'^Title:(.*)$', caseSensitive: false);
final _authorField = RegExp(r'^Author:(.*)$', caseSensitive: false);

/// A line that goes on the field above it: set in, and not blank.
final _indented = RegExp(r'^[ \t]+\S');

/// [raw] without Project Gutenberg's header before the book and its licence
/// after it, some 3,000 words that were read aloud at the end of every book
/// from there. Unchanged when the lines are not there, or nothing is
/// between them.
String _withoutGutenbergLicence(String raw) {
  final start = _gutenbergStart.firstMatch(raw);
  final from = start?.end ?? 0;
  final end = _gutenbergEnd.allMatches(raw, from).firstOrNull;
  if (start == null && end == null) return raw;
  final book = raw.substring(from, end?.start ?? raw.length);
  return book.trim().isEmpty ? raw : book;
}

/// Paragraphs and chapters out of plain text.
///
/// Two shapes are common. Gutenberg-style files separate paragraphs with a
/// blank line and hard-wrap the lines inside them; many other files (web
/// dumps, phone notes, translated novels) put one paragraph per line with no
/// blank lines at all. Treating the second shape like the first turned a
/// whole novel into a single paragraph; the first like the second, every
/// line of a story into a sentence of its own.
///
/// [chapters] says where chapters start: TomeVoice's own finding unless the
/// reader set a rule for the book (see [TextChapters]).
List<DraftSection> sectionsFromPlainText(
  String raw, {
  required String fallbackTitle,
  TextChapters chapters = const TextChapters.auto(),
}) {
  final plan = _plan(raw, chapters);
  final p = plan.paragraphs;
  return [
    for (var c = 0; c < plan.cuts.length; c++)
      (
        title: plan.cuts[c].title ?? fallbackTitle,
        blocks: [
          for (var i = plan.cuts[c].at; i < (c + 1 < plan.cuts.length ? plan.cuts[c + 1].at : p.length); i++)
            makeBlock(
              role: plan.headings.contains(i) || _looksLikeHeading(p[i]) ? BlockRole.heading : BlockRole.paragraph,
              text: p[i],
            ),
        ],
      ),
  ];
}

/// A text's paragraphs, which of them are chapter lines (headings), and
/// where its chapters start: at paragraph [at], titled [title] (null: the
/// book's own title, for the text before its first chapter line or a
/// text in one piece); and whether the reader's rule cut it ([ruled]).
typedef _Plan = ({
  List<String> paragraphs,
  Set<int> headings,
  List<({int at, String? title})> cuts,
  bool ruled,
});

/// Where [raw]'s chapters start by [rule], worked out on its paragraphs'
/// text alone: [sectionsFromPlainText] makes the blocks after, and
/// [previewTextChapters] needs none.
_Plan _plan(String raw, TextChapters rule) {
  // A rule that cannot be used (a pattern with a mistake) leaves the book
  // as TomeVoice cuts it.
  final lineTest = rule.lineTest;
  final words = rule.kind == TextChapterKind.words && rule.problem == null ? rule.words : null;
  final isChapter = lineTest ?? looksLikeChapterLine;
  var paragraphs = _paragraphs(raw, isChapter, own: lineTest != null);
  if (words != null) {
    // A paragraph longer than a chapter (a whole story on one line) is cut
    // where its sentences end.
    paragraphs = [
      for (final p in paragraphs)
        if (_wordsIn(p) > words) ..._bySentences(p, words) else p,
    ];
  }
  final headings = {
    for (var i = 0; i < paragraphs.length; i++)
      if (isChapter(paragraphs[i])) i,
  };
  if (words != null) {
    return (
      paragraphs: paragraphs,
      headings: headings,
      cuts: _wordCuts(paragraphs, words, tail: words ~/ 3),
      ruled: true,
    );
  }
  // One "chapter" line in a whole file is probably prose, not structure;
  // lines the reader named are chapters however few.
  if (headings.length >= (lineTest != null ? 1 : 2)) {
    final starts = headings.toList()..sort();
    return (
      paragraphs: paragraphs,
      headings: headings,
      cuts: [
        if (starts.first > 0) (at: 0, title: null),
        for (final i in starts) (at: i, title: paragraphs[i]),
      ],
      ruled: lineTest != null,
    );
  }
  if (lineTest != null) return _plan(raw, const TextChapters.auto());
  final total = paragraphs.fold<int>(0, (n, p) => n + _wordsIn(p));
  return (
    paragraphs: paragraphs,
    headings: headings,
    cuts: total < _partWords * 2 ? [(at: 0, title: null)] : _wordCuts(paragraphs, _partWords, tail: _partWords ~/ 3),
    ruled: false,
  );
}

/// [raw]'s paragraphs, in either shape (see [sectionsFromPlainText]); in
/// text whose paragraphs are set apart by blank lines, a line that
/// [isChapter] says heads a chapter is a paragraph of its own; with
/// [own] (the reader's rule), the line after it starts another.
List<String> _paragraphs(String raw, bool Function(String line) isChapter, {bool own = false}) {
  final lines = raw.split('\n');
  final nonEmpty = lines.where((l) => l.trim().isNotEmpty).length;
  var blank = 0;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim().isEmpty && lines[i - 1].trim().isNotEmpty) blank++;
  }
  // A blank line every few lines, or (paragraphs as long as a novel's)
  // fewer blank lines between lines that carry their sentences over.
  final blankSeparated = nonEmpty > 0 && (blank >= nonEmpty / 6 || (blank > 0 && _hardWrapped(lines)));

  final paragraphs = <String>[];
  if (blankSeparated) {
    final buf = <String>[];
    void flush() {
      if (buf.isEmpty) return;
      paragraphs.add(joinWrappedLines(buf));
      buf.clear();
    }

    for (final l in lines) {
      if (l.trim().isEmpty) {
        flush();
      } else if (isChapter(l) && (buf.isNotEmpty || own)) {
        // A line the reader named stands alone even where no blank line
        // follows it; TomeVoice's own finding is left as it always was.
        flush();
        buf.add(l);
        flush();
      } else {
        buf.add(l);
      }
    }
    flush();
  } else {
    for (final l in lines) {
      final t = collapseWhitespace(l);
      if (t.isNotEmpty) paragraphs.add(t);
    }
  }
  return paragraphs;
}

/// About a chapter's worth of words: a long text with no chapters of its
/// own is cut into parts of this size, at paragraph ends, so the reader
/// has places to jump to and a chapter to finish.
const _partWords = 4000;

/// [p]'s words, as its block will count them (without TomeVoice's own
/// marks, which the block takes out).
int _wordsIn(String p) => countWords(p.contains(_ownMarks) ? p.replaceAll(_ownMarks, '') : p);

/// Parts of about [size] words each, cut where a paragraph ends, titled
/// "Part 1", "Part 2"... A last part shorter than [tail] words joins the
/// one before it rather than standing alone; a text that makes only one
/// part is not called one.
List<({int at, String? title})> _wordCuts(List<String> paragraphs, int size, {required int tail}) {
  final starts = [0];
  var words = 0;
  for (var i = 0; i < paragraphs.length; i++) {
    words += _wordsIn(paragraphs[i]);
    if (words >= size && i + 1 < paragraphs.length) {
      starts.add(i + 1);
      words = 0;
    }
  }
  if (starts.length > 1 && words < tail) starts.removeLast();
  if (starts.length == 1) return const [(at: 0, title: null)];
  return [for (var n = 0; n < starts.length; n++) (at: starts[n], title: 'Part ${n + 1}')];
}

/// [p], a paragraph longer than [size] words, as pieces of about that many,
/// each ending where a sentence does.
List<String> _bySentences(String p, int size) {
  final out = <String>[];
  var from = 0;
  var words = 0;
  for (final s in segmentSentences(p, words: false)) {
    words += _wordsIn(p.substring(s.startOffset, s.endOffset));
    if (words >= size) {
      out.add(p.substring(from, s.endOffset).trim());
      from = s.endOffset;
      words = 0;
    }
  }
  final rest = p.substring(from).trim();
  if (rest.isNotEmpty) out.add(rest);
  return [for (final piece in out) if (piece.isNotEmpty) piece];
}

/// Join hard-wrapped lines into one paragraph, mending words that were
/// hyphenated across a line break ("exam-\nple" -> "example"), in any script
/// with lower case: Latin, Cyrillic, Greek. A soft hyphen (U+00AD) at a line
/// end is where a word was broken, whatever follows it; anywhere else it is
/// invisible, and goes.
String joinWrappedLines(List<String> lines) {
  final parts = <String>[];
  for (final raw in lines) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (parts.isNotEmpty) {
      final prev = parts.last;
      final end = prev.codeUnitAt(prev.length - 1);
      if (end == _softHyphen ||
          (prev.length >= 2 &&
              (end == 0x2D || end == 0x2010) &&
              _isLetterUnit(prev.codeUnitAt(prev.length - 2)) &&
              _lowerFirst.hasMatch(l))) {
        parts[parts.length - 1] = prev.substring(0, prev.length - 1) + l;
        continue;
      }
    }
    parts.add(l);
  }
  return collapseWhitespace(
    parts.join(' ').replaceAll(String.fromCharCode(_softHyphen), ''),
  );
}

const _softHyphen = 0xAD;
final _lowerFirst = RegExp(r'^\p{Ll}', unicode: true);

/// Whether [lines] were wrapped at a width, sentences carried over from
/// one line to the next: a quarter or more of the lines that follow
/// another go on in lower case. A file of a paragraph a line starts each
/// with a capital (or is in a script without case, which this cannot tell).
bool _hardWrapped(List<String> lines) {
  var pairs = 0, carried = 0;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || lines[i - 1].trim().isEmpty) continue;
    pairs++;
    if (_lowerFirst.hasMatch(line)) carried++;
  }
  return pairs > 0 && carried * 4 >= pairs;
}

bool _isLetterUnit(int c) =>
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0xC0;

Book _markdown(String id, BookMetadata metadata, String raw, String? filename) {
  final sections = <DraftSection>[];
  String? currentTitle = metadata.title;
  var current = <Block>[];
  final para = <String>[];
  final body = _withoutFrontMatter(raw);

  // Footnotes ("boats.[^tide]", and "[^tide]: The note." below), numbered
  // in the order they are pointed at, as a renderer numbers them. The mark
  // is shown and not said, the note shown and not read in the flow.
  final numbers = <String, int>{};
  for (final m in _footnoteRef.allMatches(body)) {
    numbers.putIfAbsent(m.group(1)!, () => numbers.length + 1);
  }
  String mark(String label) => superscriptNumber(numbers.putIfAbsent(label, () => numbers.length + 1));
  String inline(String s) =>
      _stripInlineMarkdown(s.replaceAllMapped(_footnoteRef, (m) => silentMark(mark(m.group(1)!))));

  void addHeading(int level, String text) {
    if (level <= 2 && current.isNotEmpty) {
      sections.add((title: currentTitle, blocks: current));
      current = [];
    }
    if (level <= 2) currentTitle = text;
    current.add(makeBlock(role: BlockRole.heading, text: text));
  }

  void flushPara() {
    if (para.isEmpty) return;
    final joined = joinWrappedLines(para);
    para.clear();
    // A picture is shown, not described aloud: out of the sentence it sits
    // in, a figure after it, as in HTML.
    final pictures = [for (final m in _picture.allMatches(joined)) inline(m.group(1)!)];
    final text = inline(joined.replaceAll(_picture, ' '));
    if (text.isNotEmpty) {
      current.add(makeBlock(
        role: _listMarker.hasMatch(text) ? BlockRole.listItem : BlockRole.paragraph,
        text: text.replaceFirst(_listMarker, ''),
      ));
    }
    for (final alt in pictures) {
      if (alt.isNotEmpty) current.add(makeBlock(role: BlockRole.figure, text: alt));
    }
  }

  final lines = body.split('\n');
  var inCode = false;
  var inComment = false;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    // HTML comments, which may run over several lines, are not read.
    if (inComment) {
      final close = line.indexOf('-->');
      if (close < 0) continue;
      line = line.substring(close + 3);
      inComment = false;
    }
    line = line.replaceAll(_htmlComment, '');
    final open = line.indexOf('<!--');
    if (open >= 0) {
      inComment = true;
      line = line.substring(0, open);
    }
    if (line.trimLeft().startsWith('```')) {
      flushPara();
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    // A table: a row of cells over a |---|---| line, and the rows below.
    if (line.contains('|') && i + 1 < lines.length && _isTableRule(lines[i + 1])) {
      flushPara();
      current.add(_tableRow(line));
      i++;
      while (i + 1 < lines.length && lines[i + 1].contains('|') && lines[i + 1].trim().isNotEmpty) {
        i++;
        current.add(_tableRow(lines[i]));
      }
      continue;
    }
    final heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$').firstMatch(line);
    if (heading != null) {
      flushPara();
      addHeading(heading.group(1)!.length, inline(collapseWhitespace(heading.group(2)!)));
      continue;
    }
    // A heading underlined with = (level 1) or - (level 2), which was read
    // with its row of = signs. Dashes after a blank line, or under a list
    // item, are a rule.
    final underline = _setextUnderline.firstMatch(line);
    if (underline != null && para.isNotEmpty && !_listLine.hasMatch(para.first)) {
      final text = inline(joinWrappedLines(para));
      para.clear();
      if (text.isNotEmpty) addHeading(underline.group(1)!.startsWith('=') ? 1 : 2, text);
      continue;
    }
    final note = _footnoteDefinition.firstMatch(line);
    if (note != null) {
      flushPara();
      final text = [note.group(2)!];
      while (i + 1 < lines.length &&
          lines[i + 1].trim().isNotEmpty &&
          !_footnoteDefinition.hasMatch(lines[i + 1]) &&
          !lines[i + 1].trimLeft().startsWith('#')) {
        i++;
        text.add(lines[i]);
      }
      current.add(makeBlock(
        role: BlockRole.footnote,
        text: '${silentMark(mark(note.group(1)!))} ${inline(joinWrappedLines(text))}',
      ));
      continue;
    }
    if (line.trim().isEmpty ||
        RegExp(r'^\s*([-*_]\s*){3,}$').hasMatch(line)) {
      flushPara();
      continue;
    }
    if (_listLine.hasMatch(line)) flushPara();
    para.add(line.replaceFirst(RegExp(r'^\s*>\s?'), ''));
  }
  flushPara();
  if (current.isNotEmpty) sections.add((title: currentTitle, blocks: current));

  return assembleBook(
    id: id,
    metadata: metadata,
    sections: sections,
    source: SourceKind.markdown,
    filename: filename,
  );
}

String _stripInlineMarkdown(String s) => collapseWhitespace(decodeEntities(s
    .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'(\*\*|__)(.+?)\1'), (m) => m.group(2)!)
    .replaceAllMapped(RegExp(r'(?<![\w*])[*_](\S.*?)[*_](?![\w*])'),
        (m) => m.group(1)!)
    .replaceAll('`', '')
    // Raw HTML: a line break is a space, any other tag is not read.
    .replaceAll(_htmlBreak, ' ')
    .replaceAll(_htmlTag, '')));

final _listLine = RegExp(r'^\s*([-*+]|\d+[.)])\s+');
final _listMarker = RegExp(r'^([-*+]|\d+[.)])\s+');
final _setextUnderline = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
final _picture = RegExp(r'!\[([^\]]*)\]\([^)]*\)');

/// "[^tide]" in the text; not "[^tide]:", where the note itself starts.
final _footnoteRef = RegExp(r'\[\^([^\]\s]+)\](?!:)');
final _footnoteDefinition = RegExp(r'^ {0,3}\[\^([^\]\s]+)\]:\s*(.*)$');

final _htmlComment = RegExp(r'<!--.*?-->');
final _htmlBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final _htmlTag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>');
final _tableRule = RegExp(r'^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$');

/// The |---|:---:| line under a table's header row.
bool _isTableRule(String line) => line.contains('|') && _tableRule.hasMatch(line);

/// "| Alice | 30 |" as "Alice 30", like a table row in HTML.
Block _tableRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  final cells = [
    for (final c in t.split(RegExp(r'(?<!\\)\|'))) _stripInlineMarkdown(c.replaceAll(r'\|', '|')),
  ];
  return makeBlock(role: BlockRole.table, text: cells.where((c) => c.isNotEmpty).join(' '));
}

/// Markdown without the YAML (---) or TOML (+++) front matter a static
/// site generator puts at the top: settings, not text.
String _withoutFrontMatter(String raw) {
  final lines = raw.split('\n');
  if (lines.isEmpty) return raw;
  final fence = lines.first.trim();
  if (fence != '---' && fence != '+++') return raw;
  for (var i = 1; i < lines.length && i < 200; i++) {
    final t = lines[i].trim();
    if (t == fence || (fence == '---' && t == '...')) return lines.sublist(i + 1).join('\n');
  }
  return raw;
}

/// Bytes to text: a byte order mark, then (for HTML) the charset it
/// declares, then UTF-8 when the bytes are mostly UTF-8, then UTF-16
/// without a mark, an East Asian encoding through [legacy], a Cyrillic code
/// page, and Windows-1252. See [decodeBytes].
String decodeText(Uint8List bytes, {LegacyDecoder? legacy, bool markup = false}) =>
    decodeBytes(bytes, markup: markup, legacy: legacy);

/// Windows-1252: Latin-1 plus curly quotes and dashes in 0x80-0x9F, which is
/// what nearly every "ANSI" text file actually is.
String decodeCp1252(List<int> bytes) => decodeSingleByte(bytes, 'windows-1252');

String? _firstLineTitle(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.length <= 80) return t;
    return null;
  }
  return null;
}

bool _looksLikeHeading(String p) =>
    p.length <= 80 &&
    !p.endsWith('.') &&
    !p.endsWith('?') &&
    !p.endsWith('!') &&
    p == p.toUpperCase() &&
    RegExp(r'[A-Z]').hasMatch(p);
