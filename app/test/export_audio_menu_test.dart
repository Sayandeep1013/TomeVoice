// The menus that offer saving as audio: a book's page (this chapter or the
// whole book, with how long and how large, and the voice it is read in) and
// the reader's press-and-hold menu.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/export_audio.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/speech_service.dart';

late Directory _dir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('tomevoice_menu');
    ListeningPrefs.reset();
    MarkStore.instance.reset();
    SpeechService.resetQueue();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(AudioExport.channel, null);
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('the menus', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    void voices() {
      messenger.setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), (call) async => switch (call.method) {
            'listEngines' => [
                {'name': 'com.google.android.tts', 'label': 'Google TTS'},
              ],
            'listVoices' => [
                {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
              ],
            'outputDir' => _dir.path,
            'playerPosition' => 0,
            'playerEnqueue' => 0,
            _ => null,
          });
      messenger.setMockMethodCallHandler(AudioExport.channel, (call) async => switch (call.method) {
            'space' => 64 * 1024 * 1024 * 1024,
            'audiobooksFolder' => true,
            _ => null,
          });
    }

    tearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('tomevoice/tts'), null));

    testWidgets("a book's page offers it: this chapter or the whole book, how long and how large", (tester) async {
      phone(tester);
      voices();
      late LibraryStore store;
      late LibraryEntry entry;
      await tester.runAsync(() async {
        store = LibraryStore(_dir);
        final f = File('${_dir.path}/incoming/menu.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('# Chapter 1\n\n${'The first chapter goes on. ' * 30}\n\n# Chapter 2\n\n${'The second one too. ' * 30}');
        entry = await store.importFile(PickedFile(path: f.path, name: 'menu.md'));
      });
      await tester.pumpWidget(MaterialApp(home: BookScreen(store: store, entry: entry)));
      for (var i = 0; i < 60 && find.text('Chapter 2').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Book options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save as audio…'));
      await tester.pumpAndSettle();
      expect(find.text('Save as audio'), findsOneWidget);
      expect(find.text('This chapter'), findsOneWidget);
      expect(find.text('2 chapters, each marked in the file'), findsOneWidget, reason: 'the book page offers the whole book first');
      expect(find.textContaining('of audio'), findsOneWidget);
      expect(find.textContaining('M4B'), findsOneWidget);
      expect(find.textContaining('Read by'), findsOneWidget);
      expect(find.textContaining('the current voice and settings'), findsOneWidget);
      expect(find.text('Audiobooks folder'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      await tester.tap(find.text('This chapter'));
      await tester.pumpAndSettle();
      expect(find.textContaining('M4A'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("the reader's press-and-hold menu offers it for the chapter held", (tester) async {
      phone(tester);
      voices();
      await tester.pumpWidget(MaterialApp(home: ReaderScreen(layout: ReadingLayout.build(specimenBook()))));
      await tester.pumpAndSettle();
      await tester.longPress(find.textContaining('Pack my box').first);
      await tester.pumpAndSettle();
      expect(find.text('Save as audio…'), findsOneWidget);
      expect(find.text('This chapter or the whole book, as you hear it'), findsOneWidget);
      await tester.tap(find.text('Save as audio…'));
      await tester.pumpAndSettle();
      expect(find.text('Save as audio'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
