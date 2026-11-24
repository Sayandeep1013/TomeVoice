import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'note_log.dart';

export 'note_log.dart' show LogEvent;

/// The tap log: where the reader's finger came down, how long it stayed,
/// what was under it and whether that answered, for a reader whose taps go
/// unanswered to share (About > Tap log). Off unless they turn it on;
/// nothing is ever sent from the app.
///
/// The app's own buttons (rows, sheet actions, round buttons, pills, Play)
/// are tagged ([TapTag]) and say when they answer, so a tap that landed on
/// one and was not answered shows as missed, and whether that button was
/// built anew under the finger while it was held (how 2.6.3 lost taps).
/// A page or sheet opening or closing just after a tap answers it too. It
/// also notes the moments the screen stuck (a picture over 0.12 s), which
/// make a tap feel ignored.
///
/// Never a book's words or what the reader types: a tap is a place on the
/// screen in dp, a time, and the name of the app's own button under it
/// (rows showing the reader's own words, such as a tag's, give a plain
/// name instead).
class TapLog extends NoteLog {
  TapLog._() : super(logFile: fileName, onFlag: onName, most: keep);

  static final instance = TapLog._();

  /// The most kept: one more pushes out the oldest (a few days of use).
  static const keep = 3000;

  /// The log, one note a line, in the app's private storage (out of every
  /// backup, as the voice log is).
  static const fileName = 'tap-log.jsonl';

  /// There while the log is on.
  static const onName = 'tap-log.on';

  /// How long after the finger lifts an answer still counts as the tap's
  /// (a button that also takes a double tap answers 0.3 s late).
  static const window = Duration(milliseconds: 700);

  /// A press that moves further than this is a scroll or a drag to
  /// Flutter, not a tap (its touch slop).
  static const slop = 18.0;

  /// A picture that took longer than this to draw is a stuck screen.
  static const stuck = Duration(milliseconds: 120);

  final _fingers = <int, _Press>{};
  final _lifted = <_Press>[];
  bool _timing = false;

  /// The page or sheet on top, as [TapLogScreens] sees it.
  Route<dynamic>? _top;

  @override
  void switched() {
    final binding = SchedulerBinding.instance;
    if (on && !_timing) {
      binding.addTimingsCallback(_frames);
      _timing = true;
    } else if (!on && _timing) {
      binding.removeTimingsCallback(_frames);
      _timing = false;
    }
  }

  void _frames(List<FrameTiming> timings) {
    for (final t in timings) {
      if (t.totalSpan >= stuck) note('stuck', {'ms': t.totalSpan.inMilliseconds});
    }
  }

  /// A finger came down, moved or lifted anywhere in the app ([TapRecorder]).
  void pointer(PointerEvent e) {
    if (!on) return;
    switch (e) {
      case PointerDownEvent():
        final press = _Press(DateTime.now(), e.position, screenName(_top));
        _look(press, e);
        // A second finger makes it a pinch: neither is a tap.
        if (_fingers.isNotEmpty) {
          for (final f in _fingers.values) {
            f.pinch = true;
          }
          press.pinch = true;
        }
        _fingers[e.pointer] = press;
      case PointerMoveEvent():
        final press = _fingers[e.pointer];
        if (press == null) return;
        final far = (e.position - press.at).distance;
        if (far > press.far) press.far = far;
      case PointerUpEvent():
        final press = _fingers.remove(e.pointer);
        if (press == null || press.pinch) return;
        press.up = DateTime.now();
        if (press.far > slop) {
          // Only a press that slid a little is worth a note: it may have
          // been meant as a tap. A real scroll is not.
          if (press.far <= slop * 2.7) {
            note('slid', {..._where(press), 'moved': press.far.round(), 'held': press.held});
          }
          return;
        }
        _lifted.add(press);
        Timer(window, () => _finish(press));
      case PointerCancelEvent():
        _fingers.remove(e.pointer);
    }
  }

