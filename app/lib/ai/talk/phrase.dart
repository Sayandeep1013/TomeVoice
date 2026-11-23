/// The name a held word is part of, as a reader would look it up: "Six
/// Finger" for a hold on "Six", "the Nine" for one on "Nine". A guess from
/// the capitals around the word, which the reader can then widen or narrow
/// a word at a time within the sentence.
library;

/// A word of a sentence and where it sits there.
typedef PhraseWord = ({int start, int end, String text});

/// Letters, marks and digits, with an apostrophe or a hyphen inside a word
/// ("Sunny's", "Six-Finger") kept in it.
final _word = RegExp(r"[\p{L}\p{M}\p{N}]+(?:['’-][\p{L}\p{M}\p{N}]+)*", unicode: true);

/// Small words a name may hold between its capitals: "Lord of Mysteries",
/// "Order of the Phoenix", "Leonardo da Vinci".
const _inside = {'of', 'the', 'de', 'da', 'del', 'di', 'du', 'van', 'von', 'der', 'den', 'la', 'le', 'al', 'el', 'bin', 'ibn'};

/// Words that start a sentence with a capital without being part of a name
/// after them: "Then Sunny left" is Sunny, not "Then Sunny".
const _starters = {
  'a', 'an', 'and', 'as', 'at', 'after', 'again', 'all', 'also', 'although', 'any', 'because', 'before',
  'but', 'by', 'each', 'even', 'every', 'finally', 'for', 'from', 'he', 'her', 'here', 'his', 'how', 'however',
  'i', 'if', 'in', 'instead', 'it', 'its', 'just', 'later', 'maybe', 'meanwhile', 'my', 'no', 'not', 'now',
  'of', 'oh', 'on', 'once', 'only', 'or', 'our', 'perhaps', 'she', 'since', 'so', 'some', 'soon', 'still',
  'suddenly', 'that', 'the', 'their', 'then', 'there', 'these', 'they', 'this', 'those', 'though', 'to',
  'today', 'tomorrow', 'tonight', 'unlike', 'what', 'when', 'where', 'which', 'while', 'who', 'whose', 'why',
  'yes', 'yesterday', 'yet', 'you', 'your', 'we', 'well', 'with', 'without',
};

/// Titles written with a full stop that still run on into the name.
const _titles = {'mr', 'mrs', 'ms', 'dr', 'st', 'prof', 'sr', 'jr', 'mt'};

/// The longest name guessed, in words.
const _most = 6;

bool _capital(String w) {
  final c = w.substring(0, 1);
  return c != c.toLowerCase() && c == c.toUpperCase();
}

bool _possessive(String w) => RegExp(r"['’]s$").hasMatch(w);

/// The words of [sentence], in order.
List<PhraseWord> phraseWords(String sentence) => [
      for (final m in _word.allMatches(sentence)) (start: m.start, end: m.end, text: m.group(0)!),
    ];

/// A run of words of a sentence: [from] to [to], both included.
class PhraseSpan {
  const PhraseSpan(this.sentence, this.words, this.from, this.to);

  /// Just [text], when the held word is not found in the sentence.
  PhraseSpan.alone(String text)
      : sentence = text,
        words = const [],
        from = 0,
        to = -1;

  final String sentence;
  final List<PhraseWord> words;
  final int from;
  final int to;

  bool get _inSentence => words.isNotEmpty && to >= from;

  /// The words as the sentence has them, without a closing "'s" or the
  /// quotes and stops round them.
  String get text {
    if (!_inSentence) return cleanPhrase(sentence);
    return cleanPhrase(sentence.substring(words[from].start, words[to].end));
  }

  bool get canAddBefore => _inSentence && from > 0;
  bool get canAddAfter => _inSentence && to < words.length - 1;
  bool get canDropFirst => _inSentence && to > from;
  bool get canDropLast => _inSentence && to > from;

  PhraseSpan addBefore() => canAddBefore ? PhraseSpan(sentence, words, from - 1, to) : this;
  PhraseSpan addAfter() => canAddAfter ? PhraseSpan(sentence, words, from, to + 1) : this;
  PhraseSpan dropFirst() => canDropFirst ? PhraseSpan(sentence, words, from + 1, to) : this;
  PhraseSpan dropLast() => canDropLast ? PhraseSpan(sentence, words, from, to - 1) : this;
}

