import 'library_store.dart';
import 'organise.dart';
import 'text_print.dart';

// Books that look like another copy of one already on the shelf: the same
// text in another file or format, by their prints (text_print.dart), or
// the same title by the same author where nothing says their texts
// differ. Only ever offered: two translations, or a book and its sample,
// share a title, and the reader decides.

/// How alike two prints must be to be the same text, and how unlike to be
/// different texts whatever their titles say.
const _sameText = 0.375;
const _otherText = 0.12;

/// Why [a] and [b] look like the same book, or null when they do not.
String? whySame(LibraryEntry a, LibraryEntry b) {
  if (a.id == b.id || a.isWeb || b.isWeb) return null;
  // Two volumes of one series are two books.
  final ai = a.seriesIndex, bi = b.seriesIndex;
  if (a.seriesName != null && b.seriesName != null && ai != null && bi != null && ai != bi) return null;
  final pa = a.textPrint, pb = b.textPrint;
  if (pa != null && pb != null && pa.isNotEmpty && pb.isNotEmpty) {
    final likeness = printLikeness(pa, pb);
    if (likeness >= _sameText) return 'The same text';
    if (likeness < _otherText) return null;
  }
  if (titleKey(a.title).isEmpty || titleKey(a.title) != titleKey(b.title)) return null;
  final fa = familyNames(a.authors), fb = familyNames(b.authors);
  if (fa.isNotEmpty && fb.isNotEmpty && fa.intersection(fb).isEmpty) return null;
  return 'The same title and author';
}

/// Why the books of [group] (one of duplicateGroups') look alike.
String whyAlike(List<LibraryEntry> group) {
  for (var i = 0; i < group.length; i++) {
    for (var j = i + 1; j < group.length; j++) {
      if (whySame(group[i], group[j]) case final why?) return why;
    }
  }
  return 'They look alike';
}

/// The books among [others] that [entry] looks like another copy of, with
/// why.
List<(LibraryEntry, String)> copiesOf(LibraryEntry entry, Iterable<LibraryEntry> others) => [
      for (final o in others)
        if (whySame(entry, o) case final why?) (o, why),
    ];

/// Every group of books in [books] that look like copies of one another,
/// the most recently touched first in each. [books] as a page has them: a
/// shut secret shelf's are not among them, so none is offered or named.
List<List<LibraryEntry>> duplicateGroups(List<LibraryEntry> books) {
  // Only books that share a title, or a hash among their prints' smallest,
  // are compared: not every pair of a thousand.
  final byTitle = <String, List<int>>{};
  final byHash = <int, List<int>>{};
  for (var i = 0; i < books.length; i++) {
    final b = books[i];
    if (b.isWeb) continue;
    final t = titleKey(b.title);
    if (t.isNotEmpty) (byTitle[t] ??= []).add(i);
    for (final h in printHashes(b.textPrint)) {
      (byHash[h] ??= []).add(i);
    }
  }
  final parent = List<int>.generate(books.length, (i) => i);
  int root(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  final tried = <int>{};
  void tryAll(List<int> group) {
    // A hash every book shares is a common phrase, not a sign of a copy.
    if (group.length < 2 || group.length > 40) return;
    for (var x = 0; x < group.length; x++) {
      for (var y = x + 1; y < group.length; y++) {
        final i = group[x], j = group[y];
        if (!tried.add(i * books.length + j)) continue;
        if (whySame(books[i], books[j]) != null) parent[root(i)] = root(j);
      }
    }
  }

  byTitle.values.forEach(tryAll);
  byHash.values.forEach(tryAll);
  final groups = <int, List<LibraryEntry>>{};
  for (var i = 0; i < books.length; i++) {
    (groups[root(i)] ??= []).add(books[i]);
  }
  return [
    for (final g in groups.values)
      if (g.length > 1) [...g]..sort((a, b) => b.lastTouched.compareTo(a.lastTouched)),
  ];
}
