// Web-novel sources: the plugin host running a small LNReader-style plugin
// in QuickJS, through the real libraries bundle and shim, against a local
// HTTP server. Needs the native engine, so it runs on CI (Linux); on a
// machine without it the engine tests are skipped.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show SourceKind;
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/noveldokusha_import.dart';
import 'package:tomevoice_spike/sources/cookies.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/qjs_runtime.dart';
import 'package:tomevoice_spike/sources/sha256.dart';
import 'package:tomevoice_spike/sources/source_engine.dart';
import 'package:tomevoice_spike/sources/source_store.dart';
import 'package:tomevoice_spike/sources/source_updates.dart';

/// A plugin written the way the LNReader ones are (compiled CommonJS, ES5
/// style), using fetch, cheerio, storage and FormData.
const _plugin = r'''
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var fetch_1 = require("@libs/fetch");
var cheerio_1 = require("cheerio");
var storage_1 = require("@libs/storage");
var status_1 = require("@libs/novelStatus");
var Plugin = function () {
  function Plugin() { this.id = "fake"; this.name = "Fake"; this.version = "1.0.0"; this.site = SITE; this.icon = ""; }
  Plugin.prototype.popularNovels = function (page) {
    return this.searchNovels("", page);
  };
  Plugin.prototype.searchNovels = function (term, page) {
    var site = this.site;
    return fetch_1.fetchApi(site + "search?q=" + encodeURIComponent(term)).then(function (r) { return r.text(); }).then(function (html) {
      var $ = (0, cheerio_1.load)(html);
      var out = [];
      $("li.novel").each(function () {
        out.push({ name: $(this).find("a").text(), path: $(this).find("a").attr("href"), cover: $(this).find("img").attr("src") });
      });
      return out;
    });
  };
  Plugin.prototype.parseNovel = function (path) {
    var site = this.site;
    storage_1.storage.set("last", path);
    var fd = new FormData(); fd.append("novel", path);
    return fetch_1.fetchApi(site + "chapters", { method: "POST", body: fd }).then(function (r) { return r.json(); }).then(function (list) {
      return { path: path, name: "The Fake Novel", author: "A. Writer", status: status_1.NovelStatus.Ongoing,
        genres: "Fantasy, Adventure", summary: "A story.", chapters: list };
    });
  };
  Plugin.prototype.parseChapter = function (path) {
    return fetch_1.fetchApi(this.site + path).then(function (r) {
      if (!r.ok) throw new Error("Could not reach site (" + r.status + ") try to open in webview.");
      return r.text();
    }).then(function (html) { return (0, cheerio_1.load)(html)("#content").html(); });
  };
  return Plugin;
}();
exports.default = new Plugin();
''';

/// A plugin that fetches what it is told to and says what came back, keeps
/// a secret, and tries what a hostile one would: another plugin's storage
/// by its id, and replacing the bridge and the built-ins everything uses.
const _probe = r'''
"use strict";
var fetch_1 = require("@libs/fetch");
var storage_1 = require("@libs/storage");
exports.default = {
  id: ID, name: ID, site: SITE, version: "1.0.0",
  popularNovels: function () { return Promise.resolve([]); },
  searchNovels: function (term) {
    if (term === "store") { storage_1.storage.set("secret", "pw-" + ID); return Promise.resolve([]); }
    if (term === "steal") {
      var raw = sendMessage("tv_storage", JSON.stringify(["get", "a", "secret"]));
      return Promise.resolve([{ name: String(raw) + "|" + String(storage_1.storage.get("secret")), path: "x" }]);
    }
    if (term === "hijack") {
      globalThis.sendMessage = function () { return Promise.resolve(JSON.stringify({ status: 200, body: "hijacked" })); };
      Array.prototype.concat = function () { return ["get", "secret"]; };
      JSON.parse = function () { return { status: 200, body: "hijacked" }; };
      return Promise.resolve([]);
    }
    var url = term.indexOf(":") > 0 ? term : this.site + term;
    return fetch_1.fetchApi(url).then(function (r) {
      return r.text().then(function (body) { return [{ name: r.status + ":" + body, path: "x" }]; });
    });
  },
};
''';

Future<HttpServer> _site() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final path = req.uri.path;
    final res = req.response;
    if (path == '/search' && req.uri.queryParameters['q'] == 'blocked') {
      // Cloudflare's "Just a moment…" page.
      res.statusCode = 403;
      res.headers.set('cf-mitigated', 'challenge');
      res.headers.contentType = ContentType.html;
      res.write('<title>Just a moment...</title>');
    } else if (path == '/search') {
      final q = req.uri.queryParameters['q'] ?? '';
      res.headers.contentType = ContentType.html;
      res.write('<ul><li class="novel"><a href="novel/1">Fake $q One</a><img src="/c1.jpg"></li>'
          '<li class="novel"><a href="novel/2">Fake Two</a><img src="/c2.jpg"></li></ul>');
    } else if (path == '/chapters' && req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      res.headers.contentType = ContentType.json;
      final novel = Uri.splitQueryString(body)['novel'];
      res.write(jsonEncode([
        {'name': 'Chapter 1 for $novel', 'path': 'ch/1'},
        {'name': 'Chapter 2', 'path': 'ch/2'},
      ]));
    } else if (path == '/ch/1') {
      res.headers.contentType = ContentType.html;
      res.write('<div id="content"><p>It&#39;s the first chapter.</p><p>Second line.</p></div>');
    } else if (path == '/setcookie') {
      res.cookies.add(Cookie('sid', 'abc')..path = '/');
      res.write('set');
    } else if (path == '/echo-cookie') {
      res.write('cookies:${req.headers.value(HttpHeaders.cookieHeader) ?? ''}');
    } else if (path == '/blocked') {
      res.statusCode = 403;
      res.headers.set('cf-mitigated', 'challenge');
      res.write('<title>Just a moment...</title>');
    } else {
      res.statusCode = 404;
    }
    await res.close();
  });
  return server;
}

