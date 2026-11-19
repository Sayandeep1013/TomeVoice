import 'dart:math' as math;

import 'graph.dart';
import 'memory_db.dart';

/// One entity as Who's who lists it.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.kind,
    required this.name,
    this.about,
    this.firstCh,
    this.mentions = 0,
  });

  final int id;
  final String kind;
  final String name;
  final String? about;
  final int? firstCh;

  /// Chapters it appears in.
  final int mentions;
}

enum LedgerOrder { importance, firstMet, name }

/// Who's who: the book's entities as of chapter [at] (null: all of them),
/// of [kind] and matching [query] by any of their names.
List<LedgerEntry> ledger(String path,
    {int? at, String? kind, String query = '', LedgerOrder order = LedgerOrder.importance}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    final q = normName(query);
    final where = [
      'e.merged_into IS NULL',
      'coalesce(e.first_ch, 0) <= $line',
      if (kind != null) 'e.kind = ?',
      if (q.isNotEmpty) 'e.id IN (SELECT entity FROM aliases WHERE norm LIKE ?)',
    ].join(' AND ');
    final orderBy = switch (order) {
      LedgerOrder.importance => 'seen DESC, e.name',
      LedgerOrder.firstMet => 'e.first_ch, e.name',
      LedgerOrder.name => 'e.name COLLATE NOCASE',
    };
    return [
      for (final r in m.db.select(
        'SELECT e.id, e.kind, e.name, ${describedSql(line)} about, e.first_ch, '
        '(SELECT count(*) FROM appearances a WHERE a.entity = e.id AND a.ch <= $line) seen '
        'FROM entities e WHERE $where ORDER BY $orderBy LIMIT 2000',
        [if (kind != null) kind, if (q.isNotEmpty) '%$q%'],
      ))
        LedgerEntry(
          id: r['id'] as int,
          kind: r['kind'] as String,
          name: r['name'] as String,
          about: r['about'] as String?,
          firstCh: r['first_ch'] as int?,
          mentions: r['seen'] as int,
        ),
    ];
  } finally {
    m.close();
  }
}

/// The kinds the book's entities have, with how many of each, as of [at].
List<({String kind, int count, bool core})> ledgerKinds(String path, {int? at}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    return [
      for (final r in m.db.select(
        'SELECT e.kind, count(*) n, coalesce(k.core, 0) core FROM entities e LEFT JOIN kinds k ON k.name = e.kind '
        'WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= ? GROUP BY e.kind ORDER BY core DESC, n DESC',
        [line],
      ))
        (kind: r['kind'] as String, count: r['n'] as int, core: (r['core'] as int) == 1),
    ];
  } finally {
    m.close();
  }
}

/// A node of the memory graph.
class GraphNode {
  const GraphNode({
    required this.id,
    required this.name,
    required this.kind,
    required this.weight,
    this.firstCh,
    this.lastSeen,
    this.recent = 0,
    this.forgotten = false,
  });

  final int id;
  final String name;
  final String kind;

  /// Chapters it appears in, up to the line.
  final int weight;

  /// The chapter it is first met in: before it, the timeline hides it.
  final int? firstCh;

  /// The last chapter it appears in, up to the line.
  final int? lastSeen;

  /// Chapters it appears in near where the reader is.
  final int recent;

  /// Shown as one the reader may have forgotten: it mattered, and has not
  /// been seen for a long while.
  final bool forgotten;
}

/// What a link is, for its colour: a bond (ally, friend, love), a conflict
/// (enemy, rival, betrayal), family, belonging (member, servant, owner),
/// another relation, or only events shared.
enum LinkKind { bond, conflict, family, belongs, other, shared }

/// The kind of relation [rel] names.
LinkKind linkKindOf(String rel) {
  final r = rel.toLowerCase();
  bool has(List<String> words) => words.any(r.contains);
  if (has(
      ['enem', 'rival', 'betray', 'hunt', 'oppos', 'against', 'distrust', 'hate', 'kill', 'fight', 'feud', 'war'])) {
    return LinkKind.conflict;
  }
  if (has([
    'parent',
    'child',
    'sibling',
    'brother',
    'sister',
    'father',
    'mother',
    'son',
    'daughter',
    'family',
    'married',
    'spouse',
    'wife',
    'husband',
    'cousin',
    'uncle',
    'aunt',
    'grand'
  ])) {
    return LinkKind.family;
  }
  if (has([
    'member',
    'leader',
    'serv',
    'owns',
    'owner',
    'bound',
    'belong',
    'part of',
    'rules',
    'works for',
    'keeper',
    'commands',
    'head of',
    'citizen',
    'resident'
  ])) {
    return LinkKind.belongs;
  }
  if (has([
    'ally',
    'allie',
    'friend',
    'love',
    'trust',
    'mentor',
    'companion',
    'protect',
    'partner',
    'lover',
    'admire',
    'loyal',
    'help',
    'saved'
  ])) {
    return LinkKind.bond;
  }
  return LinkKind.other;
}

/// A link between two nodes: a relation the book stated, while it held
/// ([fromCh] to [untilCh]); or events the two took part in together, from
/// the first of them.
class GraphEdge {
  const GraphEdge({
    required this.a,
    required this.b,
    required this.label,
    required this.kind,
    required this.fromCh,
    this.untilCh,
    this.weight = 1,
  });

  final int a;
  final int b;
  final String label;
  final LinkKind kind;
  final int fromCh;
  final int? untilCh;
  final int weight;

  bool get related => kind != LinkKind.shared;

  /// Whether it holds at chapter [ch].
  bool at(int ch) => fromCh <= ch && (untilCh == null || untilCh! > ch);
}

class GraphData {
  const GraphData({
    required this.nodes,
    required this.edges,
    required this.lastCh,
    this.focus,
    this.more = 0,
    this.forgotten = 0,
    this.choices = 0,
  });

  /// How many more there were to show than were shown.
  final int more;

  /// How many of those shown are ones the reader may have forgotten.
  final int forgotten;

  /// How many there were to choose from, all told.
  final int choices;

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  /// The last chapter the memory has notes for.
  final int lastCh;
  final int? focus;
}

/// The most important person (or, with none, anything) in the memory up to
/// chapter [at]: where the graph opens.
int? mainOf(String path, {int? at}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    final r = m.db.select(
      'SELECT e.id FROM entities e WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= ? '
      "ORDER BY (e.kind = 'person') DESC, (SELECT count(*) FROM appearances a WHERE a.entity = e.id AND a.ch <= ?) DESC "
      'LIMIT 1',
      [line, line],
    );
    return r.isEmpty ? null : r.first['id'] as int;
  } finally {
    m.close();
  }
}

