// Reading habits: days that start at 4 am, streaks, and the dot digits.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/stats.dart';

void main() {
  final store = StatsStore.instance;

  setUp(store.days.clear);

  test('listening at 1 am counts toward the night before', () {
    expect(dayKey(DateTime(2026, 10, 24, 1, 30)), '2026-10-23');
    expect(dayKey(DateTime(2026, 10, 24, 4, 0)), '2026-10-24');
  });

  test('a streak counts days in a row that met the goal; today not yet met keeps it', () {
    final now = DateTime(2026, 10, 24, 20);
    void read(int daysAgo, int minutes) =>
        store.addTime('b', Duration(minutes: minutes), listening: true, now: now.subtract(Duration(days: daysAgo)));
    read(1, 6);
    read(2, 30);
    read(3, 5);
    read(5, 40); // A gap on day 4 ends the run there.
    expect(store.streak(now), 3, reason: 'today is not over yet');
    read(0, 2);
    expect(store.streak(now), 3, reason: 'two minutes is short of the goal');
    read(0, 4);
    expect(store.streak(now), 4);
    expect(store.bestStreak(), 4);
  });

  test('reading counts as well as listening, and time is kept per book', () {
    final now = DateTime(2026, 10, 24, 12);
    store.addTime('a', const Duration(minutes: 3), listening: true, now: now);
    store.addTime('b', const Duration(minutes: 2), listening: false, now: now);
    final day = store.today(now);
    expect(day.listenMs, 180000);
    expect(day.readMs, 120000);
    expect(day.books, {'a': 180000, 'b': 120000});
    expect(store.met(dayKey(now)), isTrue);
  });

  test('the last days, oldest first, end today', () {
    final now = DateTime(2026, 10, 24, 12);
    store.addTime('a', const Duration(minutes: 9), listening: true, now: now.subtract(const Duration(days: 2)));
    store.addTime('a', const Duration(minutes: 4), listening: true, now: now);
    expect(store.lastDays(3, now), [9, 0, 4]);
  });

  testWidgets('a number is drawn as dots, and read out as itself', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Center(child: DotText('12', dot: 6))));
    final size = tester.getSize(find.byType(DotText));
    expect(size.width, closeTo(2 * 6 * 9 - 9, 0.01));
    expect(find.bySemanticsLabel('12'), findsOneWidget);
  });
}
