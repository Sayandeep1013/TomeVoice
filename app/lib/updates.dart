import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'library_store.dart';
import 'safe_file.dart';
import 'sources/browser_hosts.dart';
import 'sources/cookies.dart';
import 'sources/models.dart';
import 'sources/net.dart';
import 'sources/plugin_host.dart';
import 'sources/source_engine.dart';

/// A chapter a source added since the last check.
class NewChapter {
  const NewChapter({
    required this.bookId,
    required this.title,
    required this.index,
    required this.name,
    required this.foundAt,
    this.path,
  });

  final String bookId;
  final String title;

  /// Where it was in the list when found; the list can shift since, so
  /// [path] is what finds it again.
  final int index;
  final String name;
  final DateTime foundAt;

  /// The chapter's address on its site (null in logs from before 1.3).
  final String? path;

  Map<String, Object?> toJson() => {
        'book': bookId,
        'title': title,
        'index': index,
        if (path != null) 'path': path,
        'name': name,
        'found': foundAt.toIso8601String(),
      };

  static NewChapter? fromJson(Object? o) {
    if (o is! Map) return null;
    final found = DateTime.tryParse(o['found'] as String? ?? '');
    if (found == null) return null;
    return NewChapter(
      bookId: o['book'] as String? ?? '',
      title: o['title'] as String? ?? '',
      index: o['index'] as int? ?? 0,
      path: o['path'] as String?,
      name: o['name'] as String? ?? '',
      foundAt: found,
    );
  }
}

/// A source whose novels could not be checked the last time, and why.
class CheckProblem {
  const CheckProblem({
    required this.pluginId,
    required this.source,
    required this.novels,
    required this.why,
    this.kind = CheckProblemKind.failed,
    this.url,
  });

  final String pluginId;

  /// The source's name.
  final String source;

  /// How many of its novels were not checked.
  final int novels;
  final String why;
  final CheckProblemKind kind;

  /// For a browser check: the page that asked for it.
  final String? url;

  Map<String, Object?> toJson() => {
        'plugin': pluginId,
        'source': source,
        'novels': novels,
        'why': why,
        'kind': kind.name,
        if (url != null) 'url': url,
      };

  static CheckProblem? fromJson(Object? o) {
    if (o is! Map) return null;
    return CheckProblem(
      pluginId: o['plugin'] as String? ?? '',
      source: o['source'] as String? ?? '',
      novels: o['novels'] as int? ?? 0,
      why: o['why'] as String? ?? '',
      kind: CheckProblemKind.values.where((k) => k.name == o['kind']).firstOrNull ?? CheckProblemKind.failed,
      url: o['url'] as String?,
    );
  }
}

enum CheckProblemKind {
  /// The site failed or did not answer.
  failed,

  /// The site wants a browser check (its novels wait for the app).
  challenge,

  /// The source is not installed.
  missing,

  /// The source's code changed on the phone.
  tampered,

  /// The site's list looked wrong and was not taken (see judgeChapterList).
  refused,
}

/// What the log on disk holds.
typedef UpdateLog = ({
  List<NewChapter> items,
  DateTime? checked,
  DateTime? attempted,
  List<CheckProblem> problems,
});

/// What a check found.
typedef CheckResult = ({
  int found,
  int checked,
  int failed,
  List<NewChapter> added,
});

/// How often web novels are checked for new chapters.
enum UpdateEvery {
  off('Off', null),
  hours12('Every 12 hours', Duration(hours: 12)),
  daily('Daily', Duration(days: 1)),
  days2('Every 2 days', Duration(days: 2)),
  weekly('Weekly', Duration(days: 7));

  const UpdateEvery(this.label, this.interval);

  final String label;
  final Duration? interval;

  static UpdateEvery byName(String? n) => values.where((v) => v.name == n).firstOrNull ?? daily;
}

/// Checks the web novels in the library for new chapters, like NovelDokusha's
/// daily update: each source is asked for the novel's chapter list, new ones
/// are added to the book and logged for the Updates screen.
///
/// A few novels are asked at once (one per site at a time, so no site is
/// hammered). A run is recorded as done only if some novel was reached; the
/// sources that failed are kept with why, for the Updates screen.
///
/// [background]: a check made with the app closed (background_check.dart).
/// It writes no library index (the app's own engine may be holding it):
/// only lists that grew at their end are stored (the chapter counts wait in
/// the log for the app), anything that would move downloads waits for the
/// app, and sources whose sites need a browser check are skipped, as no web
/// view can run there.
class Updates {
  Updates(this.store, {this.background = false});

  final LibraryStore store;
  final bool background;