/// The graph as it stood at [at] (the line; null: all the memory has):
/// round [focus] out to [depth] links, or the whole web, of [kinds] if
/// given.
///
/// [most] are shown of all there are to choose from. Most of them are those
/// that matter now: in many chapters near [here] (where the reader is), or
/// in many chapters all told. About a quarter go to ones the reader may have
/// forgotten: they were in many chapters, but none of the last [window]
/// before [here]. Nothing is shown past the line.
GraphData graphAt(
  String path, {
  int? at,
  int? here,
  int? focus,
  int depth = 1,
  int most = 120,
  int window = 50,
  double forgottenShare = 0.25,
  Set<String>? kinds,
  int minChapters = 1,
}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    final last = (m.db.select('SELECT max(ch) last FROM notes').first['last'] as int?) ?? 0;
    final now = math.min(here ?? last, math.min(line, last));
    final kindIn = kinds == null || kinds.isEmpty
        ? ''
        : " AND e.kind IN (${kinds.map((k) => "'${k.replaceAll("'", "''")}'").join(',')})";

    // Who could be shown: round the focus, or everyone.
    Set<int>? within;
    if (focus != null) {
      final near = <int>{focus};
      var ring = <int>{focus};
      for (var hop = 0; hop < depth && ring.isNotEmpty; hop++) {
        final next = <int>{};
        for (final chunk in _chunks(ring.toList(), 400)) {
          final list = chunk.join(',');
          for (final r in m.db.select(
            'SELECT a, b FROM relations WHERE (a IN ($list) OR b IN ($list)) AND from_ch <= ?',
            [line],
          )) {
            next
              ..add(r['a'] as int)
              ..add(r['b'] as int);
          }
          for (final r in m.db.select(
            'SELECT DISTINCT r2.entity e FROM event_roles r1 JOIN event_roles r2 ON r2.event = r1.event '
            'JOIN events v ON v.id = r1.event WHERE r1.entity IN ($list) AND v.ch <= ?',
            [line],
          )) {
            next.add(r['e'] as int);
          }
        }
        next.removeAll(near);
        near.addAll(next);
        ring = next;
      }
      within = near;
    }

    final all = <GraphNode>[];
    for (final r in m.db.select(
      'SELECT e.id, e.name, e.kind, e.first_ch, '
      'sum(a.ch <= $line) w, sum(a.ch > ${now - window} AND a.ch <= $now) recent, '
      'max(CASE WHEN a.ch <= $now THEN a.ch END) seen '
      'FROM entities e LEFT JOIN appearances a ON a.entity = e.id '
      'WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= $line$kindIn GROUP BY e.id',
    )) {
      final id = r['id'] as int;
      if (within != null && !within.contains(id)) continue;
      final w = (r['w'] as int?) ?? 0;
      if (w < minChapters && id != focus) continue;
      all.add(GraphNode(
        id: id,
        name: r['name'] as String,
        kind: r['kind'] as String,
        weight: w,
        firstCh: r['first_ch'] as int?,
        lastSeen: r['seen'] as int?,
        recent: (r['recent'] as int?) ?? 0,
      ));
    }

    // Those that matter now first; then a share for the forgotten.
    double now_(GraphNode n) => n.id == focus ? double.infinity : n.recent * 4 + math.sqrt(n.weight) * 3;
    bool longGone(GraphNode n) => n.weight >= 3 && n.lastSeen != null && now - n.lastSeen! > window;
    double gone(GraphNode n) => math.sqrt(n.weight) * math.log(1 + now - n.lastSeen!);
    final byNow = [...all]..sort((a, b) => now_(b).compareTo(now_(a)));
    final byGone = all.where(longGone).toList()..sort((a, b) => gone(b).compareTo(gone(a)));
    final picked = <int, GraphNode>{};
    final forgottenSlots = all.length <= most ? 0 : math.min(byGone.length, (most * forgottenShare).round());
    for (final n in byGone.take(forgottenSlots)) {
      picked[n.id] = GraphNode(
        id: n.id,
        name: n.name,
        kind: n.kind,
        weight: n.weight,
        firstCh: n.firstCh,
        lastSeen: n.lastSeen,
        recent: n.recent,
        forgotten: true,
      );
    }
    for (final n in byNow) {
      if (picked.length >= most && n.id != focus) break;
      picked.putIfAbsent(n.id, () => n);
    }
    // Among everything shown (not only those picked as such), the most
    // missed of the long gone are marked, so the reader sees who has been
    // away; a handful, not everyone.
    final marks = math.max(forgottenSlots, math.min(24, (picked.length * forgottenShare).round()));
    final missed = picked.values.where((n) => n.id != focus && longGone(n)).toList()
      ..sort((a, b) => gone(b).compareTo(gone(a)));
    final marked = {for (final n in missed.take(marks)) n.id};
    for (final n in picked.values.toList()) {
      if (!n.forgotten && marked.contains(n.id)) {
        picked[n.id] = GraphNode(
          id: n.id,
          name: n.name,
          kind: n.kind,
          weight: n.weight,
          firstCh: n.firstCh,
          lastSeen: n.lastSeen,
          recent: n.recent,
          forgotten: true,
        );
      }
    }
    final nodes = picked;
    if (nodes.isEmpty) return GraphData(nodes: const [], edges: const [], lastCh: last, focus: focus);
    final edges = <GraphEdge>[];
    final related = <(int, int)>{};
    final ids = nodes.keys.toSet();
    for (final r in m.db.select(
      'SELECT a, b, rel, from_ch, until_ch FROM relations WHERE a != b AND from_ch <= ? ORDER BY from_ch',
      [line],
    )) {
      final a = r['a'] as int, b = r['b'] as int;
      if (!ids.contains(a) || !ids.contains(b)) continue;
      final rel = r['rel'] as String;
      final until = r['until_ch'] as int?;
      related.add(a < b ? (a, b) : (b, a));
      edges.add(GraphEdge(
        a: a,
        b: b,
        label: rel,
        kind: linkKindOf(rel),
        fromCh: r['from_ch'] as int,
        untilCh: until != null && until <= line ? until : null,
      ));
    }
    for (final chunk in _chunks(ids.toList(), 400)) {
      final list = chunk.join(',');
      for (final r in m.db.select(
        'SELECT r1.entity a, r2.entity b, count(DISTINCT r1.event) n, min(v.ch) first FROM event_roles r1 '
        'JOIN event_roles r2 ON r2.event = r1.event AND r2.entity > r1.entity JOIN events v ON v.id = r1.event '
        'WHERE r1.entity IN ($list) AND v.ch <= ? GROUP BY r1.entity, r2.entity HAVING n >= 2',
        [line],
      )) {
        final a = r['a'] as int, b = r['b'] as int;
        if (!ids.contains(b) || related.contains((a, b))) continue;
        edges.add(GraphEdge(
          a: a,
          b: b,
          label: '${r['n']} events together',
          kind: LinkKind.shared,
          fromCh: r['first'] as int,
          weight: r['n'] as int,
        ));
      }
    }
    return GraphData(
      nodes: nodes.values.toList(),
      edges: edges,
      lastCh: last,
      focus: focus,
      more: all.length - nodes.length,
      forgotten: nodes.values.where((n) => n.forgotten).length,
      choices: all.length,
    );
  } finally {
    m.close();
  }
}

Iterable<List<int>> _chunks(List<int> ids, int size) sync* {
  for (var i = 0; i < ids.length; i += size) {
    yield ids.sublist(i, math.min(i + size, ids.length));
  }
}

