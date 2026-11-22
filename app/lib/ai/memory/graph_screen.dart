import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../talk/name_card.dart';
import '../ai_client.dart' show aiMessage;
import '../ai_keys.dart';
import '../ai_router.dart';
import 'chapter_notes.dart' show jsonObjectIn;
import 'graph3d_view.dart';
import 'ledger.dart';
import 'whos_who_screen.dart' show KindDot, kindColour, kindLabel;

// Off the UI thread's isolate, each from a function of its own with plain
// values (a closure made in the State's methods would carry the State).
Future<GraphView> _drawn(
        String path, int? at, int? here, int? focus, int depth, Set<String> kinds, int most, double aspect) =>
    Isolate.run(() => graphAndLayout(path,
        at: at,
        here: here,
        focus: focus,
        depth: depth,
        kinds: kinds.isEmpty ? null : kinds,
        most: most,
        aspect: aspect));
Future<Map<int, ({double x, double y, double z})>> _ballOff(GraphData g) => Isolate.run(() => layoutGraph3d(g));
Future<Map<int, String>> _briefsOff(String path, Map<int, List<int>> members) =>
    Isolate.run(() => groupBriefs(path, members));
Future<Map<String, String>> _namesOff(String path, List<String> keys) => Isolate.run(() => groupNames(path, keys));
Future<void> _keepNamesOff(String path, Map<String, String> names) => Isolate.run(() => keepGroupNames(path, names));
Future<int?> _mainOff(String path, int? at) => Isolate.run(() => mainOf(path, at: at));
Future<NodeDetail?> _detailOff(String path, int id, int at) => Isolate.run(() => nodeDetail(path, id, at));
Future<({List<String> relations, List<({int ch, String what})> events})> _linksOff(String path, int a, int b, int at) =>
    Isolate.run(() => linksBetween(path, a, b, at));
Future<List<LedgerEntry>> _findOff(String path, int? at, String q) => Isolate.run(() => ledger(path, at: at, query: q));

/// A link's colour, by what it is.
Color linkColour(LinkKind k) => switch (k) {
      LinkKind.bond => const Color(0xFF5DBB7A),
      LinkKind.conflict => const Color(0xFFE0574F),
      LinkKind.family => const Color(0xFF5B9BE6),
      LinkKind.belongs => const Color(0xFFB08BE8),
      LinkKind.other => const Color(0xFFC9B48A),
      LinkKind.shared => const Color(0xFF8C8C96),
    };

String linkLabel(LinkKind k) => switch (k) {
      LinkKind.bond => 'Allies, friends',
      LinkKind.conflict => 'Enemies, rivals',
      LinkKind.family => 'Family',
      LinkKind.belongs => 'Belongs to',
      LinkKind.other => 'Other',
      LinkKind.shared => 'Shared events',
    };

/// How far out from the person in the middle the web goes; or the whole
/// web as a map of its groups.
enum GraphDepth { one, two, all, map }

/// Which names the graph shows: the important ones, all that fit, or only
/// those picked and their links.
enum GraphNames { key, all, none }

/// The steps of the "how many" slider.
const graphSteps = [10, 20, 30, 40, 60, 80, 120, 160, 240, 320, 480, 640, 1000, 1500, 2000, 3000, 5000];

/// How far the view is zoomed: its scale along x. (The views made here
/// scale z as well, as InteractiveViewer's own do: one left at 1 read to it
/// as no zoom at all below 1, so a drag hit a wall at the edge and a pinch
/// out ran away.)
double viewScale(Matrix4 m) => math.sqrt(m.entry(0, 0) * m.entry(0, 0) + m.entry(1, 0) * m.entry(1, 0));

/// A group of the whole web, as drawn on the Story map: its middle, how far
/// it reaches, its members, and its best-known member.
typedef GraphGroup = ({int id, Offset centre, double reach, List<int> members, int top});

/// The groups among the nodes shown at [chapter], three or more each.
List<GraphGroup> graphGroups(GraphData data, Map<int, ({double x, double y})> at, Map<int, int> cluster, int chapter) {
  final by = <int, List<GraphNode>>{};
  for (final n in data.nodes) {
    final c = cluster[n.id];
    if (c == null || (n.firstCh ?? 0) > chapter || at[n.id] == null) continue;
    (by[c] ??= []).add(n);
  }
  final groups = <GraphGroup>[];
  for (final MapEntry(key: id, value: members) in by.entries) {
    if (members.length < 3) continue;
    final pts = [for (final n in members) Offset(at[n.id]!.x, at[n.id]!.y)];
    final centre = pts.reduce((a, b) => a + b) / pts.length.toDouble();
    final ds = [for (final p in pts) (p - centre).distance]..sort();
    final reach = ds[(ds.length * 0.8).floor().clamp(0, ds.length - 1)] + 40;
    members.sort((a, b) => b.weight.compareTo(a.weight));
    groups.add((id: id, centre: centre, reach: reach, members: [for (final n in members) n.id], top: members.first.id));
  }
  return groups;
}

/// The shortest chain of links from [a] to [b] at [chapter], or null.
List<int>? graphPath(GraphData data, int a, int b, int chapter) {
  final next = <int, List<int>>{};
  for (final e in data.edges) {
    if (!e.at(chapter)) continue;
    (next[e.a] ??= []).add(e.b);
    (next[e.b] ??= []).add(e.a);
  }
  final from = <int, int>{a: a};
  final queue = [a];
  for (var i = 0; i < queue.length; i++) {
    final v = queue[i];
    if (v == b) break;
    for (final w in next[v] ?? const <int>[]) {
      if (from.containsKey(w)) continue;
      from[w] = v;
      queue.add(w);
    }
  }
  if (!from.containsKey(b)) return null;
  final path = [b];
  while (path.last != a) {
    path.add(from[path.last]!);
  }
  return path.reversed.toList();
}