  /// What is under the finger: the app's own button (its tag) and whether
  /// anything there takes a tap at all, kept to see later whether it was
  /// built anew while held.
  void _look(_Press press, PointerDownEvent e) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, e.position, e.viewId);
      for (final entry in result.path) {
        final target = entry.target;
        if (press.tag == null && target is RenderMetaData && target.metaData is TapTag) {
          press.tag = target.metaData as TapTag;
          press.tagged = target;
        }
        if (press.handler == null && target is RenderSemanticsGestureHandler && target.onTap != null) {
          press.handler = target;
        }
      }
    } on Object {
      // Nothing known of what was under it.
    }
  }

  /// Note the tap [press]: what answered it, or that nothing did (and
  /// whether its button was built anew under the finger).
  void _finish(_Press press) {
    _lifted.remove(press);
    if (!on) return;
    final tag = press.tag;
    final answer = press.answer ?? (press.screenChanged ? '${press.changeWord} ${screenName(_top)}' : null);
    final lost = (press.handler?.attached == false) || (press.tagged?.attached == false);
    note('tap', {
      ..._where(press),
      'on': tag?.name ?? (press.handler != null ? 'other' : 'nothing'),
      if (tag != null) 'kind': tag.kind,
      'held': press.held,
      if (press.far >= 1) 'moved': press.far.round(),
      'answer': answer ?? 'none',
      if (press.answerAt != null) 'ms': press.answerAt!.difference(press.up!).inMilliseconds.clamp(0, 99999),
      if (answer == null && lost) 'lost': 'rebuilt',
    });
  }

  Map<String, Object?> _where(_Press p) => {
        'screen': p.screen,
        'x': p.at.dx.round(),
        'y': p.at.dy.round(),
      };

  /// The press an answer now belongs to: the last one down, still held or
  /// lifted within [window].
  _Press? _current() {
    final now = DateTime.now();
    _Press? best;
    for (final p in [..._fingers.values, ..._lifted]) {
      if (p.pinch) continue;
      final up = p.up;
      if (up != null && now.difference(up) > window) continue;
      if (best == null || p.down.isAfter(best.down)) best = p;
    }
    return best;
  }

  /// One of the app's buttons answered a tap: [name] as it shows.
  void answered(String name) {
    if (!on) return;
    final p = _current();
    if (p == null || p.answer != null) return;
    p
      ..answer = name.isEmpty ? 'a button' : name
      ..answerAt = DateTime.now();
  }

  /// A page, sheet or dialog opened ([opened]) or closed: the answer to
  /// the tap just made, when nothing else answered it.
  void _screenChanged(Route<dynamic>? top, {required bool opened}) {
    _top = top;
    if (!on) return;
    final p = _current();
    if (p == null || p.answer != null || p.screenChanged) return;
    p
      ..screenChanged = true
      ..changeWord = opened ? 'opened' : 'back to'
      ..answerAt = DateTime.now();
  }

  @override
  void reset() {
    if (_timing) SchedulerBinding.instance.removeTimingsCallback(_frames);
    _timing = false;
    _fingers.clear();
    _lifted.clear();
    _top = null;
    super.reset();
  }

  /// What [route] shows, by the name of the screen or sheet it builds
  /// ("BookScreen", "VoiceLogSheet"), or what kind of thing it is.
  static String screenName(Route<dynamic>? route) {
    if (route == null) return 'start';
    if (route is ModalRoute) {
      final c = route.subtreeContext;
      if (c != null) {
        final found = _screenIn(c);
        if (found != null) return found;
      }
    }
    final type = route.runtimeType.toString();
    if (type.contains('BottomSheet')) return 'a sheet';
    if (type.contains('Dialog')) return 'a dialog';
    if (type.contains('Popup') || type.contains('Menu')) return 'a menu';
    return route.settings.name ?? 'a page';
  }

  static final _screenWord = RegExp(r'(Screen|Sheet|Page|Shell|Reader|View)$');
  static const _framework = {
    'BottomSheet',
    'DraggableScrollableSheet',
    'PageView',
    'ListView',
    'GridView',
    'PageStorage',
    'ScrollView',
    'CustomScrollView',
  };

  /// The first of the app's screens or sheets under [c], looking no
  /// further than a few dozen widgets down.
  static String? _screenIn(BuildContext c) {
    final queue = <Element>[];
    if (c is Element) queue.add(c);
    var seen = 0;
    while (queue.isNotEmpty && seen < 80) {
      final e = queue.removeAt(0);
      seen++;
      final name = e.widget.runtimeType.toString();
      if (!name.startsWith('_') && !_framework.contains(name) && _screenWord.hasMatch(name)) return name;
      e.visitChildElements(queue.add);
    }
    return null;
  }
}

