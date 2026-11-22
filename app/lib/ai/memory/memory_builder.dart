import 'dart:async';
import 'dart:io' show File;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai_client.dart';
import '../ai_keys.dart';
import '../ai_router.dart';
import 'cast_tidy.dart';
import 'chapter_notes.dart';
import 'graph.dart';
import 'meaning.dart';
import 'memory_db.dart';
import 'theories.dart';

/// A batch of chapters ready to send: the prompt, and where each chapter's
/// passages start, to place what the notes say.
class _Batch {
  const _Batch({required this.chapters, required this.prompt, required this.passages, required this.chars});

  final List<int> chapters;
  final String prompt;
  final Map<int, List<MemoryPlace>> passages;
  final int chars;
}

/// How far a book's memory is built, and what its Builder is doing.
enum BuildPhase { idle, running, resting, paused, done, failed }

@immutable
class BuildState {
  const BuildState({
    this.phase = BuildPhase.idle,
    this.noted = 0,
    this.total = 0,
    this.skipped = 0,
    this.until,
    this.error,
  });

  final BuildPhase phase;
  final int noted;
  final int total;

  /// Chapters the Builder could not make notes for, after trying.
  final int skipped;

  /// Resting: when the first key wakes.
  final DateTime? until;
  final String? error;

  BuildState copyWith({BuildPhase? phase, int? noted, int? total, int? skipped, DateTime? until, String? error}) =>
      BuildState(
        phase: phase ?? this.phase,
        noted: noted ?? this.noted,
        total: total ?? this.total,
        skipped: skipped ?? this.skipped,
        until: until,
        error: error,
      );
}

/// What building the rest of a memory would take, told before it starts.
@immutable
class BuildEstimate {
  const BuildEstimate({required this.chapters, required this.inputTokens, required this.outputTokens, required this.calls});

  final int chapters;
  final int inputTokens;
  final int outputTokens;
  final int calls;

  int get tokens => inputTokens + outputTokens;
}

/// How much a call may carry, by the Builder's first key: a long-context
/// provider takes several chapters at once.
({int tokens, int chapters}) batchSizeFor(AiKey? key) => switch (key?.provider) {
      AiProvider.gemini || AiProvider.inception => (tokens: 40000, chapters: 8),
      _ => (tokens: 12000, chapters: 2),
    };

/// Notes guessed at, a chapter: what the Builder writes back.
const _outputPerChapter = 1800;

/// The next chapters with no notes, in reading order, up to [upTo], as one
/// batch of at most [tokens] (a chapter longer than that goes alone).
_Batch? _nextBatch(String path, int? upTo, int tokens, int maxChapters) {
  final m = MemoryDb.open(path);
  try {
    final todo = [
      for (final r in m.db.select(
        'SELECT ch, title FROM chapters WHERE indexed = 1 AND noted = 0 AND note_error IS NULL'
        '${upTo == null ? '' : ' AND ch <= $upTo'} ORDER BY ch LIMIT ?',
        [maxChapters],
      ))
        (ch: r['ch'] as int, title: r['title'] as String? ?? ''),
    ];
    if (todo.isEmpty) return null;
    final chapters = <int>[];
    final parts = <String>[];
    final passages = <int, List<MemoryPlace>>{};
    var chars = 0;
    for (final c in todo) {
      final chunks = m.chapterText(c.ch);
      final size = chunks.fold<int>(0, (n, t) => n + t.text.length + 8);
      if (chapters.isNotEmpty && (chars + size) / 4 > tokens) break;
      chapters.add(c.ch);
      passages[c.ch] = [for (final t in chunks) t.start];
      parts.add(chapterForBuilder(c.ch, c.title, [for (final t in chunks) t.text]));
      chars += size;
    }
    final text = parts.join('\n');
    final context = BookGraph(m).contextFor(chapters, text).render();
    return _Batch(
      chapters: chapters,
      prompt: '$context\nThe chapters:\n\n$text',
      passages: passages,
      chars: chars + context.length,
    );
  } finally {
    m.close();
  }
}

/// The chapters a summary of the story so far covers: 25 chapters at the
/// first level, ten of those (250) at the second.
const arcSpan = {1: 25, 2: 250};

