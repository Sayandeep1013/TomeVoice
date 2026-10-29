import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// What a [FastScroller] moves: it says when the list moves, how far down
/// it is (0 to 1), and whether it is long enough to want a thumb.
abstract class FastScrollTarget implements Listenable {
  bool get long;
  double get fraction;
  void jumpTo(double fraction);

  /// Whether the last move was the reader's own (a list that also scrolls
  /// itself, following the voice, shows no thumb for that).
  bool get byHand => true;
}

/// A list with a [ScrollController]: long once it is [minScreens] screens.
class ControllerScrollTarget extends FastScrollTarget {
  ControllerScrollTarget(this.controller, {this.minScreens = 2.5});

  final ScrollController controller;
  final double minScreens;

  ScrollPosition? get _position => controller.hasClients && controller.positions.length == 1 ? controller.position : null;

  @override
  bool get long {
    final p = _position;
    return p != null &&
        p.hasContentDimensions &&
        p.hasViewportDimension &&
        p.maxScrollExtent > p.viewportDimension * minScreens;
  }

  @override
  double get fraction {
    final p = _position;
    if (p == null || !p.hasContentDimensions || p.maxScrollExtent <= p.minScrollExtent) return 0;
    return ((p.pixels - p.minScrollExtent) / (p.maxScrollExtent - p.minScrollExtent)).clamp(0.0, 1.0);
  }

  @override
  void jumpTo(double fraction) {
    final p = _position;
    if (p != null) p.jumpTo(p.minScrollExtent + fraction * (p.maxScrollExtent - p.minScrollExtent));
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => controller.removeListener(listener);
}

/// A thumb at the right edge of a long list (a web novel's 3,000 chapters,
/// a long book's text): it slides in while the list moves and, held and
/// dragged, carries the list straight there, a bubble beside it naming
/// where ([labelAt], given how far down, 0 to 1). A short list has none.
class FastScroller extends StatefulWidget {
  FastScroller({
    super.key,
    ScrollController? controller,
    FastScrollTarget? target,
    required this.child,
    this.labelAt,
    this.top = 0,
    this.bottom = 0,
    this.onDrag,
  })  : assert((controller == null) != (target == null)),
        target = target ?? ControllerScrollTarget(controller!);

  final FastScrollTarget target;
  final Widget child;
  final String? Function(double fraction)? labelAt;

  /// Room kept clear of the track: a pinned bar above, a gap below.
  final double top;
  final double bottom;

  /// The thumb taken (true) and let go (false): a list that tells a look
  /// around from reading by its own scrolling hears of these jumps here.
  final void Function(bool dragging)? onDrag;

  @override
  State<FastScroller> createState() => _FastScrollerState();
}

class _FastScrollerState extends State<FastScroller> {
  static const _thumbHeight = 52.0;
  static const _hitWidth = 44.0;

  bool _shown = false;
  bool _dragging = false;
  Timer? _hide;

  /// The thumb's top and the finger when the drag began: the thumb moves
  /// by as much as the finger has since.
  double _fromTop = 0;
  double _fromY = 0;
  String? _lastLabel;

  /// The listenable the thumb is following (a new [ControllerScrollTarget]
  /// is made on each build, around the same controller).
  late FastScrollTarget _target = widget.target;

  @override
  void initState() {
    super.initState();
    _target.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(FastScroller old) {
    super.didUpdateWidget(old);
    _target.removeListener(_onScroll);
    _target = widget.target;
    _target.addListener(_onScroll);
  }

  @override
  void dispose() {
    _target.removeListener(_onScroll);
    _hide?.cancel();
    super.dispose();
  }

  double get _fraction => _target.fraction;

  void _onScroll() {
    if (!mounted) return;
    if (!_target.long || (!_dragging && !_target.byHand)) {
      if (_shown) setState(() => _shown = false);
      return;
    }
    setState(() => _shown = true);
    if (!_dragging) _hideLater();
  }

  void _hideLater() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && !_dragging) setState(() => _shown = false);
    });
  }

  void _dragTo(double globalY, double track) {
    final f = ((_fromTop + globalY - _fromY) / math.max(1, track - _thumbHeight)).clamp(0.0, 1.0);
    _target.jumpTo(f);
    // A tick as the bubble names somewhere new, so a drag is felt.
    final label = widget.labelAt?.call(f);
    if (label != _lastLabel) {
      _lastLabel = label;
      unawaited(HapticFeedback.selectionClick());
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Skin.accentOf(context);
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: widget.top,
          bottom: widget.bottom,
          right: 0,
          width: 240,
          child: LayoutBuilder(
            builder: (context, box) {
              final track = box.maxHeight;
              final y = _fraction * math.max(0, track - _thumbHeight);
              final label = _dragging ? widget.labelAt?.call(_fraction) : null;
              final d = Motion.of(context, Motion.standard);
              return IgnorePointer(
                ignoring: !_shown,
                child: AnimatedOpacity(
                  opacity: _shown ? 1 : 0,
                  duration: d,
                  curve: Motion.out,
                  child: AnimatedSlide(
                    offset: _shown ? Offset.zero : const Offset(0.08, 0),
                    duration: d,
                    curve: Motion.out,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (label != null)
                          Positioned(
                            right: _hitWidth + 6,
                            top: y + _thumbHeight / 2 - 22,
                            child: _bubble(context, label),
                          ),
                        Positioned(
                          right: 0,
                          top: y,
                          width: _hitWidth,
                          height: _thumbHeight,
                          child: Semantics(
                            label: 'Fast scroll',
                            slider: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragStart: (g) {
                                _hide?.cancel();
                                _fromTop = y;
                                _fromY = g.globalPosition.dy;
                                setState(() => _dragging = true);
                                widget.onDrag?.call(true);
                              },
                              onVerticalDragUpdate: (g) => _dragTo(g.globalPosition.dy, track),
                              onVerticalDragEnd: (_) {
                                setState(() => _dragging = false);
                                _lastLabel = null;
                                _hideLater();
                                widget.onDrag?.call(false);
                              },
                              onVerticalDragCancel: () {
                                setState(() => _dragging = false);
                                _hideLater();
                                widget.onDrag?.call(false);
                              },
                              child: Center(
                                child: AnimatedContainer(
                                  duration: Motion.of(context, Motion.quick),
                                  curve: Motion.out,
                                  width: _dragging ? 10 : 6,
                                  height: _thumbHeight - 8,
                                  decoration: BoxDecoration(
                                    color: _dragging ? accent : accent.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(Radii.pill),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _bubble(BuildContext context, String label) => Material(
        color: Skin.darkOn(context),
        elevation: 4,
        borderRadius: BorderRadius.circular(Radii.row),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, maxWidth: 180),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Skin.ui(size: 15, weight: FontWeight.w700, color: Skin.onDark(context)).copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      );
}
