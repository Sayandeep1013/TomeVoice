import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Turns [PageCurl]'s leaves from outside.
class CurlController {
  _PageCurlState? _state;

  int get index => _state?._index ?? 0;

  /// Turn to [index]: one leaf on or back is turned over, further is gone
  /// to at once.
  void turnTo(int index, {bool animate = true}) => _state?._turnTo(index, animate: animate);

  /// A leaf on (1) or back (-1), as by the reader's hand (a key).
  void step(int delta) => _state?._step(delta, byHand: true);
}

/// A book's leaves, turned over like paper: the corner follows the finger,
/// the page folds along the line between where the corner was and where it
/// is, and the folded part shows its back. With [spread] two leaves lie
/// open side by side and the right one turns over the spine, its back
/// becoming the next left page, as in a printed book.
///
/// The fold is flat (a crease, not a cylinder), drawn with the leaves' own
/// widgets clipped and mirrored rather than pictures of them, so the text
/// stays sharp and nothing is rendered twice while no page is turning.
class PageCurl extends StatefulWidget {
  const PageCurl({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.initialIndex,
    required this.leaf,
    required this.paper,
    required this.onSettled,
    this.spread = false,
    this.crease,
    this.onTapMiddle,
    this.tapToTurn = true,
  });

  final CurlController controller;
  final int itemCount;
  final int initialIndex;

  /// Leaf [side] (0 left or alone, 1 right) of item [index].
  final Widget Function(BuildContext context, int index, int side) leaf;

  /// The page's paper, under every leaf (a turning leaf must hide the one
  /// beneath it).
  final BoxDecoration paper;

  /// An item came to rest; [byHand] when the reader turned to it.
  final void Function(int index, {required bool byHand}) onSettled;
  final bool spread;

  /// The shade of the gutter between two open pages (the paper's own ink,
  /// or black on a dark page); none in a single page.
  final Color? crease;
  final VoidCallback? onTapMiddle;
  final bool tapToTurn;

  @override
  State<PageCurl> createState() => _PageCurlState();
}

/// A turn in progress: leaf [from] turning over onto [from] + 1, at [q]
/// (0 lying flat, 1 turned over). A turn back is the turn on from the item
/// before, run the other way.
class _Turn {
  _Turn(this.from, this.top);
  final int from;

  /// Held by its top corner (a drag that began in the upper half).
  final bool top;
}

