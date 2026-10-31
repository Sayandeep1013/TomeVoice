import 'book_search.dart' show foldForSearch;

// A book's series, found in its title when the book itself does not say
// (an EPUB's own series is read with the book: BookMetadata.series): in
// that title alone, or in the words it shares with the library's other
// titles (seriesAcross).

/// The series [title] names, and the book's number in it: "A Song of Ice
/// and Fire 3", "Mistborn, Book Two", "Berserk Vol. 41", "Leviathan Wakes
/// (The Expanse #1)". Null when it names none.
///
/// A bare number at the end counts only after two words or more, and only
/// up to 30: "Fahrenheit 451", "Apollo 13", "Catch-22" and "Blade Runner
/// 2049" are not series. With a word that says so (Book, Vol., Part, #)
/// any number does, and Book Two or Part IV as well.
({String name, double index})? seriesFromTitle(String title) {
  final t = title.trim();
  return t.isEmpty ? null : _title(t).alone;
}

/// The series [t] names alone, a title with a number or a word for one.
({String name, double index})? _alone(String t) {
  // "Leviathan Wakes (The Expanse #1)", "The Way of Kings [Stormlight Archive 1]".
  final bracketed = _bracketed.firstMatch(t);
  if (bracketed != null) {
    final found = _named(bracketed.group(1)!);
    if (found != null) return found;
  }
  return _named(t);
}

/// What a title says of a series, each part worked out when first asked.
class _Title {
  _Title(this.text);

  final String text;

  /// Most titles have no number and no word for one: asked of every book
  /// each time the shelf is read, they are passed over before any pattern.
  late final bool numbered = _mayNumber(text);

  /// The series it names alone (seriesFromTitle).
  late final ({String name, double index})? alone = numbered ? _alone(text) : null;

  /// The runs of words just before each place in it that could name a
  /// series (see seriesAcross).
  late final List<_Run> runs = numbered ? _runsIn(text) : const [];
}

/// The titles asked lately, and the series' names: every title is asked
/// again each time the library is read or changes, and seldom changes.
/// Forgotten when there are a great many.
final _titles = <String, _Title>{};
final _keys = <String, String>{};

_Title _title(String t) => _asked(_titles, t, () => _Title(t));

V _asked<V extends Object>(Map<String, V> seen, String key, V Function() find) {
  final known = seen[key];
  if (known != null) return known;
  if (seen.length >= 20000) seen.clear();
  return seen[key] = find();
}

/// "Series, Book 3", or a bare "Series 3".
({String name, double index})? _named(String text) {
  final m = _marker.firstMatch(text);
  if (m != null) {
    final n = _number(m.group(2)!);
    final name = _tidy(m.group(1)!);
    if (n != null && _hasLetter.hasMatch(name)) return (name: name, index: n);
  }
  final bare = _bare.firstMatch(text);
  if (bare == null) return null;
  final n = int.parse(bare.group(2)!);
  final name = _tidy(bare.group(1)!);
  if (n < 1 || n > 30 || name.split(' ').length < 2 || !_hasLetter.hasMatch(name)) return null;
  return (name: name, index: n.toDouble());
}

/// Words that can say a place in a series without a digit ("Book Two",
/// "Part IV").
const _numberWords = ['book', 'bk', 'vol', 'part', 'pt.', 'no.', 'number', 'tome', 'episode'];

/// Whether [text] has a digit, or a word that can say a place in a series.
bool _mayNumber(String text) {
  if (text.codeUnits.any((c) => c >= 0x30 && c <= 0x39)) return true;
  final lower = text.toLowerCase();
  return _numberWords.any(lower.contains);
}

/// The words before a marker of a place in a series, and the place.
final _marker = RegExp(
  r'^(.*?\S)[\s,:;.–—-]*(?:\b(?:book|bk\.?|vol\.?|volume|part|pt\.|no\.|number|tome|episode)\s*|#\s*)'
  r'(\d{1,4}(?:\.\d+)?|[ivxlc]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)$',
  caseSensitive: false,
);

/// The words before a bare number at the end, and the number.
final _bare = RegExp(r'^(.*\S)\s+(\d{1,2})$');

/// What is in brackets at the end of a title.
final _bracketed = RegExp(r'^.*\S\s*[(\[]\s*([^()\[\]]+?)\s*[)\]]$');

final _hasLetter = RegExp(r'\p{L}', unicode: true);

/// Separators and spaces off the ends of a series' name.
String _tidy(String name) =>
    name.replaceAll(RegExp(r'^[\s,:;.–—-]+|[\s,:;.–—-]+$'), '').replaceAll(RegExp(r'\s+'), ' ');

double? _number(String raw) {
  final word = raw.toLowerCase();
  const words = {
    'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8,
    'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
  };
  if (words[word] case final n?) return n.toDouble();
  if (RegExp(r'^[ivxlc]+$').hasMatch(word)) return _roman(word)?.toDouble();
  return double.tryParse(raw);
}

