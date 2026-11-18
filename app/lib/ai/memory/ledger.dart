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

  /// Chapters it appears in, by the chapter shown.
  final int weight;
  final int? firstCh;
}

/// A link between two nodes: a relation, or events they shared.
class GraphEdge {
  const GraphEdge({required this.a, required this.b, required this.label, this.related = true, this.weight = 1});

  final int a;
  final int b;
  final String label;

  /// A relation the book stated (ally, sibling, member of), rather than
  /// events they took part in together.
  final bool related;
  final int weight;
}

class GraphData {
  const GraphData({required this.nodes, required this.edges, required this.lastCh, this.focus});

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  /// The last chapter the memory has notes for.
  final int lastCh;
  final int? focus;
}

/// The memory graph as it stood at chapter [at] (null: all of it): the
/// [most] entities that matter most (of [kinds], when given), or, with
/// [focus], that entity and those within two links of it; their relations
/// at that chapter, and the pairs who took part in events together.
GraphData graphAt(String path, {int? at, int? focus, int most = 120, Set<String>? kinds}) {
  final m = MemoryDb.open(path);
  try {
    final line = at ?? 1 << 30;
    final last = (m.db.select('SELECT max(ch) last FROM notes').first['last'] as int?) ?? 0;
    final kindIn = kinds == null || kinds.isEmpty ? '' : " AND e.kind IN (${kinds.map((k) => "'${k.replaceAll("'", "''")}'").join(',')})";
    Map<int, GraphNode> nodesOf(String where, List<Object?> args, int limit) => {
          for (final r in m.db.select(
            'SELECT e.id, e.name, e.kind, e.first_ch, '
            '(SELECT count(*) FROM appearances a WHERE a.entity = e.id AND a.ch <= $line) w '
            'FROM entities e WHERE e.merged_into IS NULL AND coalesce(e.first_ch, 0) <= $line$kindIn AND $where '
            'ORDER BY w DESC LIMIT $limit',
            args,
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
      for (var hop = 0; hop < 2 && near.length < most; hop++) {
        final next = <int>{};
        final list = ring.join(',');
        for (final r in m.db.select(
          'SELECT a, b FROM relations WHERE (a IN ($list) OR b IN ($list)) AND from_ch <= ? AND (until_ch IS NULL OR until_ch > ?)',
          [line, line],
        )) {
          next
            ..add(r['a'] as int)
            ..add(r['b'] as int);
        }
        for (final r in m.db.select(
          'SELECT DISTINCT r2.entity e FROM event_roles r1 JOIN event_roles r2 ON r2.event = r1.event '
          'JOIN events v ON v.id = r1.event WHERE r1.entity IN ($list) AND v.ch <= ? LIMIT 400',
          [line],
        )) {
          next.add(r['e'] as int);
        }
        next.removeAll(near);
        near.addAll(next.take(most - near.length));
        ring = next;
      }
      nodes = nodesOf('e.id IN (${near.join(',')})', const [], most);
    } else {
      nodes = nodesOf('1 = 1', const [], most);
    }
    if (nodes.isEmpty) return GraphData(nodes: const [], edges: const [], lastCh: last, focus: focus);
    final ids = nodes.keys.join(',');
    final edges = <(int, int), GraphEdge>{};
    for (final r in m.db.select(
      'SELECT a, b, rel FROM relations WHERE a IN ($ids) AND b IN ($ids) AND from_ch <= ? '
      'AND (until_ch IS NULL OR until_ch > ?) ORDER BY from_ch DESC',
      [line, line],
    )) {
      final a = r['a'] as int, b = r['b'] as int;
      final key = a < b ? (a, b) : (b, a);
      edges[key] ??= GraphEdge(a: a, b: b, label: r['rel'] as String);
    }
    for (final r in m.db.select(
      'SELECT r1.entity a, r2.entity b, count(DISTINCT r1.event) n FROM event_roles r1 '
      'JOIN event_roles r2 ON r2.event = r1.event AND r2.entity > r1.entity JOIN events v ON v.id = r1.event '
      'WHERE r1.entity IN ($ids) AND r2.entity IN ($ids) AND v.ch <= ? GROUP BY r1.entity, r2.entity HAVING n >= 2',
      [line],
    )) {
      final a = r['a'] as int, b = r['b'] as int;
      edges.putIfAbsent((a, b), () => GraphEdge(a: a, b: b, label: '${r['n']} events together', related: false, weight: r['n'] as int));
    }
    return GraphData(nodes: nodes.values.toList(), edges: edges.values.toList(), lastCh: last, focus: focus);
  } finally {
    m.close();
  }
}

/// Where each node sits: a force layout (linked nodes pull together, all
/// push apart), in a square of [size], the same each time for the same
/// graph. The heaviest node, or [GraphData.focus], at the middle.
Map<int, ({double x, double y})> layoutGraph(GraphData g, {double size = 1000, int rounds = 300}) {
  final n = g.nodes.length;
  if (n == 0) return const {};
  final rnd = math.Random(n * 7919 + g.edges.length);
  final index = {for (final (i, v) in g.nodes.indexed) v.id: i};
  final x = List<double>.generate(n, (_) => size * (0.2 + 0.6 * rnd.nextDouble()));
  final y = List<double>.generate(n, (_) => size * (0.2 + 0.6 * rnd.nextDouble()));
  final centre = g.focus != null && index.containsKey(g.focus) ? index[g.focus]! : 0;
  x[centre] = size / 2;
  y[centre] = size / 2;
  final k = size / math.sqrt(n) * 0.9;
  var heat = size / 8;
  final links = [
    for (final e in g.edges)
      if (index[e.a] != null && index[e.b] != null) (index[e.a]!, index[e.b]!, e.related ? 1.0 : 0.5),
  ];
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
    for (final (a, b, w) in links) {
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
      x[i] = x[i].clamp(size * 0.03, size * 0.97);
      y[i] = y[i].clamp(size * 0.03, size * 0.97);
    }
    if (g.focus != null && index.containsKey(g.focus)) {
      x[centre] = size / 2;
      y[centre] = size / 2;
    }
    heat = math.max(1, heat * 0.985);
  }
  // The web spread to fill the square, one scale both ways, with room at
  // its edges for the names drawn under the nodes (cut off at the screen's
  // edge on the phone).
  const margin = 0.12;
  var minX = x.reduce(math.min), maxX = x.reduce(math.max);
  var minY = y.reduce(math.min), maxY = y.reduce(math.max);
  final span = math.max(math.max(maxX - minX, maxY - minY), 1.0);
  final scale = size * (1 - 2 * margin) / span;
  final offX = (size - (maxX - minX) * scale) / 2, offY = (size - (maxY - minY) * scale) / 2;
  return {
    for (final v in g.nodes)
      v.id: (
        x: n == 1 ? size / 2 : offX + (x[index[v.id]!] - minX) * scale,
        y: n == 1 ? size / 2 : offY + (y[index[v.id]!] - minY) * scale,
      ),
  };
}

/// The graph at a chapter and where its nodes sit, made together off the
/// UI thread.
({GraphData data, Map<int, ({double x, double y})> at}) graphAndLayout(
  String path, {
  int? at,
  int? focus,
  int most = 120,
  Set<String>? kinds,
}) {
  final g = graphAt(path, at: at, focus: focus, most: most, kinds: kinds);
  return (data: g, at: layoutGraph(g));
}
