// Signing in to a source's site in the app's web view: what the site sets
// is kept in that source's own cookies, and no other source's (nor the
// app's own requests').

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/browse_screen.dart';
import 'package:tomevoice_spike/browser_check.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';

const _sources = MethodChannel('tomevoice/sources');
const _tts = MethodChannel('tomevoice/tts');

const _plugin = PluginInfo(id: 'fake', name: 'Fake Site', site: 'https://www.fake.site/', lang: 'English', version: '1', url: 'u');

/// A site whose popular page is asked for, counted.
class _Site extends SourceEngine {
  _Site() : super.forTests();

  var asked = 0;

  @override
  Future<List<NovelItem>> popular(PluginInfo p, int page, {bool latest = false, Map<String, Object?>? filters}) async {
    asked++;
    return page == 1 ? const [NovelItem(name: 'Shadow', path: 'novel/1')] : const [];
  }

  @override
  Future<Map<String, Object?>> meta(PluginInfo p) async => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final asked = <MethodCall>[];
  Map<String, Object?>? answer;

  /// What the web view hands back for a browser check.
  Map<String, Object?>? checked;

  setUp(() {
    asked.clear();
    // "theme" is set for the whole site; "session" for its host alone.
    answer = {'cookies': 'session=abc; theme=dark', 'wide': 'theme=dark'};
    checked = null;
    Net.instance.jar.clear();
    messenger.setMockMethodCallHandler(_sources, (call) async {
      asked.add(call);
      return call.method == 'browserLogin' ? answer : null;
    });
    messenger.setMockMethodCallHandler(_tts, (call) async {
      asked.add(call);
      return call.method == 'browserCheck' ? checked : null;
    });
  });

  /// The cookies [partition] sends [url].
  Set<String>? header(String url, String partition) =>
      Net.instance.cookieHeader(url, partition: partition)?.split('; ').toSet();

  /// The cookies a call put in the web view before it loaded, by name.
  Map<String, String> seeded(MethodCall call) => {
        for (final c in (call.arguments as Map)['cookies'] as List)
          if (((c as Map)['cookie'] as String).split(';').first.split('=') case [final name, final value]) name: value,
      };

  tearDown(() {
    messenger.setMockMethodCallHandler(_sources, null);
    messenger.setMockMethodCallHandler(_tts, null);
    Net.instance.jar.clear();
  });

