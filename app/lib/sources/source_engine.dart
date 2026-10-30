import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'models.dart';
import 'net.dart';
import 'plugin_host.dart';
import 'qjs_runtime.dart';
import 'source_store.dart';

/// Runs web-novel sources off the UI thread.
///
/// Plugins execute in a small pool of background isolates, each with one
/// QuickJS runtime holding the shared libraries and every plugin it has
/// been asked for. A slow site never freezes the screen, and global search
/// asks up to [_poolSize] sites at once.
class SourceEngine {
  SourceEngine._();

  static final instance = SourceEngine._();

  static const _poolSize = 3;

  SourceStore? _store;
  final _workers = <_Worker>[];
  String? _libs;
  String? _shim;

  /// Where installed plugins and their storage live.
  void attach(SourceStore store) => _store = store;

  SourceStore get store {
    final s = _store;
    if (s == null) throw StateError('SourceEngine.attach was not called');
    return s;
  }

  Future<_Worker> _worker() async {
    _libs ??= await rootBundle.loadString('assets/js/lnreader_libs.js');
    _shim ??= await rootBundle.loadString('assets/js/lnreader_shim.js');
    final idle = _workers.where((w) => w.busy == 0).firstOrNull;
    if (idle != null) return idle;
    if (_workers.length < _poolSize) {
      final w = await _Worker.spawn(libs: _libs!, shim: _shim!, sourcesDir: store.dir.path);
      _workers.add(w);
      return w;
    }
    _workers.sort((a, b) => a.busy.compareTo(b.busy));
    return _workers.first;
  }

  Future<Object?> _call(PluginInfo p, String method, List<Object?> args) async {
    final w = await _worker();
    return w.call(p.id, p.version, store.codePath(p.id), method, args);
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
      final c = _pending.remove(m['id']);
      if (c == null) return;
      if (m['challenge'] is String) {
        c.completeError(ChallengeException(m['challenge'] as String));
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

  int get busy => _pending.length;

  static Future<_Worker> spawn({required String libs, required String shim, required String sourcesDir}) async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    final init = ReceivePort();
    init.listen((m) {
      if (m is SendPort && !ready.isCompleted) ready.complete(m);
    });
    await Isolate.spawn(
        _main, [init.sendPort, receive.sendPort, libs, shim, sourcesDir, Net.userAgent, RootIsolateToken.instance],
        debugName: 'source-worker');
    final send = await ready.future;
    init.close();
    return _Worker(send, receive);
  }

  Future<Object?> call(String id, String version, String codePath, String method, List<Object?> args) {
    final n = _next++;
    final c = Completer<Object?>();
    _pending[n] = c;
    _send.send({
      'id': n,
      'plugin': id,
      'version': version,
      'code': codePath,
      'method': method,
      'args': args,
    });
    return c.future;
  }

  static Future<void> _main(List<Object?> boot) async {
    final init = boot[0] as SendPort;
    final reply = boot[1] as SendPort;
    final requests = ReceivePort();
    init.send(requests.sendPort);
    final dir = boot[4] as String;
    Net.userAgent = boot[5] as String;
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
      createJsRuntime(),
      libs: boot[2] as String,
      shim: boot[3] as String,
      sourcesDir: dir,
      viaBrowser: viaBrowser,
    );
    await for (final m in requests) {
      if (m is! Map) continue;
      final id = m['id'];
      unawaited(() async {
        try {
          await Net.instance.refreshCookies();
          host.ensure(m['plugin'] as String, m['version'] as String, m['code'] as String);
          final out = await host.call(m['plugin'] as String, m['method'] as String, (m['args'] as List).cast<Object?>());
          reply.send({'id': id, 'ok': out});
        } on ChallengeException catch (e) {
          reply.send({'id': id, 'err': e.message, 'challenge': e.url});
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
