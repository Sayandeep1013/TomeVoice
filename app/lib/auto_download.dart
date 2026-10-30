import 'dart:async';

import 'download_queue.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'sources/bridge.dart';
import 'sources/models.dart';
import 'sources/source_engine.dart';
import 'updates.dart';

/// When a web novel's new chapters download by themselves, as a check for
/// new chapters finds them. Off unless the reader turns it on for the novel;
/// on Wi-Fi only, unless they say any network.
enum AutoDownload {
  off('Off', 'New chapters wait for you to download them'),
  wifi('On Wi-Fi', 'Not on mobile data: those found then wait for Wi-Fi'),
  any('On any network', 'Mobile data too');

  const AutoDownload(this.label, this.detail);

  final String label;
  final String detail;

  static AutoDownload byName(String? name) => values.where((v) => v.name == name).firstOrNull ?? off;

  static ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  /// Web novel [id]'s.
  static AutoDownload of(String id, [ListeningPrefs? prefs]) => byName((prefs ?? _prefs).autoDownloadByNovel[id]);

  /// Web novel [id]'s is [to] now.
  static void set(String id, AutoDownload to, [ListeningPrefs? prefs]) {
    final p = prefs ?? _prefs;
    if (to == off) {
      p.autoDownloadByNovel.remove(id);
    } else {
      p.autoDownloadByNovel[id] = to.name;
    }
    p.save();
  }
}

/// What new chapters come to: those to download now, by novel, and those
/// waiting for Wi-Fi.
typedef AutoPlan = ({Map<String, List<NewChapter>> now, List<NewChapter> later});

/// The auto-download rules: of [found] (new chapters, once each), those of
/// novels set to download them ([settingOf]) go now when the novel takes
/// any network, or on Wi-Fi ([unmetered]); a novel on Wi-Fi only off Wi-Fi
/// has its wait. A novel left off has none, and a chapter with no address
/// (logged before 1.3) none either.
AutoPlan planAutoDownloads(
  Iterable<NewChapter> found,
  AutoDownload Function(String bookId) settingOf, {
  required bool unmetered,
}) {
  final now = <String, List<NewChapter>>{};
  final later = <NewChapter>[];
  final seen = <String>{};
  for (final c in found) {
    final path = c.path;
    if (path == null || !seen.add('${c.bookId}|$path')) continue;
    switch (settingOf(c.bookId)) {
      case AutoDownload.off:
        break;
      case AutoDownload.any:
        (now[c.bookId] ??= []).add(c);
      case AutoDownload.wifi:
        if (unmetered) {
          (now[c.bookId] ??= []).add(c);
        } else {
          later.add(c);
        }
    }
  }
  return (now: now, later: later);
}

/// Whether the phone is on Wi-Fi (or another network not charged by the
/// byte); false where it cannot say.
Future<bool> onWifi() async => await SourcesBridge.unmetered() ?? false;

/// New chapters downloading by themselves in the app's engine (open, or
/// left in the background): after each check, those of novels set to are
/// put in the download queue, which carries on with its notification, and
/// those that must wait for Wi-Fi are kept in the check's log until a check
/// or an opening finds it. Those found with the app closed and not fetched
/// then (see [downloadAway]) are taken the same way.
class AutoDownloads {
  AutoDownloads({DownloadQueue? queue, Future<bool> Function()? unmetered, this.prefs})
      : _queue = queue,
        _unmetered = unmetered ?? onWifi;

  final DownloadQueue? _queue;
  final Future<bool> Function() _unmetered;

  /// The settings (the app's, when null).
  final ListeningPrefs? prefs;

  Future<void> _last = Future<void>.value();

  /// [found] (what a check found; none on opening), with those waiting from
  /// before, queued as each novel asks. How many were queued. One at a time.
  Future<int> take(Updates updates, List<NewChapter> found) {
    final run = _last.then((_) => _take(updates, found));
    _last = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<int> _take(Updates updates, List<NewChapter> found) async {
    final waiting = await updates.takeWaitingDownloads();
    if (waiting.isEmpty && found.isEmpty) return 0;
    final plan = planAutoDownloads([...waiting, ...found], (id) => AutoDownload.of(id, prefs), unmetered: await _unmetered());
    final queue = _queue ?? DownloadQueue.instance;
    var queued = 0;
    for (final MapEntry(key: id, value: chapters) in plan.now.entries) {
      queued += await queue.add(id, [for (final c in chapters) ChapterItem(name: c.name, path: c.path!)]);
    }
    await updates.keepWaitingDownloads(plan.later);
    return queued;
  }
}

/// Away from the app (the background check's own engine): [found]'s
/// chapters of novels set to download them, fetched one after another at
/// [pace] while there is time ([until]) and the app has not opened
/// ([stopWhen], asked before each and again before it is written: two
/// engines never write one novel). None while the reader has the downloads
/// paused. What is left, and what waits for Wi-Fi, is left in the log for
/// the app (see AutoDownloads.take). How many came down.
Future<int> downloadAway(
  LibraryStore store,
  Updates updates,
  List<NewChapter> found, {
  required Future<bool> Function() stopWhen,
  required Future<bool> Function() unmetered,
  required DateTime until,
  Duration pace = const Duration(milliseconds: 1500),
  ListeningPrefs? prefs,
}) async {
  final plan = planAutoDownloads(found, (id) => AutoDownload.of(id, prefs), unmetered: await unmetered());
  if (plan.now.isEmpty && plan.later.isEmpty) return 0;
  final left = [...plan.later];
  final paused = await DownloadQueue.pausedIn(store.root);
  var done = 0;
  for (final chapters in plan.now.values) {
    for (final c in chapters) {
      if (paused || DateTime.now().isAfter(until) || await stopWhen()) {
        left.add(c);
        continue;
      }
      try {
        final info = await store.webNovel(c.bookId);
        final at = info?.chapters.indexWhere((x) => x.path == c.path) ?? -1;
        // Gone from the novel, or its list was left for the app: nothing to get.
        if (info == null || at < 0 || store.hasChapter(c.bookId, at)) continue;
        final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
        if (plugin == null) {
          left.add(c);
          continue;
        }
        final html = await SourceEngine.instance.chapter(plugin, c.path!);
        if (await stopWhen()) {
          left.add(c);
          continue;
        }
        await store.saveChapter(c.bookId, at, c.name, html, language: languageCodeOf(info.plugin.lang));
        done++;
        if (pace > Duration.zero) await Future<void>.delayed(pace);
      } on Object {
        // A site that fails, or wants a browser check: the app's queue
        // tries again, as it does.
        left.add(c);
      }
    }
  }
  await updates.keepWaitingDownloads(left);
  return done;
}
