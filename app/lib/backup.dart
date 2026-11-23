import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'error_log.dart' show ErrorLog;
import 'library_store.dart';
import 'marks.dart' show Mark;
import 'organise.dart' show distinctTags;
import 'safe_file.dart';
import 'speech_service.dart';
import 'stats.dart';

const _svc = SpeechService();

/// The backup format this build writes and the newest it can read.
const backupFormat = 1;

/// What a backup says about itself (`manifest.json`, first in the zip).
class BackupInfo {
  const BackupInfo({
    required this.format,
    required this.created,
    required this.root,
    required this.books,
    required this.chapters,
    this.appVersion,
  });

  final int format;
  final DateTime created;

  /// The library folder it was made from. Paths in `library.json` start with
  /// it, and a restore into another folder (another app id, another phone)
  /// rewrites them.
  final String root;
  final int books;

  /// Whether downloaded web chapters are in it.
  final bool chapters;
  final String? appVersion;

  Map<String, Object?> toJson() => {
        'app': 'TomeVoice',
        'format': format,
        'created': created.toIso8601String(),
        'root': root,
        'books': books,
        'chapters': chapters,
        if (appVersion != null) 'appVersion': appVersion,
      };

  static BackupInfo fromJson(Map<String, Object?> json) => BackupInfo(
        format: json['format'] as int? ?? 0,
        created: DateTime.tryParse(json['created'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        root: json['root'] as String? ?? '',
        books: json['books'] as int? ?? 0,
        chapters: json['chapters'] != false,
        appVersion: json['appVersion'] as String?,
      );
}

/// "TomeVoice-backup-2026-10-24.zip".
String backupFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'TomeVoice-backup-${now.year}-${two(now.month)}-${two(now.day)}.zip';
}

/// Write the library to a zip where the reader chooses. Null when they
/// closed the save dialog; otherwise how many files and bytes went in.
Future<({int files, int bytes})?> backUpLibrary(LibraryStore store, {required bool includeChapters}) async {
  // The places kept in memory go into library.json first (see saveCursor).
  await store.settlePlaces();
  final books = (await store.list()).length;
  final now = DateTime.now();
  final info = BackupInfo(
    format: backupFormat,
    created: now,
    root: store.root.path,
    books: books,
    chapters: includeChapters,
    appVersion: await _svc.appVersion(),
  );
  final r = await _svc.backupLibrary(
    manifest: jsonEncode(info.toJson()),
    includeChapters: includeChapters,
    fileName: backupFileName(now),
  );
  if (r == null) return null;
  return (files: (r['files'] as num?)?.toInt() ?? 0, bytes: (r['bytes'] as num?)?.toInt() ?? 0);
}

/// A backup unpacked next to the library, waiting to replace it or be added.
class StagedBackup {
  const StagedBackup(this.dir, this.info);

  final Directory dir;
  final BackupInfo info;

  /// Throw it away (the reader changed their mind).
  Future<void> discard() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Where a backup is unpacked: inside the library folder, so moving its
/// files into place is a rename, never a copy. Never backed up itself.
Directory stagingDir(Directory root) => Directory('${root.path}/.restore');

/// Remove a backup left unpacked by a restore that never finished, and
/// finish or undo a swap the app was stopped in the middle of.
Future<void> clearStaleRestore(Directory root, {DateTime? now}) async {
  try {
    await settleSwap(root);
    final dir = stagingDir(root);
    if (await dir.exists()) await dir.delete(recursive: true);
    await _dropReplaced(root, now ?? DateTime.now());
  } on Object {
    // Tried again next launch.
  }
}

/// The library a replace took the place of is kept a while, in a hidden
/// folder named with when ([_replacedPrefix] and the milliseconds), and not
/// deleted at once: whatever the backup lacked and the replace did not
/// carry over is still on the phone if it is missed. Deleted at the first
/// start [replacedKept] later.
const _replacedPrefix = '.replaced-library-';
const replacedKept = Duration(days: 1);

Future<void> _dropReplaced(Directory root, DateTime now) async {
  await for (final e in root.list()) {
    final name = _name(e);
    if (e is! Directory || !name.startsWith(_replacedPrefix)) continue;
    final ms = int.tryParse(name.substring(_replacedPrefix.length).split('-').first);
    if (ms == null) continue;
    if (now.difference(DateTime.fromMillisecondsSinceEpoch(ms)) >= replacedKept) await e.delete(recursive: true);
  }
}

/// What a replace has moved so far, written as it goes: an app stopped part
/// way through (or a failure that could not be undone) left the library
/// split, the old one in a hidden folder that the next replace deleted.
File _journal(Directory root) => File('${root.path}/.restore-journal.json');
Directory _aside(Directory root) => Directory('${root.path}/.before-restore');

/// A replace that failed and could not be undone at once: the journal stays,
/// and the next start puts the library back.
class RestoreUnsettled implements Exception {
  const RestoreUnsettled();

