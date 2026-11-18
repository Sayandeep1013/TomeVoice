import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui.dart';
import '../talk/name_card.dart';
import 'ledger.dart';
import 'whos_who_screen.dart' show kindColour, kindLabel;

/// The memory graph: the book's people, places and things as a web, each
/// node sized by how often it appears, joined by the relations the book
/// states (solid) and the events they shared (faint); as it stood at any
/// chapter (the slider, kept to the spoiler line); a tap picks a node and
/// lights its links, and Centre on it shows its own web.
class MemoryGraphScreen extends StatefulWidget {
  const MemoryGraphScreen({super.key, required this.bookTitle, required this.memoryPath, this.line});

  final String bookTitle;
  final String memoryPath;
  final int? line;

  @override
  State<MemoryGraphScreen> createState() => _MemoryGraphScreenState();
}

class _MemoryGraphScreenState extends State<MemoryGraphScreen> {
  static const _size = 1000.0;

  GraphData? _data;
  Map<int, ({double x, double y})> _at = const {};
  int? _focus;
  int? _picked;
  int? _chapter;
  double? _sliding;
  final Set<String> _kinds = {};
  bool _loading = true;
  int _asked = 0;
  final _view = TransformationController();

  /// The web is fitted to the screen once drawn (and again for a new centre).
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final n = ++_asked;
    setState(() => _loading = true);
    final r = await _drawn(widget.memoryPath, _chapter ?? widget.line, _focus, {..._kinds});
    if (!mounted || n != _asked) return;
    setState(() {
      _data = r.data;
      _at = r.at;
      _loading = false;
      if (_picked != null && !_at.containsKey(_picked)) _picked = null;
    });
  }

  /// The furthest chapter the slider goes to: the line, or all there is.
  int get _end {
    final last = _data?.lastCh ?? 0;
    final line = widget.line;
    return line == null ? last : math.min(line, last);
  }

  int? _hit(Offset p) {
    final data = _data;
    if (data == null) return null;
    int? best;
    var bestD = double.infinity;
    for (final n in data.nodes) {
      final at = _at[n.id];
      if (at == null) continue;
      final d = (Offset(at.x, at.y) - p).distance;
      final r = nodeRadius(n.weight) + 12;
      if (d <= r && d < bestD) {
        best = n.id;
        bestD = d;
      }
    }
    return best;
  }

  Future<void> _openCard(int id) async {
    final at = _chapter ?? widget.line;
    final card = await cardOff(widget.memoryPath, id, at);
    if (card == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NameCardSheet(card: card, line: at),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final picked = data?.nodes.where((n) => n.id == _picked).firstOrNull;
    final kinds = {for (final n in data?.nodes ?? const <GraphNode>[]) n.kind}.toList()..sort();
    final shownCh = _sliding?.round() ?? _chapter ?? _end;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Memory graph', onBack: () => Navigator.of(context).maybePop()),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.s),
                child: Text(
                  '${widget.bookTitle} · ${data == null ? '' : '${data.nodes.length} shown'}'
                  '${_focus == null ? '' : ' round one'}',
                  style: Skin.meta(context),
                ),
              ),
              if (kinds.length > 1 || _kinds.isNotEmpty)
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                    children: [
                      for (final k in {...kinds, ..._kinds})
                        Padding(
                          padding: const EdgeInsets.only(right: Gap.s),
                          child: FilterChip(
                            avatar: CircleAvatar(backgroundColor: kindColour(k), radius: 6),
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
                                      ..translateByDouble((box.maxWidth - _size * s) / 2, (box.maxHeight - _size * s) / 2, 0, 1)
                                      ..scaleByDouble(s, s, 1, 1);
                                  }
                                  return ClipRect(
                                  child: InteractiveViewer(
                                    transformationController: _view,
                                    constrained: false,
                                    boundaryMargin: const EdgeInsets.all(400),
                                    minScale: 0.25,
                                    maxScale: 5,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTapUp: (d) => setState(() => _picked = _hit(d.localPosition)),
                                      child: SizedBox(
                                        width: _size,
                                        height: _size,
                                        child: CustomPaint(
                                          painter: GraphPainter(
                                            data: data,
                                            at: _at,
                                            picked: _picked,
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
                            ],
                          ),
              ),
              if (picked != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, Gap.s, Gap.page, 0),
                  child: Row(
                    children: [
                      CircleAvatar(backgroundColor: kindColour(picked.kind), radius: 7),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Text(
                          '${picked.name} · ${kindLabel(picked.kind).toLowerCase()} · in ${picked.weight} chapters',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.ui(size: 14.5, weight: FontWeight.w600, color: Skin.inkOn(context)),
                        ),
                      ),
                      TextButton(onPressed: () => unawaited(_openCard(picked.id)), child: const Text('Card')),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _focus = picked.id;
                            _fitted = false;
                          });
                          unawaited(_load());
                        },
                        child: const Text('Centre on'),
                      ),
                    ],
                  ),
                ),
              if (_focus != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _focus = null;
                          _fitted = false;
                        });
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.zoom_out_map_rounded, size: 18),
                      label: const Text('The whole web'),
                    ),
                  ),
                ),
              if (_end > 0)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
                    child: Row(
                      children: [
                        Text('Ch ${shownCh + 1}', style: Skin.meta(context)),
                        Expanded(
                          child: Slider(
                            value: (_sliding ?? (_chapter ?? _end).toDouble()).clamp(0, _end.toDouble()),
                            max: _end.toDouble(),
                            label: 'As of chapter ${shownCh + 1}',
                            onChanged: (v) => setState(() => _sliding = v),
                            onChangeEnd: (v) {
                              setState(() {
                                _chapter = v.round() >= _end ? null : v.round();
                                _sliding = null;
                              });
                              unawaited(_load());
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
}

/// The graph laid out off the UI thread's isolate, from a function of its
/// own (a closure made in the State's method would carry the State).
Future<({GraphData data, Map<int, ({double x, double y})> at})> _drawn(
        String path, int? at, int? focus, Set<String> kinds) =>
    Isolate.run(() => graphAndLayout(path, at: at, focus: focus, kinds: kinds.isEmpty ? null : kinds));

/// A node's size: by how many chapters it is in.
double nodeRadius(int weight) => math.min(30, 5 + math.sqrt(weight.toDouble()) * 1.8);

/// Draws the graph: links under nodes, the picked node's links lit and the
/// rest dimmed; names for the larger nodes, and for all as the reader zooms
/// in (redrawn as the view moves).
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.data,
    required this.at,
    required this.picked,
    required this.view,
    required this.dark,
    required this.ink,
  }) : super(repaint: view);

  final GraphData data;
  final Map<int, ({double x, double y})> at;
  final int? picked;
  final TransformationController view;
  final bool dark;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = view.value.getMaxScaleOnAxis();
    final near = <int>{
      if (picked != null) picked!,
      for (final e in data.edges)
        if (e.a == picked || e.b == picked) ...[e.a, e.b],
    };
    Offset o(int id) => Offset(at[id]!.x, at[id]!.y);
    final line = Paint()..style = PaintingStyle.stroke;
    for (final e in data.edges) {
      if (at[e.a] == null || at[e.b] == null) continue;
      final lit = picked != null && (e.a == picked || e.b == picked);
      final faded = picked != null && !lit;
      line
        ..color = ink.withValues(alpha: faded ? 0.04 : (e.related ? (lit ? 0.7 : 0.28) : (lit ? 0.45 : 0.1)))
        ..strokeWidth = (e.related ? 1.6 : 1.0) * (lit ? 1.8 : 1) / math.sqrt(scale);
      canvas.drawLine(o(e.a), o(e.b), line);
      if (lit && e.related) _label(canvas, e.label, (o(e.a) + o(e.b)) / 2, 10 / math.sqrt(scale), ink.withValues(alpha: 0.75));
    }
    final weights = data.nodes.map((n) => n.weight).toList()..sort();
    final labelled = weights.isEmpty ? 0 : weights[math.max(0, weights.length - 25)];
    for (final n in data.nodes) {
      final p = at[n.id];
      if (p == null) continue;
      final c = Offset(p.x, p.y);
      final r = nodeRadius(n.weight);
      final dim = picked != null && !near.contains(n.id);
      final colour = kindColour(n.kind);
      canvas.drawCircle(c, r, Paint()..color = colour.withValues(alpha: dim ? 0.18 : 0.9));
      if (n.id == picked || n.id == data.focus) {
        canvas.drawCircle(
          c,
          r + 4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 / math.sqrt(scale)
            ..color = ink,
        );
      }
      final show = n.id == picked || near.contains(n.id) || n.weight >= labelled || scale > 1.6;
      if (show && !dim) _label(canvas, n.name, c + Offset(0, r + 9), 12.5 / math.sqrt(scale), ink);
    }
  }

  void _label(Canvas canvas, String text, Offset at, double size, Color colour) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: colour,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.9), blurRadius: 3)],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(GraphPainter old) =>
      old.data != data || old.at != at || old.picked != picked || old.dark != dark || old.ink != ink;
}
