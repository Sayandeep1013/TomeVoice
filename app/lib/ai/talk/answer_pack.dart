import 'dart:io';
import 'dart:math' as math;

import '../memory/graph.dart';
import '../memory/meaning.dart';
import '../memory/memory_db.dart';

/// One piece of what an answer may draw on: its words, the heading it goes
/// under, and where in the book it comes from (to cite, and to look there).
class PackItem {
  const PackItem(this.section, this.text, {this.place, this.label});

  final String section;
  final String text;
  final MemoryPlace? place;

  /// How a citation of it reads, when not by its place in this book (a
  /// passage of an earlier book: "Book One · ch 4").
  final String? label;
}

/// What a question is answered from, gathered from the book's memory: kept
/// to chapter [line] and before when the spoiler guard is on (null: the
/// whole memory).
class PackInput {
  const PackInput({
    required this.path,
    required this.question,
    this.line,
    this.here,
    this.passage = '',
    this.journal = const [],
    this.maxCards = 8,
    this.meaning,
    this.meaningModel,
  });

  final String path;
  final String question;
  final int? line;

  /// The chapter being read, in the memory's numbering.
  final int? here;

  /// The chapter being read, up to the sentence the reader is at.
  final String passage;

  /// The reader's journal entries for the book (within the line), each
  /// "ch N, date: words".
  final List<String> journal;
  final int maxCards;

  /// The question's vector, from [meaningModel], for meaning search.
  final List<double>? meaning;
  final String? meaningModel;
}

const _stop = {
  'a', 'an', 'the', 'and', 'or', 'but', 'of', 'to', 'in', 'on', 'at', 'for', 'with', 'by', 'from', 'is', 'are', //
  'was', 'were', 'be', 'been', 'it', 'its', 'he', 'she', 'they', 'them', 'his', 'her', 'their', 'what', 'who',
  'whom', 'why', 'how', 'when', 'where', 'which', 'did', 'does', 'do', 'that', 'this', 'these', 'those', 'i', 'me',
  'my', 'you', 'your', 'we', 'about', 'tell', 'again', 'there', 'happened', 'happen', 'so', 'if', 'as', 'than',
  'can', 'could', 'would', 'should', 'will', 'has', 'have', 'had', 'not', 'no', 'any', 'all', 'some', 'into',
  'chapter', 'book', 'story', 'remember', 'recall', 'explain', 'mean', 'means', 'meant',
};

/// The words of a question worth searching the text for.
String searchWords(String question) => [
      for (final w in normName(question).split(' '))
        if (w.length > 2 && !_stop.contains(w)) w,
    ].take(8).join(' ');

/// Chapter [ch] as the reader counts it; before the first, an earlier book
/// of the series.
String chapterLabel(int ch) => ch < 0 ? 'an earlier book' : 'ch ${ch + 1}';

MemoryPlace? _place(Map<String, Object?> r, {String ch = 'ch'}) {
  final c = r[ch] as int?;
  if (c == null) return null;
  return MemoryPlace(
    chapter: c,
    section: (r['sec'] as int?) ?? c,
    block: (r['blk'] as int?) ?? 0,
    sentence: (r['sen'] as int?) ?? 0,
  );
}

