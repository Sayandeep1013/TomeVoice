import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

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

/// How far the view is zoomed: its scale along x (a Matrix4's own largest
/// axis scale counts z, which stays 1, and so never reads below 1).
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
      this.nameGroups = false});

  final String bookTitle;
  final String memoryPath;

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
    ..scaleByDouble(scale, scale, 1, 1);

  /// The view it starts with: all of it, unless that would crowd the nodes
  /// onto each other (then as near as the spacing allows, a little closer
  /// than the layout's own, which still keeps them apart), the person in
  /// the middle, or the middle of it, in view.
  Matrix4 _fitView(Size box) {
    final all = math.min(box.width / _size, box.height / _height);
    final s = _depth == GraphDepth.map ? all : math.max(all, 0.7 / canvasPerDp);
    return _viewAt(_middle(), s, box.center(Offset.zero));
  }

  /// The side of the square the web is laid out in.
  double _size = 1000, _height = 1000;

  /// The graph area's height over its width, for the layout's shape.
  double _aspect = 1.6;
  bool _legend = false;

  /// Seen as a ball to turn, and where each node sits in it.
  bool _ball = false;
  Map<int, ({double x, double y, double z})>? _at3;

  GraphData? _data;
  Map<int, ({double x, double y})> _at = const {};
  Map<int, ({double x, double y})> _from = const {};
  late final AnimationController _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 450))
    ..addListener(_moved);

  int? _focus;
  GraphDepth _depth = GraphDepth.one;
  final Set<String> _kinds = {};
  final Set<LinkKind> _hiddenLinks = {};
  GraphNames _names = GraphNames.key;

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
    _focus = await _mainOff(widget.memoryPath, widget.line);
    if (_focus == null) _depth = GraphDepth.all;
    await _load();
  }

  Future<void> _load() async {
    final n = ++_asked;
    setState(() => _loading = true);
    final r = await _drawn(
      widget.memoryPath,
      widget.line,
      widget.here,
      _depth == GraphDepth.all || _depth == GraphDepth.map ? null : _focus,
      _depth == GraphDepth.two ? 2 : 1,
      {..._kinds},
      _shownMost,
      _aspect,
    );
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
      final reply = await AiRouter().chat(
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
  Widget _howMany(BuildContext context, GraphData? data) {
    final steps = [
      for (final s in graphSteps)
        if (s < _choices) s,
      _choices
    ];
    final shown = math.min(_shownMost, _choices);
    var at = steps.indexWhere((s) => s >= shown);
    if (at < 0) at = steps.length - 1;
    final forgotten = data?.forgotten ?? 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.l, Gap.s),
        child: Row(
          children: [
            SizedBox(
              width: 112,
              child: Text(
                '${steps[at] >= _choices ? 'All' : steps[at]} of $_choices'
                '${forgotten > 0 ? '\n$forgotten forgotten' : ''}',
                style: Skin.meta(context),
              ),
            ),
            Expanded(
              child: Slider(
                value: at.toDouble(),
                max: (steps.length - 1).toDouble(),
                divisions: steps.length - 1,
                label: steps[at] >= _choices ? 'Everyone' : 'The ${steps[at]} that matter most',
                onChanged: (v) {
                  final next = steps[v.round()];
                  if (next == _shownMost) return;
                  setState(() => _most = next);
                },
                onChangeEnd: (_) => unawaited(_load()),
              ),
            ),
          ],
        ),
      ),
    );
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
                                        boundaryMargin: const EdgeInsets.all(400),
                                        minScale: 0.04,
                                        maxScale: 6,
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
                                                names: _names,
                                                sectors: _picked == null ? _sectors : const [],
                                                groups: _depth == GraphDepth.map
                                                    ? graphGroups(data, _shown, _cluster, _shownCh)
                                                    : const [],
                                                hiddenLinks: _hiddenLinks,
                                                groupNames: _groupNames,
                                                since: _since,
                                                path: _path,
                                                viewport: _box,
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
                              if (_legend)
                                Positioned(
                                  left: Gap.page,
                                  top: Gap.s,
                                  child: _Legend(
                                    kinds: used,
                                    nodes: kinds,
                                    shownKinds: _kinds,
                                    hiddenLinks: _hiddenLinks,
                                    forgotten: data.forgotten > 0,
                                    onKind: (k) {
                                      setState(() => _kinds.contains(k) ? _kinds.remove(k) : _kinds.add(k));
                                      unawaited(_load());
                                    },
                                    onLink: (k) => setState(
                                        () => _hiddenLinks.contains(k) ? _hiddenLinks.remove(k) : _hiddenLinks.add(k)),
                                  ),
                                ),
                              if (_linking)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: Gap.s,
                                  child: Center(
                                    child: Chip(label: Text('Now tap who to link ${_nameOf(_picked) ?? ''} with')),
                                  ),
                                ),
                            ],
                          ),
              ),
              if (_picked != null) _panel(context),
              if (_end > 0)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.l, Gap.s),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: _playing == null ? 'Play the web growing' : 'Stop',
                          icon: Icon(_playing == null ? Icons.play_arrow_rounded : Icons.pause_rounded),
                          onPressed: _play,
                        ),
                        SizedBox(width: 64, child: Text('Ch ${_shownCh + 1}', style: Skin.meta(context))),
                        Expanded(
                          child: Slider(
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
                      ],
                    ),
                  ),
                ),
              if (_choices > graphSteps.first) _howMany(context, data),
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