/// The memory graph, built on what the apps that do this well do: a local
/// graph round one person with a depth, as Obsidian's; focus and search, as
/// Kumu's; a web that grows chapter by chapter, nodes sized by how often
/// they appear and groups gathered together, as the reading companions'
/// maps (NovelForge, StoryCodex). It opens round the main character, not the
/// whole tangle; links are coloured by what they are, groups wear a halo
/// round their members; the timeline shows the web as it stood at any
/// chapter, its nodes staying where they are, and plays it growing; a tap
/// opens a person (their neighbours lit, the rest dimmed), two show what
/// links them.
class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen(
      {super.key,
      required this.bookTitle,
      required this.memoryPath,
      this.line,
      this.here,
      this.onAsk,
      this.focus,
      this.nameGroups = false});

  final String bookTitle;
  final String memoryPath;

  /// Who it opens round, picked (a card's "See their links"); null: the
  /// whole web, round the main character.
  final int? focus;

  /// The spoiler line (null: the guard is off).
  final int? line;

  /// The chapter the reader is at: what matters "now" is near it.
  final int? here;

  /// Asks the book's Talk about something (null: not offered).
  final Future<void> Function(String question)? onAsk;

  /// Whether the Story map's groups may be named by the AI (not with the
  /// spoiler guard on, nor for a book kept from the AI).
  final bool nameGroups;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> with TickerProviderStateMixin {
  /// The view gliding to where it is going (a pick, a group, a zoom).
  late final AnimationController _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 380))
    ..addListener(() {
      final t = _glideTween;
      if (t != null) _view.value = t.evaluate(CurvedAnimation(parent: _glide, curve: Curves.easeOutCubic));
    });
  Matrix4Tween? _glideTween;
  Size _box = Size.zero;
  Offset _doubleAt = Offset.zero;

  void _glideTo(Matrix4 to) {
    if (MediaQuery.of(context).disableAnimations) {
      _view.value = to;
      return;
    }
    _glideTween = Matrix4Tween(begin: _view.value.clone(), end: to);
    unawaited(_glide.forward(from: 0));
  }

  /// The view with [p] (in the graph's own units) at [where] on the screen,
  /// at [scale].
  Matrix4 _viewAt(Offset p, double scale, Offset where) => Matrix4.identity()
    ..translateByDouble(where.dx - p.dx * scale, where.dy - p.dy * scale, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);

  /// Dragged right off the screen: back to where all of it shows.
  void _keepInSight() {
    if (_box.isEmpty) return;
    final seen = MatrixUtils.inverseTransformRect(_view.value, Offset.zero & _box);
    final web = Rect.fromLTWH(0, 0, _size, _height).deflate(math.min(_size, _height) * 0.08);
    if (!seen.overlaps(web)) _glideTo(_fitView(_box));
  }

  /// The view it starts with: all of it, unless that would crowd the nodes
  /// onto each other (then as near as the spacing allows, a little closer
  /// than the layout's own, which still keeps them apart), the person in
  /// the middle, or the middle of it, in view.
  Matrix4 _fitView(Size whole) {
    // The part of the area not under the controls.
    final box = Size(whole.width, math.max(120.0, whole.height - _controlsRoom));
    final all = math.min(box.width / _size, box.height / _height);
    // The whole web and the map: truly all of it (most nodes are fine
    // points now, so they no longer crowd when it is seen whole).
    final s = _depth == GraphDepth.map || _depth == GraphDepth.all ? all : math.max(all, 0.7 / canvasPerDp);
    return _viewAt(_middle(), s, box.center(Offset.zero));
  }

  /// The side of the square the web is laid out in.
  double _size = 1000, _height = 1000;

  /// The graph area's height over its width, for the layout's shape.
  double _aspect = 1.6;
  bool _legend = false;

  /// Whether the toolbar offers the ball (3D) view. Hidden for now at the
  /// owner's ask; the view and its layout stay, so turning this on brings it back.
  static bool get _offerBall => false;

  /// Seen as a ball to turn, and where each node sits in it.
  bool _ball = false;
  Map<int, ({double x, double y, double z})>? _at3;

  GraphData? _data;
  Map<int, ({double x, double y})> _at = const {};
  Map<int, ({double x, double y})> _from = const {};
  late final AnimationController _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 450))
    ..addListener(_moved);

  int? _focus;
  GraphDepth _depth = GraphDepth.all;
  final Set<String> _kinds = {};
  final Set<LinkKind> _hiddenLinks = {};

  /// Those carried over from an earlier book of the series, hidden.
  bool _hideEarlier = false;
  GraphNames _names = GraphNames.key;

  /// Nodes coloured by their group; off: by their kind (a switch in the key).
  bool _byGroup = true;

  /// How many are shown (null: a fit for the book), and of how many.
  int? _most;
  int _choices = 0;
  List<GraphSector> _sectors = const [];
  Map<int, int> _cluster = const {};

  /// The Story map's groups' names, by group, kept or asked of the AI.
  Map<int, String> _groupNames = const {};
  bool _naming = false;

  /// The chapter the timeline was at before its last move: what is new, or
  /// ended, since then is marked.
  int? _since;

  /// The chain of links between the two picked.
  List<int>? _path;
  int? _picked;
  int? _second;
  bool _linking = false;
  NodeDetail? _detail;
  ({List<String> relations, List<({int ch, String what})> events})? _links;

  /// The chapter the web is shown at (the timeline; null: the end).
  int? _chapter;
  Timer? _playing;
  bool _loading = true;
  int _asked = 0;
  bool _fitted = false;
  final _view = TransformationController();

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _playing?.cancel();
    _glide.dispose();
    _move.dispose();
    _view.dispose();
    super.dispose();
  }

  void _moved() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final asked = widget.focus;
    if (asked != null) {
      // Opened for one person: round them, their links lit.
      _focus = asked;
      _depth = GraphDepth.one;
      await _load();
      if (mounted && _at.containsKey(asked)) await _pick(asked);
      return;
    }
    _focus = await _mainOff(widget.memoryPath, widget.line);
    if (_focus == null) _depth = GraphDepth.all;
    await _load();
  }

  Future<void> _load() async {
    final n = ++_asked;
    setState(() => _loading = true);
    final GraphView r;
    try {
      r = await _drawn(
      widget.memoryPath,
      widget.line,
      widget.here,
      _depth == GraphDepth.all || _depth == GraphDepth.map ? null : _focus,
      _depth == GraphDepth.two ? 2 : 1,
      {..._kinds},
      _shownMost,
      _aspect,
    );
    } on Object {
      // Not to be drawn now: said, not left loading for ever.
      if (mounted && n == _asked) {
        setState(() => _loading = false);
        showSnack(context, 'The graph could not be drawn. Try again in a moment.');
      }
      return;
    }
    if (!mounted || n != _asked) return;
    final was = _shown;
    setState(() {
      // From where each node was to where it is now (new ones from the
      // middle), so a change of focus moves the web rather than cuts it.
      _from = {
        for (final id in r.at.keys) id: was[id] ?? (x: _size / 2, y: _height / 2),
      };
      _data = r.data;
      _at = r.at;
      _sectors = r.sectors;
      _cluster = r.cluster;
      _choices = r.data.choices;
      if (r.size != _size || r.height != _height) {
        _size = r.size;
        _height = r.height;
        _fitted = false;
      }
      _loading = false;
      _at3 = null;
      if (_picked != null && !_at.containsKey(_picked)) _clearPick();
    });
    unawaited(_move.forward(from: 0));
    if (_depth == GraphDepth.map) unawaited(_nameGroups());
    if (_ball) await _laidAsBall();
  }

  /// The Story map's groups named: those named before, from the memory;
  /// the rest asked of the AI in one call, each from its best-known members,
  /// and kept.
  Future<void> _nameGroups() async {
    final data = _data;
    if (data == null || _naming) return;
    final groups = graphGroups(data, _at, _cluster, _end);
    String keyOf(GraphGroup g) => (g.members.take(3).toList()..sort()).join(',');
    final keys = {for (final g in groups) g.id: keyOf(g)};
    final kept = await _namesOff(widget.memoryPath, keys.values.toList());
    if (!mounted) return;
    setState(() => _groupNames = {
          for (final g in groups)
            if (kept[keys[g.id]] != null) g.id: kept[keys[g.id]]!,
        });
    final unnamed = [
      for (final g in groups)
        if (kept[keys[g.id]] == null && g.members.length >= 5) g
    ];
    if (unnamed.isEmpty || !widget.nameGroups || !AiRing.instance.hasKeys) return;
    _naming = true;
    try {
      final briefs = await _briefsOff(widget.memoryPath, {for (final g in unnamed) g.id: g.members});
      final reply = await AiRouter(about: widget.bookTitle).chat(
          AiJob.talker,
          [
            aiMessage(
              'system',
              'You name groups of characters, places and things from a novel, found by how they are linked in the '
                  'story. Name each group in 2 to 5 words, as a reader of the book would know it: who or what holds it '
                  'together (a band, a family, a place, a war, a quest). Use only what is given. Reply with JSON '
                  'only: {"groups": [{"id": <number>, "name": "<name>"}]}',
            ),
            aiMessage('user', [for (final e in briefs.entries) 'Group ${e.key}: ${e.value}'].join('\n')),
          ],
          json: true,
          temperature: 0.3);
      final got = <String, String>{}, shown = <int, String>{};
      final list = jsonObjectIn(reply.text)['groups'];
      if (list is List) {
        for (final item in list.whereType<Map>()) {
          final id = (item['id'] as num?)?.toInt();
          final name = (item['name'] as String?)?.trim();
          if (id == null || name == null || name.isEmpty || !keys.containsKey(id)) continue;
          got[keys[id]!] = name;
          shown[id] = name;
        }
      }
      if (got.isEmpty) return;
      await _keepNamesOff(widget.memoryPath, got);
      if (mounted) setState(() => _groupNames = {..._groupNames, ...shown});
    } on Object {
      // No key able, or a reply not understood: the groups keep the name
      // of their best-known member.
    } finally {
      _naming = false;
    }
  }

  /// How many to show: the reader's choice, or a fit (forty; the Story
  /// map, everyone).
  int get _shownMost => _most ?? (_depth == GraphDepth.map ? graphSteps.last : 40);

  Future<void> _laidAsBall() async {
    final data = _data;
    if (data == null || _at3 != null) return;
    final n = _asked;
    final at = await _ballOff(data);
    if (mounted && n == _asked && _data == data) setState(() => _at3 = at);
  }

  /// Where the nodes are drawn now: on their way, while the web moves.
  Map<int, ({double x, double y})> get _shown {
    final t = Curves.easeOutCubic.transform(_move.value);
    if (t >= 1 || _from.isEmpty) return _at;
    return {
      for (final e in _at.entries)
        e.key: (
          x: (_from[e.key]?.x ?? e.value.x) + (e.value.x - (_from[e.key]?.x ?? e.value.x)) * t,
          y: (_from[e.key]?.y ?? e.value.y) + (e.value.y - (_from[e.key]?.y ?? e.value.y)) * t,
        ),
    };
  }

  /// The furthest chapter shown: the line, or all the memory has.
  int get _end {
    final last = _data?.lastCh ?? 0;
    final line = widget.line;
    return line == null ? last : math.min(line, last);
  }

  int get _shownCh => math.min(_chapter ?? _end, _end);

  /// Closer ([by] over 1) or further, round the middle of the screen: for a
  /// thumb, without pinching.
  void _zoom(double by) {
    if (_box == Size.zero) return;
    final middle = _box.center(Offset.zero);
    final at = MatrixUtils.transformPoint(Matrix4.inverted(_view.value), middle);
    _glideTo(_viewAt(at, (viewScale(_view.value) * by).clamp(0.04, 6.0), middle));
  }

  void _clearPick() {
    _picked = null;
    _second = null;
    _path = null;
    _detail = null;
    _links = null;
    _linking = false;
  }

  Future<void> _pick(int? id) async {
    if (id == null) {
      setState(_clearPick);
      return;
    }
    // Picking the second of two: what links them.
    if (_linking && _picked != null && id != _picked) {
      final a = _picked!;
      setState(() {
        _second = id;
        _linking = false;
      });
      final links = await _linksOff(widget.memoryPath, a, id, _shownCh);
      final data = _data;
      if (mounted && _second == id) {
        setState(() {
          _links = links;
          _path = data == null ? null : graphPath(data, a, id, _shownCh);
        });
      }
      return;
    }
    // The view glides so the one picked is in view, above where its panel
    // opens.
    final at = _shown[id];
    if (at != null && _box != Size.zero) {
      final scale = math.max(viewScale(_view.value), 0.9 / canvasPerDp);
      _glideTo(_viewAt(Offset(at.x, at.y), scale, Offset(_box.width / 2, _box.height * 0.32)));
    }
    setState(() {
      _picked = id;
      _second = null;
      _links = null;
      _detail = null;
    });
    final d = await _detailOff(widget.memoryPath, id, _shownCh);
    if (mounted && _picked == id) setState(() => _detail = d);
  }

  void _centre(int id) {
    setState(() {
      _focus = id;
      _fitted = false;
      if (_depth == GraphDepth.all) _depth = GraphDepth.one;
    });
    unawaited(_load());
    unawaited(_pick(id));
  }

  int? _hit(Offset p) {
    final data = _data;
    if (data == null) return null;
    final shown = _shown;
    // Nodes are drawn the same size on the screen whatever the zoom.
    final dp = 1 / viewScale(_view.value);
    int? best;
    var bestD = double.infinity;
    for (final n in data.nodes) {
      if ((n.firstCh ?? 0) > _shownCh) continue;
      final at = shown[n.id];
      if (at == null) continue;
      final d = (Offset(at.x, at.y) - p).distance;
      if (d <= (nodeDp(n.weight) + 12) * dp && d < bestD) {
        best = n.id;
        bestD = d;
      }
    }
    return best;
  }

  /// On the Story map, a tap on a group drawn shut opens it: the view goes
  /// to it.
  bool _openGroup(Offset p, Size box) {
    final data = _data;
    if (data == null || _depth != GraphDepth.map) return false;
    final scale = viewScale(_view.value);
    for (final g in graphGroups(data, _shown, _cluster, _shownCh)) {
      if (g.reach * scale >= GraphPainter.openAt) continue;
      if ((g.centre - p).distance > g.reach) continue;
      final s = math.min(6.0, math.min(box.width, box.height) / (g.reach * 2.3));
      _glideTo(_viewAt(g.centre, s, box.center(Offset.zero)));
      return true;
    }
    return false;
  }

  /// Where the view starts: the person in the middle, or the middle of
  /// those shown.
  Offset _middle() {
    final at = _at;
    final f = _focus != null && _depth != GraphDepth.all && _depth != GraphDepth.map ? at[_focus] : null;
    if (f != null) return Offset(f.x, f.y);
    if (at.isEmpty || _depth == GraphDepth.map) return Offset(_size / 2, _height / 2);
    final xs = at.values.map((p) => p.x), ys = at.values.map((p) => p.y);
    return Offset((xs.reduce(math.min) + xs.reduce(math.max)) / 2, (ys.reduce(math.min) + ys.reduce(math.max)) / 2);
  }

  /// The timeline moved to [ch] (null: the end): what came or went since
  /// where it was is marked.
  void _toChapter(int? ch) {
    _since = _shownCh;
    _chapter = ch;
    if (_chapter == null) _since = null;
  }

  /// For one the reader may have forgotten: when they were last seen.
  String? _lastSeenNote(int id) {
    final n = _data?.nodes.where((n) => n.id == id).firstOrNull;
    if (n == null || !n.forgotten || n.lastSeen == null) return null;
    return 'You may have forgotten them: last seen in chapter ${n.lastSeen! + 1}.';
  }

  /// The "how many" slider: from the few that matter most now to everyone.
  Widget _howMany(BuildContext context, GraphData? data, Color ground) {
    final steps = [
      for (final s in graphSteps)
        if (s < _choices) s,
      _choices
    ];
    final shown = math.min(_shownMost, _choices);
    var at = steps.indexWhere((s) => s >= shown);
    if (at < 0) at = steps.length - 1;
    final forgotten = data?.forgotten ?? 0;
    final all = steps[at] >= _choices;
    return _ControlRow(
      title: 'How many',
      ground: ground,
      value: [
        all ? 'Everyone ($_choices)' : 'The ${steps[at]} who matter most, of $_choices',
        if (forgotten > 0) '$forgotten forgotten',
      ].join(' · '),
      slider: Slider(
        value: at.toDouble(),
        max: (steps.length - 1).toDouble(),
        divisions: steps.length - 1,
        label: all ? 'Everyone' : 'The ${steps[at]} that matter most',
        onChanged: (v) {
          final next = steps[v.round()];
          if (next == _shownMost) return;
          setState(() => _most = next);
        },
        onChangeEnd: (_) => unawaited(_load()),
      ),
    );
  }

  /// How much of the graph's foot the controls cover.
  double get _controlsRoom {
    if (_ball) return 0;
    final rows = (_end > 0 ? 1 : 0) + (_choices > graphSteps.first ? 1 : 0);
    if (rows == 0) return 0;
    final inset = _picked == null ? MediaQuery.viewPaddingOf(context).bottom : 0.0;
    return rows * 76.0 + Gap.s + inset;
  }

  /// The timeline and how many are shown, together at the graph's foot,
  /// over it, with no ground of their own (the web shows through); what
  /// each does named above its track, the tracks lined up, the words kept
  /// legible over the links by a halo of the page's [ground].
  Widget _controls(BuildContext context, GraphData? data, Color ground) {
    final timeline = _end > 0;
    final howMany = _choices > graphSteps.first;
    if (!timeline && !howMany) return const SizedBox.shrink();
    final panel = Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.s, Gap.s),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(padding: const EdgeInsets.fromLTRB(4, 2, 20, 8)),
        child: DefaultTextStyle.merge(
          style: TextStyle(shadows: [
            for (final o in const [Offset(0, 0), Offset(1, 1), Offset(-1, -1)])
              Shadow(color: ground, blurRadius: 6, offset: o),
          ]),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (timeline)
                _ControlRow(
                  title: 'Timeline',
                  ground: ground,
                  value: _shownCh >= _end ? 'Up to chapter ${_end + 1}, all of it' : 'As of chapter ${_shownCh + 1} of ${_end + 1}',
                  action: IconButton(
                    tooltip: _playing == null ? 'Play the web growing' : 'Stop',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(_playing == null ? Icons.play_arrow_rounded : Icons.pause_rounded),
                    onPressed: _play,
                  ),
                  slider: Slider(
                    value: _shownCh.toDouble().clamp(0, _end.toDouble()),
                    max: _end.toDouble(),
                    label: 'As of chapter ${_shownCh + 1}',
                    onChanged: (v) {
                      _playing?.cancel();
                      setState(() {
                        _playing = null;
                        _toChapter(v.round() >= _end ? null : v.round());
                      });
                    },
                  ),
                ),
              if (howMany) _howMany(context, data, ground),
            ],
          ),
        ),
      ),
    );
    return _picked == null ? SafeArea(top: false, child: panel) : panel;
  }



  /// The web played growing, from the first chapter to the line, in about
  /// eight seconds whatever the book's length.
  void _play() {
    if (_playing != null) {
      _playing!.cancel();
      setState(() => _playing = null);
      return;
    }
    final end = _end;
    if (end <= 0) return;
    final step = math.max(1, (end / 64).ceil());
    setState(() => _chapter = 0);
    _playing = Timer.periodic(const Duration(milliseconds: 125), (t) {
      if (!mounted) return t.cancel();
      final next = (_chapter ?? 0) + step;
      setState(() {
        if (next >= end) {
          _toChapter(null);
          _playing = null;
          t.cancel();
        } else {
          _toChapter(next);
        }
      });
    });
  }

  Future<void> _search() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FindSheet(path: widget.memoryPath, line: widget.line),
    );
    if (picked != null && mounted) _centre(picked);
  }

  Future<void> _openCard(int id) async {
    final card = await cardOff(widget.memoryPath, id, _shownCh);
    if (card == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NameCardSheet(card: card, line: _shownCh),
    );
  }

  String? _nameOf(int? id) => _data?.nodes.where((n) => n.id == id).firstOrNull?.name;

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The middle of the screen's own ground, for the names' halos and the
    // nodes' rings: they blend into it in every colour theme, day or night.
    final pal = Skin.paletteOf(context);
    final ground = dark ? Color.lerp(pal.night[1], pal.night[2], 0.5)! : Color.lerp(pal.day[1], pal.day[2], 0.5)!;
    final kinds = {for (final n in data?.nodes ?? const <GraphNode>[]) n.kind}.toList()..sort();
    final used = {
      for (final e in data?.edges ?? const <GraphEdge>[])
        if (e.at(_shownCh)) e.kind
    }.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final focusName = _nameOf(_focus);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ScreenTopBar(title: 'Memory graph', onBack: () => Navigator.of(context).maybePop())),
                  IconButton(
                    tooltip: 'Find someone',
                    icon: const Icon(Icons.search_rounded),
                    onPressed: () => unawaited(_search()),
                  ),
                  if (_offerBall)
                    IconButton(
                      tooltip: _ball ? 'See it flat' : 'See it as a ball to turn (3D)',
                      isSelected: _ball,
                      icon: const Icon(Icons.threed_rotation_rounded),
                      onPressed: () {
                        setState(() => _ball = !_ball);
                        if (_ball) unawaited(_laidAsBall());
                      },
                    ),
                  PopupMenuButton<Object>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) => setState(() {
                      if (v is GraphNames) _names = v;
                      if (v == #key) _legend = !_legend;
                      if (v == #fit) _fitted = false;
                    }),
                    itemBuilder: (_) => [
                      for (final (v, label) in const [
                        (GraphNames.key, 'The important names'),
                        (GraphNames.all, 'All the names that fit'),
                        (GraphNames.none, 'Only the names of those picked'),
                      ])
                        CheckedPopupMenuItem(value: v, checked: _names == v, child: Text(label)),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(value: #key, checked: _legend, child: const Text('What the colours mean')),
                      if (!_ball) const PopupMenuItem(value: #fit, child: Text('Fit to the screen')),
                    ],
                  ),
                  const SizedBox(width: Gap.s),
                ],
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  children: [
                    for (final d in GraphDepth.values)
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.s),
                        child: ChoiceChip(
                          label: Text(switch (d) {
                            GraphDepth.one => focusName == null ? 'Close links' : 'Round $focusName',
                            GraphDepth.two => 'Two links out',
                            GraphDepth.all => 'The whole web',
                            GraphDepth.map => 'Story map',
                          }),
                          selected: _depth == d,
                          onSelected: (_) {
                            setState(() {
                              _depth = d;
                              _fitted = false;
                            });
                            unawaited(_load());
                          },
                        ),
                      ),
                    // The kinds, on the same line: a tap shows only those.
                    if (kinds.length > 1 || _kinds.isNotEmpty)
                      for (final k in {...kinds, ..._kinds})
                        Padding(
                          padding: const EdgeInsets.only(right: Gap.s),
                          child: FilterChip(
                            avatar: KindDot(k, size: 10),
                            showCheckmark: false,
                            label: Text(kindLabel(k)),
                            selected: _kinds.contains(k),
                            onSelected: (on) {
                              setState(() => on ? _kinds.add(k) : _kinds.remove(k));
                              unawaited(_load());
                            },
                          ),
                        ),
                  ],
                ),
              ),
              Expanded(
                child: data == null
                    ? const Center(child: CircularProgressIndicator())
                    : data.nodes.isEmpty
                        ? const EmptyState(
                            icon: Icons.hub_outlined,
                            title: 'Nothing to draw yet',
                            body: "Build the memory from the book's page, and its web grows here, chapter by chapter.",
                          )
                        : Stack(
                            children: [
                              if (_ball)
                                Positioned.fill(
                                  child: _at3 == null
                                      ? const Center(child: CircularProgressIndicator())
                                      : Graph3dView(
                                          data: data,
                                          at: _at3!,
                                          chapter: _shownCh,
                                          picked: _picked,
                                          second: _second,
                                          onPick: (id) => unawaited(_pick(id)),
                                          ink: Skin.inkOn(context),
                                          dark: dark,
                                          linkColour: linkColour,
                                        ),
                                )
                              else
                                Positioned.fill(
                                  child: LayoutBuilder(builder: (context, box) {
                                    if (box.maxWidth > 0) _aspect = (box.maxHeight / box.maxWidth).clamp(1.0, 2.2);
                                    _box = Size(box.maxWidth, box.maxHeight);
                                    if (!_fitted) {
                                      _fitted = true;
                                      _view.value = _fitView(_box);
                                    }
                                    return ClipRect(
                                      child: InteractiveViewer(
                                        transformationController: _view,
                                        constrained: false,
                                        // No wall: the web can be dragged as
                                        // far as wanted, and glides back if
                                        // it is dragged right off the screen.
                                        boundaryMargin: const EdgeInsets.all(double.infinity),
                                        minScale: 0.04,
                                        maxScale: 6,
                                        onInteractionEnd: (_) => _keepInSight(),
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // Twice: closer, round where it was
                                          // tapped; twice again, all of it.
                                          onDoubleTapDown: (d) => _doubleAt = d.localPosition,
                                          onDoubleTap: () {
                                            final scale = viewScale(_view.value);
                                            final fit = viewScale(_fitView(_box));
                                            final on = MatrixUtils.transformPoint(_view.value, _doubleAt);
                                            _glideTo(scale > fit * 1.6
                                                ? _fitView(_box)
                                                : _viewAt(_doubleAt, math.min(6.0, scale * 2.4), on));
                                          },
                                          onTapUp: (d) {
                                            final hit = _hit(d.localPosition);
                                            if (hit == null &&
                                                _openGroup(d.localPosition, Size(box.maxWidth, box.maxHeight))) {
                                              return;
                                            }
                                            unawaited(_pick(hit));
                                          },
                                          child: SizedBox(
                                            width: _size,
                                            height: _height,
                                            child: CustomPaint(
                                              painter: GraphPainter(
                                                data: data,
                                                at: _shown,
                                                chapter: _shownCh,
                                                picked: _picked,
                                                second: _second,
                                                view: _view,
                                                dark: dark,
                                                ink: Skin.inkOn(context),
                                                ground: ground,
                                                names: _names,
                                                sectors: _picked == null ? _sectors : const [],
                                                groups: _depth == GraphDepth.map
                                                    ? graphGroups(data, _shown, _cluster, _shownCh)
                                                    : const [],
                                                hiddenLinks: {..._hiddenLinks},
                                                hideEarlier: _hideEarlier,
                                                groupNames: _groupNames,
                                                since: _since,
                                                path: _path,
                                                viewport: _box,
                                                cluster: _cluster,
                                                byGroup: _byGroup,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              if (_loading)
                                const Positioned(
                                  top: 8,
                                  right: 16,
                                  child:
                                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                ),
                              // The timeline and how many, over the graph's foot
                              // with no ground of their own: the web shows
                              // through, and runs on under them.
                              if (!_ball)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: _controls(context, data, ground),
                                ),
                              if (!_ball)
                                Positioned(
                                  right: Gap.s,
                                  top: 0,
                                  bottom: _controlsRoom,
                                  child: Center(
                                    child: _ZoomButtons(
                                    onCloser: () => _zoom(1.6),
                                    onFurther: () => _zoom(1 / 1.6),
                                    onAll: () => _glideTo(_fitView(_box)),
                                  ),
                                  ),
                                ),
                              // The key, a tap away on the graph itself.
                              if (!_legend)
                                Positioned(
                                  left: Gap.page,
                                  top: Gap.s,
                                  child: _KeyButton(
                                    kinds: kinds.take(3).toList(),
                                    onTap: () => setState(() => _legend = true),
                                  ),
                                ),
                              // Kept within the graph's area, scrolling when a
                              // book has many kinds.
                              if (_legend)
                                Positioned(
                                  left: Gap.page,
                                  top: Gap.s,
                                  bottom: Gap.s,
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: SingleChildScrollView(
                                      child: _Legend(
                                    onClose: () => setState(() => _legend = false),
                                    kinds: used,
                                    nodes: kinds,
                                    shownKinds: _kinds,
                                    hiddenLinks: _hiddenLinks,
                                    forgotten: data.forgotten > 0,
                                    earlier: data.nodes.any((n) => (n.firstCh ?? 0) < 0),
                                    hideEarlier: _hideEarlier,
                                    onEarlier: () => setState(() => _hideEarlier = !_hideEarlier),
                                    byGroup: _byGroup,
                                    onByGroup: (v) => setState(() => _byGroup = v),
                                    onKind: (k) {
                                      setState(() => _kinds.contains(k) ? _kinds.remove(k) : _kinds.add(k));
                                      unawaited(_load());
                                    },
                                    onLink: (k) => setState(
                                        () => _hiddenLinks.contains(k) ? _hiddenLinks.remove(k) : _hiddenLinks.add(k)),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_linking)
                                Positioned(
                                  left: 56,
                                  right: 56,
                                  bottom: _controlsRoom + Gap.s,
                                  child: Center(
                                    child: Chip(label: Text('Now tap who to link ${_nameOf(_picked) ?? ''} with')),
                                  ),
                                ),
                            ],
                          ),
              ),
              if (_picked != null) _panel(context),
            ],
          ),
        ),
      ),
    );
  }

  /// The picked person (or two): what they are, the chapters they are in,
  /// their relations as chips to go to, Card, Centre here and Linked with…;
  /// for two, what links them.
  Widget _panel(BuildContext context) {
    final d = _detail;
    final links = _links;
    final second = _second;
    Widget close() => IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => setState(_clearPick),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.s),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.s),
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.34),
      decoration: BoxDecoration(
        color: Skin.capsuleOn(context),
        borderRadius: BorderRadius.circular(Radii.row + 6),
        border: Border.all(color: Skin.outlineOn(context)),
      ),
      child: second != null
          ? SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${_nameOf(_picked)} & ${_nameOf(second)}',
                            style: Skin.ui(size: 16, weight: FontWeight.w700, color: Skin.inkOn(context))),
                      ),
                      close(),
                    ],
                  ),
                  if (_path != null && _path!.length > 2)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.xs),
                      child: Text('Linked through: ${_path!.map(_nameOf).join(' → ')}',
                          style: Skin.ui(size: 14, weight: FontWeight.w600, color: const Color(0xFFE07A3A))),
                    ),
                  if (links == null)
                    const Padding(padding: EdgeInsets.all(Gap.s), child: LinearProgressIndicator())
                  else if (links.relations.isEmpty && links.events.isEmpty)
                    Text('Nothing links them yet, as far as the memory knows.', style: Skin.meta(context))
                  else ...[
                    for (final r in links.relations)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(r, style: Skin.ui(size: 14, weight: FontWeight.w600, color: Skin.inkOn(context))),
                      ),
                    for (final e in links.events)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('Chapter ${e.ch + 1}: ${e.what}',
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkSoftOn(context))),
                      ),
                  ],
                ],
              ),
            )
          : d == null
              ? const Padding(padding: EdgeInsets.all(Gap.m), child: LinearProgressIndicator())
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          KindDot(d.kind, size: 14),
                          const SizedBox(width: Gap.s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.name,
                                    style: Skin.ui(size: 16, weight: FontWeight.w700, color: Skin.inkOn(context))),
                                Text(
                                  '${kindLabel(d.kind)} · in ${d.chapters.length} '
                                  '${d.chapters.length == 1 ? 'chapter' : 'chapters'}'
                                  '${d.firstCh == null || d.firstCh! < 0 ? '' : ' · first in ${d.firstCh! + 1}'}',
                                  style: Skin.meta(context),
                                ),
                              ],
                            ),
                          ),
                          close(),
                        ],
                      ),
                      if (_lastSeenNote(d.id) case final note?)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.xs),
                          child: Text(note,
                              style: Skin.ui(size: 13.5, weight: FontWeight.w600, color: const Color(0xFFE07A3A))),
                        ),
                      if (d.chapters.isNotEmpty && _end > 0) ...[
                        const SizedBox(height: Gap.xs),
                        _Presence(chapters: d.chapters, end: _shownCh, colour: kindColour(d.kind)),
                      ],
                      if ((d.about ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.s),
                          child: Text(
                            d.about!,
                            style: Skin.ui(size: 14, weight: FontWeight.w400, color: Skin.inkOn(context))
                                .copyWith(height: 1.35),
                          ),
                        ),
                      if (d.relations.isNotEmpty) ...[
                        const SizedBox(height: Gap.s),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final r in d.relations)
                              ActionChip(
                                visualDensity: VisualDensity.compact,
                                avatar: CircleAvatar(backgroundColor: linkColour(r.kind), radius: 5),
                                label: Text(r.rel),
                                onPressed: () => _centre(r.other),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: Gap.xs),
                      Wrap(
                        children: [
                          TextButton(onPressed: () => unawaited(_openCard(d.id)), child: const Text('Card')),
                          TextButton(onPressed: () => _centre(d.id), child: const Text('Centre here')),
                          TextButton(
                            onPressed: () => setState(() => _linking = true),
                            child: const Text('Linked with…'),
                          ),
                          if (widget.onAsk != null)
                            TextButton(
                              onPressed: () => unawaited(widget.onAsk!(
                                  'Tell me about ${d.name}: who or what they are, what they have done so far, '
                                  'and why they matter.')),
                              child: const Text('Ask about this'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// The chapters someone is in, as a strip across the book so far.
class _Presence extends StatelessWidget {
  const _Presence({required this.chapters, required this.end, required this.colour});

  final List<int> chapters;
  final int end;
  final Color colour;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 10,
        width: double.infinity,
        child: CustomPaint(painter: _PresencePainter(chapters, end, colour, Skin.outlineOn(context))),
      );
}

class _PresencePainter extends CustomPainter {
  _PresencePainter(this.chapters, this.end, this.colour, this.track);

  final List<int> chapters;
  final int end;
  final Color colour;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)), Paint()..color = track);
    final span = math.max(1, end + 1);
    final w = math.max(2.0, size.width / span);
    final p = Paint()..color = colour;
    for (final ch in chapters) {
      if (ch < 0 || ch > end) continue;
      canvas.drawRect(Rect.fromLTWH(ch / span * size.width, 0, w, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_PresencePainter old) => old.chapters != chapters || old.end != end;
}

/// The key, shut: a few of the kinds' dots and "Key", a tap opening it.
class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.kinds, required this.onTap});

  final List<String> kinds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'What the colours mean',
        child: Material(
          color: Skin.capsuleOn(context).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(Radii.pill),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final k in kinds) ...[KindDot(k, size: 8), const SizedBox(width: 3)],
                    const SizedBox(width: 4),
                    Text('Key', style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.inkOn(context))),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// Closer, further, and all of it: zoom for a thumb, without pinching.
