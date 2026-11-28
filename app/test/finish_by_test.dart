// Reading goals: a day to finish a book by, what it asks of each day at the
// reader's own pace, and the moment today's goal is reached.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/stats.dart';

void main() {
  final store = StatsStore.instance;

  setUp(store.reset);
  tearDown(store.reset);

  test('the words left at a pace, shared over the days to the day, both counted', () {
    final now = DateTime(2026, 11, 28, 12);
    // 60,000 words at 150 a minute: 400 minutes, over 28 Nov to 7 Dec (10 days).
    final plan = finishPlan(wordsLeft: 60000, by: DateTime(2026, 12, 7), wpm: 150, now: now)!;
    expect(plan.daysLeft, 10);
    expect(plan.minutesLeft, 400);
    expect(plan.minutesPerDay, 40);
    expect(finishPlan(wordsLeft: 100, by: DateTime(2026, 11, 28), wpm: 150, now: now)!.daysLeft, 1, reason: 'today is the last day');
    expect(finishPlan(wordsLeft: 100, by: DateTime(2026, 11, 27), wpm: 150, now: now), isNull, reason: 'passed');
  });

  test("the reader's own pace once there is half an hour of listening to go by", () {
    final now = DateTime(2026, 11, 28, 20);
    store.addTime('b', const Duration(minutes: 20), listening: true, now: now);
    store.addWords(4000, now: now);
    expect(store.wordsPerMinute(now), isNull, reason: 'too little to go by');
    store.addTime('b', const Duration(minutes: 20), listening: true, now: now.subtract(const Duration(days: 3)));
    store.addWords(4000, now: now.subtract(const Duration(days: 3)));
    expect(store.wordsPerMinute(now), 200);
  });

  test("today's goal reached says so once", () {
    final now = DateTime(2026, 11, 28, 20);
    store.goal = const Duration(minutes: 10);
    var said = 0;
    void heard() => said++;
    store.goalMet.addListener(heard);
    addTearDown(() => store.goalMet.removeListener(heard));
    store.addTime('b', const Duration(minutes: 6), listening: true, now: now);
    expect(said, 0);
    store.addTime('b', const Duration(minutes: 6), listening: true, now: now);
    expect(said, 1);
    store.addTime('b', const Duration(minutes: 6), listening: true, now: now);
    expect(said, 1, reason: 'once a day');
    expect(store.minutesToday('b', now), 18);
  });

  test('a day to finish by is kept in stats.json and read back', () async {
    final tmp = Directory.systemTemp.createTempSync('tomevoice_finish');
    addTearDown(() => tmp.deleteSync(recursive: true));
    await store.attach(tmp);
    await store.setFinishBy('book-1', DateTime(2026, 12, 24));
    store.reset();
    await store.attach(tmp);
    expect(store.finishBy, {'book-1': '2026-12-24'});
    await store.setFinishBy('book-1', null);
    expect(store.finishBy, isEmpty);
  });
}
