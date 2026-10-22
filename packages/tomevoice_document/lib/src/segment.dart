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
final _spaceRe = RegExp(r'\s+');

/// Longest unit we hand to the engine in one go. A 900-character sentence is
/// several seconds of synthesis before the first sound, and one highlight
/// that never moves. Split at a clause boundary instead.
const maxSentenceChars = 280;

/// Collapse runs of whitespace to a single space and trim.
String collapseWhitespace(String raw) => raw.replaceAll(_spaceRe, ' ').trim();

/// Terminators that end a sentence regardless of what follows: Devanagari and
/// Bengali danda, CJK full stops, Arabic question mark.
bool _isHardStop(int c) =>
    c == 0x0964 || // ।
    c == 0x0965 || // ॥
    c == 0x3002 || // 。
    c == 0xFF01 || // ！
    c == 0xFF1F || // ？
    c == 0x061F || // ؟
    c == 0x06D4; // ۔

bool _isSoftStop(int c) => c == 0x2E || c == 0x21 || c == 0x3F; // . ! ?

/// Sentence + word tokeniser.
///
/// Not ICU, but no longer English-only: danda, CJK and Arabic stops end a
/// sentence, and a `.` ends one unless the next word starts with a lowercase
/// Latin letter (so it works for scripts without capitals). Abbreviations and
/// decimals are kept whole. Anything longer than [maxSentenceChars] is split at
/// the best clause boundary so speech starts quickly.
List<Sentence> segmentSentences(String text) {
  if (text.isEmpty) return const [];

  final bounds = <({int start, int end})>[];
  var start = _skipSpace(text, 0);
  final n = text.length;

  for (var i = start; i < n; i++) {
    final c = text.codeUnitAt(i);
    final hard = _isHardStop(c);
    if (!hard && !_isSoftStop(c)) continue;

    if (c == 0x2E) {
      // 3.14, "...", or an abbreviation.
      if (i + 1 < n && _isDigit(text.codeUnitAt(i + 1))) continue;
      if (i + 1 < n && text.codeUnitAt(i + 1) == 0x2E) continue;
      if (i > 0 && text.codeUnitAt(i - 1) == 0x2E) {
        // End of an ellipsis: only a boundary if a capital follows.
        if (!_capitalFollows(text, i + 1)) continue;
      }
      if (_endsWithAbbreviation(text, start, i)) continue;
    }

    var end = i + 1;
    while (end < n && _isCloser(text.codeUnitAt(end))) {
      end++;
    }

    if (!hard) {
      final next = _skipSpace(text, end);
      final sawSpace = next > end;
      if (next < n) {
        // "U.S.A" or "x.y" — not a boundary.
        if (!sawSpace) continue;
        // "“Help!” he cried." — lowercase continues the sentence.
        if (_isLowerLatin(text.codeUnitAt(next))) continue;
      }
    }

    if (end > start) bounds.add((start: start, end: end));
    start = _skipSpace(text, end);
    i = start - 1;
  }

  if (start < n) {
    var end = n;
    while (end > start && _isSpace(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (end > start) bounds.add((start: start, end: end));
  }

  final out = <Sentence>[];
  for (final b in bounds) {
    for (final piece in _splitLong(text, b.start, b.end)) {
      out.add(Sentence(
        startOffset: piece.start,
        endOffset: piece.end,
        words: wordSpans(text, piece.start, piece.end),
      ));
    }
  }
  return out;
}

/// Break an over-long range at clause punctuation, else at a space.
List<({int start, int end})> _splitLong(String text, int start, int end) {
  final out = <({int start, int end})>[];
  var s = start;
  while (end - s > maxSentenceChars) {
    final limit = s + maxSentenceChars;
    var cut = -1;
    // Prefer the last clause mark in the back half of the window.
    for (var i = limit; i > s + maxSentenceChars ~/ 3; i--) {
      final c = text.codeUnitAt(i - 1);
      if ((c == 0x3B || // ;
              c == 0x3A || // :
              c == 0x2C || // ,
              c == 0x2014 || // —
              c == 0x2013 || // –
              c == 0x060C || // ،
              c == 0x3001) && // 、
          i < end &&
          _isSpace(text.codeUnitAt(i))) {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      for (var i = limit; i > s + 1; i--) {
        if (_isSpace(text.codeUnitAt(i))) {
          cut = i;
          break;
        }
      }
    }
    if (cut < 0) cut = limit;
    var pieceEnd = cut;
    while (pieceEnd > s && _isSpace(text.codeUnitAt(pieceEnd - 1))) {
      pieceEnd--;
    }
    if (pieceEnd > s) out.add((start: s, end: pieceEnd));
    s = _skipSpace(text, cut);
  }
  if (end > s) out.add((start: s, end: end));
  return out;
}

List<WordSpan> wordSpans(String text, int start, int end) {
  final slice = text.substring(start, end);
  return [
    for (final m in _wordRe.allMatches(slice))
      WordSpan(start + m.start, start + m.end),
  ];
}

int _skipSpace(String text, int i) {
  while (i < text.length && _isSpace(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

bool _capitalFollows(String text, int from) {
  final i = _skipSpace(text, from);
  if (i == from || i >= text.length) return i >= text.length;
  final c = text.codeUnitAt(i);
  return c >= 65 && c <= 90;
}

bool _endsWithAbbreviation(String text, int start, int dotIndex) {
  var i = dotIndex - 1;
  while (i >= start && _isLatinLetter(text.codeUnitAt(i))) {
    i--;
  }
  final token = text.substring(i + 1, dotIndex);
  if (token.isEmpty) return false;
  // Initials: "A. C. Doyle" — a lone capital that is a whole word.
  if (token.length == 1 &&
      token.toUpperCase() == token &&
      (i < start || _isSpace(text.codeUnitAt(i)) || text.codeUnitAt(i) == 0x2E)) {
    return true;
  }
  final lower = token.toLowerCase();
  if (_abbrev.contains(lower)) return true;
  // e.g. / i.e. — token is "g" or "e" after an earlier dot.
  if ((lower == 'g' || lower == 'e') &&
      dotIndex >= 3 &&
      text.codeUnitAt(dotIndex - 2) == 0x2E) {
    return true;
  }
  return false;
}

bool _isCloser(int c) =>
    c == 0x22 || // "
    c == 0x27 || // '
    c == 0x201D || // ”
    c == 0x2019 || // ’
    c == 0x29 || // )
    c == 0x5D || // ]
    c == 0xBB || // »
    c == 0x300D || // 」
    c == 0x300F; // 』

bool _isSpace(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0xA0 ||
    c == 0x2009 ||
    c == 0x200A ||
    c == 0x202F ||
    c == 0x3000;

bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isLowerLatin(int c) => (c >= 97 && c <= 122) || (c >= 0xDF && c <= 0xFF);
bool _isLatinLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

int countWords(String text) => _wordRe.allMatches(text).length;
