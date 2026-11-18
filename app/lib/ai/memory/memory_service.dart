import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../library_store.dart';
import '../ai_keys.dart';
import '../ai_router.dart';
import 'memory_builder.dart';
import 'memory_db.dart';
import 'word_index.dart';

/// Where a book's memory stands, as its page shows it.
@immutable
class BookMemoryState {
  const BookMemoryState({
    this.exists = false,
    this.indexed = 0,
    this.noted = 0,
    this.skipped = 0,
    this.entities = 0,
    this.lastNoted,
    this.indexing,
    this.build = const BuildState(),
    this.guard = false,
    this.readUpTo,
    this.bytes = 0,
  });

  final bool exists;

  /// Chapters in the word index, with notes, passed over.
  final int indexed;
  final int noted;
  final int skipped;

  /// People, places and things in the graph.
  final int entities;
  final int? lastNoted;

  /// The word index being made: how far.
  final IndexProgress? indexing;
  final BuildState build;

  /// The spoiler guard: the AI kept to what was read. Off unless turned on.
  final bool guard;

  /// "I've read up to chapter N" (0-based), for a book read elsewhere first.
  final int? readUpTo;
  final int bytes;

  bool get building => build.phase == BuildPhase.running || indexing != null;

  BookMemoryState copyWith({
    bool? exists,
    int? indexed,
    int? noted,
    int? skipped,
    int? entities,
    int? lastNoted,
    IndexProgress? indexing,
    bool clearIndexing = false,
    BuildState? build,
    bool? guard,
    int? readUpTo,
    bool clearReadUpTo = false,
    int? bytes,
  }) =>
      BookMemoryState(
        exists: exists ?? this.exists,
        indexed: indexed ?? this.indexed,
        noted: noted ?? this.noted,
        skipped: skipped ?? this.skipped,
        entities: entities ?? this.entities,
        lastNoted: lastNoted ?? this.lastNoted,
        indexing: clearIndexing ? null : (indexing ?? this.indexing),
        build: build ?? this.build,
        guard: guard ?? this.guard,
        readUpTo: clearReadUpTo ? null : (readUpTo ?? this.readUpTo),
        bytes: bytes ?? this.bytes,
      );
}

typedef _Read = ({
  int indexed,
  int noted,
  int skipped,
  int entities,
  int? lastNoted,
  bool guard,
  int? readUpTo,
  int bytes,
});

_Read _read(String path) {
  final m = MemoryDb.open(path);
  try {
    final c = m.db
        .select('SELECT count(*) n, sum(noted) noted, sum(note_error IS NOT NULL) skipped, '
            'max(CASE WHEN noted = 1 THEN ch END) last FROM chapters WHERE indexed = 1')
        .first;
    final e = m.db.select('SELECT count(*) n FROM entities WHERE merged_into IS NULL').first;
    return (
      indexed: c['n'] as int,
      noted: (c['noted'] as int?) ?? 0,
      skipped: (c['skipped'] as int?) ?? 0,
      entities: e['n'] as int,
      lastNoted: c['last'] as int?,
      guard: m.meta('guard') == 'on',
      readUpTo: int.tryParse(m.meta('readUpTo') ?? ''),
      bytes: m.bytes,
    );
  } finally {
    m.close();
  }
}

void _setMeta(String path, String k, String? v) {
  final m = MemoryDb.open(path);
  try {
    m.setMeta(k, v);
  } finally {
    m.close();
  }
}

/// Every book's memory, for the pages that show it and the work that makes
/// it: the word index made on the phone, then the Builder's notes, one book
/// built at a time (so keys' quotas go to one book until it is done). A
/// build that stops because every key rests goes on by itself when the
/// first wakes, while the app is open.
class MemoryService {
  MemoryService._();

  static final instance = MemoryService._();

  LibraryStore? _store;
  AiRouter? _router;

  final _states = <String, ValueNotifier<BookMemoryState>>{};
  final _builders = <String, MemoryBuilder>{};
  final _wakes = <String, Timer>{};

  void attach(LibraryStore store, {AiRouter? router}) {
    _store = store;
    _router = router;
  }

  @visibleForTesting
  void reset() {
    for (final t in _wakes.values) {
      t.cancel();
    }
    _wakes.clear();
    for (final b in _builders.values) {
      b.pause();
    }
    _builders.clear();
    _states.clear();
    _store = null;
    _router = null;
  }