class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onCloser, required this.onFurther, required this.onAll});

  final VoidCallback onCloser;
  final VoidCallback onFurther;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tip, VoidCallback onTap) => IconButton(
          tooltip: tip,
          icon: Icon(icon, size: 20, color: Skin.inkOn(context)),
          onPressed: onTap,
        );
    return Material(
      color: Skin.capsuleOn(context).withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(Radii.pill),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(Icons.add_rounded, 'Closer', onCloser),
          button(Icons.remove_rounded, 'Further', onFurther),
          button(Icons.fit_screen_outlined, 'All of it', onAll),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.onClose,
    required this.kinds,
    required this.nodes,
    required this.shownKinds,
    required this.hiddenLinks,
    required this.forgotten,
    this.earlier = false,
    this.hideEarlier = false,
    this.onEarlier,
    required this.onKind,
    required this.onLink,
    this.byGroup = true,
    this.onByGroup,
  });

  /// Nodes coloured by group (else by kind), and the switch between.
  final bool byGroup;
  final ValueChanged<bool>? onByGroup;

  final List<LinkKind> kinds;
  final List<String> nodes;
  final Set<String> shownKinds;
  final Set<LinkKind> hiddenLinks;
  final bool forgotten;

  /// Whether some came from an earlier book of the series (a tap hides them).
  final bool earlier;
  final bool hideEarlier;
  final VoidCallback? onEarlier;
  final void Function(String kind) onKind;
  final void Function(LinkKind kind) onLink;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    Widget dot(double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Skin.inkSoftOn(context)),
        );
    Widget row(Widget mark, String label, {required bool on, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 16, child: Center(child: mark)),
                const SizedBox(width: 6),
                Text(label,
                    style: Skin.meta(context, size: 11.5).copyWith(decoration: on ? null : TextDecoration.lineThrough)),
              ],
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Skin.capsuleOn(context).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('KEY · TAP TO HIDE OR SHOW', style: Skin.meta(context, size: 10)),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Close the key',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: const Icon(Icons.close_rounded),
                onPressed: onClose,
              ),
            ],
          ),
          if (onByGroup != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Colour by', style: Skin.meta(context, size: 11.5)),
                  const SizedBox(width: 6),
                  for (final (v, label) in const [(true, 'Group'), (false, 'Kind')])
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: byGroup == v,
                        visualDensity: VisualDensity.compact,
                        labelStyle: Skin.meta(context, size: 11.5),
                        onSelected: (_) => onByGroup!(v),
                      ),
                    ),
                ],
              ),
            ),
          // A tap on a kind shows only it (and others tapped); on a link,
          // hides or shows those links.
          for (final k in {...nodes, ...shownKinds})
            row(KindDot(k, size: 9), kindLabel(k),
                on: shownKinds.isEmpty || shownKinds.contains(k), onTap: () => onKind(k)),
          if (forgotten)
            row(
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, border: Border.all(color: const Color(0xFFE07A3A), width: 1.6)),
              ),
              'You may have forgotten',
              on: true,
            ),
          if (earlier)
            row(
              Container(
                width: 11,
                height: 11,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Skin.inkSoftOn(context), width: 1.6)),
              ),
              'From an earlier book',
              on: !hideEarlier,
              onTap: onEarlier,
            ),
          row(Row(mainAxisSize: MainAxisSize.min, children: [dot(4), const SizedBox(width: 2), dot(8)]),
              'Bigger: matters more (in more chapters)',
              on: true),
          if (nodes.isNotEmpty) const SizedBox(height: 4),
          for (final k in kinds)
            row(Container(width: 16, height: 3, color: linkColour(k)), linkLabel(k),
                on: !hiddenLinks.contains(k), onTap: () => onLink(k)),
        ],
      ),
    );
  }
}

