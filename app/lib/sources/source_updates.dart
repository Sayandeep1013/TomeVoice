import 'dart:io';

import 'models.dart';
import 'net.dart';
import 'source_engine.dart';
import 'source_store.dart';

/// What became of one source in an update.
class UpdateOutcome {
  const UpdateOutcome(this.plugin, {required this.updated, this.note});

  final PluginInfo plugin;

  /// The new version is installed.
  final bool updated;

  /// Why not, or what to know about it, for the reader.
  final String? note;
}

/// Update each of [updates] (newer versions from the lists their sources
/// came from), keeping the version that works: the new one replaces the
/// old only once it loads and lists the site's popular novels. When it does
/// not but the old one still does, the old stays. When neither does (the
/// site is down, or changed and the old version broke first), the new one
/// is installed: it is the likelier to be right once the site answers.
Future<List<UpdateOutcome>> updateSources(
  SourceStore store,
  SourceEngine engine,
  Iterable<PluginInfo> updates, {
  void Function(PluginInfo plugin, int done, int total)? onProgress,
}) async {
  final todo = updates.toList();
  final out = <UpdateOutcome>[];
  for (var n = 0; n < todo.length; n++) {
    final next = todo[n];
    onProgress?.call(next, n, todo.length);
    String? staged;
    try {
      final (code, hash) = await store.download(next);
      staged = await store.stage(next.id, code);
      final problem = await engine.smokeTest(next, staged, hash);
      if (problem == null) {
        await store.installCode(next, code, hash);
        out.add(UpdateOutcome(next, updated: true));
        continue;
      }
      final old = await store.installedById(next.id);
      final oldProblem = old?.sha256 == null
          ? 'not installed'
          : await engine.smokeTest(old!, store.codePath(old.id), old.sha256!);
      if (oldProblem == null) {
        out.add(UpdateOutcome(next,
            updated: false, note: 'Version ${next.version} did not work ($problem), so ${old!.version} was kept.'));
      } else {
        await store.installCode(next, code, hash);
        out.add(UpdateOutcome(next, updated: true, note: 'The site did not answer either version: $problem'));
      }
    } on Object catch (e) {
      out.add(UpdateOutcome(next, updated: false, note: friendlyError(e)));
    } finally {
      if (staged != null) {
        try {
          await File(staged).delete();
        } on FileSystemException {
          // Gone already.
        }
      }
    }
  }
  return out;
}
