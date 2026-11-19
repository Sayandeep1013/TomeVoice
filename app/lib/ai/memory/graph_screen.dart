import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../talk/name_card.dart';
import 'ledger.dart';
import 'whos_who_screen.dart' show KindDot, kindColour, kindLabel;

// Off the UI thread's isolate, each from a function of its own with plain
// values (a closure made in the State's methods would carry the State).
Future<({GraphData data, Map<int, ({double x, double y})> at, double size})> _drawn(
  String path,
  int? at,
  int? focus,
  int depth,
  Set<String> kinds,
  int minChapters,
) =>
    Isolate.run(() => graphAndLayout(path,
        at: at, focus: focus, depth: depth, kinds: kinds.isEmpty ? null : kinds, minChapters: minChapters));
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

/// How far out from the person in the middle the web goes.
enum GraphDepth { one, two, all }

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
  const MemoryGraphScreen({super.key, required this.bookTitle, required this.memoryPath, this.line});

  final String bookTitle;
  final String memoryPath;

  /// The spoiler line (null: the guard is off).
  final int? line;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> with SingleTickerProviderStateMixin {
  /// The side of the square the web is laid out in.
  double _size = 1000;
  bool _legend = false;

  GraphData? _data;
  Map<int, ({double x, double y})> _at = const {};
  Map<int, ({double x, double y})> _from = const {};
  late final AnimationController _move =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450))..addListener(_moved);

  int? _focus;
  GraphDepth _depth = GraphDepth.one;
  final Set<String> _kinds = {};
  bool _minor = false;
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
      _depth == GraphDepth.all ? null : _focus,
      _depth == GraphDepth.two ? 2 : 1,
      {..._kinds},
      _minor ? 1 : 2,
    );
    if (!mounted || n != _asked) return;
    final was = _shown;
    setState(() {
      // From where each node was to where it is now (new ones from the
      // middle), so a change of focus moves the web rather than cuts it.
      _from = {
        for (final id in r.at.keys) id: was[id] ?? (x: _size / 2, y: _size / 2),
      };
      _data = r.data;
      _at = r.at;
      if (r.size != _size) {
        _size = r.size;
        _fitted = false;
      }
      _loading = false;
      if (_picked != null && !_at.containsKey(_picked)) _clearPick();
    });
    unawaited(_move.forward(from: 0));
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
      if (mounted && _second == id) setState(() => _links = links);
      return;
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
    final dp = 1 / _view.value.getMaxScaleOnAxis();
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
          _chapter = null;
          _playing = null;
          t.cancel();
        } else {
          _chapter = next;
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
    final used = {for (final e in data?.edges ?? const <GraphEdge>[]) if (e.at(_shownCh)) e.kind}.toList()
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
                    tooltip: _legend ? 'Hide the key' : 'What the colours mean',
                    isSelected: _legend,
                    icon: const Icon(Icons.legend_toggle_rounded),
                    onPressed: () => setState(() => _legend = !_legend),
                  ),
                  IconButton(
                    tooltip: 'Fit to the screen',
                    icon: const Icon(Icons.fit_screen_rounded),
                    onPressed: () => setState(() => _fitted = false),
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
                          }),
                          selected: _depth == d,
                          onSelected: (_) {
                            setState(() => _depth = d);
                            unawaited(_load());
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.s),
                      child: FilterChip(
                        label: const Text('Minor ones'),
                        selected: _minor,
                        onSelected: (v) {
                          setState(() => _minor = v);
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
                              Positioned.fill(
                                child: LayoutBuilder(builder: (context, box) {
                                  if (!_fitted) {
                                    _fitted = true;
                                    final s = math.min(box.maxWidth, box.maxHeight) / _size;
                                    _view.value = Matrix4.identity()
                                      ..translateByDouble(
                                          (box.maxWidth - _size * s) / 2, (box.maxHeight - _size * s) / 2, 0, 1)
                                      ..scaleByDouble(s, s, 1, 1);
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
                                        onTapUp: (d) => unawaited(_pick(_hit(d.localPosition))),
                                        child: SizedBox(
                                          width: _size,
                                          height: _size,
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
                                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                ),
                              if (_legend && used.isNotEmpty)
                                Positioned(left: Gap.page, top: Gap.s, child: _Legend(kinds: used, nodes: kinds)),
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
                                _chapter = v.round() >= _end ? null : v.round();
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                                label: Text('${r.rel} ${r.name}'),
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
  const _Legend({required this.kinds, required this.nodes});

  final List<LinkKind> kinds;
  final List<String> nodes;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Skin.capsuleOn(context).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final k in nodes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 16, child: Center(child: KindDot(k, size: 9))),
                    const SizedBox(width: 6),
                    Text(kindLabel(k), style: Skin.meta(context, size: 10.5)),
                  ],
                ),
              ),
            if (nodes.isNotEmpty) const SizedBox(height: 4),
            for (final k in kinds)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 16, height: 3, color: linkColour(k)),
                    const SizedBox(width: 6),
                    Text(linkLabel(k), style: Skin.meta(context, size: 10.5)),
                  ],
                ),
              ),
          ],
        ),
      );
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
/// whole book, so the timeline does not move them. Groups wear a halo round
/// their members; links are curved and coloured by what they are, dashed
/// for belonging; the picked node's links lit and the rest dimmed; names on
/// small pills, the most important first, none over another.
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
  }) : super(repaint: view);

  final GraphData data;
  final Map<int, ({double x, double y})> at;
  final int chapter;
  final int? picked;
  final int? second;
  final TransformationController view;
  final bool dark;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = view.value.getMaxScaleOnAxis();
    // A screen pixel, in the canvas's own units: nodes, lines and names are
    // drawn the same size on the screen whatever the zoom, so zooming in
    // spreads a crowd out rather than making it bigger.
    final dp = 1 / scale;
    final px = 1.4 / scale;
    final visible = {
      for (final n in data.nodes)
        if ((n.firstCh ?? 0) <= chapter && at[n.id] != null) n.id: n,
    };
    final edges = [
      for (final e in data.edges)
        if (e.at(chapter) && visible.containsKey(e.a) && visible.containsKey(e.b)) e,
    ];
    final near = <int>{
      if (picked != null) picked!,
      if (second != null) second!,
      for (final e in edges)
        if (e.a == picked || e.b == picked) ...[e.a, e.b],
    };
    Offset o(int id) => Offset(at[id]!.x, at[id]!.y);

    // Groups: a soft halo round each and the members it has now.
    for (final g in visible.values.where((n) => n.kind == 'faction')) {
      final members = [
        for (final e in edges)
          if (e.kind == LinkKind.belongs && (e.a == g.id || e.b == g.id)) e.a == g.id ? e.b : e.a,
      ];
      if (members.isEmpty) continue;
      final pts = [o(g.id), for (final m in members) o(m)];
      final c = pts.reduce((a, b) => a + b) / pts.length.toDouble();
      final r = pts.map((p) => (p - c).distance).reduce(math.max) + 26 * dp;
      canvas.drawCircle(
        c,
        r,
        Paint()..color = kindColour('faction').withValues(alpha: picked == null || near.contains(g.id) ? 0.10 : 0.04),
      );
    }

    for (final e in edges) {
      final lit = picked != null && (e.a == picked || e.b == picked);
      final faded = picked != null && !lit;
      final colour = linkColour(e.kind);
      final p1 = o(e.a), p2 = o(e.b);
      // A gentle curve, bent the same way each time for the same pair.
      final mid = (p1 + p2) / 2;
      final d = p2 - p1;
      final bend = ((e.a + e.b) % 2 == 0 ? 1 : -1) * 0.12;
      final ctrl = mid + Offset(-d.dy, d.dx) * bend;
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, p2.dx, p2.dy);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..color = colour.withValues(
          alpha: faded
              ? 0.06
              : e.kind == LinkKind.shared
                  ? (lit ? 0.55 : 0.18)
                  : (lit ? 0.95 : 0.55),
        )
        ..strokeWidth = (e.kind == LinkKind.shared ? 1.0 + math.min(2.0, e.weight / 4) : 2.0) * (lit ? 1.6 : 1) * px;
      if (e.kind == LinkKind.belongs) {
        _dashed(canvas, path, paint, 8 * px, 6 * px);
      } else {
        canvas.drawPath(path, paint);
      }
      if (lit && e.kind != LinkKind.shared) {
        _pill(canvas, e.label, (ctrl + mid) / 2, 10.5 * dp, colour, strong: false);
      }
    }

    // Nodes, the heaviest last so they sit on top.
    final order = visible.values.toList()..sort((a, b) => a.weight.compareTo(b.weight));
    for (final n in order) {
      final c = o(n.id);
      final r = nodeDp(n.weight) * dp;
      final dim = picked != null && !near.contains(n.id);
      final colour = kindColour(n.kind);
      final isNew = n.firstCh == chapter && chapter > 0;
      if (n.id == picked || n.id == second || n.id == data.focus || isNew) {
        canvas.drawCircle(
          c,
          r + 6 * dp,
          Paint()..color = (isNew ? colour : ink).withValues(alpha: n.id == picked || n.id == second ? 0.35 : 0.15),
        );
      }
      canvas.drawCircle(c, r, Paint()..color = colour.withValues(alpha: dim ? 0.2 : 1));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * px
          ..color = (dark ? Colors.black : Colors.white).withValues(alpha: dim ? 0.2 : 0.7),
      );
    }

    // Names: the important first, each kept only where it overlaps none
    // placed before (the picked, always).
    final placed = <Rect>[];
    int rank(GraphNode n) => n.id == picked || n.id == second ? 2 : (near.contains(n.id) ? 1 : 0);
    final byWeight = visible.values.toList()
      ..sort((a, b) {
        final r = rank(b).compareTo(rank(a));
        return r != 0 ? r : b.weight.compareTo(a.weight);
      });
    for (final n in byWeight) {
      if (picked != null && !near.contains(n.id)) continue;
      final strong = n.id == picked || n.id == second;
      final rect = _pill(
        canvas,
        n.name,
        o(n.id) + Offset(0, (nodeDp(n.weight) + 11) * dp),
        11.5 * dp,
        ink,
        strong: strong,
        avoid: placed,
        force: strong,
      );
      if (rect != null) placed.add(rect);
    }
  }

  /// [text] on a small pill centred at [at]; null (and nothing drawn) when
  /// it would overlap one of [avoid], unless [force].
  Rect? _pill(Canvas canvas, String text, Offset at, double size, Color colour,
      {required bool strong, List<Rect> avoid = const [], bool force = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: strong ? Colors.white : colour,
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
        ..color = strong
            ? const Color(0xFFE07A3A)
            : (dark ? const Color(0xFF101614) : Colors.white).withValues(alpha: 0.82),
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
      old.ink != ink;
}
