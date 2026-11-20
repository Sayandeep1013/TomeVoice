// Interview me: at a chapter's end the journal's questions asked aloud (in
// the reader's words turned to them), each answer heard until a pause; a
// pick question's pick matched in what was said; "skip" passes, "stop"
// ends; the answers kept.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/dictation.dart';
import 'package:tomevoice_spike/interview.dart';
import 'package:tomevoice_spike/journal.dart';

const _channel = Dictation.defaultChannel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the reader's own questions, asked of them", () {
    expect(askedAloud(const JournalQuestion('What do I think happens next?')), 'What do you think happens next?');
    expect(askedAloud(const JournalQuestion('Why?')), 'Why?');
    expect(askedAloud(const JournalQuestion('I liked my favourite scene because…')), 'You liked your favourite scene because…');
    expect(askedAloud(defaultJournalQuestions.first), 'How are you feeling? Loving it, Good, Mixed, Meh or Frustrated?');
  });

  test('what was said: a pick matched, the words kept; skip and stop', () {
    final feel = defaultJournalQuestions.first;
    final a = heardFor(feel, 'pretty good actually') as HeardAnswer;
    expect((a.answer.pick, a.answer.text), ('Good', 'Pretty good actually.'));
    final b = heardFor(feel, 'Mixed') as HeardAnswer;
    expect((b.answer.pick, b.answer.text), ('Mixed', ''));
    final c = heardFor(feel, 'hard to say') as HeardAnswer;
    expect((c.answer.pick, c.answer.text), (null, 'Hard to say.'));
    expect(heardFor(const JournalQuestion('Why?'), 'skip'), isA<HeardSkip>());
    expect(heardFor(const JournalQuestion('Why?'), ''), isA<HeardSkip>());
    expect(heardFor(const JournalQuestion('Why?'), "that's all"), isA<HeardStop>());
    final d = heardFor(const JournalQuestion('Why?'), 'because she lied to him') as HeardAnswer;
    expect(d.answer.text, 'Because she lied to him.');
  });

  testWidgets('asked, heard, passed and kept', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'start' ? 'listening' : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
    Future<void> hear(String text) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('final', {'text': text})),
        (_) {},
      );
      await tester.pump();
      // The pause after the last words: the answer taken.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
    }

    final said = <String>[];
    List<JournalAnswer>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            got = await runInterview(
              context,
              questions: const [
                JournalQuestion('How am I feeling?', picks: ['Good', 'Meh']),
                JournalQuestion('What stood out?'),
                JournalQuestion('What do I think happens next?'),
              ],
              chapter: 4,
              say: (t) async => said.add(t),
              language: 'en',
              settle: const Duration(milliseconds: 100),
              patience: const Duration(seconds: 5),
            );
          },
          child: const Text('Go'),
        ),
      ),
    ));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('ABOUT CHAPTER 4'), findsOneWidget);
    expect(said, ['How are you feeling? Good or Meh?']);
    expect(calls.where((c) => c.method == 'start').length, 1);

    await hear('good I think');
    expect(said.last, 'What stood out?');
    await hear('skip');
    expect(said.last, 'What do you think happens next?');
    await hear('she wins the duel');
    await tester.pumpAndSettle();

    expect(got?.map((a) => (a.question, a.pick, a.text)), [
      ('How am I feeling?', 'Good', 'Good I think.'),
      ('What do I think happens next?', null, 'She wins the duel.'),
    ]);
    expect(find.text('Interview'), findsNothing);
  });

  testWidgets('nothing said: the question passes after a while; Done ends it with what was said', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      return call.method == 'start' ? 'listening' : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));
    final said = <String>[];
    List<JournalAnswer>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            got = await runInterview(
              context,
              questions: const [JournalQuestion('Why?'), JournalQuestion('What stood out?')],
              chapter: 1,
              say: (t) async => said.add(t),
              patience: const Duration(seconds: 2),
            );
          },
          child: const Text('Go'),
        ),
      ),
    ));
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(said, ['Why?']);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(said, ['Why?', 'What stood out?']);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(got, isEmpty);
  });
}