/// Find anyone in the memory by any of their names, to centre the web on.
class _FindSheet extends StatefulWidget {
  const _FindSheet({required this.path, required this.line});

  final String path;
  final int? line;

  @override
  State<_FindSheet> createState() => _FindSheetState();
}

class _FindSheetState extends State<_FindSheet> {
  List<LedgerEntry>? _found;

  @override
  void initState() {
    super.initState();
    unawaited(_find(''));
  }

  Future<void> _find(String q) async {
    final r = await _findOff(widget.path, widget.line, q);
    if (mounted) setState(() => _found = r);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            const SheetHeader('Centre the web on…'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              child: SearchField(hint: 'Find by any name', autofocus: true, onChanged: (v) => unawaited(_find(v))),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final e in _found ?? const <LedgerEntry>[])
                    ListTile(
                      leading: KindDot(e.kind),
                      title: Text(e.name),
                      subtitle: Text('${kindLabel(e.kind)} · in ${e.mentions} chapters', style: Skin.meta(context)),
                      onTap: () => Navigator.of(context).pop(e.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// Draws the graph as it stood at [chapter]: nodes not met yet, and links
/// not made or already ended, left out, every node in its place for the
/// whole book, so the timeline does not move them. Nodes, lines and names
/// keep their size on the screen whatever the zoom. Links are coloured by
/// what they are: softly at rest, in full when they touch the one picked;
/// what came since [since] is marked, and links that ended since then are
/// shown dashed. Each node wears a thin ring of the ground, so it stands
/// clear of the links; the person in the middle and the one picked a firm
/// ring of their own. Ones the reader may have forgotten wear a broken amber
/// ring. On the Story map, each group is a bubble with its name, opening
/// into its members as it is zoomed into. Only what is on the screen is
/// drawn, and names are laid out once and kept, so a big book pans smoothly.
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.data,
    required this.at,
    required this.chapter,
    required this.picked,
    this.second,
    required this.view,
    required this.dark,
    required this.ink,
    this.ground,
    this.names = GraphNames.key,
    this.sectors = const [],
    this.groups = const [],
    this.hiddenLinks = const {},
    this.hideEarlier = false,
    this.groupNames = const {},
    this.since,
    this.path,
    this.viewport = Size.zero,
    this.cluster = const {},
    this.byGroup = true,
  }) : super(repaint: view);

  /// Each node's group (see clustersOf), for colouring by group.
  final Map<int, int> cluster;

  /// Nodes coloured by their group (as a web of groups reads at a glance);
  /// else by their kind.
  final bool byGroup;

  /// The size of the graph's area on the screen: names keep inside it.
  final Size viewport;

  final GraphData data;
  final Map<int, ({double x, double y})> at;
  final int chapter;
  final int? picked;
  final int? second;
  final TransformationController view;
  final bool dark;
  final Color ink;

  /// The ground the graph sits on (null: white by day, near black by night):
  /// names wear a halo of it, and nodes a thin ring of it.
  final Color? ground;
  final GraphNames names;
  final List<GraphSector> sectors;
  final List<GraphGroup> groups;
  final Set<LinkKind> hiddenLinks;

  /// Those carried over from an earlier book (before chapter 1), left out.
  final bool hideEarlier;
  final Map<int, String> groupNames;
  final int? since;
  final List<int>? path;

  /// A group opens into its members once it is this wide on the screen.
  static const openAt = 230.0;

  static const _amber = Color(0xFFE07A3A);

  /// The groups' colours, the biggest group first: warm and cool in turn,
  /// so groups side by side stand apart; past these, round the wheel.
  static const _groupHues = [
    Color(0xFFE8584F),
    Color(0xFF8E5BD8),
    Color(0xFFF08A3C),
    Color(0xFFB65AC0),
    Color(0xFFE2667F),
    Color(0xFF6B6FE0),
    Color(0xFFE9A23B),
    Color(0xFF9B4F96),
    Color(0xFF4F8FE0),
    Color(0xFF3FA796),
  ];

  static Color groupColour(int i) => i >= 0 && i < _groupHues.length
      ? _groupHues[i]
      : HSLColor.fromAHSL(1, (i * 137.508 + 200) % 360, 0.5, 0.58).toColor();

  Color get _ground => ground ?? (dark ? const Color(0xFF101614) : Colors.white);

  /// Names laid out once, at their size on the screen, and kept across
  /// frames: a pan or a zoom draws the same names again, scaled, rather than
  /// laying each out anew on every frame.
  static final _labels = <(String, double, int, int, bool), TextPainter>{};
  static const _labelsKept = 4000;

  static TextPainter _label(String text, double size, FontWeight weight, Color colour, {bool halo = false}) =>
      _labels[(text, size, weight.value, colour.toARGB32(), halo)] ??= TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'Figtree',
            fontSize: size,
            fontWeight: weight,
            color: halo ? null : colour,
            foreground: halo
                ? (Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = size * 0.3
                  ..strokeJoin = StrokeJoin.round
                  ..color = colour)
                : null,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size * 16);

