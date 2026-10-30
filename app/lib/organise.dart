import 'book_search.dart' show foldForSearch;
import 'library_store.dart';
import 'prefs.dart';
import 'series.dart';

// The library beyond its shelves: tags, series, the orders books can be
// put in and what they can be narrowed to. Everything here is worked out
// from the books it is given, which a page has from LibraryStore.index: a
// shut secret shelf's books are not among them, so no tag, series,
// language, format or count here can tell of one.

// ------------------------------------------------------------------ order

/// [books] in the order [sort] puts them. Last read keeps the index's own
/// order (newest first). Ties fall back to the series' order, then the
/// title, so books of a series always stand in their order.
List<LibraryEntry> sortBooks(Iterable<LibraryEntry> books, LibrarySort sort) {
  final out = [...books];
  int title(LibraryEntry a, LibraryEntry b) => _cmpStr(foldForSearch(a.title), foldForSearch(b.title));
  int inSeries(LibraryEntry a, LibraryEntry b) {
    final c = _cmpStr(_seriesKey(a), _seriesKey(b));
    if (c != 0) return c;
    return (a.seriesIndex ?? double.infinity).compareTo(b.seriesIndex ?? double.infinity);
  }

  int then(int c, LibraryEntry a, LibraryEntry b) {
    if (c != 0) return c;
    final s = inSeries(a, b);
    if (s != 0) return s;
    final t = title(a, b);
    return t != 0 ? t : a.id.compareTo(b.id);
  }

  switch (sort) {
    case LibrarySort.recent:
      break;
    case LibrarySort.added:
      out.sort((a, b) => then(b.addedAt.compareTo(a.addedAt), a, b));
    case LibrarySort.title:
      out.sort((a, b) => then(title(a, b), a, b));
    case LibrarySort.author:
      // By family name; books with no author after those with one.
      out.sort((a, b) {
        final ka = authorKey(a.authors), kb = authorKey(b.authors);
        if (ka.isEmpty != kb.isEmpty) return ka.isEmpty ? 1 : -1;
        return then(_cmpStr(ka, kb), a, b);
      });
    case LibrarySort.series:
      // Each series together and in its order; books in none after, by title.
      out.sort((a, b) {
        final sa = a.seriesName == null, sb = b.seriesName == null;
        if (sa != sb) return sa ? 1 : -1;
        return then(0, a, b);
      });
    case LibrarySort.progress:
      out.sort((a, b) => then(b.progress.compareTo(a.progress), a, b));
  }
  return out;
}

int _cmpStr(String a, String b) => a.compareTo(b);

String _seriesKey(LibraryEntry e) => foldForSearch(e.seriesName ?? '');

/// How [authors] sort: by the first one's family name, as a library's shelf
/// does ("Austen, Jane" before "Dickens, Charles"). A name written
/// "Family, Given" is taken as it is; otherwise its last word, with the
/// little words before it that belong to it ("Le Guin", "van Gogh", "de la
/// Mare"), and without a Jr. or a III after it.
String authorKey(List<String> authors) {
  final name = authors.where((a) => a.trim().isNotEmpty).firstOrNull?.trim();
  if (name == null) return '';
  final (family, given) = _familyAndGiven(name);
  return foldForSearch('$family\u0000$given');
}

/// The family names of [authors], folded, to tell whether two books share
/// an author ("Jane Austen", "Austen, Jane" and "J. Austen" do).
Set<String> familyNames(List<String> authors) => {
      for (final a in authors)
        if (a.trim().isNotEmpty) foldForSearch(_familyAndGiven(a.trim()).$1),
    };

(String, String) _familyAndGiven(String name) {
  final comma = name.indexOf(',');
  if (comma > 0) {
    final after = name.substring(comma + 1).trim();
    // "Martin Luther King, Jr." is not "Family, Given".
    if (!_suffix.hasMatch(after)) return (name.substring(0, comma).trim(), after);
    name = name.substring(0, comma).trim();
  }
  final words = name.split(RegExp(r'\s+'));
  while (words.length > 1 && _suffix.hasMatch(words.last)) {
    words.removeLast();
  }
  if (words.length == 1) return (words.single, '');
  var start = words.length - 1;
  while (start > 0 && _particles.contains(words[start - 1].toLowerCase())) {
    start--;
  }
  // "Le Guin" when the whole is not only particles.
  if (start == 0) start = words.length - 1;
  return (words.sublist(start).join(' '), words.sublist(0, start).join(' '));
}

