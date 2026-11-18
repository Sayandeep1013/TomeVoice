import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../download_queue.dart';
import '../../library_store.dart';
import '../../sources/models.dart' show ChapterItem;
import '../ai_keys.dart';
import '../ai_router.dart';
import 'memory_builder.dart';
import 'memory_db.dart';
import 'series.dart';
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
    this.begun = false,
    this.private = false,
  });

  /// The reader asked for it to be built: kept up from then on.
  final bool begun;

  /// The reader keeps this book away from the AI: nothing of it is sent.
  final bool private;

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
    bool? begun,
    bool? private,
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
        begun: begun ?? this.begun,
        private: private ?? this.private,
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
  bool begun,
  bool private,
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
      begun: m.meta('begun') == '1',
      private: m.meta('private') == '1',
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

// Off the UI thread's isolate, from functions of their own: a closure made
// in the service's methods would carry the service (and the library, and
// the zone it runs in), which cannot be sent to another isolate.
Future<_Read> _readOff(String path) => Isolate.run(() => _read(path));

Future<({int bytes, int noted})> _sizesOff(String dir, String path) => Isolate.run(() {
      var bytes = 0;
      final d = Directory(dir);
      if (d.existsSync()) {
        for (final f in d.listSync().whereType<File>()) {
          bytes += f.lengthSync();
        }
      }
      var noted = 0;
      if (File(path).existsSync()) {
        final m = MemoryDb.open(path);
        try {
          noted = m.db.select('SELECT count(*) n FROM chapters WHERE noted = 1').first['n'] as int;
        } finally {
          m.close();
        }
      }
      return (bytes: bytes, noted: noted);
    });

Future<Set<int>> _readChaptersOff(String path) => Isolate.run(() {
      if (!File(path).existsSync()) return <int>{};
      final m = MemoryDb.open(path);
      try {
        return {
          for (final r in m.db.select('SELECT ch FROM chapters WHERE indexed = 1 AND noted = 1')) r['ch'] as int,
        };
      } finally {
        m.close();
      }
    });

Future<int> _bytesOff(String dir, List<int> chapters) => Isolate.run(() {
      var bytes = 0;
      for (final c in chapters) {
        final f = File('$dir/$c.json');
        if (f.existsSync()) bytes += f.lengthSync();
      }
      return bytes;
    });

Future<bool> _pausedOff(String path) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        return m.meta('paused') == '1';
      } finally {
        m.close();
      }
    });

/// The first chapter (from 0) not in the word index: where a memory built
/// in order has to wait.
Future<int> _firstGapOff(String path) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        var gap = 0;
        for (final r in m.db.select('SELECT ch FROM chapters WHERE indexed = 1 ORDER BY ch')) {
          if (r['ch'] as int != gap) break;
          gap++;
        }
        return gap;
      } finally {
        m.close();
      }
    });

Future<void> _retrySkippedOff(String path) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        m.db.execute('UPDATE chapters SET note_error = NULL WHERE note_error IS NOT NULL');
      } finally {
        m.close();
      }
    });