  /// What does not change with the view, worked out once for this painter
  /// (a pan or a zoom draws the same again): what is shown, its links, its
  /// sizes and colours, the order names are tried in.
  late final _Prep _prep = _prepare();

  _Prep _prepare() {
    final visible = <int, GraphNode>{
      for (final n in data.nodes)
        if ((n.firstCh ?? 0) <= chapter && at[n.id] != null && !(hideEarlier && (n.firstCh ?? 0) < 0)) n.id: n,
    };
    final from = since;
    bool isNew(int ch) => from != null && ch > from && ch <= chapter;
    final edges = [
      for (final e in data.edges)
        if (!hiddenLinks.contains(e.kind) &&
            visible.containsKey(e.a) &&
            visible.containsKey(e.b) &&
            (e.at(chapter) || (e.untilCh != null && isNew(e.untilCh!))))
          e,
    ];
    final onPath = <(int, int)>{};
    final chain = path;
    if (chain != null) {
      for (var i = 0; i + 1 < chain.length; i++) {
        onPath
          ..add((chain[i], chain[i + 1]))
          ..add((chain[i + 1], chain[i]));
      }
    }
    final near = <int>{
      if (picked != null) picked!,
      if (second != null) second!,
      ...?chain,
      for (final e in edges)
        if (e.at(chapter) && (e.a == picked || e.b == picked)) ...[e.a, e.b],
    };
    // Sizes by standing among those shown: the few that matter most stand
    // out, the many are fine points. (By chapters alone, in a book of
    // thousands nearly everyone reached the largest size.)
    final byWeight = visible.values.toList()..sort((a, b) => b.weight.compareTo(a.weight));
    final radius = <int, double>{};
    final n = byWeight.length;
    final least = n <= 30 ? 3.2 : (n <= 200 ? 2.2 : 1.6);
    var rankOf = 0;
    for (var i = 0; i < n; i++) {
      if (i == 0 || byWeight[i].weight != byWeight[i - 1].weight) rankOf = i;
      // By place, not share: about a dozen stand out however many are
      // shown (by share, a web of 1,800 still drew some fifty large), and
      // the rest are fine points.
      final r = least + (8.5 - least) * math.exp(-rankOf / 6);
      radius[byWeight[i].id] = byWeight[i].id == data.focus ? math.max(r, 7.0) : r;
    }
    // Each group its own colour, the biggest first; one alone, plain.
    final sizes = <int, int>{};
    for (final id in visible.keys) {
      final c = cluster[id];
      if (c != null) sizes[c] = (sizes[c] ?? 0) + 1;
    }
    final plainDot = Color.lerp(ink, const Color(0xFF8C8C96), 0.5)!;
    final colour = <int, Color>{
      for (final node in visible.values)
        node.id: !byGroup
            ? kindColour(node.kind)
            : switch (cluster[node.id]) {
                final c? when (sizes[c] ?? 0) > 1 => groupColour(c),
                _ => plainDot,
              },
    };
    int rank(GraphNode n) => n.id == picked || n.id == second ? 3 : (near.contains(n.id) ? 2 : (n.forgotten ? 1 : 0));
    final named = [...byWeight]..sort((a, b) {
        final r = rank(b).compareTo(rank(a));
        return r != 0 ? r : b.weight.compareTo(a.weight);
      });
    return _Prep(
      visible: visible,
      edges: edges,
      onPath: onPath,
      near: near,
      order: byWeight.reversed.toList(),
      radius: radius,
      colour: colour,
      named: named,
      rank: {for (final n in visible.values) n.id: rank(n)},
    );
  }

