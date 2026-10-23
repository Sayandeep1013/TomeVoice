import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'models.dart';
import 'net.dart';

/// Repositories and installed sources, kept under `<root>/sources/`.
///
/// A repository is a URL to a plugin index in LNReader's format: a JSON
/// list of `{id, name, site, lang, version, url, iconUrl}`. A new install
/// starts with LNReader's own list ([builtIn]), so there is something to
/// install at once; readers can remove it and add any others. Installing a
/// plugin downloads its code, so browsing and reading work from the copy on
/// the phone.
class SourceStore {
  SourceStore(Directory root, {this.defaults = builtIn}) : dir = Directory('${root.path}/sources');

  /// LNReader's plugin list: some 300 sites in many languages, kept up to
  /// date by its community.
  static const builtIn = [
    'https://raw.githubusercontent.com/LNReader/lnreader-plugins/plugins/v3.0.0/.dist/plugins.min.json',
  ];

  final Directory dir;

  /// The lists a new install starts with. Once the reader adds or removes
  /// one, their own choice is kept instead.
  final List<String> defaults;

  /// Bumped when repositories or installed sources change.
  final changes = ValueNotifier<int>(0);

  File get _reposFile => File('${dir.path}/repos.json');
  File get _installedFile => File('${dir.path}/installed.json');
  Directory get _pluginDir => Directory('${dir.path}/plugins');
  File _indexCache(String repo) => File('${dir.path}/index-${repo.hashCode.toUnsigned(32)}.json');

  Future<void> ensure() async {
    await _pluginDir.create(recursive: true);
    await Net.instance.attach(dir);
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

  /// Add [url] after checking it really is a plugin index. Returns how many
  /// sources it lists.
  Future<int> addRepo(String url) async {
    final clean = url.trim();
    final uri = Uri.tryParse(clean);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      throw const FormatException('That is not a web address.');
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
    final text = await Net.instance.text(repo);
    final raw = jsonDecode(text);
    if (raw is! List) throw const FormatException('That address is not a source list.');
    final plugins = [
      for (final p in raw)
        if (p is Map) PluginInfo.fromJson(Map<String, Object?>.from(p))?.withRepo(repo),
    ].whereType<PluginInfo>().toList();
    await _indexCache(repo).writeAsString(jsonEncode([for (final p in plugins) p.toJson()]));
    return plugins;
  }

  /// Every source the repositories offer, newest version of each. Uses the
  /// copy from the last refresh unless [refresh] is set or there is none.
  Future<List<PluginInfo>> available({bool refresh = false}) async {
    final byId = <String, PluginInfo>{};
    for (final repo in await repos()) {
      List<PluginInfo> list;
      final cache = _indexCache(repo);
      if (!refresh && await cache.exists()) {
        list = [
          for (final p in jsonDecode(await cache.readAsString()) as List)
            PluginInfo.fromJson(Map<String, Object?>.from(p as Map)),
        ].whereType<PluginInfo>().toList();
      } else {
        try {
          list = await _fetchIndex(repo);
        } on Object {
          list = const [];
        }
      }
      for (final p in list) {
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

  Future<List<PluginInfo>> installed() async {
    await ensure();
    try {
      if (await _installedFile.exists()) {
        return [
          for (final p in jsonDecode(await _installedFile.readAsString()) as List)
            PluginInfo.fromJson(Map<String, Object?>.from(p as Map)),
        ].whereType<PluginInfo>().toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }
    } on Object {
      // Fall through to none.
    }
    return const [];
  }

  Future<PluginInfo?> installedById(String id) async =>
      (await installed()).where((p) => p.id == id).firstOrNull;

  Future<void> _saveInstalled(List<PluginInfo> list) async {
    await _installedFile.writeAsString(jsonEncode([for (final p in list) p.toJson()]));
    changes.value++;
  }

  /// Download [plugin]'s code and add it (or replace an older version).
  Future<void> install(PluginInfo plugin) async {
    await ensure();
    final code = await Net.instance.text(plugin.url);
    if (!code.contains('exports')) {
      throw const FormatException('That source could not be downloaded properly.');
    }
    await File(codePath(plugin.id)).writeAsString(code);
    final list = await installed();
    await _saveInstalled([for (final p in list) if (p.id != plugin.id) p, plugin]);
  }

  Future<void> uninstall(String id) async {
    try {
      await File(codePath(id)).delete();
    } on FileSystemException {
      // Already gone.
    }
    final list = await installed();
    await _saveInstalled([for (final p in list) if (p.id != id) p]);
  }

  /// Installed sources that a repository has a newer version of.
  Future<List<PluginInfo>> updates() async {
    final avail = {for (final p in await available()) p.id: p};
    return [
      for (final p in await installed())
        if (avail[p.id] != null && p.olderThan(avail[p.id]!)) avail[p.id]!,
    ];
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
