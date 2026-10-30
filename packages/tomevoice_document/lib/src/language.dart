import 'model.dart';

/// ISO 639-1 code for the dominant non-Latin script in [sample], or null when
/// the text is Latin (or empty) and the script alone cannot say which
/// language it is.
///
/// This exists because metadata lies: EPUBs ship `en` on Bengali novels, and
/// TXT, PDF and DOCX carry no language at all. Picking the voice from the
/// script is what makes a Bengali book get a Bengali voice.
String? detectScriptLanguage(String sample) {
  final counts = <String, int>{};
  var latin = 0;
  var kana = 0;
  for (final rune in sample.runes) {
    if (rune < 0x80) {
      if ((rune >= 65 && rune <= 90) || (rune >= 97 && rune <= 122)) latin++;
      continue;
    }
    if (rune >= 0x3040 && rune <= 0x30FF) kana++;
    final lang = _scriptOf(rune);
    if (lang == null) {
      if (rune >= 0xC0 && rune <= 0x24F) latin++;
      continue;
    }
    counts[lang] = (counts[lang] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  var best = counts.entries.first;
  for (final e in counts.entries) {
    if (e.value > best.value) best = e;
  }
  // A Latin book quoting one Greek word is still a Latin book.
  if (best.value < latin * 0.25) return null;
  if (best.key == 'zh' && kana > best.value * 0.05) return 'ja';
  // One script, several languages: their own letters tell them apart.
  if (best.key == 'ar') return _arabicScript(sample, best.value);
  if (best.key == 'ru') return _cyrillic(sample, best.value);
  return best.key;
}

/// Urdu and Persian write with the Arabic script plus letters of their own:
/// Urdu's ے ہ ں ھ ٹ ڈ ڑ, Persian's پ چ ژ گ and its own kaf and yeh (ک ی),
/// where Arabic has ك ي and ة.
String _arabicScript(String sample, int letters) {
  var urdu = 0, persian = 0, arabic = 0;
  for (final r in sample.runes) {
    switch (r) {
      case 0x0679 || 0x0688 || 0x0691 || 0x06BA || 0x06BE || 0x06C1 || 0x06D2 || 0x06D3:
        urdu++;
      case 0x067E || 0x0686 || 0x0698 || 0x06AF || 0x06A9 || 0x06CC:
        persian++;
      case 0x0629 || 0x064A || 0x0643 || 0x0649:
        arabic++;
    }
  }
  if (urdu >= 2 && urdu * 50 >= letters) return 'ur';
  if (persian > arabic) return 'fa';
  return 'ar';
}

/// Russian's neighbours in Cyrillic, by the letters Russian lacks:
/// Ukrainian і ї є ґ, Belarusian ў, Serbian ђ ћ, Macedonian ѓ ќ ѕ (both with
/// ј љ њ џ); Bulgarian has none of Russian's ы э ё and many ъ.
String _cyrillic(String sample, int letters) {
  var ukrainian = 0, russian = 0, belarusian = 0, serbian = 0, macedonian = 0, shared = 0, hard = 0;
  for (final r in sample.runes) {
    switch (r) {
      case 0x0456 || 0x0406 || 0x0457 || 0x0407 || 0x0454 || 0x0404 || 0x0491 || 0x0490:
        ukrainian++;
      case 0x044B || 0x042B || 0x044D || 0x042D || 0x0451 || 0x0401:
        russian++;
      case 0x045E || 0x040E:
        belarusian++;
      case 0x0452 || 0x0402 || 0x045B || 0x040B:
        serbian++;
      case 0x0453 || 0x0403 || 0x045C || 0x040C || 0x0455 || 0x0405:
        macedonian++;
      case 0x0458 || 0x0408 || 0x0459 || 0x0409 || 0x045A || 0x040A || 0x045F || 0x040F:
        shared++;
      case 0x044A || 0x042A:
        hard++;
    }
  }
  if ((serbian + macedonian + shared) * 100 > letters && serbian + macedonian + shared > russian) {
    return macedonian > serbian ? 'mk' : 'sr';
  }
  if (belarusian * 200 > letters) return 'be';
  if (ukrainian > russian) return 'uk';
  if (russian * 1000 < letters && hard * 100 > letters) return 'bg';
  return 'ru';
}

/// The commonest words of the Latin-script languages told apart here.
const _stopWords = <String, Set<String>>{
  'en': {
    'the', 'and', 'of', 'to', 'was', 'that', 'he', 'she', 'it', 'with', 'for', 'his', 'her', 'you', 'had',
    'have', 'is', 'are', 'they', 'this', 'but', 'from', 'which', 'were', 'would', 'there', 'not', 'at',
    'by', 'be', 'on', 'as', 'in', 'a', 'i', 'my', 'me', 'we', 'said', 'will', 'been', 'very', 'who', 'what',
    'them', 'their', 'when', 'did', 'could', 'into', 'an', 'or', 'if', 'him', 'every', 'went', 'upon',
  },
  'fr': {
    'le', 'la', 'les', 'de', 'des', 'du', 'et', 'est', 'un', 'une', 'que', 'qui', 'dans', 'pas', 'ne', 'il',
    'elle', 'je', 'vous', 'nous', 'au', 'aux', 'sur', 'pour', 'avec', 'ce', 'cette', 'mais', 'était', 'sont',
    'ont', 'se', 'lui', 'plus', 'son', 'sa', 'ses', 'tous', 'tout', 'avait', 'être', 'fait', 'comme', 'très',
    'où', 'chez', 'ils', 'elles', 'leur', 'y', 'en', 'à', 'été', 'aussi', 'bien', 'moi', 'toi',
  },
  'es': {
    'el', 'la', 'los', 'las', 'de', 'del', 'y', 'que', 'en', 'un', 'una', 'es', 'por', 'con', 'no', 'se',
    'su', 'sus', 'para', 'como', 'pero', 'lo', 'le', 'al', 'más', 'era', 'fue', 'está', 'muy', 'sin',
    'sobre', 'también', 'ella', 'él', 'había', 'tenía', 'todos', 'días', 'iba', 'cuando', 'porque', 'yo',
    'me', 'mi', 'eso', 'esta', 'este', 'ya', 'hay',
  },
  'de': {
    'der', 'die', 'das', 'und', 'ist', 'nicht', 'ein', 'eine', 'einen', 'einem', 'ich', 'zu', 'den', 'dem',
    'mit', 'sich', 'auf', 'für', 'es', 'von', 'im', 'auch', 'er', 'sie', 'wir', 'war', 'wie', 'aber', 'noch',
    'nach', 'wird', 'bei', 'aus', 'dass', 'oder', 'hat', 'hatte', 'sehr', 'um', 'am', 'zum', 'zur', 'ihr',
    'ihre', 'ihrer', 'jeden', 'ging', 'des', 'nur', 'schon', 'wenn',
  },
  'it': {
    'il', 'lo', 'la', 'gli', 'le', 'di', 'del', 'della', 'dei', 'che', 'e', 'è', 'un', 'una', 'per', 'non',
    'con', 'si', 'da', 'sono', 'ma', 'come', 'anche', 'più', 'al', 'alla', 'nel', 'nella', 'era', 'questo',
    'ha', 'ho', 'mi', 'ti', 'li', 'aveva', 'molto', 'ogni', 'sua', 'suo', 'andava', 'ci', 'perché',
    'quando', 'così',
  },
  'pt': {
    'o', 'a', 'os', 'as', 'de', 'do', 'da', 'dos', 'das', 'e', 'que', 'em', 'um', 'uma', 'não', 'para',
    'com', 'se', 'por', 'mais', 'como', 'mas', 'ao', 'no', 'na', 'é', 'foi', 'ele', 'ela', 'seu', 'sua',
    'era', 'isso', 'muito', 'também', 'numa', 'num', 'tinha', 'dias', 'deles', 'ia', 'você', 'já', 'quando',
  },
  'nl': {
    'de', 'het', 'een', 'en', 'van', 'is', 'dat', 'niet', 'op', 'te', 'zijn', 'met', 'voor', 'die', 'er',
    'maar', 'ook', 'als', 'bij', 'aan', 'om', 'dan', 'nog', 'wat', 'door', 'naar', 'was', 'ik', 'je', 'hij',
    'ze', 'wij', 'geen', 'heeft', 'had', 'eens', 'haar', 'elke', 'heel', 'veel', 'zich', 'uit', 'werd',
  },
  'sv': {
    'och', 'i', 'att', 'det', 'som', 'en', 'på', 'är', 'av', 'för', 'med', 'till', 'den', 'har', 'de',
    'inte', 'om', 'ett', 'han', 'men', 'var', 'jag', 'hon', 'så', 'hade', 'sig', 'från', 'också', 'efter',
  },
  'pl': {
    'i', 'w', 'nie', 'się', 'na', 'z', 'że', 'do', 'to', 'jest', 'jak', 'ale', 'po', 'co', 'tak', 'za',
    'od', 'był', 'była', 'było', 'jego', 'jej', 'mnie', 'już', 'tylko', 'przez', 'może',
  },
};

/// Word -> the languages it is a common word of.
final _stopIndex = () {
  final out = <String, List<String>>{};
  for (final e in _stopWords.entries) {
    for (final w in e.value) {
      (out[w] ??= []).add(e.key);
    }
  }
  return out;
}();

final _word = RegExp(r'\p{L}+', unicode: true);

/// The language of Latin-script [sample] (en, fr, es, de, it, pt, nl, sv,
/// pl) from how often its commonest words occur, or null when there is too
/// little to tell. A word shared by several languages ("de", "la") counts
/// for each a share. [strict] asks for much more evidence: enough to
/// overrule what a book says about itself.
String? detectLatinLanguage(String sample, {bool strict = false}) {
  final scores = <String, double>{};
  for (final m in _word.allMatches(sample.toLowerCase())) {
    final langs = _stopIndex[m.group(0)];
    if (langs == null) continue;
    for (final l in langs) {
      scores[l] = (scores[l] ?? 0) + 1 / langs.length;
    }
  }
  if (scores.isEmpty) return null;
  final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final best = ranked.first.value;
  final second = ranked.length > 1 ? ranked[1].value : 0.0;
  if (best < (strict ? 20 : 4) || best < second * (strict ? 3 : 1.5)) return null;
  return ranked.first.key;
}

String? _scriptOf(int r) {
  if (r >= 0x0980 && r <= 0x09FF) return 'bn';
  if (r >= 0x0900 && r <= 0x097F) return 'hi';
  if (r >= 0x0A00 && r <= 0x0A7F) return 'pa';
  if (r >= 0x0A80 && r <= 0x0AFF) return 'gu';
  if (r >= 0x0B00 && r <= 0x0B7F) return 'or';
  if (r >= 0x0B80 && r <= 0x0BFF) return 'ta';
  if (r >= 0x0C00 && r <= 0x0C7F) return 'te';
  if (r >= 0x0C80 && r <= 0x0CFF) return 'kn';
  if (r >= 0x0D00 && r <= 0x0D7F) return 'ml';
  if (r >= 0x0D80 && r <= 0x0DFF) return 'si';
  if (r >= 0x0E00 && r <= 0x0E7F) return 'th';
  if (r >= 0x0600 && r <= 0x06FF) return 'ar';
  if (r >= 0x0590 && r <= 0x05FF) return 'he';
  if (r >= 0x0400 && r <= 0x04FF) return 'ru';
  if (r >= 0x0370 && r <= 0x03FF) return 'el';
  if (r >= 0x3040 && r <= 0x30FF) return 'ja';
  if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
    return 'ko';
  }
  if (r >= 0x4E00 && r <= 0x9FFF) return 'zh';
  return null;
}

/// Languages whose script is Latin, so declared metadata can be trusted when
/// the text is Latin too.
const _latinScript = {
  'en', 'fr', 'de', 'es', 'it', 'pt', 'nl', 'sv', 'no', 'nb', 'da', 'fi',
  'pl', 'cs', 'sk', 'ro', 'hu', 'tr', 'id', 'ms', 'vi', 'ca', 'hr', 'sl',
  'lt', 'lv', 'et', 'tl', 'sw', 'af', 'eu', 'ga', 'is', 'la', 'sq',
};

/// The language to speak [book] in: script evidence first, then metadata if it
/// agrees with the script, then English.
///
/// Latin-script text with no language of its own (or the "en" so many
/// books carry by default, when its words say otherwise) is judged by its
/// commonest words. A book whose metadata says nothing, but whose
/// paragraphs are marked (xml:lang), goes by those marks.
///
/// A book with no text yet (a web novel before its first chapter is fetched)
/// is judged by its title and description, and failing those keeps what it
/// declares: there is no text to contradict it.
String resolveLanguage(Book book) {
  final declared = _primary(book.metadata.language) ?? _primary(_markedLanguage(book));
  final sample = _sampleOf(book);
  final empty = sample.trim().isEmpty;
  final fromScript = detectScriptLanguage(
    empty ? '${book.metadata.title} ${book.metadata.description ?? ''}' : sample,
  );
  if (fromScript != null) return fromScript;
  if (!empty) {
    final unknown = declared == null || !_latinScript.contains(declared);
    if (unknown || declared == 'en') {
      final fromWords = detectLatinLanguage(sample, strict: !unknown);
      if (fromWords != null) return fromWords;
    }
  }
  if (declared != null && (empty || _latinScript.contains(declared))) return declared;
  return 'en';
}

/// The language most of [book]'s text is marked as, block by block.
String? _markedLanguage(Book book) {
  final chars = <String, int>{};
  for (final s in book.sections) {
    for (final b in s.blocks) {
      final l = b.language;
      if (l != null) chars[l] = (chars[l] ?? 0) + b.text.length;
    }
  }
  if (chars.isEmpty) return null;
  return chars.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// [book] with its metadata language replaced by [resolveLanguage].
Book withResolvedLanguage(Book book) {
  final lang = resolveLanguage(book);
  if (book.metadata.language == lang) return book;
  return book.copyWith(metadata: book.metadata.copyWith(language: lang));
}

String? _primary(String? tag) {
  if (tag == null) return null;
  final t = tag.trim().toLowerCase();
  if (t.length < 2) return null;
  return t.split(RegExp('[-_]')).first;
}

/// A few thousand characters from across the book, skipping the front matter
/// that is often in English even when the book is not.
String _sampleOf(Book book) {
  final buf = StringBuffer();
  final sections = book.sections;
  if (sections.isEmpty) return '';
  final picks = <int>{
    for (final f in const [0.1, 0.3, 0.5, 0.7, 0.9])
      (sections.length * f).floor().clamp(0, sections.length - 1),
  };
  final order = [...picks, for (var i = 0; i < sections.length; i++) i];
  final seen = <int>{};
  for (final i in order) {
    if (!seen.add(i)) continue;
    for (final b in sections[i].blocks) {
      if (buf.length > 6000) return buf.toString();
      buf
        ..write(b.text)
        ..write(' ');
    }
  }
  return buf.toString();
}