/// "iv" as 4, up to 399; null for what is not a well-formed numeral ("vv").
int? _roman(String s) {
  const values = {'i': 1, 'v': 5, 'x': 10, 'l': 50, 'c': 100};
  var total = 0;
  for (var i = 0; i < s.length; i++) {
    final v = values[s[i]]!;
    final next = i + 1 < s.length ? values[s[i + 1]]! : 0;
    total += v < next ? -v : v;
  }
  if (total <= 0 || total >= 400) return null;
  // Written back the usual way, it must be what was read ("iiii" is not).
  const table = [(100, 'c'), (90, 'xc'), (50, 'l'), (40, 'xl'), (10, 'x'), (9, 'ix'), (5, 'v'), (4, 'iv'), (1, 'i')];
  var rest = total;
  final out = StringBuffer();
  for (final (n, letters) in table) {
    while (rest >= n) {
      out.write(letters);
      rest -= n;
    }
  }
  return out.toString() == s ? total : null;
}

/// A series' number as people write it: "3", "1.5".
String seriesNumber(double n) => n == n.roundToDouble() ? n.round().toString() : '$n';

// ------------------------------------------------------ across a library

/// The series each of [titles] is in, the library's books taken together:
/// the longest run of words just before a place in a series that another
/// of [titles] has before a place of its own, or that names one of the
/// series the library's books are in already, [named]. "A Game of Thrones
/// A Song of Ice and Fire 1" and "A Storm of Swords A Song of Ice and Fire
/// 3" are both in A Song of Ice and Fire, "The First Law 1 The Blade
/// Itself" and "The First Law 2 Before They Are Hanged" in The First Law.
/// Case, accents and separators (" - ", ":", ",") aside. A title that
/// shares none is in the series it names alone (seriesFromTitle), or none.
///
/// A place is a number up to 30, or any after a word that says so (Book,
/// Vol., Part, #), at the end of a title or within it. A run is two words
/// or more, not only little ones, and it does not start with "of" or "and"
/// (it may with "The" or "A"), end on one, or follow one: "Rise of the King
/// 2" and "Return of the King 3" share none. Titles that share a run only
/// at one place (two copies of a book, or "Learn Python 3 the Hard Way" and
/// "Learn Python 3 in a Day") are not a series by it.
///
/// Asked of the whole library as it is read and changed: only titles with
/// a number are looked into, and runs are matched by their words in a map.
List<({String name, double index})?> seriesAcross(List<String> titles, {Iterable<String> named = const []}) {
  // How each series named already is spelled, and by how many, by its words.
  final spelled = <String, int>{};
  for (final name in named) {
    _count(spelled, name);
  }
  final namedAs = <String, Map<String, int>>{};
  spelled.forEach((name, n) {
    final key = _wordsKey(name);
    if (key.isNotEmpty) (namedAs[key] ??= {})[name] = n;
  });
  // Each title's runs, and the titles that have each run.
  final said = [for (final t in titles) _title(t.trim())];
  final shares = <String, _Share>{};
  for (var i = 0; i < said.length; i++) {
    for (final r in said[i].runs) {
      (shares[r.key] ??= _Share(i, r.place)).add(i, r);
    }
  }
  // Spelled as the series named already is, else as most titles spell it.
  final names = <String, String>{};
  String nameOf(String key) => names[key] ??= _commonest(namedAs[key] ?? _spellings(shares[key]!));
  return [
    for (final t in said)
      if (_sharedRun(t.runs, shares, namedAs) case final r?) (name: nameOf(r.key), index: r.place) else t.alone,
  ];
}

/// A series' name as a title's runs are matched to it: its words, in lower
/// case and without accents, separators or brackets ("A Song of Ice and
/// Fire" and "a song of ice and fire," are one).
String _wordsKey(String name) => _asked(_keys, name, () => [for (final w in _wordsOf(name)) w.key].join(' '));

/// The longest of [own] runs that names a series already, or that another
/// title has too, not all of them at one place.
_Run? _sharedRun(List<_Run> own, Map<String, _Share> shares, Map<String, Object> named) {
  _Run? best;
  for (final r in own) {
    if (best != null && r.words <= best.words) continue;
    final s = shares[r.key]!;
    if (named.containsKey(r.key) || (s.titles && s.places)) best = r;
  }
  return best;
}

/// The runs of words just before each place in [title] that could name a
/// series.
List<_Run> _runsIn(String title) {
  final words = _wordsOf(title);
  final out = <_Run>[];
  for (var n = 1; n < words.length; n++) {
    // After a word that says so, any number, and the run ends before that
    // word; a bare number, up to 30.
    var end = n;
    var place = _markers.contains(words[n - 1].raw) ? _markedPlace(words[n].key) : null;
    if (place != null) {
      end = n - 1;
    } else {
      place = _barePlace(words[n].key);
    }
    if (place == null) continue;
    var key = '';
    for (var start = end - 1; start >= 0; start--) {
      key = key.isEmpty ? words[start].key : '${words[start].key} $key';
      if (end - start >= 2 && _canName(words, start, end)) {
        out.add(_Run(title, key, place, words[start].start, words[end - 1].end, end - start));
      }
    }
  }
  return out;
}