/// What one of the app's buttons is, to the tap log: its [kind] ("row",
/// "sheet action", "button", "Play") and its [name] as it shows.
@immutable
class TapTag {
  const TapTag(this.kind, this.name);

  final String kind;
  final String name;
}

/// [child] tagged for the tap log as [kind] named [name] (a finger on it is
/// known to be on that button).
Widget tapTagged(String kind, String name, Widget child) =>
    MetaData(metaData: TapTag(kind, name), child: child);

/// [onTap], telling the tap log first that [name] answered.
VoidCallback? tapAnswered(String name, VoidCallback? onTap) {
  if (onTap == null) return null;
  return () {
    TapLog.instance.answered(name);
    onTap();
  };
}

/// Every finger on the app, to the tap log (it notes nothing while off).
/// Sits over the whole app, letting every touch through untouched.
class TapRecorder extends StatelessWidget {
  const TapRecorder({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: TapLog.instance.pointer,
        onPointerMove: TapLog.instance.pointer,
        onPointerUp: TapLog.instance.pointer,
        onPointerCancel: TapLog.instance.pointer,
        child: child,
      );
}

/// Which page or sheet is on top, for the tap log; one opening or closing
/// just after a tap answers it.
class TapLogScreens extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      TapLog.instance._screenChanged(route, opened: true);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      TapLog.instance._screenChanged(previousRoute, opened: false);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == TapLog.instance._top) TapLog.instance._screenChanged(previousRoute, opened: false);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == TapLog.instance._top) TapLog.instance._screenChanged(newRoute, opened: true);
  }
}

/// One finger's press.
class _Press {
  _Press(this.down, this.at, this.screen);

  final DateTime down;
  final Offset at;
  final String screen;
  DateTime? up;
  double far = 0;
  bool pinch = false;
  TapTag? tag;
  RenderObject? tagged;
  RenderObject? handler;
  String? answer;
  DateTime? answerAt;
  bool screenChanged = false;
  String changeWord = '';

  int get held => (up ?? DateTime.now()).difference(down).inMilliseconds;
}