/// One node, picked on the graph: what it is at chapter [at], when first
/// met, the chapters it is in (for its strip), and its relations then.
class NodeDetail {
  const NodeDetail({
    required this.id,
    required this.name,
    required this.kind,
    this.about,
    this.firstCh,
    this.chapters = const [],
    this.relations = const [],
  });

  final int id;
  final String name;
  final String kind;
  final String? about;
  final int? firstCh;
  final List<int> chapters;
  final List<({int other, String name, String rel, LinkKind kind})> relations;
}

NodeDetail? nodeDetail(String path, int id, int at) {
  final m = MemoryDb.open(path);
  try {
    final e = m.db.select('SELECT name, kind, first_ch FROM entities WHERE id = ?', [id]).firstOrNull;
    if (e == null) return null;
    return NodeDetail(
      id: id,
      name: e['name'] as String,
      kind: e['kind'] as String,
      about: describedAt(m, id, at),
      firstCh: e['first_ch'] as int?,
      chapters: [
        for (final r in m.db.select('SELECT ch FROM appearances WHERE entity = ? AND ch <= ? ORDER BY ch', [id, at]))
          r['ch'] as int,
      ],
      relations: [
        for (final r in m.db.select(
          'SELECT r.rel, CASE WHEN r.a = ? THEN r.b ELSE r.a END other, '
          'CASE WHEN r.a = ? THEN eb.name ELSE ea.name END oname, r.a = ? mine FROM relations r '
          'JOIN entities ea ON ea.id = r.a JOIN entities eb ON eb.id = r.b '
          'WHERE (r.a = ? OR r.b = ?) AND r.from_ch <= ? AND (r.until_ch IS NULL OR r.until_ch > ?) ORDER BY r.from_ch LIMIT 16',
          [id, id, id, id, id, at, at],
        ))
          (
            other: r['other'] as int,
            name: r['oname'] as String,
            // Read from this one's side: "owned by Sunny"; or, the other
            // way, "Sunny owns them", "Sunny, master of them".
            rel: (r['mine'] as int) == 1
                ? '${r['rel']} ${r['oname']}'
                : RegExp(r' (of|to|with|by|for|from|in)$').hasMatch(r['rel'] as String)
                    ? '${r['oname']}, ${r['rel']} them'
                    : '${r['oname']} ${r['rel']} them',
            kind: linkKindOf(r['rel'] as String),
          ),
      ],
    );
  } finally {
    m.close();
  }
}

/// What links [a] and [b] by chapter [at]: the relations between them (and
/// when), and the events they took part in together, in order.
({List<String> relations, List<({int ch, String what})> events}) linksBetween(String path, int a, int b, int at) {
  final m = MemoryDb.open(path);
  try {
    return (
      relations: [
        for (final r in m.db.select(
          'SELECT r.rel, r.from_ch, r.until_ch, ea.name an, eb.name bn FROM relations r '
          'JOIN entities ea ON ea.id = r.a JOIN entities eb ON eb.id = r.b '
          'WHERE ((r.a = ? AND r.b = ?) OR (r.a = ? AND r.b = ?)) AND r.from_ch <= ? ORDER BY r.from_ch',
          [a, b, b, a, at],
        ))
          '${r['an']} ${r['rel']} ${r['bn']} (from chapter ${(r['from_ch'] as int) + 1}'
              '${r['until_ch'] != null && (r['until_ch'] as int) <= at ? ' to ${(r['until_ch'] as int) + 1}' : ''})',
      ],
      events: [
        for (final r in m.db.select(
          'SELECT DISTINCT v.id, v.ch, v.what FROM events v JOIN event_roles x ON x.event = v.id AND x.entity = ? '
          'JOIN event_roles y ON y.event = v.id AND y.entity = ? WHERE v.ch <= ? ORDER BY v.ch, v.id LIMIT 30',
          [a, b, at],
        ))
          (ch: r['ch'] as int, what: r['what'] as String),
      ],
    );
  } finally {
    m.close();
  }
}

/// A node's radius on the screen, in logical pixels, whatever the zoom: by
/// how many chapters it is in. Zooming in moves nodes apart, not bigger, so
/// a crowded middle opens up.
double nodeDp(int weight) => math.min(17, 5 + math.sqrt(math.max(0, weight).toDouble()) * 1.3);

/// A logical pixel in the canvas's units, the graph fitted on a phone: the
/// spacing the layout keeps between nodes.
const canvasPerDp = 2.6;

/// Where each node sits, and the side of the square they sit in (at least
/// [size]; more, for a web too big to fit without nodes touching). The same
/// each time for the same graph.
///
/// Round someone ([GraphData.focus]): they are in the middle, those linked
/// to them in a ring round them (grouped by how they are linked), and the
/// rest in rings further out, each near those it links to. The whole web: a
/// force layout (linked nodes pull together, all push apart). Either way no
/// two nodes overlap.
/// A section of the ring round the focus: those linked to them as [kind],
/// its name drawn at [x], [y].
typedef GraphSector = ({LinkKind kind, double x, double y});

