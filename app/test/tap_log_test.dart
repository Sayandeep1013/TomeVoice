// The tap log: off, it notes nothing; on, each tap is where the finger came
// down, which of the app's buttons was under it and whether that answered
// (a page opening counts), a press built anew under the finger is marked as
// lost that way, a press that slid is told apart, the reader's own words
// (a tag's name) never go in, and its notes outlive the app.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/tap_log.dart';
import 'package:tomevoice_spike/ui.dart';

class DemoScreen extends StatelessWidget {
  const DemoScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Demo page')));
}

/// A button whose wrapper changes as the finger comes down (as 2.6.3's
/// press did): the InkWell is built anew and the tap is lost.
class _Swapper extends StatefulWidget {
  const _Swapper({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_Swapper> createState() => _SwapperState();
}

class _SwapperState extends State<_Swapper> {
  bool _wrapped = false;

  @override
  Widget build(BuildContext context) {
    final button = tapTagged(
      'row',
      'Swapped',
      InkWell(
        onTap: tapAnswered('Swapped', widget.onTap),
        child: const SizedBox(width: 200, height: 56, child: Center(child: Text('Swapped'))),
      ),
    );
    return Listener(
      onPointerDown: (_) => setState(() => _wrapped = true),
      child: _wrapped ? Padding(padding: EdgeInsets.zero, child: button) : button,
    );
  }
}

Widget _app(Widget body) => MaterialApp(
      navigatorObservers: [TapLogScreens()],
      builder: (context, child) => TapRecorder(child: child!),
      home: Scaffold(body: ListView(children: [body, const SizedBox(height: 400)])),
    );

/// A finger's tap on [at]: down, held [hold] in frames, up, then long
/// enough for the log to hear any answer and write.
Future<void> tapHeld(WidgetTester tester, Offset at, {Duration hold = const Duration(milliseconds: 120)}) async {
  final finger = await tester.startGesture(at);
  for (var left = hold; left > Duration.zero; left -= const Duration(milliseconds: 16)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await finger.up();
  await tester.pump();
  await tester.pump(TapLog.window + const Duration(milliseconds: 100));
}

/// Past the log's write, so no timer is left when the test ends.
Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 5));

List<LogEvent> _taps() => TapLog.instance.events.where((e) => e.kind == 'tap').toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final log = TapLog.instance;
  setUp(log.reset);
  tearDown(log.reset);

