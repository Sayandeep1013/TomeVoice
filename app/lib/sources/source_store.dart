import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'models.dart';
import 'net.dart';
import 'sha256.dart';

/// Repositories and installed sources, kept under `<root>/sources/`: the
/// app's internal storage, which no other app can read or change (the
/// library's folder, external app storage, is open to other apps on
/// Android 8 to 10; see [open], which moves sources out of it).
///
/// A repository is a URL to a plugin index in LNReader's format: a JSON
/// list of `{id, name, site, lang, version, url, iconUrl}`. A new install
/// starts with LNReader's own list ([builtIn]), so there is something to
/// install at once; readers can remove it and add any others. Installing a
/// plugin downloads its code, so browsing and reading work from the copy on
/// the phone. Lists and code come over https only; each installed plugin
/// keeps the SHA-256 of its code, checked whenever it is loaded, and is
/// updated only from the list it was installed from.
class SourceStore {
  SourceStore(Directory root, {this.defaults = builtIn, @visibleForTesting this.allowInsecure = false})
      : dir = Directory('${root.path}/sources');

  /// LNReader's plugin list: some 300 sites in many languages, kept up to
  /// date by its community.
  static const builtIn = [
    'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json',
  ];

  final Directory dir;

  /// The lists a new install starts with. Once the reader adds or removes
  /// one, their own choice is kept instead.
  final List<String> defaults;

  /// Tests serve their lists from this machine, over http.
  final bool allowInsecure;

  /// Bumped when repositories or installed sources change.
  final changes = ValueNotifier<int>(0);

  /// Installed sources their list has a newer version of, by plugin id (see
  /// [updates]); what Browse and Sources show as waiting.
  final pending = ValueNotifier<Map<String, PluginInfo>>(const {});

  File get _reposFile => File('${dir.path}/repos.json');
  File get _installedFile => File('${dir.path}/installed.json');
  File get _restoredFile => File('${dir.path}/restored.json');
  File get _movedFlag => File('${dir.path}/moved.json');
  Directory get _pluginDir => Directory('${dir.path}/plugins');
  File _indexCache(String repo) => File('${dir.path}/index-${repo.hashCode.toUnsigned(32)}.json');

  /// The store at [root], with sources/ moved there first from [legacyRoot]
  /// (where builds before 1.3 kept it), once: every file is copied and read
  /// back to check it, and only then is the old copy deleted. If the move
  /// fails, the old place is used for now and the move tried next launch.
  /// A sources/ that turns up in [legacyRoot] after the move is one a
  /// restore brought back: see [_adoptRestored].
  static Future<SourceStore> open(Directory root, {Directory? legacyRoot, List<String> defaults = builtIn}) async {
    final store = SourceStore(root, defaults: defaults);
    final old = legacyRoot == null || legacyRoot.path == root.path ? null : Directory('${legacyRoot.path}/sources');
    if (old != null && await old.exists()) {
      if (await store._movedFlag.exists()) {
        await store._adoptRestored(old);
      } else if (!await store._moveFrom(old)) {
        final fallback = SourceStore(legacyRoot!, defaults: defaults);
        await fallback.ensure();
        await fallback.recordMissingHashes();
        return fallback;
      }
    }
    await store.ensure();
    if (old != null && !await store._movedFlag.exists()) {
      await store._movedFlag.writeAsString(jsonEncode({'at': DateTime.now().toIso8601String()}));
    }
    await store.recordMissingHashes();
    return store;
  }

