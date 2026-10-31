import 'package:flutter/material.dart';

import 'prefs.dart';
import 'theme.dart';

/// Auto-scroll's speeds on the scroll, in lines a minute: each step a tenth
/// or so on from the last.
const autoScrollSpeeds = [6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 27, 30, 33, 36, 40, 45, 50, 55, 60, 70, 80, 90];

/// How long it leaves each page in pages, in seconds.
const autoPageWaits = [5, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 75, 90, 120, 150, 180];

/// "30 s", "1 min", "1 min 30 s".
String waitLabel(int seconds) {
  if (seconds < 60) return '$seconds s';
  final m = seconds ~/ 60, s = seconds % 60;
  return s == 0 ? '$m min' : '$m min $s s';
}

/// Auto-scroll: reading on without the voice, the page moving by itself. On
/// the scroll, a steady scroll at [lines] a minute; in pages, a page turned
/// every [seconds]. The book's page moves it (and stops it at a chapter's
/// end); the Read tab starts it, and its pill over the page holds it, makes
/// it faster or slower, and stops it. It and the voice never run together:
/// starting it stops the voice, and Play stops it.
class AutoScroll extends ChangeNotifier {
  AutoScroll(this._prefs);

  /// The reader's settings, where its speeds are kept: read each time, as
  /// the page loads its own after it opens.
  final ListeningPrefs Function() _prefs;

  /// Started, and not stopped since (held a moment, perhaps).
  bool get on => _on;
  bool _on = false;

  /// Held until the reader goes on: the pill's pause, or with TalkBack on,
  /// whatever stopped it a moment (it never starts again by itself then).
  bool get held => _held;
  bool _held = false;

  int get lines => _prefs().autoScrollLines;
  int get seconds => _prefs().autoPageSeconds;

  void start() {
    _on = true;
    _held = false;
    notifyListeners();
  }

  void stop() {
    if (!_on) return;
    _on = false;
    _held = false;
    notifyListeners();
  }

  void hold() {
    if (!_on || _held) return;
    _held = true;
    notifyListeners();
  }

  void goOn() {
    if (!_on || !_held) return;
    _held = false;
    notifyListeners();
  }

  /// "24 lines a minute", or in [pages] "A page every 30 s".
  String label({required bool pages}) => pages ? 'A page every ${waitLabel(seconds)}' : '$lines lines a minute';

  /// A step faster: more lines a minute, or in [pages] less time on each.
  bool canSpeedUp({required bool pages}) =>
      pages ? _nearest(autoPageWaits, seconds) > 0 : _nearest(autoScrollSpeeds, lines) < autoScrollSpeeds.length - 1;
  bool canSlowDown({required bool pages}) =>
      pages ? _nearest(autoPageWaits, seconds) < autoPageWaits.length - 1 : _nearest(autoScrollSpeeds, lines) > 0;

  void speedUp({required bool pages}) => _step(1, pages: pages);
  void slowDown({required bool pages}) => _step(-1, pages: pages);

  void _step(int faster, {required bool pages}) {
    final p = _prefs();
    if (pages) {
      final i = (_nearest(autoPageWaits, p.autoPageSeconds) - faster).clamp(0, autoPageWaits.length - 1);
      p.autoPageSeconds = autoPageWaits[i];
    } else {
      final i = (_nearest(autoScrollSpeeds, p.autoScrollLines) + faster).clamp(0, autoScrollSpeeds.length - 1);
      p.autoScrollLines = autoScrollSpeeds[i];
    }
    p.save();
    notifyListeners();
  }

  /// The step nearest [value] (a speed kept from before may fall between).
  static int _nearest(List<int> steps, int value) {
    var best = 0;
    for (var i = 1; i < steps.length; i++) {
      if ((steps[i] - value).abs() < (steps[best] - value).abs()) best = i;
    }
    return best;
  }
}

/// While auto-scroll is on: hold it or go on, its speed, slower and faster,
/// and stop. Over the page as a search's matches are.
class AutoScrollPill extends StatelessWidget {
  const AutoScrollPill({super.key, required this.auto, required this.pages});

  final AutoScroll auto;

  /// In pages: a page's wait, not a speed.
  final bool pages;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auto,
        builder: (context, _) {
          final onDark = Skin.onDark(context);
          Widget button(String tip, IconData icon, VoidCallback? onTap, {Color? color}) => IconButton(
                tooltip: tip,
                onPressed: onTap,
                color: color ?? onDark,
                disabledColor: onDark.withValues(alpha: 0.3),
                icon: Icon(icon),
              );
          return Semantics(
            container: true,
            label: 'Auto-scroll',
            child: Material(
              color: Skin.darkOn(context),
              shape: const StadiumBorder(),
              elevation: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  auto.held
                      ? button('Go on', Icons.play_arrow_rounded, auto.goOn, color: Skin.accentOf(context))
                      : button('Pause auto-scroll', Icons.pause_rounded, auto.hold, color: Skin.accentOf(context)),
                  Flexible(
                    child: Text(
                      auto.label(pages: pages),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Skin.ui(size: 13, weight: FontWeight.w600, color: onDark),
                    ),
                  ),
                  button(pages ? 'Longer on each page' : 'Scroll slower', Icons.remove_rounded,
                      auto.canSlowDown(pages: pages) ? () => auto.slowDown(pages: pages) : null),
                  button(pages ? 'Shorter on each page' : 'Scroll faster', Icons.add_rounded,
                      auto.canSpeedUp(pages: pages) ? () => auto.speedUp(pages: pages) : null),
                  button('Stop auto-scroll', Icons.close_rounded, auto.stop),
                ],
              ),
            ),
          );
        },
      );
}

/// Tells [onFront] whether its page is the one in front (nothing opened over
/// it: a sheet, a dialog, another screen) each time that changes, after the
/// frame: only this small widget hears the route, so the page is not built
/// again when a sheet opens over it.
class FrontWatch extends StatefulWidget {
  const FrontWatch({super.key, required this.onFront, required this.child});

  final ValueChanged<bool> onFront;
  final Widget child;

  @override
  State<FrontWatch> createState() => _FrontWatchState();
}

class _FrontWatchState extends State<FrontWatch> {
  bool _front = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final front = ModalRoute.isCurrentOf(context) ?? true;
    if (front == _front) return;
    _front = front;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _front == front) widget.onFront(front);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