/// The pack: the cards of the names the question (and the passage being
/// read) speaks of, as they stand at the line, with their relations and
/// key events; the places in the text the question's words are found; the
/// latest chapters' summaries and the arcs; open threads; the reader's
/// journal; and the passage itself.
List<PackItem> buildPack(PackInput i) {
  final m = MemoryDb.open(i.path);
  try {
    final g = BookGraph(m);
    final at = i.line ?? 1 << 30;
    final items = <PackItem>[];

    // The cards: named in the question first, then in what is being read.
    final asked = g.namedIn(i.question).map(g.live).whereType<int>().toSet();
    final tail = i.passage.length > 2000 ? i.passage.substring(i.passage.length - 2000) : i.passage;
    final reading = g.namedIn(tail).map(g.live).whereType<int>().toSet()..removeAll(asked);
    final ids = [...asked, ..._byMentions(m, reading)].take(i.maxCards);
    for (final id in ids) {
      items.addAll(cardItems(m, id, at));
    }

    // The text itself, where the question's words are.
    final words = searchWords(i.question);
    if (words.isNotEmpty) {
      for (final h in m.search(words, upTo: i.line, limit: 8, any: true)) {
        items.add(PackItem('Passages', '${chapterLabel(h.place.chapter)}: ${h.snippet}', place: h.place));
      }
    }

    // Moments that mean what was asked, in whatever words.
    final v = i.meaning, model = i.meaningModel;
    if (v != null && model != null) {
      for (final h in meaningSearch(i.path, model, v, upTo: i.line)) {
        items.add(PackItem('Moments that match', '${chapterLabel(h.ch)}: ${h.text}', place: h.place));
      }
    }

    // The story so far: the arcs, then the latest chapters.
    final here = math.min(i.here ?? at, at);
    for (final r in m.db.select(
      'SELECT level, from_ch, to_ch, summary FROM arcs WHERE to_ch <= ? ORDER BY level DESC, from_ch',
      [here],
    )) {
      final from = r['from_ch'] as int, to = r['to_ch'] as int;
      items.add(from < 0
          ? PackItem('The story so far', 'Before this book (the earlier books of the series): ${r['summary']}')
          : PackItem('The story so far', 'Chapters ${from + 1}–${to + 1}: ${r['summary']}',
              place: MemoryPlace(chapter: from, section: from)));
    }
    for (final r in m.db.select(
      'SELECT n.ch, n.summary, c.section FROM notes n JOIN chapters c ON c.ch = n.ch WHERE n.ch <= ? ORDER BY n.ch DESC LIMIT 6',
      [here],
    ).reversed) {
      final ch = r['ch'] as int;
      items.add(PackItem('Latest chapters', '${chapterLabel(ch)}: ${r['summary']}',
          place: MemoryPlace(chapter: ch, section: r['section'] as int)));
    }

    // Threads still open at the line, those the question touches first.
    final qWords = normName(i.question).split(' ').where((w) => w.length > 3).toSet();
    final threads = [
      for (final r in m.db.select(
        'SELECT id, title, about, raised_ch FROM threads WHERE raised_ch <= ? AND (resolved_ch IS NULL OR resolved_ch > ?) '
        'ORDER BY raised_ch DESC LIMIT 60',
        [at, at],
      ))
        r,
    ]..sort((a, b) {
        int score(Map<String, Object?> r) =>
            normName('${r['title']} ${r['about'] ?? ''}').split(' ').where(qWords.contains).length;
        return score(b).compareTo(score(a));
      });
    for (final r in threads.take(8)) {
      final ch = r['raised_ch'] as int;
      items.add(PackItem(
        'Open threads',
        '"${r['title']}" (raised ${chapterLabel(ch)})${r['about'] == null ? '' : ': ${r['about']}'}',
        place: MemoryPlace(chapter: ch, section: ch),
      ));
    }

    for (final j in i.journal.take(8)) {
      items.add(PackItem("The reader's journal", j));
    }
    if (i.passage.trim().isNotEmpty) {
      final p = i.passage.length > 6000 ? '…${i.passage.substring(i.passage.length - 6000)}' : i.passage;
      items.add(PackItem('What the reader is reading now${i.here == null ? '' : ' (${chapterLabel(i.here!)})'}', p));
    }
    return items;
  } finally {
    m.close();
  }
}

List<int> _byMentions(MemoryDb m, Set<int> ids) => ids.isEmpty
    ? const []
    : [
        for (final r in m.db.select('SELECT id FROM entities WHERE id IN (${ids.join(',')}) ORDER BY mentions DESC'))
          r['id'] as int,
      ];