class _PageCurlState extends State<PageCurl> with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;
  _Turn? _turn;
  double _q = 0;

  /// The corner's offset from its path, while a finger holds it.
  Offset _lift = Offset.zero;
  bool _byHand = false;

  late final _anim = AnimationController(vsync: this)..addListener(_onTick);
  double _animFrom = 0, _animTo = 0;
  Offset _liftFrom = Offset.zero;
  bool _arc = false;

  Offset? _dragStart;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void didUpdateWidget(PageCurl old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller._state == this) old.controller._state = null;
      widget.controller._state = this;
    }
    if (_index >= widget.itemCount) _index = math.max(0, widget.itemCount - 1);
  }

  @override
  void dispose() {
    if (widget.controller._state == this) widget.controller._state = null;
    _anim.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- turning

  void _turnTo(int target, {required bool animate}) {
    target = target.clamp(0, widget.itemCount - 1);
    if (_turn != null) return;
    if (target == _index) return;
    final d = Motion.of(context, _duration);
    if (!animate || d == Duration.zero || (target - _index).abs() != 1) {
      setState(() => _index = target);
      widget.onSettled(_index, byHand: false);
      return;
    }
    _start(forward: target > _index, top: false, byHand: false);
    _run(to: target > _index ? 1 : 0, arc: true);
  }

  /// A turn on or back by a tap, a key or the reader's hand.
  void _step(int delta, {required bool byHand}) {
    if (_turn != null) return;
    final target = _index + delta;
    if (target < 0 || target >= widget.itemCount) return;
    final d = Motion.of(context, _duration);
    if (d == Duration.zero) {
      setState(() => _index = target);
      widget.onSettled(_index, byHand: byHand);
      return;
    }
    _start(forward: delta > 0, top: false, byHand: byHand);
    _run(to: delta > 0 ? 1 : 0, arc: true);
  }

  static const _duration = Duration(milliseconds: 560);

  void _start({required bool forward, required bool top, required bool byHand}) {
    _byHand = byHand;
    _turn = _Turn(forward ? _index : _index - 1, top);
    _q = forward ? 0 : 1;
    _lift = Offset.zero;
    _arc = false;
  }

  /// Carry the turn on to [to] (1 turned over, 0 back as it was).
  void _run({required double to, required bool arc}) {
    _animFrom = _q;
    _animTo = to;
    _liftFrom = _lift;
    _arc = arc;
    final distance = (to - _q).abs();
    final ms = (_duration.inMilliseconds * (arc ? 1 : math.max(0.35, distance))).round();
    _anim
      ..duration = Duration(milliseconds: ms)
      ..value = 0;
    _anim.animateTo(1, curve: arc ? Curves.easeInOutCubic : Curves.easeOutCubic).whenComplete(_landed);
  }

  void _onTick() {
    final t = _anim.value;
    setState(() {
      _q = _animFrom + (_animTo - _animFrom) * t;
      _lift = Offset.lerp(_liftFrom, Offset.zero, t)!;
    });
  }

  void _landed() {
    final turn = _turn;
    if (turn == null || !mounted) return;
    final done = _animTo >= 0.5;
    setState(() {
      _index = done ? turn.from + 1 : turn.from;
      _turn = null;
      _q = 0;
      _lift = Offset.zero;
    });
    widget.onSettled(_index, byHand: _byHand);
  }

  // -------------------------------------------------------------- gestures

  void _onTapUp(TapUpDetails d) {
    if (_turn != null) return;
    final x = d.localPosition.dx / _size.width;
    if (widget.tapToTurn && x < 0.28) {
      _step(-1, byHand: true);
    } else if (widget.tapToTurn && x > 0.72) {
      _step(1, byHand: true);
    } else {
      widget.onTapMiddle?.call();
    }
  }

  void _onDragStart(DragStartDetails d) {
    // A page already turning finishes its turn first.
    _dragStart = _turn == null ? d.localPosition : null;
    _dragQ0 = null;
  }

  double? _dragQ0;

  void _onDragUpdate(DragUpdateDetails d) {
    final start = _dragStart;
    if (start == null) return;
    final dx = d.localPosition.dx - start.dx;
    if (_turn == null) {
      if (dx.abs() < 4) return;
      final forward = dx < 0;
      final target = _index + (forward ? 1 : -1);
      if (target < 0 || target >= widget.itemCount) {
        _dragStart = null;
        return;
      }
      _start(forward: forward, top: start.dy < _size.height / 2, byHand: true);
      _dragQ0 = forward ? 0 : 1;
    }
    final width = widget.spread ? _size.width / 2 : _size.width;
    // The corner keeps up with the finger: across a leaf's width (and a
    // little more on a single page, whose leaf turns past the screen's edge)
    // is a whole turn.
    final span = widget.spread ? width : width * 0.9;
    final q = (_dragQ0! - dx / span).clamp(0.0, 1.0);
    setState(() {
      _q = q;
      _lift = Offset(0, (d.localPosition.dy - start.dy) * 0.6);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_turn == null || _dragStart == null) {
      _dragStart = null;
      return;
    }
    final v = d.velocity.pixelsPerSecond.dx;
    // A flick decides; otherwise, past halfway.
    final on = v.abs() > 300 ? v < 0 : _q > 0.5;
    _dragStart = null;
    _run(to: on ? 1 : 0, arc: false);
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          _size = Size(box.maxWidth, box.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: ClipRect(child: _turn == null ? _still(context) : _turning(context, _turn!)),
          );
        },
      );

  Widget _paperLeaf(BuildContext context, int index, int side) => RepaintBoundary(
        child: DecoratedBox(
          decoration: widget.paper,
          child: widget.leaf(context, index, side),
        ),
      );

  Widget _still(BuildContext context) {
    if (!widget.spread) return _paperLeaf(context, _index, 0);
    return Stack(
      children: [
        Row(
          children: [
            Expanded(child: _paperLeaf(context, _index, 0)),
            Expanded(child: _paperLeaf(context, _index, 1)),
          ],
        ),
        _creaseAt(_size.width / 2),
      ],
    );
  }

  /// The gutter where two pages meet: a shadow into the binding, a little
  /// light on the paper's rise either side. Over the flat pages, under a
  /// leaf turning over it.
  Widget _creaseAt(double spine) {
    final c = widget.crease;
    if (c == null) return const SizedBox.shrink();
    return Positioned(
      left: spine - _creaseHalf,
      width: _creaseHalf * 2,
      top: 0,
      bottom: 0,
      child: IgnorePointer(child: CustomPaint(painter: Crease(c))),
    );
  }

  static const _creaseHalf = 34.0;

  Widget _turning(BuildContext context, _Turn turn) {
    final w = _size.width, h = _size.height;
    final spread = widget.spread;
    // The turning leaf, its hinge (the spine, or a single page's left edge)
    // and the corner held.
    final leaf = spread ? Rect.fromLTWH(w / 2, 0, w / 2, h) : Offset.zero & _size;
    final spine = leaf.left;
    final corner = Offset(leaf.right, turn.top ? 0 : h);
    final over = Offset(2 * spine - corner.dx, corner.dy);
    var p = Offset.lerp(corner, over, _q)!;
    if (_arc) {
      // Lifted from the bottom corner in an arc, as a hand turns a page.
      p += Offset(0, (turn.top ? 1 : -1) * h * 0.14 * math.sin(math.pi * _q));
    }
    p += _lift;
    // Paper does not stretch: the corner stays within a leaf's width of the
    // hinge beside it, and within the leaf's diagonal of the other end.
    final hinge = Offset(spine, corner.dy);
    final far = Offset(spine, h - corner.dy);
    final lw = leaf.width;
    if ((p - hinge).distance > lw) p = hinge + (p - hinge) / (p - hinge).distance * lw;
    final diag = math.sqrt(lw * lw + h * h);
    if ((p - far).distance > diag) p = far + (p - far) / (p - far).distance * diag;

    final under = <Widget>[
      // What lies beneath: the next item's leaves where this one lifts.
      if (spread) ...[
        Positioned.fromRect(rect: Rect.fromLTWH(0, 0, w / 2, h), child: _paperLeaf(context, turn.from, 0)),
        Positioned.fromRect(rect: leaf, child: _paperLeaf(context, turn.from + 1, 1)),
      ] else
        Positioned.fill(child: _paperLeaf(context, turn.from + 1, 0)),
    ];
    final n = corner - p;
    if (n.distance < 1) {
      return Stack(children: [...under, Positioned.fromRect(rect: leaf, child: _frontOf(context, turn))]);
    }
    final m = (corner + p) / 2;
    final u = n / n.distance;
    final rectPoly = [leaf.topLeft, leaf.topRight, leaf.bottomRight, leaf.bottomLeft];
    final front = _clip(rectPoly, m, u, keepBehind: true);
    final lifted = _clip(rectPoly, m, u, keepBehind: false);
    final reflect = _reflection(m, u);
    final flap = [for (final x in lifted) MatrixUtils.transformPoint(reflect, x)];
    // The back of the leaf: the next left page in a spread (it lands
    // there); on a single page its own print showing faintly through.
    final Matrix4 backTransform;
    final Widget back;
    final Rect backRect;
    if (spread) {
      backTransform = reflect.multiplied(_mirrorX(spine));
      back = _paperLeaf(context, turn.from + 1, 0);
      backRect = Rect.fromLTWH(0, 0, w / 2, h);
    } else {
      backTransform = reflect;
      back = Stack(
        fit: StackFit.expand,
        children: [
          _paperLeaf(context, turn.from, 0),
          ColoredBox(color: _tone(widget.paper).withValues(alpha: 0.86)),
        ],
      );
      backRect = leaf;
    }
    final shade = _q.clamp(0.0, 1.0);
    return Stack(
      children: [
        ...under,
        if (spread) _creaseAt(spine),
        // The shadow the lifted leaf casts on the page beneath, along the fold.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _FoldShadow(region: lifted, m: m, u: u, strength: 1 - shade * 0.6)),
          ),
        ),
        // The part of the leaf still lying flat.
        Positioned.fill(
          child: ClipPath(
            clipper: _PolygonClip(front),
            child: Stack(children: [Positioned.fromRect(rect: leaf, child: _frontOf(context, turn))]),
          ),
        ),
        // The folded part, its back up, with its shadow on what it covers.
        Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _FlapShadow(flap))),
        ),
        Positioned.fill(
          child: ClipPath(
            clipper: _PolygonClip(flap),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Transform(
                    transform: backTransform,
                    child: Stack(children: [Positioned.fromRect(rect: backRect, child: back)]),
                  ),
                ),
                Positioned.fill(child: CustomPaint(painter: _FlapShade(m: m, u: u, flap: flap))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _frontOf(BuildContext context, _Turn turn) => _paperLeaf(context, turn.from, widget.spread ? 1 : 0);
}

/// The binding between two open pages, in [shade]: darkest at the spine,
/// with the paper catching the light as it rises either side.
class Crease extends CustomPainter {
  Crease(this.shade);
  final Color shade;

  @override
  void paint(Canvas canvas, Size size) {
    final light = shade.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, 0),
          [
            shade.withValues(alpha: 0),
            light.withValues(alpha: 0.035),
            shade.withValues(alpha: 0.10),
            shade.withValues(alpha: 0.34),
            shade.withValues(alpha: 0.10),
            light.withValues(alpha: 0.035),
            shade.withValues(alpha: 0),
          ],
          const [0, 0.22, 0.40, 0.5, 0.60, 0.78, 1],
        ),
    );
    // The fold itself: a hairline.
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      Paint()
        ..color = shade.withValues(alpha: 0.28)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(Crease old) => old.shade != shade;
}