class _Legend extends StatelessWidget {
  const _Legend({
    required this.kinds,
    required this.nodes,
    required this.shownKinds,
    required this.hiddenLinks,
    required this.forgotten,
    required this.onKind,
    required this.onLink,
  });

  final List<LinkKind> kinds;
  final List<String> nodes;
  final Set<String> shownKinds;
  final Set<LinkKind> hiddenLinks;
  final bool forgotten;
  final void Function(String kind) onKind;
  final void Function(LinkKind kind) onLink;

  @override
  Widget build(BuildContext context) {
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
/// what they are, faint unless they touch the one picked; what came since
/// [since] is marked, and links that ended since then are shown dashed.
/// Ones the reader may have forgotten wear a broken amber ring. On the Story
/// map, each group is a bubble with its name, opening into its members as
/// it is zoomed into.
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
    this.names = GraphNames.key,
    this.sectors = const [],
    this.groups = const [],
    this.hiddenLinks = const {},
    this.groupNames = const {},
    this.since,
    this.path,
    this.viewport = Size.zero,
  }) : super(repaint: view);

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
  final GraphNames names;
  final List<GraphSector> sectors;
  final List<GraphGroup> groups;
  final Set<LinkKind> hiddenLinks;
  final Map<int, String> groupNames;
  final int? since;
  final List<int>? path;

  /// A group opens into its members once it is this wide on the screen.
  static const openAt = 230.0;

  static const _amber = Color(0xFFE07A3A);

  static Color groupColour(int i) => HSLColor.fromAHSL(1, (i * 137.508 + 200) % 360, 0.45, 0.55).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = viewScale(view.value);
    // A screen pixel, in the canvas's own units.
    final dp = 1 / scale;
    final px = 1.4 / scale;
    final visible = {
      for (final n in data.nodes)
        if ((n.firstCh ?? 0) <= chapter && at[n.id] != null) n.id: n,
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
    Offset o(int id) => Offset(at[id]!.x, at[id]!.y);

    // The Story map: each group a bubble, shut (its name only) until zoomed
    // into, then a faint wash round its members.
    final shut = <int>{};
    for (final g in groups) {
      final open = g.reach * scale >= openAt;
      canvas.drawCircle(g.centre, g.reach, Paint()..color = groupColour(g.id).withValues(alpha: open ? 0.06 : 0.22));
      if (!open) shut.addAll(g.members);
    }

    final many = edges.length > 1500;
    for (final e in edges) {
      if (shut.contains(e.a) && shut.contains(e.b)) continue;
      final pathEdge = onPath.contains((e.a, e.b));
      final lit = (picked != null && (e.a == picked || e.b == picked)) || pathEdge;
      final ended = !e.at(chapter);
      final fresh = isNew(e.fromCh);
      final faded = picked != null && !lit;
      final colour = ended ? ink : linkColour(e.kind);
      final p1 = o(e.a), p2 = o(e.b);
      final mid = (p1 + p2) / 2;
      final d = p2 - p1;
      final bend = ((e.a + e.b) % 2 == 0 ? 1 : -1) * 0.12;
      final ctrl = mid + Offset(-d.dy, d.dx) * bend;
      final line = Path()..moveTo(p1.dx, p1.dy);
      if (many) {
        line.lineTo(p2.dx, p2.dy);
      } else {
        line.quadraticBezierTo(ctrl.dx, ctrl.dy, p2.dx, p2.dy);
      }
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..color = (pathEdge ? _amber : colour).withValues(
          alpha: faded
              ? 0.05
              : ended
                  ? 0.35
                  : lit || fresh
                      ? 0.95
                      : e.kind == LinkKind.shared
                          ? 0.07
                          : 0.38,
        )
        ..strokeWidth = (e.kind == LinkKind.shared ? 1.0 + math.min(2.0, e.weight / 4) : 2.0) *
            (lit || fresh ? 1.6 : 1) *
            (pathEdge ? 1.8 : 1) *
            px;
      if (e.kind == LinkKind.belongs || ended) {
        _dashed(canvas, line, paint, 8 * px, 6 * px);
      } else {
        canvas.drawPath(line, paint);
      }
      if (lit && e.kind != LinkKind.shared && !many) {
        _pill(canvas, ended ? '${e.label} (ended)' : e.label, (ctrl + mid) / 2, 10.5 * dp, colour, strong: false);
      }
    }

    // Nodes, the heaviest last so they sit on top.
    final order = visible.values.toList()..sort((a, b) => a.weight.compareTo(b.weight));
    for (final n in order) {
      final c = o(n.id);
      final inShut = shut.contains(n.id);
      final r = nodeDp(n.weight) * dp * (inShut ? 0.6 : 1);
      final dim = picked != null && !near.contains(n.id);
      final colour = kindColour(n.kind);
      final newHere = n.firstCh != null && isNew(n.firstCh!);
      if (n.id == picked || n.id == second || n.id == data.focus || newHere) {
        canvas.drawCircle(
          c,
          r + 6 * dp,
          Paint()..color = (newHere ? _amber : ink).withValues(alpha: n.id == picked || n.id == second ? 0.35 : 0.2),
        );
      }
      canvas.drawCircle(c, r, Paint()..color = colour.withValues(alpha: dim ? 0.2 : (inShut ? 0.6 : 1)));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * px
          ..color = (dark ? Colors.black : Colors.white).withValues(alpha: dim ? 0.2 : 0.7),
      );
      // One the reader may have forgotten: a broken amber ring.
      if (n.forgotten && !inShut) {
        _dashed(
          canvas,
          Path()..addOval(Rect.fromCircle(center: c, radius: r + 4 * dp)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 * dp
            ..color = _amber.withValues(alpha: dim ? 0.2 : 0.75),
          3 * dp,
          3.5 * dp,
        );
      }
    }

    // Names are kept off the circles as well as off each other.
    final placed = <Rect>[
      if (visible.length <= 1500)
        for (final n in visible.values)
          if (!shut.contains(n.id)) Rect.fromCircle(center: o(n.id), radius: nodeDp(n.weight) * dp),
    ];
    // The groups' names, each on its island's top edge, always shown.
    for (final g in groups) {
      if (g.reach * scale >= openAt) continue;
      final name = groupNames[g.id] ?? '${visible[g.top]?.name ?? ''} and ${g.members.length - 1} more';
      final rect = _pill(canvas, name, g.centre - Offset(0, g.reach * 0.86), 12 * dp, groupColour(g.id),
          strong: false, force: true);
      if (rect != null) placed.add(rect);
    }

    // The person in the middle is always named, before anything else.
    final f = data.focus;
    if (f != null && visible.containsKey(f) && f != picked && f != second) {
      final rect = _pill(
          canvas, visible[f]!.name, o(f) + Offset(0, (nodeDp(visible[f]!.weight) + 11) * dp), 12.5 * dp, ink,
          strong: false, force: true);
      if (rect != null) placed.add(rect);
    }

    // The sections of the ring round the focus.
    if (picked == null) {
      for (final c in sectors) {
        final rect = _pill(canvas, linkLabel(c.kind), Offset(c.x, c.y), 10.5 * dp, linkColour(c.kind),
            strong: false, avoid: placed, faint: true);
        if (rect != null) placed.add(rect);
      }
    }

    // Names: the picked and those linked, then the most important; each
    // kept only where it overlaps none placed before.
    int rank(GraphNode n) => n.id == picked || n.id == second ? 3 : (near.contains(n.id) ? 2 : (n.forgotten ? 1 : 0));
    final byWeight = visible.values.where((n) => !shut.contains(n.id)).toList()
      ..sort((a, b) {
        final r = rank(b).compareTo(rank(a));
        return r != 0 ? r : b.weight.compareTo(a.weight);
      });
    // What of the graph is on the screen now.
    final shown = viewport == Size.zero ? null : MatrixUtils.inverseTransformRect(view.value, Offset.zero & viewport);
    var plain = 0;
    for (final n in byWeight) {
      if (n.id == f && f != picked && f != second) continue;
      final important = rank(n) >= 2 || n.id == data.focus;
      if (picked != null && !near.contains(n.id)) continue;
      if (!important) {
        if (names == GraphNames.none) continue;
        if (names == GraphNames.key && plain >= 16 && !n.forgotten) continue;
      }
      final strong = n.id == picked || n.id == second;
      // Below the circle, or above, right or left of it: the first free.
      final r = nodeDp(n.weight) * dp;
      final w = _width(n.name, 11.5 * dp, strong);
      Rect? rect;
      for (final at in [
        o(n.id) + Offset(0, r + 11 * dp),
        o(n.id) - Offset(0, r + 11 * dp),
        o(n.id) + Offset(r + 4 * dp + w / 2, 0),
        o(n.id) - Offset(r + 4 * dp + w / 2, 0),
      ]) {
        if (shown != null && !shown.contains(at.translate(-w / 2, 0)) ||
            shown != null && !shown.contains(at.translate(w / 2, 0))) {
          continue;
        }
        rect = _pill(canvas, n.name, at, 11.5 * dp, ink, strong: strong, avoid: placed);
        if (rect != null) break;
      }
      rect ??= strong
          ? _pill(canvas, n.name, o(n.id) + Offset(0, r + 11 * dp), 11.5 * dp, ink, strong: true, force: true)
          : null;
      if (rect != null) {
        placed.add(rect);
        if (!important) plain++;
      }
    }
  }

  /// How wide [text]'s pill is.
  double _width(String text, double size, bool strong) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style:
              TextStyle(fontFamily: 'Figtree', fontSize: size, fontWeight: strong ? FontWeight.w700 : FontWeight.w600)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: size * 16);
    return tp.width + size;
  }

  /// [text] on a small pill centred at [at]; null (and nothing drawn) when
  /// it would overlap one of [avoid], unless [force].
  Rect? _pill(Canvas canvas, String text, Offset at, double size, Color colour,
      {required bool strong, List<Rect> avoid = const [], bool force = false, bool faint = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Figtree',
          fontSize: size,
          color: strong ? Colors.white : colour.withValues(alpha: faint ? 0.75 : 1),
          fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size * 16);
    final pad = Offset(size * 0.5, size * 0.25);
    final rect = Rect.fromCenter(center: at, width: tp.width + pad.dx * 2, height: tp.height + pad.dy * 2);
    if (!force && avoid.any((r) => r.overlaps(rect))) return null;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()
        ..color =
            strong ? _amber : (dark ? const Color(0xFF101614) : Colors.white).withValues(alpha: faint ? 0.55 : 0.82),
    );
    tp.paint(canvas, rect.topLeft + pad);
    return rect;
  }

  void _dashed(Canvas canvas, Path path, Paint paint, double on, double off) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + on, m.length)), paint);
        d += on + off;
      }
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
      old.names != names ||
      old.sectors != sectors ||
      old.groups.length != groups.length ||
      old.hiddenLinks.length != hiddenLinks.length ||
      old.since != since ||
      old.groupNames != groupNames ||
      old.path != path;
}
