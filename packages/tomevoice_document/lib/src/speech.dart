import 'model.dart';

/// What the voice is given for a sentence, with the way back to the text
/// on the page: the voice reports word positions in what it was given, and
/// the highlight belongs on the page's words.
///
/// A silent stretch (a footnote marker) is a pronunciation substitution
/// whose replacement is empty, so [spans] have the shape the app's
/// `Respelled` uses for its rules: (start in [text], end in [text], start on
/// the page, end on the page), here with start == end in [text].
class SpokenText {
  const SpokenText(this.text, this.spans);

  /// The page's text, unchanged.
  const SpokenText.same(this.text) : spans = const [];

  final String text;
  final List<(int, int, int, int)> spans;

  bool get changed => spans.isNotEmpty;

  /// Position [o] in [text] as a position on the page. A word that ends
  /// where a silent stretch was left out ends, on the page, after it
  /// ([end]); one that starts there starts after it.
  int toShown(int o, {bool end = false}) {
    var shift = 0;
    for (final (s, e, os, oe) in spans) {
      if (o < s) break;
      if (o < e || (end && o == e)) return end ? oe : os;
      shift = oe - e;
    }
    return o + shift;
  }
}

/// What a [SpeechHint] found.
enum SpeechHintKind {
  /// A web address: "https://example.com/a/b", "www.example.org",
  /// "Amazon.com".
  url,

  /// An email address.
  email,

  /// A bracketed reference: "[12]", "[12–14]", "[1, 3]".
  citation,

  /// A line of symbols only: "* * *", "———", "◆◆◆".
  symbols,
}

/// A stretch of text that the app may want to speak differently (a URL as
/// its domain, a citation not at all). Offsets in the text it was found in.
class SpeechHint {
  const SpeechHint(this.kind, this.start, this.end);

  final SpeechHintKind kind;
  final int start;
  final int end;

  @override
  String toString() => '${kind.name}[$start, $end)';
}

final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}');
final _url = RegExp(r'(?:(?:https?|ftp)://|www\.)[^\s<>"]+', caseSensitive: false);
final _domain = RegExp(
  r'\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|edu|gov|io|co|uk|de|fr|ru|in|info|me|app|dev|ai|ly|tv)'
  r'\b(?:/[^\s<>"]*)?',
);
final _citation = RegExp(r'\[\d{1,4}(?:\s*[-–—,]\s*\d{1,4})*\]');
final _sayable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Stretches of [text] a voice may want to say differently: URLs, email
/// addresses, bracketed citations, and lines of nothing but symbols. In
/// order, never overlapping. The app decides what to do with them.
List<SpeechHint> speechHints(String text) {
  final out = <SpeechHint>[];
  bool free(int s, int e) => !out.any((h) => s < h.end && e > h.start);
  void add(SpeechHintKind kind, int s, int e) {
    if (e > s && free(s, e)) out.add(SpeechHint(kind, s, e));
  }

  for (final m in _email.allMatches(text)) {
    add(SpeechHintKind.email, m.start, m.end);
  }
  for (final m in [..._url.allMatches(text), ..._domain.allMatches(text)]) {
    add(SpeechHintKind.url, m.start, m.start + _urlLength(text.substring(m.start, m.end)));
  }
  for (final m in _citation.allMatches(text)) {
    add(SpeechHintKind.citation, m.start, m.end);
  }
  var lineStart = 0;
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !_sayable.hasMatch(trimmed)) {
      final s = lineStart + line.indexOf(trimmed);
      add(SpeechHintKind.symbols, s, s + trimmed.length);
    }
    lineStart += line.length + 1;
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// A matched URL without the punctuation after it ("example.com." ends a
/// sentence); a closing bracket stays when the URL opened one.
int _urlLength(String url) {
  var end = url.length;
  while (end > 0) {
    final c = url[end - 1];
    if ('.,;:!?\'"”’'.contains(c)) {
      end--;
    } else if (c == ')' || c == ']') {
      final open = c == ')' ? '(' : '[';
      final body = url.substring(0, end);
      if (open.allMatches(body).length >= c.allMatches(body).length) break;
      end--;
    } else {
      break;
    }
  }
  return end;
}

/// [shown] without its [silent] stretches: what to speak, and how its
/// positions map back. Stretches out of order, overlapping or outside the
/// text are ignored.
SpokenText spokenText(String shown, List<TextStretch> silent) {
  if (silent.isEmpty) return SpokenText.same(shown);
  final out = StringBuffer();
  final spans = <(int, int, int, int)>[];
  var at = 0;
  for (final r in silent) {
    if (r.start < at || r.end > shown.length || r.end <= r.start) continue;
    out.write(shown.substring(at, r.start));
    spans.add((out.length, out.length, r.start, r.end));
    at = r.end;
  }
  out.write(shown.substring(at));
  return spans.isEmpty ? SpokenText.same(shown) : SpokenText(out.toString(), spans);
}
