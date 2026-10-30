import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cookies.dart';
import 'net.dart';
import 'sha256.dart';

/// A JavaScript engine, as the plugin host needs it. The QuickJS one is in
/// qjs_runtime.dart; keeping the host to this interface lets everything else
/// be tested without the native engine.
abstract class JsRuntime {
  /// Run [code]; its result as text. Throws [JsException] on a JS error.
  String eval(String code, {String name = '<eval>'});

  /// Run [code], which yields a Promise; completes with what it resolves to,
  /// as text.
  Future<String> evalAsync(String code, {Duration timeout = const Duration(seconds: 90)});

  /// Answer `sendMessage(channel, json)` calls from JavaScript. A handler may
  /// return a Future, which JavaScript sees as a Promise.
  void onMessage(String channel, Object? Function(List<Object?> args) handler);

  /// Whether a timer the code set is still to fire: the engine must not be
  /// disposed under it.
  bool get hasPendingTimers => false;

  void dispose();
}

class JsException implements Exception {
  JsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a source does when it cannot do what was asked: the site is down,
/// changed, or wants a browser check. [message] is said to the reader.
class SourceException implements Exception {
  SourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The site answered with a browser check (Cloudflare) instead of itself.
/// Passing it once in a web view ([url]) lets the requests through.
/// [pluginId]: the source that met it, whose cookies the check's go with.
class ChallengeException extends SourceException {
  ChallengeException(this.url, {this.pluginId = ''})
      : super('${Uri.tryParse(url)?.host ?? 'The site'} wants a quick browser check first.');

  final String url;
  final String pluginId;
}

/// The novel's site has no source installed, so no more chapters can be
/// fetched. [pluginId] is what to install (it may not be in any list).
class MissingSourceException extends SourceException {
  MissingSourceException(this.pluginId, this.name)
      : super('$name is not installed, so this chapter cannot be fetched yet.');

  final String pluginId;
  final String name;
}

/// The source took longer than it is given. Its engine is not used again
/// (what it started may still be running there).
class SourceTimeoutException extends SourceException {
  SourceTimeoutException() : super('The site took too long to answer.');
}

/// An installed source's code is not what was installed (changed on the
/// phone, or brought back by a restore), so it is not run. Installing it
/// again from its list puts it right.
class TamperedSourceException extends SourceException {
  TamperedSourceException(this.pluginId, this.name)
      : super("$name's code on the phone is not what was installed, so it was not run.");

  final String pluginId;
  final String name;
}

/// One source plugin, in a JavaScript context of its own.
class _Plugin {
  _Plugin(this.id, this.version, this.site, this.rt);

  final String id;
  final String version;

  /// Its site's home page, from the list it was installed from: the only
  /// site whose pages may be fetched for it through the phone's web view.
  final String site;
  final JsRuntime rt;
  Map<String, Object?> meta = const {};

  /// The hash its code was checked against when loaded.
  String? sha256;

  /// Calls in flight, each collecting the browser checks its requests met.
  final calls = <_Call>{};

  /// A call ran out of time: what it started may still run in this engine.
  bool stuck = false;

  int get busy => calls.length;
}

class _Call {
  final challenged = <String>[];
}

/// Runs LNReader source plugins: each in a JavaScript context of its own
/// (made by [newRuntime]) holding the libraries they use (lnreader_libs.js),
/// the host that hands them `require` (lnreader_shim.js), and the plugin.
/// No plugin can see or change another's globals, storage or cookies: the
/// bridges below know which plugin is asking from the context it asks in,
/// never from what the JavaScript says.
///
/// Fetch goes through [Net], with the plugin's own cookies; storage is a
/// small JSON file per plugin. At most [maxLive] contexts are kept; the one
/// unused longest goes first.
class PluginHost {
  PluginHost(
    this.newRuntime, {
    required this.libs,
    required this.shim,
    required this.sourcesDir,
    this.viaBrowser,
    this.maxLive = 5,
    this.onBrowserHost,
  });

  /// A site turned out to need [viaBrowser] (see browser_hosts.dart).
  final void Function(String host)? onBrowserHost;

  final JsRuntime Function() newRuntime;
  final String libs;
  final String shim;

  /// Where plugins' storage files live.
  final String sourcesDir;

  /// A page's HTML as the phone's web view gets it, or null: for sites whose
  /// Cloudflare turns away the app's own requests but lets a browser in.
  final Future<String?> Function(String url)? viaBrowser;

