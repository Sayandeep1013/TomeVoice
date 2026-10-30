// Reading habits: days that start at 4 am, streaks and their goal, and the
// dot digits.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/stats.dart';
import 'package:tomevoice_spike/stats_screen.dart';

void main() {
  final store = StatsStore.instance;

  setUp(store.reset);
  tearDown(store.reset);

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

  group('the daily goal', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tv_goal'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test("is the reader's: kept in stats.json, where the widgets read it, and read back", () async {
      await store.attach(tmp);
      expect(store.goal, const Duration(minutes: 5));
      await store.setGoal(20);
      final saved = jsonDecode(File('${tmp.path}/stats.json').readAsStringSync()) as Map;
      expect(saved['goalMinutes'], 20);
      store.reset();
      await store.attach(tmp);
      expect(store.goal, const Duration(minutes: 20));
    });

    test('only the goals offered can be picked', () async {
      for (final m in [0, 7, 90]) {
        await store.setGoal(m);
        expect(store.goal, const Duration(minutes: 5), reason: '$m minutes');
      }
      expect(StatsStore.goals, [5, 10, 15, 20, 30, 45, 60]);
    });

    test('the streak, the best and a day met count by it', () async {
      final now = DateTime(2026, 10, 24, 20);
      for (var d = 1; d <= 3; d++) {
        store.addTime('b', const Duration(minutes: 12), listening: true, now: now.subtract(Duration(days: d)));
      }
      expect(store.streak(now), 3);
      await store.setGoal(15);
      expect(store.streak(now), 0, reason: 'twelve minutes a day is short of fifteen');
      expect(store.bestStreak(), 0);
      expect(store.met(dayKey(now.subtract(const Duration(days: 1)))), isFalse);
      await store.setGoal(10);
      expect(store.streak(now), 3);
    });

    Future<List<String>> pumpStats(WidgetTester tester, {double text = 1}) async {
      final calls = <String>[];
      const channel = MethodChannel('tomevoice/tts');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final library = LibraryStore(tmp);
      await tester.runAsync(() => library.index());
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
        home: StatsScreen(store: library),
      ));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('is picked where the streak is shown, and the widgets are drawn again with it', (tester) async {
      store.addTime('b', const Duration(minutes: 12), listening: true);
      // Saved now, not in half a minute (no timer left behind).
      await store.flush();
      final calls = await pumpStats(tester);
      expect(find.text('DONE TODAY'), findsOneWidget);
      await tester.tap(find.text('15'));
      // Written at once (real time, for the file), then the widgets told.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(store.goal, const Duration(minutes: 15));
      expect(find.text('OF 15 MIN TODAY'), findsOneWidget);
      expect(calls, contains('refreshWidgets'));
      await tester.scrollUntilVisible(
        find.textContaining('with 15 minutes of listening'),
        300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
      );
      expect(find.textContaining('with 15 minutes of listening'), findsOneWidget);
    });

    testWidgets("the week's bars make room for the phone's larger text", (tester) async {
      store.addTime('b', const Duration(minutes: 40), listening: true);
      await store.flush();
      await pumpStats(tester, text: 2);
      // A fixed 140 overflowed: Flutter reports it as an error.
      expect(tester.takeException(), isNull);
      final bars = tester.getSize(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_WeekBars'));
      expect(bars.height, greaterThan(140));
    });
  });
}
