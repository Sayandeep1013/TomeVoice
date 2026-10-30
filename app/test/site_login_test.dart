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
  String? answer;

  setUp(() {
    asked.clear();
    answer = 'session=abc; theme=dark';
    Net.instance.jar.clear();
    messenger.setMockMethodCallHandler(_sources, (call) async {
      asked.add(call);
      return call.method == 'browserLogin' ? answer : null;
    });
    messenger.setMockMethodCallHandler(_tts, (call) async => null);
  });

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

    expect(Net.instance.cookieHeader('https://www.fake.site/fiction/1', partition: 'fake'), contains('session=abc'));
    expect(Net.instance.cookieHeader('https://fake.site/fiction/1', partition: 'fake'), contains('session=abc'),
        reason: 'the site, with or without www');
    expect(Net.instance.cookieHeader('https://www.fake.site/fiction/1', partition: 'other'), isNull);
    expect(Net.instance.cookieHeader('https://www.fake.site/fiction/1'), isNull, reason: "not the app's own requests'");
    expect(Net.instance.cookieHeader('https://elsewhere.site/', partition: 'fake'), isNull, reason: 'only its site');
    expect(find.textContaining('Signed in to Fake Site'), findsOneWidget);
  });

  testWidgets('closed without Done, nothing is kept', (tester) async {
    answer = null;
    expect(await signIn(tester), isFalse);
    expect(Net.instance.cookieHeader('https://www.fake.site/', partition: 'fake'), isNull);
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