  final int maxLive;

  /// Sites that needed [viaBrowser]; their pages go straight there.
  final _browserHosts = <String>{};

  /// Loaded plugins, the one used last at the end (a map literal keeps its
  /// order of insertion).
  final _live = <String, _Plugin>{};

  /// What plugin [id] said about itself when loaded: filters, settings.
  Map<String, Object?> meta(String id) => _live[id]?.meta ?? const {};

  /// Whether plugin [id] is loaded at [version].
  bool has(String id, String version) => _live[id]?.version == version;

  /// Load (or reload, after an update) plugin [id] from [codePath], for
  /// [site] (its home page, as its list names it). With [sha256], the code
  /// must be what was installed ([TamperedSourceException] otherwise).
  void ensure(String id, String version, String codePath, {String site = '', String? sha256, String? name}) {
    final have = _live.remove(id);
    if (have != null && have.version == version && have.sha256 == sha256 && !have.stuck) {
      _live[id] = have;
      return;
    }
    if (have != null) _retire(have);
    final bytes = File(codePath).readAsBytesSync();
    if (sha256 != null && sha256Hex(bytes) != sha256) throw TamperedSourceException(id, name ?? id);
    final code = utf8.decode(bytes, allowMalformed: true);
    final rt = newRuntime();
    final p = _Plugin(id, version, site, rt)..sha256 = sha256;
    try {
      rt.onMessage('tv_fetch', (args) => _fetch(p, args));
      rt.onMessage('tv_storage', (args) => _storage(p, args));
      rt.eval(libs, name: 'lnreader_libs.js');
      rt.eval(shim, name: 'lnreader_shim.js');
      final raw = rt.eval('__tvLoadPlugin(${jsonEncode(id)}, ${jsonEncode(code)})', name: id);
      p.meta = Map<String, Object?>.from(jsonDecode(raw) as Map);
    } on Object {
      rt.dispose();
      rethrow;
    }
    _live[id] = p;
    _evict();
  }

  /// Contexts replaced while something still ran in them.
  final _retired = <_Plugin>[];

  /// Contexts past [maxLive], the least recently used first, unless busy;
  /// and replaced ones that have finished.
  void _evict() {
    for (final p in [..._live.values]) {
      if (_live.length <= maxLive) break;
      if (p.busy > 0 || p.rt.hasPendingTimers) continue;
      _live.remove(p.id);
      p.rt.dispose();
    }
    _retired.removeWhere((p) {
      if (p.stuck || p.busy > 0 || p.rt.hasPendingTimers) return false;
      p.rt.dispose();
      return true;
    });
  }

  /// [p] is replaced: its context goes once nothing runs in it. One left
  /// stuck by a call that timed out is never disposed: its engine still
  /// polls the promise that never settled (the worker is restarted instead).
  void _retire(_Plugin p) {
    if (!p.stuck) _retired.add(p);
  }

  /// Whether a call timed out here, so the engines should be started again.
  bool get stuck => _live.values.any((p) => p.stuck);

  /// Call [method] on plugin [id] with [args]; the result, decoded from JSON.
  ///
  /// When a request on the way met a browser check, throws
  /// [ChallengeException]: whatever the plugin made of that page is wrong.
  Future<Object?> call(String id, String method, List<Object?> args, {Duration? timeout}) async {
    final p = _live[id];
    if (p == null) throw SourceException('Source $id is not loaded.');
    // The one used last goes to the end, furthest from eviction.
    _live
      ..remove(id)
      ..[id] = p;
    final call = _Call();
    p.calls.add(call);
    void challenged() {
      if (call.challenged.isNotEmpty) throw ChallengeException(call.challenged.last, pluginId: id);
    }

    try {
      final out = await p.rt.evalAsync(
        '__tvCall(${jsonEncode(id)}, ${jsonEncode(method)}, ${jsonEncode(jsonEncode(args))})',
        timeout: timeout ?? const Duration(seconds: 90),
      );
      challenged();
      return jsonDecode(out);
    } on TimeoutException {
      p.stuck = true;
      challenged();
      throw SourceTimeoutException();
    } on JsException catch (e) {
      challenged();
      throw SourceException(_clean(e.message));
    } finally {
      p.calls.remove(call);
    }
  }

  /// Dispose every context, stuck ones too: the worker is going, and what
  /// still polls them goes with it.
  void dispose() {
    for (final p in [..._live.values, ..._retired]) {
      p.rt.dispose();
    }
    _live.clear();
    _retired.clear();
  }

