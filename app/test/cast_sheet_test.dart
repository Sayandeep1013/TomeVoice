// A book page's Characters: shown under its voice once the book's speech
// tags name anyone, listing them with how often each speaks; a voice given
// to one is kept with the book's settings, and their own line is heard in
// it. A book in which nobody is named shows no such entry. The reader's
// listening sheet offers the same, and the reading stops for a line said.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingLayout;
import 'package:tomevoice_spike/neural_voices.dart' show wavBytes;
import 'package:tomevoice_spike/player_controls.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/reader_screen.dart';
import 'package:tomevoice_spike/scheduler.dart';
import 'package:tomevoice_spike/speakers.dart' show BookCast;
import 'package:tomevoice_spike/speech_service.dart';

late Directory _dir;

final _o = String.fromCharCode(0x201C);
final _c = String.fromCharCode(0x201D);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const tts = MethodChannel('tomevoice/tts');

  /// What the phone's voice was asked to say, and in which voice.
  final said = <({String text, String? voice})>[];

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('tomevoice_cast_sheet');
    ListeningPrefs.reset();
    MarkStore.instance.reset();
    SpeechService.resetQueue();
    said.clear();
    var n = 0;
    messenger.setMockMethodCallHandler(tts, (call) async {
      switch (call.method) {
        case 'listEngines':
          return [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ];
        case 'listVoices':
          return [
            for (final v in ['en-gb-x-gba-local', 'en-gb-x-gbb-local', 'en-gb-x-gbc-local'])
              {'name': v, 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
          ];
        case 'synthesise':
          final args = Map<String, Object?>.from(call.arguments as Map);
          said.add((text: args['text']! as String, voice: args['voiceName'] as String?));
          final f = File('${_dir.path}/s${n++}.wav')..writeAsBytesSync(wavBytes(Float32List(2400), 24000));
          return <String, Object?>{'wavPath': f.path, 'engineId': 'test', 'rangeEvents': const []};
        case 'outputDir':
          return _dir.path;
        case 'playerPosition':
        case 'playerEnqueue':
          return 0;
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(tts, null);
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  /// Let real file IO and isolates finish (and the clock move on, for a
  /// sample's length) until [until], then settle the frame.
  Future<void> settle(WidgetTester tester, {required bool Function() until, String Function()? what}) async {
    for (var i = 0; i < 160 && !until(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(until(), isTrue, reason: 'waited too long${what == null ? '' : ': ${what()}'}');
    await tester.pumpAndSettle();
  }

  bool quiet() => find.byType(CircularProgressIndicator).evaluate().isEmpty;

  /// A book of [text] in a fresh library, its page shown.
  Future<LibraryEntry> pumpBook(WidgetTester tester, String text) async {
    phone(tester);
    late LibraryStore store;
    late LibraryEntry entry;
    await tester.runAsync(() async {
      store = LibraryStore(_dir);
      final f = File('${_dir.path}/incoming/talk.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      entry = await store.importFile(PickedFile(path: f.path, name: 'talk.md'));
    });
    await tester.pumpWidget(MaterialApp(home: BookScreen(store: store, entry: entry)));
    return entry;
  }

  final talk = [
    '# Chapter 1',
    for (var i = 0; i < 6; i++) ...[
      '${_o}The gate is shut again tonight, and the watch is late,$_c said Zorian.',
      '${_o}Then we wait for the morning bell,$_c said Kirielle.',
    ],
    '# Chapter 2',
    'The rain went on until dawn, and nobody came along the road.',
  ].join('\n\n');

  testWidgets('who speaks, listed on the book page; a voice given to one is kept, and heard', (tester) async {
    final entry = await pumpBook(tester, talk);
    await settle(tester, until: () => find.text('CHARACTERS').evaluate().isNotEmpty && quiet());
    expect(find.text('CHARACTERS'), findsOneWidget, reason: 'the book page did not offer its characters');
    expect(find.text('2 speak, all in the dialogue voice'), findsOneWidget);

    await tester.tap(find.text('CHARACTERS'));
    await tester.pumpAndSettle();
    expect(find.text('Characters'), findsOneWidget);
    expect(find.text('Zorian'), findsOneWidget);
    expect(find.text('Kirielle'), findsOneWidget);
    expect(find.text('6 lines · Dialogue voice'), findsNWidgets(2));
    expect(find.byTooltip('Hear Zorian'), findsNothing, reason: 'a sample is offered for a voice given, not before');

    // Zorian in the narrator's voice.
    await tester.tap(find.text('Zorian'));
    await tester.pumpAndSettle();
    expect(find.text('Whose voice reads their lines'.toUpperCase()), findsOneWidget);
    expect(find.text('Dialogue voice'), findsOneWidget);
    expect(find.text('Narrator'), findsOneWidget);
    expect(find.text('VOICES'), findsOneWidget, reason: "the book's language's voices are offered");
    await tester.tap(find.text('Narrator'));
    // The sample said, and done with: its spinner come and gone.
    var spun = false;
    await settle(
      tester,
      until: () {
        if (!quiet()) spun = true;
        return said.isNotEmpty && spun && quiet();
      },
      what: () => 'asked to say ${said.length} lines, ${quiet() ? 'no spinner' : 'a spinner still turning'}',
    );
    final cast = ListeningPrefs.memory.castByBook[entry.id];
    expect(cast?.voices, {'Zorian': BookCast.narrator}, reason: 'the choice was not kept with the settings');
    expect(cast!.people.map((c) => c.name), containsAll(['Zorian', 'Kirielle']));
    expect(find.text("6 lines · Narrator's voice"), findsOneWidget);
    expect(find.byTooltip('Hear Zorian'), findsOneWidget);
    expect(said.first.text, contains('The gate is shut again tonight'), reason: "the sample is not Zorian's own line");

    // Back on the page, it says so.
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();
    expect(find.text('Zorian has a voice of their own'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a book in which nobody is named in a speech tag has no Characters', (tester) async {
    await pumpBook(tester, '# Chapter 1\n\n${'The road ran on for miles under the rain. ' * 20}');
    await settle(tester, until: () => find.text('Chapter 1').evaluate().isNotEmpty && quiet());
    // Time for the book to be read for its characters.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(find.text('VOICE FOR THIS BOOK'), findsOneWidget);
    expect(find.text('CHARACTERS'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group("the reader's listening sheet", () {
    /// A book of [text] in a fresh library, open in the reader (as a web
    /// novel's page, with [web]), the page settled and the book read for
    /// its characters; the book's id. (A line of its own makes it another
    /// book than the page's above: who speaks is found once a run.)
    Future<String> openReader(WidgetTester tester, String text, {bool web = false}) async {
      phone(tester);
      late LibraryStore store;
      late LibraryEntry entry;
      late ReadingLayout layout;
      await tester.runAsync(() async {
        store = LibraryStore(_dir);
        final f = File('${_dir.path}/incoming/talk.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('$text\n\nThis copy is read in the reader.');
        entry = await store.importFile(PickedFile(path: f.path, name: 'talk.md'));
        layout = await store.loadLayout(entry.id);
      });
      await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
          layout: layout,
          store: store,
          onReachedEnd: web ? ({required bool playing, bool browse = false}) async {} : null,
        ),
      ));
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      return entry.id;
    }

    /// The listening sheet, down to its reading rules.
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Voice'));
      await tester.pumpAndSettle();
      final sheet = find.descendant(of: find.byKey(const Key('reader-settings')), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.byIcon(Icons.rule_rounded), 300, scrollable: sheet);
      await tester.pumpAndSettle();
    }

    testWidgets("offers the book's characters, as its page does; a line said there stops the reading first",
        (tester) async {
      final id = await openReader(tester, talk);
      // Read aloud a moment, then paused.
      final player = tester.widget<PlayButton>(find.byType(PlayButton)).player;
      await tester.tap(find.byTooltip('Play'));
      for (var i = 0; i < 40 && player.state.value != PlayState.playing; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump(const Duration(seconds: 1));
      expect(player.state.value, PlayState.paused);

      await openSheet(tester);
      final card = find.ancestor(of: find.text('Characters'), matching: find.byType(InkWell));
      expect(card, findsOneWidget, reason: 'the sheet did not offer the characters');
      expect(find.text('2 speak, all in the dialogue voice'), findsOneWidget);
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('Zorian'), findsOneWidget);
      expect(find.text('Kirielle'), findsOneWidget);

      // Zorian in the narrator's voice: his own line said in it, once the
      // reading has stopped for it. (Paused, the reading may still make the
      // sentences after it, his lines among them.)
      var stopped = -1;
      void onStop() {
        if (player.state.value == PlayState.idle && stopped < 0) stopped = said.length;
      }

      player.state.addListener(onStop);
      bool his() => stopped >= 0 && said.skip(stopped).any((s) => s.text.contains('The gate is shut again tonight'));
      await tester.tap(find.text('Zorian'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Narrator'));
      // The line said, and done with: its spinner come and gone.
      var spun = false;
      await settle(
        tester,
        until: () {
          if (!quiet()) spun = true;
          return his() && spun && quiet();
        },
        what: () => '${said.length} said, stopped at $stopped',
      );
      player.state.removeListener(onStop);
      expect(player.state.value, PlayState.idle, reason: 'the reading went on under the line said');
      expect(ListeningPrefs.memory.castByBook[id]?.voices, {'Zorian': BookCast.narrator});

      // Back in the listening sheet, it says so.
      Navigator.of(tester.element(find.text('Zorian'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Zorian has a voice of their own'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('offers none for a book in which nobody is named, nor for a web novel', (tester) async {
      await openReader(tester, '# Chapter 1\n\n${'The road ran on for miles under the rain. ' * 20}');
      await openSheet(tester);
      expect(find.text('Characters'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));

      await openReader(tester, talk, web: true);
      await openSheet(tester);
      expect(find.text('Characters'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