int _median(List<int> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

String _secs(num ms) => '${(ms / 1000).toStringAsFixed(2)} s';

String _times(int n) => n == 1 ? 'once' : '$n times';

/// A tap held at least this long is a press-and-hold, not a tap.
const _hold = 500;

/// Under this, a quick tap; from it, a finger that stayed a moment.
const _quick = 150;

/// What [events] say, in plain words, a line each: how many taps the app's
/// buttons answered, which went unanswered and why, how quickly answers
/// came, taps on nothing, presses taken as scrolls, and a stuck screen.
List<String> tapLogSummary(List<LogEvent> events) {
  final out = <String>[];
  final taps = events.where((e) => e.kind == 'tap' && (e.n('held') ?? 0) < _hold).toList();
  if (taps.isEmpty) {
    out.add('No tap was noted yet: use the app as you normally do with the log on.');
  } else {
    final ours = taps.where((e) => e.s('kind').isNotEmpty).toList();
    out.add('${taps.length} ${taps.length == 1 ? 'tap' : 'taps'} noted; ${ours.length} on the app\'s own buttons, '
        'which say when they answer.');
    final missed = ours.where((e) => e.s('answer') == 'none').toList();
    if (ours.isNotEmpty && missed.isEmpty) out.add('Every tap on those buttons was answered.');
    if (missed.isNotEmpty) {
      final byName = <String, int>{};
      for (final e in missed) {
        final name = '${e.s('on')} (${e.s('screen')})';
        byName[name] = (byName[name] ?? 0) + 1;
      }
      final names = (byName.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .map((e) => e.value == 1 ? e.key : '${e.key} ${e.value} times')
          .join(', ');
      out.add('${missed.length} of them went unanswered: $names.');
      final rebuilt = missed.where((e) => e.s('lost') == 'rebuilt').length;
      if (rebuilt > 0) {
        out.add('$rebuilt of the unanswered were lost because the button was built anew under the finger '
            'while it was held: a fault in the app, not the finger.');
      }
    }
    if (ours.isNotEmpty) {
      String part(List<LogEvent> xs) =>
          '${xs.where((e) => e.s('answer') != 'none').length} of ${xs.length}';
      final quick = ours.where((e) => (e.n('held') ?? 0) < _quick).toList();
      final longer = ours.where((e) => (e.n('held') ?? 0) >= _quick).toList();
      if (quick.isNotEmpty && longer.isNotEmpty) {
        out.add('Quick taps (under ${_secs(_quick)}) were answered ${part(quick)} times; '
            'taps held a moment longer ${part(longer)}.');
      }
    }
    final times = [
      for (final e in taps)
        if (e.s('answer') != 'none' && e.n('ms') != null) e.n('ms')!.round(),
    ];
    if (times.isNotEmpty) {
      out.add('An answer came ${_secs(_median(times))} after the finger lifted, as a rule '
          '(slowest ${_secs(times.reduce((a, b) => a > b ? a : b))}).');
    }
    final nothing = taps.where((e) => e.s('on') == 'nothing' && e.s('answer') == 'none').length;
    if (nothing > 0) out.add('A tap landed where there is nothing to tap ${_times(nothing)}.');
    final others = taps.where((e) => e.s('on') == 'other' && e.s('answer') == 'none').length;
    if (others > 0) {
      out.add('$others ${others == 1 ? 'tap' : 'taps'} on other controls (menus, switches, text buttons) '
          'opened nothing; this log cannot see whether those answered in place.');
    }
  }
  final slid = events.where((e) => e.kind == 'slid').length;
  if (slid > 0) {
    out.add('A press slid a little (${TapLog.slop.round()} dp or more), so it was taken as a scroll, not a tap, '
        '${_times(slid)}.');
  }
  final stuck = [for (final e in events) if (e.kind == 'stuck' && e.n('ms') != null) e.n('ms')!.round()];
  if (stuck.isNotEmpty) {
    out.add('The screen stuck ${_times(stuck.length)} (a picture took over ${_secs(TapLog.stuck.inMilliseconds)} '
        'to draw), the longest ${_secs(stuck.reduce((a, b) => a > b ? a : b))}.');
  }
  return out;
}

/// The whole log as text to share: [header] (the phone and the app), the
/// summary, then every note, oldest first.
String tapLogText(List<LogEvent> events, {required List<String> header}) {
  final b = StringBuffer()
    ..writeln('TomeVoice tap log')
    ..writeln("It never holds a book's words or what you type: a tap is a place on the screen in dp, how long the "
        "finger stayed, and the name of the app's button under it.")
    ..writeln();
  for (final h in header) {
    b.writeln(h);
  }
  b
    ..writeln()
    ..writeln('In short')
    ..writeln('--------');
  for (final s in tapLogSummary(events)) {
    b.writeln('- $s');
  }
  b
    ..writeln()
    ..writeln('Step by step')
    ..writeln('------------');
  writeSteps(b, events);
  return b.toString();
}
