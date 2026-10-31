// Web novels on screen: Browse before any source is installed, the Sources
// screen, and a stored novel's page. No network: what the page shows comes
// from the copy on the phone.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/browse_screen.dart';
import 'package:tomevoice_spike/browser_check.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/novel_screen.dart';
import 'package:tomevoice_spike/plugin_options.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/sources_screen.dart';

const _channel = MethodChannel('tomevoice/tts');

/// Sources as the tests make them up: [novels] by path.
class _FakeEngine extends SourceEngine {
  _FakeEngine(this.novels) : super.forTests();

  final Map<String, SourceNovel> novels;

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async =>
      novels[path] ?? (throw SourceException('No such novel.'));

  /// Sources asked in a global search; "slow" never answers.
  final searched = <String>[];

  @override
  Future<List<NovelItem>> search(PluginInfo p, String query, int page) async {
    searched.add(p.id);
    if (p.id == 'slow') return Completer<List<NovelItem>>().future;
    return [NovelItem(name: '$query at ${p.name}', path: 'novel/1')];
  }
}

/// Installed sources as the tests make them up, nothing on disk.
class _FakeSources extends SourceStore {
  _FakeSources(super.root, this.plugins) : super(defaults: const []);

  final List<PluginInfo> plugins;

  @override
  Future<List<PluginInfo>> installed() async => plugins;

