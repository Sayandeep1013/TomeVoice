// Main menu > AI chat: where talking with the AI starts. With no key it says
// to add one behind the gear; the gear opens AI settings (the keys and
// everything else of the AI); past talks come from the journal.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/ai/ai_chat_screen.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_screen.dart';
import 'package:tomevoice_spike/journal.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_ai_chat');
    store = LibraryStore(tmp);
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ListeningPrefs.reset();
  });

  tearDown(() {
    AiRing.instance.reset();
    JournalStore.instance.reset();
    ListeningPrefs.reset();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AiChatScreen(store: store)));
    await tester.pumpAndSettle();
  }

  testWidgets('with no key it points to the gear, and the gear opens AI settings', (tester) async {
    await pump(tester);
    expect(find.text('AI chat'), findsOneWidget);
    expect(find.text('Talk about your books'), findsOneWidget);
    await tester.tap(find.byTooltip('AI settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AiScreen), findsOneWidget);
    expect(find.text('AI settings'), findsOneWidget);
    expect(find.textContaining(RegExp('^Add a key')), findsOneWidget);
  });

  testWidgets('with a key, the past talks are listed from the journal', (tester) async {
    await tester.runAsync(() => AiRing.instance.put(const AiKey(
          id: 'k1',
          provider: AiProvider.gemini,
          label: 'Gemini',
          baseUrl: 'https://example.com/v1',
          secret: 'sk-1111',
          models: {AiJob.talker: 'flash'},
        )));
    await tester.runAsync(() => JournalStore.instance.put(JournalEntry(
          id: 't1',
          bookId: 'b1',
          bookTitle: 'Pride and Prejudice',
          created: DateTime.now().toUtc(),
          stamp: const JournalStamp(at: ReadingCursor(sectionIndex: 3), chapter: 3, number: 4),
          talk: const [
            TalkLine(mine: true, text: 'Why does Darcy refuse to dance?'),
            TalkLine(mine: false, text: 'He thinks the company beneath him.'),
          ],
        )));
    await pump(tester);
    expect(find.text('Talk about'), findsOneWidget);
    expect(find.text('Past talks'), findsOneWidget);
    expect(find.text('Why does Darcy refuse to dance?'), findsOneWidget);
    expect(find.textContaining('Pride and Prejudice'), findsOneWidget);
  });
}
