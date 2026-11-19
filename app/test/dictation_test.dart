// Speaking into the journal: the phone's recogniser heard through its
// channel; words joined to what is written (a space, a capital where a
// sentence begins); listening goes on through a pause until stop; the
// book's voice waits meanwhile and reads on after; a refused microphone
// said plainly.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/dictation.dart';
import 'package:tomevoice_spike/journal.dart';
import 'package:tomevoice_spike/journal_page.dart';
import 'package:tomevoice_spike/prefs.dart';

const _channel = MethodChannel('tomevoice/dictate');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('words joined to what is written', () {
    test('a capital at a sentence start, a space between', () {
      expect(insertWords('', 'sunny fought back').text, 'Sunny fought back');
      expect(insertWords('He ran.', 'then he hid').text, 'He ran. Then he hid');
      expect(insertWords('He ran and', 'hid').text, 'He ran and hid');
      expect(insertWords('He ran ', 'and hid').text, 'He ran and hid');
    });

    test('in the middle, where the cursor is, and the cursor after them', () {
      final r = insertWords('He ran. He hid.', 'quickly', at: 6);
      expect(r.text, 'He ran quickly. He hid.');
      expect(r.at, 'He ran quickly'.length);
      expect(insertWords('Ends here', '  ').text, 'Ends here');
    });

    test('what a recogniser error means', () {
      expect(Dictation.problemOf(5, 'en'), isNull);
      expect(Dictation.problemOf(9, 'en'), contains('microphone'));
      expect(Dictation.problemOf(12, 'bn'), contains('(bn)'));
    });
  });

  group('the journal page', () {
    late List<MethodCall> calls;
    var answer = 'listening';

    setUp(() {
      JournalStore.instance.reset();
      ListeningPrefs.reset();
      calls = [];
      answer = 'listening';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'start' ? answer : null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      JournalStore.instance.reset();
      ListeningPrefs.reset();
    });

    /// The recogniser saying something, as Dictation.kt does.
    Future<void> hear(WidgetTester tester, String method, Map<String, Object?> args) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pump();
    }

    final stamp = JournalStamp(at: ReadingCursor(sectionIndex: 3), chapter: 3, number: 4);

    Future<({int held, int readOn})> open(WidgetTester tester, {required bool playing}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      var held = 0, readOn = 0;
      late ({int held, int readOn}) Function() counts;
      counts = () => (held: held, readOn: readOn);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => openJournal(
                context,
                bookId: 'book',
                bookTitle: 'Shadow Slave',
                stampNow: () => stamp,
                language: 'en',
                hold: () async {
                  if (!playing) return null;
                  held++;
                  return () => readOn++;
                },
              ),
              child: const Text('Write'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      _counts = counts;
      return counts();
    }

    testWidgets('spoken words land in the answer, through a pause, and the book waits meanwhile', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, playing: true);
      await tester.tap(find.bySemanticsLabel('Speak instead of writing'));
      await tester.pump();
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {'language': 'en'});
      expect(_counts().held, 1);
      expect(find.textContaining('Listening'), findsOneWidget);

      await hear(tester, 'partial', {'text': 'sunny fought'});
      expect(find.text('sunny fought'), findsOneWidget);
      await hear(tester, 'final', {'text': 'sunny fought back'});
      // Whole: into the first question asked in words, and listening again.
      expect(find.widgetWithText(TextField, 'Sunny fought back'), findsOneWidget);
      expect(calls.where((c) => c.method == 'start').length, 2);
      // A pause too long: still listening.
      await hear(tester, 'error', {'code': 7});
      expect(calls.where((c) => c.method == 'start').length, 3);
      await hear(tester, 'final', {'text': 'and won'});
      expect(find.widgetWithText(TextField, 'Sunny fought back and won'), findsOneWidget);

      // Stop: the last words come, then the book reads on.
      await tester.tap(find.bySemanticsLabel('Stop speaking'));
      await tester.pump();
      expect(calls.last.method, 'stop');
      await hear(tester, 'error', {'code': 7});
      await tester.pump();
      expect(find.textContaining('Listening'), findsNothing);
      expect(_counts().readOn, 1);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final e = JournalStore.instance.forBook('book').single;
      expect(e.answers.single.text, 'Sunny fought back and won');
      semantics.dispose();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the microphone refused: said, and the book reads on', (tester) async {
      final semantics = tester.ensureSemantics();
      answer = 'denied';
      await open(tester, playing: true);
      await tester.tap(find.bySemanticsLabel('Speak instead of writing'));
      await tester.pump();
      expect(find.textContaining('may not use the microphone'), findsOneWidget);
      expect(_counts().readOn, 1);
      semantics.dispose();
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

late ({int held, int readOn}) Function() _counts;
