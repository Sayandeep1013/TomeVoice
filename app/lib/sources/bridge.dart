import 'dart:async';

import 'package:flutter/services.dart';

/// Web novels' calls to the platform, on a channel of their own
/// (SourcesBridge.kt). It is registered on the app's engine and on the one
/// the background check starts, where the app's main channel does not exist.
/// Every call answers null (or false) where the platform does not (tests,
/// or a call only the app's engine has).
class SourcesBridge {
  const SourcesBridge._();

  static const _channel = MethodChannel('tomevoice/sources');

  static Future<T?> _ask<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on Object {
      return null;
    }
  }

  /// Internal app storage, where sources live (no other app can read it).
  static Future<String?> sourcesRoot() => _ask<String>('sourcesRoot');

  /// The library's folder (external app storage), as MainActivity has it.
  static Future<String?> libraryRoot() => _ask<String>('libraryRoot');
}
