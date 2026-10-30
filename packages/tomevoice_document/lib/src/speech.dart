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