({Map<int, ({double x, double y})> at, double size, double height, List<GraphSector> sectors}) layoutGraph(GraphData g,
    {double size = 1000, int rounds = 300, Map<int, ({double x, double y})>? start, double aspect = 1}) {
  final n = g.nodes.length;
  if (n == 0) return (at: const {}, size: size, height: size, sectors: const []);
  final index = {for (final (i, v) in g.nodes.indexed) v.id: i};
  final radius = [for (final v in g.nodes) nodeDp(v.weight) * canvasPerDp];
  final links = [
    for (final e in g.edges)
      if (index[e.a] != null && index[e.b] != null && e.a != e.b) (index[e.a]!, index[e.b]!, e),
  ];
  final x = List<double>.filled(n, 0), y = List<double>.filled(n, 0);
  final focus = g.focus != null ? index[g.focus] : null;
  var sectors = <({LinkKind kind, double angle, double r})>[];
  if (focus != null) {
    sectors = _rings(g, focus, links, radius, x, y);
  } else if (start != null && g.nodes.every((v) => start.containsKey(v.id))) {
    // From where they sit on the whole map, drawn together: the same rough
    // arrangement, without the long empty stretches between them.
    final xs = [for (final v in g.nodes) start[v.id]!.x], ys = [for (final v in g.nodes) start[v.id]!.y];
    final minX = xs.reduce(math.min), minY = ys.reduce(math.min);
    final span = math.max(1.0, math.max(xs.reduce(math.max) - minX, ys.reduce(math.max) - minY));
    for (var i = 0; i < n; i++) {
      x[i] = (xs[i] - minX) / span * size;
      y[i] = (ys[i] - minY) / span * size;
    }
    _forces(g, links, size, 140, x, y, seeded: true, heatFrom: size / 20, aspect: aspect);
  } else {
    _forces(g, links, size, rounds, x, y, aspect: aspect);
  }
  _apart(radius, x, y, fixed: focus);

  // Into a square with room at its edges for the names under the nodes:
  // spread to fill it when small, the square made bigger when not.
  const margin = 130.0;
  var minX = x.reduce(math.min), maxX = x.reduce(math.max);
  var minY = y.reduce(math.min), maxY = y.reduce(math.max);
  if (focus != null) {
    // Round someone: they stay in the middle of the square.
    final reach = [minX, maxX, minY, maxY].map((v) => v.abs()).reduce(math.max);
    minX = minY = -reach;
    maxX = maxY = reach;
  }
  // Round someone, a square; the whole web, the shape of the screen.
  final tall = focus == null ? aspect : 1.0;
  var spanX = math.max(maxX - minX, 1.0), spanY = math.max(maxY - minY, 1.0);
  if (focus == null && n > 2 && spanY / spanX < tall * 0.9) {
    // Drawn out to the screen's shape: only ever further apart.
    final stretch = math.min(tall * 0.9 / (spanY / spanX), 1.8);
    for (var i = 0; i < n; i++) {
      y[i] = minY + (y[i] - minY) * stretch;
    }
    maxY = minY + (maxY - minY) * stretch;
    spanY = maxY - minY;
  }
  final grow = n == 1 ? 1.0 : math.max(1.0, math.min((size - 2 * margin) / spanX, (size * tall - 2 * margin) / spanY));
  final side = math.max(size, spanX * grow + 2 * margin);
  final high = math.max(size * tall, spanY * grow + 2 * margin);
  final offX = (side - spanX * grow) / 2, offY = (high - spanY * grow) / 2;
  return (
    at: {
      for (final v in g.nodes)
        v.id: (
          x: n == 1 ? side / 2 : offX + (x[index[v.id]!] - minX) * grow,
          y: n == 1 ? high / 2 : offY + (y[index[v.id]!] - minY) * grow,
        ),
    },
    size: side,
    height: high,
    // Each section's name between the focus and its part of the ring.
    sectors: [
      for (final c in sectors)
        (
          kind: c.kind,
          x: offX + (math.cos(c.angle) * c.r * 0.58 - minX) * grow,
          y: offY + (math.sin(c.angle) * c.r * 0.58 - minY) * grow,
        ),
    ],
  );
}

/// The rings round [focus], seated like a stadium. Those linked to the
/// focus are in front: each way of being linked (family, allies, enemies,
/// groups…) has its own wedge, the closest in its front row and the rest in
/// the rows behind. Those further out (two links and more) sit in rows
/// round the outside, each near those it links to.
List<({LinkKind kind, double angle, double r})> _rings(
    GraphData g, int focus, List<(int, int, GraphEdge)> links, List<double> radius, List<double> x, List<double> y) {
  final n = g.nodes.length;
  final next = List.generate(n, (_) => <int>{});
  for (final (a, b, _) in links) {
    next[a].add(b);
    next[b].add(a);
  }
  final hops = List<int>.filled(n, -1)..[focus] = 0;
  final queue = [focus];
  for (var i = 0; i < queue.length; i++) {
    for (final m in next[queue[i]]) {
      if (hops[m] < 0) {
        hops[m] = hops[queue[i]] + 1;
        queue.add(m);
      }
    }
  }
  for (var i = 0; i < n; i++) {
    if (hops[i] < 0) hops[i] = 2; // not linked: with the far ones
    if (hops[i] > 2) hops[i] = 2;
  }
  // How each in front is linked to the focus, and how closely.
  final kindTo = <int, int>{};
  final close = List<double>.generate(n, (i) => math.sqrt(g.nodes[i].weight) + g.nodes[i].recent);
  for (final (a, b, e) in links) {
    final other = a == focus ? b : (b == focus ? a : null);
    if (other == null) continue;
    kindTo[other] = math.min(kindTo[other] ?? 99, e.kind.index);
    close[other] += e.related ? 40 : math.min(20, e.weight * 2.0);
  }
  const front = 300.0, row = 170.0, slot = 120.0;
  final angle = List<double>.filled(n, 0);
  final sectors = <({LinkKind kind, double angle, double r})>[];

  // In front: a wedge for each way of being linked, its share of the circle
  // by how many are in it, with a gap between wedges.
  final inFront = [
    for (var i = 0; i < n; i++)
      if (hops[i] == 1) i
  ];
  var outer = front;
  if (inFront.isNotEmpty) {
    final byKind = <int, List<int>>{};
    for (final i in inFront) {
      (byKind[kindTo[i] ?? LinkKind.shared.index] ??= []).add(i);
    }
    final kinds = byKind.keys.toList()..sort();
    const gap = 0.10;
    final open = 2 * math.pi - (kinds.length > 1 ? gap * kinds.length : 0);
    var start = -math.pi / 2;
    for (final k in kinds) {
      final members = byKind[k]!..sort((a, b) => close[b].compareTo(close[a]));
      final share = open * members.length / inFront.length;
      // Rows from the front, each holding as many as its arc has room for.
      var r = front, placed = 0;
      while (placed < members.length) {
        final room = math.max(1, (share * r / slot).floor());
        final take = math.min(room, members.length - placed);
        for (var j = 0; j < take; j++) {
          final i = members[placed + j];
          angle[i] = start + share * (j + 0.5) / take;
          x[i] = math.cos(angle[i]) * r;
          y[i] = math.sin(angle[i]) * r;
        }
        placed += take;
        outer = math.max(outer, r);
        r += row;
      }
      if (kinds.length > 1) {
        sectors
            .add((kind: LinkKind.values[math.min(k, LinkKind.values.length - 1)], angle: start + share / 2, r: front));
      }
      start += share + (kinds.length > 1 ? gap : 0);
    }
  }

  // Further out: rows round the outside, each near those it links to.
  final far = [
    for (var i = 0; i < n; i++)
      if (hops[i] == 2) i
  ];
  if (far.isNotEmpty) {
    double wanted(int i) {
      final inner = [
        for (final m in next[i])
          if (hops[m] == 1) angle[m]
      ];
      if (inner.isEmpty) return i * 2.399; // spread round evenly
      final sx = inner.fold(0.0, (t, a) => t + math.cos(a)), sy = inner.fold(0.0, (t, a) => t + math.sin(a));
      return math.atan2(sy, sx);
    }

    final want = {for (final i in far) i: wanted(i) % (2 * math.pi)};
    far.sort((a, b) => close[b].compareTo(close[a]));
    var r = outer + row * 1.4, placed = 0;
    while (placed < far.length) {
      final room = math.max(1, (2 * math.pi * r / slot).floor());
      final rowMembers = far.sublist(placed, math.min(far.length, placed + room))
        ..sort((a, b) => want[a]!.compareTo(want[b]!));
      // Evenly round the row, turned so each is near where it would be.
      var sx = 0.0, sy = 0.0;
      for (final (k, i) in rowMembers.indexed) {
        final even = 2 * math.pi * (k + 0.5) / rowMembers.length;
        sx += math.cos(want[i]! - even);
        sy += math.sin(want[i]! - even);
      }
      final turn = sx == 0 && sy == 0 ? 0.0 : math.atan2(sy, sx);
      for (final (k, i) in rowMembers.indexed) {
        angle[i] = 2 * math.pi * (k + 0.5) / rowMembers.length + turn;
        x[i] = math.cos(angle[i]) * r;
        y[i] = math.sin(angle[i]) * r;
      }
      placed += rowMembers.length;
      r += row;
    }
  }
  x[focus] = 0;
  y[focus] = 0;
  return sectors;
}

