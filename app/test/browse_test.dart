// Web novels on screen: Browse before any source is installed, the Sources
// screen, and a stored novel's page. No network: what the page shows comes
// from the copy on the phone.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/browse_screen.dart';
import 'package:tomevoice_spike/browser_check.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/novel_screen.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/sources_screen.dart';

const _channel = MethodChannel('tomevoice/tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_browse');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, bool Function() until) async {
    for (var i = 0; i < 60 && !until(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Browse with no sources says how to get some', (tester) async {
    phone(tester);
    final store = LibraryStore(tmp);
    final sources = SourceStore(tmp);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BrowseScreen(store: store, sources: sources))));
    await settle(tester, () => find.text('Find web novels').evaluate().isNotEmpty);

    expect(find.text('Find web novels'), findsOneWidget);
    await tester.tap(find.text('Add sources'));
    await settle(tester, () => find.byType(SourcesScreen).evaluate().isNotEmpty);
    expect(find.byType(SourcesScreen), findsOneWidget);
    expect(find.text('Add a source list'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stored web novel shows its chapters, and which are on the phone', (tester) async {
    phone(tester);
    final store = LibraryStore(tmp);
    const plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
    await tester.runAsync(() async {
      await store.addWebNovel(
        plugin,
        SourceNovel(
          path: 'novel/1',
          name: 'Shadow',
          author: 'Writer',
          summary: 'A story about shadows.',
          status: 'Ongoing',
          genres: const ['Fantasy'],
          chapters: [for (var i = 0; i < 4; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'ch/$i')],
        ),
      );
      final id = LibraryStore.webId('fake', 'novel/1');
      await store.saveChapter(id, 0, 'Chapter 1', '<p>Chapter 1</p><p>Words to read in the first chapter.</p>');
    });

    await tester.pumpWidget(MaterialApp(
      home: NovelScreen(store: store, plugin: plugin, path: 'novel/1', name: 'Shadow'),
    ));
    await settle(tester, () => find.text('Chapter 4').evaluate().isNotEmpty);

    expect(find.text('Shadow'), findsWidgets);
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('In your library'), findsOneWidget);
    expect(find.text('Listen'), findsOneWidget);
    for (var i = 1; i <= 4; i++) {
      expect(find.text('Chapter $i'), findsOneWidget);
    }
    expect(find.byIcon(Icons.offline_pin_rounded), findsOneWidget, reason: 'only chapter 1 is downloaded');

    // Newest first, on a tap.
    await tester.tap(find.byTooltip('Newest first'));
    await tester.pump();
    final first = tester.getTopLeft(find.text('Chapter 4')).dy;
    final last = tester.getTopLeft(find.text('Chapter 1')).dy;
    expect(first, lessThan(last));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a site's browser check opens, and its cookies are kept for the retry", (tester) async {
    phone(tester);
    final asked = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      asked.add(call);
      return call.method == 'browserCheck' ? 'cf_clearance=abc; theme=dark' : null;
    });
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SourceProblem(
          error: ChallengeException('https://www.royalroad.com/fictions/search?title=x'),
          onRetry: () => retried++,
        ),
      ),
    ));
    expect(find.text('A quick check first'), findsOneWidget);
    expect(find.textContaining('www.royalroad.com wants a quick browser check'), findsOneWidget);
    await tester.tap(find.text('Open the check'));
    await tester.pumpAndSettle();
    final check = asked.singleWhere((c) => c.method == 'browserCheck');
    expect((check.arguments as Map)['userAgent'], Net.userAgent);
    expect(retried, 1);
    expect(Net.instance.cookieHeader('www.royalroad.com'), contains('cf_clearance=abc'));
    await Net.instance.clearCookies();
  });

  testWidgets('a novel whose source is not installed offers to install it', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SourceProblem(error: MissingSourceException('novelhall', 'Novel Hall'), onRetry: () {}),
      ),
    ));
    expect(find.text('Needs its source'), findsOneWidget);
    expect(find.text('Install Novel Hall'), findsOneWidget);
    expect(find.textContaining('already on the phone still read'), findsOneWidget);
  });
}
