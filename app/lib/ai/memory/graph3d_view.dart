import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ledger.dart';
import 'whos_who_screen.dart' show kindColour;

/// The memory graph as a ball to turn: one finger turns it, two pinch it
/// nearer or further; it turns slowly by itself until touched (not at all
/// when the phone asks for less motion). Nearer nodes are bigger and
/// brighter, further ones smaller and fainter; a tap picks the nearest
/// node under the finger. The same graph, chapter and pick as the flat one.
class Graph3dView extends StatefulWidget {
  const Graph3dView({
    super.key,
    required this.data,
    required this.at,
    required this.chapter,
    required this.picked,
    required this.second,
    required this.onPick,
    required this.ink,
    required this.dark,
    required this.linkColour,
  });

  final GraphData data;
  final Map<int, ({double x, double y, double z})> at;
  final int chapter;
  final int? picked;
  final int? second;
  final void Function(int? id) onPick;
  final Color ink;
  final bool dark;
  final Color Function(LinkKind kind) linkColour;

  @override
  State<Graph3dView> createState() => _Graph3dViewState();
}

class _Graph3dViewState extends State<Graph3dView> with SingleTickerProviderStateMixin {
  double _yaw = 0.6, _pitch = -0.35, _zoom = 1;
  double _zoomAtStart = 1;
  bool _spinning = true;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// Where each node was drawn last, for a tap to find.
  List<({int id, Offset at, double r})> _drawn = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_ticker.start());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    // Still once touched, or when the phone asks for less motion: no frames
    // drawn for nothing.
    if (!_spinning || MediaQuery.of(context).disableAnimations) {
      _ticker.stop();
      return;
    }
    if (dt <= 0 || dt > 0.2) return;
    setState(() => _yaw += dt * 0.12);
  }

  void _spin() {
    _spinning = true;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      unawaited(_ticker.start());
    }
  }

  int? _hit(Offset p) {
    int? best;
    var bestD = double.infinity;
    // Nearest first: the list is drawn far to near.
    for (final n in _drawn.reversed) {
      final d = (n.at - p).distance;
      if (d <= n.r + 12 && d < bestD) {
        best = n.id;
        bestD = d;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) {
            _spinning = false;
            _zoomAtStart = _zoom;
          },
          onScaleUpdate: (d) => setState(() {
            _yaw += d.focalPointDelta.dx * 0.008;
            _pitch = (_pitch + d.focalPointDelta.dy * 0.008).clamp(-1.4, 1.4);
            if (d.pointerCount > 1) _zoom = (_zoomAtStart * d.scale).clamp(0.4, 6);
          }),
          onTapUp: (d) => widget.onPick(_hit(d.localPosition)),
          // Twice: back as it was, turning.
          onDoubleTap: () => setState(() {
            _zoom = 1;
            _spin();
          }),
          child: CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _BallPainter(
              view: widget,
              yaw: _yaw,
              pitch: _pitch,
              zoom: _zoom,
              onDrawn: (d) => _drawn = d,
            ),
          ),
        ),
      );
}

class _BallPainter extends CustomPainter {
  _BallPainter({required this.view, required this.yaw, required this.pitch, required this.zoom, required this.onDrawn});

  final Graph3dView view;
  final double yaw, pitch, zoom;
  final void Function(List<({int id, Offset at, double r})>) onDrawn;