/// The next part of the story due its summary: a span of chapters whose
/// chapters (those on the phone) all have notes, and that the reading has
/// gone past; with what it is made from (the chapters' summaries, or the
/// first level's). Null when none is due.
({int level, int from, int to, String text})? _nextArc(String path) {
  final m = MemoryDb.open(path);
  try {
    final last = m.db.select('SELECT max(ch) last FROM chapters WHERE indexed = 1').first['last'] as int?;
    if (last == null) return null;
    for (final level in [1, 2]) {
      final span = arcSpan[level]!;
      for (var from = 0; from + span - 1 < last; from += span) {
        final to = from + span - 1;
        if (m.db.select('SELECT 1 FROM arcs WHERE level = ? AND from_ch = ?', [level, from]).isNotEmpty) continue;
        final waiting = m.db.select(
          'SELECT count(*) n FROM chapters WHERE indexed = 1 AND noted = 0 AND note_error IS NULL AND ch BETWEEN ? AND ?',
          [from, to],
        ).first['n'] as int;
        if (waiting > 0) continue;
        final parts = level == 1
            ? [
                for (final r in m.db.select('SELECT ch, summary FROM notes WHERE ch BETWEEN ? AND ? ORDER BY ch', [from, to]))
                  'Chapter ${(r['ch'] as int) + 1}: ${r['summary']}',
              ]
            : [
                for (final r in m.db.select(
                    'SELECT from_ch, to_ch, summary FROM arcs WHERE level = 1 AND from_ch BETWEEN ? AND ? ORDER BY from_ch',
                    [from, to]))
                  'Chapters ${(r['from_ch'] as int) + 1} to ${(r['to_ch'] as int) + 1}: ${r['summary']}',
              ];
        // The second level waits for all ten of the first.
        if (level == 2 && parts.length < span ~/ arcSpan[1]!) continue;
        if (parts.isEmpty) continue;
        return (level: level, from: from, to: to, text: parts.join('\n'));
      }
    }
    return null;
  } finally {
    m.close();
  }
}

void _keepArc(String path, int level, int from, int to, String summary) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute(
      'INSERT INTO arcs(level, from_ch, to_ch, summary) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(level, from_ch) DO UPDATE SET to_ch = excluded.to_ch, summary = excluded.summary',
      [level, from, to, summary],
    );
  } finally {
    m.close();
  }
}

void _merge(String path, List<ChapterNotes> notes, Map<int, List<MemoryPlace>> passages, String? model) {
  // Forgotten while this batch was out: opening the path would make a new,
  // empty memory with only this batch's people in it.
  if (!File(path).existsSync()) return;
  final m = MemoryDb.open(path);
  try {
    final g = BookGraph(m);
    m.inTransaction(() {
      final made = <String, int>{};
      for (final n in notes) {
        // Noted meanwhile by another run (the closed-app build, and the
        // app's own just after it): kept as it was, never merged twice.
        if (m.db.select('SELECT 1 FROM chapters WHERE ch = ? AND noted = 1', [n.chapter]).isNotEmpty) continue;
        g.apply(n, passages[n.chapter] ?? const [], made, model: model);
      }
    });
  } finally {
    m.close();
  }
}

void _markFailed(String path, int ch, String why) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute('UPDATE chapters SET note_error = ? WHERE ch = ?', [why, ch]);
  } finally {
    m.close();
  }
}

({int noted, int total, int skipped}) _counts(String path, int? upTo) {
  final m = MemoryDb.open(path);
  try {
    final r = m.db
        .select('SELECT count(*) total, sum(noted) noted, sum(note_error IS NOT NULL) skipped FROM chapters '
            'WHERE indexed = 1${upTo == null ? '' : ' AND ch <= $upTo'}')
        .first;
    return (noted: (r['noted'] as int?) ?? 0, total: r['total'] as int, skipped: (r['skipped'] as int?) ?? 0);
  } finally {
    m.close();
  }
}

