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

  /// [bytes] as text in [charset] (any the phone knows: GBK, Big5,
  /// Shift_JIS, windows-1251…); null when it cannot (an unknown name, or no
  /// platform, as in tests).
  static Future<String?> decode(Uint8List bytes, String charset) =>
      _ask<String>('decode', {'bytes': bytes, 'charset': charset});

  /// Forget the phone's web view cookies (browser checks, sign-ins): all of
  /// them, or those of [url]'s site.
  static Future<void> clearWebCookies({String? url}) => _ask<void>('clearWebCookies', {'url': url});

  // ------------------------------------------------- the background check

  /// Have Android run the Dart function behind [handle] (a callback handle,
  /// see background_check.dart) every [minutes], with the network the
  /// reader allows ([unmetered]: Wi-Fi only) and the battery not low;
  /// [minutes] 0 stops it.
  static Future<void> scheduleChecks({required int handle, required int minutes, bool unmetered = true}) =>
      _ask<void>('scheduleChecks', {'handle': handle, 'minutes': minutes, 'unmetered': unmetered});

  /// The background check is done: [outcome] says what to tell the reader
  /// ({found, title, text, lines}). Ends its engine.
  static Future<void> backgroundDone(Map<String, Object?> outcome) => _ask<void>('backgroundDone', outcome);

  /// Whether a background check is running now (the app then leaves its
  /// own check on opening to it).
  static Future<bool> backgroundBusy() async => await _ask<bool>('backgroundBusy') ?? false;

  /// Whether TomeVoice may post notifications (asked for on Android 13 and
  /// later); null where the platform does not say.
  static Future<bool?> notificationsAllowed() => _ask<bool>('notificationsAllowed');

  /// Ask the reader (Android 13 and later) to let TomeVoice notify them.
  static Future<void> askNotifications() => _ask<void>('askNotifications');

  /// Chapters downloading ({title, text, done, total}): shown in a
  /// notification, with a foreground service keeping the app alive while it
  /// is in the background. Null: done, or paused.
  static Future<void> downloadProgress(Map<String, Object?>? progress) =>
      _ask<void>('downloadProgress', progress == null ? const {'active': false} : {'active': true, ...progress});
}