/// An engine whose smoke test answers as [verdict] says, by plugin.
class _SmokeEngine extends SourceEngine {
  _SmokeEngine(this.verdict) : super.forTests();

  final String? Function(PluginInfo p) verdict;

  @override
  Future<String?> smokeTest(PluginInfo p, String codePath, String sha256, {Duration timeout = Duration.zero}) async =>
      verdict(p);
}

/// Whether QuickJS is built here (CI, Linux); the engine tests skip
/// themselves where it is not.
bool _hasEngine() {
  try {
    createJsRuntime().dispose();
    return true;
  } on UnsupportedError {
    return false;
  }
}

PluginHost _host(Directory dir, {Future<String?> Function(String url)? viaBrowser, int maxLive = 4}) => PluginHost(
      createJsRuntime,
      libs: File('assets/js/lnreader_libs.js').readAsStringSync(),
      shim: File('assets/js/lnreader_shim.js').readAsStringSync(),
      sourcesDir: dir.path,
      viaBrowser: viaBrowser,
      maxLive: maxLive,
    );

void main() {
  // The test sites run on this machine, which the app itself never asks.
  setUp(() => Net.allowPrivateAddresses = true);
  tearDown(() => Net.allowPrivateAddresses = false);

  test('a source plugin searches, describes a novel and reads a chapter', () async {
    if (!_hasEngine()) {
      markTestSkipped('QuickJS is not built on this machine');
      return;
    }
    final server = await _site();
    final dir = Directory.systemTemp.createTempSync('tv_sources');
    late PluginHost host;
    addTearDown(() async {
      await server.close(force: true);
      host.dispose();
      dir.deleteSync(recursive: true);
    });
    final site = 'http://127.0.0.1:${server.port}/';
    final code = File('${dir.path}/fake.js')..writeAsStringSync(_plugin.replaceAll('SITE', jsonEncode(site)));
    // The phone's web view, once the test hands one over.
    var browserOn = false;
    host = _host(
      dir,
      viaBrowser: (url) async =>
          browserOn ? '<ul><li class="novel"><a href="novel/7">Seen by the browser</a></li></ul>' : null,
    );
    host.ensure('fake', '1.0.0', code.path, site: site);

    final found = [
      for (final o in await host.call('fake', 'searchNovels', ['dragon', 1]) as List) NovelItem.fromJs(o)!,
    ];
    expect(found.map((n) => n.name), ['Fake dragon One', 'Fake Two']);
    expect(found.first.path, 'novel/1');

    final novel = SourceNovel.fromJs(await host.call('fake', 'parseNovel', ['novel/1']), path: 'novel/1');
    expect(novel.name, 'The Fake Novel');
    expect(novel.genres, ['Fantasy', 'Adventure']);
    expect(novel.status, 'Ongoing');
    expect(novel.chapters.map((c) => c.name), ['Chapter 1 for novel/1', 'Chapter 2'],
        reason: 'FormData went out as a form body');

    final html = await host.call('fake', 'parseChapter', ['ch/1']) as String;
    expect(html, contains("It's the first chapter."));

    // A failing site becomes a readable error, not a crash.
    await expectLater(
      host.call('fake', 'parseChapter', ['ch/9']),
      throwsA(isA<SourceException>().having((e) => e.message, 'message', contains('Could not reach site'))),
    );

    // A browser check is reported as one, with its address, not as "nothing found".
    await expectLater(
      host.call('fake', 'searchNovels', ['blocked', 1]),
      throwsA(isA<ChallengeException>().having((e) => e.url, 'url', contains('/search?q=blocked'))),
    );

    // With the phone's web view to hand, a checked page is read through it.
    browserOn = true;
    final browsed = await host.call('fake', 'searchNovels', ['blocked', 1]) as List;
    expect(NovelItem.fromJs(browsed.single)!.name, 'Seen by the browser');

    // Storage persisted to the plugin's file.
    final stored = jsonDecode(File('${dir.path}/storage-fake.json').readAsStringSync()) as Map;
    expect(jsonDecode(stored['last'] as String)['value'], 'novel/1');
  });

  test("plugins cannot reach each other's storage, cookies or globals, nor the phone's network", () async {
    if (!_hasEngine()) {
      markTestSkipped('QuickJS is not built on this machine');
      return;
    }
    final server = await _site();
    final dir = Directory.systemTemp.createTempSync('tv_isolation');
    var browserAsked = 0;
    final host = _host(dir, viaBrowser: (url) async {
      browserAsked++;
      return '<p>through the browser</p>';
    });
    addTearDown(() async {
      await server.close(force: true);
      host.dispose();
      dir.deleteSync(recursive: true);
    });
    final site = 'http://127.0.0.1:${server.port}/';
    for (final id in ['a', 'b', 'c']) {
      File('${dir.path}/$id.js')
          .writeAsStringSync(_probe.replaceAll('SITE', jsonEncode(site)).replaceAll('ID', jsonEncode(id)));
      host.ensure(id, '1.0.0', '${dir.path}/$id.js', site: site);
    }
    Future<String> ask(String id, String term) async =>
        NovelItem.fromJs(((await host.call(id, 'searchNovels', [term, 1])) as List).firstOrNull)?.name ?? '';

    // Storage: b names a's, and gets its own (which has nothing).
    await ask('a', 'store');
    expect(await ask('b', 'steal'), isNot(contains('pw-a')));
    expect(jsonDecode(File('${dir.path}/storage-a.json').readAsStringSync())['secret'], contains('pw-a'));

    // Globals: b replaces the bridge and built-ins in its own context only.
    await ask('b', 'hijack');
    expect(await ask('a', 'echo-cookie'), '200:cookies:');

    // Cookies: what a's site set goes back with a's requests alone.
    await ask('a', 'setcookie');
    expect(await ask('a', 'echo-cookie'), '200:cookies:sid=abc');
    expect(await ask('c', 'echo-cookie'), '200:cookies:');

    // The web view: only for a plugin's own site ("localhost" is another).
    expect(await ask('a', 'blocked'), '200:<p>through the browser</p>');
    expect(browserAsked, 1);
    await expectLater(ask('a', 'http://localhost:${server.port}/blocked'), throwsA(isA<ChallengeException>()));
    expect(browserAsked, 1);

    // Nothing but web pages, and nothing on the phone or its network.
    expect(await ask('c', 'file:///etc/hosts'), startsWith('0:'));
    Net.allowPrivateAddresses = false;
    expect(await ask('c', 'echo-cookie'), startsWith('0:'));
  });

  test('only addresses on the open internet are asked', () {
    bool public(String a) => isPublicAddress(InternetAddress(a));
    for (final a in [
      '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254', '100.64.0.1',
      '0.0.0.0', '224.0.0.1', '255.255.255.255', '192.0.2.1', '::1', '::', 'fe80::1', 'fd00::1', 'fc00::1', 'ff02::1',
      '::ffff:127.0.0.1', '::ffff:192.168.0.1', '64:ff9b::a00:1', '2002:c0a8:101::1', '2001:db8::1',
    ]) {
      expect(public(a), isFalse, reason: a);
    }
    for (final a in ['1.1.1.1', '8.8.8.8', '172.32.0.1', '100.128.0.1', '2606:4700::1111', '::ffff:8.8.8.8', '2002:808:808::1']) {
      expect(public(a), isTrue, reason: a);
    }
  });

  test('cookies keep their domain, path, expiry and Secure flag, and each source its own', () {
    final jar = CookieJar();
    final page = Uri.parse('https://www.site.com/novel/1');
    jar.take(page, [
      Cookie('host', '1')..path = '/',
      Cookie('shared', '2')
        ..domain = '.site.com'
        ..path = '/',
      Cookie('deep', '3'), // no path: the page's own folder, /novel
      Cookie('gone', '4')..maxAge = 0,
      Cookie('safe', '5')
        ..secure = true
        ..path = '/',
      Cookie('other', '6')..domain = 'example.com',
    ], partition: 'p1');
    Set<String>? header(String url, [String part = 'p1']) =>
        jar.headerFor(Uri.parse(url), partition: part)?.split('; ').toSet();
    expect(header('https://www.site.com/novel/2'), {'deep=3', 'host=1', 'shared=2', 'safe=5'});
    expect(jar.headerFor(Uri.parse('https://www.site.com/novel/2'), partition: 'p1'), startsWith('deep=3'),
        reason: 'the longer path first');
    expect(header('https://m.site.com/'), {'shared=2'}, reason: 'host-only and path cookies stay put');
    expect(header('http://www.site.com/'), {'host=1', 'shared=2'}, reason: 'Secure only over https');
    expect(header('https://example.com/'), isNull, reason: 'a site cannot set cookies for another');
    expect(header('https://www.site.com/novel/2', 'p2'), isNull, reason: 'another source has its own');

    // Kept on disk and read back; a clear stays a clear.
    final copy = CookieJar()..mergeJson(jsonDecode(jsonEncode(jar.toJson())));
    expect(copy.headerFor(Uri.parse('https://www.site.com/novel/2'), partition: 'p1'), contains('deep=3'));
    jar.clear();
    jar.mergeJson(jsonDecode(jsonEncode(copy.toJson())));
    expect(jar.isEmpty, isTrue, reason: 'an older copy does not bring cleared cookies back');
  });

  test('tag names a site ran together are split, short ones kept whole', () {
    expect(SourceNovel.unglue('AdventureFantasyMystery'), ['Adventure', 'Fantasy', 'Mystery']);
    expect(SourceNovel.unglue('LitRPG'), ['LitRPG']);
    expect(SourceNovel.unglue('GameLit'), ['GameLit']);
    expect(SourceNovel.unglue('Slice of Life'), ['Slice of Life']);
    expect(SourceNovel.fromJs({'genres': 'Action, RomanceDrama'}, path: 'p').genres, ['Action', 'Romance', 'Drama']);
  });

  test("a new install starts with LNReader's list; removing it is remembered", () async {
    final dir = Directory.systemTemp.createTempSync('tv_repos');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SourceStore(dir);
    expect(await store.repos(), SourceStore.builtIn);
    await store.removeRepo(SourceStore.builtIn.single);
    expect(await SourceStore(dir).repos(), isEmpty);
  });

  test('versions compare numerically', () {
    expect(compareVersions('1.2.10', '1.2.9'), greaterThan(0));
    expect(compareVersions('2.0', '2.0.0'), 0);
    expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
  });

  test('a response decodes in the charset the server names', () {
    final r = NetResponse(
      status: 200,
      url: 'u',
      headers: const {'content-type': 'text/html; charset=ISO-8859-1'},
      bytes: latin1.encode('café'),
    );
    expect(r.text(), 'café');
  });

  test('a source list is checked, its sources installed, updated and removed', () async {
    var version = '1.0.0';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/plugins.min.json') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode([
          {'id': 'fake', 'name': 'Fake', 'site': '$base/', 'lang': 'English', 'version': version, 'url': '$base/fake.js'},
          {'id': 'ru1', 'name': 'Ru', 'site': '$base/', 'lang': 'Русский', 'version': '1.0.0', 'url': '$base/ru.js'},
        ]));
      } else if (req.uri.path == '/fake.js') {
        res.write('exports.default = {}; // version $version');
      } else if (req.uri.path == '/nothing.json') {
        res.write('<html>not a list</html>');
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_repo');
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    // Served over http from this machine; the app takes https only.
    final store = SourceStore(dir, defaults: const [], allowInsecure: true);

    await expectLater(store.addRepo('$base/nothing.json'), throwsA(isA<FormatException>()));
    expect(await store.addRepo('$base/plugins.min.json'), 2);
    expect(await store.repos(), ['$base/plugins.min.json']);

    final available = await store.available();
    expect(available.map((p) => p.id), ['fake', 'ru1'], reason: 'sorted by language, then name');
    final installed = await store.install(available.first);
    expect((await store.installed()).single.id, 'fake');
    expect(await store.code('fake'), contains('version 1.0.0'));
    expect(installed.sha256, sha256Hex(utf8.encode('exports.default = {}; // version 1.0.0')));
    expect(installed.repo, '$base/plugins.min.json');
    expect(await store.updates(), isEmpty);

    version = '1.1.0';
    await store.available(refresh: true);
    expect((await store.updates()).values.single.version, '1.1.0');
    expect(store.pending.value.keys, ['fake']);

    await store.uninstall('fake');
    expect(await store.installed(), isEmpty);
    expect(File(store.codePath('fake')).existsSync(), isFalse);
  });

  test('SHA-256 gives the answers in FIPS 180-4', () {
    expect(sha256Hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256Hex(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    expect(sha256Hex(List.filled(1000000, 0x61)), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    // Lengths either side of a block's end.
    expect(sha256Hex(List.filled(55, 0x61)), '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318');
    expect(sha256Hex(List.filled(64, 0x61)), 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb');
  });

  test('lists and code come over https only, and a source is updated only from its own list', () async {
    var a = '1.0.0', b = '9.9.0';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response;
      final p = req.uri.path;
      if (p == '/a.json' || p == '/b.json') {
        final v = p == '/a.json' ? a : b;
        res.write(jsonEncode([
          {'id': 'fake', 'name': 'Fake', 'site': '$base/', 'lang': 'English', 'version': v, 'url': '$base$p.js',
            'sha256': '0' * 64, 'repo': 'https://elsewhere/'},
        ]));
      } else {
        res.write('exports.default = {}; // from $p');
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_https');
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    await expectLater(SourceStore(dir, defaults: const []).addRepo('$base/a.json'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('https'))));
    await expectLater(
        SourceStore(dir, defaults: const []).install(
            PluginInfo(id: 'x', name: 'X', site: '$base/', lang: 'English', version: '1', url: '$base/x.js')),
        throwsA(isA<FormatException>()));

    final store = SourceStore(dir, defaults: const [], allowInsecure: true);
    await store.addRepo('$base/a.json');
    await store.addRepo('$base/b.json');
    expect((await store.available()).single.version, '9.9.0', reason: 'the newest is offered to install');
    // Installed from list a: list b's newer copy never replaces it.
    final fromA = await store.fromItsList(
        PluginInfo(id: 'fake', name: 'Fake', site: '', lang: '', version: '0', url: '', repo: '$base/a.json'));
    expect((fromA!.version, fromA.repo), ('1.0.0', '$base/a.json'), reason: "what list a says, under a's name");
    await store.install(fromA);
    final installed = (await store.installed()).single;
    expect(installed.repo, '$base/a.json');
    expect(installed.sha256, sha256Hex(utf8.encode('exports.default = {}; // from /a.json.js')),
        reason: "the code's own hash, not what the list said");
    expect(await store.updates(), isEmpty);
    a = '1.1.0';
    await store.available(refresh: true);
    final update = (await store.updates())['fake']!;
    expect((update.version, update.repo, update.url), ('1.1.0', '$base/a.json', '$base/a.json.js'));
  });

  test("a plugin whose code is not what was installed is not run", () {
    final dir = Directory.systemTemp.createTempSync('tv_tamper');
    addTearDown(() => dir.deleteSync(recursive: true));
    final code = File('${dir.path}/p.js')..writeAsStringSync('exports.default = {}; // as installed');
    final hash = sha256Hex(code.readAsBytesSync());
    var made = 0;
    final host = PluginHost(() {
      made++;
      throw UnsupportedError('no engine needed: the check comes first');
    }, libs: '', shim: '', sourcesDir: dir.path);
    code.writeAsStringSync('exports.default = {}; // changed by someone else');
    expect(() => host.ensure('p', '1', code.path, sha256: hash, name: 'Pea'),
        throwsA(isA<TamperedSourceException>().having((e) => e.name, 'name', 'Pea')));
    expect(made, 0, reason: 'its code never reached an engine');
  });

  test('sources move to internal storage once, checked; a restored copy is adopted, its code never run', () async {
    final tmp = Directory.systemTemp.createTempSync('tv_move');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final library = Directory('${tmp.path}/external')..createSync();
    final internal = Directory('${tmp.path}/internal')..createSync();
    final old = Directory('${library.path}/sources/plugins')..createSync(recursive: true);
    File('${old.path}/fake.js').writeAsStringSync('exports.default = {}; // fake');
    File('${library.path}/sources/installed.json').writeAsStringSync(jsonEncode([
      {'id': 'fake', 'name': 'Fake', 'site': 'https://fake.site/', 'lang': 'English', 'version': '1', 'url': 'https://e/f.js', 'repo': 'https://l/a.json'},
    ]));
    File('${library.path}/sources/repos.json').writeAsStringSync(jsonEncode(['https://l/a.json']));
    File('${library.path}/sources/storage-fake.json').writeAsStringSync('{"k":"v"}');

    final store = await SourceStore.open(internal, legacyRoot: library);
    expect(store.dir.path, '${internal.path}/sources');
    expect(Directory('${library.path}/sources').existsSync(), isFalse, reason: 'the old copy goes once checked');
    expect(await store.code('fake'), contains('// fake'));
    expect(await store.repos(), ['https://l/a.json']);
    final fake = (await store.installed()).single;
    expect(fake.sha256, sha256Hex(utf8.encode('exports.default = {}; // fake')), reason: 'its hash, kept from now on');

    // A backup from before the move, restored into the library's folder.
    Directory('${library.path}/sources/plugins').createSync(recursive: true);
    File('${library.path}/sources/plugins/other.js').writeAsStringSync('exports.default = {}; // anything at all');
    File('${library.path}/sources/installed.json').writeAsStringSync(jsonEncode([
      {'id': 'fake', 'name': 'Fake', 'site': 'https://fake.site/', 'lang': 'English', 'version': '1', 'url': 'https://e/f.js', 'sha256': '0' * 64},
      {'id': 'other', 'name': 'Other', 'site': 'https://other.site/', 'lang': 'English', 'version': '1', 'url': 'https://e/o.js', 'repo': 'https://l/b.json'},
    ]));
    File('${library.path}/sources/repos.json').writeAsStringSync(jsonEncode(['https://l/b.json', 'http://insecure/c.json']));
    File('${library.path}/sources/storage-other.json').writeAsStringSync('{"x":"y"}');
    final again = await SourceStore.open(internal, legacyRoot: library);
    expect(Directory('${library.path}/sources').existsSync(), isFalse);
    expect(await again.repos(), ['https://l/a.json', 'https://l/b.json'], reason: 'its https lists are taken');
    expect(File('${again.dir.path}/storage-other.json').existsSync(), isTrue, reason: 'and its settings');
    expect((await again.installed()).map((p) => p.id), ['fake'], reason: 'nothing it brought is run');
    expect((await again.installed()).single.sha256, fake.sha256, reason: "the backup's hash is not taken");
    expect(File(again.codePath('other')).existsSync(), isFalse);
    expect((await again.restored()).map((p) => p.id), ['other'], reason: 'installed again from its list instead');
  });

  test('a move that cannot finish leaves the old copy in use', () async {
    final tmp = Directory.systemTemp.createTempSync('tv_move_fail');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final library = Directory('${tmp.path}/external')..createSync();
    final internal = Directory('${tmp.path}/internal')..createSync();
    Directory('${library.path}/sources/plugins').createSync(recursive: true);
    File('${library.path}/sources/installed.json').writeAsStringSync('[]');
    // Something in the way where the sources should go.
    File('${internal.path}/sources').writeAsStringSync('in the way');
    final store = await SourceStore.open(internal, legacyRoot: library);
    expect(store.dir.path, '${library.path}/sources');
    expect(File('${library.path}/sources/installed.json').existsSync(), isTrue);
  });

  test('lists are read again at most daily, and a failed read keeps what was known', () async {
    var fetched = 0;
    var version = '1.0.0';
    var down = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final res = req.response;
      if (down) {
        res.statusCode = 503;
      } else if (req.uri.path == '/list.json') {
        fetched++;
        res.write(jsonEncode([
          {'id': 'fake', 'name': 'Fake', 'site': '$base/', 'lang': 'English', 'version': version, 'url': '$base/f.js'},
        ]));
      } else {
        res.write('exports.default = {};');
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_daily');
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final store = SourceStore(dir, defaults: const [], allowInsecure: true);
    await store.addRepo('$base/list.json');
    await store.install((await store.available()).single);
    expect(fetched, 1);

    version = '1.1.0';
    expect((await store.refreshIfDue()).keys, ['fake'], reason: 'never read on a schedule before');
    expect(fetched, 2);
    expect(store.pending.value.keys, ['fake']);
    await store.refreshIfDue();
    expect(fetched, 2, reason: 'once a day is enough');

    down = true;
    await store.refreshIfDue(every: Duration.zero);
    expect(store.pending.value.keys, ['fake'], reason: 'a list that cannot be read now keeps its last copy');
  });

  test('Update all keeps the version that works', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var version = '1.0.0';
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/list.json') {
        res.write(jsonEncode([
          for (final id in ['good', 'broken', 'down'])
            {'id': id, 'name': id, 'site': '$base/', 'lang': 'English', 'version': version, 'url': '$base/$id-$version.js'},
        ]));
      } else {
        res.write('exports.default = {}; // ${req.uri.path}');
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_update_all');
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final store = SourceStore(dir, defaults: const [], allowInsecure: true);
    await store.addRepo('$base/list.json');
    for (final p in await store.available()) {
      await store.install(p);
    }
    version = '2.0.0';
    final updates = await store.updates(refresh: true);
    expect(updates.keys.toSet(), {'good', 'broken', 'down'});

    // good: 2.0 works. broken: 2.0 fails, 1.0 still works. down: neither answers.
    final engine = _SmokeEngine((p) => switch ((p.name, p.version.split('#').first)) {
          ('good', _) => null,
          ('broken', '2.0.0') => 'It listed no novels.',
          ('broken', _) => null,
          _ => 'The site took too long to answer.',
        });
    final out = {for (final o in await updateSources(store, engine, updates.values)) o.plugin.id: o};
    final now = {for (final p in await store.installed()) p.id: p.version};
    expect(now, {'good': '2.0.0', 'broken': '1.0.0', 'down': '2.0.0'});
    expect(out['broken']!.note, contains('1.0.0 was kept'));
    expect(await store.code('broken'), contains('broken-1.0.0.js'), reason: 'the old code is untouched');
    expect(store.pending.value.keys, ['broken'], reason: 'still waiting, and still offered');
    expect(Directory('${store.dir.path}/plugins').listSync().where((f) => f.path.endsWith('.next.js')), isEmpty);
  });

  test('the engine runs an installed source in a worker, checks its code, and tries an update first', () async {
    if (!_hasEngine()) {
      markTestSkipped('QuickJS is not built on this machine');
      return;
    }
    final server = await _site();
    final site = 'http://127.0.0.1:${server.port}/';
    var version = '1.0.0';
    final lists = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${lists.port}';
    lists.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/list.json') {
        res.write(jsonEncode([
          {'id': 'fake', 'name': 'Fake', 'site': site, 'lang': 'English', 'version': version, 'url': '$base/fake-$version.js'},
        ]));
      } else if (req.uri.path == '/fake-1.0.0.js') {
        res.write(_plugin.replaceAll('SITE', jsonEncode(site)));
      } else {
        // 2.0.0: loads, but its popular page breaks.
        res.write(_plugin
            .replaceAll('SITE', jsonEncode(site))
            .replaceAll('return this.searchNovels("", page);', 'throw new Error("broken in 2.0");'));
      }
      await res.close();
    });
    final dir = Directory.systemTemp.createTempSync('tv_engine');
    final engine = SourceEngine.forTests(
      libs: File('assets/js/lnreader_libs.js').readAsStringSync(),
      shim: File('assets/js/lnreader_shim.js').readAsStringSync(),
    );
    addTearDown(() async {
      engine.close();
      await server.close(force: true);
      await lists.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final store = SourceStore(dir, defaults: const [], allowInsecure: true);
    engine.attach(store);
    await store.addRepo('$base/list.json');
    final installed = await store.install((await store.available()).single);
    expect((await engine.popular(installed, 1)).map((n) => n.name), ['Fake  One', 'Fake Two']);

    // Changed on the phone: not run when it is next loaded (here, by a new
    // worker; in the app, after a restart or once its context was let go).
    File(store.codePath('fake')).writeAsStringSync('exports.default = {}; // swapped');
    engine.close();
    await expectLater(engine.popular(installed, 1), throwsA(isA<TamperedSourceException>()));
    await store.install(installed);
    expect(await engine.popular(installed, 1), hasLength(2));

    // A broken update is tried and turned down; the working version stays.
    version = '2.0.0';
    final update = (await store.updates(refresh: true))['fake']!;
    final out = (await updateSources(store, engine, [update])).single;
    expect(out.updated, isFalse);
    expect((await store.installedById('fake'))!.version, '1.0.0');
    expect(await engine.popular(installed, 1), hasLength(2));
  });

  test('a response is capped as it is unpacked, a request is cut off in time, and one site gets two at once', () async {
    var open = 0, most = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/big':
          res.add(List.filled(3 << 20, 0x61));
        case '/bomb':
          // A small download that unpacks to far more than any page.
          res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          res.add(gzip.encode(List.filled(40 << 20, 0)));
        case '/trickle':
          for (var i = 0; i < 100; i++) {
            res.add([0x61]);
            await res.flush();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        case '/slow':
          open++;
          if (open > most) most = open;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          open--;
          res.write('ok');
      }
      await res.close();
    });
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    await expectLater(Net.instance.request('$base/big', maxBytes: 1 << 20),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('too large'))));
    await expectLater(Net.instance.request('$base/bomb', maxBytes: 1 << 20),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('too large'))));
    final sw = Stopwatch()..start();
    await expectLater(
        Net.instance.request('$base/trickle', total: const Duration(milliseconds: 600)), throwsA(isA<TimeoutException>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)), reason: 'cut off, not read to the end');
    await Future.wait([for (var i = 0; i < 5; i++) Net.instance.request('$base/slow')]);
    expect(most, Net.perHost);
  });

  test('a source that runs out of time has its worker replaced', () async {
    if (!_hasEngine()) {
      markTestSkipped('QuickJS is not built on this machine');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('tv_stuck');
    final engine = SourceEngine.forTests(
      libs: File('assets/js/lnreader_libs.js').readAsStringSync(),
      shim: File('assets/js/lnreader_shim.js').readAsStringSync(),
    );
    addTearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });
    final store = SourceStore(dir, defaults: const []);
    engine.attach(store);
    // Its popular page never comes: a promise that never settles.
    const hang = 'exports.default = { id: "hang", name: "Hang", site: "https://h.test/", version: "1", '
        'popularNovels: function () { return new Promise(function () {}); } };';
    final code = File('${dir.path}/hang.js')..writeAsStringSync(hang);
    const p = PluginInfo(id: 'hang', name: 'Hang', site: 'https://h.test/', lang: 'English', version: '1', url: '');
    final why = await engine.smokeTest(p, code.path, sha256Hex(utf8.encode(hang)), timeout: const Duration(seconds: 1));
    expect(why, contains('too long'));
    expect(engine.workerCount, 0, reason: 'the worker it was stuck in is gone');
    // The next call gets a fresh one.
    expect(await engine.smokeTest(p, code.path, sha256Hex(utf8.encode(hang)), timeout: const Duration(seconds: 1)),
        contains('too long'));
  });

  test('a web novel in the library: fetched chapters are read, the rest wait', () async {
    final dir = Directory.systemTemp.createTempSync('tv_web');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = LibraryStore(dir);
    const plugin = PluginInfo(id: 'fake', name: 'Fake', site: 'https://fake.site/', lang: 'English', version: '1', url: 'u');
    final novel = SourceNovel(
      path: 'novel/1',
      name: 'Shadow',
      author: 'Writer',
      summary: 'A story.',
      chapters: [for (var i = 0; i < 5; i++) ChapterItem(name: 'Chapter ${i + 1}', path: 'ch/$i')],
    );
    final e = await store.addWebNovel(plugin, novel);
    expect(e.isWeb, isTrue);
    expect(e.formatLabel, 'WEB');
    expect(e.chapterCount, 5);
    expect(e.language, 'en');
    expect((await store.list()).single.id, e.id);

    await store.saveChapter(e.id, 0, 'Chapter 1', '<p>Chapter 1</p><p>The first chapter has words enough to read.</p>');
    await store.saveChapter(e.id, 2, 'Chapter 3', '<p>Chapter 3</p><p>The third chapter, also with words to read.</p>');
    expect(store.downloadedChapters(e.id), {0, 2});

    final layout = await store.loadLayout(e.id);
    expect(layout.chapters, hasLength(2));
    expect(layout.book.metadata.description, 'A story.');
    expect(layout.units.map((u) => u.sectionIndex).toSet(), {0, 2});

    await store.saveWebChapters(e.id, [...novel.chapters, const ChapterItem(name: 'Chapter 6', path: 'ch/5')]);
    expect((await store.list()).single.chapterCount, 6);
    expect((await store.webNovel(e.id))!.chapters.last.name, 'Chapter 6');
  });

  test('source language names become language codes', () {
    expect(languageCodeOf('English'), 'en');
    expect(languageCodeOf('Русский'), 'ru');
    expect(languageCodeOf('${String.fromCharCode(0x200E)}العربية'), 'ar');
    expect(languageCodeOf('বাংলা'), 'bn');
    expect(languageCodeOf('Klingon'), isNull, reason: "not a guess of English: the chapters' script decides");
  });

  test('a NovelDokusha backup brings its novels, downloaded text and place', () async {
    final dir = Directory.systemTemp.createTempSync('tv_nd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final json = File('${dir.path}/nd.json')
      ..writeAsStringSync(jsonEncode({
        'books': [
          {
            'title': 'Lord of Mysteries',
            'url': 'https://www.example-novels.com/novel/lord-of-mysteries',
            'completed': false,
            'lastReadChapter': 'https://www.example-novels.com/novel/lord-of-mysteries/chapter-2',
            'cover': '',
            'description': 'Steam and machinery.',
            'chapters': [
              {
                'title': 'Chapter 1 Crimson',
                'url': 'https://www.example-novels.com/novel/lord-of-mysteries/chapter-1',
                'read': true,
                'body': 'Pain! Such a headache!${String.fromCharCode(10) * 2}Zhou Mingrui woke up & looked around.',
              },
              {
                'title': 'Chapter 2 Situation',
                'url': 'https://www.example-novels.com/novel/lord-of-mysteries/chapter-2',
                'read': false,
                'body': null,
              },
              {
                'title': 'Chapter 3 Melissa',
                'url': 'https://www.example-novels.com/novel/lord-of-mysteries/chapter-3',
                'read': false,
                'body': null,
              },
            ],
          },
        ],
      }));
    final store = LibraryStore(dir);
    final report = await importNovelDokushaJson(store, SourceStore(dir, defaults: const []), json.path);
    expect(report.novels, 1);
    expect(report.chapters, 1);
    expect(report.unmatched, ['Lord of Mysteries'], reason: 'no source for that site is installed');

    final e = (await store.list()).single;
    expect(e.isWeb, isTrue);
    expect(e.chapterCount, 3);
    expect(e.novelPath, 'novel/lord-of-mysteries');
    expect((await store.cursorFor(e.id)).sectionIndex, 1, reason: 'NovelDokusha was on chapter 2');
    final layout = await store.loadLayout(e.id);
    expect(layout.units.map((u) => u.text), contains('Zhou Mingrui woke up & looked around.'));
    expect(json.existsSync(), isFalse, reason: 'the temporary file is cleaned up');
  });

  test("a NovelDokusha novel's paths are written as its plugin writes them", () async {
    final dir = Directory.systemTemp.createTempSync('tv_nd_paths');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Installed: a plugin whose site has no slash at the end, so its paths
    // start with one (it reads site + path).
    Directory('${dir.path}/sources/plugins').createSync(recursive: true);
    File('${dir.path}/sources/installed.json').writeAsStringSync(jsonEncode([
      {'id': 'novels', 'name': 'Novels', 'site': 'https://example-novels.com', 'lang': 'English', 'version': '1', 'url': 'https://e/x.js'},
    ]));
    final json = File('${dir.path}/nd.json')
      ..writeAsStringSync(jsonEncode({
        'books': [
          {
            'title': 'Lord of Mysteries',
            'url': 'https://www.example-novels.com/novel/lord-of-mysteries',
            'cover': '',
            'description': '',
            'chapters': [
              {'title': 'Chapter 1', 'url': 'https://www.example-novels.com/novel/lord-of-mysteries/chapter-1', 'read': false},
            ],
          },
        ],
      }));
    final store = LibraryStore(dir);
    final report = await importNovelDokushaJson(store, SourceStore(dir, defaults: const []), json.path);
    expect(report.unmatched, isEmpty);
    final e = (await store.list()).single;
    expect(e.plugin, 'novels');
    expect(e.novelPath, '/novel/lord-of-mysteries');
    expect((await store.webNovel(e.id))!.chapters.single.path, '/novel/lord-of-mysteries/chapter-1');
  });

  test("NovelDokusha's local books come across from the text in the backup", () async {
    final dir = Directory.systemTemp.createTempSync('tv_nd_local');
    addTearDown(() => dir.deleteSync(recursive: true));
    final json = File('${dir.path}/nd.json')
      ..writeAsStringSync(jsonEncode({
        'books': [
          {
            'title': 'A_Game_of_Thrones_A_Song_of_Ice_and_Fire_1.epub',
            'url': 'local://A_Game_of_Thrones_A_Song_of_Ice_and_Fire_1.epub',
            'completed': false,
            'lastReadChapter': null,
            'cover': '',
            'description': '',
            'chapters': [
              {
                'title': 'Prologue',
                'url': 'local://A_Game_of_Thrones_A_Song_of_Ice_and_Fire_1.epub/0',
                'read': false,
                'body': 'We should start back, Gared urged as the woods began to grow dark around them.',
              },
            ],
          },
        ],
      }));
    final store = LibraryStore(dir);
    // An earlier import brought it in as a web novel; that copy goes.
    await store.addWebNovel(
      const PluginInfo(id: 'noveldokusha:local', name: 'NovelDokusha', site: '', lang: 'English', version: '0', url: ''),
      const SourceNovel(path: 'local://A_Game_of_Thrones_A_Song_of_Ice_and_Fire_1.epub', name: 'old'),
    );
    final report = await importNovelDokushaJson(store, SourceStore(dir, defaults: const []), json.path);
    expect(report.novels, 1);
    expect(report.chapters, 1);
    expect(report.unmatched, isEmpty, reason: 'a local book has no site to install');
    final e = (await store.list()).single;
    expect(e.isWeb, isFalse, reason: 'a book, not a web novel');
    expect(e.source, SourceKind.epub);
    expect(e.title, 'A Game of Thrones A Song of Ice and Fire 1');
    final layout = await store.loadLayout(e.id);
    expect(layout.units.map((u) => u.text).join(' '), contains('Gared urged'));
    expect(layout.chapterTitle(0), 'Prologue');
  });
}
