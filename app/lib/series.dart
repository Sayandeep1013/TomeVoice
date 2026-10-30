// A book's series, found in its title when the book itself does not say
// (an EPUB's own series is read with the book: BookMetadata.series).

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
  if (t.isEmpty) return null;
  // Most titles have no number and no word for one: asked of every book
  // each time the shelf is read, they are passed over before any pattern.
  final lower = t.toLowerCase();
  if (!t.codeUnits.any((c) => c >= 0x30 && c <= 0x39) && !_numberWords.any(lower.contains)) return null;
  // "Leviathan Wakes (The Expanse #1)", "The Way of Kings [Stormlight Archive 1]".
  final bracketed = _bracketed.firstMatch(t);
  if (bracketed != null) {
    final found = _named(bracketed.group(1)!);
    if (found != null) return found;
  }
  return _named(t);
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