  /// Copy [old] into this store's folder, each file checked, then delete it.
  Future<bool> _moveFrom(Directory old) async {
    final staging = Directory('${dir.path}.moving');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await for (final e in old.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = e.path.substring(old.path.length + 1);
        final dest = File('${staging.path}/$rel');
        await dest.parent.create(recursive: true);
        final bytes = await e.readAsBytes();
        await dest.writeAsBytes(bytes, flush: true);
        final back = await dest.readAsBytes();
        if (back.length != bytes.length || sha256Hex(back) != sha256Hex(bytes)) {
          throw FileSystemException('The copy differs', dest.path);
        }
      }
      // Nothing here is in use yet: the move has not been finished before.
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.parent.create(recursive: true);
      await staging.rename(dir.path);
      await _movedFlag.writeAsString(jsonEncode({'at': DateTime.now().toIso8601String(), 'from': old.path}));
    } on Object {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } on Object {
        // Left for the next try, which empties it first.
      }
      return false;
    }
    try {
      await old.delete(recursive: true);
    } on Object {
      // What is left is adopted (and deleted) next launch.
    }
    return true;
  }

  /// sources/ in the library's folder again after the move: a backup from
  /// before it, restored. Its lists and the sources' settings are taken. Its
  /// plugin code never is (anything could be in a backup file): the sources
  /// it had installed are installed again from their lists instead (see
  /// [reinstallRestored]).
  Future<void> _adoptRestored(Directory old) async {
    try {
      await ensure();
      final theirRepos = File('${old.path}/repos.json');
      if (await theirRepos.exists()) {
        final mine = await repos();
        final theirs = [for (final r in jsonDecode(await theirRepos.readAsString()) as List) '$r'];
        final merged = [...mine, for (final r in theirs) if (!mine.contains(r) && _isHttps(r)) r];
        if (merged.length != mine.length) await _reposFile.writeAsString(jsonEncode(merged));
      }
      await for (final e in old.list(followLinks: false)) {
        final name = e.uri.pathSegments.last;
        if (e is File && name.startsWith('storage-') && name.endsWith('.json')) {
          final dest = File('${dir.path}/$name');
          if (!await dest.exists()) await e.copy(dest.path);
        }
      }
      final theirInstalled = File('${old.path}/installed.json');
      if (await theirInstalled.exists()) {
        final have = {for (final p in await installed()) p.id};
        final waiting = {for (final p in await restored()) p.id: p};
        for (final o in jsonDecode(await theirInstalled.readAsString()) as List) {
          final p = o is Map ? PluginInfo.fromJson(Map<String, Object?>.from(o)) : null;
          if (p != null && !have.contains(p.id)) waiting[p.id] = p;
        }
        await _restoredFile.writeAsString(jsonEncode([for (final p in waiting.values) p.toJson()]));
      }
    } on Object {
      // What could be read was taken.
    }
    try {
      await old.delete(recursive: true);
    } on Object {
      // Tried again next launch.
    }
  }

  /// Sources a restored backup had installed, waiting to be installed again
  /// from their lists.
  Future<List<PluginInfo>> restored() async {
    try {
      if (await _restoredFile.exists()) {
        return [
          for (final o in jsonDecode(await _restoredFile.readAsString()) as List)
            if (o is Map)
              if (PluginInfo.fromJson(Map<String, Object?>.from(o)) case final p?) p,
        ];
      }
    } on Object {
      // None.
    }
    return const [];
  }

  /// Install again, from their lists, the sources a restored backup had.
  /// Returns how many were installed; those no list offers stay waiting.
  Future<int> reinstallRestored() async {
    final waiting = await restored();
    if (waiting.isEmpty) return 0;
    final listed = await _listed();
    var done = 0;
    final left = <PluginInfo>[];
    for (final p in waiting) {
      final from = listed[p.repo]?[p.id] ?? _newestOf(listed, p.id);
      if (from == null) {
        left.add(p);
        continue;
      }
      try {
        await install(from);
        done++;
      } on Object {
        left.add(p);
      }
    }
    if (left.isEmpty) {
      try {
        await _restoredFile.delete();
      } on FileSystemException {
        // Gone already.
      }
    } else {
      await _restoredFile.writeAsString(jsonEncode([for (final p in left) p.toJson()]));
    }
    return done;
  }

  Future<void> ensure() async {
    await _pluginDir.create(recursive: true);
  }

  bool _isHttps(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return false;
    return u.scheme == 'https' || (allowInsecure && u.scheme == 'http');
  }

  // ------------------------------------------------------------ repositories

  Future<List<String>> repos() async {
    await ensure();
    try {
      if (await _reposFile.exists()) {
        return [for (final r in jsonDecode(await _reposFile.readAsString()) as List) r.toString()];
      }
    } on Object {
      // A broken file: start again from the built-in list.
    }
    return defaults;
  }

  /// Lists added before only https was taken: not read until added again
  /// with https.
  Future<List<String>> insecureRepos() async => [for (final r in await repos()) if (!_isHttps(r)) r];

  /// Add [url] after checking it really is a plugin index. Returns how many
  /// sources it lists.
  Future<int> addRepo(String url) async {
    final clean = url.trim();
    final uri = Uri.tryParse(clean);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      throw const FormatException('That is not a web address.');
    }
    if (!_isHttps(clean)) {
      throw const FormatException('Only lists on https:// addresses can be added: code from them runs on the phone.');
    }
    final plugins = await _fetchIndex(clean);
    if (plugins.isEmpty) throw const FormatException('No sources were found at that address.');
    final list = await repos();
    if (!list.contains(clean)) {
      await _reposFile.writeAsString(jsonEncode([...list, clean]));
    }
    changes.value++;
    return plugins.length;
  }

  Future<void> removeRepo(String url) async {
    final list = await repos();
    await _reposFile.writeAsString(jsonEncode([for (final r in list) if (r != url) r]));
    try {
      await _indexCache(url).delete();
    } on FileSystemException {
      // Never fetched.
    }
    changes.value++;
  }

  Future<List<PluginInfo>> _fetchIndex(String repo) async {
    await ensure();
    if (!_isHttps(repo)) throw const FormatException('Only https source lists are read.');
    final text = await Net.instance.text(repo);
    final raw = jsonDecode(text);
    if (raw is! List) throw const FormatException('That address is not a source list.');
    final plugins = [
      for (final p in raw)
        // What a list says of a plugin's list or hash is not taken: the
        // list is the one it was read from, and the hash is the code's own.
        if (p is Map) PluginInfo.fromJson({...Map<String, Object?>.from(p)}..remove('sha256'))?.withRepo(repo),
    ].whereType<PluginInfo>().toList();
    await _indexCache(repo).writeAsString(jsonEncode([for (final p in plugins) p.toJson()]));
    return plugins;
  }

  /// Every list's sources, by list, then by plugin id. Uses the copy from the
  /// last refresh unless [refresh] is set or there is none.
  Future<Map<String, Map<String, PluginInfo>>> _listed({bool refresh = false}) async {
    final out = <String, Map<String, PluginInfo>>{};
    for (final repo in await repos()) {
      if (!_isHttps(repo)) continue;
      List<PluginInfo> list;
      final cache = _indexCache(repo);
      if (!refresh && await cache.exists()) {
        try {
          list = [
            for (final p in jsonDecode(await cache.readAsString()) as List)
              PluginInfo.fromJson(Map<String, Object?>.from(p as Map)),
          ].whereType<PluginInfo>().toList();
        } on Object {
          list = const [];
        }
      } else {
        try {
          list = await _fetchIndex(repo);
        } on Object {
          list = const [];
        }
      }
      out[repo] = {for (final p in list) p.id: p};
    }
    return out;
  }

  static PluginInfo? _newestOf(Map<String, Map<String, PluginInfo>> listed, String id) {
    PluginInfo? best;
    for (final list in listed.values) {
      final p = list[id];
      if (p != null && (best == null || best.olderThan(p))) best = p;
    }
    return best;
  }

  /// Every source the repositories offer, newest version of each. Uses the
  /// copy from the last refresh unless [refresh] is set or there is none.
  Future<List<PluginInfo>> available({bool refresh = false}) async {
    final listed = await _listed(refresh: refresh);
    final byId = <String, PluginInfo>{};
    for (final list in listed.values) {
      for (final p in list.values) {
        final have = byId[p.id];
        if (have == null || have.olderThan(p)) byId[p.id] = p;
      }
    }
    final out = byId.values.toList()
      ..sort((a, b) {
        final l = a.lang.compareTo(b.lang);
        return l != 0 ? l : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return out;
  }

  // ------------------------------------------------------------- installed

  List<PluginInfo>? _installed;
  DateTime? _installedStamp;

  Future<List<PluginInfo>> installed() async {
    await ensure();
    try {
      if (await _installedFile.exists()) {
        // Read again only when another engine (the check made away from the
        // app) may have written it.
        final stamp = await _installedFile.lastModified();
        final cached = _installed;
        if (cached != null && stamp == _installedStamp) return cached;
        final list = [
          for (final p in jsonDecode(await _installedFile.readAsString()) as List)
            PluginInfo.fromJson(Map<String, Object?>.from(p as Map)),
        ].whereType<PluginInfo>().toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _installed = List.unmodifiable(list);
        _installedStamp = stamp;
        return _installed!;
      }
    } on Object {
      // Fall through to none.
    }
    return const [];
  }

  Future<PluginInfo?> installedById(String id) async =>
      (await installed()).where((p) => p.id == id).firstOrNull;

  Future<void> _saveInstalled(List<PluginInfo> list) async {
    final tmp = File('${_installedFile.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final p in list) p.toJson()]), flush: true);
    await tmp.rename(_installedFile.path);
    _installed = null;
    changes.value++;
  }

  /// Download [plugin]'s code over https, as it would be installed, without
  /// installing it: its bytes and their SHA-256.
  Future<(Uint8List, String)> download(PluginInfo plugin) async {
    if (!_isHttps(plugin.url)) {
      throw const FormatException('Sources are only installed from https:// addresses.');
    }
    final r = await Net.instance.request(plugin.url, maxBytes: 4 << 20);
    if (!r.ok) throw HttpException('HTTP ${r.status}', uri: Uri.tryParse(plugin.url));
    if (!r.text().contains('exports')) {
      throw const FormatException('That source could not be downloaded properly.');
    }
    return (r.bytes, sha256Hex(r.bytes));
  }

  /// Download [plugin]'s code and add it (or replace an older version).
  /// Returns it as installed, with its code's hash.
  Future<PluginInfo> install(PluginInfo plugin) async {
    await ensure();
    final (code, hash) = await download(plugin);
    return installCode(plugin, code, hash);
  }

  /// Put [code] (already downloaded and checked, its hash [hash]) in place
  /// as [plugin].
  Future<PluginInfo> installCode(PluginInfo plugin, Uint8List code, String hash) async {
    await ensure();
    final f = File(codePath(plugin.id));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(code, flush: true);
    await tmp.rename(f.path);
    final record = plugin.withHash(hash);
    final list = await installed();
    await _saveInstalled([for (final p in list) if (p.id != plugin.id) p, record]);
    if (pending.value.containsKey(plugin.id)) {
      pending.value = {...pending.value}..remove(plugin.id);
    }
    return record;
  }

  Future<void> uninstall(String id) async {
    try {
      await File(codePath(id)).delete();
    } on FileSystemException {
      // Already gone.
    }
    final list = await installed();
    await _saveInstalled([for (final p in list) if (p.id != id) p]);
    if (pending.value.containsKey(id)) pending.value = {...pending.value}..remove(id);
  }

  /// Installed sources that the list each was installed from has a newer
  /// version of: plugin id to the newer one. Another list carrying the same
  /// id never replaces a source (one installed before lists were recorded
  /// is updated only when a single list carries it). Kept in [pending].
  Future<Map<String, PluginInfo>> updates({bool refresh = false}) async {
    final listed = await _listed(refresh: refresh);
    final out = <String, PluginInfo>{};
    for (final p in await installed()) {
      PluginInfo? newer;
      final repo = p.repo;
      if (repo != null) {
        newer = listed[repo]?[p.id];
      } else {
        final carriers = [
          for (final l in listed.values)
            if (l[p.id] case final x?) x,
        ];
        if (carriers.length == 1) newer = carriers.single;
      }
      if (newer != null && p.olderThan(newer)) out[p.id] = newer;
    }
    pending.value = out;
    return out;
  }

  /// [p] as the list it was installed from offers it now (freshly read when
  /// [refresh]); for one installed before lists were recorded, the newest
  /// any list offers.
  Future<PluginInfo?> fromItsList(PluginInfo p, {bool refresh = false}) async {
    final listed = await _listed(refresh: refresh);
    final repo = p.repo;
    if (repo == null) return _newestOf(listed, p.id);
    return listed[repo]?[p.id];
  }

  /// Plugins installed before their code's hash was kept get one now, from
  /// the code on the phone as it is (nothing better to go by); from then on
  /// any change to it is caught.
  Future<void> recordMissingHashes() async {
    final list = await installed();
    if (list.every((p) => p.sha256 != null)) return;
    final next = <PluginInfo>[];
    for (final p in list) {
      if (p.sha256 != null) {
        next.add(p);
        continue;
      }
      final f = File(codePath(p.id));
      next.add(await f.exists() ? p.withHash(sha256Hex(await f.readAsBytes())) : p);
    }
    await _saveInstalled(next);
  }

  /// Where an installed plugin's code lives.
  String codePath(String id) => '${_pluginDir.path}/${_safe(id)}.js';

  Future<String?> code(String id) async {
    final f = File(codePath(id));
    return await f.exists() ? f.readAsString() : null;
  }

  /// Per-plugin key/value storage, for plugins that keep settings.
  File storageFile(String id) => File('${dir.path}/storage-${_safe(id)}.json');

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