  /// "Error: Could not reach site ('403') try to open in webview." ->
  /// the readable part.
  static String _clean(String m) {
    var s = m.split('\n').first.trim();
    for (final p in const ['Uncaught ', 'Error: ', 'TypeError: ']) {
      if (s.startsWith(p)) s = s.substring(p.length);
    }
    return s.isEmpty ? 'The source failed.' : s;
  }

  // ------------------------------------------------------------- bridges

  static const _defaultHeaders = {
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  Future<String> _fetch(_Plugin p, List<Object?> args) async {
    final url = '${args[0]}';
    final req = Map<String, Object?>.from((args.length > 1 ? args[1] : null) as Map? ?? const {});
    if (!Net.isWebAddress(url)) return _failed(url, 'Only web pages can be asked for.');
    final headers = <String, String>{..._defaultHeaders};
    final given = req['headers'];
    if (given is Map) {
      given.forEach((k, v) {
        if (v != null) headers[k.toString()] = v.toString();
      });
    }
    final method = (req['method'] as String? ?? 'GET').toUpperCase();
    final host = Uri.tryParse(url)?.host ?? '';
    // Only the plugin's own site may be fetched through the web view, which
    // keeps every site's cookies (logins too) in one place.
    final browser = method == 'GET' && sameSite(host, p.site) ? viaBrowser : null;
    try {
      if (browser != null && _browserHosts.contains(host)) {
        // The web view is held to the open internet as the app's own
        // requests are.
        await Net.vet(host);
        final html = await browser(url);
        if (html != null) return _page(url, html);
      }
      final r = await Net.instance.request(
        url,
        method: method,
        headers: headers,
        body: req['body'] as String?,
        partition: p.id,
      );
      if (r.isChallenge && browser != null) {
        final html = await browser(url);
        if (html != null) {
          if (_browserHosts.add(host)) onBrowserHost?.call(host);
          return _page(url, html);
        }
      }
      if (r.isChallenge) {
        for (final c in p.calls) {
          c.challenged.add(url);
        }
      }
      return jsonEncode({
        'status': r.status,
        'statusText': '',
        'url': r.url,
        'redirected': r.url != url,
        'headers': r.headers,
        'body': r.text(req['encoding'] as String?),
      });
    } on Object catch (e) {
      // A network failure looks to the plugin like a failed response, which
      // is what a browser fetch would report as well.
      return _failed(url, '$e');
    }
  }

  static String _failed(String url, String why) => jsonEncode({
        'status': 0,
        'statusText': why,
        'url': url,
        'redirected': false,
        'headers': const <String, String>{},
        'body': '',
      });

  static String _page(String url, String html) => jsonEncode({
        'status': 200,
        'statusText': '',
        'url': url,
        'redirected': false,
        'headers': const {'content-type': 'text/html; charset=utf-8'},
        'body': html,
      });

  final _stores = <String, Map<String, String>>{};

  Map<String, String> _storeOf(String pluginId) => _stores.putIfAbsent(pluginId, () {
        try {
          final f = File(_storagePath(pluginId));
          if (f.existsSync()) {
            return Map<String, String>.from(jsonDecode(f.readAsStringSync()) as Map);
          }
        } on Object {
          // Start empty.
        }
        return <String, String>{};
      });

  String _storagePath(String id) =>
      '$sourcesDir/storage-${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  void _saveStore(String pluginId) {
    try {
      final f = File(_storagePath(pluginId));
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_storeOf(pluginId)), flush: true);
      tmp.renameSync(f.path);
    } on Object {
      // Settings are kept in memory for this session regardless.
    }
  }

  /// Synchronous: plugins read settings while they load. The store is
  /// [p]'s own, whatever the JavaScript names: `[op, key, value]`.
  Object? _storage(_Plugin p, List<Object?> args) {
    final op = args[0] as String;
    final store = _storeOf(p.id);
    switch (op) {
      case 'get':
        return store['${args[1]}'];
      case 'set':
        store['${args[1]}'] = '${args[2]}';
        _saveStore(p.id);
        return null;
      case 'delete':
        store.remove('${args[1]}');
        _saveStore(p.id);
        return null;
      case 'clearAll':
        store.clear();
        _saveStore(p.id);
        return null;
      case 'keys':
        return jsonEncode(store.keys.toList());
    }
    return null;
  }
}
