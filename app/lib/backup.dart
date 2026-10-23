import 'dart:convert';
import 'dart:io';

import 'library_store.dart';
import 'speech_service.dart';

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

/// Remove a backup left unpacked by a restore that never finished.
Future<void> clearStaleRestore(Directory root) async {
  try {
    final dir = stagingDir(root);
    if (await dir.exists()) await dir.delete(recursive: true);
  } on Object {
    // Tried again next launch.
  }
}

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

/// Swap the library for [staged]. The current one is moved aside first and
/// put back if anything fails.
Future<void> replaceLibrary(Directory root, StagedBackup staged) async {
  final aside = Directory('${root.path}/.before-restore');
  if (await aside.exists()) await aside.delete(recursive: true);
  await aside.create();
  final movedAside = <String>[];
  final movedIn = <String>[];
  try {
    await for (final e in root.list()) {
      final name = _name(e);
      if (name.startsWith('.')) continue;
      await e.rename('${aside.path}/$name');
      movedAside.add(name);
    }
    await for (final e in staged.dir.list()) {
      final name = _name(e);
      await e.rename('${root.path}/$name');
      movedIn.add(name);
    }
  } on Object {
    for (final name in movedIn) {
      await _entity('${root.path}/$name').delete(recursive: true);
    }
    for (final name in movedAside) {
      await _entity('${aside.path}/$name').rename('${root.path}/$name');
    }
    rethrow;
  }
  await staged.discard();
  await aside.delete(recursive: true);
}

/// What [addToLibrary] did.
typedef AddReport = ({int added, int updated, int sources});

/// Add [staged] to the library: books not here are added; for a book in
/// both, the further place is kept and missing downloaded chapters are
/// added. Sources and source lists not here are added. Settings stay.
Future<AddReport> addToLibrary(Directory root, StagedBackup staged) async {
  final from = staged.dir.path;
  final current = await _readIndex(File('${root.path}/library.json'));
  final incoming = await _readIndex(File('$from/library.json'));

  // Categories: the same id, or the same name, is the same category.
  final cats = [for (final c in current['categories'] as List) Map<String, Object?>.from(c as Map)];
  final catFor = <String, String>{};
  for (final c in incoming['categories'] as List) {
    final m = Map<String, Object?>.from(c as Map);
    final id = m['id'] as String? ?? '';
    final same = cats.where((x) => x['id'] == id).firstOrNull ??
        cats.where((x) => (x['name'] as String?)?.toLowerCase() == (m['name'] as String?)?.toLowerCase()).firstOrNull;
    if (same != null) {
      catFor[id] = same['id'] as String;
    } else {
      cats.add(m);
      catFor[id] = id;
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
  await staged.discard();
  return (added: added, updated: updated, sources: sources);
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
