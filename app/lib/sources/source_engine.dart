import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'browser_hosts.dart';
import 'models.dart';
import 'net.dart';
import 'plugin_host.dart';
import 'qjs_runtime.dart';
import 'source_store.dart';

/// Runs web-novel sources off the UI thread.
///
/// Plugins execute in a small pool of background isolates, each plugin in a
/// QuickJS context of its own (see PluginHost) and always in the same
/// isolate, so its context is made once. A slow site never freezes the
/// screen, and global search asks up to [_poolSize] sites at once. A worker
/// in which a call ran out of time takes no more calls and is replaced: what
/// that call started may still be running there.
class SourceEngine {
  SourceEngine._();

  /// For tests: an engine whose answers they make up (overriding [novel],
  /// [chapter] and the like), set as [instance]; or a real one, given the
  /// libraries and the shim (read from assets/js without the asset bundle).
  @visibleForTesting
  SourceEngine.forTests({String? libs, String? shim, String? extra})
      : _libs = libs,
        _shim = shim,
        // Given the libraries but not the extras: none (no asset bundle).
        _extra = extra ?? (libs == null ? null : '');

  static SourceEngine _instance = SourceEngine._();

  static SourceEngine get instance => _instance;

  @visibleForTesting
  static set instance(SourceEngine engine) => _instance = engine;

  static const _poolSize = 3;

  SourceStore? _store;
  final _workers = <_Worker>[];
  String? _libs;
  String? _shim;

  /// lnreader_extra.js, for the few plugins that need it.
  String? _extra;

  /// Where installed plugins and their storage live.
  void attach(SourceStore store) => _store = store;

  /// Workers running now (tests: one where a call ran out of time is gone).
  @visibleForTesting
  int get workerCount => _workers.length;

  /// End every worker (tests; the app's last as long as it does).
  @visibleForTesting
  void close() {
    for (final w in _workers) {
      w.close();
    }
    _workers.clear();
    _assigned.clear();
  }

  SourceStore get store {
    final s = _store;
    if (s == null) throw StateError('SourceEngine.attach was not called');
    return s;
  }

  /// Which worker each plugin runs in.
  final _assigned = <String, _Worker>{};
  Future<_Worker>? _spawning;

  /// Cookies the workers' sites set: kept by this (the main) isolate, the
  /// one that writes cookies.json.
  ReceivePort? _cookies;

  SendPort get _cookieSink => (_cookies ??= ReceivePort()..listen(Net.instance.takeForwarded)).sendPort;

  Future<_Worker> _workerFor(String pluginId) async {
    _libs ??= await rootBundle.loadString('assets/js/lnreader_libs.js');
    _shim ??= await rootBundle.loadString('assets/js/lnreader_shim.js');
    _extra ??= await rootBundle.loadString('assets/js/lnreader_extra.js');
    final have = _assigned[pluginId];
    if (have != null && !have.retired) return have;
    final live = [for (final w in _workers) if (!w.retired) w];
    final _Worker w;
    if (live.length < _poolSize) {
      w = await (_spawning ??=
          _Worker.spawn(libs: _libs!, shim: _shim!, extra: _extra, sourcesDir: store.dir.path, cookies: _cookieSink)
              .then((w) {
        _workers.add(w);
        return w;
      }).whenComplete(() => _spawning = null));
    } else {
      int load(_Worker w) => _assigned.values.where((x) => identical(x, w)).length * 4 + w.busy;
      w = live.reduce((a, b) => load(b) < load(a) ? b : a);
    }
    return _assigned[pluginId] = w;
  }

  Future<Object?> _call(PluginInfo given, String method, List<Object?> args, {Duration? timeout}) async {
    // The source as installed now (what a novel stored may be an older
    // version): its code, site and the hash its code is checked against.
    final p = await store.installedById(given.id) ?? (throw MissingSourceException(given.id, given.name));
    return _callWith(p, store.codePath(p.id), method, args, timeout: timeout);
  }