/// The whole web: linked nodes pull together, all push apart.
void _forces(GraphData g, List<(int, int, GraphEdge)> links, double size, int rounds, List<double> x, List<double> y,
    {bool seeded = false, double? heatFrom, double aspect = 1}) {
  final n = g.nodes.length;
  final rnd = math.Random(n * 7919 + g.edges.length);
  if (!seeded) {
    for (var i = 0; i < n; i++) {
      x[i] = size * (0.2 + 0.6 * rnd.nextDouble());
      y[i] = size * (0.2 + 0.6 * rnd.nextDouble());
    }
  }
  // Room enough for every node, however many.
  final k = math.max(size / math.sqrt(n) * 0.9, 120.0);
  var heat = heatFrom ?? size / 8;
  // Pushing apart only reaches so far: nodes are put in a grid of cells
  // that wide, and each pushes those in its own cell and the ones round it.
  // Thousands of nodes lay out in a moment; the pull to the middle keeps
  // the far ones together.
  final reach = k * 3;
  for (var round = 0; round < rounds; round++) {
    final dx = List<double>.filled(n, 0), dy = List<double>.filled(n, 0);
    final grid = <(int, int), List<int>>{};
    for (var i = 0; i < n; i++) {
      (grid[((x[i] / reach).floor(), (y[i] / reach).floor())] ??= []).add(i);
    }
    for (final MapEntry(key: (cx, cy), value: cell) in grid.entries) {
      for (var ox = -1; ox <= 1; ox++) {
        for (var oy = -1; oy <= 1; oy++) {
          final other = grid[(cx + ox, cy + oy)];
          if (other == null) continue;
          for (final i in cell) {
            for (final j in other) {
              if (j <= i) continue;
              var ex = x[i] - x[j], ey = y[i] - y[j];
              var d = math.sqrt(ex * ex + ey * ey);
              if (d > reach) continue;
              if (d < 0.01) {
                ex = rnd.nextDouble() - 0.5;
                ey = rnd.nextDouble() - 0.5;
                d = 0.5;
              }
              final f = k * k / d;
              dx[i] += ex / d * f;
              dy[i] += ey / d * f;
              dx[j] -= ex / d * f;
              dy[j] -= ey / d * f;
            }
          }
        }
      }
    }
    for (final (a, b, e) in links) {
      final w = e.related ? 1.0 : 0.5;
      final ex = x[a] - x[b], ey = y[a] - y[b];
      final d = math.max(0.01, math.sqrt(ex * ex + ey * ey));
      final f = d * d / k * w;
      dx[a] -= ex / d * f;
      dy[a] -= ey / d * f;
      dx[b] += ex / d * f;
      dy[b] += ey / d * f;
    }
    for (var i = 0; i < n; i++) {
      // A pull to the middle keeps lone nodes from drifting off.
      // (Weaker up and down for a tall screen, so the web grows tall.)
      dx[i] += (size / 2 - x[i]) * 0.06 * k / 10;
      dy[i] += (size / 2 - y[i]) * 0.06 * k / 10 / (aspect * aspect);
      final d = math.max(0.01, math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]));
      x[i] += dx[i] / d * math.min(d, heat);
      y[i] += dy[i] / d * math.min(d, heat);
    }
    heat = math.max(1, heat * 0.985);
  }
}

/// Nodes that overlap (or crowd each other's names) pushed apart, [fixed]
/// staying where it is.
void _apart(List<double> radius, List<double> x, List<double> y, {int? fixed}) {
  final n = x.length;
  if (n < 2) return;
  final cellSize = radius.reduce(math.max) * 2 + 48;
  for (var round = 0; round < 120; round++) {
    var moved = false;
    final grid = <(int, int), List<int>>{};
    for (var i = 0; i < n; i++) {
      (grid[((x[i] / cellSize).floor(), (y[i] / cellSize).floor())] ??= []).add(i);
    }
    final pairs = <(int, int)>[];
    for (final MapEntry(key: (cx, cy), value: cell) in grid.entries) {
      for (var ox = -1; ox <= 1; ox++) {
        for (var oy = -1; oy <= 1; oy++) {
          final other = grid[(cx + ox, cy + oy)];
          if (other == null) continue;
          for (final i in cell) {
            for (final j in other) {
              if (j > i) pairs.add((i, j));
            }
          }
        }
      }
    }
    for (final (i, j) in pairs) {
      {
        final want = radius[i] + radius[j] + 48;
        var ex = x[j] - x[i], ey = y[j] - y[i];
        var d = math.sqrt(ex * ex + ey * ey);
        if (d >= want) continue;
        if (d < 0.01) {
          ex = math.cos(i * 2.4 + j);
          ey = math.sin(i * 2.4 + j);
          d = 1;
        }
        final push = (want - d) / 2 + 0.5;
        final ux = ex / d * push, uy = ey / d * push;
        if (i != fixed) {
          x[i] -= j == fixed ? ux * 2 : ux;
          y[i] -= j == fixed ? uy * 2 : uy;
        }
        if (j != fixed) {
          x[j] += i == fixed ? ux * 2 : ux;
          y[j] += i == fixed ? uy * 2 : uy;
        }
        moved = true;
      }
    }
    if (!moved) break;
  }
}

/// What the graph screen draws, made off the UI thread: the graph, where
/// its nodes sit, the side of their square, the sections of the ring round
/// the focus, and, for the whole web, each node's group.
typedef GraphView = ({
  GraphData data,
  Map<int, ({double x, double y})> at,
  double size,
  double height,
  List<GraphSector> sectors,
  Map<int, int> cluster,
});

/// The graph and where its nodes sit. Round someone, laid out afresh as
/// rings; the whole web, on its saved map (see [wholeWeb]), so its nodes
/// stay where they are however many are shown.
GraphView graphAndLayout(
  String path, {
  int? at,
  int? here,
  int? focus,
  int depth = 1,
  int most = 120,
  Set<String>? kinds,
  int minChapters = 1,
  double aspect = 1,
}) {
  final g =
      graphAt(path, at: at, here: here, focus: focus, depth: depth, most: most, kinds: kinds, minChapters: minChapters);
  if (focus == null && g.nodes.isNotEmpty) {
    final m = MemoryDb.open(path);
    try {
      final map = wholeWeb(m);
      // A few of many: drawn together from where they sit on the map.
      if (g.nodes.length < map.at.length * 0.6 && g.nodes.every((n) => map.at.containsKey(n.id))) {
        final l = layoutGraph(g, start: map.at, aspect: aspect);
        return (
          data: g,
          at: l.at,
          size: l.size,
          height: l.height,
          sectors: const [],
          cluster: {for (final n in g.nodes) n.id: map.cluster[n.id] ?? 0},
        );
      }
      if (g.nodes.every((n) => map.at.containsKey(n.id))) {
        return (
          data: g,
          at: {for (final n in g.nodes) n.id: map.at[n.id]!},
          size: map.size,
          height: map.height,
          sectors: const [],
          cluster: {for (final n in g.nodes) n.id: map.cluster[n.id] ?? 0},
        );
      }
    } finally {
      m.close();
    }
  }
  final l = layoutGraph(g, aspect: aspect);
  return (data: g, at: l.at, size: l.size, height: l.height, sectors: l.sectors, cluster: const {});
}