  /// The links and nodes, drawn once at a scale and kept as a picture: a
  /// pan, or a zoom within a little of it, draws the picture again rather
  /// than every link and node.
  ui.Picture? _base;
  double _baseScale = 0;

  /// The picture last made, let go of when the next is made.
  static ui.Picture? _lastBase;

  @override
  void paint(Canvas canvas, Size size) {
    // Kept names let go of between frames, never while one is drawn.
    if (_labels.length > _labelsKept) {
      for (final t in _labels.values) {
        t.dispose();
      }
      _labels.clear();
    }
    final scale = viewScale(view.value);
    // A screen pixel, in the canvas's own units.
    final dp = 1 / scale;
    final shown = viewport == Size.zero ? null : MatrixUtils.inverseTransformRect(view.value, Offset.zero & viewport);
    final room = shown?.inflate(24 * dp);
    bool onScreen(Offset p, double r) => room == null || room.inflate(r).contains(p);
    final prep = _prep;
    final visible = prep.visible;
    Offset o(int id) => Offset(at[id]!.x, at[id]!.y);

    _grid(canvas, shown, dp);

    // The Story map's groups, shut (their name only) until zoomed into.
    final shut = <int>{};
    for (final g in groups) {
      if (g.reach * scale < openAt) shut.addAll(g.members);
    }

    if (_base == null || (scale / _baseScale - 1).abs() > 0.12) {
      final recorder = ui.PictureRecorder();
      _drawBase(Canvas(recorder), scale, shut);
      _base = recorder.endRecording();
      _baseScale = scale;
      if (!identical(_lastBase, _base)) {
        _lastBase?.dispose();
        _lastBase = _base;
      }
    }
    canvas.drawPicture(_base!);

    // Names are kept off the bigger circles as well as off each other
    // (those on the screen: the rest cannot meet a name drawn there).
    double r(int id) => (prep.radius[id] ?? 2) * dp;
    final placed = <Rect>[
      for (final n in visible.values)
        if ((prep.radius[n.id] ?? 0) >= 3 && !shut.contains(n.id) && onScreen(o(n.id), 0))
          Rect.fromCircle(center: o(n.id), radius: r(n.id)),
    ];
    // The groups' names, each on its island's top edge, always shown.
    for (final g in groups) {
      if (g.reach * scale >= openAt || !onScreen(g.centre, g.reach)) continue;
      final name = groupNames[g.id] ?? '${visible[g.top]?.name ?? ''} and ${g.members.length - 1} more';
      final rect = _pill(canvas, name, g.centre - Offset(0, g.reach * 0.86), 12, dp, groupColour(g.id),
          strong: false, force: true);
      if (rect != null) placed.add(rect);
    }

    // The person in the middle is always named, before anything else.
    final f = data.focus;
    if (f != null && visible.containsKey(f) && f != picked && f != second) {
      final rect = _pill(canvas, visible[f]!.name, o(f) + Offset(0, r(f) + 15 * dp), 12.5, dp, ink,
          strong: false, force: true, bare: true);
      if (rect != null) placed.add(rect);
    }

    // The sections of the ring round the focus.
    if (picked == null) {
      for (final c in sectors) {
        if (!onScreen(Offset(c.x, c.y), 0)) continue;
        final rect = _pill(canvas, linkLabel(c.kind), Offset(c.x, c.y), 10.5, dp, linkColour(c.kind),
            strong: false, avoid: placed, faint: true);
        if (rect != null) placed.add(rect);
      }
    }

    // The labels on the links of the one picked.
    if (picked != null && prep.edges.length <= 1500) {
      for (final e in prep.edges) {
        if (e.kind == LinkKind.shared || (e.a != picked && e.b != picked)) continue;
        if (shut.contains(e.a) && shut.contains(e.b)) continue;
        final mid = (o(e.a) + o(e.b)) / 2;
        if (!onScreen(mid, 0)) continue;
        _pill(canvas, e.at(chapter) ? e.label : '${e.label} (ended)', mid, 10.5, dp, linkColour(e.kind),
            strong: false);
      }
    }

    // Names: the picked and those linked, then the most important; each
    // kept only where it overlaps none placed before.
    var plain = 0;
    for (final n in prep.named) {
      if (shut.contains(n.id)) continue;
      if (n.id == f && f != picked && f != second) continue;
      final important = (prep.rank[n.id] ?? 0) >= 2 || n.id == data.focus;
      if (picked != null && !prep.near.contains(n.id)) continue;
      if (!important) {
        if (names == GraphNames.none) continue;
        if (names == GraphNames.key && plain >= 16 && !n.forgotten) continue;
      }
      final strong = n.id == picked || n.id == second;
      if (!strong && !onScreen(o(n.id), 0)) continue;
      // Below the circle, or above, right or left of it: the first free.
      // The one picked a little further out, clear of its ring.
      final rr = r(n.id);
      final gap = (strong ? 14 : 9) * dp;
      final w = _width(n.name, 11.5, dp, strong);
      Rect? rect;
      for (final at in [
        o(n.id) + Offset(0, rr + gap),
        o(n.id) - Offset(0, rr + gap),
        o(n.id) + Offset(rr + 4 * dp + w / 2, 0),
        o(n.id) - Offset(rr + 4 * dp + w / 2, 0),
      ]) {
        if (shown != null && !shown.contains(at.translate(-w / 2, 0)) ||
            shown != null && !shown.contains(at.translate(w / 2, 0))) {
          continue;
        }
        rect = _pill(canvas, n.name, at, 11.5, dp, ink, strong: strong, avoid: placed, bare: !strong);
        if (rect != null) break;
      }
      rect ??= strong ? _pill(canvas, n.name, o(n.id) + Offset(0, rr + gap), 11.5, dp, ink, strong: true, force: true) : null;
      if (rect != null) {
        placed.add(rect);
        if (!important) plain++;
      }
    }
  }