  @override
  String toString() => 'The restore stopped part way. TomeVoice puts your library back when it next starts.';
}

/// Finish a swap that got all the way through, or put the library back
/// as it was before one that did not.
Future<void> settleSwap(Directory root) async {
  final journal = _journal(root);
  final aside = _aside(root);
  if (!await journal.exists()) {
    // Before journals, a replace left this only when it could not undo
    // itself: what is in it is the library as it was. Put it back where
    // nothing has taken its place.
    if (await aside.exists()) {
      await for (final e in aside.list()) {
        final name = _name(e);
        if (!await _exists('${root.path}/$name')) await e.rename('${root.path}/$name');
      }
      if (await aside.list().isEmpty) await aside.delete(recursive: true);
    }
    return;
  }
  Map<String, Object?> j;
  try {
    j = Map<String, Object?>.from(jsonDecode(await journal.readAsString()) as Map);
  } on Object {
    j = const {};
  }
  if (j['done'] == true) {
    // Kept a while (see _dropReplaced), never deleted at once.
    if (await aside.exists()) {
      final ms = DateTime.now().millisecondsSinceEpoch;
      var to = '${root.path}/$_replacedPrefix$ms';
      for (var n = 2; await _exists(to); n++) {
        to = '${root.path}/$_replacedPrefix$ms-$n';
      }
      await aside.rename(to);
    }
  } else {
    final staged = stagingDir(root);
    for (final name in (j['in'] as List? ?? const []).cast<String>()) {
      // Only what the swap brought in: never a dot-file (its own folders,
      // this journal, the secrets) or what stays on the phone, nor a name
      // still in the unpacked backup, whose move never happened. Deleting a
      // ".before-restore" a crafted backup named deleted the library.
      if (!_swapped(name) || await _exists('${staged.path}/$name')) continue;
      final path = '${root.path}/$name';
      if (await _exists(path)) await _entity(path).delete(recursive: true);
    }
    for (final name in (j['aside'] as List? ?? const []).cast<String>()) {
      if (!_swapped(name)) continue;
      final from = '${aside.path}/$name';
      if (await _exists(from)) await _entity(from).rename('${root.path}/$name');
    }
    // Emptied, it goes; anything left in it is kept, under another name.
    if (await aside.exists()) {
      if (await aside.list().isEmpty) {
        await aside.delete();
      } else {
        await aside.rename('${aside.path}-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
  }
  await journal.delete();
}

/// Whether [name] is one a swap moves: a plain name at the library's top,
/// not a dot-file, nor what stays on the phone.
bool _swapped(String name) =>
    name.isNotEmpty && !name.startsWith('.') && !name.contains('/') && !name.contains(r'\') && !keptOnPhone.contains(name);

Future<bool> _exists(String path) async => await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

/// Ask for a backup and unpack it. Null when the reader closed the picker.
Future<StagedBackup?> pickBackup(LibraryStore store) async {
  final staging = stagingDir(store.root);
  final manifest = await _svc.pickBackup(staging.path);
  if (manifest == null) return null;
  final staged = StagedBackup(staging, BackupInfo.fromJson(Map<String, Object?>.from(jsonDecode(manifest) as Map)));
  try {
    await checkStaged(staged, store.root);
  } on Object {
    await staged.discard();
    rethrow;
  }
  return staged;
}

/// Make sure [staged] can be used here, and point its paths at [root].
Future<void> checkStaged(StagedBackup staged, Directory root) async {
  if (staged.info.format > backupFormat) {
    throw const FormatException('That backup was made by a newer TomeVoice. Update the app first.');
  }
  final index = File('${staged.dir.path}/library.json');
  if (!await index.exists()) {
    throw const FormatException('That backup has no library in it.');
  }
  // A backup never holds a dot-file or dot-folder at its top (the unpacker
  // refuses one too): those are a restore's own, and a ".before-restore"
  // brought in made a replace delete the library it had moved aside.
  await for (final e in staged.dir.list()) {
    if (_name(e).startsWith('.')) throw const FormatException('That backup is damaged or was not made by TomeVoice.');
  }
  // Every book's id becomes a folder name: one that is not a book id (a
  // "..") could delete or replace folders outside the books. And every
  // entry must read as the library reads it, before anything is swapped.
  try {
    final books = (jsonDecode(await index.readAsString()) as Map)['books'] as List? ?? const [];
    for (final b in books) {
      if (b is! Map || !LibraryStore.isBookId('${b['id']}')) throw const FormatException('');
      LibraryEntry.fromJson(Map<String, Object?>.from(b));
    }
  } on Object {
    throw const FormatException('That backup is damaged or was not made by TomeVoice.');
  }
  // What a backup never carries, even if a file says otherwise: the update
  // check's state (it names the APK to install).
  final update = File('${staged.dir.path}/app_update.json');
  if (await update.exists()) await update.delete();
  await rewritePaths(index, from: staged.info.root, to: root.path);
}

/// Book files and covers are stored with their full path, which names the
/// app's folder. Point them at [to].
Future<void> rewritePaths(File index, {required String from, required String to}) async {
  if (from.isEmpty || from == to) return;
  final text = await index.readAsString();
  final next = text.replaceAll('$from/', '$to/');
  if (next != text) await index.writeAsString(next);
}

/// What stays on this phone through a restore: never in a backup, so never
/// swapped. The natural voices (moved aside with the rest, a restore deleted
/// them), the OCR language data and any scan being read (ocr.dart), the
/// update check's state, which holds whether to check at all, and the error
/// log and when it last asked Android how runs ended, this phone's own
/// (error_log.dart: they share the library's folder only on a phone with no
/// storage outside the app).
const keptOnPhone = {
  'voices',
  'ocr',
  'app_update.json',
  ErrorLog.fileName,
  ErrorLog.exitsName,
  'voice-log.jsonl',
  'voice-log.on',
};

/// What a replace kept of the library it replaced, that the backup did not
/// have: books on a secret shelf, downloaded chapters, and the AI memories
/// kept from removed books.
typedef ReplaceReport = ({int secretBooks, int chapters, int memories});

/// The folder of memories kept from removed books (LibraryStore's
/// kept-memories): one folder a book, by its id, with memory.db and
/// kept.json.
const keptMemoriesDir = 'kept-memories';

/// The kept memories in library folder [root]: book id to its folder.
Future<Map<String, Directory>> _keptIn(String root) async {
  final dir = Directory('$root/$keptMemoriesDir');
  if (!await dir.exists()) return const {};
  final out = <String, Directory>{};
  await for (final d in dir.list()) {
    if (d is! Directory) continue;
    final id = _name(d);
    if (LibraryStore.isBookId(id) && await File('${d.path}/memory.db').exists()) out[id] = d;
  }
  return out;
}

/// When kept memory [d] was kept (its kept.json), for which of two is newer.
Future<DateTime> _keptAt(Directory d) async {
  final about = await _readMap(File('${d.path}/kept.json'));
  return DateTime.tryParse('${about['keptAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0);
}

/// Kept memories in [root] whose book is in the library ([ids]) again,
/// moved back into the book's folder when it has no memory of its own (as
/// LibraryStore does when a book is added again); how many.
Future<int> _keptBack(Directory root, Iterable<Object?> ids) async {
  final kept = await _keptIn(root.path);
  var back = 0;
  for (final id in ids) {
    final d = kept[id];
    if (d == null) continue;
    final dst = File('${root.path}/books/$id/memory.db');
    if (await dst.exists()) continue;
    await dst.parent.create(recursive: true);
    await File('${d.path}/memory.db').rename(dst.path);
    await d.delete(recursive: true);
    back++;
  }
  return back;
}

/// Swap the library for [staged]. The current one is moved aside first and
/// put back if anything fails. What the backup never had is carried over
/// (see [_carryOver]).
Future<ReplaceReport> replaceLibrary(Directory root, StagedBackup staged) async {
  // A swap left unsettled is settled first: its hidden folder may hold the
  // library as it was, which deleting it here lost for good.
  await settleSwap(root);
  final aside = _aside(root);
  if (await aside.exists()) {
    // What an older app's interrupted replace left, that nothing could be
    // put back from: kept under another name, never deleted.
    await aside.rename('${aside.path}-${DateTime.now().millisecondsSinceEpoch}');
  }
  await aside.create();
  final journal = _journal(root);
  final movedAside = <String>[];
  final movedIn = <String>[];
  Future<void> note({bool done = false}) =>
      writeSafely(journal, jsonEncode({'aside': movedAside, 'in': movedIn, 'done': done}));
  try {
    await note();
    await for (final e in root.list()) {
      final name = _name(e);
      if (name.startsWith('.') || keptOnPhone.contains(name)) continue;
      // Noted before the move: stopped between the two, the name is put back
      // from wherever it is.
      movedAside.add(name);
      await note();
      await e.rename('${aside.path}/$name');
    }
    await for (final e in staged.dir.list()) {
      final name = _name(e);
      // Never a dot-file (checkStaged refuses a backup with one).
      if (!_swapped(name)) continue;
      movedIn.add(name);
      await note();
      await e.rename('${root.path}/$name');
    }
    await note(done: true);
  } on Object {
    // Undone now if it can be; if not, the journal stays and the next start
    // puts the library back.
    try {
      await settleSwap(root);
    } on Object {
      throw const RestoreUnsettled();
    }
    rethrow;
  }
  ReplaceReport kept = (secretBooks: 0, chapters: 0, memories: 0);
  try {
    kept = await _carryOver(root, aside);
  } on Object catch (e, st) {
    // The backup is in place all the same; what was not carried over is in
    // the library kept aside (see _dropReplaced).
    ErrorLog.instance.record('A restore could not carry everything over from the replaced library ($e)', st);
  }
  await staged.discard();
  await settleSwap(root);
  return kept;
}

/// Book folder [from] (a backup's) into [to], the same book's folder here:
/// what [to] lacks comes in, downloaded chapters as [_moveChapters] takes
/// them, and its place (cursor.json) when saved later than the one here.
/// The place here when it is the later one, for the list to show; null
/// when the backup's is.
Future<Map<String, Object?>?> _mergeFolder(Directory from, Directory to) async {
  await for (final e in from.list()) {
    final name = _name(e);
    if (name == 'ch' || name == 'cursor.json') continue;
    if (!await _exists('${to.path}/$name')) await e.rename('${to.path}/$name');
  }
  await _moveChapters(from.path, to.path);
  final theirs = File('${from.path}/cursor.json');
  final mine = File('${to.path}/cursor.json');
  final here = await mine.exists() ? await _readMap(mine) : const <String, Object?>{};
  if (!await theirs.exists()) return here['cursor'] is Map ? here : null;
  DateTime? at(Map<String, Object?> j) => DateTime.tryParse('${j['at']}');
  final t = at(await _readMap(theirs));
  final m = at(here);
  if (here['cursor'] is! Map || (t != null && (m == null || t.isAfter(m)))) {
    await theirs.copy(mine.path);
    return null;
  }
  return here;
}

/// What the library being replaced ([aside]) has and the backup now in
/// [root] never had, carried over:
/// - its secret shelves' books, when the backup has no secret shelf (an
///   automatic backup leaves it out unless the reader let it in), with their
///   quotes, bookmarks and journal entries; a book the backup has stays the
///   backup's;
/// - downloaded web-novel chapters the backup lacks (an automatic backup has
///   none unless asked), for the novels in both.
/// Run once the swap is done: anything it leaves behind is in the library
/// kept aside.
Future<ReplaceReport> _carryOver(Directory root, Directory aside) async {
  final index = File('${root.path}/library.json');
  final mine = await _readIndex(File('${aside.path}/library.json'));
  final theirs = await _readIndex(index);
  final cats = [for (final c in theirs['categories'] as List) Map<String, Object?>.from(c as Map)];
  final books = [for (final b in theirs['books'] as List) Map<String, Object?>.from(b as Map)];
  final ids = {for (final b in books) b['id']};

  // Chapters first: of the books the backup has.
  var chapters = 0;
  for (final id in ids) {
    if (id is! String || !LibraryStore.isBookId(id)) continue;
    chapters += await _moveChapters('${aside.path}/books/$id', '${root.path}/books/$id');
  }

  final carried = <String>{};
  final secretCats = [
    for (final c in mine['categories'] as List)
      if (c is Map && c['secret'] == true) Map<String, Object?>.from(c),
  ];
  if (secretCats.isNotEmpty && !cats.any((c) => c['secret'] == true)) {
    final catFor = <String, String>{};
    for (final c in secretCats) {
      final id = c['id'] as String? ?? '';
      var free = id;
      for (var n = 2; cats.any((x) => x['id'] == free); n++) {
        free = '$id-$n';
      }
      cats.add({...c, 'id': free});
      catFor[id] = free;
    }
    await Directory('${root.path}/books').create(recursive: true);
    for (final b in mine['books'] as List) {
      if (b is! Map) continue;
      final id = '${b['id']}';
      final cat = catFor[b['category']];
      if (cat == null || ids.contains(id) || !LibraryStore.isBookId(id)) continue;
      final from = Directory('${aside.path}/books/$id');
      final dest = '${root.path}/books/$id';
      if (await _exists(dest)) continue;
      if (await from.exists()) await from.rename(dest);
      books.add({...Map<String, Object?>.from(b), 'category': cat});
      carried.add(id);
    }
  }
  if (carried.isNotEmpty) {
    await _writeIndex(index, {...theirs, 'categories': cats, 'books': books});
    await _carryLines(root, aside, 'marks.json', carried);
    await _carryLines(root, aside, 'journal.json', carried);
  }

  // The AI memories kept from removed books, when the backup has none (one
  // made before they were kept, or by an older app): each cost a build's
  // worth of calls, and the backup has nothing in their place.
  var memories = 0;
  final mineKept = await _keptIn(aside.path);
  if (mineKept.isNotEmpty && (await _keptIn(root.path)).isEmpty) {
    final into = Directory('${root.path}/$keptMemoriesDir');
    if (await into.exists()) await into.delete(recursive: true);
    await into.create(recursive: true);
    for (final e in mineKept.entries) {
      await e.value.rename('${into.path}/${e.key}');
      memories++;
    }
  }
  // A kept memory whose book the library has (again): back in its folder.
  await _keptBack(root, {...ids, ...carried});
  return (secretBooks: carried.length, chapters: chapters, memories: memories);
}

/// The entries of list file [name] (quotes and bookmarks, the journal) of
/// [books] in [aside], added to [root]'s where it has none with their id;
/// newest first, as both are kept.
Future<void> _carryLines(Directory root, Directory aside, String name, Set<String> books) async {
  final theirs = [
    for (final m in await _readList(File('${aside.path}/$name')))
      if (m is Map && books.contains(m['book'])) m,
  ];
  if (theirs.isEmpty) return;
  final file = File('${root.path}/$name');
  final mine = await _readList(file);
  final have = {for (final m in mine) if (m is Map) m['id']};
  final added = [for (final m in theirs) if (!have.contains(m['id'])) m];
  if (added.isEmpty) return;
  DateTime created(Object? m) =>
      (m is Map ? DateTime.tryParse('${m['created']}') : null) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final all = [...mine, ...added]..sort((a, b) => created(b).compareTo(created(a)));
  await writeSafely(file, jsonEncode(all));
}

/// Downloaded chapters of a web novel in book folder [from] that [to] lacks,
/// moved in; how many. Where both have their chapter list (novel.json), only
/// a chapter both lists have at that number: a site that added or took one
/// out since filed the texts under other numbers, and one moved by number
/// alone showed another chapter's text.
Future<int> _moveChapters(String from, String to) async {
  final ch = Directory('$from/ch');
  if (!await ch.exists()) return 0;
  final a = await _chapterPaths(from);
  final b = await _chapterPaths(to);
  final into = Directory('$to/ch');
  var moved = 0;
  await for (final f in ch.list()) {
    if (f is! File) continue;
    final name = _name(f);
    if (a != null && b != null) {
      final n = name.endsWith('.json') ? int.tryParse(name.substring(0, name.length - 5)) : null;
      if (n == null || n < 0 || n >= a.length || n >= b.length || a[n] != b[n]) continue;
    }
    final dest = File('${into.path}/$name');
    if (await dest.exists()) continue;
    await into.create(recursive: true);
    await f.rename(dest.path);
    moved++;
  }
  return moved;
}

/// The chapter paths in book folder [dir]'s novel.json, in order; null
/// when it has none (not a web novel), or it cannot be read.
Future<List<String>?> _chapterPaths(String dir) async {
  final f = File('$dir/novel.json');
  try {
    if (!await f.exists()) return null;
    final list = (jsonDecode(await f.readAsString()) as Map)['chapters'];
    if (list is! List) return null;
    return [for (final c in list) c is Map ? '${c['path']}' : ''];
  } on Object {
    return null;
  }
}

/// What a replace with [staged] does to the library in [root], for its
/// confirm: how many books here the backup lacks (they go), how many on a
/// secret shelf are kept (the backup has no secret shelf: see [_carryOver]),
/// and whether the backup has no downloaded chapters, so that those here
/// are kept for the novels in both.
Future<({int gone, int secretKept, bool chaptersKept, int memoriesKept})> replacePreview(
    Directory root, StagedBackup staged) async {
  final mine = await _readIndex(File('${root.path}/library.json'));
  final theirs = await _readIndex(File('${staged.dir.path}/library.json'));
  final ids = {for (final b in theirs['books'] as List) if (b is Map) b['id']};
  final keepSecret = !(theirs['categories'] as List).any((c) => c is Map && c['secret'] == true);
  final secret = {
    for (final c in mine['categories'] as List)
      if (c is Map && c['secret'] == true) c['id'],
  };
  var gone = 0, kept = 0;
  for (final b in mine['books'] as List) {
    if (b is! Map || ids.contains(b['id'])) continue;
    if (keepSecret && secret.contains(b['category'])) {
      kept++;
    } else {
      gone++;
    }
  }
  final memories = (await _keptIn(staged.dir.path)).isEmpty ? (await _keptIn(root.path)).length : 0;
  return (gone: gone, secretKept: kept, chaptersKept: !staged.info.chapters, memoriesKept: memories);
}

String _memories(int n) => '$n AI ${n == 1 ? 'memory' : 'memories'}';

/// The confirm's words for a replace (see [replacePreview]).
String replaceWarning({
  required String made,
  required int gone,
  required int secretKept,
  required bool chaptersKept,
  int memoriesKept = 0,
}) {
  String books(int n) => '$n ${n == 1 ? 'book' : 'books'}';
  return [
    "Your books, places, categories, quotes, journal and settings become the backup's from $made.",
    if (gone > 0) "${books(gone)} on this phone that the backup doesn't have will be removed.",
    if (secretKept > 0) 'The backup has no secret shelf, so yours (${books(secretKept)}) is kept.',
    if (chaptersKept) 'The backup has no downloaded chapters, so those on this phone are kept for the web novels it has.',
    if (memoriesKept > 0)
      'The backup has no memories from removed books, so yours (${_memories(memoriesKept)}) '
          '${memoriesKept == 1 ? 'stays' : 'stay'} for when those books come back.',
    'Natural voices and OCR languages stay on this phone.',
  ].join('\n\n');
}

/// The summary after a replace, as the app starts again.
String replaceSummary(String made, ReplaceReport r) {
  final kept = [
    if (r.secretBooks > 0) 'your secret shelf (${r.secretBooks} ${r.secretBooks == 1 ? 'book' : 'books'})',
    if (r.chapters > 0) '${r.chapters} downloaded ${r.chapters == 1 ? 'chapter' : 'chapters'}',
    if (r.memories > 0) '${_memories(r.memories)} from removed books',
  ];
  final list = kept.length < 2 ? kept.join() : '${kept.sublist(0, kept.length - 1).join(', ')} and ${kept.last}';
  return 'Your library is the backup made $made.${kept.isEmpty ? '' : ' Kept from before: $list.'}';
}

/// What [addToLibrary] did: books added and brought up to date, sources,
/// quotes and bookmarks, days of stats, reading rules, AI memories (a
/// book's, or one kept from a removed book), and whether the backup's
/// settings were taken.
typedef AddReport = ({
  int added,
  int updated,
  int sources,
  int marks,
  int days,
  int rules,
  int memories,
  bool settings,
});

/// Add [staged] to the library: books not here are added; for a book in
/// both, the further place is kept and missing downloaded chapters are
/// added. Sources and source lists, quotes and bookmarks, days of stats and
/// reading rules not here are added (they were left behind before, so a
/// move to a new phone lost them). Settings stay, unless [settings].
Future<AddReport> addToLibrary(Directory root, StagedBackup staged, {bool settings = false}) async {
  final from = staged.dir.path;
  final current = await _readIndex(File('${root.path}/library.json'));
  final incoming = await _readIndex(File('$from/library.json'));

  // Categories: the same id, or the same name, is the same category, but
  // only one of the same kind: a secret shelf merged into an open one (the
  // default "Later") put its books on show.
  final cats = [for (final c in current['categories'] as List) Map<String, Object?>.from(c as Map)];
  final catFor = <String, String>{};
  for (final c in incoming['categories'] as List) {
    final m = Map<String, Object?>.from(c as Map);
    final id = m['id'] as String? ?? '';
    final secret = m['secret'] == true;
    final kind = cats.where((x) => (x['secret'] == true) == secret);
    final same = kind.where((x) => x['id'] == id).firstOrNull ??
        kind.where((x) => (x['name'] as String?)?.toLowerCase() == (m['name'] as String?)?.toLowerCase()).firstOrNull;
    if (same != null) {
      catFor[id] = same['id'] as String;
    } else {
      // Its id may be taken by a shelf of the other kind.
      var free = id;
      for (var n = 2; cats.any((x) => x['id'] == free); n++) {
        free = '$id-$n';
      }
      cats.add({...m, 'id': free});
      catFor[id] = free;
    }
  }

  final books = [for (final b in current['books'] as List) Map<String, Object?>.from(b as Map)];
  var added = 0;
  var updated = 0;
  var memories = 0;
  final addedIds = <String>[];
  await Directory('${root.path}/books').create(recursive: true);
  for (final b in incoming['books'] as List) {
    final m = Map<String, Object?>.from(b as Map);
    final id = m['id'] as String? ?? '';
    if (id.isEmpty) continue;
    final cat = m['category'] as String?;
    if (cat != null) m['category'] = catFor[cat] ?? cat;
    final dir = Directory('$from/books/$id');
    final here = books.indexWhere((x) => x['id'] == id);
    if (here < 0) {
      final dest = Directory('${root.path}/books/$id');
      if (await dest.exists() && await dir.exists()) {
        // Its folder is here, though the list has no entry for it (a list
        // that could not be read and was set aside, an import or a move cut
        // short): its downloaded chapters and a later place are this phone's.
        // Kept; what it lacks comes in.
        final place = await _mergeFolder(dir, dest);
        if (place != null) {
          m['cursor'] = place['cursor'];
          if (place['progress'] is num) m['progress'] = place['progress'];
          if (place['where'] is String) m['where'] = place['where'];
          if (place['at'] is String) m['openedAt'] = place['at'];
        }
      } else if (await dir.exists()) {
        await dir.rename(dest.path);
      }
      books.add(m);
      addedIds.add(id);
      added++;
      continue;
    }
    var changed = false;
    final mine = (books[here]['progress'] as num?)?.toDouble() ?? 0;
    final theirs = (m['progress'] as num?)?.toDouble() ?? 0;
    if (theirs > mine) {
      final cursor = File('${dir.path}/cursor.json');
      if (await cursor.exists()) {
        await Directory('${root.path}/books/$id').create(recursive: true);
        await cursor.copy('${root.path}/books/$id/cursor.json');
      }
      books[here] = {
        ...books[here],
        for (final k in const ['cursor', 'progress', 'where', 'openedAt'])
          if (m.containsKey(k)) k: m[k],
      };
      // A TXT book cut into other chapters there: the place is in those, so
      // the rule and the text cut by it come with it.
      if (jsonEncode(books[here]['chapters']) != jsonEncode(m['chapters'])) {
        final parsed = File('${dir.path}/parsed.json');
        if (await parsed.exists()) {
          await Directory('${root.path}/books/$id').create(recursive: true);
          await parsed.copy('${root.path}/books/$id/parsed.json');
        }
        final kept = {...books[here]}..remove('chapters');
        books[here] = {...kept, if (m['chapters'] != null) 'chapters': m['chapters']};
      }
      changed = true;
    }
    // How the reader organised it: see _organised.
    final organised = _organised(books[here], m);
    if (organised != null) {
      books[here] = organised;
      changed = true;
    }
    if (await _moveChapters(dir.path, '${root.path}/books/$id') > 0) changed = true;
    // Its AI memory, built on the other phone, when this one has none: a
    // memory here is never replaced.
    final memory = File('${dir.path}/memory.db');
    final memoryHere = File('${root.path}/books/$id/memory.db');
    if (LibraryStore.isBookId(id) && await memory.exists() && !await memoryHere.exists()) {
      await memoryHere.parent.create(recursive: true);
      await memory.rename(memoryHere.path);
      memories++;
    }
    if (changed) updated++;
  }
  memories += await _addKeptMemories(root, from, {for (final b in books) b['id']});
  // This phone's memories kept from removed books, for the books the backup
  // brought back.
  await _keptBack(root, addedIds);

  await _writeIndex(File('${root.path}/library.json'), {...current, 'categories': cats, 'books': books});
  final sources = await _addSources(Directory('${root.path}/sources'), Directory('$from/sources'));
  final marks = await _addMarks(root, from);
  final days = await _addStats(root, from);
  final rules = await _addRules(root, from);
  final took = settings && await _takeSettings(root, from);
  await staged.discard();
  return (
    added: added,
    updated: updated,
    sources: sources,
    marks: marks,
    days: days,
    rules: rules,
    memories: memories,
    settings: took,
  );
}

/// The backup's memories kept from removed books ([from]'s kept-memories)
/// added to [root]: into the book's folder when the library has the book
/// ([ids]) and it has no memory of its own; otherwise kept here, where
/// none is kept for that book or the backup's was kept later. How many.
Future<int> _addKeptMemories(Directory root, String from, Set<Object?> ids) async {
  final theirs = await _keptIn(from);
  if (theirs.isEmpty) return 0;
  final mine = await _keptIn(root.path);
  var n = 0;
  for (final e in theirs.entries) {
    final id = e.key;
    if (ids.contains(id)) {
      final dst = File('${root.path}/books/$id/memory.db');
      if (await dst.exists()) continue;
      await dst.parent.create(recursive: true);
      await File('${e.value.path}/memory.db').rename(dst.path);
      n++;
      continue;
    }
    final here = mine[id];
    if (here != null) {
      if (!(await _keptAt(e.value)).isAfter(await _keptAt(here))) continue;
      await here.delete(recursive: true);
    }
    await Directory('${root.path}/$keptMemoriesDir').create(recursive: true);
    await e.value.rename('${root.path}/$keptMemoriesDir/$id');
    n++;
  }
  return n;
}

/// A book in both libraries, [mine] as it is here and [theirs] in the
/// backup, with what the reader gave it on either phone; null when that
/// changes nothing. Tags: both phones' (one tag once, as spelled here). A
/// series: this phone's when it has one or was told it has none, else the
/// backup's. A print of its text (made here or there, the same): whichever
/// has one.
Map<String, Object?>? _organised(Map<String, Object?> mine, Map<String, Object?> theirs) {
  final out = {...mine};
  final mineTags = [for (final t in mine['tags'] is List ? mine['tags'] as List : const []) if (t is String) t];
  final tags = distinctTags([
    ...mineTags,
    for (final t in theirs['tags'] is List ? theirs['tags'] as List : const []) if (t is String) t,
  ]);
  if (tags.length != mineTags.length) out['tags'] = tags;
  if (!mine.containsKey('series') && theirs['series'] is String) {
    out['series'] = theirs['series'];
    if (theirs['seriesIndex'] is num) out['seriesIndex'] = theirs['seriesIndex'];
  }
  if (mine['print'] == null && theirs['print'] is String) out['print'] = theirs['print'];
  return out.length == mine.length && tags.length == mineTags.length ? null : out;
}

/// Quotes and bookmarks from [from] that are not here (by id), the whole
/// list newest first, as Saved keeps it. Only those that read as quotes:
/// one that did not made the whole list unreadable here.
Future<int> _addMarks(Directory root, String from) async {
  final theirs = await _readList(File('$from/marks.json'));
  if (theirs.isEmpty) return 0;
  final file = File('${root.path}/marks.json');
  final mine = await _readList(file);
  final ids = {for (final m in mine) if (m is Map) m['id']};
  final added = [for (final m in theirs) if (Mark.fromJson(m) case final x? when !ids.contains(x.id)) m];
  if (added.isEmpty) return 0;
  // By the moment each was saved: a time from before they carried a Z
  // (this phone's own clock's) does not sort as text with one that does.
  DateTime created(Object? m) =>
      (m is Map ? DateTime.tryParse('${m['created']}') : null) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final all = [...mine, ...added]..sort((a, b) => created(b).compareTo(created(a)));
  await writeSafely(file, jsonEncode(all));
  return added.length;
}

/// Days of listening and reading from [from]. A day only there is added; a
/// day on both keeps the larger of each figure, so a backup added twice (or
/// the same phone's) never counts anything twice.
Future<int> _addStats(Directory root, String from) async {
  final theirs = await _readMap(File('$from/stats.json'));
  final theirDays = theirs['days'];
  if (theirDays is! Map || theirDays.isEmpty) return 0;
  final file = File('${root.path}/stats.json');
  final mine = await _readMap(file);
  final days = Map<String, Object?>.from(mine['days'] as Map? ?? const {});
  var changed = 0;
  for (final e in theirDays.entries) {
    if (e.value is! Map) continue;
    final t = DayStats.fromJson(Map<String, Object?>.from(e.value as Map));
    final here = days[e.key];
    if (here is! Map) {
      days[e.key as String] = t.toJson();
      changed++;
      continue;
    }
    final m = DayStats.fromJson(Map<String, Object?>.from(here));
    final merged = DayStats(
      listenMs: math.max(m.listenMs, t.listenMs),
      readMs: math.max(m.readMs, t.readMs),
      words: math.max(m.words, t.words),
      chapters: math.max(m.chapters, t.chapters),
      books: {
        for (final id in {...m.books.keys, ...t.books.keys}) id: math.max(m.books[id] ?? 0, t.books[id] ?? 0),
      },
    );
    if (jsonEncode(merged.toJson()) != jsonEncode(m.toJson())) {
      days[e.key as String] = merged.toJson();
      changed++;
    }
  }
  if (changed == 0) return 0;
  final goal = mine['goalMinutes'] ?? theirs['goalMinutes'];
  await writeSafely(file, jsonEncode({...mine, if (goal != null) 'goalMinutes': goal, 'days': days}));
  return changed;
}

/// Pronunciation fixes and skipped lines from [from] that are not here. A
/// fix here for the same word (and book) wins.
Future<int> _addRules(Directory root, String from) async {
  final theirs = await _readMap(File('$from/rules.json'));
  final theirSay = theirs['say'] is List ? theirs['say'] as List : const [];
  final theirSkip = theirs['skip'] is List ? theirs['skip'] as List : const [];
  if (theirSay.isEmpty && theirSkip.isEmpty) return 0;
  final file = File('${root.path}/rules.json');
  final mine = await _readMap(file);
  final say = [...(mine['say'] is List ? mine['say'] as List : const [])];
  final skip = [...(mine['skip'] is List ? mine['skip'] as List : const [])];
  String sayKey(Object? r) => r is Map ? '${'${r['from'] ?? ''}'.trim().toLowerCase()}|${r['book'] ?? ''}' : '';
  String skipKey(Object? r) => r is Map ? '${r['text'] ?? ''}|${r['plugin'] ?? ''}' : '';
  final haveSay = {for (final r in say) sayKey(r)};
  final haveSkip = {for (final r in skip) skipKey(r)};
  var added = 0;
  for (final r in theirSay) {
    if (r is Map && haveSay.add(sayKey(r))) {
      say.add(r);
      added++;
    }
  }
  for (final r in theirSkip) {
    if (r is Map && haveSkip.add(skipKey(r))) {
      skip.add(r);
      added++;
    }
  }
  if (added > 0) await writeSafely(file, jsonEncode({...mine, 'say': say, 'skip': skip}));
  return added;
}

/// The backup's settings (voice, speed, theme, page) in place of these.
Future<bool> _takeSettings(Directory root, String from) async {
  final theirs = File('$from/prefs.json');
  if (!await theirs.exists()) return false;
  await writeSafely(File('${root.path}/prefs.json'), await theirs.readAsString());
  return true;
}

/// The summary of a restore, for after the app has started again (it starts
/// again so every store reads the restored files). A dot-file: never backed
/// up, and left where it is by a replace.
File _reportFile(Directory root) => File('${root.path}/.restore-report.txt');

Future<void> saveRestoreReport(Directory root, String text) => _reportFile(root).writeAsString(text);

/// The last restore's summary, once; null when there is none.
Future<String?> takeRestoreReport(Directory root) async {
  final f = _reportFile(root);
  try {
    if (!await f.exists()) return null;
    final text = (await f.readAsString()).trim();
    await f.delete();
    return text.isEmpty ? null : text;
  } on Object {
    return null;
  }
}

/// What [addToLibrary] did, as a sentence.
String addSummary(AddReport r) {
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  final parts = [
    if (r.added > 0) n(r.added, 'book', 'books'),
    if (r.marks > 0) n(r.marks, 'quote or bookmark', 'quotes and bookmarks'),
    if (r.rules > 0) n(r.rules, 'reading rule', 'reading rules'),
    if (r.days > 0) n(r.days, 'day of stats', 'days of stats'),
    if (r.memories > 0) n(r.memories, 'AI memory', 'AI memories'),
    if (r.sources > 0) n(r.sources, 'source', 'sources'),
  ];
  final list = parts.length < 2
      ? parts.join()
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  final head = parts.isEmpty ? 'Nothing new to add from the backup.' : 'Added $list from the backup.';
  final updated = r.updated > 0 ? ' ${n(r.updated, 'book', 'books')} brought up to date.' : '';
  final settings = r.settings ? " The backup's settings are in use." : '';
  return '$head$updated$settings';
}

/// Installed sources and source lists from [from] that [to] lacks.
Future<int> _addSources(Directory to, Directory from) async {
  if (!await from.exists()) return 0;
  await Directory('${to.path}/plugins').create(recursive: true);

  final reposFile = File('${to.path}/repos.json');
  final theirRepos = await _readList(File('${from.path}/repos.json'));
  if (theirRepos.isNotEmpty) {
    final mine = await _readList(reposFile);
    final union = [...mine, for (final r in theirRepos) if (!mine.contains(r)) r];
    if (union.length != mine.length || !await reposFile.exists()) {
      await reposFile.writeAsString(jsonEncode(union));
    }
  }

  final installedFile = File('${to.path}/installed.json');
  final mine = await _readList(installedFile);
  final ids = {for (final p in mine) if (p is Map) p['id']};
  var added = 0;
  for (final p in await _readList(File('${from.path}/installed.json'))) {
    if (p is! Map || ids.contains(p['id'])) continue;
    mine.add(p);
    added++;
  }
  if (added > 0) await installedFile.writeAsString(jsonEncode(mine));

  // Plugin code and each plugin's saved settings, where missing.
  for (final sub in ['plugins', '']) {
    final dir = Directory(sub.isEmpty ? from.path : '${from.path}/$sub');
    if (!await dir.exists()) continue;
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = _name(f);
      if (sub.isEmpty && !name.startsWith('storage-')) continue;
      final dest = File(sub.isEmpty ? '${to.path}/$name' : '${to.path}/$sub/$name');
      if (!await dest.exists()) await f.rename(dest.path);
    }
  }
  return added;
}

Future<Map<String, Object?>> _readIndex(File f) async {
  Map<String, Object?> raw = {};
  if (await f.exists()) {
    try {
      raw = Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map);
    } on FormatException {
      raw = {};
    }
  }
  return {
    ...raw,
    'categories': raw['categories'] as List? ?? const [],
    'books': raw['books'] as List? ?? const [],
  };
}

Future<void> _writeIndex(File f, Map<String, Object?> index) async {
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(index));
  await tmp.rename(f.path);
}

Future<Map<String, Object?>> _readMap(File f) async {
  try {
    if (await f.exists()) return Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map);
  } on Object {
    // A broken file counts as empty.
  }
  return {};
}

Future<List<Object?>> _readList(File f) async {
  try {
    if (await f.exists()) return List<Object?>.from(jsonDecode(await f.readAsString()) as List);
  } on Object {
    // A broken list counts as empty.
  }
  return [];
}

String _name(FileSystemEntity e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

FileSystemEntity _entity(String path) =>
    FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);