/// The paper's colour: its own, or the first of its gradient's.
Color _tone(BoxDecoration paper) => paper.color ?? paper.gradient?.colors.first ?? Colors.white;

/// [poly] clipped to one side of the line through [m] with normal [u]:
/// behind it (towards the hinge) or beyond (towards the corner).
List<Offset> _clip(List<Offset> poly, Offset m, Offset u, {required bool keepBehind}) {
  double side(Offset x) => ((x - m).dx * u.dx + (x - m).dy * u.dy) * (keepBehind ? -1 : 1);
  final out = <Offset>[];
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    final sa = side(a), sb = side(b);
    if (sa >= 0) out.add(a);
    if ((sa >= 0) != (sb >= 0)) out.add(Offset.lerp(a, b, sa / (sa - sb))!);
  }
  return out;
}

/// Reflection across the line through [m] with unit normal [u].
Matrix4 _reflection(Offset m, Offset u) {
  final a = 1 - 2 * u.dx * u.dx, b = -2 * u.dx * u.dy, d = 1 - 2 * u.dy * u.dy;
  final k = 2 * (m.dx * u.dx + m.dy * u.dy);
  return Matrix4(a, b, 0, 0, b, d, 0, 0, 0, 0, 1, 0, k * u.dx, k * u.dy, 0, 1);
}