  /// A fine grid of points behind the graph, moving with it; its spacing
  /// doubles or halves as the zoom does, so it stays between about 22 and
  /// 45 points apart on the screen.
  void _grid(Canvas canvas, Rect? shown, double dp) {
    if (shown == null) return;
    final step = 32 * math.pow(2, (math.log(dp) / math.ln2).round()).toDouble();
    final x0 = (shown.left / step).floor() * step, y0 = (shown.top / step).floor() * step;
    final cols = (shown.width / step).ceil() + 1, rows = (shown.height / step).ceil() + 1;
    if (cols * rows > 6000) return;
    final points = Float32List(cols * rows * 2);
    var i = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        points[i++] = x0 + c * step;
        points[i++] = y0 + r * step;
      }
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = ink.withValues(alpha: dark ? 0.16 : 0.12)
        ..strokeWidth = 1.7 * dp
        ..strokeCap = StrokeCap.round,
    );
  }

  /// The links and the nodes, as they look at [scale].
  void _drawBase(Canvas canvas, double scale, Set<int> shut) {
    final prep = _prep;
    final dp = 1 / scale;
    final px = 1.4 / scale;
    final ground = _ground;
    final from = since;
    bool isNew(int ch) => from != null && ch > from && ch <= chapter;
    Offset o(int id) => Offset(at[id]!.x, at[id]!.y);

    for (final g in groups) {
      final open = g.reach * scale >= openAt;
      canvas.drawCircle(g.centre, g.reach, Paint()..color = groupColour(g.id).withValues(alpha: open ? 0.06 : 0.22));
    }

    // Links at rest, by colour and width, each lot drawn in one go.
    final lots = <(int, double), List<double>>{};
    // Lit, new or dashed: one by one, over the rest.
    final over = <(Offset, Offset, Color, double, bool)>[];
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final e in prep.edges) {
      if (shut.contains(e.a) && shut.contains(e.b)) continue;
      final p1 = o(e.a), p2 = o(e.b);
      final pathEdge = prep.onPath.contains((e.a, e.b));
      final lit = (picked != null && (e.a == picked || e.b == picked)) || pathEdge;
      final ended = !e.at(chapter);
      final fresh = isNew(e.fromCh);
      final faded = picked != null && !lit;
      final shared = e.kind == LinkKind.shared;
      final kindColour = ended ? ink : linkColour(e.kind);
      // At rest: in the colours of the groups it joins (blended across two),
      // or by what it is, drawn towards the ink. Lit, or new since the
      // timeline moved, by what it is, in full.
      final Color rest;
      if (byGroup) {
        final a = prep.colour[e.a]!, b = prep.colour[e.b]!;
        rest = shared || ended ? Color.lerp(a, ink, 0.4)! : Color.lerp(a, b, 0.5)!;
      } else {
        rest = shared || ended ? ink : Color.lerp(ink, kindColour, 0.7)!;
      }
      final across = byGroup && cluster[e.a] != cluster[e.b];
      final colour = (pathEdge ? _amber : (lit || fresh ? kindColour : rest)).withValues(
        alpha: faded
            ? 0.04
            : ended
                ? 0.25
                : lit || fresh
                    ? 0.9
                    : shared
                        ? math.min(0.2, 0.06 + e.weight * 0.02)
                        : (across ? 0.22 : 0.34),
      );
      final width = (lit || fresh ? 1.4 : (shared ? 0.6 : 0.8)) * (pathEdge ? 1.8 : 1) * px;
      final dashed = e.kind == LinkKind.belongs || ended;
      if (dashed || lit || fresh || pathEdge) {
        over.add((p1, p2, colour, width, dashed));
      } else {
        (lots[(colour.toARGB32(), width)] ??= []).addAll([p1.dx, p1.dy, p2.dx, p2.dy]);
      }
    }
    for (final MapEntry(key: (argb, width), value: points) in lots.entries) {
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.fromList(points),
        line
          ..color = Color(argb)
          ..strokeWidth = width,
      );
    }
    for (final (p1, p2, colour, width, dashed) in over) {
      line
        ..color = colour
        ..strokeWidth = width;
      if (dashed) {
        _dashLine(canvas, p1, p2, line, 8 * px, 6 * px);
      } else {
        canvas.drawLine(p1, p2, line);
      }
    }

    // Nodes, the heaviest last so they sit on top.
    final fill = Paint();
    final ring = Paint()..style = PaintingStyle.stroke;
    for (final n in prep.order) {
      final c = o(n.id);
      final inShut = shut.contains(n.id);
      final r = (prep.radius[n.id] ?? 2) * dp * (inShut ? 0.7 : 1);
      final dim = picked != null && !prep.near.contains(n.id);
      final colour = prep.colour[n.id]!;
      final newHere = n.firstCh != null && isNew(n.firstCh!);
      final mark = n.id == picked || n.id == second;
      // A soft glow round the one picked, the person in the middle, one new
      // here, and the few that matter most.
      final hub = (prep.radius[n.id] ?? 0) >= 6.5;
      if (mark || n.id == data.focus || newHere || hub) {
        canvas.drawCircle(
          c,
          r * 2.4 + 3 * dp,
          fill..color = (newHere ? _amber : colour).withValues(alpha: mark ? 0.34 : (hub && !dim ? 0.16 : 0.2)),
        );
      }
      // A thin ring of the ground keeps a bigger one clear of the links
      // that run into it (the small points go without: they read as dots).
      if (!dim && !inShut && r >= 3 * dp) canvas.drawCircle(c, r + 1.3 * dp, fill..color = ground.withValues(alpha: 0.9));
      canvas.drawCircle(c, r, fill..color = colour.withValues(alpha: dim ? 0.18 : (inShut ? 0.6 : 1)));
      // The one picked (the accent) and the person in the middle (their own
      // colour): a firm ring a little way out.
      if ((mark || n.id == data.focus) && !inShut) {
        canvas.drawCircle(
          c,
          r + 4.5 * dp,
          ring
            ..strokeWidth = 1.6 * dp
            ..color = (mark ? _amber : colour).withValues(alpha: 0.95),
        );
      }
      // Carried over from an earlier book of the series: a thin plain ring.
      if ((n.firstCh ?? 0) < 0 && !inShut) {
        canvas.drawCircle(
          c,
          r + 2 * dp,
          ring
            ..strokeWidth = 1 * dp
            ..color = ink.withValues(alpha: dim ? 0.15 : 0.55),
        );
      }
      // One the reader may have forgotten: a broken amber ring, eight arcs.
      if (n.forgotten && !inShut) {
        ring
          ..strokeWidth = 1 * dp
          ..color = _amber.withValues(alpha: dim ? 0.2 : 0.8);
        final box = Rect.fromCircle(center: c, radius: r + 3 * dp);
        for (var i = 0; i < 8; i++) {
          canvas.drawArc(box, i * math.pi / 4, math.pi / 8, false, ring);
        }
      }
    }
  }

  /// How wide a name's label is, in the canvas's units: [size] is its size
  /// on the screen.
  double _width(String text, double size, double dp, bool strong) {
    final tp = strong
        ? _label(text, size, FontWeight.w700, Colors.white)
        : _label(text, size, FontWeight.w500, ink.withValues(alpha: 0.85));
    return (tp.width + size) * dp;
  }

  /// [text] on a small pill centred at [at], [size] high on the screen;
  /// null (and nothing drawn) when it would overlap one of [avoid], unless
  /// [force].
  Rect? _pill(Canvas canvas, String text, Offset at, double size, double dp, Color colour,
      {required bool strong, List<Rect> avoid = const [], bool force = false, bool faint = false, bool bare = false}) {
    final weight = strong ? FontWeight.w700 : (bare ? FontWeight.w500 : FontWeight.w600);
    final tp =
        _label(text, size, weight, strong ? Colors.white : colour.withValues(alpha: faint ? 0.75 : (bare ? 0.85 : 1)));
    final pad = (bare ? Offset(size * 0.2, size * 0.05) : Offset(size * 0.5, size * 0.25)) * dp;
    final rect = Rect.fromCenter(center: at, width: tp.width * dp + pad.dx * 2, height: tp.height * dp + pad.dy * 2);
    if (!force && avoid.any((r) => r.overlaps(rect))) return null;
    void draw(TextPainter t) {
      canvas
        ..save()
        ..translate(rect.left + pad.dx, rect.top + pad.dy)
        ..scale(dp);
      t.paint(canvas, Offset.zero);
      canvas.restore();
    }

    if (bare) {
      // Plain text, kept legible over the links by a halo of the ground.
      draw(_label(text, size, weight, _ground.withValues(alpha: 0.85), halo: true));
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()..color = strong ? _amber : _ground.withValues(alpha: faint ? 0.55 : 0.82),
      );
    }
    draw(tp);
    return rect;
  }

  /// A straight dashed line from [a] to [b]; solid when it would take too
  /// many dashes (one running far off the screen, zoomed right in).
  void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint, double on, double off) {
    final d = b - a;
    final length = d.distance;
    if (length == 0) return;
    if (length / (on + off) > 600) {
      canvas.drawLine(a, b, paint);
      return;
    }
    final step = d / length;
    for (var t = 0.0; t < length; t += on + off) {
      canvas.drawLine(a + step * t, a + step * math.min(t + on, length), paint);
    }
  }

  @override
  bool shouldRepaint(GraphPainter old) =>
      old.data != data ||
      old.at != at ||
      old.chapter != chapter ||
      old.picked != picked ||
      old.second != second ||
      old.dark != dark ||
      old.ink != ink ||
      old.ground != ground ||
      old.names != names ||
      old.sectors != sectors ||
      old.groups.length != groups.length ||
      !setEquals(old.hiddenLinks, hiddenLinks) ||
      old.cluster != cluster ||
      old.byGroup != byGroup ||
      old.hideEarlier != hideEarlier ||
      old.since != since ||
      old.groupNames != groupNames ||
      old.path != path;
}

