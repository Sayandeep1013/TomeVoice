import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A thumb at the right edge of a long list (a web novel's 3,000 chapters):
/// it slides in while the list moves and, held and dragged, carries the
/// list straight there, a bubble beside it naming where ([labelAt], given
/// how far down, 0 to 1). A list a few screens long has none.
class FastScroller extends StatefulWidget {
  const FastScroller({
    super.key,
    required this.controller,
    required this.child,
    this.labelAt,
    this.top = 0,
    this.bottom = 0,
    this.minScreens = 4,
  });

  final ScrollController controller;
  final Widget child;
  final String? Function(double fraction)? labelAt;

  /// Room kept clear of the track: a pinned bar above, a gap below.
  final double top;
  final double bottom;

  /// How many screens long a list must be to have the thumb.
  final double minScreens;

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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(FastScroller old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hide?.cancel();
    super.dispose();
  }

  ScrollPosition? get _position {
    final c = widget.controller;
    return c.hasClients && c.positions.length == 1 ? c.position : null;
  }

  bool get _long {
    final p = _position;
    return p != null &&
        p.hasContentDimensions &&
        p.hasViewportDimension &&
        p.maxScrollExtent > p.viewportDimension * widget.minScreens;
  }

  double get _fraction {
    final p = _position;
    if (p == null || !p.hasContentDimensions || p.maxScrollExtent <= p.minScrollExtent) return 0;
    return ((p.pixels - p.minScrollExtent) / (p.maxScrollExtent - p.minScrollExtent)).clamp(0.0, 1.0);
  }

  void _onScroll() {
    if (!mounted) return;
    if (!_long) {
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
    final p = _position;
    if (p == null) return;
    final f = ((_fromTop + globalY - _fromY) / math.max(1, track - _thumbHeight)).clamp(0.0, 1.0);
    p.jumpTo(p.minScrollExtent + f * (p.maxScrollExtent - p.minScrollExtent));
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
                              },
                              onVerticalDragUpdate: (g) => _dragTo(g.globalPosition.dy, track),
                              onVerticalDragEnd: (_) {
                                setState(() => _dragging = false);
                                _lastLabel = null;
                                _hideLater();
                              },
                              onVerticalDragCancel: () {
                                setState(() => _dragging = false);
                                _hideLater();
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