BuildEstimate _estimate(String path, int? upTo, int tokens, int maxChapters) {
  final m = MemoryDb.open(path);
  try {
    final rows = m.db.select(
      'SELECT c.ch, r.chars FROM chapters c LEFT JOIN chapter_rows r ON r.ch = c.ch '
      'WHERE c.indexed = 1 AND c.noted = 0 AND c.note_error IS NULL${upTo == null ? '' : ' AND c.ch <= $upTo'} '
      'ORDER BY c.ch',
    );
    var input = 0, calls = 0, inBatch = 0, batchTokens = 0;
    for (final r in rows) {
      final t = (((r['chars'] as int?) ?? 0) / 4).ceil();
      if (inBatch > 0 && (batchTokens + t > tokens || inBatch >= maxChapters)) {
        calls++;
        inBatch = 0;
        batchTokens = 0;
      }
      inBatch++;
      batchTokens += t;
      input += t;
    }
    if (inBatch > 0) calls++;
    // Each call also carries the instructions and the cast it is told of.
    input += calls * 3500;
    return BuildEstimate(
      chapters: rows.length,
      inputTokens: input,
      outputTokens: rows.length * _outputPerChapter,
      calls: calls,
    );
  } finally {
    m.close();
  }
}

// Work on another isolate, each closure made here from plain values: one
// made in a builder's method that also has a closure using `this` (a
// router call) would carry the builder, which cannot be sent.
Future<BuildEstimate> _estimateOff(String p, int? u, int tokens, int chapters) =>
    Isolate.run(() => _estimate(p, u, tokens, chapters));
Future<({int noted, int total, int skipped})> _countsOff(String p, int? u) => Isolate.run(() => _counts(p, u));
Future<({int level, int from, int to, String text})?> _nextArcOff(String p) => Isolate.run(() => _nextArc(p));
Future<bool> _tidyDueOff(String p) => Isolate.run(() => castTidyDue(p));
Future<void> _markTidiedOff(String p) => Isolate.run(() => markCastTidied(p));
Future<_Batch?> _nextBatchOff(String p, int? u, int tokens, int most) =>
    Isolate.run(() => _nextBatch(p, u, tokens, most));
Future<void> _markFailedOff(String p, int ch, String why) => Isolate.run(() => _markFailed(p, ch, why));
Future<void> _keepArcOff(String p, int level, int from, int to, String text) =>
    Isolate.run(() => _keepArc(p, level, from, to, text));
Future<List<MeaningItem>> _pendingOff(String p, String model) => Isolate.run(() => pendingMeaning(p, model, limit: 64));
Future<void> _keepVectorsOff(String p, String model, List<MeaningItem> items, List<List<double>> v) =>
    Isolate.run(() => keepVectors(p, model, items, v));
Future<List<({int id, String text, int ch})>> _openTheoriesOff(String p) => Isolate.run(() => openTheories(p));
Future<String> _forCheckOff(String p, List<int> chapters) => Isolate.run(() => chaptersForCheck(p, chapters));
Future<void> _verdictOff(String p, int id, String status, int at, String why) =>
    Isolate.run(() => keepVerdict(p, id, status, at, why));
Future<void> _mergeOff(String p, List<ChapterNotes> notes, Map<int, List<MemoryPlace>> places, String? model) =>
    Isolate.run(() => _merge(p, notes, places, model));

/// Builds one book's memory: the chapters in the word index that have no
/// notes yet, a batch at a time, in reading order (the graph of chapter N
/// is what chapter N+1 is linked against), each batch's notes merged in
/// one transaction. A batch the model answers badly is asked again once
/// with what was wrong, then halved; a chapter that fails alone is marked
/// and passed over. When every key rests, it stops and says until when.
class MemoryBuilder {
  MemoryBuilder({required this.path, AiRouter? router, this.upTo, this.limits})
      : router = router ?? AiRouter();

  final String path;
  final AiRouter router;

  /// Build no further than this chapter (null: all on the phone). Set
  /// while a web novel's chapters are still downloading, to the chapter
  /// before the first not yet on the phone, so the memory is built in the
  /// story's order.
  int? upTo;

  /// The batch size, when not taken from the Builder's key.
  final ({int tokens, int chapters})? limits;

  final state = ValueNotifier(const BuildState());
  bool _stop = false;
  bool _running = false;

  bool get running => _running;

  /// Paused, and landing the batch on its way.
  bool get stopping => _running && _stop;

  ({int tokens, int chapters}) get _limits =>
      limits ?? batchSizeFor(router.ring.forJob(AiJob.builder).firstOrNull);

  Future<BuildEstimate> estimate() {
    final l = _limits;
    final p = path, u = upTo;
    return _estimateOff(p, u, l.tokens, l.chapters);
  }

