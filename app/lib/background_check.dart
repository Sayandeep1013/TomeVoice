import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'auto_download.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'sources/bridge.dart';
import 'sources/net.dart';
import 'sources/source_engine.dart';
import 'sources/source_store.dart';
import 'updates.dart';

/// New chapters checked for with TomeVoice closed.
///
/// Android's WorkManager runs NovelCheckWorker (Kotlin) on the reader's
/// schedule (Settings > Check for new chapters), on Wi-Fi with the battery
/// not low. The check itself is Dart (the sources run in QuickJS), so the
/// worker starts a Flutter engine of its own on [backgroundCheckMain]. That
/// engine has none of the app's own platform calls (the web view, the
/// phone's browser agent): sources whose sites need a browser check are
/// skipped and listed on the Updates screen, and the library index is left
/// to the app (see Updates.background).
///
/// While the app's own engine is up (TomeVoice open, left in the background
/// with Back, or reading a book with no screen), the worker starts no engine:
/// it asks that one to check (checkInApp, through SourcesBridge's
/// "runCheck"), as two engines must never write the library at once, and
/// posts the same notification with what it found.
class BackgroundChecks {
  const BackgroundChecks._();

  /// Have the check run every [every] (stopped when it is Off).
  static Future<void> schedule(UpdateEvery every) async {
    final handle = PluginUtilities.getCallbackHandle(backgroundCheckMain)?.toRawHandle();
    if (handle == null) return;
    await SourcesBridge.scheduleChecks(handle: handle, minutes: every.interval?.inMinutes ?? 0);
  }
}

/// Where the background engine starts. It says it is done (with what to
/// tell the reader) whatever happens, so the worker never waits it out.
@pragma('vm:entry-point')
Future<void> backgroundCheckMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  var outcome = const <String, Object?>{'found': 0};
  try {
    outcome = await runBackgroundCheck();
  } on Object catch (e) {
    outcome = {'found': 0, 'error': '$e'};
  } finally {
    await SourcesBridge.backgroundDone(outcome);
  }
}

/// The check, from the app's folders ([libraryRoot] and [sourcesRoot], as
/// SourcesBridge gives them, or a test's). What the notification says.
Future<Map<String, Object?>> runBackgroundCheck({String? libraryRoot, String? sourcesRoot}) async {
  final started = DateTime.now();
  final library = libraryRoot ?? await SourcesBridge.libraryRoot();
  final internal = sourcesRoot ?? await SourcesBridge.sourcesRoot();
  if (library == null || internal == null) return const {'found': 0};
  // Turned off since it was scheduled: nothing to do.
  final prefs = await ListeningPrefs.load(library);
  if (UpdateEvery.byName(prefs.updateEvery).interval == null) return const {'found': 0};
  final sources = SourceStore(Directory(internal));
  Net.userAgent = await sources.savedUserAgent() ?? Net.userAgent;
  await Net.instance.attach(sources.dir);
  SourceEngine.instance.attach(sources);
  // The library's index is the app's engine's alone: never written here.
  final store = LibraryStore(Directory(library), readOnly: true);
  // The app opening mid-check takes over: this one stops before its next
  // write (the log of what it did is still kept; the app waits for it,
  // see SourcesBridge.backgroundBusy).
  final updates = Updates(store, background: true, stopWhen: SourcesBridge.appIsOpen);
  final result = await updates.checkAll();
  // New chapters of novels that download them by themselves, while there
  // is time (the worker gives this engine nine minutes); the rest wait in
  // the log for the app.
  try {
    await downloadAway(
      store,
      updates,
      result.added,
      stopWhen: SourcesBridge.appIsOpen,
      unmetered: onWifi,
      until: started.add(const Duration(minutes: 6)),
    );
  } on Object {
    // What was found is still said.
  }
  return describeNewChapters(store, result.added);
}

/// What to tell the reader of [added]: how many chapters, and of which
/// novels. One on a secret shelf goes unnamed ("a novel"), open or not: the
/// notification stays, on the lock screen too, after TomeVoice is left and
/// the shelves shut (it is worded in the app's engine as well, when the
/// worker asks it).
Map<String, Object?> describeNewChapters(LibraryStore store, List<NewChapter> added) {
  if (added.isEmpty) return const {'found': 0};
  final byBook = <String, int>{};
  final titles = <String, String>{};
  for (final c in added) {
    byBook[c.bookId] = (byBook[c.bookId] ?? 0) + 1;
    titles[c.bookId] = store.isSecret(c.bookId) ? 'A novel' : c.title;
  }
  String chapters(int n) => n == 1 ? 'a new chapter' : '$n new chapters';
  final lines = [for (final e in byBook.entries) '${titles[e.key]}: ${chapters(e.value)}'];
  if (byBook.length == 1) {
    return {'found': added.length, 'title': titles[byBook.keys.single], 'text': chapters(added.length), 'lines': lines};
  }
  final named = [
    for (final id in byBook.keys)
      if (titles[id] != 'A novel') titles[id]!,
  ];
  final others = byBook.length - named.take(2).length;
  final text = named.isEmpty
      ? 'In ${byBook.length} novels'
      : '${named.take(2).join(', ')}${others > 0 ? ' and $others more' : ''}';
  final total = added.length;
  return {'found': total, 'title': total == 1 ? 'A new chapter' : '$total new chapters', 'text': text, 'lines': lines};
}
