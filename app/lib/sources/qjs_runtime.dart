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
    // One context per source now (see PluginHost), so each gets less room;
    // the libraries and a long chapter list fit easily.
    memoryLimit: 128 << 20,
    // CPU milliseconds per evaluation: a plugin stuck in a loop is stopped.
    timeout: 30000,
  );

  bool _disposed = false;

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

  /// flutter_qjs's setTimeout keeps each callback until it has run; one
  /// still waiting would recreate the engine if it fired after dispose.
  @override
  bool get hasPendingTimers {
    if (_disposed) return false;
    final r = _rt.evaluate(
        "typeof __NATIVE_FLUTTER_JS__setTimeoutCallbacks === 'object' ? Object.keys(__NATIVE_FLUTTER_JS__setTimeoutCallbacks).length : 0");
    return !r.isError && r.stringResult != '0';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _rt.getEngineInstanceId();
    // The engine reports the references the plugin bridge kept as a leak
    // on every dispose, which says nothing useful here.
    runZoned(_rt.dispose, zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {}));
    JavascriptRuntime.channelFunctionsRegistered.remove(id);
  }
}
