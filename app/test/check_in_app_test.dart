// The closed-app check while TomeVoice is only in the background: its
// worker finds the app's engine up (Back keeps it) and, rather than start a
// second engine, asks that one to check ("runCheck" on the sources channel),
// then posts what it says. Here the platform side is a fake channel.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/home_shell.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/sources/bridge.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';

const _tts = MethodChannel('tomevoice/tts');
const _sources = MethodChannel('tomevoice/sources');
const _codec = StandardMethodCodec();

/// Sites as the tests make them up: each novel's list by path, asked counted.
class _Sites extends SourceEngine {
  _Sites() : super.forTests();

  final lists = <String, List<ChapterItem>>{};
  var asked = 0;

  @override
  Future<SourceNovel> novel(PluginInfo p, String path) async {
    asked++;
    return SourceNovel(path: path, name: path, chapters: lists[path] ?? const []);
  }
}

class _Installed extends SourceStore {
  _Installed(super.root, this.plugins) : super(defaults: const []);

  final List<PluginInfo> plugins;

  @override
  Future<List<PluginInfo>> installed() async => plugins;

  @override
  Future<PluginInfo?> installedById(String id) async => plugins.where((p) => p.id == id).firstOrNull;
}

const _plugin =
    PluginInfo(id: 's', name: 'Site s', site: 'https://s.test/', lang: 'English', version: '1', url: 'https://x/s.js');

List<ChapterItem> _chapters(String novel, int n) => [for (var i = 1; i <= n; i++) ChapterItem(name: 'Chapter $i', path: '$novel/$i')];

/// The platform's call to Dart, as NovelCheckWorker makes it through
/// SourcesBridge.askAppToCheck: its answer, or null for "not implemented".
Future<Object?> fromPlatform(String method) async {
  final reply = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_sources.name, _codec.encodeMethodCall(MethodCall(method)), reply.complete);
  final data = await reply.future;
  return data == null ? null : _codec.decodeEnvelope(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_tts, null);
    messenger.setMockMethodCallHandler(_sources, null);
    LibraryStore.secretOpen.value = false;
  });

  test('the worker\'s "runCheck" is answered with what the check says to tell the reader', () async {
    var checks = 0;
    SourcesBridge.answerChecks(() async {
      checks++;
      return {'found': 2, 'title': 'Shadow', 'text': '2 new chapters', 'lines': ['Shadow: 2 new chapters']};
    });
    final answer = await fromPlatform('runCheck') as Map;
    expect(checks, 1);
    expect(answer['found'], 2);
    expect(answer['lines'], ['Shadow: 2 new chapters']);
    expect(await fromPlatform('somethingElse'), isNull, reason: 'not implemented: the worker posts nothing');
  });

  group("the app's engine checks, as asked", () {
    late Directory tmp;
    late SourceEngine before;
    late _Sites sites;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tv_check_in_app');
      ListeningPrefs.reset();
      before = SourceEngine.instance;
      sites = _Sites();
      SourceEngine.instance = sites;
      messenger.setMockMethodCallHandler(_tts, (call) async => call.method == 'outputDir' ? tmp.path : null);
      // The app's calls to the platform: none answered (no Wi-Fi said, no
      // web view, the library where the test put it).
      messenger.setMockMethodCallHandler(_sources, (call) async => null);
      SourcesBridge.answerChecks(checkInApp);
    });

    tearDown(() {
      SourceEngine.instance = before;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    /// The library the app has open, with novels at site s (each [n]
    /// chapters on the phone's list; the site has [more] besides).
    Future<OpenLibrary> library(Map<String, int> novels, {int more = 2}) async {
      final open = await openLibrary();
      sites.attach(_Installed(open.sources.dir, [_plugin]));
      for (final MapEntry(key: path, value: n) in novels.entries) {
        await open.store.addWebNovel(_plugin, SourceNovel(path: path, name: 'Novel $path', chapters: _chapters(path, n)));
        sites.lists[path] = _chapters(path, n + more);
      }
      return open;
    }

    test("in the app's own engine, onto its own index; then not again so soon", () async {
      final open = await library({'a': 3, 'b': 3});
      final answer = await fromPlatform('runCheck') as Map;
      expect(answer['found'], 4);
      expect(answer['title'], '4 new chapters');
      expect(answer['text'], allOf(contains('Novel a'), contains('Novel b')));
      // The check was this engine's: the shelf's own index has the new counts.
      expect([for (final e in await open.store.list()) e.chapterCount], [5, 5]);
      expect(await open.updates.lastChecked(), isNotNull);

      // Asked again a moment later (the app checked meanwhile): the sites are left alone.
      final asked = sites.asked;
      expect((await fromPlatform('runCheck') as Map)['found'], 0);
      expect(sites.asked, asked);
    });

    test('a novel on a secret shelf is not named, though the shelf is open in the app', () async {
      final open = await library({'a': 3});
      final id = (await open.store.list(all: true)).single.id;
      final shelf = await open.store.addCategory('Hidden', secret: true);
      await open.store.moveBooks({id}, shelf.id);
      LibraryStore.secretOpen.value = true;
      final answer = await fromPlatform('runCheck') as Map;
      expect(answer['found'], 2);
      expect(answer['title'], 'A novel');
      expect('$answer', isNot(contains('Novel a')));
    });

    test('checks turned off: nothing is asked of the sites', () async {
      await library({'a': 3});
      ListeningPrefs.loaded!.updateEvery = 'off';
      expect((await fromPlatform('runCheck') as Map)['found'], 0);
      expect(sites.asked, 0);
    });
  });
}