/// Where each node sits in three dimensions, for the graph seen as a ball
/// to turn: round someone, they are at the middle and each ring of the flat
/// graph is a shell round them; the whole web, a ball. Linked nodes pull
/// together, all push apart, none overlapping, the same each time.
Map<int, ({double x, double y, double z})> layoutGraph3d(GraphData g, {int rounds = 220}) {
  final n = g.nodes.length;
  if (n == 0) return const {};
  final index = {for (final (i, v) in g.nodes.indexed) v.id: i};
  final radius = [for (final v in g.nodes) nodeDp(v.weight) * canvasPerDp];
  final links = [
    for (final e in g.edges)
      if (index[e.a] != null && index[e.b] != null && e.a != e.b) (index[e.a]!, index[e.b]!, e.related ? 1.0 : 0.5),
  ];
  final focus = g.focus != null ? index[g.focus] : null;
  // How many links out from the focus each is (none: everyone in one ball).
  final hops = List<int>.filled(n, 1);
  if (focus != null) {
    final next = List.generate(n, (_) => <int>{});
    for (final (a, b, _) in links) {
      next[a].add(b);
      next[b].add(a);
    }
    hops.fillRange(0, n, -1);
    hops[focus] = 0;
    final queue = [focus];
    for (var i = 0; i < queue.length; i++) {
      for (final m in next[queue[i]]) {
        if (hops[m] < 0) {
          hops[m] = hops[queue[i]] + 1;
          queue.add(m);
        }
      }
    }
    final deepest = hops.reduce(math.max);
    for (var i = 0; i < n; i++) {
      if (hops[i] < 0) hops[i] = deepest + 1;
    }
  }
  // Each shell big enough for its nodes to sit apart on it.
  final shell = <int, double>{};
  for (var h = 1; h <= hops.reduce(math.max); h++) {
    final area = [
      for (var i = 0; i < n; i++)
        if (hops[i] == h) math.pow(radius[i] * 2 + 60, 2)
    ].fold(0.0, (t, a) => t + a);
    // Roomy, so that seen from any side the near ones hide few behind them.
    shell[h] = math.max((shell[h - 1] ?? 0) + 340, math.sqrt(area / (4 * math.pi)) * 2.0);
  }
  // Start on spheres (a Fibonacci spiral each), then let the forces work.
  final x = List<double>.filled(n, 0), y = List<double>.filled(n, 0), z = List<double>.filled(n, 0);
  final onShell = <int, int>{};
  final count = <int, int>{};
  for (final h in hops) {
    count[h] = (count[h] ?? 0) + 1;
  }
  for (var i = 0; i < n; i++) {
    if (i == focus) continue;
    final h = hops[i];
    final k = onShell[h] = (onShell[h] ?? -1) + 1;
    final m = count[h]!;
    final t = (k + 0.5) / m;
    final phi = math.acos(1 - 2 * t), theta = math.pi * (1 + math.sqrt(5)) * k;
    final r = shell[h] ?? 300;
    x[i] = r * math.sin(phi) * math.cos(theta);
    y[i] = r * math.sin(phi) * math.sin(theta);
    z[i] = r * math.cos(phi);
  }
  final spread = math.max(160.0, 900 / math.pow(n, 1 / 3));
  var heat = 60.0;
  for (var round = 0; round < rounds; round++) {
    final dx = List<double>.filled(n, 0), dy = List<double>.filled(n, 0), dz = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final ex = x[i] - x[j], ey = y[i] - y[j], ez = z[i] - z[j];
        final d = math.max(1.0, math.sqrt(ex * ex + ey * ey + ez * ez));
        var f = spread * spread / d / 8;
        final room = radius[i] + radius[j] + 48;
        if (d < room) f += (room - d) * 4;
        dx[i] += ex / d * f;
        dy[i] += ey / d * f;
        dz[i] += ez / d * f;
        dx[j] -= ex / d * f;
        dy[j] -= ey / d * f;
        dz[j] -= ez / d * f;
      }
    }
    for (final (a, b, w) in links) {
      final ex = x[a] - x[b], ey = y[a] - y[b], ez = z[a] - z[b];
      final d = math.max(1.0, math.sqrt(ex * ex + ey * ey + ez * ez));
      final f = d * d / spread * w / 4;
      dx[a] -= ex / d * f;
      dy[a] -= ey / d * f;
      dz[a] -= ez / d * f;
      dx[b] += ex / d * f;
      dy[b] += ey / d * f;
      dz[b] += ez / d * f;
    }
    for (var i = 0; i < n; i++) {
      if (i == focus) continue;
      final d = math.max(1.0, math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]));
      // Held to its shell round the focus; the whole web, to the middle.
      final pull = focus == null ? -d * 0.02 : ((shell[hops[i]] ?? d) - d) * 0.6;
      dx[i] += x[i] / d * pull;
      dy[i] += y[i] / d * pull;
      dz[i] += z[i] / d * pull;
      final m = math.max(0.01, math.sqrt(dx[i] * dx[i] + dy[i] * dy[i] + dz[i] * dz[i]));
      x[i] += dx[i] / m * math.min(m, heat);
      y[i] += dy[i] / m * math.min(m, heat);
      z[i] += dz[i] / m * math.min(m, heat);
    }
    heat = math.max(2, heat * 0.985);
  }
  if (focus == null) {
    // The ball's middle at the middle.
    final cx = x.reduce((a, b) => a + b) / n, cy = y.reduce((a, b) => a + b) / n, cz = z.reduce((a, b) => a + b) / n;
    for (var i = 0; i < n; i++) {
      x[i] -= cx;
      y[i] -= cy;
      z[i] -= cz;
    }
  }
  return {for (final v in g.nodes) v.id: (x: x[index[v.id]!], y: y[index[v.id]!], z: z[index[v.id]!])};
}