  Future<void> refreshCounts() async {
    final p = path, u = upTo;
    final c = await _countsOff(p, u);
    state.value = state.value.copyWith(
        phase: state.value.phase, noted: c.noted, total: c.total, skipped: c.skipped, until: state.value.until);
  }

  /// Stops after the batch in flight; what it brings is kept.
  void pause() {
    _stop = true;
    if (!_running) state.value = state.value.copyWith(phase: BuildPhase.paused);
  }

  /// Runs until the memory is built, it is paused, or every key rests.
  Future<BuildState> run() async {
    if (_running) return state.value;
    _running = true;
    _stop = false;
    try {
      await refreshCounts();
      state.value = state.value.copyWith(phase: BuildPhase.running);
      final l = _limits;
      final p = path, u = upTo;
      var tokens = l.tokens, most = l.chapters;
      while (!_stop) {
        // The story so far kept up as it goes: a span's summary once its
        // chapters all have notes.
        final arc = await _nextArcOff(p);
        if (arc != null) {
          if (!await _summarise(arc)) return state.value;
          continue;
        }
        // The cast tidied now and then, and when the book is done: one
        // character split over two cards made one, names on the wrong card
        // taken off.
        if (await _tidyDueOff(p)) {
          if (!await _tidy()) return state.value;
          continue;
        }
        final batch = await _nextBatchOff(p, u, tokens, most);
        if (batch == null) {
          await refreshCounts();
          state.value = state.value.copyWith(phase: BuildPhase.done);
          return state.value;
        }
        final ok = await _send(batch);
        if (ok == null) return state.value; // resting or failed
        if (!ok) {
          // Halve the batch and try again; one chapter alone is marked.
          if (batch.chapters.length > 1) {
            most = math.max(1, batch.chapters.length ~/ 2);
            continue;
          }
          final ch = batch.chapters.single;
          await _markFailedOff(p, ch, 'The notes could not be made');
        } else {
          most = l.chapters;
          tokens = l.tokens;
          await _checkTheories(batch.chapters);
          await _embed();
        }
        await refreshCounts();
      }
      state.value = state.value.copyWith(phase: BuildPhase.paused);
      return state.value;
    } on Object catch (e) {
      // Anything not foreseen (a reply of an odd shape, the memory file
      // busy): the build stops and says so, with "Go on building", rather
      // than leaving the page at "Building" with nothing going on.
      state.value = state.value.copyWith(phase: BuildPhase.failed, error: _plain(e));
      return state.value;
    } finally {
      _running = false;
    }
  }

  static String _plain(Object e) => switch (e) {
        AiError(:final message) => message,
        _ => 'something went wrong ($e)'.split('\n').first,
      };

  /// A span's summary written and kept; false when the work stops (every
  /// key resting). A reply with nothing in it is kept as a dash, so the
  /// span is not asked again and again.
  Future<bool> _summarise(({int level, int from, int to, String text}) arc) async {
    final words = arc.level == 1 ? '150 to 250' : '250 to 400';
    try {
      final reply = await router.chat(AiJob.builder, [
        aiMessage(
          'system',
          'You keep the story so far of a novel for its reader. From the summaries given, write one account of '
              'chapters ${arc.from + 1} to ${arc.to + 1} in $words words: what happened, in order; who rose, fell, '
              'changed or died; what was revealed; what is still unanswered. Plain prose, no headings. Use only '
              'what is given.',
        ),
        aiMessage('user', arc.text),
      ], temperature: 0.3);
      final text = reply.text.trim();
      final p = path;
      await _keepArcOff(p, arc.level, arc.from, arc.to, text.isEmpty ? '—' : text);
      return true;
    } on AiResting catch (e) {
      state.value = state.value.copyWith(
        phase: e.until == null ? BuildPhase.failed : BuildPhase.resting,
        until: e.until,
        error: e.until == null ? (e.last?.message ?? 'No key can build memories') : null,
      );
      return false;
    }
  }

  /// The cast tidied; false when the work stops (every key resting).
  Future<bool> _tidy() async {
    try {
      await tidyCast(path, router);
    } on AiResting catch (e) {
      state.value = state.value.copyWith(
        phase: e.until == null ? BuildPhase.failed : BuildPhase.resting,
        until: e.until,
        error: e.until == null ? (e.last?.message ?? 'No key can build memories') : null,
      );
      return false;
    } on Object {
      // A reply not understood, or the memory busy: tried again once more
      // is noted.
      final p = path;
      await _markTidiedOff(p);
    }
    return true;
  }

