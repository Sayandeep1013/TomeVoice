import 'model.dart';

final _abbrev = <String>{
  'mr',
  'mrs',
  'ms',
  'dr',
  'prof',
  'sr',
  'jr',
  'st',
  'vs',
  'etc',
  'inc',
  'ltd',
  'co',
  'no',
  'vol',
  'ch',
  'fig',
  'pp',
  'approx',
  'dept',
  'est',
  'al',
};

final _wordRe = RegExp(r'\S+');

/// Collapse runs of whitespace to a single space and trim.
String collapseWhitespace(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Sentence + word tokeniser for English-like text.
///
/// This is not ICU. Abbreviations are handled; nested quotes and dialogue
/// dashes are good enough for ingestion. Language-specific ICU lands with
/// the full Phase 1 reader, not this speakable-document slice.
List<Sentence> segmentSentences(String text) {
  if (text.isEmpty) return const [];

  final bounds = <({int start, int end})>[];
  var start = 0;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch != '.' && ch != '!' && ch != '?') continue;

    // Ellipsis or decimal: 3.14 or ...
    if (ch == '.' && i + 1 < text.length && _isDigit(text[i + 1])) continue;
    if (ch == '.' && i + 1 < text.length && text[i + 1] == '.') continue;

    var end = i + 1;
    while (end < text.length && _isCloser(text[end])) {
      end++;
    }

    final rest = end < text.length ? text.substring(end) : '';
    final followedBySpaceThenCapital = RegExp(r'^\s+$').hasMatch(rest) ||
        RegExp(r'^\s+[A-Z"“(\[]').hasMatch(rest) ||
        rest.isEmpty;

    if (!followedBySpaceThenCapital && rest.isNotEmpty) continue;
    if (_endsWithAbbreviation(text, start, i)) continue;

    final slice = text.substring(start, end).trim();
    if (slice.isNotEmpty) {
      bounds.add((start: _leadingSkip(text, start), end: end));
    }
    start = end;
    while (start < text.length && _isSpace(text[start])) {
      start++;
    }
    i = start - 1;
  }

  if (start < text.length) {
    final slice = text.substring(start).trim();
    if (slice.isNotEmpty) {
      bounds.add((start: _leadingSkip(text, start), end: text.length));
    }
  }

  if (bounds.isEmpty && text.trim().isNotEmpty) {
    bounds.add((start: 0, end: text.length));
  }

  return [
    for (final b in bounds)
      Sentence(
        startOffset: b.start,
        endOffset: b.end,
        words: wordSpans(text, b.start, b.end),
      ),
  ];
}

List<WordSpan> wordSpans(String text, int start, int end) {
  final slice = text.substring(start, end);
  return [
    for (final m in _wordRe.allMatches(slice))
      WordSpan(start + m.start, start + m.end),
  ];
}

int _leadingSkip(String text, int start) {
  var i = start;
  while (i < text.length && _isSpace(text[i])) {
    i++;
  }
  return i;
}

bool _endsWithAbbreviation(String text, int start, int dotIndex) {
  var i = dotIndex - 1;
  while (i >= start && _isLetter(text[i])) {
    i--;
  }
  final token = text.substring(i + 1, dotIndex).toLowerCase();
  if (token.isEmpty) {
    // Initials: "A. C. Doyle" — single letter before the dot.
    if (dotIndex > start && _isLetter(text[dotIndex - 1])) return true;
    return false;
  }
  if (_abbrev.contains(token)) return true;
  // e.g. / i.e. — token is "g" or "e" after an earlier dot.
  if ((token == 'g' || token == 'e') &&
      dotIndex >= 3 &&
      text[dotIndex - 2] == '.') {
    return true;
  }
  return false;
}

bool _isCloser(String ch) =>
    ch == '"' ||
    ch == "'" ||
    ch == '”' ||
    ch == '’' ||
    ch == ')' ||
    ch == ']' ||
    ch == '»';

bool _isSpace(String ch) => ch.trim().isEmpty;
bool _isDigit(String ch) => ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;
bool _isLetter(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

int countWords(String text) => _wordRe.allMatches(text).length;