/// What a [GraphPainter] works out once (see GraphPainter._prepare).
class _Prep {
  const _Prep({
    required this.visible,
    required this.edges,
    required this.onPath,
    required this.near,
    required this.order,
    required this.radius,
    required this.colour,
    required this.named,
    required this.rank,
  });

  final Map<int, GraphNode> visible;
  final List<GraphEdge> edges;
  final Set<(int, int)> onPath;
  final Set<int> near;

  /// The nodes, lightest first, so the heaviest are drawn on top.
  final List<GraphNode> order;

  /// Each node's radius on the screen.
  final Map<int, double> radius;
  final Map<int, Color> colour;

  /// The order names are tried in.
  final List<GraphNode> named;
  final Map<int, int> rank;
}

/// One control under the graph: its name and what it is set to above, a
/// button beside them if it has one, its track below.
class _ControlRow extends StatelessWidget {
  const _ControlRow({required this.title, required this.value, required this.slider, required this.ground, this.action});

  /// The page's ground, a halo round the words so they read over the links.
  final Color ground;
  final String title;
  final String value;
  final Widget slider;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title.toUpperCase(),
                  style: Skin.meta(context, size: 10.5).copyWith(letterSpacing: 1.1, shadows: _halo(ground))),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Skin.ui(size: 13, weight: FontWeight.w600, color: Skin.inkOn(context))
                        .copyWith(shadows: _halo(ground))),
              ),
              if (action != null) action! else const SizedBox(height: 36),
            ],
          ),
          slider,
        ],
      );
}

/// A soft halo of [ground] round words drawn over the graph.
List<Shadow> _halo(Color ground) => [
      for (final o in const [Offset(0, 0), Offset(1, 1), Offset(-1, -1), Offset(1, -1), Offset(-1, 1)])
        Shadow(color: ground, blurRadius: 5, offset: o),
    ];
