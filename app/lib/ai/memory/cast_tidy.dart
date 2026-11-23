import 'dart:isolate';

import '../ai_client.dart' show aiMessage;
import '../ai_keys.dart';
import '../ai_router.dart';
import 'chapter_notes.dart' show jsonObjectIn;
import 'graph.dart';
import 'memory_db.dart';

/// How many chapters are noted between tidyings of the cast.
const tidyEvery = 250;

/// Chapters noted since the last tidy before a caught-up book is tidied again.
const tidyAtLeast = 25;

/// What the AI is asked to tidy the cast: the memory is noted a few
/// chapters at a time, and sometimes splits one character over two cards
/// (known first by a description, then by name), or puts a name on the
/// wrong card.
const castTidyInstructions =
    'You tidy the cast list of a novel\'s memory. It was noted chapter by chapter, and sometimes split one '
    'character, place or thing over two entries (known first by a description, later by name), or put a name on '
    'the wrong entry. Given the entries (id, kind, name, the chapters it is in, what it is, its other names), '
    'reply with JSON only: {"same": [{"keep": <id>, "merge": [<id>, ...]}], "names": [{"id": <id>, "name": '
    '"<name>"}], "wrong": [{"id": <id>, "names": ["<name>", ...]}]}. '
    'same: entries that are one and the same (by their names and what they are); keep is the best known. Only '
    'when sure: never two different characters who share a title or a word. '
    'taken: an entry for one character that, from some chapter on, holds the story of another entry instead '
    '(its other names from then on are those of the other, while its own name and what it is are someone '
    'minor): {"id": <id>, "by": <the id of the other>, "from_ch": <the chapter it starts>}, as a list under '
    '"taken". Not '
    'same: the minor character stays. '
    'names: an entry named by a description or a passing title ("Silver Haired Girl", "the masked man") whose '
    'own name is among its other names (or a merged entry\'s): that name, as the book writes it most. '
    'wrong: other names on an entry that are plainly another entry\'s name. '
    'Leave out everything that is fine. Use only what is given.';

/// The best-known of the cast as the AI is shown them, and their ids.
({String text, Set<int> ids}) castBrief(String path, {int most = 120}) {
  final m = MemoryDb.open(path);
  try {
    final lines = <String>[];
    final ids = <int>{};
    for (final r in m.db.select(
      'SELECT id, kind, name, about, first_ch, last_ch, mentions FROM entities '
      'WHERE merged_into IS NULL AND mentions >= 3 ORDER BY mentions DESC LIMIT ?',
      [most],
    )) {
      final id = r['id'] as int;
      final own = normName(r['name'] as String);
      final names = [
        for (final a in m.db.select('SELECT alias, norm, ch FROM aliases WHERE entity = ? ORDER BY ch', [id]))
          if (a['norm'] != own && keepsAsName(a['alias'] as String))
            '${a['alias']} (ch ${((a['ch'] as int?) ?? 0) + 1})',
      ];
      // Its names first, then what it was called.
      bool proper(String n) => isProperName(n.substring(0, n.lastIndexOf(' (ch ')));
      final shown = [...names.where(proper), ...names.where((n) => !proper(n))].take(16);
      var about = (r['about'] as String?) ?? '';
      if (about.length > 110) about = '${about.substring(0, 110)}…';
      ids.add(id);
      lines.add([
        'e$id ${r['kind']} "${r['name']}" (ch ${((r['first_ch'] as int?) ?? 0) + 1}-'
            '${((r['last_ch'] as int?) ?? 0) + 1}, in ${r['mentions']} chapters)',
        if (about.isNotEmpty) '- $about',
        if (shown.isNotEmpty) '; also: ${shown.join(', ')}',
      ].join(' '));
    }
    return (text: lines.join('\n'), ids: ids);
  } finally {
    m.close();
  }
}

/// The AI's [reply] applied: cards merged, renamed, wrong names taken off;
/// only of the entries it was shown ([ids]). How many changes it made.
int applyCastTidy(String path, Map<String, Object?> reply, Set<int> ids) {
  final m = MemoryDb.open(path);
  var changes = 0;
  try {
    final g = BookGraph(m);
    int? idOf(Object? v) {
      final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}'.replaceFirst('e', ''));
      return n != null && ids.contains(n) ? g.live(n) : null;
    }

    Iterable<Map<Object?, Object?>> list(String k) => (reply[k] is List ? reply[k] as List : const []).whereType<Map>();
    m.inTransaction(() {
      for (final s in list('same')) {
        final keep = idOf(s['keep']);
        if (keep == null) continue;
        for (final o in (s['merge'] is List ? s['merge'] as List : const [])) {
          final id = idOf(o);
          if (id == null || id == keep) continue;
          g.merge(id, keep, by: 'ai');
          changes++;
        }
      }
      for (final t in list('taken')) {
        final id = idOf(t['id']), by = idOf(t['by']);
        final from = (t['from_ch'] as num?)?.toInt();
        if (id == null || by == null || id == by || from == null || from < 1) continue;
        // The AI's chapter, or where the card's chapters say it began, if
        // that is earlier.
        final seen = g.takeoverStart(id);
        g.handOver(id, by, seen != null && seen < from - 1 ? seen : from - 1);
        changes++;
      }
      for (final w in list('wrong')) {
        final id = idOf(w['id']);
        if (id == null) continue;
        for (final n in (w['names'] is List ? w['names'] as List : const []).whereType<String>()) {
          if (!g.answersTo(id, n)) continue;
          g.dropAlias(id, n);
          changes++;
        }
      }
      for (final n in list('names')) {
        final id = idOf(n['id']);
        final name = (n['name'] as String?)?.trim();
        // Only a name it already goes by: nothing made up.
        if (id == null || name == null || name.isEmpty || !g.answersTo(id, name)) continue;
        g.rename(id, name);
        changes++;
      }
      m.setMeta('cast_tidied', '${_noted(m)}');
    });
  } finally {
    m.close();
  }
  return changes;
}

