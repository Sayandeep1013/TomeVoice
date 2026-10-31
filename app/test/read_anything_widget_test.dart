// The library's ways in for anything to read: Add books > Paste a link or
// text, and words or a link shared to TomeVoice while it runs or as it
// starts. Each arrives the way an opened file does: on its shelf, with its
// page open.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/book_screen.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/main.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/shared_text.dart';
import 'package:tomevoice_spike/speech_service.dart';

const _channel = MethodChannel('tomevoice/tts');

late Directory _tmp;
Map<String, Object?>? _pendingShare;
String? _clipboard;
var _clipboardReads = 0;

/// What MainActivity does when something is shared to the running app: it
/// keeps the share as pending and sends it as an event.
Future<void> _share(Map<String, Object?> share) {
  _pendingShare = share;
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'tomevoice/tts',
    const StandardMethodCodec().encodeMethodCall(MethodCall('platformEvent', {'type': 'sharedText', ...share})),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MarkStore.instance.reset();
    _tmp = Directory.systemTemp.createTempSync('tv_read_anything');
    ListeningPrefs.reset();
    SpeechService.resetQueue();
    resetShareQueue();
    _pendingShare = null;
    _clipboard = null;
    _clipboardReads = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'outputDir':
          return _tmp.path;
        case 'launchArgs':
          return <String, Object?>{};
        case 'listEngines':
          return [
            {'name': 'com.google.android.tts', 'label': 'Google TTS'},
          ];
        case 'listVoices':
          return [
            {'name': 'en-gb-x-gba-local', 'locale': 'en-GB', 'quality': 300, 'networkRequired': false, 'installed': true},
          ];
        case 'pendingShare':
          final share = _pendingShare;
          _pendingShare = null;
          return share;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        _clipboardReads++;
        return _clipboard == null ? null : {'text': _clipboard};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  /// Let real file IO and isolates run until [until] (each isolate a book
  /// is parsed on takes a while to start in a debug test), then settle. The
  /// clock moves too: a book's page fills in once it has slid in.
  Future<void> settle(WidgetTester tester, bool Function() until) async {
    for (var i = 0; i < 1200 && !until(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(until(), isTrue, reason: 'waited 30 s');
    await tester.pumpAndSettle();
  }

  bool emptyShelf() => find.text('Your shelf is empty').evaluate().isNotEmpty;

  /// A book's page, its book loaded (finding a chapter is offered only then).
  bool bookOpen() =>
      find.byType(BookScreen).evaluate().isNotEmpty && find.byTooltip('Find a chapter').evaluate().isNotEmpty;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  Future<List<LibraryEntry>> books(WidgetTester tester) async =>
      (await tester.runAsync(() => LibraryStore(_tmp).list(all: true)))!;

  testWidgets('Add books > Paste a link or text asks first, then reads the words as a book', (tester) async {
    phone(tester);
    _clipboard = 'Words to listen to\n\nThe first paragraph of something copied from a notes app, long enough to read.';
    await tester.pumpWidget(const SpikeApp());
    await settle(tester, emptyShelf);

    // The + is a menu now: books on the phone, or something to paste.
    await tester.tap(find.byTooltip('Add books'));
    await tester.pumpAndSettle();
    expect(find.text('Books on this phone'), findsOneWidget);
    await tester.tap(find.text('Paste a link or text'));
    await tester.pumpAndSettle();
    expect(find.text('Paste what you copied?'), findsOneWidget);
    expect(_clipboardReads, 0, reason: 'the clipboard is not read before asking');

    // Cancelled: nothing read.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_clipboardReads, 0);

    await tester.tap(find.byTooltip('Add books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste a link or text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await settle(tester, bookOpen);
    expect(_clipboardReads, 1);
    expect(find.byType(BookScreen), findsOneWidget);
    expect(find.text('Words to listen to'), findsWidgets);
    final shelf = await books(tester);
    expect(shelf.single.title, 'Words to listen to');
    await finish(tester);
  });

  testWidgets('an empty clipboard says so, and makes nothing', (tester) async {
    phone(tester);
    await tester.pumpWidget(const SpikeApp());
    await settle(tester, emptyShelf);
    // The empty shelf's own button opens the same menu.
    await tester.tap(find.text('Add books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste a link or text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to paste. Copy a link or some text first.'), findsOneWidget);
    expect(await books(tester), isEmpty);
    await finish(tester);
  });

  testWidgets('words shared while TomeVoice runs arrive as an opened file does, once', (tester) async {
    phone(tester);
    await tester.pumpWidget(const SpikeApp());
    await settle(tester, emptyShelf);
    const share = {
      'id': 'share-1',
      'text': 'Shared from a notes app\n\nA few sentences somebody chose and shared to TomeVoice to hear them read.',
      'subject': '',
    };
    await _share(share);
    await settle(tester, bookOpen);
    expect(find.text('Shared from a notes app'), findsWidgets);
    expect(_pendingShare, isNull, reason: 'the pending copy was taken, so it is not read again later');

    // The same share again is not read twice.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await _share(share);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(BookScreen), findsNothing);
    expect(await books(tester), hasLength(1));
    await finish(tester);
  });

  testWidgets('a share that started the app is read once the shelf is up', (tester) async {
    phone(tester);
    _pendingShare = {
      'id': 'launch',
      'text': 'Started with words\n\nSome words that opened the app, long enough to be read aloud to someone.',
      'subject': 'Ignored for words',
    };
    await tester.pumpWidget(const SpikeApp());
    await settle(tester, bookOpen);
    expect(find.byType(BookScreen), findsOneWidget);
    expect(find.text('Started with words'), findsWidgets);
    await finish(tester);
  });

  testWidgets('a link already read opens its article at once, with no network', (tester) async {
    phone(tester);
    await tester.runAsync(() async {
      final store = LibraryStore(_tmp);
      const page = '<html><body><h1>Known article</h1>'
          '<p>Text of an article read before, long enough to be a book of its own.</p></body></html>';
      await store.importMade(
        id: articleIdOf(Uri.parse('https://news.example/a')),
        name: 'Known article.html',
        bytes: Uint8List.fromList(utf8.encode(page)),
        category: await articleShelf(store),
      );
    });
    await tester.pumpWidget(const SpikeApp());
    // Its shelf, made for it.
    await settle(tester, () => find.text('Articles').evaluate().isNotEmpty);
    await _share({
      'id': 'again',
      'text': 'https://www.news.example/a/?utm_source=share',
      'subject': 'Known article',
    });
    await settle(tester, bookOpen);
    expect(find.text('Known article'), findsWidgets);
    expect(await books(tester), hasLength(1));
    await finish(tester);
  });
}
