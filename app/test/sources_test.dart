// Web-novel sources: the plugin host running a small LNReader-style plugin
// in QuickJS, through the real libraries bundle and shim, against a local
// HTTP server. Needs the native engine, so it runs on CI (Linux); on a
// machine without it the engine tests are skipped.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/noveldokusha_import.dart';
import 'package:tomevoice_spike/sources/models.dart';
import 'package:tomevoice_spike/sources/net.dart';
import 'package:tomevoice_spike/sources/plugin_host.dart';
import 'package:tomevoice_spike/sources/qjs_runtime.dart';
import 'package:tomevoice_spike/sources/source_store.dart';

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
    } else {
      res.statusCode = 404;
    }
    await res.close();
  });
  return server;
}

void main() {
  JsRuntime? runtime() {
    try {
      return createJsRuntime();
    } on UnsupportedError {
      return null;
    }
  }

  test('a source plugin searches, describes a novel and reads a chapter', () async {
    final rt = runtime();
    if (rt == null) {
      markTestSkipped('QuickJS is not built on this machine');
      return;
    }
    final server = await _site();
    final dir = Directory.systemTemp.createTempSync('tv_sources');
    addTearDown(() async {
      await server.close(force: true);
      rt.dispose();
      dir.deleteSync(recursive: true);
    });
    final site = 'http://127.0.0.1:${server.port}/';
    final code = File('${dir.path}/fake.js')..writeAsStringSync(_plugin.replaceAll('SITE', jsonEncode(site)));
    final host = PluginHost(
      rt,
      libs: File('assets/js/lnreader_libs.js').readAsStringSync(),
      shim: File('assets/js/lnreader_shim.js').readAsStringSync(),
      sourcesDir: dir.path,
    );
    host.ensure('fake', '1.0.0', code.path);

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
    final viaBrowser = PluginHost(
      rt,
      libs: '',
      shim: '',
      sourcesDir: dir.path,
      viaBrowser: (url) async => '<ul><li class="novel"><a href="novel/7">Seen by the browser</a></li></ul>',
    );
    viaBrowser.ensure('fake', '1.0.0', code.path);
    final browsed = await viaBrowser.call('fake', 'searchNovels', ['blocked', 1]) as List;
    expect(NovelItem.fromJs(browsed.single)!.name, 'Seen by the browser');

    // Storage persisted to the plugin's file.
    final stored = jsonDecode(File('${dir.path}/storage-fake.json').readAsStringSync()) as Map;
    expect(jsonDecode(stored['last'] as String)['value'], 'novel/1');
  });

  test('tag names a site ran together are split, short ones kept whole', () {
    expect(SourceNovel.unglue('AdventureFantasyMystery'), ['Adventure', 'Fantasy', 'Mystery']);
    expect(SourceNovel.unglue('LitRPG'), ['LitRPG']);
    expect(SourceNovel.unglue('GameLit'), ['GameLit']);
    expect(SourceNovel.unglue('Slice of Life'), ['Slice of Life']);
    expect(SourceNovel.fromJs({'genres': 'Action, RomanceDrama'}, path: 'p').genres, ['Action', 'Romance', 'Drama']);
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
    final store = SourceStore(dir);

    await expectLater(store.addRepo('$base/nothing.json'), throwsA(isA<FormatException>()));
    expect(await store.addRepo('$base/plugins.min.json'), 2);
    expect(await store.repos(), ['$base/plugins.min.json']);

    final available = await store.available();
    expect(available.map((p) => p.id), ['fake', 'ru1'], reason: 'sorted by language, then name');
    await store.install(available.first);
    expect((await store.installed()).single.id, 'fake');
    expect(await store.code('fake'), contains('version 1.0.0'));
    expect(await store.updates(), isEmpty);

    version = '1.1.0';
    await store.available(refresh: true);
    expect((await store.updates()).single.version, '1.1.0');

    await store.uninstall('fake');
    expect(await store.installed(), isEmpty);
    expect(File(store.codePath('fake')).existsSync(), isFalse);
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
    expect(languageCodeOf('Klingon'), 'en');
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
    final report = await importNovelDokushaJson(store, SourceStore(dir), json.path);
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
}