  /// Load [p], a version of a source not installed yet (its code at
  /// [codePath], hashing to [sha256]), in a context of its own, and ask for
  /// its first popular page: null if it listed novels, else what went
  /// wrong. What an update must pass before it replaces what works.
  Future<String?> smokeTest(PluginInfo p, String codePath, String sha256,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final trial = PluginInfo(
      id: '${p.id}#trial',
      name: p.name,
      site: p.site,
      lang: p.lang,
      version: '${p.version}#${sha256.substring(0, 12)}',
      url: p.url,
      sha256: sha256,
    );
    try {
      final r = await _callWith(trial, codePath, 'popularNovels', [
        1,
        {'showLatestNovels': false, 'filters': null},
      ], timeout: timeout);
      return _novels(r).isNotEmpty ? null : 'It listed no novels.';
    } on SourceException catch (e) {
      return e.message;
    } on Object catch (e) {
      return friendlyError(e);
    }
  }

  Future<Object?> _callWith(PluginInfo p, String codePath, String method, List<Object?> args, {Duration? timeout}) async {
    final w = await _workerFor(p.id);
    try {
      return await w.call(p, codePath, method, args, timeout: timeout);
    } finally {
      if (w.retired) {
        _assigned.removeWhere((_, x) => identical(x, w));
        if (w.busy == 0) {
          w.close();
          _workers.remove(w);
        }
      }
    }
  }

  /// A page of the site's popular (or newest) novels; with [filters] (key
  /// to `{type, value}`, as LNReader hands them), only those the reader
  /// chose (null: the plugin's own defaults).
  Future<List<NovelItem>> popular(PluginInfo p, int page, {bool latest = false, Map<String, Object?>? filters}) async {
    final r = await _call(p, 'popularNovels', [
      page,
      {'showLatestNovels': latest, 'filters': filters},
    ]);
    return _novels(r);
  }

  /// What plugin [p] says of itself: its filters and settings (see
  /// LNReader's Plugin type), with what it was loaded as.
  Future<Map<String, Object?>> meta(PluginInfo p) async =>
      Map<String, Object?>.from(await _call(p, '__meta', const []) as Map? ?? const {});

  /// The values plugin [p]'s settings have now (by key; null where unset).
  Future<Map<String, Object?>> settings(PluginInfo p) async =>
      Map<String, Object?>.from(await _call(p, '__settings', const []) as Map? ?? const {});

  /// Set plugin [p]'s setting [key] to [value], kept as the plugin keeps
  /// its own storage; the plugin is loaded again, as some read settings only
  /// as they load.
  Future<void> setSetting(PluginInfo p, String key, Object? value) => _call(p, '__setting', [key, value]);

  /// A page of search results.
  Future<List<NovelItem>> search(PluginInfo p, String query, int page) async =>
      _novels(await _call(p, 'searchNovels', [query, page]));

  /// Pages of a paged chapter list asked at once.
  static const _pagesAtOnce = 3;

  /// The most pages read (some 50,000 chapters); a longer list is marked
  /// incomplete.
  static const _maxPages = 1000;

