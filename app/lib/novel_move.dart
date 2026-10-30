import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor, SourceKind;

import 'download_queue.dart';
import 'library_store.dart';
import 'marks.dart';
import 'prefs.dart';
import 'read_marks.dart';
import 'safe_file.dart';
import 'sources/models.dart';

/// The number a chapter's title gives it: "Chapter 12", "Ch. 12.5: Dusk",
/// "12 - Dawn", "Episode 3", "c12", "第12章", and "Vol. 2 Chapter 4" (4: a
/// volume's, book's or part's number is not the chapter's). Null when it
/// says none: a number in a title's words ("The 100 Doors") is not one.
double? chapterNumberOf(String name) {
  var t = name.toLowerCase();
  // "Chapter 1,234": one number.
  for (var before = ''; before != t;) {
    before = t;
    t = t.replaceAllMapped(RegExp(r'(\d),(\d{3})(?!\d)'), (m) => '${m[1]}${m[2]}');
  }
  final cjk = RegExp(r'第\s*(\d+(?:\.\d+)?)').firstMatch(t);
  if (cjk != null) return double.tryParse(cjk[1]!);
  final rest = t.replaceAll(RegExp(r'(?<![a-z])(?:volume|vol|book|arc|season|part|pt|v)\.?\s*\d+(?:\.\d+)?'), ' ');
  final named = RegExp(r'(?<![a-z])(?:chapter|chap|ch|episode|ep|c)\.?\s*(\d+(?:\.\d+)?)').firstMatch(rest);
  if (named != null) return double.tryParse(named[1]!);
  final first = RegExp(r'^[^\p{L}\d]*(\d+(?:\.\d+)?)(?![\p{L}\d])', unicode: true).firstMatch(rest);
  return first == null ? null : double.tryParse(first[1]!);
}

/// Where each chapter of one source's list is in another's: the same
/// novel's chapters, as two sites list them.
class ChapterMatch {
  ChapterMatch(Map<int, int> to, {required this.fromCount, required this.toCount})
      : to = Map.unmodifiable(to),
        _matched = to.keys.toList()..sort();

  /// Old chapter to its place in the new list, for those found there.
  final Map<int, int> to;
  final int fromCount;
  final int toCount;
  final List<int> _matched;

  int get matched => to.length;

  /// Where old chapter [i] is in the new list: its match, or where it would
  /// be going by the nearest chapter before it that was matched (after it,
  /// for one before them all), within the new list.
  int follow(int i) {
    if (toCount <= 0) return 0;
    final j = to[i];
    if (j != null) return j;
    // The last matched chapter before i, by halves.
    var lo = 0, hi = _matched.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_matched[mid] < i) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final int at;
    if (lo > 0) {
      final k = _matched[lo - 1];
      at = to[k]! + (i - k);
    } else if (lo < _matched.length) {
      final k = _matched[lo];
      at = to[k]! - (k - i);
    } else {
      at = i;
    }
    return at.clamp(0, toCount - 1);
  }
}

/// Words that say nothing of a chapter in particular.
const _noise = {'chapter', 'chap', 'ch', 'c', 'episode', 'ep', 'volume', 'vol', 'v', 'part', 'pt', 'the', 'a', 'an', 'of'};

final _split = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _digits = RegExp(r'^\d+$');

/// [names]' words, each without the noise, the numbers and the words most
/// of the list shares (a novel's title the site puts before every chapter).
List<Set<String>> _wordsOf(List<String> names) {
  final words = [
    for (final n in names)
      {
        for (final w in n.toLowerCase().split(_split))
          if (w.isNotEmpty && !_noise.contains(w) && !_digits.hasMatch(w)) w,
      },
  ];
  if (names.length < 4) return words;
  final seen = <String, int>{};
  for (final ws in words) {
    for (final w in ws) {
      seen[w] = (seen[w] ?? 0) + 1;
    }
  }
  final common = {for (final e in seen.entries) if (e.value * 2 > names.length) e.key};
  if (common.isEmpty) return words;
  return [for (final ws in words) ws.difference(common)];
}

/// A name with only its letters and numbers, numbers without leading
/// zeros: "Chapter 044: Dawn!" and "chapter 44 - dawn" are one.
String _plain(String name) => name
    .toLowerCase()
    .split(_split)
    .where((w) => w.isNotEmpty)
    .map((w) => _digits.hasMatch(w) ? '${int.tryParse(w) ?? w}' : w)
    .join(' ');

/// How alike two chapters' words are (0 to 1); null when either has none.
double? _alike(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return null;
  return a.intersection(b).length / a.union(b).length;
}

