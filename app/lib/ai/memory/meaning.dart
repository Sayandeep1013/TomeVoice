import 'dart:math' as math;
import 'dart:typed_data';

import 'graph.dart' show because;
import 'memory_db.dart';

/// Meaning search: each chapter's summary and each event kept as a vector
/// (from the reader's Embedder key), so a question finds the moments it
/// means even in other words: "the time he nearly froze" finds the chapter
/// where Sunny lies dying in the snow. Optional: without an Embedder key,
/// the word index and the graph do the finding.

/// Something to make a vector of: what it is, whose, and its words.
class MeaningItem {
  const MeaningItem({required this.owner, required this.id, required this.ch, required this.text});

  /// 'note' (a chapter's summary; [id] is the chapter) or 'event'.
  final String owner;
  final int id;
  final int ch;
  final String text;
}

/// What has no vector yet for [model]: chapter summaries, then events that
/// matter, oldest first, at most [limit].
List<MeaningItem> pendingMeaning(String path, String model, {int limit = 256}) {
  final m = MemoryDb.open(path);
  try {
    final notes = [
      for (final r in m.db.select(
        "SELECT ch, summary FROM notes WHERE ch NOT IN (SELECT id FROM vectors WHERE owner = 'note' AND model = ?) "
        'ORDER BY ch LIMIT ?',
        [model, limit],
      ))
        MeaningItem(owner: 'note', id: r['ch'] as int, ch: r['ch'] as int, text: r['summary'] as String),
    ];
    if (notes.length >= limit) return notes;
    final events = [
      for (final r in m.db.select(
        "SELECT id, ch, what, why, result FROM events WHERE importance >= 2 AND id NOT IN "
        "(SELECT id FROM vectors WHERE owner = 'event' AND model = ?) ORDER BY ch, id LIMIT ?",
        [model, limit - notes.length],
      ))
        MeaningItem(
          owner: 'event',
          id: r['id'] as int,
          ch: r['ch'] as int,
          text: [r['what'], if (r['why'] != null) because(r['why'] as String), if (r['result'] != null) '→ ${r['result']}'].join(' '),
        ),
    ];
    return [...notes, ...events];
  } finally {
    m.close();
  }
}

/// [v] as kept: its scale (a float) then each value in a byte.
Uint8List packVector(List<double> v) {
  var most = 0.0;
  for (final x in v) {
    most = math.max(most, x.abs());
  }
  final scale = most == 0 ? 1.0 : most / 127;
  final out = ByteData(4 + v.length)..setFloat32(0, scale, Endian.little);
  for (var i = 0; i < v.length; i++) {
    out.setInt8(4 + i, (v[i] / scale).round().clamp(-127, 127));
  }
  return out.buffer.asUint8List();
}

Float32List unpackVector(Uint8List b) {
  final d = ByteData.sublistView(b);
  final scale = d.getFloat32(0, Endian.little);
  final out = Float32List(b.length - 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = d.getInt8(4 + i) * scale;
  }
  return out;
}

void keepVectors(String path, String model, List<MeaningItem> items, List<List<double>> vectors) {
  final m = MemoryDb.open(path);
  try {
    m.inTransaction(() {
      final put = m.db.prepare('INSERT OR REPLACE INTO vectors(owner, id, ch, model, v) VALUES (?, ?, ?, ?, ?)');
      for (var i = 0; i < items.length && i < vectors.length; i++) {
        put.execute([items[i].owner, items[i].id, items[i].ch, model, packVector(vectors[i])]);
      }
      put.close();
    });
  } finally {
    m.close();
  }
}

double _cosine(List<double> a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / math.sqrt(na * nb);
}

/// A moment found by meaning: what it says, where, how close.
class MeaningHit {
  const MeaningHit({required this.owner, required this.ch, required this.text, required this.score, this.place});

  final String owner;
  final int ch;
  final String text;
  final double score;
  final MemoryPlace? place;
}

/// The moments closest in meaning to [query] (its vector from [model]),
/// within chapter [upTo] when the guard is on.
List<MeaningHit> meaningSearch(String path, String model, List<double> query, {int? upTo, int limit = 6}) {
  final m = MemoryDb.open(path);
  try {
    final scored = <(double, String, int, int)>[];
    for (final r in m.db.select(
      'SELECT owner, id, ch, v FROM vectors WHERE model = ?${upTo == null ? '' : ' AND ch <= $upTo'}',
      [model],
    )) {
      scored.add((_cosine(query, unpackVector(r['v'] as Uint8List)), r['owner'] as String, r['id'] as int, r['ch'] as int));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    final out = <MeaningHit>[];
    for (final (score, owner, id, ch) in scored.take(limit)) {
      if (owner == 'note') {
        final r = m.db.select('SELECT n.summary, c.section FROM notes n JOIN chapters c ON c.ch = n.ch WHERE n.ch = ?', [id]);
        if (r.isEmpty) continue;
        out.add(MeaningHit(
          owner: owner,
          ch: ch,
          text: r.first['summary'] as String,
          score: score,
          place: MemoryPlace(chapter: ch, section: r.first['section'] as int),
        ));
      } else {
        final r = m.db.select('SELECT what, why, result, sec, blk, sen FROM events WHERE id = ?', [id]);
        if (r.isEmpty) continue;
        final e = r.first;
        out.add(MeaningHit(
          owner: owner,
          ch: ch,
          text: '${e['what']}${e['why'] == null ? '' : ', ${because(e['why'] as String)}'}${e['result'] == null ? '' : ' → ${e['result']}'}',
          score: score,
          place: MemoryPlace(
            chapter: ch,
            section: (e['sec'] as int?) ?? ch,
            block: (e['blk'] as int?) ?? 0,
            sentence: (e['sen'] as int?) ?? 0,
          ),
        ));
      }
    }
    return out;
  } finally {
    m.close();
  }
}
