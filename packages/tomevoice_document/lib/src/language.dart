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
  return best.key;
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
/// A book with no text yet (a web novel before its first chapter is fetched)
/// is judged by its title and description, and failing those keeps what it
/// declares: there is no text to contradict it.
String resolveLanguage(Book book) {
  final declared = _primary(book.metadata.language);
  final sample = _sampleOf(book);
  final empty = sample.trim().isEmpty;
  final fromScript = detectScriptLanguage(
    empty ? '${book.metadata.title} ${book.metadata.description ?? ''}' : sample,
  );
  if (fromScript != null) return fromScript;
  if (declared != null && (empty || _latinScript.contains(declared))) return declared;
  return 'en';
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