/// Entity [id]'s card as it stands at chapter [at]: who or what, its names,
/// how it stands, its relations, its key events in order, a line it said.
List<PackItem> cardItems(MemoryDb m, int id, int at) {
  final e = m.db.select('SELECT kind, name, about, first_ch, mentions FROM entities WHERE id = ?', [id]).firstOrNull;
  if (e == null) return const [];
  final first = e['first_ch'] as int?;
  if (first != null && first > at) return const [];
  final name = e['name'] as String;
  final head = 'Card: $name';
  final names = [
    for (final a in m.db.select('SELECT alias FROM aliases WHERE entity = ? AND (ch IS NULL OR ch <= ?)', [id, at]))
      a['alias'] as String,
  ]..remove(name);
  final out = <PackItem>[
    PackItem(
      head,
      '$name (${e['kind']})${names.isEmpty ? '' : ', also called ${names.take(8).join(', ')}'}. '
      '${describedAt(m, id, at) ?? ''} First met in ${chapterLabel(first ?? 0)}.',
      place: first == null || first < 0 ? null : MemoryPlace(chapter: first, section: first),
    ),
  ];
  for (final f in m.db.select(
    'SELECT attr, value, from_ch ch, sec, blk, sen FROM facts WHERE entity = ? AND from_ch <= ? '
    "AND (until_ch IS NULL OR until_ch > ?) AND attr != 'description' ORDER BY from_ch",
    [id, at, at],
  )) {
    out.add(PackItem(head, '${f['attr']}: ${f['value']} (from ${chapterLabel(f['ch'] as int)})', place: _place(f)));
  }
  for (final r in m.db.select(
    'SELECT r.rel, r.a, r.b, r.from_ch ch, r.sec, r.blk, r.sen, r.note, ea.name an, eb.name bn FROM relations r '
    'JOIN entities ea ON ea.id = r.a JOIN entities eb ON eb.id = r.b '
    'WHERE (r.a = ? OR r.b = ?) AND r.from_ch <= ? AND (r.until_ch IS NULL OR r.until_ch > ?) ORDER BY r.from_ch LIMIT 12',
    [id, id, at, at],
  )) {
    out.add(PackItem(head, '${r['an']} ${r['rel']} ${r['bn']}${r['note'] == null ? '' : ' (${r['note']})'}',
        place: _place(r)));
  }
  final events = [
    for (final v in m.db.select(
      'SELECT DISTINCT v.id, v.ch, v.sec, v.blk, v.sen, v.what, v.why, v.result, v.importance FROM events v '
      'JOIN event_roles r ON r.event = v.id WHERE r.entity = ? AND v.ch <= ? '
      'ORDER BY v.importance DESC, v.ch DESC LIMIT 10',
      [id, at],
    ))
      v,
  ]..sort((a, b) => (a['ch'] as int).compareTo(b['ch'] as int));
  for (final v in events) {
    out.add(PackItem(
      head,
      '${chapterLabel(v['ch'] as int)}: ${v['what']}'
      '${v['why'] == null ? '' : ', ${because(v['why'] as String)}'}${v['result'] == null ? '' : ' → ${v['result']}'}',
      place: _place(v),
    ));
  }
  final q = m.db.select(
      'SELECT text, ch, sec, blk, sen FROM quotes WHERE speaker = ? AND ch <= ? ORDER BY ch DESC LIMIT 1', [id, at]);
  if (q.isNotEmpty) out.add(PackItem(head, 'Said: "${q.first['text']}"', place: _place(q.first)));
  return out;
}

/// What a tool the model asked for answers, from the memory, within [line].
List<PackItem> runTool(String path, String name, Map<String, Object?> args, int? line) {
  final m = MemoryDb.open(path);
  try {
    final at = line ?? 1 << 30;
    final g = BookGraph(m);
    switch (name) {
      case 'search_text':
        final q = '${args['query'] ?? ''}';
        return [
          for (final h in m.search(q, upTo: line, limit: 10))
            PackItem('Passages', '${chapterLabel(h.place.chapter)}: ${h.snippet}', place: h.place),
        ];
      case 'card':
        final id = g.byName('${args['name'] ?? ''}');
        return id == null ? [const PackItem('Card', 'Nobody and nothing of that name is known yet.')] : cardItems(m, id, at);
      case 'events':
        final id = g.byName('${args['name'] ?? ''}');
        if (id == null) return [const PackItem('Events', 'Nobody and nothing of that name is known yet.')];
        final from = ((args['from_chapter'] as num?)?.toInt() ?? 1) - 1;
        final to = math.min(((args['to_chapter'] as num?)?.toInt() ?? (1 << 30)) - 1, at);
        return [
          for (final v in m.db.select(
            'SELECT DISTINCT v.ch, v.sec, v.blk, v.sen, v.what, v.why, v.result FROM events v JOIN event_roles r ON r.event = v.id '
            'WHERE r.entity = ? AND v.ch BETWEEN ? AND ? ORDER BY v.ch, v.id LIMIT 40',
            [id, from, to],
          ))
            PackItem('Events', '${chapterLabel(v['ch'] as int)}: ${v['what']}'
                '${v['why'] == null ? '' : ', ${because(v['why'] as String)}'}${v['result'] == null ? '' : ' → ${v['result']}'}',
                place: _place(v)),
        ];
      case 'chapter_notes':
        final ch = ((args['chapter'] as num?)?.toInt() ?? 0) - 1;
        if (ch > at) return [const PackItem('Notes', 'That chapter is past where the reader is.')];
        final r = m.db.select('SELECT n.summary, c.section FROM notes n JOIN chapters c ON c.ch = n.ch WHERE n.ch = ?', [ch]);
        if (r.isEmpty) return [const PackItem('Notes', 'There are no notes for that chapter yet.')];
        return [
          PackItem('Notes', '${chapterLabel(ch)}: ${r.first['summary']}',
              place: MemoryPlace(chapter: ch, section: r.first['section'] as int)),
        ];
      case 'read_chapter':
        final ch = ((args['chapter'] as num?)?.toInt() ?? 0) - 1;
        if (ch > at) return [const PackItem('Text', 'That chapter is past where the reader is.')];
        final chunks = m.chapterText(ch);
        if (chunks.isEmpty) return [const PackItem('Text', 'That chapter is not on the phone.')];
        final from = ((args['from_passage'] as num?)?.toInt() ?? 1) - 1;
        return [
          for (final c in chunks.skip(math.max(0, from)).take(30))
            PackItem('Text of ${chapterLabel(ch)}', c.text, place: c.start),
        ];
      case 'thread':
        final norm = normName('${args['name'] ?? ''}');
        final t = m.db.select(
          'SELECT id, title, raised_ch, resolved_ch FROM threads WHERE norm LIKE ? AND raised_ch <= ? LIMIT 1',
          ['%$norm%', at],
        );
        if (t.isEmpty) return [const PackItem('Thread', 'No thread of that name is known.')];
        return [
          for (final s in m.db.select(
            'SELECT ch, sec, blk, sen, what, step FROM thread_steps WHERE thread = ? AND ch <= ? ORDER BY ch',
            [t.first['id'], at],
          ))
            PackItem('Thread: ${t.first['title']}', '${chapterLabel(s['ch'] as int)} (${s['step']}): ${s['what'] ?? ''}',
                place: _place(s)),
        ];
    }
    return [PackItem('Error', 'There is no tool called $name.')];
  } finally {
    m.close();
  }
}