/// The chapters of [from] (one site's list) found in [to] (another's, the
/// same novel): by their numbers and names first, kept in the order both
/// lists run (a number that turns up out of order, "The 100 Doors" among
/// chapters in the twenties, is not taken); then, between those, by the
/// words of their titles; then, where as many are left on both sides, in
/// turn. No place is given twice.
ChapterMatch matchChapters(List<ChapterItem> from, List<ChapterItem> to) {
  final fromNumbers = [for (final c in from) chapterNumberOf(c.name) ?? c.number];
  final toNumbers = [for (final c in to) chapterNumberOf(c.name) ?? c.number];
  final fromPlain = [for (final c in from) _plain(c.name)];
  final toPlain = [for (final c in to) _plain(c.name)];
  final fromWords = _wordsOf([for (final c in from) c.name]);
  final toWords = _wordsOf([for (final c in to) c.name]);

  // Pairs that could be the same chapter: the same number, or the same
  // name. A key on many chapters (every one "Chapter") is no help.
  Map<K, List<int>> index<K>(List<K?> keys) {
    final out = <K, List<int>>{};
    for (var j = 0; j < keys.length; j++) {
      final k = keys[j];
      if (k != null && (k is! String || k.isNotEmpty)) (out[k] ??= []).add(j);
    }
    return out;
  }

  final byNumber = index(toNumbers);
  final byName = index(toPlain);
  final pairs = <(int, int)>{};
  for (var i = 0; i < from.length; i++) {
    for (final (keys, key) in [(byNumber[fromNumbers[i]], fromNumbers[i]), (byName[fromPlain[i]], fromPlain[i])]) {
      if (keys == null || key == null || keys.length > 20) continue;
      for (final j in keys) {
        pairs.add((i, j));
      }
    }
  }

  // The longest run of them in order on both sides: each a chapter's
  // place, held fast. Of two runs as long, the one nearer the lists'
  // own order (a site that numbers on through its volumes, beside one
  // that starts each volume at 1 again: the first volume, not the last).
  final sorted = pairs.toList()..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.compareTo(a.$2));
  final tails = <int>[];
  final back = List<int>.filled(sorted.length, -1);
  for (var k = 0; k < sorted.length; k++) {
    final (i, j) = sorted[k];
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[tails[mid]].$2 < j) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == tails.length) {
      if (lo > 0) back[k] = tails[lo - 1];
      tails.add(k);
    } else {
      final (ti, tj) = sorted[tails[lo]];
      if (tj == j && (ti - tj).abs() <= (i - j).abs()) continue;
      if (lo > 0) back[k] = tails[lo - 1];
      tails[lo] = k;
    }
  }
  final placed = <int, int>{};
  for (var k = tails.isEmpty ? -1 : tails.last; k >= 0; k = back[k]) {
    placed[sorted[k].$1] = sorted[k].$2;
  }

  // Between two held chapters (or before the first, after the last): the
  // rest by their titles' words, in order; then, between two held ones
  // only, in turn where as many are left on both sides (at either end of
  // the lists that is no sign: one site's newest chapter beside the
  // other's side story).
  void fill(int a, int b, int c, int d) {
    if (a >= b || c >= d) return;
    final held = <(int, int)>[(a - 1, c - 1)];
    var next = c;
    for (var i = a; i < b && next < d; i++) {
      int? best;
      var bestScore = 0.5;
      for (var j = next; j < d && j < next + 50; j++) {
        final s = _alike(fromWords[i], toWords[j]);
        if (s != null && s > bestScore) {
          best = j;
          bestScore = s;
        }
      }
      if (best != null) {
        placed[i] = best;
        held.add((i, best));
        next = best + 1;
      }
    }
    held.add((b, d));
    // As many on both sides between two held chapters: the same ones, in
    // turn (two translations title a chapter each their own way).
    for (var h = 0; h + 1 < held.length; h++) {
      final (i0, j0) = held[h];
      final (i1, j1) = held[h + 1];
      if (i1 - i0 != j1 - j0) continue;
      if (i0 < 0 || i1 >= from.length) continue;
      for (var k = 1; i0 + k < i1; k++) {
        placed[i0 + k] = j0 + k;
      }
    }
  }

  final anchors = (placed.keys.toList()..sort());
  var i0 = 0, j0 = 0;
  for (final i in anchors) {
    final j = placed[i]!;
    fill(i0, i, j0, j);
    i0 = i + 1;
    j0 = j + 1;
  }
  fill(i0, from.length, j0, to.length);
  return ChapterMatch(placed, fromCount: from.length, toCount: to.length);
}

/// Why a novel cannot be moved where the reader picked.
class MoveRefused implements Exception {
  MoveRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A move worked out, to be shown before it is made: the novel there, how
/// its chapters match, and what goes with it.
class MovePlan {
  const MovePlan({
    required this.to,
    required this.novel,
    required this.match,
    required this.downloads,
    required this.carried,
    required this.marks,
    required this.readMarks,
    required this.place,
    required this.placeThere,
  });

