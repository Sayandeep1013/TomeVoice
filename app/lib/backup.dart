import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'library_store.dart';
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
Future<void> clearStaleRestore(Directory root) async {
  try {
    await settleSwap(root);
    final dir = stagingDir(root);
    if (await dir.exists()) await dir.delete(recursive: true);
  } on Object {
    // Tried again next launch.
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
    if (await aside.exists()) await aside.delete(recursive: true);
  } else {
    for (final name in (j['in'] as List? ?? const []).cast<String>()) {
      final path = '${root.path}/$name';
      if (await _exists(path)) await _entity(path).delete(recursive: true);
    }
    for (final name in (j['aside'] as List? ?? const []).cast<String>()) {
      final from = '${aside.path}/$name';
      if (await _exists(from)) await _entity(from).rename('${root.path}/$name');
    }
    if (await aside.exists()) await aside.delete(recursive: true);
  }
  await journal.delete();
}

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
/// them), the OCR language data and any scan being read (ocr.dart), and the
/// update check's state, which holds whether to check at all.
const keptOnPhone = {'voices', 'ocr', 'app_update.json'};

/// Swap the library for [staged]. The current one is moved aside first and
/// put back if anything fails.
Future<void> replaceLibrary(Directory root, StagedBackup staged) async {
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
      if (keptOnPhone.contains(name)) continue;
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
  await staged.discard();
  await settleSwap(root);
}

/// What [addToLibrary] did: books added and brought up to date, sources,
/// quotes and bookmarks, days of stats, reading rules, and whether the
/// backup's settings were taken.
typedef AddReport = ({int added, int updated, int sources, int marks, int days, int rules, bool settings});

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
      if (await dest.exists()) await dest.delete(recursive: true);
      if (await dir.exists()) await dir.rename(dest.path);
      books.add(m);
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
      changed = true;
    }
    final ch = Directory('${dir.path}/ch');
    if (await ch.exists()) {
      final into = Directory('${root.path}/books/$id/ch');
      await into.create(recursive: true);
      await for (final f in ch.list()) {
        final dest = '${into.path}/${_name(f)}';
        if (f is File && !await File(dest).exists()) {
          await f.rename(dest);
          changed = true;
        }
      }
    }
    if (changed) updated++;
  }

  await _writeIndex(File('${root.path}/library.json'), {...current, 'categories': cats, 'books': books});
  final sources = await _addSources(Directory('${root.path}/sources'), Directory('$from/sources'));
  final marks = await _addMarks(root, from);
  final days = await _addStats(root, from);
  final rules = await _addRules(root, from);
  final took = settings && await _takeSettings(root, from);
  await staged.discard();
  return (added: added, updated: updated, sources: sources, marks: marks, days: days, rules: rules, settings: took);
}

/// Quotes and bookmarks from [from] that are not here (by id), the whole
/// list newest first, as Saved keeps it.
Future<int> _addMarks(Directory root, String from) async {
  final theirs = await _readList(File('$from/marks.json'));
  if (theirs.isEmpty) return 0;
  final file = File('${root.path}/marks.json');
  final mine = await _readList(file);
  final ids = {for (final m in mine) if (m is Map) m['id']};
  final added = [for (final m in theirs) if (m is Map && m['id'] is String && !ids.contains(m['id'])) m];
  if (added.isEmpty) return 0;
  String created(Object? m) => m is Map ? '${m['created'] ?? ''}' : '';
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