/// Mirror across the vertical line x = [s] (the spine).
Matrix4 _mirrorX(double s) => Matrix4(-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2 * s, 0, 0, 1);

Path _path(List<Offset> poly) => Path()..addPolygon(poly, true);

class _PolygonClip extends CustomClipper<Path> {
  _PolygonClip(this.poly);
  final List<Offset> poly;

  @override
  Path getClip(Size size) => poly.length < 3 ? Path() : _path(poly);

  @override
  bool shouldReclip(_PolygonClip old) => true;
}

/// Shadow on the page beneath, darkest at the fold.
class _FoldShadow extends CustomPainter {
  _FoldShadow({required this.region, required this.m, required this.u, required this.strength});
  final List<Offset> region;
  final Offset m;
  final Offset u;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (region.length < 3) return;
    canvas.save();
    canvas.clipPath(_path(region));
    const reach = 48.0;
    canvas.drawPaint(Paint()
      ..shader = ui.Gradient.linear(
        m,
        m + u * reach,
        [Colors.black.withValues(alpha: 0.30 * strength), Colors.black.withValues(alpha: 0)],
      ));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FoldShadow old) => true;
}

/// The folded part's shadow on what it covers.
class _FlapShadow extends CustomPainter {
  _FlapShadow(this.flap);
  final List<Offset> flap;

  @override
  void paint(Canvas canvas, Size size) {
    if (flap.length < 3) return;
    canvas.drawShadow(_path(flap), Colors.black, 8, false);
  }

  @override
  bool shouldRepaint(_FlapShadow old) => true;
}

/// Light across the folded part: the crease darker, the turned edge lit.
class _FlapShade extends CustomPainter {
  _FlapShade({required this.m, required this.u, required this.flap});
  final Offset m;
  final Offset u;
  final List<Offset> flap;

  @override
  void paint(Canvas canvas, Size size) {
    if (flap.length < 3) return;
    // The flap lies behind the fold line (on the hinge's side).
    final into = -u;
    const reach = 120.0;
    canvas.drawPaint(Paint()
      ..shader = ui.Gradient.linear(
        m,
        m + into * reach,
        [
          Colors.black.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.06),
          Colors.black.withValues(alpha: 0.04),
        ],
        const [0, 0.35, 1],
      ));
  }

  @override
  bool shouldRepaint(_FlapShade old) => true;
}