/// Communities in a weighted graph, by Louvain: each node joins the
/// neighbouring group that most raises how tightly knit the groups are,
/// then the groups are merged into nodes and it goes again. Returns a group
/// number for each node, the biggest group first, the same each time.
List<int> louvain(int n, List<(int, int, double)> links, {double resolution = 1}) {
  if (n == 0) return const [];
  // The graph at this level: adjacency with weights, self-loops kept.
  var size = n;
  var adj = List.generate(size, (_) => <int, double>{});
  for (final (a, b, w) in links) {
    if (a == b) continue;
    adj[a][b] = (adj[a][b] ?? 0) + w;
    adj[b][a] = (adj[b][a] ?? 0) + w;
  }
  var member = List<int>.generate(n, (i) => i); // original node → node at this level
  for (var level = 0; level < 12; level++) {
    final degree = [for (final row in adj) row.values.fold(0.0, (t, w) => t + w)];
    final total = degree.fold(0.0, (t, w) => t + w);
    if (total == 0) break;
    final group = List<int>.generate(size, (i) => i);
    final groupDegree = [...degree];
    var improved = false;
    for (var pass = 0; pass < 20; pass++) {
      var moved = false;
      for (var i = 0; i < size; i++) {
        final own = group[i];
        // The weight from i into each neighbouring group.
        final into = <int, double>{};
        for (final MapEntry(key: j, value: w) in adj[i].entries) {
          if (j == i) continue;
          into[group[j]] = (into[group[j]] ?? 0) + w;
        }
        groupDegree[own] -= degree[i];
        var best = own;
        var bestGain = (into[own] ?? 0) - resolution * groupDegree[own] * degree[i] / total;
        for (final MapEntry(key: c, value: w) in into.entries) {
          final gain = w - resolution * groupDegree[c] * degree[i] / total;
          if (gain > bestGain + 1e-12 || (gain > bestGain - 1e-12 && c < best && gain >= bestGain)) {
            best = c;
            bestGain = gain;
          }
        }
        groupDegree[best] += degree[i];
        if (best != own) {
          group[i] = best;
          moved = true;
          improved = true;
        }
      }
      if (!moved) break;
    }
    if (!improved) break;
    // Groups renumbered and made into the next level's nodes.
    final renumber = <int, int>{};
    for (final c in group) {
      renumber.putIfAbsent(c, () => renumber.length);
    }
    final next = List.generate(renumber.length, (_) => <int, double>{});
    for (var i = 0; i < size; i++) {
      for (final MapEntry(key: j, value: w) in adj[i].entries) {
        final a = renumber[group[i]]!, b = renumber[group[j]]!;
        next[a][b] = (next[a][b] ?? 0) + w;
      }
    }
    member = [for (final m in member) renumber[group[m]]!];
    if (renumber.length == size) break;
    size = renumber.length;
    adj = next;
  }
  // The biggest group first.
  final counts = <int, int>{};
  for (final m in member) {
    counts[m] = (counts[m] ?? 0) + 1;
  }
  final order = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!) == 0 ? a.compareTo(b) : counts[b]!.compareTo(counts[a]!));
  final rank = {for (final (i, c) in order.indexed) c: i};
  return [for (final m in member) rank[m]!];
}