  /// Vectors for meaning search made for what was noted, when a key can
  /// embed; passed over when none can.
  Future<void> _embed() async {
    if (router.ring.forJob(AiJob.embedder).isEmpty) return;
    final p = path;
    for (var round = 0; round < 8; round++) {
      final model = router.ring.forJob(AiJob.embedder).first.models[AiJob.embedder]!;
      final items = await _pendingOff(p, model);
      if (items.isEmpty) return;
      try {
        final got = await router.run(AiJob.embedder, (key, to) async {
          final v = await router.client.embed(to, [for (final i in items) i.text]);
          router.ring.count(key.id, AiUsage(input: items.fold(0, (n, i) => n + i.text.length ~/ 4), guessed: true));
          return (model: key.models[AiJob.embedder]!, vectors: v);
        });
        await _keepVectorsOff(p, got.model, items, got.vectors);
      } on AiResting {
        return;
      }
    }
  }

  /// The reader's open theories held up to the chapters just noted: those
  /// they clearly settle get their verdict (kept hidden from the reader
  /// until they reach that chapter). Passed over when no key can do it.
  Future<void> _checkTheories(List<int> chapters) async {
    final p = path;
    final open = await _openTheoriesOff(p);
    final last = chapters.reduce(math.max);
    final due = [for (final t in open) if (t.ch < last) t];
    if (due.isEmpty) return;
    final text = await _forCheckOff(p, chapters);
    if (text.trim().isEmpty) return;
    try {
      final reply = await router.chat(
        AiJob.builder,
        [aiMessage('user', theoryCheckPrompt(due, text))],
        json: true,
        temperature: 0.1,
      );
      final v = jsonObjectIn(reply.text);
      final ids = {for (final t in due) t.id: t};
      for (final r in (v['verdicts'] as List? ?? const [])) {
        if (r is! Map) continue;
        final id = (r['id'] as num?)?.toInt();
        final status = '${r['status'] ?? ''}'.toLowerCase();
        final ch = ((r['ch'] as num?)?.toInt() ?? (last + 1)) - 1;
        final t = id == null ? null : ids[id];
        if (t == null || !const {'confirmed', 'busted', 'mixed'}.contains(status)) continue;
        // Settled in one of these chapters, after the theory was stated.
        final at = chapters.contains(ch) && ch > t.ch ? ch : last;
        final why = '${r['why'] ?? ''}'.trim();
        await _verdictOff(p, t.id, status, at, why);
      }
    } on AiResting {
      return;
    } on NotesFormatException {
      return;
    }
  }

  /// One batch sent and its notes merged: true when kept, false when the
  /// model's reply could not be used, null when the work stops (every key
  /// resting, or none able).
  Future<bool?> _send(_Batch batch) async {
    final messages = [
      aiMessage('system', builderInstructions),
      aiMessage('user', batch.prompt),
    ];
    for (var attempt = 0; attempt < 2; attempt++) {
      final AiReply reply;
      try {
        reply = await router.chat(AiJob.builder, messages, json: true, temperature: 0.2);
      } on AiResting catch (e) {
        state.value = state.value.copyWith(
          phase: e.until == null ? BuildPhase.failed : BuildPhase.resting,
          until: e.until,
          error: e.until == null ? (e.last?.message ?? 'No key can build memories') : null,
        );
        return null;
      }
      try {
        if (reply.finish == 'length') throw const NotesFormatException('The reply was cut off: it was too long.');
        final most = batch.passages.values.fold<int>(0, (n, p) => math.max(n, p.length));
        final notes = parseChapterNotes(reply.text, batch.chapters, passages: most);
        final p = path, places = batch.passages, model = router.lastKey?.models[AiJob.builder];
        await _mergeOff(p, notes, places, model);
        return true;
      } on NotesFormatException catch (e) {
        if (reply.finish == 'length') return false;
        messages
          ..add(aiMessage('assistant', reply.text.length > 2000 ? '${reply.text.substring(0, 2000)}…' : reply.text))
          ..add(aiMessage('user', '${e.message} Send the whole JSON object again, as asked, and nothing else.'));
      }
    }
    return false;
  }
}
