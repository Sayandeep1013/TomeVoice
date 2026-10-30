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
  SourceEngine.forTests({String? libs, String? shim})
      : _libs = libs,
        _shim = shim;

  static SourceEngine _instance = SourceEngine._();

  static SourceEngine get instance => _instance;

  @visibleForTesting
  static set instance(SourceEngine engine) => _instance = engine;

  static const _poolSize = 3;

  SourceStore? _store;
  final _workers = <_Worker>[];
  String? _libs;
  String? _shim;

  /// Where installed plugins and their storage live.
  void attach(SourceStore store) => _store = store;

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

  Future<_Worker> _workerFor(String pluginId) async {
    _libs ??= await rootBundle.loadString('assets/js/lnreader_libs.js');
    _shim ??= await rootBundle.loadString('assets/js/lnreader_shim.js');
    final have = _assigned[pluginId];
    if (have != null && !have.retired) return have;
    final live = [for (final w in _workers) if (!w.retired) w];
    final _Worker w;
    if (live.length < _poolSize) {
      w = await (_spawning ??= _Worker.spawn(libs: _libs!, shim: _shim!, sourcesDir: store.dir.path).then((w) {
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

  /// A page of the site's popular (or newest) novels.
  Future<List<NovelItem>> popular(PluginInfo p, int page, {bool latest = false}) async {
    final r = await _call(p, 'popularNovels', [
      page,
      {'showLatestNovels': latest, 'filters': null},
    ]);
    return _novels(r);
  }

  /// A page of search results.
  Future<List<NovelItem>> search(PluginInfo p, String query, int page) async =>
      _novels(await _call(p, 'searchNovels', [query, page]));

  /// A novel's details and its whole chapter list, oldest first. Sites that
  /// split the list over pages are read to the end; a page that comes back
  /// empty before the last one leaves the list marked incomplete
  /// ([SourceNovel.complete]), so it never replaces a stored list.
  Future<SourceNovel> novel(PluginInfo p, String path) async {
    final first = SourceNovel.fromJs(await _call(p, 'parseNovel', [path]), path: path);
    final pages = first.totalPages ?? 0;
    if (pages <= 1) return first;
    final chapters = [...first.chapters];
    var complete = pages <= 400;
    for (var n = first.chapters.isEmpty ? 1 : 2; n <= pages && n <= 400; n++) {
      final page = await _call(p, 'parsePage', [path, '$n']);
      final more = [
        for (final c in ((page is Map ? page['chapters'] : null) as List? ?? const []))
          if (ChapterItem.fromJs(c) case final ch?) ch,
      ];
      if (more.isEmpty) {
        complete = false;
        break;
      }
      chapters.addAll(more);
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

  static Future<_Worker> spawn({required String libs, required String shim, required String sourcesDir}) async {
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
    // The platform channel, for pages only the phone's web view gets.
    Future<String?> Function(String)? viaBrowser;
    if (boot[6] case final RootIsolateToken token) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      const channel = MethodChannel('tomevoice/tts');
      viaBrowser = (url) async {
        try {
          return await channel.invokeMethod<String>('browserFetch', {'url': url, 'userAgent': Net.userAgent});
        } on Object {
          return null;
        }
      };
    }
    final host = PluginHost(
      createJsRuntime,
      libs: boot[2] as String,
      shim: boot[3] as String,
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
          final out = await host.call(plugin, m['method'] as String, (m['args'] as List).cast<Object?>(),
              timeout: ms == null ? null : Duration(milliseconds: ms));
          reply.send({'id': id, 'ok': out});
        } on TamperedSourceException catch (e) {
          reply.send({'id': id, 'err': e.message, 'tampered': e.pluginId, 'name': e.name});
        } on ChallengeException catch (e) {
          reply.send({'id': id, 'err': e.message, 'challenge': e.url, 'plugin': plugin, 'stuck': host.stuck});
        } on SourceTimeoutException catch (e) {
          reply.send({'id': id, 'err': e.message, 'timeout': true, 'stuck': true});
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
