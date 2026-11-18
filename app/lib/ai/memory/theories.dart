import 'dart:isolate';

import 'memory_db.dart';

/// A theory the reader stated, and what the story has said of it.
class Theory {
  const Theory({
    required this.id,
    required this.text,
    required this.ch,
    required this.made,
    this.status = 'open',
    this.decidedCh,
    this.verdict,
    this.told = false,
  });

  final int id;
  final String text;

  /// The chapter the reader was at when they stated it.
  final int ch;
  final DateTime made;

  /// open, confirmed, busted or mixed: as far as the reader may know.
  final String status;
  final int? decidedCh;
  final String? verdict;
  final bool told;

  bool get decided => status != 'open';
}

// Off the UI thread's isolate, each from a function of its own (a closure
// made in a State's method would carry the State).
Future<int?> addTheoryOff(String path, String text, int ch) =>
    MemoryDb.existsAt(path) ? Isolate.run(() => addTheory(path, text, ch)) : Future.value(null);
Future<List<Theory>> theoriesOff(String path, int at) =>
    MemoryDb.existsAt(path) ? Isolate.run(() => theoriesAt(path, at)) : Future.value(const []);
Future<List<Theory>> untoldOff(String path, int at) =>
    MemoryDb.existsAt(path) ? Isolate.run(() => untold(path, at)) : Future.value(const []);
Future<void> markToldOff(String path, List<int> ids) => Isolate.run(() => markTold(path, ids));
Future<void> removeTheoryOff(String path, int id) => Isolate.run(() => removeTheory(path, id));

/// [text] kept as a theory stated at chapter [ch]; its id.
int addTheory(String path, String text, int ch) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute('INSERT INTO theories(text, ch, made, status) VALUES (?, ?, ?, ?)',
        [text.trim(), ch, DateTime.now().toUtc().toIso8601String(), 'open']);
    return m.db.lastInsertRowId;
  } finally {
    m.close();
  }
}

/// The reader's theories, newest first, as the reader at chapter [at] may
/// see them: a verdict the story gives later than [at] stays hidden (the
/// theory still open), whatever the spoiler guard, for knowing a theory
/// was confirmed is itself a spoiler.
List<Theory> theoriesAt(String path, int at) {
  final m = MemoryDb.open(path);
  try {
    return [
      for (final r in m.db.select('SELECT * FROM theories ORDER BY id DESC'))
        () {
          final decided = r['decided_ch'] as int?;
          final known = decided != null && decided <= at;
          return Theory(
            id: r['id'] as int,
            text: r['text'] as String,
            ch: r['ch'] as int,
            made: DateTime.parse(r['made'] as String),
            status: known ? r['status'] as String : 'open',
            decidedCh: known ? decided : null,
            verdict: known ? r['verdict'] as String? : null,
            told: (r['told'] as int? ?? 0) == 1,
          );
        }(),
    ];
  } finally {
    m.close();
  }
}

/// Verdicts the reader at [at] has reached but has not been told yet.
List<Theory> untold(String path, int at) => [
      for (final t in theoriesAt(path, at))
        if (t.decided && !t.told) t,
    ];

void markTold(String path, List<int> ids) {
  if (ids.isEmpty) return;
  final m = MemoryDb.open(path);
  try {
    m.db.execute('UPDATE theories SET told = 1 WHERE id IN (${ids.join(',')})');
  } finally {
    m.close();
  }
}

void removeTheory(String path, int id) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute('DELETE FROM theories WHERE id = ?', [id]);
  } finally {
    m.close();
  }
}

/// The theories still open in the memory itself (whatever the reader
/// knows), each with the chapter it was stated at: for the Builder to
/// check against the chapters it reads.
List<({int id, String text, int ch})> openTheories(String path) {
  final m = MemoryDb.open(path);
  try {
    return [
      for (final r in m.db.select("SELECT id, text, ch FROM theories WHERE status = 'open' ORDER BY id"))
        (id: r['id'] as int, text: r['text'] as String, ch: r['ch'] as int),
    ];
  } finally {
    m.close();
  }
}

/// A verdict kept: the story [status] the theory at chapter [ch], [why].
void keepVerdict(String path, int id, String status, int ch, String why, {String? evidence}) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute(
      "UPDATE theories SET status = ?, decided_ch = ?, verdict = ?, evidence = ?, told = 0 WHERE id = ? AND status = 'open'",
      [status, ch, why, evidence, id],
    );
  } finally {
    m.close();
  }
}

/// What the Builder is asked of open theories, given the chapters it has
/// just made notes for (their summaries, reveals and threads resolved).
String theoryCheckPrompt(List<({int id, String text, int ch})> theories, String chapters) => '''
A reader stated these theories about the novel while reading. Here is what the latest chapters say. For each theory, decide only whether these chapters clearly settle it: "confirmed" (the text shows it true), "busted" (the text shows it false) or "mixed" (partly true). If these chapters do not clearly settle it, leave it out. Never use what you may know of the book from elsewhere.

Theories:
${[for (final t in theories) '#${t.id} (stated at chapter ${t.ch + 1}): ${t.text}'].join('\n')}

The latest chapters:
$chapters

Return one JSON object, nothing else: {"verdicts": [{"id": <theory number>, "status": "confirmed" | "busted" | "mixed", "ch": <the chapter number that settles it, as given>, "why": "<one or two sentences, from the text>"}]}
''';

/// The chapters just noted, as the theory check reads them: each summary,
/// what it revealed, and threads it resolved.
String chaptersForCheck(String path, List<int> chapters) {
  final m = MemoryDb.open(path);
  try {
    final b = StringBuffer();
    for (final ch in chapters) {
      final s = m.db.select('SELECT summary FROM notes WHERE ch = ?', [ch]).firstOrNull;
      if (s == null) continue;
      b.writeln('Chapter ${ch + 1}: ${s['summary']}');
      for (final r in m.db.select('SELECT what, overturns FROM reveals WHERE ch = ?', [ch])) {
        b.writeln('  Revealed: ${r['what']}${r['overturns'] == null ? '' : ' (overturning: ${r['overturns']})'}');
      }
      for (final r in m.db.select(
          "SELECT t.title, s.what FROM thread_steps s JOIN threads t ON t.id = s.thread WHERE s.ch = ? AND s.step = 'resolved'",
          [ch])) {
        b.writeln('  Answered: ${r['title']}${r['what'] == null ? '' : ': ${r['what']}'}');
      }
    }
    return b.toString();
  } finally {
    m.close();
  }
}
