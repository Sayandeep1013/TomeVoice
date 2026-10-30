import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'library_store.dart';
import 'safe_file.dart';
import 'sources/bridge.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/plugin_host.dart';
import 'sources/source_engine.dart';

/// One chapter waiting to be downloaded, by its address on its site (its
/// place in the list can change before it is reached).
class DownloadJob {
  DownloadJob({required this.bookId, required this.path, required this.name, this.tries = 0, this.failed});

  final String bookId;
  final String path;
  final String name;

  /// Failed attempts so far.
  int tries;

  /// Why it stopped trying, said to the reader; null while it will be tried.
  String? failed;

  /// Not to be tried before this (backing off, or as the site asked).
  DateTime? notBefore;

  Map<String, Object?> toJson() => {
        'book': bookId,
        'path': path,
        'name': name,
        if (tries > 0) 'tries': tries,
        if (failed != null) 'failed': failed,
      };

  static DownloadJob? fromJson(Object? o) {
    if (o is! Map) return null;
    final book = o['book'], path = o['path'];
    if (book is! String || path is! String) return null;
    return DownloadJob(
      bookId: book,
      path: path,
      name: o['name'] as String? ?? '',
      tries: o['tries'] as int? ?? 0,
      failed: o['failed'] as String?,
    );
  }
}

/// How one novel's downloads stand.
class BookDownloads {
  const BookDownloads({required this.waiting, required this.failed, this.current, this.problem});

  /// Chapters still to download.
  final int waiting;

  /// Chapters it stopped trying.
  final int failed;

  /// The chapter being downloaded now.
  final String? current;

  /// Why the last that failed did.
  final String? problem;
}

/// Web-novel chapters to download, kept on disk (downloads.json in the
/// library) so leaving a novel's page, or the app, does not lose them: the
/// queue carries on in the background while the app lives, with a
/// notification showing how far it is (Android's foreground service keeps
/// the app alive meanwhile), and picks up where it was when the app opens.
///
/// One request at a time per site, a pause of [_pace] or more between two,
/// a few sites at once. A chapter that fails is tried again after a wait
/// that doubles each time (or what the site asked for, Retry-After), at
/// most [maxTries] times; one whose source needs the reader (not installed,
/// changed, a browser check) waits for them. Pause stops it all until Resume.
class DownloadQueue {
  DownloadQueue._();

  static final instance = DownloadQueue._();

  /// A queue of its own, for tests.
  @visibleForTesting
  DownloadQueue.forTests({Duration pace = const Duration(milliseconds: 1500), Duration backoff = const Duration(seconds: 5)})
      : _pace = pace,
        _backoff = backoff;

  Duration _pace = const Duration(milliseconds: 1500);
  Duration _backoff = const Duration(seconds: 5);

  static const maxTries = 5;

  /// Sites asked at once.
  static const _lanes = 3;

  LibraryStore? _store;
  File? _file;
  final _jobs = <DownloadJob>[];
  bool _paused = false;

  /// Bumped on every change, for pages showing progress.
  final changes = ValueNotifier<int>(0);

  /// Chapters downloaded since the queue last ran dry, for the notification.
  int _done = 0;

  bool get paused => _paused;

