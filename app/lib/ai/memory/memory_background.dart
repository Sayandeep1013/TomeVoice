import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../library_store.dart';
import '../../prefs.dart';
import '../../secrets.dart';
import '../../sources/bridge.dart';
import '../ai_keys.dart';
import '../ai_router.dart';
import 'memory_builder.dart';
import 'memory_db.dart';
import 'word_index.dart';

/// The books' memories built with TomeVoice closed, by MemoryBuildWorker
/// (Kotlin): every hour or so, on the reader's conditions (AI > Building
/// memories). The work itself is here, in an engine of the worker's own.
class MemoryBackground {
  const MemoryBackground._();

  /// The worker scheduled as [prefs] say, or stopped: on only while the AI
  /// has a key.
  static Future<void> apply(ListeningPrefs prefs) async {
    final handle = PluginUtilities.getCallbackHandle(memoryBuildMain)?.toRawHandle();
    if (handle == null) return;
    final on = prefs.aiBackground && AiRing.instance.hasKeys;
    try {
      await SourcesBridge.scheduleMemory(
        handle: handle,
        minutes: on ? 60 : 0,
        unmetered: prefs.aiBackgroundWifi,
        charging: prefs.aiBackgroundCharging,
      );
    } on Object {
      // No platform (tests, Windows): nothing to schedule.
    }
  }
}

@pragma('vm:entry-point')
Future<void> memoryBuildMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  var outcome = const <String, Object?>{'found': 0};
  try {
    outcome = await runBackgroundBuild(stopWhen: SourcesBridge.appIsOpen);
  } on Object catch (e) {
    outcome = {'found': 0, 'error': '$e'};
  } finally {
    await SourcesBridge.backgroundDone(outcome);
  }
}

/// Builds the memories the reader has begun, one book at a time, for at
/// most [budget]: each book's new chapters indexed, then noted until done,
/// out of time, the app opened ([stopWhen]), or every key resting. Books on
/// a secret shelf are never sent. Says how many chapters were noted.
Future<Map<String, Object?>> runBackgroundBuild({
  String? libraryRoot,
  String? internalRoot,
  Duration budget = const Duration(minutes: 8),
  Future<bool> Function()? stopWhen,
  AiRouter? router,
}) async {
  final until = DateTime.now().add(budget);
  final library = libraryRoot ?? await SourcesBridge.libraryRoot();
  final internal = internalRoot ?? await SourcesBridge.sourcesRoot();
  if (library == null) return const {'found': 0};
  if (internal != null) Secrets.home = Directory(internal);
  final ring = router?.ring ?? AiRing.instance;
  if (router == null) await ring.attach(Directory(library));
  if (!ring.hasKeys) return const {'found': 0};
  final store = LibraryStore(Directory(library), readOnly: true);
  final entries = await store.list(all: true);
  var noted = 0;
  for (final e in entries) {
    if (DateTime.now().isAfter(until)) break;
    if (store.isSecret(e.id)) continue;
    final path = MemoryDb.pathIn(store.bookDir(e.id));
    if (!File(path).existsSync()) continue;
    if (!_begun(path)) continue;
    await WordIndexer(store).index(e.id);
    final b = MemoryBuilder(path: path, router: router);
    final watch = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (DateTime.now().isAfter(until) || (stopWhen != null && await stopWhen())) b.pause();
    });
    await b.refreshCounts();
    final had = b.state.value.noted;
    final s = await b.run();
    watch.cancel();
    noted += s.noted - had;
    if (s.phase == BuildPhase.resting || s.phase == BuildPhase.failed) break;
  }
  return {'found': 0, 'noted': noted};
}

bool _begun(String path) {
  final m = MemoryDb.open(path);
  try {
    if (m.meta('private') == '1' || m.meta('paused') == '1') return false;
    if (m.meta('begun') == '1') return true;
    return (m.db.select('SELECT count(*) n FROM notes').first['n'] as int) > 0;
  } finally {
    m.close();
  }
}