int _noted(MemoryDb m) => m.db.select('SELECT count(*) n FROM chapters WHERE noted = 1').first['n'] as int;

/// Whether the cast is due a tidying: [tidyEvery] chapters noted since the
/// last, or the book's notes finished since. "Finished" is also true each
/// time the builder catches up with a book still being downloaded or
/// followed, so then [tidyAtLeast] new chapters are wanted too: one new
/// chapter is not worth a call bigger than the chapter's own.
bool castTidyDue(String path) {
  final m = MemoryDb.open(path);
  try {
    final noted = _noted(m);
    final last = int.tryParse(m.meta('cast_tidied') ?? '') ?? 0;
    if (noted < 30 || noted <= last) return false;
    final left = m.db.select('SELECT count(*) n FROM chapters WHERE noted = 0 AND note_error IS NULL').first['n'] as int;
    return noted - last >= tidyEvery || (left == 0 && (last == 0 || noted - last >= tidyAtLeast));
  } finally {
    m.close();
  }
}

/// The cast marked tidied as of now (a reply not understood is not asked
/// again until more is noted).
void markCastTidied(String path) {
  final m = MemoryDb.open(path);
  try {
    m.setMeta('cast_tidied', '${_noted(m)}');
  } finally {
    m.close();
  }
}

/// The cast tidied by the AI, in one call: how many changes it made.
/// Throws [AiResting] when no key can take it; a reply not understood
/// changes nothing (and is not asked again until more is noted). [only]:
/// the keys the book's build keeps to.
Future<int> tidyCast(String path, AiRouter router, {Set<String>? only}) async {
  final brief = await Isolate.run(() => castBrief(path));
  if (brief.ids.length < 2) {
    // Nothing to join: marked done, or the builder would find it due again
    // at once and go round for ever.
    await Isolate.run(() => markCastTidied(path));
    return 0;
  }
  final reply = await router.chat(AiJob.builder, [
    aiMessage('system', castTidyInstructions),
    aiMessage('user', brief.text),
  ], json: true, temperature: 0.1, only: only);
  final Map<String, Object?> json;
  try {
    json = jsonObjectIn(reply.text);
  } on Object {
    await Isolate.run(() => markCastTidied(path));
    return 0;
  }
  final ids = brief.ids;
  return Isolate.run(() => applyCastTidy(path, json, ids));
}

/// Entity [id] renamed by the reader.
Future<void> renameEntity(String path, int id, String name) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        m.inTransaction(() => BookGraph(m).rename(id, name));
      } finally {
        m.close();
      }
    });

/// Where another's story seems to begin on card [id] (null: it does not).
Future<int?> takeoverStartOf(String path, int id) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        return BookGraph(m).takeoverStart(id);
      } finally {
        m.close();
      }
    });

/// What card [from] holds from chapter [ch] on given to [to] by the reader.
Future<void> handOverEntity(String path, int from, int to, int ch) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        m.inTransaction(() => BookGraph(m).handOver(from, to, ch));
      } finally {
        m.close();
      }
    });

/// Entity [from] made one with [into] by the reader.
Future<void> mergeEntity(String path, int from, int into) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        m.inTransaction(() => BookGraph(m).merge(from, into));
      } finally {
        m.close();
      }
    });

/// The merges of the memory at [path] not undone, newest first; into
/// [into] alone when given.
Future<List<MergeRecord>> mergesOf(String path, {int? into}) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        return BookGraph(m).merges(into: into);
      } finally {
        m.close();
      }
    });

/// Merges [ids] undone, newest first.
Future<void> undoMerges(String path, List<int> ids) => Isolate.run(() {
      final m = MemoryDb.open(path);
      try {
        m.inTransaction(() {
          for (final id in [...ids]..sort((a, b) => b - a)) {
            BookGraph(m).undoMerge(id);
          }
        });
      } finally {
        m.close();
      }
    });
