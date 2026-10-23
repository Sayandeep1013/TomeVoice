import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'book_card.dart';
import 'library_store.dart';
import 'speech_service.dart';
import 'stats.dart';
import 'theme.dart';
import 'ui.dart';

/// Reading habits: the streak, this week, twenty weeks of days as dots, and
/// what was read most. Everything stays on the phone.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final _stats = StatsStore.instance;
  Map<String, LibraryEntry> _books = const {};

  @override
  void initState() {
    super.initState();
    _stats.changes.addListener(_changed);
    unawaited(widget.store.list().then((l) {
      if (mounted) setState(() => _books = {for (final e in l) e.id: e});
    }));
  }

  @override
  void dispose() {
    _stats.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final streak = _stats.streak();
    final best = _stats.bestStreak();
    final week = _stats.lastDays(7);
    final todayMin = week.last;
    final totals = _stats.totals();
    final top = totals.books.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final ink = Skin.inkOn(context);
    final accent = Skin.accentOf(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: Skin.ground(context)),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenTopBar(title: 'Stats', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                      Gap.page, Gap.s, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                  children: [
                    _card(
                      context,
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                DotText('$streak', dot: 9, color: ink, off: ink.withValues(alpha: 0.07)),
                                const SizedBox(height: Gap.m),
                                Text(streak == 1 ? 'DAY STREAK' : 'DAYS STREAK', style: Skin.meta(context)),
                                if (best > streak) ...[
                                  const SizedBox(height: 2),
                                  Text('BEST $best', style: Skin.meta(context, size: 10)),
                                ],
                              ],
                            ),
                          ),
                          _TodayRing(minutes: todayMin, goal: StatsStore.goal.inMinutes, color: accent),
                        ],
                      ),
                    ),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('This week'),
                    const SizedBox(height: Gap.m),
                    _card(context, _WeekBars(minutes: week, goal: StatsStore.goal.inMinutes, color: accent)),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('Twenty weeks'),
                    const SizedBox(height: Gap.m),
                    _card(context, _YearDots(stats: _stats, color: ink)),
                    const SizedBox(height: Gap.l),
                    const SectionTitle('All told'),
                    const SizedBox(height: Gap.m),
                    _card(
                      context,
                      Wrap(
                        runSpacing: Gap.l,
                        children: [
                          _figure(context, _hours(totals.listenMs), 'listened'),
                          _figure(context, _hours(totals.readMs), 'read'),
                          _figure(context, _thousands(totals.words), 'words heard'),
                          _figure(context, '${totals.chapters}', totals.chapters == 1 ? 'chapter finished' : 'chapters finished'),
                        ],
                      ),
                    ),
                    if (top.isNotEmpty) ...[
                      const SizedBox(height: Gap.l),
                      const SectionTitle('Most read'),
                      const SizedBox(height: Gap.s),
                      for (final e in top.take(5)) _bookRow(context, e.key, e.value),
                    ],
                    const SizedBox(height: Gap.l),
                    OutlinedButton.icon(
                      onPressed: () => addWidget(context, 'streak'),
                      icon: const Icon(Icons.widgets_outlined, size: 18),
                      label: const Text('Put the streak on your home screen'),
                    ),
                    const SizedBox(height: Gap.l),
                    Text(
                      'A day counts toward the streak with ${StatsStore.goal.inMinutes} minutes of listening or reading. '
                      'Days start at 4 am, so late nights count toward the day before.',
                      style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Widget child) => Container(
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(
          color: Skin.capsuleOn(context),
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: child,
      );

  Widget _figure(BuildContext context, String value, String label) => FractionallySizedBox(
        widthFactor: 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Skin.title(context, size: 28)),
            Text(label.toUpperCase(), style: Skin.meta(context, size: 10)),
          ],
        ),
      );

  Widget _bookRow(BuildContext context, String id, int ms) {
    final book = _books[id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        children: [
          SizedBox(width: 34, child: book == null ? null : BookCover(entry: book, width: 34, titled: false)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Text(book?.title ?? 'A book no longer here',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 16)),
          ),
          Text(_hours(ms), style: Skin.meta(context)),
        ],
      ),
    );
  }

  static String _hours(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }

  static String _thousands(int n) => n < 10000 ? '$n' : '${(n / 1000).round()}k';
}

/// Today's minutes as a ring that closes at the goal.
class _TodayRing extends StatelessWidget {
  const _TodayRing({required this.minutes, required this.goal, required this.color});

  final int minutes;
  final int goal;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CustomPaint(
              painter: _RingPainter(
                (minutes / goal).clamp(0.0, 1.0),
                color,
                Skin.inkOn(context).withValues(alpha: 0.12),
              ),
              child: Center(child: Text('$minutes', style: Skin.title(context, size: 22))),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(minutes >= goal ? 'DONE TODAY' : 'OF $goal MIN TODAY', style: Skin.meta(context, size: 9.5)),
        ],
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);

  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(4), 0, math.pi * 2, false, stroke..color = track);
    if (value > 0) canvas.drawArc(rect.deflate(4), -math.pi / 2, math.pi * 2 * value, false, stroke..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color;
}

/// Seven bars, today on the right, with the goal as a faint line.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.minutes, required this.goal, required this.color});

  final List<int> minutes;
  final int goal;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final top = math.max(goal * 2, minutes.fold<int>(0, math.max)).toDouble();
    final now = dayOf(dayKey(DateTime.now()));
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < minutes.length; i++)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(minutes[i] == 0 ? '' : '${minutes[i]}', style: Skin.meta(context, size: 9.5)),
                  const SizedBox(height: 4),
                  Container(
                    height: math.max(4, 96 * minutes[i] / top),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: minutes[i] >= goal ? color : color.withValues(alpha: minutes[i] == 0 ? 0.12 : 0.45),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    letters[now.subtract(Duration(days: minutes.length - 1 - i)).weekday - 1],
                    style: Skin.meta(context, size: 10),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Twenty weeks, one dot a day, brighter for more.
class _YearDots extends StatelessWidget {
  const _YearDots({required this.stats, required this.color});

  final StatsStore stats;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final days = stats.lastDays(7 * 20);
    return LayoutBuilder(
      builder: (context, c) {
        final step = c.maxWidth / 20;
        final dot = math.min(step * 0.62, 11.0);
        return SizedBox(
          height: step * 7,
          child: CustomPaint(painter: _DaysPainter(days, color, dot, step, StatsStore.goal.inMinutes)),
        );
      },
    );
  }
}

class _DaysPainter extends CustomPainter {
  _DaysPainter(this.days, this.color, this.dot, this.step, this.goal);

  final List<int> days;
  final Color color;
  final double dot;
  final double step;
  final int goal;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < days.length; i++) {
      final m = days[i];
      final level = m == 0 ? 0.08 : (m < goal ? 0.3 : (m < goal * 4 ? 0.65 : 1.0));
      canvas.drawCircle(
        Offset((i ~/ 7) * step + step / 2, (i % 7) * step + step / 2),
        dot / 2,
        Paint()..color = color.withValues(alpha: level),
      );
    }
  }

  @override
  bool shouldRepaint(_DaysPainter old) => old.days.join() != days.join() || old.color != color;
}

/// Ask the launcher to add a TomeVoice widget ([kind]: player, playerWide,
/// streak, streakWide), or say how to add one by hand.
Future<void> addWidget(BuildContext context, String kind) async {
  final ok = await const SpeechService().pinWidget(kind);
  if (!ok && context.mounted) {
    showSnack(
      context,
      'Press and hold an empty spot on your home screen, then Widgets → TomeVoice.',
      long: true,
    );
  }
}
