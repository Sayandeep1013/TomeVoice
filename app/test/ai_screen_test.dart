// Main menu > AI: keys added from any provider, as many as wanted, each
// with a model per job; each job lists its keys in order; a key's state
// (resting, refused) shown.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/ai_client.dart';
import 'package:tomevoice_spike/ai/ai_data.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';
import 'package:tomevoice_spike/ai/ai_screen.dart';

void main() {
  setUp(AiRing.instance.reset);
  tearDown(AiRing.instance.reset);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AiScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> addKey(WidgetTester tester, String provider, String secret, {String? builder, String? talker}) async {
    await tester.tap(find.textContaining(RegExp('^Add (a|another) key')));
    await tester.pumpAndSettle();
    // The first time: what is sent, agreed to.
    if (find.text('I agree').evaluate().isNotEmpty) {
      await tester.tap(find.text('I agree'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(ChoiceChip, provider));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'API key'), secret);
    if (builder != null) await tester.enterText(find.widgetWithText(TextField, 'Building memories'), builder);
    if (talker != null) await tester.enterText(find.widgetWithText(TextField, 'Talking'), talker);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('three keys from one provider and one from another, each job with its own order', (tester) async {
    await pump(tester);
    expect(find.textContaining('Nothing from your books is sent until you add a key'), findsOneWidget);

    await addKey(tester, 'Inception (Mercury)', 'sk-one-1111', builder: 'mercury-3', talker: 'mercury-3');
    await addKey(tester, 'Inception (Mercury)', 'sk-two-2222', builder: 'mercury-3');
    await addKey(tester, 'Inception (Mercury)', 'sk-three-3333', builder: 'mercury-3');
    await addKey(tester, 'Google Gemini', 'AIza-4444', talker: 'gemini-flash');

    final ring = AiRing.instance;
    expect(ring.keys.map((k) => k.label), ['Inception (Mercury)', 'Inception (Mercury) 2', 'Inception (Mercury) 3', 'Google Gemini']);
    expect(ring.forJob(AiJob.builder).length, 3);
    expect(ring.forJob(AiJob.talker).map((k) => k.label), ['Inception (Mercury)', 'Google Gemini']);
    // The secret is never shown whole.
    expect(find.textContaining('••••4444'), findsOneWidget);
    expect(find.textContaining('AIza-4444'), findsNothing);
    await tester.scrollUntilVisible(find.text('Building memories'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('HOLD TO MOVE'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Talking'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('gemini-flash'), findsOneWidget);
  });

  testWidgets('nothing is sent before the reader agrees: asked once, before the first key', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add a key'));
    await tester.pumpAndSettle();
    expect(find.text('Before the AI reads with you'), findsOneWidget);
    expect(find.textContaining('There is no TomeVoice server'), findsOneWidget);
    // Not now: no key sheet, nothing agreed.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'API key'), findsNothing);
    expect(AiRing.instance.consented, isFalse);

    await addKey(tester, 'Google Gemini', 'AIza-5555', talker: 'gemini-flash');
    expect(AiRing.instance.consented, isTrue);
    // Asked once only.
    await tester.tap(find.text('Add another key'));
    await tester.pumpAndSettle();
    expect(find.text('Before the AI reads with you'), findsNothing);
    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
  });

  test('a ring kept from before the question (an update) has not agreed; the router sends nothing', () async {
    final tmp = Directory.systemTemp.createTempSync('tv_consent');
    addTearDown(() => tmp.deleteSync(recursive: true));
    const key = AiKey(
        id: 'a', provider: AiProvider.gemini, label: 'Gemini', baseUrl: 'http://127.0.0.1:9/v1', secret: 's1',
        models: {AiJob.talker: 'flash'});
    // As 2.1 kept it: keys, no consent.
    File('${tmp.path}/.secrets.json').writeAsStringSync(jsonEncode({
      'ai.ring': jsonEncode({
        'keys': [key.toJson()],
      }),
    }));
    final ring = AiRing.instance;
    await ring.attach(tmp);
    expect(ring.hasKeys, isTrue);
    expect(ring.consented, isFalse);
    await expectLater(
      AiRouter(ring: ring).chat(AiJob.talker, [aiMessage('user', 'hi')]),
      throwsA(isA<AiResting>().having((e) => e.last, 'last', notConsented)),
    );
    await ring.consent();
    expect(ring.consented, isTrue);
    // Kept: read again, still agreed.
    ring.reset();
    await ring.attach(tmp);
    expect(ring.consented, isTrue);
  });

  test('what was sent: each call logged with its book, kept on the phone, the oldest let go', () async {
    final tmp = Directory.systemTemp.createTempSync('tv_log');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final ring = AiRing.instance;
    await ring.attach(tmp);
    const key = AiKey(
        id: 'a', provider: AiProvider.gemini, label: 'Gemini', baseUrl: 'https://x/v1', secret: 's1',
        models: {AiJob.talker: 'flash', AiJob.builder: 'lite'});
    await ring.put(key);
    ring.logCall(AiJob.builder, key, about: 'Shadow Slave', usage: const AiUsage(input: 40000, output: 900));
    ring.logCall(AiJob.talker, key, about: 'Shadow Slave', usage: const AiUsage(input: 3000, output: 200));
    expect(ring.log.map((e) => (e.job, e.model, e.about)), [
      (AiJob.builder, 'lite', 'Shadow Slave'),
      (AiJob.talker, 'flash', 'Shadow Slave'),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    ring.reset();
    await ring.attach(tmp);
    expect(ring.log.length, 2);
    expect(ring.log.last.input, 3000);
    for (var i = 0; i < AiRing.logKept + 5; i++) {
      ring.logCall(AiJob.talker, key);
    }
    expect(ring.log.length, AiRing.logKept);
    await ring.clearLog();
    expect(ring.log, isEmpty);
    // Its save timer goes before the folder does.
    ring.reset();
  });

  testWidgets('the list of what was sent, newest first', (tester) async {
    const key = AiKey(
        id: 'a', provider: AiProvider.gemini, label: 'Gemini', baseUrl: 'https://x/v1', secret: 's1',
        models: {AiJob.talker: 'flash', AiJob.builder: 'lite'});
    final ring = AiRing.instance;
    ring.logCall(AiJob.builder, key, about: 'Lord of the Mysteries', usage: const AiUsage(input: 40000, output: 900));
    ring.logCall(AiJob.talker, key, about: 'Shadow Slave', usage: const AiUsage(input: 3000, output: 200));
    await tester.pumpWidget(const MaterialApp(home: AiLogScreen()));
    await tester.pumpAndSettle();
    final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.title! as Text).data).toList();
    expect(titles, ['Talking · Shadow Slave', 'Building memories · Lord of the Mysteries']);
    expect(find.textContaining('3.0k in, 200 out'), findsOneWidget);
    expect(find.textContaining('40k in, 900 out'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("a resting key says until when; a refused one says why", (tester) async {
    final ring = AiRing.instance;
    await ring.put(const AiKey(
        id: 'a', provider: AiProvider.gemini, label: 'Gemini', baseUrl: 'https://x/v1', secret: 's1',
        models: {AiJob.builder: 'flash-lite'}));
    await ring.put(const AiKey(
        id: 'b', provider: AiProvider.openrouter, label: 'Router', baseUrl: 'https://y/v1', secret: 's2',
        models: {AiJob.talker: 'some/model'}));
    final wake = DateTime.now().add(const Duration(hours: 2));
    await ring.rest('a', wake, 'quota');
    await ring.refuse('b', 'Invalid API key');
    await pump(tester);
    expect(find.text('Resting until ${wakeTime(wake)}'), findsOneWidget);
    expect(find.text('Refused: Invalid API key'), findsOneWidget);
  });

  test('a likely model for each job, from what the key offers', () {
    const gemini = [
      'gemini-2.5-flash',
      'gemini-3.5-flash-lite',
      'gemini-3.6-flash',
      'gemini-3.8-flash-preview',
      'gemini-embedding-001',
      'gemini-3.6-flash-image',
    ];
    expect(suggestModel(AiProvider.gemini, AiJob.builder, gemini), 'gemini-3.5-flash-lite');
    expect(suggestModel(AiProvider.gemini, AiJob.talker, gemini), 'gemini-3.6-flash');
    expect(suggestModel(AiProvider.gemini, AiJob.embedder, gemini), 'gemini-embedding-001');
    expect(suggestModel(AiProvider.inception, AiJob.builder, ['mercury-coder', 'mercury-2', 'mercury-3']), 'mercury-3');
    expect(suggestModel(AiProvider.openrouter, AiJob.talker, ['a/b']), isNull);
  });

  test('token counts read short', () {
    expect(tokenCount(950), '950');
    expect(tokenCount(3412), '3,412');
    expect(tokenCount(48200), '48k');
    expect(tokenCount(1250000), '1.3M');
    expect(tokenCount(14000000), '14M');
  });
  test('a daily limit: typed short, kept, and once reached the key rests until midnight', () async {
    expect(capOf('2M'), 2000000);
    expect(capOf('500k'), 500000);
    expect(capOf('1.5m'), 1500000);
    expect(capOf('120,000'), 120000);
    expect(capOf(''), isNull);
    expect(capOf('lots'), isNull);

    const key = AiKey(id: 'c', provider: AiProvider.gemini, label: 'Gemini', baseUrl: 'u', secret: 's',
        models: {AiJob.builder: 'm'}, dailyCap: 1000);
    expect(AiKey.fromJson(key.toJson())!.dailyCap, 1000);
    expect(AiKey.fromJson(key.copyWith(label: 'x').toJson())!.dailyCap, 1000);

    final ring = AiRing.instance;
    await ring.put(key);
    final noon = DateTime(2026, 11, 20, 12);
    ring.count('c', const AiUsage(input: 600, output: 100), now: noon);
    expect(ring.stateOf('c').restingAt(noon), isFalse);
    ring.count('c', const AiUsage(input: 300, output: 50), now: noon);
    await Future<void>.delayed(Duration.zero);
    expect(ring.stateOf('c').restingAt(noon), isTrue);
    expect(ring.stateOf('c').restUntil, DateTime(2026, 11, 21));
  });
  test("checking a key says whether its model calls tools and keeps to JSON", () async {
    const to = AiEndpoint(baseUrl: 'u', key: 'k', model: 'mercury-3');
    expect(await probeModel(_Probe(tools: true, json: true), to), contains('both work fully'));
    final neither = await probeModel(_Probe(tools: false, json: false), to);
    expect(neither, contains('did not call a tool'));
    expect(neither, contains('did not keep to JSON'));
  });
}

/// A provider that calls tools, or keeps to JSON, or not.
class _Probe extends AiClient {
  _Probe({required this.tools, required this.json});

  final bool tools;
  final bool json;

  @override
  Future<AiReply> chat(
    AiEndpoint to,
    List<Map<String, Object?>> messages, {
    List<AiTool> tools = const [],
    bool json = false,
    int? maxTokens,
    double? temperature,
    void Function(String piece)? onText,
  }) async {
    if (tools.isNotEmpty) {
      return AiReply(text: '', toolCalls: [if (this.tools) const AiToolCall(id: '1', name: 'ping', arguments: '{}')]);
    }
    return AiReply(text: this.json ? '{"ok": true}' : 'Sure! Here you go.');
  }
}