  /// The library to download into; picks up where the queue was.
  Future<void> attach(LibraryStore store) async {
    _store = store;
    _file = File('${store.root.path}/downloads.json');
    try {
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString()) as Map;
        _paused = raw['paused'] == true;
        _jobs
          ..clear()
          ..addAll([
            for (final o in raw['jobs'] as List? ?? const [])
              if (DownloadJob.fromJson(o) case final j?) j,
          ]);
      }
    } on Object {
      // A broken queue file: start empty.
    }
    changes.value++;
    _kick();
  }

  /// [chapters] of novel [bookId], to download in this order after what is
  /// already waiting ([first]: before it). Those queued already, or on the
  /// phone, are left out. Returns how many were added.
  Future<int> add(String bookId, Iterable<ChapterItem> chapters, {bool first = false}) async {
    final store = _store;
    if (store == null) return 0;
    final info = await store.webNovel(bookId);
    if (info != null) _pluginOf[bookId] = info.plugin.id;
    final at = {for (var i = 0; i < (info?.chapters.length ?? 0); i++) info!.chapters[i].path: i};
    final queued = {for (final j in _jobs) if (j.bookId == bookId) j.path};
    final fresh = [
      for (final c in chapters)
        if (!queued.contains(c.path) && !(at[c.path] != null && store.hasChapter(bookId, at[c.path]!)))
          DownloadJob(bookId: bookId, path: c.path, name: c.name),
    ];
    if (fresh.isEmpty) return 0;
    if (first) {
      _jobs.insertAll(0, fresh);
    } else {
      _jobs.addAll(fresh);
    }
    await _save();
    _kick();
    return fresh.length;
  }

  /// How novel [bookId]'s downloads stand; null when it has none waiting.
  BookDownloads? of(String bookId) {
    var waiting = 0, failed = 0;
    String? problem;
    for (final j in _jobs) {
      if (j.bookId != bookId) continue;
      if (j.failed != null) {
        failed++;
        problem = j.failed;
      } else {
        waiting++;
      }
    }
    if (waiting == 0 && failed == 0) return null;
    final now = _running.values.where((j) => j.bookId == bookId).firstOrNull;
    return BookDownloads(waiting: waiting, failed: failed, current: now?.name, problem: problem);
  }

  /// The addresses of [bookId]'s chapters waiting (not failed).
  Set<String> waitingPaths(String bookId) =>
      {for (final j in _jobs) if (j.bookId == bookId && j.failed == null) j.path};

  Future<void> pause() async {
    _paused = true;
    await _save();
    _notify();
  }

  Future<void> resume() async {
    _paused = false;
    // Chapters waiting on a backoff are tried at once.
    for (final j in _jobs) {
      j.notBefore = null;
    }
    await _save();
    _kick();
  }

  /// Forget [bookId]'s downloads still waiting (all of them, when null).
  Future<void> cancel([String? bookId]) async {
    _jobs.removeWhere((j) => bookId == null || j.bookId == bookId);
    await _save();
    _kick();
  }

  /// Try again the chapters of [bookId] that failed.
  Future<void> retry(String bookId) async {
    for (final j in _jobs) {
      if (j.bookId == bookId && j.failed != null) {
        j
          ..failed = null
          ..tries = 0
          ..notBefore = null;
      }
    }
    await _save();
    _kick();
  }

  // --------------------------------------------------------------- running

  /// The job each site is busy with.
  final _running = <String, DownloadJob>{};

  /// When each site was last asked.
  final _lastAsked = <String, DateTime>{};
  Timer? _wake;

  /// Start lanes for work that can be done now; wake later for work that
  /// waits.
  void _kick() {
    _wake?.cancel();
    if (_paused || _store == null) {
      _notify();
      return;
    }
    while (_running.length < _lanes) {
      final job = _next();
      if (job == null) break;
      unawaited(_run(job));
    }
    final waiting = [for (final j in _jobs) if (j.failed == null && !_running.containsValue(j)) j];
    if (_running.isEmpty && waiting.isEmpty) _done = 0;
    if (_running.length < _lanes && waiting.isNotEmpty) {
      // Something waits on a backoff or a site's pace: come back then.
      final now = DateTime.now();
      final soonest = waiting.map((j) => _readyAt(j, now)).reduce((a, b) => a.isBefore(b) ? a : b);
      _wake = Timer(soonest.difference(now) + const Duration(milliseconds: 50), _kick);
    }
    _notify();
  }

  String _siteOf(DownloadJob j) => _pluginOf[j.bookId] ?? j.bookId;

  /// Each novel's source, as found when its first job ran.
  final _pluginOf = <String, String>{};

  DateTime _readyAt(DownloadJob j, DateTime now) {
    var at = j.notBefore ?? now;
    final last = _lastAsked[_siteOf(j)];
    if (last != null && last.add(_pace).isAfter(at)) at = last.add(_pace);
    return at;
  }

  DownloadJob? _next() {
    final now = DateTime.now();
    for (final j in _jobs) {
      if (j.failed != null || _running.containsValue(j)) continue;
      final site = _siteOf(j);
      if (_running.containsKey(site)) continue;
      if (_readyAt(j, now).isAfter(now)) continue;
      return j;
    }
    return null;
  }

  Future<void> _run(DownloadJob job) async {
    final store = _store!;
    var site = _siteOf(job);
    _running[site] = job;
    try {
      final info = await store.webNovel(job.bookId);
      if (info == null) {
        _jobs.remove(job);
        return;
      }
      _pluginOf[job.bookId] = info.plugin.id;
      if (site != info.plugin.id) {
        // Its site was not known yet: hold the right lane from now on.
        _running.remove(site);
        site = info.plugin.id;
        if (_running.containsKey(site)) return;
        _running[site] = job;
      }
      // Found again by its address: the list may have changed since.
      var at = info.chapters.indexWhere((c) => c.path == job.path);
      if (at < 0 || store.hasChapter(job.bookId, at)) {
        _jobs.remove(job);
        return;
      }
      final plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
      if (plugin == null) throw MissingSourceException(info.plugin.id, info.plugin.name);
      _lastAsked[site] = DateTime.now();
      final html = await SourceEngine.instance.chapter(plugin, job.path);
      // Its place again: the list may have been re-filed while it came.
      final now = await store.webNovel(job.bookId);
      at = now?.chapters.indexWhere((c) => c.path == job.path) ?? -1;
      if (at >= 0) await store.saveChapter(job.bookId, at, job.name, html, language: languageCodeOf(info.plugin.lang));
      _jobs.remove(job);
      _done++;
    } on Object catch (e) {
      _failed(job, e);
    } finally {
      if (identical(_running[site], job)) _running.remove(site);
      _lastAsked[site] = DateTime.now();
      await _save();
      _kick();
    }
  }

  /// [job] failed with [e]: tried again later, or (out of tries, or needing
  /// the reader) marked failed with why.
  void _failed(DownloadJob job, Object e) {
    final needsReader = e is MissingSourceException || e is TamperedSourceException || e is ChallengeException;
    job.tries++;
    if (needsReader || job.tries >= maxTries) {
      final why = e is SourceException ? e.message : friendlyError(e);
      // The same cause holds the novel's other chapters back too.
      for (final j in _jobs) {
        if (j.bookId == job.bookId && (identical(j, job) || needsReader)) j.failed = why;
      }
      return;
    }
    var wait = _backoff * math.pow(2, job.tries - 1).toInt();
    if (wait > const Duration(minutes: 10)) wait = const Duration(minutes: 10);
    if (e is RateLimitedException && e.retryAfter > wait) wait = e.retryAfter;
    job.notBefore = DateTime.now().add(wait);
    // A site that asked to slow down is left alone for as long, whatever chapter.
    if (e is RateLimitedException) {
      for (final j in _jobs) {
        if (_siteOf(j) == _siteOf(job) && j.failed == null) j.notBefore = job.notBefore;
      }
    }
  }

  Future<void>? _saving;

  Future<void> _save() async {
    final f = _file;
    changes.value++;
    if (f == null) return;
    final write = writeSafely(f, jsonEncode({if (_paused) 'paused': true, 'jobs': [for (final j in _jobs) j.toJson()]}));
    _saving = write;
    try {
      await write;
    } on Object {
      // Kept in memory; saved with the next change.
    }
  }

  /// Nothing downloading and the queue on disk as it is (tests).
  @visibleForTesting
  Future<void> whenIdle() async {
    while (_running.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    try {
      await _saving;
    } on Object {
      // Written or not, nothing is in flight.
    }
  }

  /// The notification (and the service keeping the app alive) while
  /// chapters download; gone when none wait or the queue is paused.
  void _notify() {
    changes.value++;
    final waiting = _jobs.where((j) => j.failed == null).length;
    if (waiting == 0 || _paused) {
      unawaited(SourcesBridge.downloadProgress(null));
      return;
    }
    final now = _running.values.firstOrNull;
    final title = now == null ? 'Downloading chapters' : (_titles[now.bookId] ?? 'Downloading chapters');
    unawaited(SourcesBridge.downloadProgress({
      'title': title,
      'text': now == null ? '$waiting to go' : '${now.name} · $waiting to go',
      'done': _done,
      'total': _done + waiting,
    }));
    if (now != null && !_titles.containsKey(now.bookId)) unawaited(_title(now.bookId));
  }

  /// Novel titles for the notification (none for one on a secret shelf
  /// while the shelves are shut).
  final _titles = <String, String>{};

  Future<void> _title(String bookId) async {
    final store = _store;
    if (store == null) return;
    final e = (await store.list(all: true)).where((e) => e.id == bookId).firstOrNull;
    if (e == null) return;
    _titles[bookId] = store.isSecret(bookId) && !LibraryStore.secretOpen.value ? 'Downloading chapters' : e.title;
    _notify();
  }
}