final _suffix = RegExp(r'^(?:jr|sr|ii|iii|iv|phd|md)\.?$', caseSensitive: false);

const _particles = {
  'de', 'da', 'di', 'du', 'del', 'della', 'des', 'la', 'le', 'van', 'von', 'der', 'den', 'ter', 'ten', 'af', 'bin',
  'ibn', 'al', 'el', 'st', 'st.', 'dos', 'das', 'do',
};

/// A title as two copies of one book share it: case, accents, punctuation,
/// a leading "The" or "A", and a subtitle or what is in brackets after it
/// set aside ("Pride and Prejudice: A Novel", "pride_and_prejudice",
/// "Pride & Prejudice (Penguin Classics)"). Numbers stay: volume 2 is
/// another book.
String titleKey(String title) {
  var t = title.replaceAll(RegExp(r'[(\[][^()\[\]]*[)\]]'), ' ');
  final colon = t.indexOf(RegExp(r':| - | – | — '));
  if (colon > 3) t = t.substring(0, colon);
  t = foldForSearch(t).replaceAll('&', ' and ').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  t = t.replaceFirst(RegExp(r'^(?:the|a|an) '), '');
  return t;
}

// ------------------------------------------------------------------ tags

/// How a tag is told apart from another: "Fantasy", "fantasy" and
/// " FANTASY " are one tag.
String tagKey(String tag) => foldForSearch(tag.trim().replaceAll(RegExp(r'\s+'), ' '));

/// The tags of [books], each once with how many of them carry it, in
/// alphabetical order. Its name is spelled as most of them spell it.
List<({String name, int count})> tagsIn(Iterable<LibraryEntry> books) {
  final spellings = <String, Map<String, int>>{};
  for (final b in books) {
    for (final t in b.tags) {
      final s = spellings[tagKey(t)] ??= {};
      s[t] = (s[t] ?? 0) + 1;
    }
  }
  final out = [
    for (final s in spellings.values)
      (
        name: (s.entries.toList()..sort((a, b) => b.value != a.value ? b.value - a.value : a.key.compareTo(b.key)))
            .first
            .key,
        count: s.values.fold(0, (a, b) => a + b),
      ),
  ];
  out.sort((a, b) => tagKey(a.name).compareTo(tagKey(b.name)));
  return out;
}

/// [typed], as a tag: trimmed, and spelled as [books] already spell it if
/// one of them carries it. Only [books] are asked, so a tag named here can
/// never take its spelling from a book on a shut secret shelf.
String tagNamed(String typed, Iterable<LibraryEntry> books) {
  final clean = typed.trim().replaceAll(RegExp(r'\s+'), ' ');
  final key = tagKey(clean);
  for (final t in tagsIn(books)) {
    if (tagKey(t.name) == key) return t.name;
  }
  return clean;
}

/// [tags] with each one once, the first spelling kept.
List<String> distinctTags(Iterable<String> tags) {
  final seen = <String>{};
  return [
    for (final t in tags)
      if (t.trim().isNotEmpty && seen.add(tagKey(t))) t.trim().replaceAll(RegExp(r'\s+'), ' '),
  ];
}

// ---------------------------------------------------------------- series

/// The series of [books], each once with how many of them are in it, in
/// alphabetical order.
List<({String name, int count})> seriesIn(Iterable<LibraryEntry> books) {
  final names = <String, String>{};
  final counts = <String, int>{};
  for (final b in books) {
    final s = b.seriesName;
    if (s == null) continue;
    final k = foldForSearch(s);
    names.putIfAbsent(k, () => s);
    counts[k] = (counts[k] ?? 0) + 1;
  }
  final keys = names.keys.toList()..sort();
  return [for (final k in keys) (name: names[k]!, count: counts[k]!)];
}

/// [typed], as a series' name: trimmed, and spelled as [books] already
/// spell it if one of them is in it (only [books] are asked, as for tags).
String seriesNamed(String typed, Iterable<LibraryEntry> books) {
  final clean = typed.trim().replaceAll(RegExp(r'\s+'), ' ');
  final key = foldForSearch(clean);
  for (final s in seriesIn(books)) {
    if (foldForSearch(s.name) == key) return s.name;
  }
  return clean;
}