  /// A novel's details and its whole chapter list, oldest first. Sites that
  /// split the list over pages are read a few pages at a time to the end. A
  /// page that fails or comes back empty ends the list there: what came
  /// before it is kept, marked incomplete ([SourceNovel.complete]), so it is
  /// shown but never replaces a stored list. A browser check is said, not
  /// kept quiet: the reader can pass it and try again.
  Future<SourceNovel> novel(PluginInfo p, String path) async {
    final first = SourceNovel.fromJs(await _call(p, 'parseNovel', [path]), path: path);
    final pages = first.totalPages ?? 0;
    if (pages <= 1) return first;
    final chapters = [...first.chapters];
    final last = pages < _maxPages ? pages : _maxPages;
    var complete = pages <= _maxPages;
    Future<List<ChapterItem>?> page(int n) async {
      try {
        final r = await _call(p, 'parsePage', [path, '$n']);
        return [
          for (final c in ((r is Map ? r['chapters'] : null) as List? ?? const []))
            if (ChapterItem.fromJs(c) case final ch?) ch,
        ];
      } on ChallengeException {
        rethrow;
      } on Object {
        return null;
      }
    }

    var n = first.chapters.isEmpty ? 1 : 2;
    pages:
    while (n <= last) {
      final batch = [for (var k = n; k < n + _pagesAtOnce && k <= last; k++) k];
      final got = await Future.wait([for (final k in batch) page(k)]);
      for (final more in got) {
        if (more == null || more.isEmpty) {
          complete = false;
          break pages;
        }
        chapters.addAll(more);
      }
      n += batch.length;
    }
    return SourceNovel(
      path: first.path,
      name: first.name,
      cover: first.cover,
      author: first.author,
      summary: first.summary,
      status: first.status,
      genres: first.genres,
      chapters: chapters,
      complete: complete,
    );
  }

  /// A chapter's text, as HTML.
  Future<String> chapter(PluginInfo p, String path) async {
    final r = await _call(p, 'parseChapter', [path]);
    if (r is! String || r.trim().isEmpty) throw SourceException('The chapter came back empty.');
    return r;
  }

  /// The web address of a novel or chapter path, for "Open in browser".
  Future<String> resolveUrl(PluginInfo p, String path, {bool novel = true}) async {
    final r = await _call(p, 'resolveUrl', [path, novel]);
    return r is String ? r : p.site + path;
  }

  static List<NovelItem> _novels(Object? r) => [
        for (final o in (r as List? ?? const []))
          if (NovelItem.fromJs(o) case final n?) n,
      ];
}

/// One background isolate running a [PluginHost].
class _Worker {
  _Worker(this._send, this._receive) {
    _receive.listen((m) {
      if (m is! Map) return;
      // A call ran out of time in there: no more calls (see SourceEngine).
      if (m['stuck'] == true) retired = true;
      final c = _pending.remove(m['id']);
      if (c == null) return;
      if (m['challenge'] is String) {
        c.completeError(ChallengeException(m['challenge'] as String, pluginId: m['plugin'] as String? ?? ''));
      } else if (m['retryAfter'] is int) {
        c.completeError(RateLimitedException(Duration(milliseconds: m['retryAfter'] as int)));
      } else if (m['tampered'] is String) {
        c.completeError(TamperedSourceException(m['tampered'] as String, m['name'] as String? ?? ''));
      } else if (m['timeout'] == true) {
        c.completeError(SourceTimeoutException());
      } else if (m.containsKey('err')) {
        c.completeError(SourceException(m['err'] as String));
      } else {
        c.complete(m['ok']);
      }
    });
  }

  final SendPort _send;
  final ReceivePort _receive;
  final _pending = <int, Completer<Object?>>{};
  int _next = 0;

  /// Takes no more calls; closed once those it has are done.
  bool retired = false;

  int get busy => _pending.length;