/// An earlier book of the series a memory carries on from: its memory, its
/// title, and how far the reader went in it (null: all of it).
typedef EarlierBook = ({String id, String path, String title, int? upTo});

/// The earlier books the memory at [path] carries on from, earliest first
/// (those whose memory is still on the phone).
List<EarlierBook> earlierBooks(String path) {
  if (!MemoryDb.existsAt(path)) return const [];
  final m = MemoryDb.open(path);
  try {
    final ids = (m.meta('follows') ?? '').split(',').where((s) => s.isNotEmpty).toList();
    final titles = (m.meta('follows_titles') ?? '').split('\n');
    final cuts = (m.meta('follows_upto') ?? '').split(',');
    final dir = File(path).parent.parent.path;
    return [
      for (final (i, id) in ids.indexed)
        if (MemoryDb.existsAt('$dir/$id/memory.db'))
          (
            id: id,
            path: '$dir/$id/memory.db',
            title: i < titles.length && titles[i].trim().isNotEmpty ? titles[i].trim() : 'an earlier book',
            upTo: i < cuts.length ? int.tryParse(cuts[i]) : null,
          ),
    ];
  } finally {
    m.close();
  }
}

/// "Book One · ch 4".
String earlierLabel(String title, int ch) => '$title · ${chapterLabel(ch)}';

/// What the earlier books say to [question]: the cards of the names it asks
/// about, and the passages where its words are, the latest book first.
List<PackItem> earlierPack(String question, List<EarlierBook> books, {int perBook = 4}) {
  final words = searchWords(question);
  final out = <PackItem>[];
  for (final b in books.reversed) {
    final m = MemoryDb.open(b.path);
    try {
      final g = BookGraph(m);
      final at = b.upTo ?? 1 << 30;
      final section = 'From ${b.title}, an earlier book';
      for (final id in g.namedIn(question).map(g.live).whereType<int>().take(2)) {
        for (final c in cardItems(m, id, at).take(6)) {
          out.add(PackItem(section, c.text, label: c.place == null ? b.title : earlierLabel(b.title, c.place!.chapter)));
        }
      }
      if (words.isNotEmpty) {
        for (final h in m.search(words, upTo: b.upTo, limit: perBook, any: true)) {
          out.add(PackItem(section, '${earlierLabel(b.title, h.place.chapter)}: ${h.snippet}',
              label: earlierLabel(b.title, h.place.chapter)));
        }
      }
    } finally {
      m.close();
    }
  }
  return out;
}

/// The tool search_earlier_books: [query] in each earlier book's text.
List<PackItem> searchEarlier(String query, List<EarlierBook> books) {
  final out = <PackItem>[];
  for (final b in books) {
    final m = MemoryDb.open(b.path);
    try {
      for (final h in m.search(query, upTo: b.upTo, limit: 8)) {
        out.add(PackItem('Passages in ${b.title}', '${earlierLabel(b.title, h.place.chapter)}: ${h.snippet}',
            label: earlierLabel(b.title, h.place.chapter)));
      }
    } finally {
      m.close();
    }
  }
  return out.isEmpty ? [const PackItem('Earlier books', 'Nothing of that is in the earlier books.')] : out;
}
