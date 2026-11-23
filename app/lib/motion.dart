import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'theme.dart' show Motion;

/// The give of something pressed: it squashes under the finger (a little
/// wider, a little shorter) and, let go, springs back past where it was and
/// wobbles to rest, like jelly. The spring only ticks while it moves; at rest
/// it costs nothing. With animations removed on the phone it stays still.
///
/// Either told whether it is down ([pressed], from the InkWell inside it),
/// or listening to the finger itself ([Jelly.listen]): a press that turns
/// into a scroll lets go at once, so a list does not wobble as it moves.
class Jelly extends StatefulWidget {
  const Jelly({super.key, required this.pressed, required this.child, this.strength = 1})
      : _listens = false;

  /// Listens to the finger on [child] itself (no InkWell to ask).
  const Jelly.listen({super.key, required this.child, this.strength = 1})
      : pressed = false,
        _listens = true;

  final bool pressed;
  final Widget child;

  /// How much it gives: 1 for a button, less for a wide row (a whole row
  /// squashing as much as a button looks like it broke).
  final double strength;

  final bool _listens;

  @override
  State<Jelly> createState() => _JellyState();
}

/// The spring a press comes back on: light damping, so it overshoots and
/// wobbles a couple of times in about half a second.
const _spring = SpringDescription(mass: 1, stiffness: 520, damping: 15);

class _JellyState extends State<Jelly> with SingleTickerProviderStateMixin {
  /// How far down it is: 1 pressed, 0 at rest, below 0 springing past.
  late final _p = AnimationController.unbounded(vsync: this);
  Offset? _from;
  bool _down = false;

  @override
  void didUpdateWidget(Jelly old) {
    super.didUpdateWidget(old);
    if (!widget._listens && old.pressed != widget.pressed) _set(widget.pressed);
  }

  void _set(bool down) {
    if (down == _down) return;
    _down = down;
    if (Motion.reduced(context)) {
      _p.value = 0;
      return;
    }
    if (down) {
      _p.animateTo(1, duration: const Duration(milliseconds: 90), curve: Curves.easeOutCubic);
    } else {
      _p.animateWith(SpringSimulation(_spring, _p.value, 0, _p.velocity));
    }
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = 0.075 * widget.strength;
    Widget body = AnimatedBuilder(
      animation: _p,
      builder: (context, child) {
        final p = _p.value;
        if (p.abs() < 0.001) return child!;
        // Down: wider and shorter; springing past: taller and narrower.
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(1 + k * 0.35 * p, 1 - k * p, 1),
          child: child,
        );
      },
      child: widget.child,
    );
    if (!widget._listens) return body;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _from = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        // Turned into a scroll or a drag: let go now.
        final from = _from;
        if (from != null && (e.position - from).distance > 12) {
          _from = null;
          _set(false);
        }
      },
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: body,
    );
  }
}

/// A curve that springs: past the end and back, settling, for things that
/// arrive (a screen, a card, a mark). [damping] 1 does not overshoot; lower
/// overshoots more (0.55 about 12%, 0.75 about 3%).
class SpringCurve extends Curve {
  const SpringCurve({this.damping = 0.6, this.cycles = 1.6});

  final double damping;

  /// How many swings fit in the curve's time.
  final double cycles;

  @override
  double transformInternal(double t) {
    final w = 2 * math.pi * cycles;
    final z = damping;
    if (z >= 1) return 1 - math.exp(-w * t) * (1 + w * t);
    final wd = w * math.sqrt(1 - z * z);
    return 1 - math.exp(-z * w * t) * (math.cos(wd * t) + z * w / wd * math.sin(wd * t));
  }
}
