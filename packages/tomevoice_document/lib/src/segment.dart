import 'model.dart';

/// Titles that stand before a name: "Capt. Smith", "Mt. Everest". Their
/// full stop never ends a sentence.
const _titles = {
  'mr', 'mrs', 'ms', 'messrs', 'mme', 'mlle', 'dr', 'prof', 'st', 'mt', 'ft', 'capt', 'gen', 'col', 'lt',
  'sgt', 'cpl', 'maj', 'adm', 'cmdr', 'brig', 'rev', 'fr', 'sen', 'rep', 'gov', 'pres', 'hon', 'supt',
  'insp', 'det', 'sra', 'srta', 'vs',
};

/// Abbreviations followed by a number: "No. 5", "Vol. IV", "Fig. 3".
/// Before anything else ("he said no. The...") the stop is a stop.
const _beforeNumbers = {
  'no', 'nos', 'vol', 'vols', 'ch', 'chap', 'fig', 'figs', 'pp', 'p', 'para', 'art', 'sec', 'ed', 'eds',
  'op', 'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
};

/// Abbreviations that can end a sentence: "etc. The list goes on." They
/// end one when a capitalised word follows, unless it is another
/// abbreviation ("Co. Ltd.").
const _endable = {
  'etc', 'inc', 'ltd', 'co', 'corp', 'bros', 'jr', 'sr', 'al', 'esq', 'approx', 'dept', 'est', 'cf',
  'viz', 'ca',
};