/// [s] without the quotes, brackets and stops round it, nor a closing "'s";
/// spaces made single.
String cleanPhrase(String s) {
  var t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r"^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$", unicode: true), '');
  return t.replaceFirst(RegExp(r"['’]s$"), '');
}

/// Only spaces between two words (or a title's full stop: "Mr. Darcy"), so
/// they can be one name.
bool _joined(String sentence, PhraseWord a, PhraseWord b) {
  final gap = sentence.substring(a.end, b.start);
  if (RegExp(r'^\s+$').hasMatch(gap)) return true;
  return RegExp(r'^\.\s+$').hasMatch(gap) && _titles.contains(a.text.toLowerCase());
}

/// Whether word [i] starts its sentence: the first word, or the first after
/// a full stop, a question or an exclamation (an opening quote between).
bool _startsSentence(String sentence, List<PhraseWord> words, int i) {
  if (i == 0) return true;
  final gap = sentence.substring(words[i - 1].end, words[i].start);
  return RegExp(r'[.!?…:]').hasMatch(gap) && !(gap.trimLeft().startsWith('.') && _titles.contains(words[i - 1].text.toLowerCase()));
}

/// The name [word] is part of in [sentence], guessed from the capitals
/// round it:
/// - a word with no capital is looked up alone;
/// - capitalised words next to it, with only spaces between, join it, with
///   small words like "of" between two of them ("Lord of Mysteries");
/// - a "the" just before the name joins it ("the Nine");
/// - a capital that only starts the sentence ("Then", "When") does not;
/// - a word ending "'s" ends the name ("Sunny's sword" is Sunny);
/// - at most six words.
/// When [word] is not in [sentence] it is looked up alone.
PhraseSpan guessPhrase(String sentence, String word) {
  final words = phraseWords(sentence);
  final held = cleanPhrase(word);
  if (held.isEmpty) return PhraseSpan.alone(word);
  var h = words.indexWhere((w) => w.text == held || cleanPhrase(w.text) == held);
  if (h < 0) {
    final low = held.toLowerCase();
    h = words.indexWhere((w) => cleanPhrase(w.text).toLowerCase() == low);
  }
  if (h < 0) return PhraseSpan.alone(held);
  if (!_capital(words[h].text)) return PhraseSpan(sentence, words, h, h);

  bool nameWord(int i) {
    final w = words[i].text;
    if (!_capital(w)) return false;
    // A capital that only opens the sentence, on a word that is no name.
    if (_startsSentence(sentence, words, i) && _starters.contains(w.toLowerCase())) return false;
    return true;
  }

  var from = h;
  var to = h;
  // Rightwards, unless the held word already ends in "'s".
  while (!_possessive(words[to].text) && to - from + 1 < _most) {
    final n = to + 1;
    if (n >= words.length || !_joined(sentence, words[to], words[n])) break;
    if (nameWord(n) && !_startsSentence(sentence, words, n)) {
      to = n;
      continue;
    }
    // "of" or "of the" between two capitals.
    var k = n;
    while (k < words.length && k - n < 2 && _inside.contains(words[k].text.toLowerCase()) &&
        !_capital(words[k].text) && _joined(sentence, words[k - 1], words[k])) {
      k++;
    }
    if (k > n && k < words.length && _joined(sentence, words[k - 1], words[k]) && nameWord(k) &&
        k - from + 1 <= _most) {
      to = k;
      continue;
    }
    break;
  }
  // Leftwards.
  while (to - from + 1 < _most && !_startsSentence(sentence, words, from)) {
    final p = from - 1;
    if (!_joined(sentence, words[p], words[from]) || _possessive(words[p].text)) break;
    if (nameWord(p)) {
      from = p;
      continue;
    }
    var k = p;
    while (k >= 0 && p - k < 2 && _inside.contains(words[k].text.toLowerCase()) && !_capital(words[k].text) &&
        _joined(sentence, words[k], words[k + 1])) {
      k--;
    }
    if (k < p && k >= 0 && _joined(sentence, words[k], words[k + 1]) && nameWord(k) && to - k + 1 <= _most &&
        !_possessive(words[k].text)) {
      from = k;
      continue;
    }
    break;
  }
  // "the Nine", "The Weaver": the article goes with the name.
  if (from > 0 && words[from - 1].text.toLowerCase() == 'the' && _joined(sentence, words[from - 1], words[from]) &&
      !_startsSentence(sentence, words, from)) {
    from--;
  }
  return PhraseSpan(sentence, words, from, to);
}
