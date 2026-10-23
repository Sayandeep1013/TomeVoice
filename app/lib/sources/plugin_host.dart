import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'net.dart';

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
class ChallengeException extends SourceException {
  ChallengeException(this.url)
      : super('${Uri.tryParse(url)?.host ?? 'The site'} wants a quick browser check first.');

  final String url;
}

/// Runs LNReader source plugins in one [JsRuntime]: the libraries they use
/// (lnreader_libs.js), the host that hands them `require` (lnreader_shim.js),
/// and the plugins themselves, each loaded once and kept.
///
/// Fetch goes through [Net]; storage is a small JSON file per plugin.
class PluginHost {
  PluginHost(this.rt, {required this.libs, required this.shim, required this.sourcesDir});

  final JsRuntime rt;
  final String libs;
  final String shim;

  /// Where plugins' storage files live.
  final String sourcesDir;

  final _loaded = <String, String>{};

  /// Addresses that answered with a browser check, newest last.
  final _challenged = <String>[];
  final _meta = <String, Map<String, Object?>>{};
  bool _ready = false;

  void _init() {
    if (_ready) return;
    rt.onMessage('tv_fetch', _fetch);
    rt.onMessage('tv_storage', _storage);
    rt.eval(libs, name: 'lnreader_libs.js');
    rt.eval(shim, name: 'lnreader_shim.js');
    _ready = true;
  }

  /// What the plugin said about itself when loaded: filters, settings.
  Map<String, Object?> meta(String id) => _meta[id] ?? const {};

  /// Load (or reload, after an update) plugin [id] from [codePath].
  void ensure(String id, String version, String codePath) {
    _init();
    if (_loaded[id] == version) return;
    final code = File(codePath).readAsStringSync();
    final raw = rt.eval('__tvLoadPlugin(${jsonEncode(id)}, ${jsonEncode(code)})', name: id);
    _meta[id] = Map<String, Object?>.from(jsonDecode(raw) as Map);
    _loaded[id] = version;
  }

  /// Call [method] on plugin [id] with [args]; the result, decoded from JSON.
  ///
  /// When a request on the way met a browser check, throws
  /// [ChallengeException]: whatever the plugin made of that page is wrong.
  Future<Object?> call(String id, String method, List<Object?> args, {Duration? timeout}) async {
    final checks = _challenged.length;
    void challenged() {
      if (_challenged.length > checks) throw ChallengeException(_challenged.last);
    }

    try {
      final out = await rt.evalAsync(
        '__tvCall(${jsonEncode(id)}, ${jsonEncode(method)}, ${jsonEncode(jsonEncode(args))})',
        timeout: timeout ?? const Duration(seconds: 90),
      );
      challenged();
      return jsonDecode(out);
    } on TimeoutException {
      challenged();
      throw SourceException('The site took too long to answer.');
    } on JsException catch (e) {
      challenged();
      throw SourceException(_clean(e.message));
    }
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

  Future<String> _fetch(List<Object?> args) async {
    final url = args[0] as String;
    final req = Map<String, Object?>.from((args.length > 1 ? args[1] : null) as Map? ?? const {});
    final headers = <String, String>{..._defaultHeaders};
    final given = req['headers'];
    if (given is Map) {
      given.forEach((k, v) {
        if (v != null) headers[k.toString()] = v.toString();
      });
    }
    try {
      final r = await Net.instance.request(
        url,
        method: (req['method'] as String? ?? 'GET').toUpperCase(),
        headers: headers,
        body: req['body'] as String?,
      );
      if (r.isChallenge) _challenged.add(url);
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
      return jsonEncode({
        'status': 0,
        'statusText': '$e',
        'url': url,
        'redirected': false,
        'headers': const <String, String>{},
        'body': '',
      });
    }
  }

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
      File(_storagePath(pluginId)).writeAsStringSync(jsonEncode(_storeOf(pluginId)));
    } on Object {
      // Settings are kept in memory for this session regardless.
    }
  }

  /// Synchronous: plugins read settings while they load.
  Object? _storage(List<Object?> args) {
    final op = args[0] as String;
    final pluginId = args[1] as String;
    final store = _storeOf(pluginId);
    switch (op) {
      case 'get':
        return store[args[2] as String];
      case 'set':
        store[args[2] as String] = args[3] as String;
        _saveStore(pluginId);
        return null;
      case 'delete':
        store.remove(args[2] as String);
        _saveStore(pluginId);
        return null;
      case 'clearAll':
        store.clear();
        _saveStore(pluginId);
        return null;
      case 'keys':
        return jsonEncode(store.keys.toList());
    }
    return null;
  }
}