final _spaceRe = RegExp(r'\s+');
final _roman = RegExp(r'^[IVXLCDM]+$');

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
///
/// [silent] stretches (footnote markers) are shown but not spoken, so they
/// are transparent here: "house.¹ The next" is two sentences, the marker
/// ending the first, and nothing is ever cut inside one.
///
/// [words] fills each sentence's word spans; a book's blocks are made
/// without them (nothing reads them back, and an object per word was a
/// large share of the memory a big import took).
List<Sentence> segmentSentences(
  String text, {
  List<TextStretch> silent = const [],
  bool words = true,
}) {
  if (text.isEmpty) return const [];

  // Start of each silent stretch -> its end.
  final quiet = {for (final r in silent) r.start: r.end};
  final bounds = <({int start, int end})>[];
  var start = _skipSpace(text, 0);
  final n = text.length;

  for (var i = start; i < n; i++) {
    final skipTo = quiet[i];
    if (skipTo != null) {
      i = skipTo - 1;
      continue;
    }
    final c = text.codeUnitAt(i);
    final hard = _isHardStop(c);
    if (!hard && !_isSoftStop(c)) continue;

    if (c == 0x2E) {
      // 3.14, "...", or an abbreviation.
      if (i + 1 < n && !quiet.containsKey(i + 1) && _isDigit(text.codeUnitAt(i + 1))) continue;
      if (i + 1 < n && text.codeUnitAt(i + 1) == 0x2E) continue;
      if (i > 0 && text.codeUnitAt(i - 1) == 0x2E) {
        // End of an ellipsis: only a boundary if a capital follows.
        if (!_capitalFollows(text, i + 1)) continue;
      }
      if (_abbreviationContinues(text, start, i)) continue;
    }

    // Closing quotes and brackets, and a marker after the stop, belong to
    // the sentence that ends here.
    var end = i + 1;
    while (end < n) {
      if (_isCloser(text.codeUnitAt(end))) {
        end++;
        continue;
      }
      final markEnd = quiet[end];
      if (markEnd == null) break;
      end = markEnd;
    }

    if (!hard) {
      final next = _skipSpace(text, end);
      final sawSpace = next > end;
      if (next < n) {
        // "U.S.A" or "x.y" — not a boundary.
        if (!sawSpace) continue;
        // "“Help!” he cried." — lowercase continues the sentence, in any
        // script with capitals ("т. е. согласился").
        if (_isLower(text.codeUnitAt(next))) continue;
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
    for (final piece in _splitLong(text, b.start, b.end, silent)) {
      out.add(Sentence(
        startOffset: piece.start,
        endOffset: piece.end,
        words: words ? wordSpans(text, piece.start, piece.end) : const [],
        silent: silent.isEmpty
            ? const []
            : [
                for (final r in silent)
                  if (r.start >= piece.start && r.end <= piece.end) r,
              ],
      ));
    }
  }
  return out;
}

/// Break an over-long range at clause punctuation, else at a space, never
/// inside a [silent] stretch.
List<({int start, int end})> _splitLong(String text, int start, int end, List<TextStretch> silent) {
  bool inside(int i) => silent.any((r) => i > r.start && i < r.end);
  final out = <({int start, int end})>[];
  var s = start;
  while (end - s > maxSentenceChars) {
    final limit = s + maxSentenceChars;
    var cut = -1;
    // Prefer the last clause mark in the back half of the window.
    for (var i = limit; i > s + maxSentenceChars ~/ 3; i--) {
      final c = text.codeUnitAt(i - 1);
      // Chinese and Japanese put no space after their clause marks.
      final wide = c == 0x3001 || // 、
          c == 0xFF0C || // ，
          c == 0xFF1B || // ；
          c == 0xFF1A; // ：
      if ((wide ||
              c == 0x3B || // ;
              c == 0x3A || // :
              c == 0x2C || // ,
              c == 0x2014 || // —
              c == 0x2013 || // –
              c == 0x060C) && // ،
          i < end &&
          (wide || _isSpace(text.codeUnitAt(i))) &&
          !inside(i)) {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      for (var i = limit; i > s + 1; i--) {
        if (_isSpace(text.codeUnitAt(i)) && !inside(i)) {
          cut = i;
          break;
        }
      }
    }
    if (cut < 0) {
      cut = limit;
      for (final r in silent) {
        if (cut > r.start && cut < r.end) cut = r.start > s ? r.start : r.end;
      }
    }
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

/// Word units of `text[start, end)`, for highlighting and gap placement:
/// runs of non-space characters, except that Chinese and Japanese, which
/// put no spaces between words, get one unit per character (punctuation
/// right after a character goes with it). Thai is left whole: it has no
/// spaces and splitting it needs a dictionary.
List<WordSpan> wordSpans(String text, int start, int end) {
  final out = <WordSpan>[];
  var i = start;
  while (i < end) {
    while (i < end && _isRegexSpace(text.codeUnitAt(i))) {
      i++;
    }
    if (i >= end) break;
    var j = i + 1;
    if (_isHanOrKana(text.codeUnitAt(i))) {
      while (j < end && _isWidePunctuation(text.codeUnitAt(j))) {
        j++;
      }
    } else {
      while (j < end && !_isRegexSpace(text.codeUnitAt(j)) && !_isHanOrKana(text.codeUnitAt(j))) {
        j++;
      }
    }
    out.add(WordSpan(i, j));
    i = j;
  }
  return out;
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

/// Whether the full stop at [dot] belongs to an abbreviation or an initial
/// and so does not end the sentence.
bool _abbreviationContinues(String text, int start, int dot) {
  var i = dot - 1;
  while (i >= start && _isLetter(text.codeUnitAt(i))) {
    i--;
  }
  final token = text.substring(i + 1, dot);
  if (token.isEmpty) return false;
  final before = i < start ? 0x20 : text.codeUnitAt(i);
  // Initials: "A. C. Doyle", "А. С. Пушкин": a lone capital that is a
  // whole word.
  if (token.length == 1 &&
      _isUpper(token.codeUnitAt(0)) &&
      (i < start || _isSpace(before) || before == 0x2E || before == 0x28)) {
    return true;
  }
  // '"No." She turned away': a quote or bracket right after the stop
  // closes what was said, whatever the word.
  if (dot + 1 < text.length && _isCloser(text.codeUnitAt(dot + 1))) return false;
  final lower = token.toLowerCase();
  // e.g. / i.e. — token is "g" or "e" after an earlier dot.
  if ((lower == 'g' || lower == 'e') && dot >= 3 && text.codeUnitAt(dot - 2) == 0x2E) return true;
  if (_titles.contains(lower)) return true;
  final next = _nextWord(text, dot + 1);
  if (_beforeNumbers.contains(lower)) {
    if (next.isEmpty) return false;
    final c = next.codeUnitAt(0);
    if (_isDigit(c) || c == 0x23 || _isLower(c)) return true;
    // "Vol. IV", "Ch. XII"; but "No. I don't" is a stop.
    return lower != 'no' && _roman.hasMatch(next);
  }
  if (_endable.contains(lower)) {
    if (next.isEmpty) return false;
    final c = next.codeUnitAt(0);
    if (_isDigit(c) || _isLower(c) || c == 0x28) return true;
    final word = next.toLowerCase();
    return _titles.contains(word) || _beforeNumbers.contains(word) || _endable.contains(word);
  }
  return false;
}

/// The word after [from] (spaces skipped), up to the next space or stop.
String _nextWord(String text, int from) {
  final i = _skipSpace(text, from);
  var j = i;
  while (j < text.length && !_isSpace(text.codeUnitAt(j)) && text.codeUnitAt(j) != 0x2E) {
    j++;
  }
  return text.substring(i, j);
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
    c == 0x300F || // 』
    c == 0x3009 || // 〉
    c == 0x300B || // 》
    c == 0x3011 || // 】
    c == 0xFF09; // ）

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

/// What `\s` matches in a Dart RegExp: word counts must not move.
bool _isRegexSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    c == 0xFEFF;

bool _isDigit(int c) => c >= 48 && c <= 57;

/// Letters of the alphabets with capitals: Latin, Greek, Cyrillic.
bool _isLetter(int c) =>
    (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) ||
    (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
    (c >= 0x370 && c <= 0x3FF) ||
    (c >= 0x400 && c <= 0x52F);

bool _isLower(int c) {
  if (c >= 97 && c <= 122) return true;
  if (c < 0xC0) return false;
  final s = String.fromCharCode(c);
  return s == s.toLowerCase() && s != s.toUpperCase();
}

bool _isUpper(int c) {
  if (c >= 65 && c <= 90) return true;
  if (c < 0xC0) return false;
  final s = String.fromCharCode(c);
  return s == s.toUpperCase() && s != s.toLowerCase();
}

/// Han ideographs and kana: written without spaces between words.
bool _isHanOrKana(int c) =>
    (c >= 0x3040 && c <= 0x30FF) || // hiragana, katakana
    (c >= 0x31F0 && c <= 0x31FF) || // katakana extensions
    (c >= 0x3400 && c <= 0x4DBF) || // CJK extension A
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK unified ideographs
    (c >= 0xF900 && c <= 0xFAFF) || // compatibility ideographs
    (c >= 0xFF66 && c <= 0xFF9F); // half-width katakana

/// CJK punctuation and full-width symbols: no words of their own.
bool _isWidePunctuation(int c) =>
    (c >= 0x3000 && c <= 0x303F) ||
    (c >= 0xFF01 && c <= 0xFF0F) ||
    (c >= 0xFF1A && c <= 0xFF20) ||
    (c >= 0xFF3B && c <= 0xFF40) ||
    (c >= 0xFF5B && c <= 0xFF65);

/// Thai and Lao, also written without spaces between words.
bool _isThaiOrLao(int c) => c >= 0x0E00 && c <= 0x0EFF;

/// Words in [text], for reading time and statistics: the reader estimates
/// minutes left at 165 words a minute aloud and 230 silently.
///
/// Spaced scripts count runs of non-space characters, exactly as before.
/// Chinese and Japanese count by character: speech runs at about 250 to 330
/// characters a minute (Mandarin's four to five syllables a second, one
/// character each; Japanese text a little faster), where English is spoken
/// at about 165 words, so about 1.8 characters take an English word's time
/// and the same per-minute figures stay right. Thai and Lao, also unspaced,
/// average about five letters and marks to a word. Korean has spaces.
int countWords(String text) {
  var words = 0, wide = 0, thai = 0;
  var inWord = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (_isRegexSpace(c)) {
      inWord = false;
    } else if (_isHanOrKana(c)) {
      wide++;
      inWord = false;
    } else if (_isThaiOrLao(c)) {
      thai++;
      inWord = false;
    } else if (_isWidePunctuation(c)) {
      inWord = false;
    } else if (!inWord) {
      words++;
      inWord = true;
    }
  }
  return words + (wide * 5 + 4) ~/ 9 + (thai + 2) ~/ 5;
}