/// Everyone in the memory placed once, and kept: the whole web's map, as
/// islands. The cast is split into groups (by [louvain]); each group is laid
/// out on its own, as an island, and the islands are set beside each other,
/// those that share the most links nearest, in a tall shape for the phone.
/// Its nodes stay where they are however many are shown. Made again only
/// when the memory has grown.
({Map<int, ({double x, double y})> at, Map<int, int> cluster, double size, double height}) wholeWeb(MemoryDb m) {
  m.db.execute('CREATE TABLE IF NOT EXISTS graph_places(entity INTEGER PRIMARY KEY, x REAL, y REAL, cluster INTEGER)');
  final sig = [
    'islands2',
    m.db.select('SELECT count(*) n FROM entities WHERE merged_into IS NULL').first['n'],
    m.db.select('SELECT count(*) n FROM relations').first['n'],
    m.db.select('SELECT coalesce(max(ch), -1) n FROM notes').first['n'],
  ].join(':');
  ({Map<int, ({double x, double y})> at, Map<int, int> cluster, double size, double height}) stored() {
    final at = <int, ({double x, double y})>{}, cluster = <int, int>{};
    for (final r in m.db.select('SELECT entity, x, y, cluster FROM graph_places')) {
      at[r['entity'] as int] = (x: r['x'] as double, y: r['y'] as double);
      cluster[r['entity'] as int] = r['cluster'] as int;
    }
    final w = at.values.fold(1000.0, (s, p) => math.max(s, p.x + 130));
    final h = at.values.fold(1000.0, (s, p) => math.max(s, p.y + 130));
    return (at: at, cluster: cluster, size: w, height: h);
  }

  if (m.meta('graph_places') == sig) return stored();

  final ids = [
    for (final r
        in m.db.select('SELECT e.id, (SELECT count(*) FROM appearances a WHERE a.entity = e.id) w FROM entities e '
            'WHERE e.merged_into IS NULL ORDER BY w DESC, e.id'))
      (id: r['id'] as int, w: r['w'] as int),
  ];
  final n = ids.length;
  if (n == 0) return (at: const {}, cluster: const {}, size: 1000, height: 1000);
  final index = {for (final (i, v) in ids.indexed) v.id: i};
  final weights = <(int, int), double>{};
  for (final r in m.db.select('SELECT a, b FROM relations WHERE a != b')) {
    final a = index[r['a']], b = index[r['b']];
    if (a == null || b == null) continue;
    final k = a < b ? (a, b) : (b, a);
    weights[k] = (weights[k] ?? 0) + 2;
  }
  for (final r in m.db.select('SELECT r1.entity a, r2.entity b, count(DISTINCT r1.event) n FROM event_roles r1 '
      'JOIN event_roles r2 ON r2.event = r1.event AND r2.entity > r1.entity GROUP BY r1.entity, r2.entity')) {
    final a = index[r['a']], b = index[r['b']];
    if (a == null || b == null) continue;
    final k = a < b ? (a, b) : (b, a);
    weights[k] = (weights[k] ?? 0) + math.min(3.0, (r['n'] as int) / 2);
  }
  final links = [for (final e in weights.entries) (e.key.$1, e.key.$2, e.value)];
  final found = louvain(n, links);
  // Groups of one or two (those linked to almost nobody) share one island.
  final sizes = <int, int>{};
  for (final g in found) {
    sizes[g] = (sizes[g] ?? 0) + 1;
  }
  final big = (sizes.keys.where((g) => sizes[g]! >= 3).toList()..sort());
  final renumber = {for (final (i, g) in big.indexed) g: i};
  final groups = [for (final g in found) renumber[g] ?? big.length];
  final radius = [for (final v in ids) nodeDp(v.w) * canvasPerDp];

  // Each island laid out on its own, round its middle.
  final count = groups.fold(0, math.max) + 1;
  final members = List.generate(count, (_) => <int>[]);
  for (var i = 0; i < n; i++) {
    members[groups[i]].add(i);
  }
  final x = List<double>.filled(n, 0), y = List<double>.filled(n, 0);
  final reach = List<double>.filled(count, 0);
  for (var c = 0; c < count; c++) {
    final ms = members[c];
    if (ms.isEmpty) continue;
    final local = {for (final (k, i) in ms.indexed) i: k};
    final g = GraphData(
      nodes: [for (final i in ms) GraphNode(id: ids[i].id, name: '', kind: '', weight: ids[i].w)],
      edges: const [],
      lastCh: 0,
    );
    // From a spiral, the best-known in the middle: a disc, not a ring.
    final lx = [for (var k = 0; k < ms.length; k++) math.cos(k * 2.399) * math.sqrt(k + 0.5) * 70];
    final ly = [for (var k = 0; k < ms.length; k++) math.sin(k * 2.399) * math.sqrt(k + 0.5) * 70];
    if (ms.length > 1) {
      final inner = [
        for (final (a, b, w) in links)
          if (local.containsKey(a) && local.containsKey(b))
            (
              local[a]!,
              local[b]!,
              GraphEdge(a: ids[a].id, b: ids[b].id, label: '', kind: LinkKind.other, fromCh: 0, weight: w.round()),
            ),
      ];
      final side = 300 + math.sqrt(ms.length) * 120;
      if (inner.isNotEmpty) {
        for (var k = 0; k < ms.length; k++) {
          lx[k] += side / 2;
          ly[k] += side / 2;
        }
        _forces(g, inner, side, 200, lx, ly, seeded: true);
      }
      _apart([for (final i in ms) radius[i]], lx, ly);
    }
    final cx = lx.reduce((a, b) => a + b) / ms.length, cy = ly.reduce((a, b) => a + b) / ms.length;
    for (final (k, i) in ms.indexed) {
      x[i] = lx[k] - cx;
      y[i] = ly[k] - cy;
      reach[c] = math.max(reach[c], math.sqrt(x[i] * x[i] + y[i] * y[i]) + radius[i]);
    }
    reach[c] += 50;
  }

  // The islands set beside each other: pulled together by the links between
  // them, kept from touching, in a tall shape.
  final between = <(int, int), double>{};
  for (final (a, b, w) in links) {
    final ga = groups[a], gb = groups[b];
    if (ga == gb) continue;
    final k = ga < gb ? (ga, gb) : (gb, ga);
    between[k] = (between[k] ?? 0) + w;
  }
  final cxs = List<double>.filled(count, 0), cys = List<double>.filled(count, 0);
  var spiral = 0.0;
  for (var c = 0; c < count; c++) {
    // Biggest first, round a spiral.
    final a = c * 2.399;
    spiral = c == 0 ? 0 : spiral + reach[c] * 0.6;
    cxs[c] = math.cos(a) * spiral;
    cys[c] = math.sin(a) * spiral * 1.6;
  }
  for (var round = 0; round < 400; round++) {
    final fx = List<double>.filled(count, 0), fy = List<double>.filled(count, 0);
    for (var a = 0; a < count; a++) {
      for (var b = a + 1; b < count; b++) {
        var ex = cxs[b] - cxs[a], ey = cys[b] - cys[a];
        var d = math.sqrt(ex * ex + ey * ey);
        if (d < 0.01) {
          ex = math.cos(a + b * 1.7);
          ey = math.sin(a + b * 1.7);
          d = 1;
        }
        final want = reach[a] + reach[b] + 40;
        if (d < want) {
          final push = (want - d) / 2;
          fx[a] -= ex / d * push;
          fy[a] -= ey / d * push;
          fx[b] += ex / d * push;
          fy[b] += ey / d * push;
        } else {
          final w = between[(a, b)] ?? 0;
          if (w > 0) {
            final pull = math.min(d - want, 30.0) * math.min(1.0, w / 20);
            fx[a] += ex / d * pull;
            fy[a] += ey / d * pull;
            fx[b] -= ex / d * pull;
            fy[b] -= ey / d * pull;
          }
        }
      }
    }
    for (var c = 0; c < count; c++) {
      // Towards the middle, more strongly from the sides: a tall shape.
      fx[c] -= cxs[c] * 0.02;
      fy[c] -= cys[c] * 0.008;
      cxs[c] += fx[c].clamp(-60, 60);
      cys[c] += fy[c].clamp(-60, 60);
    }
  }
  // No two islands touching, however the forces left them.
  for (var round = 0; round < 300; round++) {
    var moved = false;
    for (var a = 0; a < count; a++) {
      for (var b = a + 1; b < count; b++) {
        var ex = cxs[b] - cxs[a], ey = cys[b] - cys[a];
        var d = math.sqrt(ex * ex + ey * ey);
        final want = reach[a] + reach[b] + 30;
        if (d >= want) continue;
        if (d < 0.01) {
          ex = 1;
          ey = 0;
          d = 1;
        }
        final push = (want - d) / 2 + 1;
        cxs[a] -= ex / d * push;
        cys[a] -= ey / d * push;
        cxs[b] += ex / d * push;
        cys[b] += ey / d * push;
        moved = true;
      }
    }
    if (!moved) break;
  }
  for (var i = 0; i < n; i++) {
    x[i] += cxs[groups[i]];
    y[i] += cys[groups[i]];
  }

  final minX = x.reduce(math.min), minY = y.reduce(math.min);
  m.db.execute('BEGIN');
  try {
    m.db.execute('DELETE FROM graph_places');
    final put = m.db.prepare('INSERT INTO graph_places(entity, x, y, cluster) VALUES (?, ?, ?, ?)');
    for (var i = 0; i < n; i++) {
      put.execute([ids[i].id, x[i] - minX + 130, y[i] - minY + 130, groups[i]]);
    }
    put.close();
    m.setMeta('graph_places', sig);
    m.db.execute('COMMIT');
  } on Object {
    m.db.execute('ROLLBACK');
    rethrow;
  }
  return stored();
}

/// What the AI is told of each group to name it: its best-known members
/// (up to ten) and what each is, keyed by the group's number.
Map<int, String> groupBriefs(String path, Map<int, List<int>> members) {
  final m = MemoryDb.open(path);
  try {
    return {
      for (final MapEntry(key: g, value: ids) in members.entries)
        g: [
          for (final id in ids.take(10))
            for (final r in m.db.select('SELECT name, kind, about FROM entities WHERE id = ?', [id]))
              '${r['name']} (${r['kind']})${(r['about'] as String?)?.isNotEmpty == true ? ': ${r['about']}' : ''}',
        ].join('; '),
    };
  } finally {
    m.close();
  }
}

/// The names kept for groups, by the key made of their best-known members.
Map<String, String> groupNames(String path, Iterable<String> keys) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute('CREATE TABLE IF NOT EXISTS graph_group_names(k TEXT PRIMARY KEY, name TEXT NOT NULL)');
    return {
      for (final k in keys)
        for (final r in m.db.select('SELECT name FROM graph_group_names WHERE k = ?', [k])) k: r['name'] as String,
    };
  } finally {
    m.close();
  }
}

void keepGroupNames(String path, Map<String, String> names) {
  final m = MemoryDb.open(path);
  try {
    m.db.execute('CREATE TABLE IF NOT EXISTS graph_group_names(k TEXT PRIMARY KEY, name TEXT NOT NULL)');
    for (final e in names.entries) {
      m.db.execute('INSERT OR REPLACE INTO graph_group_names(k, name) VALUES (?, ?)', [e.key, e.value]);
    }
  } finally {
    m.close();
  }
}