  String _path(String id) => MemoryDb.pathIn(_store!.bookDir(id));

  /// Book [id]'s memory, kept up to date while it is watched.
  ValueListenable<BookMemoryState> stateOf(String id) {
    final had = _states[id];
    if (had != null) return had;
    final n = _states[id] = ValueNotifier(const BookMemoryState());
    unawaited(refresh(id));
    return n;
  }

  ValueNotifier<BookMemoryState> _n(String id) => _states[id] ??= ValueNotifier(const BookMemoryState());

  Future<void> refresh(String id) async {
    final store = _store;
    if (store == null) return;
    final path = _path(id);
    if (!File(path).existsSync()) {
      _n(id).value = _n(id).value.copyWith(exists: false, indexed: 0, noted: 0, entities: 0, bytes: 0);
      return;
    }
    final r = await Isolate.run(() => _read(path));
    final n = _n(id);
    n.value = n.value.copyWith(
      exists: true,
      indexed: r.indexed,
      noted: r.noted,
      skipped: r.skipped,
      entities: r.entities,
      lastNoted: r.lastNoted,
      guard: r.guard,
      readUpTo: r.readUpTo,
      clearReadUpTo: r.readUpTo == null,
      bytes: r.bytes,
    );
  }

  /// The word index of [id] brought up to date (free, on the phone).
  Future<void> index(String id) async {
    final store = _store;
    if (store == null) return;
    final n = _n(id);
    n.value = n.value.copyWith(indexing: const IndexProgress(0, 0));
    try {
      await WordIndexer(store).index(id, onProgress: (p) => n.value = n.value.copyWith(indexing: p));
    } finally {
      n.value = n.value.copyWith(clearIndexing: true);
      await refresh(id);
    }
  }

  MemoryBuilder _builder(String id) => _builders[id] ??= () {
        final b = MemoryBuilder(path: _path(id), router: _router);
        b.state.addListener(() {
          final n = _n(id);
          n.value = n.value.copyWith(
            build: b.state.value,
            noted: b.state.value.noted,
            skipped: b.state.value.skipped,
          );
        });
        return b;
      }();

  /// What building the rest of [id]'s memory would take; the word index is
  /// made first.
  Future<BuildEstimate> estimate(String id) async {
    await index(id);
    return _builder(id).estimate();
  }

  /// Whether [id] may be sent to a provider at all: never from a secret
  /// shelf.
  bool maySend(String id) => !(_store?.isSecret(id) ?? true);

  /// Builds [id]'s memory: the word index, then the notes, until done,
  /// paused, or every key rests (and then again when one wakes).
  Future<void> build(String id) async {
    if (!maySend(id) || !AiRing.instance.hasKeys) return;
    _wakes.remove(id)?.cancel();
    // One book at a time: the others wait their turn.
    for (final e in _builders.entries) {
      if (e.key != id && e.value.running) e.value.pause();
    }
    if (_n(id).value.indexing == null) await index(id);
    final s = await _builder(id).run();
    await refresh(id);
    if (s.phase == BuildPhase.resting && s.until != null) {
      final wait = s.until!.difference(DateTime.now());
      _wakes[id] = Timer(wait.isNegative ? Duration.zero : wait + const Duration(seconds: 5), () {
        _wakes.remove(id);
        unawaited(build(id));
      });
    }
  }

  void pause(String id) {
    _wakes.remove(id)?.cancel();
    _builders[id]?.pause();
  }

  bool isBuilding(String id) => _builders[id]?.running ?? false;

  /// The spoiler guard for [id]: on, the AI keeps to what was read.
  Future<void> setGuard(String id, bool on) async {
    final path = _path(id);
    await Isolate.run(() => _setMeta(path, 'guard', on ? 'on' : null));
    _n(id).value = _n(id).value.copyWith(exists: true, guard: on);
  }

  /// "I've read up to chapter [ch]" (0-based), or null to go by the place.
  Future<void> setReadUpTo(String id, int? ch) async {
    final path = _path(id);
    await Isolate.run(() => _setMeta(path, 'readUpTo', ch?.toString()));
    _n(id).value = _n(id).value.copyWith(exists: true, readUpTo: ch, clearReadUpTo: ch == null);
  }

  /// [id]'s memory deleted, all of it.
  Future<void> forget(String id) async {
    pause(id);
    _builders.remove(id);
    final f = File(_path(id));
    if (await f.exists()) await f.delete();
    _n(id).value = const BookMemoryState();
  }
}