/// Whether words [start] up to [end] of a title can name a series.
bool _canName(List<_Word> words, int start, int end) {
  if (_joining.contains(words[start].key) || _little(words[end - 1].key)) return false;
  if (start > 0 && _little(words[start - 1].key)) return false;
  for (var w = start; w < end; w++) {
    if (words[w].letter && !_little(words[w].key)) return true;
  }
  return false;
}

/// [key] as a place after a word that says so: any number ("3", "2.5"), a
/// numeral ("iv") or a number's word ("two").
double? _markedPlace(String key) => _placeWord.hasMatch(key) ? _number(key) : null;

/// [key] as a place on its own: a number from 1 to 30.
double? _barePlace(String key) {
  if (key.isEmpty || key.length > 2 || !key.codeUnits.every(_isDigit)) return null;
  final n = int.parse(key);
  return n >= 1 && n <= 30 ? n.toDouble() : null;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Words a series' name does not start with, end on or follow ("of the" in
/// "Return of the King 3"); an article may start one ("The First Law").
const _joining = {
  'of', 'and', '&', 'or', 'in', 'on', 'at', 'to', 'for', 'with', 'by', 'from', 'into', 'de', 'del', 'des', 'du',
  'et', 'und',
};
const _articles = {
  'the', 'a', 'an', 'der', 'die', 'das', 'le', 'la', 'les', 'el', 'los', 'las', 'il', 'lo', 'un', 'una', 'une', 'ein',
  'eine',
};

bool _little(String key) => _joining.contains(key) || _articles.contains(key);

/// A word of a title: where it stands; as it is compared ([key]: in lower
/// case, without accents or the quotes and stops round it); in lower case
/// as it is written ([raw]: "vol."); and whether it has a letter.
typedef _Word = ({int start, int end, String key, String raw, bool letter});

/// The words of [text]: separators (" - ", ":", ",", brackets) are not
/// words, and "#" is one of its own.
List<_Word> _wordsOf(String text) => [
      for (final m in _wordPattern.allMatches(text))
        if (_wordAt(m) case final w?) w,
    ];

final _wordPattern = RegExp(r'#|[^\s#,:;/|()\[\]{}]+');

/// The word [m] is, or null for a dash or a mark that only separates.
_Word? _wordAt(Match m) {
  final raw = foldForSearch(m[0]!);
  var a = 0, b = raw.length;
  while (a < b && _edges.contains(raw.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _edges.contains(raw.codeUnitAt(b - 1))) {
    b--;
  }
  final key = raw.substring(a, b);
  final letter = _hasLetterIn(key);
  if (!letter && key != '#' && key != '&' && !_letterOrDigit.hasMatch(key)) return null;
  return (start: m.start, end: m.end, key: key, raw: raw, letter: letter);
}

/// The quotes and stops round a word.
final _edges = {for (final c in '"\'.!?*«»'.codeUnits) c};

/// Whether [s] has a letter: plain ones looked at, any other asked.
bool _hasLetterIn(String s) {
  for (final c in s.codeUnits) {
    if (c >= 0x80) return _hasLetter.hasMatch(s);
    if ((c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a)) return true;
  }
  return false;
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _placeWord =
    RegExp(r'^(?:\d{1,4}(?:\.\d+)?|[ivxlc]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)$');
final _brackets = RegExp(r'[()\[\]{}]');

/// Words that say a place follows, in lower case as they are written.
const _markers = {'book', 'bk', 'bk.', 'vol', 'vol.', 'volume', 'part', 'pt.', 'no.', 'number', 'tome', 'episode', '#'};

/// A run of [words] words before a place in [title], from [from] up to [to]
/// in it.
class _Run {
  _Run(this.title, this.key, this.place, this.from, this.to, this.words);

  final String title;
  final String key;
  final double place;
  final int from, to;
  final int words;

  /// As the title writes it, without brackets.
  late final String spelling = _tidy(title.substring(from, to).replaceAll(_brackets, ' '));
}

/// The titles that have a run, from the first, [title] in the list, which
/// has it before [place].
class _Share {
  _Share(this.title, this.place);

  final int title;
  final double place;

  /// Whether another title has it, and whether before another place.
  var titles = false;
  var places = false;

  /// The run in each title that has it.
  final runs = <_Run>[];

  void add(int i, _Run r) {
    runs.add(r);
    titles |= i != title;
    places |= r.place != place;
  }
}

/// How [share]'s titles write it, and how often.
Map<String, int> _spellings(_Share share) {
  final out = <String, int>{};
  for (final r in share.runs) {
    _count(out, r.spelling);
  }
  return out;
}

void _count(Map<String, int> counts, String s) {
  counts[s] = (counts[s] ?? 0) + 1;
}

/// The spelling most have; of two as common, the first in order.
String _commonest(Map<String, int> counts) =>
    (counts.entries.toList()..sort((a, b) => b.value != a.value ? b.value - a.value : a.key.compareTo(b.key)))
        .first
        .key;
