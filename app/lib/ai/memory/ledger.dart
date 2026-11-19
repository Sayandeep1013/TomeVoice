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
List<LedgerEntry> ledger(String path, {int? at, String? kind, String query = '', LedgerOrder order = LedgerOrder.importance}) {
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
  const GraphNode({required this.id, required this.name, required this.kind, required this.weight, this.firstCh});

  final int id;
  final String name;
  final String kind;

  /// Chapters it appears in, up to the line.
  final int weight;

  /// The chapter it is first met in: before it, the timeline hides it.
  final int? firstCh;
}

/// What a link is, for its colour: a bond (ally, friend, love), a conflict
/// (enemy, rival, betrayal), family, belonging (member, servant, owner),
/// another relation, or only events shared.
enum LinkKind { bond, conflict, family, belongs, other, shared }

/// The kind of relation [rel] names.
LinkKind linkKindOf(String rel) {
  final r = rel.toLowerCase();
  bool has(List<String> words) => words.any(r.contains);
  if (has(['enem', 'rival', 'betray', 'hunt', 'oppos', 'against', 'distrust', 'hate', 'kill', 'fight', 'feud', 'war'])) {
    return LinkKind.conflict;
  }
  if (has(['parent', 'child', 'sibling', 'brother', 'sister', 'father', 'mother', 'son', 'daughter', 'family',
    'married', 'spouse', 'wife', 'husband', 'cousin', 'uncle', 'aunt', 'grand'])) {
    return LinkKind.family;
  }
  if (has(['member', 'leader', 'serv', 'owns', 'owner', 'bound', 'belong', 'part of', 'rules', 'works for', 'keeper',
    'commands', 'head of', 'citizen', 'resident'])) {
    return LinkKind.belongs;
  }
  if (has(['ally', 'allie', 'friend', 'love', 'trust', 'mentor', 'companion', 'protect', 'partner', 'lover', 'admire',
    'loyal', 'help', 'saved'])) {
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
  const GraphData({required this.nodes, required this.edges, required this.lastCh, this.focus});

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

/// The memory graph up to chapter [at] (the spoiler line; null: all of it),
/// every link with the chapters it held, so a timeline can show any chapter
/// before it without the nodes moving. The [most] entities that matter most
/// (of [kinds], when given; in at least [minChapters] chapters), or, with
/// [focus], that entity and those within [depth] links of it.
GraphData graphAt(
  String path, {
  int? at,
  int? focus,
  int depth = 1,
  int most = 120,
  Set<String>? kinds,
  int minChapters = 1,
}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    final last = (m.db.select('SELECT max(ch) last FROM notes').first['last'] as int?) ?? 0;
    final kindIn = kinds == null || kinds.isEmpty
        ? ''
        : " AND e.kind IN (${kinds.map((k) => "'${k.replaceAll("'", "''")}'").join(',')})";
    Map<int, GraphNode> nodesOf(String where, int limit) => {
          for (final r in m.db.select(
            'SELECT * FROM (SELECT e.id, e.name, e.kind, e.first_ch, '
            '(SELECT count(*) FROM appearances a WHERE a.entity = e.id AND a.ch <= $line) w '
            'FROM entities e WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= $line$kindIn AND $where) '
            'WHERE w >= $minChapters OR id = ${focus ?? -1} ORDER BY w DESC LIMIT $limit',
          ))
            r['id'] as int: GraphNode(
              id: r['id'] as int,
              name: r['name'] as String,
              kind: r['kind'] as String,
              weight: r['w'] as int,
              firstCh: r['first_ch'] as int?,
            ),
        };

    Map<int, GraphNode> nodes;
    if (focus != null) {
      final near = <int>{focus};
      var ring = <int>{focus};
      for (var hop = 0; hop < depth && near.length < most; hop++) {
        final next = <int>{};
        final list = ring.join(',');
        for (final r in m.db.select(
          'SELECT a, b FROM relations WHERE (a IN ($list) OR b IN ($list)) AND from_ch <= ?',
          [line],
        )) {
          next
            ..add(r['a'] as int)
            ..add(r['b'] as int);
        }
        for (final r in m.db.select(
          'SELECT r2.entity e, count(DISTINCT r1.event) n FROM event_roles r1 JOIN event_roles r2 ON r2.event = r1.event '
          'JOIN events v ON v.id = r1.event WHERE r1.entity IN ($list) AND r2.entity NOT IN ($list) AND v.ch <= ? '
          'GROUP BY r2.entity ORDER BY n DESC LIMIT 60',
          [line],
        )) {
          next.add(r['e'] as int);
        }
        next.removeAll(near);
        near.addAll(next.take(most - near.length));
        ring = next;
      }
      nodes = nodesOf('e.id IN (${near.join(',')})', most);
    } else {
      nodes = nodesOf('1 = 1', most);
    }
    if (nodes.isEmpty) return GraphData(nodes: const [], edges: const [], lastCh: last, focus: focus);
    final ids = nodes.keys.join(',');
    final edges = <GraphEdge>[];
    final related = <(int, int)>{};
    for (final r in m.db.select(
      'SELECT a, b, rel, from_ch, until_ch FROM relations WHERE a IN ($ids) AND b IN ($ids) AND a != b AND from_ch <= ? '
      'ORDER BY from_ch',
      [line],
    )) {
      final a = r['a'] as int, b = r['b'] as int;
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
    for (final r in m.db.select(
      'SELECT r1.entity a, r2.entity b, count(DISTINCT r1.event) n, min(v.ch) first FROM event_roles r1 '
      'JOIN event_roles r2 ON r2.event = r1.event AND r2.entity > r1.entity JOIN events v ON v.id = r1.event '
      'WHERE r1.entity IN ($ids) AND r2.entity IN ($ids) AND v.ch <= ? GROUP BY r1.entity, r2.entity HAVING n >= 2',
      [line],
    )) {
      final a = r['a'] as int, b = r['b'] as int;
      if (related.contains((a, b))) continue;
      edges.add(GraphEdge(
        a: a,
        b: b,
        label: '${r['n']} events together',
        kind: LinkKind.shared,
        fromCh: r['first'] as int,
        weight: r['n'] as int,
      ));
    }
    return GraphData(nodes: nodes.values.toList(), edges: edges, lastCh: last, focus: focus);
  } finally {
    m.close();
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
            rel: (r['mine'] as int) == 1 ? r['rel'] as String : '${r['rel']} (of them)',
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
({Map<int, ({double x, double y})> at, double size}) layoutGraph(GraphData g, {double size = 1000, int rounds = 300}) {
  final n = g.nodes.length;
  if (n == 0) return (at: const {}, size: size);
  final index = {for (final (i, v) in g.nodes.indexed) v.id: i};
  final radius = [for (final v in g.nodes) nodeDp(v.weight) * canvasPerDp];
  final links = [
    for (final e in g.edges)
      if (index[e.a] != null && index[e.b] != null && e.a != e.b) (index[e.a]!, index[e.b]!, e),
  ];
  final x = List<double>.filled(n, 0), y = List<double>.filled(n, 0);
  final focus = g.focus != null ? index[g.focus] : null;
  if (focus != null) {
    _rings(g, focus, links, radius, x, y);
  } else {
    _forces(g, links, size, rounds, x, y);
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
  final span = math.max(math.max(maxX - minX, maxY - minY), 1.0);
  final grow = n == 1 ? 1.0 : math.max(1.0, (size - 2 * margin) / span);
  final side = math.max(size, span * grow + 2 * margin);
  final offX = (side - (maxX - minX) * grow) / 2, offY = (side - (maxY - minY) * grow) / 2;
  return (
    at: {
      for (final v in g.nodes)
        v.id: (
          x: n == 1 ? side / 2 : offX + (x[index[v.id]!] - minX) * grow,
          y: n == 1 ? side / 2 : offY + (y[index[v.id]!] - minY) * grow,
        ),
    },
    size: side,
  );
}

/// The rings round [focus]: how many links out each node is, the first
/// ring in order of how it is linked to the focus, each further ring in the
/// order of the nodes it links to in the ring inside it.
void _rings(GraphData g, int focus, List<(int, int, GraphEdge)> links, List<double> radius, List<double> x,
    List<double> y) {
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
  final deepest = hops.reduce(math.max);
  for (var i = 0; i < n; i++) {
    if (hops[i] < 0) hops[i] = deepest + 1; // not linked: the outermost ring
  }
  // How each of the first ring is linked to the focus.
  final kindTo = <int, int>{};
  for (final (a, b, e) in links) {
    final other = a == focus ? b : (b == focus ? a : null);
    if (other == null) continue;
    kindTo[other] = math.min(kindTo[other] ?? 99, e.kind.index);
  }
  final angle = List<double>.filled(n, 0);
  var ringR = 0.0;
  for (var ring = 1; ring <= hops.reduce(math.max); ring++) {
    final members = [for (var i = 0; i < n; i++) if (hops[i] == ring) i];
    if (members.isEmpty) continue;
    // Where each would like to be: by its link to the focus in the first
    // ring; further out, beside those it links to, inside.
    double wanted(int i) {
      if (ring == 1) return (kindTo[i] ?? 9) * 100.0 - g.nodes[i].weight / 1000;
      final inner = [for (final m in next[i]) if (hops[m] == ring - 1) angle[m]];
      if (inner.isEmpty) return 1000 + i.toDouble();
      // The mean of angles, taken as points on a circle.
      final sx = inner.fold(0.0, (t, a) => t + math.cos(a)), sy = inner.fold(0.0, (t, a) => t + math.sin(a));
      return math.atan2(sy, sx);
    }

    final want = {for (final i in members) i: wanted(i)};
    members.sort((a, b) => want[a]!.compareTo(want[b]!));
    // Each its share of the ring, by its size and room for its name.
    final arcs = [for (final i in members) radius[i] * 2 + 70];
    final round = arcs.fold(0.0, (t, a) => t + a);
    ringR = math.max(ringR + 230, round / (2 * math.pi));
    var at = 0.0;
    final placed = <double>[];
    for (final a in arcs) {
      placed.add((at + a / 2) / round * 2 * math.pi);
      at += a;
    }
    // Turned so that, further out, each sits as near its wanted angle as
    // the ring lets it.
    var turn = 0.0;
    if (ring > 1) {
      var sx = 0.0, sy = 0.0;
      for (final (k, i) in members.indexed) {
        final w = want[i]!;
        if (w >= 1000) continue;
        sx += math.cos(w - placed[k]);
        sy += math.sin(w - placed[k]);
      }
      if (sx != 0 || sy != 0) turn = math.atan2(sy, sx);
    } else {
      turn = -math.pi / 2;
    }
    for (final (k, i) in members.indexed) {
      angle[i] = placed[k] + turn;
      x[i] = math.cos(angle[i]) * ringR;
      y[i] = math.sin(angle[i]) * ringR;
    }
  }
  x[focus] = 0;
  y[focus] = 0;
}

/// The whole web: linked nodes pull together, all push apart.
void _forces(GraphData g, List<(int, int, GraphEdge)> links, double size, int rounds, List<double> x, List<double> y) {
  final n = g.nodes.length;
  final rnd = math.Random(n * 7919 + g.edges.length);
  for (var i = 0; i < n; i++) {
    x[i] = size * (0.2 + 0.6 * rnd.nextDouble());
    y[i] = size * (0.2 + 0.6 * rnd.nextDouble());
  }
  // Room enough for every node, however many.
  final k = math.max(size / math.sqrt(n) * 0.9, 120.0);
  var heat = size / 8;
  for (var round = 0; round < rounds; round++) {
    final dx = List<double>.filled(n, 0), dy = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ex = x[i] - x[j], ey = y[i] - y[j];
        var d = math.sqrt(ex * ex + ey * ey);
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
      dx[i] += (size / 2 - x[i]) * 0.06 * k / 10;
      dy[i] += (size / 2 - y[i]) * 0.06 * k / 10;
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
  for (var round = 0; round < 120; round++) {
    var moved = false;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
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

/// The graph at a chapter and where its nodes sit, made together off the
/// UI thread.
({GraphData data, Map<int, ({double x, double y})> at, double size}) graphAndLayout(
  String path, {
  int? at,
  int? focus,
  int depth = 1,
  int most = 120,
  Set<String>? kinds,
  int minChapters = 1,
}) {
  final g = graphAt(path, at: at, focus: focus, depth: depth, most: most, kinds: kinds, minChapters: minChapters);
  final l = layoutGraph(g);
  return (data: g, at: l.at, size: l.size);
}