Future<void> _setMetaOff(String path, String k, String? v) => Isolate.run(() => _setMeta(path, k, v));

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
    _store?.chapterSaved.removeListener(_onSaved);
    _store = store;
    _router = router;
    store.chapterSaved.addListener(_onSaved);
  }

  /// When each book was last kept up, and the wait after a web novel's
  /// chapters are saved (a download of many saves one by one).
  final _keptAt = <String, DateTime>{};
  final _afterSaves = <String, Timer>{};

  void _onSaved() {
    final saved = _store?.chapterSaved.value;
    if (saved == null) return;
    final id = saved.$1;
    // Not put off by every save: while a download goes on, what has come
    // joins the memory every twenty seconds or so.
    if (_afterSaves[id]?.isActive ?? false) return;
    _afterSaves[id] = Timer(const Duration(seconds: 20), () {
      _afterSaves.remove(id);
      unawaited(keepUp(id, force: true));
    });
  }

  /// A web novel's chapters up to where the reader is (or "I've read up
  /// to") that are not on the phone, nor waiting to download: to fetch
  /// before its memory is built. Empty for a book that is not a web novel.
  Future<List<ChapterItem>> missingChapters(String id) async {
    final store = _store;
    if (store == null) return const [];
    final info = await store.webNovel(id);
    if (info == null) return const [];
    final here = await hereOf(id);
    final read = _n(id).value.readUpTo;
    final upTo = math.max(here, read ?? 0);
    final on = store.downloadedChapters(id);
    final waiting = DownloadQueue.instance.waitingPaths(id);
    return [
      for (var i = 0; i <= upTo && i < info.chapters.length; i++)
        if (!on.contains(i) && !waiting.contains(info.chapters[i].path)) info.chapters[i],
    ];
  }

  /// A web novel's chapters: how many it has, how many are on the phone and
  /// the space they take, and how many the memory has read (null for a book
  /// that is not a web novel).
  Future<({int total, int onPhone, int bytes, int noted})?> chaptersOf(String id) async {
    final store = _store;
    if (store == null) return null;
    final info = await store.webNovel(id);
    if (info == null) return null;
    final dir = '${store.bookDir(id)}/ch';
    final path = _path(id);
    final r = await _sizesOff(dir, path);
    return (total: info.chapters.length, onPhone: store.downloadedChapters(id).length, bytes: r.bytes, noted: r.noted);
  }

  /// Every chapter of web novel [id] not on the phone, to the download
  /// queue (one at a time, gently on the site); they join the memory as they
  /// come. How many were queued.
  Future<int> downloadAll(String id) async {
    final info = await _store?.webNovel(id);
    if (info == null) return 0;
    return DownloadQueue.instance.add(id, info.chapters);
  }

  /// The downloaded chapters of web novel [id] the memory has already read
  /// (in its word index, with notes) taken off the phone: the memory keeps
  /// its own copy of their words, and a chapter opened to read is fetched
  /// again. How many, and the space freed.
  Future<({int chapters, int bytes})> freeSpace(String id) async {
    final store = _store;
    if (store == null) return (chapters: 0, bytes: 0);
    final path = _path(id);
    final read = await _readChaptersOff(path);
    final gone = [for (final c in store.downloadedChapters(id)) if (read.contains(c)) c];
    if (gone.isEmpty) return (chapters: 0, bytes: 0);
    final dir = '${store.bookDir(id)}/ch';
    final bytes = await _bytesOff(dir, gone);
    await store.deleteChapters(id, gone);
    return (chapters: gone.length, bytes: bytes);
  }

  /// The chapters the Builder passed over, tried again.
  Future<void> retrySkipped(String id) async {
    await _retrySkippedOff(_path(id));
    await refresh(id);
    await build(id);
  }

  /// [chapters] of [id] sent to the download queue (one at a time, gentle
  /// on the site); as they come they join the memory.
  Future<int> download(String id, List<ChapterItem> chapters) => DownloadQueue.instance.add(id, chapters);

  /// A book whose memory the reader has begun is kept up as they read: its
  /// new chapters (read, or downloaded) indexed and noted. Not a book never
  /// built (no quota spent on it unasked), and not while another book's
  /// memory is being built (that one goes on first). At most every minute
  /// and a half, unless [force].
  Future<void> keepUp(String id, {bool force = false}) async {
    final store = _store;
    if (store == null || !AiRing.instance.hasKeys) return;
    if (!File(_path(id)).existsSync()) return;
    final last = _keptAt[id];
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 90)) return;
    if (_builders.values.any((b) => b.running) || _wakes.isNotEmpty) return;
    await refresh(id);
    if (!maySend(id)) return;
    if (_n(id).value.noted == 0 && !_n(id).value.begun) return;
    // Paused by the reader: it waits for them.
    if (_paused.contains(id) || await _pausedOff(_path(id))) {
      _paused.add(id);
      return;
    }
    _keptAt[id] = DateTime.now();
    await build(id);
  }

  @visibleForTesting
  void reset() {
    _store?.chapterSaved.removeListener(_onSaved);
    for (final t in _afterSaves.values) {
      t.cancel();
    }
    _afterSaves.clear();
    _keptAt.clear();
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

  /// Book [id]'s memory file.
  String pathOf(String id) => _path(id);

  /// The books with a memory (not on a shut secret shelf), each with its
  /// state kept up to date: for the AI page's list.
  Future<List<LibraryEntry>> booksWithMemory() async {
    final store = _store;
    if (store == null) return const [];
    final shown = await store.list();
    return [
      for (final e in shown)
        if (File(_path(e.id)).existsSync()) e,
    ];
  }

  /// The spoiler line of [id] away from the reader: with the guard on, the
  /// furthest of where the reader is and "I've read up to"; null when off.
  Future<int?> lineOf(String id) async {
    final s = _n(id).value;
    if (_store == null || !s.guard) return null;
    final here = await hereOf(id);
    final read = s.readUpTo;
    return read == null || read < here ? here : read;
  }

  /// The chapter the reader is at in [id], in the memory's numbering.
  Future<int> hereOf(String id) async {
    final store = _store;
    if (store == null) return 0;
    final entry = (await store.list(all: true)).where((e) => e.id == id).firstOrNull;
    final cursor = await store.cursorFor(id);
    var here = 0;
    if (entry != null) {
      if (entry.isWeb) {
        here = cursor.sectionIndex;
      } else {
        final l = await store.loadLayout(id);
        if (!l.isEmpty) here = l.unitChapter[l.unitForCursor(cursor, saved: true).clamp(0, l.units.length - 1)];
      }
    }
    return here;
  }

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
    final r = await _readOff(path);
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
      begun: r.begun,
      private: r.private,
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
  bool maySend(String id) => !(_store?.isSecret(id) ?? true) && !_n(id).value.private;

  /// Keep [id] away from the AI (nothing of it sent, built or talked
  /// about), or let it read the book again.
  Future<void> setPrivate(String id, bool private) async {
    if (private) pause(id);
    final path = _path(id);
    await _setMetaOff(path, 'private', private ? '1' : null);
    _n(id).value = _n(id).value.copyWith(exists: true, private: private);
  }

  /// Builds [id]'s memory: the word index, then the notes, until done,
  /// paused, or every key rests (and then again when one wakes).
  Future<void> build(String id) async {
    if (!maySend(id) || !AiRing.instance.hasKeys) return;
    _wakes.remove(id)?.cancel();
    // One book at a time: the others wait their turn.
    for (final e in _builders.entries) {
      if (e.key != id && e.value.running) e.value.pause();
    }
    // Asked to build: a pause the reader made is over.
    if (_paused.remove(id) || File(_path(id)).existsSync()) {
      if (File(_path(id)).existsSync()) await _setMetaOff(_path(id), 'paused', null);
    }
    if (_n(id).value.indexing == null) await index(id);
    // The library closed meanwhile (a restore, a test's end): nothing more.
    if (_store == null) return;
    if (!_n(id).value.begun) {
      final path = _path(id);
      await _setMetaOff(path, 'begun', '1');
      _n(id).value = _n(id).value.copyWith(begun: true);
    }
    // While its chapters are still downloading (one by one, from the
    // first), only up to the first not yet on the phone: the memory is made
    // in the story's order, a rank before it changes, a meeting before the
    // falling-out. Once nothing waits, the rest, wherever it is.
    final waiting = (DownloadQueue.instance.of(id)?.waiting ?? 0) > 0;
    final builder = _builder(id);
    builder.upTo = waiting ? await _firstGapOff(_path(id)) - 1 : null;
    final s = await builder.run();
    await refresh(id);
    if (s.phase == BuildPhase.resting && s.until != null) {
      final wait = s.until!.difference(DateTime.now());
      _wakes[id] = Timer(wait.isNegative ? Duration.zero : wait + const Duration(seconds: 5), () {
        _wakes.remove(id);
        unawaited(build(id));
      });
    }
  }

  /// Stops [id]'s building, and keeps it stopped (kept up as it is read,
  /// or built with the app closed, neither) until the reader goes on.
  void pause(String id) {
    _wakes.remove(id)?.cancel();
    _builders[id]?.pause();
    _paused.add(id);
    final store = _store;
    if (store != null && File(_path(id)).existsSync()) unawaited(_setMetaOff(_path(id), 'paused', '1'));
  }

  final _paused = <String>{};

  bool isBuilding(String id) => _builders[id]?.running ?? false;

  /// The spoiler guard for [id]: on, the AI keeps to what was read.
  Future<void> setGuard(String id, bool on) async {
    final path = _path(id);
    await _setMetaOff(path, 'guard', on ? 'on' : null);
    _n(id).value = _n(id).value.copyWith(exists: true, guard: on);
  }

  /// "I've read up to chapter [ch]" (0-based), or null to go by the place.
  Future<void> setReadUpTo(String id, int? ch) async {
    final path = _path(id);
    await _setMetaOff(path, 'readUpTo', ch?.toString());
    _n(id).value = _n(id).value.copyWith(exists: true, readUpTo: ch, clearReadUpTo: ch == null);
  }

  /// [id]'s memory made to follow on from [previous]'s (the book before it
  /// in a series): its cast, how they stood, open threads and story carried
  /// over. How many people and things came over.
  Future<int> followOnFrom(String id, String previous) async {
    final path = _path(id);
    final n = await followOnOff(path, _path(previous));
    await _setMetaOff(path, 'follows', previous);
    await refresh(id);
    return n;
  }

  /// [id]'s memory deleted, all of it.
  Future<void> forget(String id) async {
    pause(id);
    // A batch on its way would write into the new, empty memory: wait for
    // it to come back first (a minute at most).
    final b = _builders.remove(id);
    for (var i = 0; b != null && b.running && i < 240; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _paused.remove(id);
    final f = File(_path(id));
    if (await f.exists()) await f.delete();
    _n(id).value = const BookMemoryState();
  }
}