/// The books of series [name] among [books], in its order.
List<LibraryEntry> booksInSeries(Iterable<LibraryEntry> books, String name) {
  final key = foldForSearch(name);
  return sortBooks([for (final b in books) if (b.seriesName != null && foldForSearch(b.seriesName!) == key) b],
      LibrarySort.series);
}

/// "Book 3 of A Song of Ice and Fire", or the series' name alone when the
/// book's number in it is not known.
String seriesLine(LibraryEntry e) {
  final name = e.seriesName;
  if (name == null) return '';
  final n = e.seriesIndex;
  return n == null ? name : 'Book ${seriesNumber(n)} of $name';
}

// --------------------------------------------------------------- filters

/// How far a book has been read, for the shelf's filter.
enum ReadState {
  unread('Not started'),
  reading('In progress'),
  finished('Finished');

  const ReadState(this.label);
  final String label;

  static ReadState of(LibraryEntry e) => e.finished ? finished : (e.progress > 0 ? reading : unread);
}

/// A book's language as the filter groups it: "en" for "en-GB" too.
String? languageKey(LibraryEntry e) {
  final l = e.language?.toLowerCase();
  if (l == null || l.isEmpty) return null;
  return l.split(RegExp('[-_]')).first;
}

/// What the shelf is narrowed to: books in one of the chosen states, of one
/// of the chosen formats, and so on. A kind with nothing chosen narrows
/// nothing. Tags and series are kept by their keys (tagKey, folded names).
class ShelfFilter {
  const ShelfFilter({
    this.states = const {},
    this.formats = const {},
    this.languages = const {},
    this.tags = const {},
    this.series = const {},
  });

  final Set<ReadState> states;
  final Set<String> formats;
  final Set<String> languages;
  final Set<String> tags;
  final Set<String> series;

  bool get isEmpty => states.isEmpty && formats.isEmpty && languages.isEmpty && tags.isEmpty && series.isEmpty;

  /// How many things are chosen.
  int get count => states.length + formats.length + languages.length + tags.length + series.length;

  bool matches(LibraryEntry e) =>
      (states.isEmpty || states.contains(ReadState.of(e))) &&
      (formats.isEmpty || formats.contains(e.formatLabel)) &&
      (languages.isEmpty || languages.contains(languageKey(e))) &&
      (tags.isEmpty || e.tags.any((t) => tags.contains(tagKey(t)))) &&
      (series.isEmpty || (e.seriesName != null && series.contains(foldForSearch(e.seriesName!))));

  /// Only what [books] still have: a tag, series, format or language none
  /// of them carries is dropped (a shelf shut on the books that had it),
  /// so it is neither applied nor shown.
  ShelfFilter within(Iterable<LibraryEntry> books) {
    if (isEmpty) return this;
    final formatsHere = <String>{}, languagesHere = <String>{}, tagsHere = <String>{}, seriesHere = <String>{};
    for (final b in books) {
      formatsHere.add(b.formatLabel);
      if (languageKey(b) case final l?) languagesHere.add(l);
      for (final t in b.tags) {
        tagsHere.add(tagKey(t));
      }
      if (b.seriesName case final s?) seriesHere.add(foldForSearch(s));
    }
    final next = ShelfFilter(
      states: states,
      formats: formats.intersection(formatsHere),
      languages: languages.intersection(languagesHere),
      tags: tags.intersection(tagsHere),
      series: series.intersection(seriesHere),
    );
    return next.count == count ? this : next;
  }

  ShelfFilter copyWith({
    Set<ReadState>? states,
    Set<String>? formats,
    Set<String>? languages,
    Set<String>? tags,
    Set<String>? series,
  }) =>
      ShelfFilter(
        states: states ?? this.states,
        formats: formats ?? this.formats,
        languages: languages ?? this.languages,
        tags: tags ?? this.tags,
        series: series ?? this.series,
      );

  @override
  bool operator ==(Object other) =>
      other is ShelfFilter &&
      _same(states, other.states) &&
      _same(formats, other.formats) &&
      _same(languages, other.languages) &&
      _same(tags, other.tags) &&
      _same(series, other.series);

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(states),
        Object.hashAllUnordered(formats),
        Object.hashAllUnordered(languages),
        Object.hashAllUnordered(tags),
        Object.hashAllUnordered(series),
      );

  static bool _same<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);
}

/// [set] with [value] taken out if it is in, put in if it is not.
Set<T> toggled<T>(Set<T> set, T value) => set.contains(value) ? ({...set}..remove(value)) : {...set, value};