  testWidgets('off, a tap notes nothing', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(SettingRow(title: 'Book memories', onTap: () => taps++)));
    await tapHeld(tester, tester.getCenter(find.text('Book memories')));
    expect(taps, 1);
    expect(log.events, isEmpty);
    await settle(tester);
  });

  testWidgets("on, a tap on the app's own row is noted with its name, its place and its answer", (tester) async {
    log.onForTests = true;
    var taps = 0;
    await tester.pumpWidget(_app(SettingRow(title: 'Book memories', onTap: () => taps++)));
    final at = tester.getCenter(find.text('Book memories'));
    await tapHeld(tester, at);
    expect(taps, 1);
    final tap = _taps().single;
    expect(tap.s('on'), 'Book memories');
    expect(tap.s('kind'), 'row');
    expect(tap.s('answer'), 'Book memories');
    expect(tap.n('x'), at.dx.round());
    expect(tap.n('y'), at.dy.round());
    expect(tap.n('held'), isNotNull);
    expect(tap.s('lost'), isEmpty);
    await settle(tester);
  });

  testWidgets('on, a tap that opens a page is answered by that page, by its name', (tester) async {
    log.onForTests = true;
    await tester.pumpWidget(_app(Builder(
      builder: (context) => FilledButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DemoScreen())),
        child: const Text('Open'),
      ),
    )));
    await tapHeld(tester, tester.getCenter(find.text('Open')));
    await tester.pumpAndSettle();
    final tap = _taps().single;
    expect(tap.s('on'), 'other', reason: 'a Material button, not one of the tagged ones');
    expect(tap.s('answer'), 'opened DemoScreen');
    await settle(tester);
  });

  testWidgets('on, a tap where there is nothing to tap is noted as such', (tester) async {
    log.onForTests = true;
    await tester.pumpWidget(_app(const SizedBox(height: 100, child: Text('Just words'))));
    await tapHeld(tester, tester.getCenter(find.text('Just words')));
    final tap = _taps().single;
    expect(tap.s('on'), 'nothing');
    expect(tap.s('answer'), 'none');
    await settle(tester);
  });

  testWidgets('on, a button built anew under the finger shows as a tap lost that way', (tester) async {
    log.onForTests = true;
    var taps = 0;
    await tester.pumpWidget(_app(_Swapper(onTap: () => taps++)));
    await tapHeld(tester, tester.getCenter(find.text('Swapped')));
    expect(taps, 0, reason: 'the fault this log is there to catch');
    final tap = _taps().single;
    expect(tap.s('on'), 'Swapped');
    expect(tap.s('answer'), 'none');
    expect(tap.s('lost'), 'rebuilt');
    expect(tapLogSummary(log.events), anyElement(contains('built anew under the finger')));
    await settle(tester);
  });

  testWidgets('on, a press that slid a little is told apart from a tap', (tester) async {
    log.onForTests = true;
    var taps = 0;
    await tester.pumpWidget(_app(SettingRow(title: 'Book memories', onTap: () => taps++)));
    final finger = await tester.startGesture(tester.getCenter(find.text('Book memories')));
    await tester.pump(const Duration(milliseconds: 16));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
    await finger.up();
    await tester.pump(TapLog.window + const Duration(milliseconds: 100));
    expect(taps, 0);
    expect(_taps(), isEmpty);
    expect(log.events.where((e) => e.kind == 'slid').single.n('moved'), greaterThanOrEqualTo(30));
    await settle(tester);
  });

  testWidgets("on, a row showing the reader's own words is logged by its plain name", (tester) async {
    log.onForTests = true;
    await tester.pumpWidget(_app(SheetAction(icon: Icons.sell_outlined, label: 'Secret tag', logName: 'a tag', onTap: () {})));
    await tapHeld(tester, tester.getCenter(find.text('Secret tag')));
    final tap = _taps().single;
    expect(tap.s('on'), 'a tag');
    expect(tap.s('answer'), 'a tag');
    final text = tapLogText(log.events, header: const ['Phone: a test']);
    expect(text, isNot(contains('Secret tag')));
    expect(text, contains('Phone: a test'));
    await settle(tester);
  });

  test('the summary says what went unanswered, why, and how held taps fared against quick ones', () {
    final t = DateTime(2026, 11, 25, 10);
    LogEvent tap(String on, String answer, int held, {String lost = ''}) => LogEvent(t, 'tap', {
          'screen': 'AiChatScreen',
          'x': 100,
          'y': 600,
          'on': on,
          if (on != 'nothing') 'kind': 'row',
          'held': held,
          'answer': answer,
          if (answer != 'none') 'ms': 40,
          if (lost.isNotEmpty) 'lost': lost,
        });
    final events = [
      tap('Book memories', 'Book memories', 60),
      tap('Play', 'Play', 70),
      tap('Read from here', 'Read from here', 80),
      tap('Book memories', 'none', 200, lost: 'rebuilt'),
      tap('Book memories', 'none', 180, lost: 'rebuilt'),
      tap('nothing', 'none', 90),
      LogEvent(t, 'slid', const {'moved': 25}),
      LogEvent(t, 'stuck', const {'ms': 300}),
    ];
    final s = tapLogSummary(events);
    expect(s, contains("6 taps noted; 5 on the app's own buttons, which say when they answer."));
    expect(s, contains('2 of them went unanswered: Book memories (AiChatScreen) 2 times.'));
    expect(s, anyElement(startsWith('2 of the unanswered were lost because the button was built anew')));
    expect(s, contains('Quick taps (under 0.15 s) were answered 3 of 3 times; taps held a moment longer 0 of 2.'));
    expect(s, anyElement(startsWith('A tap landed where there is nothing to tap once')));
    expect(s, anyElement(startsWith('A press slid a little')));
    expect(s, anyElement(startsWith('The screen stuck once')));
    expect(tapLogSummary(const []), [startsWith('No tap was noted yet')]);
  });

  test('on, its notes are kept on the phone and read back; cleared, they are gone', () async {
    final dir = Directory.systemTemp.createTempSync('tomevoice_taplog');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });
    await log.attach(dir);
    await log.setOn(true);
    log.note('tap', {'on': 'Play', 'answer': 'Play', 'held': 90});
    await log.flush();
    log.reset();
    await log.attach(dir);
    expect(log.on, isTrue);
    expect(log.events.map((e) => e.kind), containsAll(['log on', 'tap']));
    await log.clear();
    expect(log.events, isEmpty);
    expect(File('${dir.path}/${TapLog.fileName}').existsSync(), isFalse);
    await log.setOn(false);
    expect(File('${dir.path}/${TapLog.onName}').existsSync(), isFalse);
  });
}
