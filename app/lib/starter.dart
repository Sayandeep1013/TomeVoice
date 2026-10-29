import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'library_store.dart';
import 'sources/source_engine.dart';
import 'sources/source_store.dart';
import 'speech_service.dart';

/// What a new install starts with, so the first shelf is not empty: a
/// public-domain classic that ships inside the app, two sources, and two
/// popular web novels whose details, chapter list and cover come from the
/// site on first launch. All of it can be removed like anything else, and
/// what is removed is not brought back.
///
/// An install that already has books (an update) is left as it is.
class Starter {
  const Starter._();

  /// Pride and Prejudice from Project Gutenberg, with Hugh Thomson's 1894
  /// peacock cover. Public domain.
  static const _book = 'assets/starter/pride-and-prejudice.epub';

  static const _plugins = ['readnovelfull', 'royalroad'];

  static const _novels = [
    ('readnovelfull', 'shadow-slave.html'),
    ('readnovelfull', 'lord-of-the-mysteries-v1.html'),
  ];

  /// Fill a new library. What needs the network and fails (offline on
  /// first launch) is tried again next time.
  static Future<void> seed(Directory root, LibraryStore store, SourceStore sources) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final flag = File('${root.path}/starter.json');
    var done = <String, Object?>{};
    if (await flag.exists()) {
      try {
        done = Map<String, Object?>.from(jsonDecode(await flag.readAsString()) as Map);
      } on Object {
        return;
      }
    } else if ((await store.list(all: true)).isNotEmpty) {
      await flag.writeAsString(jsonEncode({'skipped': true}));
      return;
    }
    if (done['skipped'] == true) return;
    Future<void> save() => flag.writeAsString(jsonEncode(done));

    if (done['book'] != true) {
      final copy = File('${root.path}/starter.epub');
      try {
        final data = await rootBundle.load(_book);
        await copy.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        await store.importFile(
          PickedFile(path: copy.path, name: 'Pride and Prejudice.epub', mime: 'application/epub+zip'),
        );
        done['book'] = true;
        await save();
      } on Object {
        // Tried again next launch.
      } finally {
        if (await copy.exists()) await copy.delete();
      }
    }

    final added = {...(done['novels'] as List? ?? const []).cast<String>()};
    if (done['plugins'] == true && added.length == _novels.length) return;
    try {
      if (done['plugins'] != true) {
        final available = await sources.available();
        final installed = {for (final p in await sources.installed()) p.id};
        for (final id in _plugins) {
          final p = available.where((p) => p.id == id).firstOrNull;
          if (p != null && !installed.contains(id)) await sources.install(p);
        }
        done['plugins'] = true;
        await save();
      }
      for (final (pluginId, path) in _novels) {
        if (added.contains(path)) continue;
        final plugin = await sources.installedById(pluginId);
        if (plugin == null) continue;
        final novel = await SourceEngine.instance.novel(plugin, path);
        await store.addWebNovel(plugin, novel);
        added.add(path);
        done['novels'] = added.toList();
        await save();
      }
    } on Object {
      // Offline, or the site is down: next launch tries again.
    }
  }
}