  Future<bool?> signIn(WidgetTester tester) async {
    bool? out;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => out = await signInToSite(context, _plugin),
            child: const Text('Sign in'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();
    return out;
  }

  testWidgets("a sign-in's cookies go to that source alone", (tester) async {
    expect(await signIn(tester), isTrue);
    final call = asked.singleWhere((c) => c.method == 'browserLogin');
    expect((call.arguments as Map)['url'], 'https://www.fake.site/');
    expect((call.arguments as Map)['userAgent'], Net.userAgent);
    expect((call.arguments as Map)['domain'], 'fake.site');

    expect(header('https://www.fake.site/fiction/1', 'fake'), {'session=abc', 'theme=dark'});
    expect(header('https://fake.site/fiction/1', 'fake'), {'theme=dark'},
        reason: 'the one set for the whole site goes there; the one for its host alone stays there');
    expect(Net.instance.cookieHeader('http://www.fake.site/fiction/1', partition: 'fake'), isNull,
        reason: 'taken from an https page: over https only');
    expect(Net.instance.cookieHeader('https://www.fake.site/fiction/1', partition: 'other'), isNull);
    expect(Net.instance.cookieHeader('https://www.fake.site/fiction/1'), isNull, reason: "not the app's own requests'");
    expect(Net.instance.cookieHeader('https://elsewhere.site/', partition: 'fake'), isNull, reason: 'only its site');
    expect(find.textContaining('Signed in to Fake Site'), findsOneWidget);
  });

  testWidgets("one source's sign-in is never in the web view for another's browser check", (tester) async {
    // Source "fake" is signed in; "other" reads the same site.
    expect(await signIn(tester), isTrue);
    await tester.runAsync(() => Net.instance.keepFromBrowser(
        Uri.parse('https://www.fake.site/'), {'cookies': 'pref=big'}, partition: 'other'));
    asked.clear();

    // "other" meets a check there. The web view holds its cookies alone, so
    // fake's session cannot pass it; the clearance goes to "other" alone.
    checked = {'cookies': 'pref=big; cf_clearance=xyz', 'wide': 'cf_clearance=xyz'};
    bool? passed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                passed = await passBrowserCheck(context, ChallengeException('https://www.fake.site/x', pluginId: 'other')),
            child: const Text('Check'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Check'));
    for (var i = 0; i < 20 && passed == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(passed, isTrue);
    final check = asked.singleWhere((c) => c.method == 'browserCheck');
    expect(seeded(check), {'pref': 'big'}, reason: "the source's own cookies, not the signed-in one's");
    expect(header('https://www.fake.site/', 'other'), {'pref=big', 'cf_clearance=xyz'});
    expect(header('https://www.fake.site/', 'fake'), {'session=abc', 'theme=dark'},
        reason: "the check's clearance is not copied to the signed-in source");

    // Signing in again starts from that source's own cookies, which the
    // web view is handed before the page loads.
    asked.clear();
    expect(await signIn(tester), isTrue);
    expect(seeded(asked.singleWhere((c) => c.method == 'browserLogin')), {'session': 'abc', 'theme': 'dark'});

    // Cleared for one, gone from it alone.
    await tester.runAsync(() => Net.instance.clearCookies(partition: 'fake'));
    expect(Net.instance.cookieHeader('https://www.fake.site/', partition: 'fake'), isNull);
    expect(Net.instance.cookieHeader('https://www.fake.site/', partition: 'other'), contains('cf_clearance=xyz'));
  });

  testWidgets('closed without Done, nothing is kept', (tester) async {
    answer = null;
    expect(await signIn(tester), isFalse);
    expect(Net.instance.cookieHeader('https://www.fake.site/', partition: 'fake'), isNull);
  });

  testWidgets("a page through the hidden web view: the source's cookies alone, and what the site sets kept for it",
      (tester) async {
    await tester.runAsync(() async {
      await Net.instance.keepFromBrowser(Uri.parse('https://www.fake.site/'), {'cookies': 'session=abc'}, partition: 'fake');
      await Net.instance.keepFromBrowser(Uri.parse('https://www.fake.site/'), {'cookies': 'mine=1'}, partition: 'other');
    });
    messenger.setMockMethodCallHandler(_sources, (call) async {
      asked.add(call);
      return call.method == 'browserFetch'
          ? {
              'html': '<p>The novel</p>',
              'url': 'https://www.fake.site/novel/1',
              'cookies': 'session=abc; cf_clearance=new',
              'wide': 'cf_clearance=new',
            }
          : null;
    });
    final page = (await tester.runAsync(() => Net.instance.viaWebView('https://www.fake.site/n?id=1', partition: 'fake')))!;
    expect((page.html, page.url), ('<p>The novel</p>', 'https://www.fake.site/novel/1'));
    final call = asked.singleWhere((c) => c.method == 'browserFetch');
    expect(((call.arguments as Map)['url'], (call.arguments as Map)['method']), ('https://www.fake.site/n?id=1', 'GET'));
    expect(seeded(call), {'session': 'abc'}, reason: "fake's own, not other's");
    expect(header('https://www.fake.site/', 'fake'), {'session=abc', 'cf_clearance=new'});
    expect(header('https://www.fake.site/', 'other'), {'mine=1'});
  });

  testWidgets("from a source's page, and its novels asked for again once signed in", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final before = SourceEngine.instance;
    final site = _Site();
    SourceEngine.instance = site;
    addTearDown(() => SourceEngine.instance = before);
    final dir = Directory.systemTemp.createTempSync('tv_login');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.pumpWidget(MaterialApp(home: SourceScreen(store: LibraryStore(dir), plugin: _plugin)));
    await tester.pumpAndSettle();
    expect(find.text('Shadow'), findsOneWidget);
    final before0 = site.asked;
    await tester.tap(find.byTooltip('Sign in to Fake Site'));
    await tester.pumpAndSettle();
    expect(asked.where((c) => c.method == 'browserLogin'), hasLength(1));
    expect(site.asked, greaterThan(before0));
    expect(Net.instance.cookieHeader('https://www.fake.site/', partition: 'fake'), contains('session=abc'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
  });
}