  @override
  Future<PluginInfo?> installedById(String id) async => plugins.where((p) => p.id == id).firstOrNull;
}

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
    final sources = SourceStore(tmp, defaults: const []);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BrowseScreen(store: store, sources: sources))));
    await settle(tester, () => find.text('Find web novels').evaluate().isNotEmpty);

    expect(find.text('Find web novels'), findsOneWidget);
    await tester.tap(find.text('Install sources'));
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
    // Every other chapter has its own download button.
    for (var i = 2; i <= 4; i++) {
      expect(find.byTooltip('Download chapter $i'), findsOneWidget);
    }
    expect(find.byTooltip('Download chapter 1'), findsNothing);

    // Newest first, on a tap.
    await tester.tap(find.byTooltip('Newest first'));
    await tester.pump();
    final first = tester.getTopLeft(find.text('Chapter 4')).dy;
    final last = tester.getTopLeft(find.text('Chapter 1')).dy;
    expect(first, lessThan(last));
    // The order is kept for this novel, and for novels not turned yet.
    final prefs = ListeningPrefs.memory;
    expect(prefs.newestFirstFor(LibraryStore.webId('fake', 'novel/1')), isTrue);
    expect(prefs.newestFirstFor('web-another'), isTrue);
    await tester.pumpWidget(const SizedBox());
    // Let the debounced save of prefs run.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a novel on a shut secret shelf shows as not in the library until the lock is given', (tester) async {
    phone(tester);
    var confirmed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'confirmUser') {
        confirmed = true;
        return true;
      }
      return null;
    });
    addTearDown(() => LibraryStore.secretOpen.value = false);
    final store = LibraryStore(tmp);
    const plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
    final id = LibraryStore.webId('fake', 'novel/1');
    // The site, as the page asks it: the novel, its chapters a little renamed.
    final engine = _FakeEngine({
      'novel/1': SourceNovel(
        path: 'novel/1',
        name: 'Shadow',
        chapters: [for (var i = 0; i < 4; i++) ChapterItem(name: 'Chapter ${i + 1} (site)', path: 'ch/$i')],
      ),
    });
    final before = SourceEngine.instance;
    SourceEngine.instance = engine;
    addTearDown(() => SourceEngine.instance = before);
    engine.attach(_FakeSources(tmp, [plugin]));
    await tester.runAsync(() async {
      await store.addWebNovel(
        plugin,
        SourceNovel(
          path: 'novel/1',
          name: 'Shadow',
          chapters: [for (var i = 0; i < 4; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'ch/$i')],
        ),
      );
      await store.saveChapter(id, 0, 'Chapter 1', '<p>Words to read in the first chapter.</p>');
      final secret = await store.addCategory('Hidden', secret: true);
      await store.moveBooks({id}, secret.id);
    });
    LibraryStore.secretOpen.value = false;

    await tester.pumpWidget(MaterialApp(
      home: NovelScreen(store: store, plugin: plugin, path: 'novel/1', name: 'Shadow'),
    ));
    await settle(tester, () => find.text('Chapter 4 (site)').evaluate().isNotEmpty);
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.text('In your library'), findsNothing);
    expect(find.text('Listen'), findsOneWidget, reason: 'no Continue');
    expect(find.byIcon(Icons.offline_pin_rounded), findsNothing, reason: 'no download is shown');
    expect(find.text('Chapter 1'), findsNothing, reason: 'the stored chapter list is not shown either');

    // Add to library asks for the lock, then shows the stored novel; no copy is made.
    await tester.tap(find.text('Add to library'));
    await settle(tester, () => find.text('In your library').evaluate().isNotEmpty);
    expect(confirmed, isTrue);
    expect(find.text('In your library'), findsOneWidget);
    expect(find.byIcon(Icons.offline_pin_rounded), findsOneWidget);
    expect((await tester.runAsync(() => store.list(all: true)))!.where((e) => e.isWeb), hasLength(1));

    // Shut again (as on leaving the app): hidden again.
    LibraryStore.secretOpen.value = false;
    await settle(tester, () => find.text('Add to library').evaluate().isNotEmpty);
    expect(find.byIcon(Icons.offline_pin_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a site's browser check opens, and its cookies are kept for the retry", (tester) async {
    phone(tester);
    final asked = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      asked.add(call);
      return call.method == 'browserCheck' ? {'cookies': 'cf_clearance=abc; theme=dark', 'wide': 'cf_clearance=abc'} : null;
    });
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SourceProblem(
          error: ChallengeException('https://www.royalroad.com/fictions/search?title=x', pluginId: 'royalroad'),
          onRetry: () => retried++,
        ),
      ),
    ));
    expect(find.text('A quick check first'), findsOneWidget);
    expect(find.textContaining('www.royalroad.com wants a quick browser check'), findsOneWidget);
    await tester.tap(find.text('Open the check'));
    // Real time too: keeping the cookies writes a file.
    await settle(tester, () => retried > 0);
    final check = asked.singleWhere((c) => c.method == 'browserCheck');
    expect((check.arguments as Map)['userAgent'], Net.userAgent);
    expect((check.arguments as Map)['cookies'], isEmpty,
        reason: "the web view holds that source's cookies alone, and it has none yet");
    expect((check.arguments as Map)['domain'], 'royalroad.com');
    expect(retried, 1);
    expect(Net.instance.cookieHeader('https://www.royalroad.com/fictions', partition: 'royalroad'),
        contains('cf_clearance=abc'));
    expect(Net.instance.cookieHeader('https://royalroad.com/fictions', partition: 'royalroad'), 'cf_clearance=abc',
        reason: "the clearance is the whole site's; the other cookie its host's alone");
    expect(Net.instance.cookieHeader('http://www.royalroad.com/fictions', partition: 'royalroad'), isNull,
        reason: 'from an https page: over https only');
    expect(Net.instance.cookieHeader('https://www.royalroad.com/fictions', partition: 'another'), isNull,
        reason: 'kept for the source that met the check, not every source');
    await Net.instance.clearCookies();
  });

  testWidgets("Sources clears the sites' cookies, the app's and the web view's", (tester) async {
    phone(tester);
    const sources = MethodChannel('tomevoice/sources');
    final asked = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(sources, (call) async {
      asked.add(call);
      return null;
    });
    addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(sources, null));
    await tester.runAsync(
        () => Net.instance.keepFromBrowser(Uri.parse('https://www.site.test/'), {'cookies': 'sid=1'}, partition: 'site'));
    await tester.pumpWidget(MaterialApp(home: SourcesScreen(store: SourceStore(tmp, defaults: const []))));
    await settle(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await tester.tap(find.byTooltip('More'));
    await settle(tester, () => find.text('Clear site cookies').evaluate().isNotEmpty);
    await tester.tap(find.text('Clear site cookies'));
    await settle(tester, () => find.text('Clear').evaluate().isNotEmpty);
    await tester.tap(find.text('Clear'));
    await settle(tester, () => asked.any((c) => c.method == 'clearWebCookies'));
    expect((asked.singleWhere((c) => c.method == 'clearWebCookies').arguments as Map)['url'], isNull);
    expect(Net.instance.cookieHeader('https://www.site.test/', partition: 'site'), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("global search asks the reader's languages, can be stopped, and marks what is in the library",
      (tester) async {
    phone(tester);
    PluginInfo source(String id, String lang) =>
        PluginInfo(id: id, name: 'Site $id', site: 'https://$id.test/', lang: lang, version: '1', url: 'u');
    final plugins = [source('fast', 'English'), source('slow', 'English'), source('ru', 'Русский')];
    final engine = _FakeEngine(const {});
    final before = SourceEngine.instance;
    SourceEngine.instance = engine;
    addTearDown(() => SourceEngine.instance = before);
    final store = LibraryStore(tmp);
    await tester.runAsync(() => store.addWebNovel(plugins.first, const SourceNovel(path: 'novel/1', name: 'Kept')));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BrowseScreen(store: store, sources: _FakeSources(tmp, plugins))),
    ));
    await settle(tester, () => find.text('Site fast').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), 'dragon');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester, () => find.text('Stop').evaluate().isNotEmpty);
    expect(engine.searched.toSet(), {'fast', 'slow'}, reason: "the phone's language (English) only");
    expect(find.text('In library'), findsOneWidget, reason: 'the novel from fast is in the library');
    await tester.tap(find.text('Stop'));
    await settle(tester, () => find.text('Stopped.').evaluate().isNotEmpty);
    expect(find.text('SEARCHED 2 SOURCES'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // The stopped source's own wait runs out unseen.
    await tester.pump(const Duration(seconds: 21));
  });

  testWidgets("a source's filters are shown as it defines them, and chosen", (tester) async {
    phone(tester);
    Map<String, Object?>? got;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await showModalBottomSheet<Map<String, Object?>>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const PluginOptionsSheet(
                title: 'Filters',
                action: 'Show',
                definitions: {
                  'genre': {
                    'label': 'Genre',
                    'type': 'Picker',
                    'options': [
                      {'label': 'All', 'value': 'all'},
                      {'label': 'Fantasy', 'value': 'fantasy'},
                    ],
                  },
                  'tags': {
                    'label': 'Tags',
                    'type': 'XCheckbox',
                    'options': [
                      {'label': 'Magic', 'value': 'magic'},
                    ],
                  },
                  'done': {'label': 'Completed only', 'type': 'Switch'},
                },
                values: {'genre': 'all', 'tags': null, 'done': false},
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fantasy'));
    await tester.tap(find.text('Magic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Magic'));
    await tester.tap(find.text('Completed only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(got, {
      'genre': 'fantasy',
      'tags': {'include': <String>[], 'exclude': ['magic']},
      'done': true,
    });
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

  testWidgets('chapters can be picked by a long press, then downloaded or removed together', (tester) async {
    phone(tester);
    final store = LibraryStore(tmp);
    const plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
    final id = LibraryStore.webId('fake', 'novel/1');
    await tester.runAsync(() async {
      await store.addWebNovel(
        plugin,
        SourceNovel(
          path: 'novel/1',
          name: 'Shadow',
          chapters: [for (var i = 0; i < 4; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'ch/$i')],
        ),
      );
      await store.saveChapter(id, 0, 'Chapter 1', '<p>Words to read in the first chapter.</p>');
    });
    await tester.pumpWidget(MaterialApp(
      home: NovelScreen(store: store, plugin: plugin, path: 'novel/1', name: 'Shadow'),
    ));
    await settle(tester, () => find.text('Chapter 4').evaluate().isNotEmpty);

    await tester.longPress(find.text('Chapter 2'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Download 1'), findsOneWidget);

    // While picking, a tap adds a chapter instead of opening it.
    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Download 1'), findsOneWidget, reason: 'chapter 1 is on the phone already');

    await tester.tap(find.byTooltip('Remove 1 download'));
    await settle(tester, () => find.text('Removed the download.').evaluate().isNotEmpty);
    expect(store.hasChapter(id, 0), isFalse);
    expect(find.text('2 selected'), findsNothing);
    expect(find.byIcon(Icons.offline_pin_rounded), findsNothing);

    // Select all, then Cancel leaves picking without leaving the page.
    await tester.pump(const Duration(seconds: 6)); // the snack bar times out
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Chapter 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