  /// The source it moves to.
  final PluginInfo to;

  /// The novel there, with its whole chapter list.
  final SourceNovel novel;
  final ChapterMatch match;

  /// Chapters on the phone, and how many of them go to a chapter there
  /// (the rest are kept aside, never deleted).
  final int downloads;
  final int carried;

  /// Quotes and bookmarks.
  final int marks;

  /// Chapters marked read or unread by hand.
  final int readMarks;

  /// The chapter the place is in here (-1: not begun), and the one it is
  /// in there.
  final int place;
  final int placeThere;
}

/// Work out moving web novel [entry] to [novel] on source [to] (its details
/// and whole chapter list, just fetched). Throws [MoveRefused] when it cannot
/// go there.
Future<MovePlan> planMove(LibraryStore store, LibraryEntry entry, PluginInfo to, SourceNovel novel) async {
  if (!entry.isWeb) throw MoveRefused('Only a web novel moves to another source.');
  final id = LibraryStore.webId(to.id, novel.path);
  if (id == entry.id) throw MoveRefused('That is where it is already.');
  if ((await store.list(all: true)).any((e) => e.id == id)) {
    throw MoveRefused('That novel is in your library already, from ${to.name}.');
  }
  if (!novel.complete) throw MoveRefused("${to.name}'s chapter list did not come in whole. Try again in a moment.");
  if (novel.chapters.isEmpty) throw MoveRefused('${to.name} lists no chapters for it.');
  final info = await store.settleWebChapters(entry.id);
  if (info == null) throw MoveRefused('This novel is not in the library.');
  final match = matchChapters(info.chapters, novel.chapters);
  final downloads = store.downloadedChapters(entry.id);
  final cursor = await store.cursorFor(entry.id);
  final begun = entry.openedAt != null;
  final read = await ReadMarkStore.instance.of(store, entry.id);
  return MovePlan(
    to: to,
    novel: novel,
    match: match,
    downloads: downloads.length,
    carried: downloads.where(match.to.containsKey).length,
    marks: MarkStore.instance.forBook(entry.id).length,
    readMarks: read.read.length + read.unread.length,
    place: begun ? cursor.sectionIndex : -1,
    placeThere: begun ? match.follow(cursor.sectionIndex) : -1,
  );
}

/// Move web novel [entry] to the novel and source of [plan], as Mihon
/// migrates: the novel there takes its place in the library, on the same
/// shelf, with what was kept for it carried to the same chapters there (by
/// [MovePlan.match]): the place, the downloads (one that matches nothing is
/// kept aside under ch/orphaned, never deleted), quotes and bookmarks, read
/// marks, its cover and its own settings (voice, speed, order). Chapters
/// waiting to download wait there instead. The new entry.
///
/// The new folder is made whole first and the library's entry swapped in
/// one step; the old folder goes last.
Future<LibraryEntry> moveNovel(LibraryStore store, LibraryEntry entry, MovePlan plan, {DownloadQueue? queue}) async {
  final from = entry.id;
  final to = LibraryStore.webId(plan.to.id, plan.novel.path);
  final info = await store.settleWebChapters(from);
  if (info == null) throw MoveRefused('This novel is not in the library.');
  final match = plan.match;
  final q = queue ?? DownloadQueue.instance;
  // Nothing comes down into the old folder while it moves.
  final waiting = await q.takeOut(from);

  final oldDir = store.bookDir(from);
  final newDir = store.bookDir(to);
  final there = Directory(newDir);
  // Left by a move that stopped part way: not in the library.
  if (await there.exists()) await there.delete(recursive: true);
  await there.create(recursive: true);
  final novel = WebNovelInfo(
    plugin: plan.to,
    novel: plan.novel,
    chapters: plan.novel.chapters,
    checkedAt: DateTime.now(),
    filed: true,
  );
  await writeSafely(File('$newDir/novel.json'), jsonEncode(novel.toJson()));
  final downloaded = store.downloadedChapters(from);
  await _runMoveFiles(oldDir, newDir, {...match.to});

  // The place, in the same chapter there: at its sentence when that
  // chapter's text came along, else at its start.
  final cursor = await store.cursorFor(from);
  final begun = entry.openedAt != null;
  final c = cursor.sectionIndex;
  final carried = match.to.containsKey(c) && downloaded.contains(c);
  final place = !begun
      ? cursor
      : ReadingCursor(
          sectionIndex: match.follow(c),
          blockIndex: carried ? cursor.blockIndex : 0,
          sentenceIndex: carried ? cursor.sentenceIndex : 0,
        );
  final count = plan.novel.chapters.length;
  final within = (entry.progress * info.chapters.length - c).clamp(0.0, 1.0);
  final progress = !begun ? entry.progress : ((place.sectionIndex + within) / count).clamp(0.0, 1.0);
  await writeSafely(File('$newDir/cursor.json'), jsonEncode({'cursor': place.toJson(), 'progress': progress}));

  // Read marks, by the chapters' addresses there.
  final oldAt = {for (var i = 0; i < info.chapters.length; i++) info.chapters[i].path: i};
  ChapterItem? chapterThere(String path) {
    final i = oldAt[path];
    final j = i == null ? null : match.to[i];
    return j == null ? null : plan.novel.chapters[j];
  }

  final marks = await ReadMarkStore.instance.of(store, from);
  if (!marks.isEmpty) await ReadMarkStore.instance.replace(store, to, marks.mapped((p) => chapterThere(p)?.path));

  String? rebased(String? path) =>
      path != null && path.startsWith('$oldDir/') ? '$newDir/${path.substring(oldDir.length + 1)}' : path;
  final moved = LibraryEntry(
    id: to,
    title: plan.novel.name.isEmpty ? entry.title : plan.novel.name,
    authors: plan.novel.author == null ? entry.authors : [plan.novel.author!],
    source: SourceKind.web,
    wordCount: 0,
    sourcePath: '',
    addedAt: entry.addedAt,
    openedAt: entry.openedAt,
    cursor: place,
    progress: progress,
    where: entry.where,
    language: entry.language,
    cover: rebased(entry.cover),
    coverMode: entry.coverMode,
    customCover: rebased(entry.customCover),
    category: entry.category,
    plugin: plan.to.id,
    novelPath: plan.novel.path,
    chapterCount: count,
  );
  await store.swapWebNovel(from, moved);

  // What else is kept by the book: its quotes and bookmarks, and its own
  // voice, speed and order.
  await MarkStore.instance.moveBook(from, to, match.follow);
  final prefs = ListeningPrefs.loaded;
  if (prefs != null && movePrefs(prefs, from, to)) prefs.save();

  // Chapters that were waiting to download, at their places there.
  final again = [
    for (final j in waiting)
      if (chapterThere(j.path) case final c?) c,
  ];
  if (again.isNotEmpty) await q.add(to, again);

  try {
    await Directory(oldDir).delete(recursive: true);
  } on FileSystemException {
    // Left behind; nothing reads it.
  }
  return moved;
}

/// [prefs]' settings of book [from] (voice, dialogue voice, speed, order of
/// chapters, new chapters downloading by themselves) as book [to]'s.
/// Whether any were.
bool movePrefs(ListeningPrefs prefs, String from, String to) {
  var any = false;
  void move<T>(Map<String, T> m) {
    if (!m.containsKey(from)) return;
    m[to] = m.remove(from) as T;
    any = true;
  }

  move(prefs.voiceByBook);
  move(prefs.dialogueByBook);
  move(prefs.speedByBook);
  move(prefs.newestFirstByNovel);
  move(prefs.autoDownloadByNovel);
  return any;
}

// Top-level, so the closure handed to Isolate.run captures only these.
Future<void> _runMoveFiles(String from, String to, Map<int, int> places) =>
    Isolate.run(() => _moveFilesSync(from, to, places));

/// Move what [from] (an old book folder) keeps to [to]: its pictures, its
/// downloads to their chapters' places by [places] (one with no place, or
/// whose place holds one already, kept aside under ch/orphaned), and those
/// set aside before.
void _moveFilesSync(String from, String to, Map<int, int> places) {
  final img = Directory('$from/img');
  if (img.existsSync()) img.renameSync('$to/img');
  final ch = Directory('$from/ch');
  if (!ch.existsSync()) return;
  final into = Directory('$to/ch')..createSync(recursive: true);
  void aside(File f, String name) {
    final dir = Directory('${into.path}/orphaned')..createSync(recursive: true);
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    var target = '${dir.path}/$name';
    for (var k = 1; File(target).existsSync(); k++) {
      target = '${dir.path}/$stem-$k.json';
    }
    f.renameSync(target);
  }

  for (final f in ch.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    final n = int.tryParse(name.substring(0, name.length - 5));
    final j = n == null ? null : places[n];
    if (j != null && !File('${into.path}/$j.json').existsSync()) {
      f.renameSync('${into.path}/$j.json');
    } else {
      aside(f, name);
    }
  }
  final orphans = Directory('${ch.path}/orphaned');
  if (orphans.existsSync()) {
    for (final f in orphans.listSync().whereType<File>()) {
      aside(f, f.uri.pathSegments.last);
    }
  }
}