  /// Novels asked at once.
  static const parallel = 4;

  /// True while a check is running.
  final running = ValueNotifier<bool>(false);

  /// "Checking Shadow Slave (3 of 7)…" while running.
  final status = ValueNotifier<String?>(null);

  File get _log => File('${store.root.path}/updates.json');

  /// Newest first.
  Future<List<NewChapter>> recent() async => (await log()).items;

  Future<DateTime?> lastChecked() async => (await log()).checked;

  /// The new chapters, newest first, when the sites were last asked, and
  /// what failed then: the log read once, as the Updates screen wants it.
  Future<UpdateLog> log() async {
    final raw = await _raw();
    return (
      items: [
        for (final o in raw['new'] as List? ?? const [])
          if (NewChapter.fromJson(o) case final c?) c,
      ],
      checked: DateTime.tryParse(raw['checked'] as String? ?? ''),
      attempted: DateTime.tryParse(raw['attempted'] as String? ?? ''),
      problems: [
        for (final o in raw['problems'] as List? ?? const [])
          if (CheckProblem.fromJson(o) case final p?) p,
      ],
    );
  }

  Future<Map<String, Object?>> _raw() async {
    try {
      if (await _log.exists()) return Map<String, Object?>.from(jsonDecode(await _log.readAsString()) as Map);
    } on Object {
      // A broken log: start again.
    }
    return {};
  }

