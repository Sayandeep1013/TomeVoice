import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'library_store.dart';
import 'sources/models.dart';
import 'sources/source_engine.dart';

/// A chapter a source added since the last check.
class NewChapter {
  const NewChapter({
    required this.bookId,
    required this.title,
    required this.index,
    required this.name,
    required this.foundAt,
  });

  final String bookId;
  final String title;
  final int index;
  final String name;
  final DateTime foundAt;

  Map<String, Object?> toJson() => {
        'book': bookId,
        'title': title,
        'index': index,
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
      name: o['name'] as String? ?? '',
      foundAt: found,
    );
  }
}

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
class Updates {
  Updates(this.store);

  final LibraryStore store;

  /// True while a check is running.
  final running = ValueNotifier<bool>(false);

  /// "Checking Shadow Slave (3 of 7)…" while running.
  final status = ValueNotifier<String?>(null);

  File get _log => File('${store.root.path}/updates.json');

  /// Newest first.
  Future<List<NewChapter>> recent() async => (await log()).items;

  Future<DateTime?> lastChecked() async => (await log()).checked;

  /// The new chapters, newest first, and when the sites were last asked:
  /// the log read once for both, as the Updates screen wants them together.
  Future<({List<NewChapter> items, DateTime? checked})> log() async {
    try {
      if (!await _log.exists()) return (items: const <NewChapter>[], checked: null);
      final raw = jsonDecode(await _log.readAsString()) as Map;
      return (
        items: [
          for (final o in raw['new'] as List? ?? const [])
            if (NewChapter.fromJson(o) case final c?) c,
        ],
        checked: DateTime.tryParse(raw['checked'] as String? ?? ''),
      );
    } on Object {
      return (items: const <NewChapter>[], checked: null);
    }
  }

  Future<void> _save(List<NewChapter> items, DateTime checked) async {
    // Keep the log short: a month or 500 chapters, whichever is less.
    final cutoff = checked.subtract(const Duration(days: 30));
    final kept = [for (final c in items) if (c.foundAt.isAfter(cutoff)) c].take(500).toList();
    await _log.writeAsString(jsonEncode({
      'checked': checked.toIso8601String(),
      'new': [for (final c in kept) c.toJson()],
    }));
  }

  /// Check now if the last check is older than [every] (or never ran).
  Future<int> checkIfDue(UpdateEvery every) async {
    final interval = every.interval;
    if (interval == null) return 0;
    final last = await lastChecked();
    if (last != null && DateTime.now().difference(last) < interval) return 0;
    return checkAll();
  }

  /// Ask every web novel's source for its chapter list. Finished novels and
  /// ones whose source is no longer installed are skipped. Returns how many
  /// new chapters were found.
  Future<int> checkAll({bool skipCompleted = true}) =>
      // A pull while the check on opening still runs waits for that one, so
      // the spinner stays until it ends and the count is the real one.
      _checking ??= _checkAll(skipCompleted).whenComplete(() => _checking = null);

  Future<int>? _checking;

  Future<int> _checkAll(bool skipCompleted) async {
    running.value = true;
    var found = 0;
    try {
      final now = DateTime.now();
      // Secret shelves' novels are checked too, but not named while they run.
      final web = [for (final e in await store.list(all: true)) if (e.isWeb) e];
      final log = [...await recent()];
      for (var i = 0; i < web.length; i++) {
        final e = web[i];
        final name = store.isSecret(e.id) && !LibraryStore.secretOpen.value ? 'a novel' : e.title;
        status.value = 'Checking $name (${i + 1} of ${web.length})…';
        final info = await store.webNovel(e.id);
        if (info == null) continue;
        if (skipCompleted && info.novel.status == 'Completed' && e.finished) continue;
        final PluginInfo? plugin = await SourceEngine.instance.store.installedById(info.plugin.id);
        if (plugin == null) continue;
        try {
          final fresh = await SourceEngine.instance.novel(plugin, info.novel.path);
          final had = {for (final c in info.chapters) c.path};
          final added = <NewChapter>[];
          for (var n = 0; n < fresh.chapters.length; n++) {
            final c = fresh.chapters[n];
            if (!had.contains(c.path)) {
              added.add(NewChapter(bookId: e.id, title: e.title, index: n, name: c.name, foundAt: now));
            }
          }
          // A list that looks wrong is not stored (the novel's page says
          // why), and its "new" chapters are not new.
          final verdict = await store.offerWebChapters(e.id, fresh.chapters, complete: fresh.complete);
          if (verdict.taken && added.isNotEmpty) {
            log.insertAll(0, added.reversed);
            found += added.length;
          }
        } on Object {
          // One site being down does not stop the others.
        }
      }
      await _save(log, now);
    } finally {
      running.value = false;
      status.value = null;
    }
    return found;
  }
}