  static Future<_Worker> spawn({
    required String libs,
    required String shim,
    required String sourcesDir,
    required SendPort cookies,
    String? extra,
  }) async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    final init = ReceivePort();
    init.listen((m) {
      if (m is SendPort && !ready.isCompleted) ready.complete(m);
    });
    await Isolate.spawn(
        _main,
        [
          init.sendPort,
          receive.sendPort,
          libs,
          shim,
          sourcesDir,
          Net.userAgent,
          RootIsolateToken.instance,
          Net.allowPrivateAddresses,
          cookies,
          extra,
        ],
        debugName: 'source-worker');
    final send = await ready.future;
    init.close();
    return _Worker(send, receive);
  }

  Future<Object?> call(PluginInfo p, String codePath, String method, List<Object?> args, {Duration? timeout}) {
    final n = _next++;
    final c = Completer<Object?>();
    _pending[n] = c;
    _send.send({
      'id': n,
      'plugin': p.id,
      'name': p.name,
      'version': p.version,
      'code': codePath,
      'site': p.site,
      'sha256': p.sha256,
      'method': method,
      'args': args,
      if (timeout != null) 'timeout': timeout.inMilliseconds,
    });
    return c.future;
  }

  /// End the isolate: its engines are disposed, and what still ran in them
  /// stops with it.
  void close() {
    _send.send(const {'exit': true});
    _receive.close();
  }

  static Future<void> _main(List<Object?> boot) async {
    final init = boot[0] as SendPort;
    final reply = boot[1] as SendPort;
    final requests = ReceivePort();
    init.send(requests.sendPort);
    final dir = boot[4] as String;
    Net.userAgent = boot[5] as String;
    // Tests' sites are on this machine (see Net.allowPrivateAddresses).
    Net.allowPrivateAddresses = boot[7] == true;
    await Net.instance.attachPath(dir);
    // The main isolate keeps the cookie file; this one reads it, and sends
    // what sites set there.
    Net.instance.forwardCookiesTo(boot[8] as SendPort);
    // The platform channel, for pages only the phone's web view gets (none
    // in the background check's engine, which has no activity: null there).
    BrowserFetch? viaBrowser;
    if (boot[6] case final RootIsolateToken token) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      const channel = MethodChannel('tomevoice/sources');
      viaBrowser = (url, {method = 'GET', body}) async {
        try {
          return await channel.invokeMethod<String>(
              'browserFetch', {'url': url, 'userAgent': Net.userAgent, 'method': method, 'body': body});
        } on Object {
          return null;
        }
      };
    }
    final host = PluginHost(
      createJsRuntime,
      libs: boot[2] as String,
      shim: boot[3] as String,
      extra: boot[9] as String?,
      sourcesDir: dir,
      viaBrowser: viaBrowser,
      onBrowserHost: (host) => unawaited(noteBrowserHost(Directory(dir), host)),
    );
    await for (final m in requests) {
      if (m is! Map) continue;
      if (m['exit'] == true) {
        host.dispose();
        Isolate.exit();
      }
      final id = m['id'];
      final plugin = m['plugin'] as String;
      unawaited(() async {
        try {
          await Net.instance.refreshCookies();
          host.ensure(plugin, m['version'] as String, m['code'] as String,
              site: m['site'] as String? ?? '', sha256: m['sha256'] as String?, name: m['name'] as String?);
          final ms = m['timeout'] as int?;
          final method = m['method'] as String;
          final args = (m['args'] as List).cast<Object?>();
          // The host's own questions about a plugin, not the plugin's methods.
          final Object? out = switch (method) {
            '__meta' => host.meta(plugin),
            '__settings' => host.settingsOf(plugin),
            '__setting' => host.setSetting(plugin, args[0] as String, args[1]),
            _ => await host.call(plugin, method, args, timeout: ms == null ? null : Duration(milliseconds: ms)),
          };
          reply.send({'id': id, 'ok': out});
        } on TamperedSourceException catch (e) {
          reply.send({'id': id, 'err': e.message, 'tampered': e.pluginId, 'name': e.name});
        } on ChallengeException catch (e) {
          reply.send({'id': id, 'err': e.message, 'challenge': e.url, 'plugin': plugin, 'stuck': host.stuck});
        } on SourceTimeoutException catch (e) {
          reply.send({'id': id, 'err': e.message, 'timeout': true, 'stuck': true});
        } on RateLimitedException catch (e) {
          reply.send({'id': id, 'err': e.message, 'retryAfter': e.retryAfter.inMilliseconds});
        } on SourceException catch (e) {
          reply.send({'id': id, 'err': e.message});
        } on JsException catch (e) {
          reply.send({'id': id, 'err': e.message.split('\n').first});
        } on Object catch (e) {
          reply.send({'id': id, 'err': '$e'});
        }
      }());
    }
  }
}
