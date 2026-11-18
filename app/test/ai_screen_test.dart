// Main menu > AI: keys added from any provider, as many as wanted, each
// with a model per job; each job lists its keys in order; a key's state
// (resting, refused) shown.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
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
}
