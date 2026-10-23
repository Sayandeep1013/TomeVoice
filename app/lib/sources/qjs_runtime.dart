import 'dart:async';

import 'package:flutter_qjs/flutter_qjs.dart';

import 'plugin_host.dart';

/// The QuickJS engine (kodjodevf/flutter_qjs, MIT; QuickJS by Fabrice
/// Bellard and Charlie Gordon, MIT).
JsRuntime createJsRuntime() => _QuickJs();

class _QuickJs implements JsRuntime {
  _QuickJs() {
    _rt.enableHandlePromises();
  }

  final _rt = QuickJsRuntime2(
    stackSize: 4 << 20,
    memoryLimit: 256 << 20,
    // CPU milliseconds per evaluation: a plugin stuck in a loop is stopped.
    timeout: 30000,
  );

  @override
  String eval(String code, {String name = '<eval>'}) {
    final r = _rt.evaluate(code, name: name);
    if (r.isError) throw JsException(r.stringResult);
    return r.stringResult;
  }

  @override
  Future<String> evalAsync(String code, {Duration timeout = const Duration(seconds: 90)}) async {
    final r = _rt.evaluate(code);
    if (r.isError) throw JsException(r.stringResult);
    try {
      final done = await _rt.handlePromise(r, timeout: timeout);
      if (done.isError) throw JsException(done.stringResult);
      return done.stringResult;
    } on TimeoutException {
      rethrow;
    } on JsException {
      rethrow;
    } on Object catch (e) {
      // A rejected promise arrives as the engine's own error type.
      throw JsException('$e');
    }
  }

  @override
  void onMessage(String channel, Object? Function(List<Object?> args) handler) {
    _rt.onMessage(channel, (dynamic args) => handler(args is List ? args.cast<Object?>() : [args]));
  }

  @override
  void dispose() => _rt.dispose();
}