  @override
  void paint(Canvas canvas, Size size) {
    final data = view.data;
    final chapter = view.chapter;
    final visible = {
      for (final n in data.nodes)
        if ((n.firstCh ?? 0) <= chapter && view.at[n.id] != null) n.id: n,
    };
    if (visible.isEmpty) {
      onDrawn(const []);
      return;
    }
    // The ball fitted to the screen: its furthest node at the edge.
    final reach = visible.keys.map((id) {
      final p = view.at[id]!;
      return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
    }).fold(1.0, math.max);
    final fit = math.min(size.width, size.height) / 2 * 0.82 / reach * zoom;
    final camera = reach * 3.2;
    final centre = size.center(Offset.zero);
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    // Turned, then seen from in front: where on the screen, how near.
    final proj = <int, ({Offset at, double near})>{};
    for (final id in visible.keys) {
      final p = view.at[id]!;
      final x1 = p.x * cy + p.z * sy, z1 = -p.x * sy + p.z * cy;
      final y2 = p.y * cp - z1 * sp, z2 = p.y * sp + z1 * cp;
      final f = camera / (camera + z2);
      proj[id] = (at: centre + Offset(x1, y2) * fit * f, near: f);
    }
    final nears = proj.values.map((p) => p.near);
    final nearest = nears.reduce(math.max), furthest = nears.reduce(math.min);
    double depth(int id) => nearest == furthest ? 1 : (proj[id]!.near - furthest) / (nearest - furthest);

    final picked = view.picked, second = view.second;
    final edges = [
      for (final e in data.edges)
        if (e.at(chapter) && visible.containsKey(e.a) && visible.containsKey(e.b)) e,
    ];
    final near = <int>{
      if (picked != null) picked,
      if (second != null) second,
      for (final e in edges)
        if (e.a == picked || e.b == picked) ...[e.a, e.b],
    };

    // Links, far ones fainter.
    for (final e in edges) {
      final lit = picked != null && (e.a == picked || e.b == picked);
      final d = (depth(e.a) + depth(e.b)) / 2;
      final alpha = picked != null && !lit ? 0.04 : (e.kind == LinkKind.shared ? 0.10 : 0.30) + d * (lit ? 0.6 : 0.35);
      canvas.drawLine(
        proj[e.a]!.at,
        proj[e.b]!.at,
        Paint()
          ..color = view.linkColour(e.kind).withValues(alpha: alpha.clamp(0, 1))
          ..strokeWidth = (lit ? 2.4 : 1.2) * (0.6 + d * 0.6),
      );
    }

    // Nodes, far to near.
    final order = visible.keys.toList()..sort((a, b) => proj[a]!.near.compareTo(proj[b]!.near));
    final drawn = <({int id, Offset at, double r})>[];
    for (final id in order) {
      final n = visible[id]!;
      final d = depth(id);
      final c = proj[id]!.at;
      final r = nodeDp(n.weight) * proj[id]!.near * math.sqrt(zoom).clamp(0.8, 1.8);
      final dim = picked != null && !near.contains(id);
      final colour = kindColour(n.kind);
      if (id == picked || id == second || id == data.focus) {
        canvas.drawCircle(
            c, r + 5, Paint()..color = view.ink.withValues(alpha: id == data.focus && id != picked ? 0.15 : 0.35));
      }
      // Further away: fainter, as if in a haze.
      canvas.drawCircle(c, r, Paint()..color = colour.withValues(alpha: dim ? 0.15 : 0.35 + d * 0.65));
      drawn.add((id: id, at: c, r: r));
    }
    onDrawn(drawn);

    // Names: the picked and their links, then the nearest and biggest, none
    // over another.
    final placed = <Rect>[];
    final byRank = visible.keys.toList()
      ..sort((a, b) {
        int rank(int id) => id == picked || id == second ? 3 : (near.contains(id) && picked != null ? 2 : 0);
        final r = rank(b).compareTo(rank(a));
        if (r != 0) return r;
        return (depth(b) * 2 + visible[b]!.weight / 50).compareTo(depth(a) * 2 + visible[a]!.weight / 50);
      });
    for (final id in byRank) {
      if (picked != null && !near.contains(id)) continue;
      if (picked == null && depth(id) < 0.35) continue; // the far side: no names
      final strong = id == picked || id == second;
      final n = visible[id]!;
      final r = nodeDp(n.weight) * proj[id]!.near;
      final tp = TextPainter(
        text: TextSpan(
          text: n.name,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
            color: strong ? Colors.white : view.ink.withValues(alpha: 0.55 + depth(id) * 0.45),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 180);
      final at = proj[id]!.at + Offset(0, r + 11);
      final rect = Rect.fromCenter(center: at, width: tp.width + 12, height: tp.height + 5);
      if (!strong && placed.any((p) => p.overlaps(rect))) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()
          ..color = strong
              ? const Color(0xFFE07A3A)
              : (view.dark ? const Color(0xFF101614) : Colors.white).withValues(alpha: 0.8),
      );
      tp.paint(canvas, rect.topLeft + const Offset(6, 2.5));
      placed.add(rect);
    }
  }

  @override
  bool shouldRepaint(_BallPainter old) => old.yaw != yaw || old.pitch != pitch || old.zoom != zoom || old.view != view;
}