  /// Chapter counts a check made away from the app found, onto the shelf's
  /// cards (the app's engine owns the library index).
  Future<void> takeCounts() async {
    final raw = await _raw();
    final counts = raw['counts'];
    if (counts is! Map || counts.isEmpty) return;
    await store.noteChapterCounts({
      for (final e in counts.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    });
    await writeSafely(_log, jsonEncode({...raw}..remove('counts')));
  }

  /// Check now if the last successful check is older than [every] (or none
  /// ran). After a failed run (offline), no sooner than half an hour on.
  Future<int> checkIfDue(UpdateEvery every) async {
    final interval = every.interval;
    if (interval == null) return 0;
    final l = await log();
    final now = DateTime.now();
    if (l.checked != null && now.difference(l.checked!) < interval) return 0;
    if (l.attempted != null && now.difference(l.attempted!) < const Duration(minutes: 30)) return 0;
    return (await checkAll()).found;
  }

  /// Ask every web novel's source for its chapter list. Finished novels are
  /// skipped. Returns what was found.
  Future<CheckResult> checkAll({bool skipCompleted = true}) =>
      // A pull while the check on opening still runs waits for that one, so
      // the spinner stays until it ends and the count is the real one.
      _checking ??= _checkAll(skipCompleted).whenComplete(() => _checking = null);

  Future<CheckResult>? _checking;

  Future<CheckResult> _checkAll(bool skipCompleted) async {
    running.value = true;
    final now = DateTime.now();
    final added = <NewChapter>[];
    final counts = <String, int>{};
    final problems = <String, CheckProblem>{};
    var reached = 0, failed = 0;
    try {
      final all = await store.list(all: true);
      final web = <LibraryEntry>[];
      for (final e in all) {
        if (!e.isWeb) continue;
        if (skipCompleted && e.finished && (await store.webNovel(e.id))?.novel.status == 'Completed') continue;
        web.add(e);
      }
      final browserSites = background ? await browserHosts(SourceEngine.instance.store.dir) : const <String>{};
      void problem(PluginInfo p, CheckProblemKind kind, String why, {String? url}) {
        final had = problems[p.id];
        problems[p.id] = CheckProblem(
          pluginId: p.id,
          source: p.name,
          novels: (had?.novels ?? 0) + 1,
          why: had?.why ?? why,
          kind: had?.kind ?? kind,
          url: had?.url ?? url,
        );
      }

      // One site at a time each, a few sites at once.
      final queue = [...web];
      final busy = <String>{};
      var done = 0;
      Future<void> lane() async {
        while (true) {
          final i = queue.indexWhere((e) => !busy.contains(e.plugin));
          if (i < 0) {
            if (queue.isEmpty) return;
            // Every waiting novel's site is being asked: wait for one.
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          final e = queue.removeAt(i);
          final site = e.plugin ?? '';
          busy.add(site);
          try {
            final name = store.isSecret(e.id) && !LibraryStore.secretOpen.value ? 'a novel' : e.title;
            status.value = 'Checking $name (${++done} of ${web.length})…';
            switch (await _checkOne(e, now, browserSites, problem)) {
              case (final found?, final count):
                reached++;
                added.addAll(found);
                if (count != null) counts[e.id] = count;
              case (null, _):
                failed++;
            }
          } finally {
            busy.remove(site);
          }
        }
      }

      await Future.wait([for (var i = 0; i < parallel; i++) lane()]);
      await _save(added, now, ok: reached > 0 || web.isEmpty, problems: problems.values.toList(), counts: counts);
    } finally {
      running.value = false;
      status.value = null;
    }
    return (found: added.length, checked: reached, failed: failed, added: added);
  }

  /// Check novel [e]: the chapters it gained (null when it could not be
  /// asked) and, away from the app, its new chapter count.
  Future<(List<NewChapter>?, int?)> _checkOne(
    LibraryEntry e,
    DateTime now,
    Set<String> browserSites,
    void Function(PluginInfo p, CheckProblemKind kind, String why, {String? url}) problem,
  ) async {
    final info = await store.webNovel(e.id);
    if (info == null) return (null, null);
    final known = info.plugin;
    final plugin = await SourceEngine.instance.store.installedById(known.id);
    if (plugin == null) {
      problem(known, CheckProblemKind.missing, '${known.name} is not installed.');
      return (null, null);
    }
    if (background) {
      // Left for the app: a site that needs its web view, and a novel whose
      // downloads an earlier change has still to put in place.
      if (browserSites.any((h) => sameSite(h, plugin.site))) {
        problem(plugin, CheckProblemKind.challenge, 'Its site wants a browser check, so it waits for the app.');
        return (null, null);
      }
      if (!info.filed) return (null, null);
    }
    try {
      final fresh = await SourceEngine.instance.novel(plugin, info.novel.path);
      final had = {for (final c in info.chapters) c.path};
      final found = <NewChapter>[];
      for (var n = 0; n < fresh.chapters.length; n++) {
        final c = fresh.chapters[n];
        if (!had.contains(c.path)) {
          found.add(NewChapter(bookId: e.id, title: e.title, index: n, path: c.path, name: c.name, foundAt: now));
        }
      }
      if (background) {
        final verdict = judgeChapterList(info.chapters, fresh.chapters, complete: fresh.complete);
        if (verdict.refused) {
          problem(plugin, CheckProblemKind.refused, verdict.why ?? '');
          return (const <NewChapter>[], null);
        }
        if (!verdict.taken) return (const <NewChapter>[], null);
        // Grown at the end only; anything else is the app's to take.
        if (!await store.appendWebChapters(e.id, info, fresh.chapters)) return (const <NewChapter>[], null);
        return (found, fresh.chapters.length);
      }
      // A list that looks wrong is not stored (the novel's page says why),
      // and its "new" chapters are not new.
      final verdict = await store.offerWebChapters(e.id, fresh.chapters, complete: fresh.complete);
      if (verdict.refused) problem(plugin, CheckProblemKind.refused, verdict.why ?? '');
      return (verdict.taken ? found : const <NewChapter>[], null);
    } on ChallengeException catch (err) {
      problem(plugin, CheckProblemKind.challenge, err.message, url: err.url);
    } on TamperedSourceException catch (err) {
      problem(plugin, CheckProblemKind.tampered, err.message);
    } on MissingSourceException catch (err) {
      problem(plugin, CheckProblemKind.missing, err.message);
    } on Object catch (err) {
      // One site being down does not stop the others.
      problem(plugin, CheckProblemKind.failed, friendlyError(err));
    }
    return (null, null);
  }

  Future<void> _save(
    List<NewChapter> added,
    DateTime now, {
    required bool ok,
    required List<CheckProblem> problems,
    Map<String, int> counts = const {},
  }) async {
    // Read again: a check in the other engine may have written since.
    final raw = await _raw();
    final items = [
      ...added.reversed,
      for (final o in raw['new'] as List? ?? const [])
        if (NewChapter.fromJson(o) case final c?) c,
    ];
    // Keep the log short: a month or 500 chapters, whichever is less.
    final cutoff = now.subtract(const Duration(days: 30));
    final kept = [for (final c in items) if (c.foundAt.isAfter(cutoff)) c].take(500).toList();
    final before = raw['counts'];
    await writeSafely(
      _log,
      jsonEncode({
        // Only a run that reached a site counts as a check: offline, the
        // next opening (or the next background run) tries again.
        'checked': ok ? now.toIso8601String() : raw['checked'],
        'attempted': now.toIso8601String(),
        'new': [for (final c in kept) c.toJson()],
        'problems': [for (final p in problems) p.toJson()],
        if (counts.isNotEmpty || before is Map) 'counts': {if (before is Map) ...before, ...counts},
      }),
    );
  }
}
