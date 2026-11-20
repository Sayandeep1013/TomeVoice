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

  /// Set in a source worker (source_engine.dart): its calls go to the main
  /// isolate, which asks the platform and posts the answer back. A worker
  /// never calls the platform itself: one that ended while a call was out
  /// (a web view still loading a page) made Flutter's engine end the whole
  /// app when the answer came, as its port was gone.
  static Future<Object?> Function(String method, Map<String, Object?>? args)? relay;

  static Future<T?> _ask<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final via = relay;
      if (via != null) {
        final got = await via(method, args);
        return got is T ? got : null;
      }
      return await _channel.invokeMethod<T>(method, args);
    } on Object {
      return null;
    }
  }

  /// A worker's call, made here on the main isolate (see [relay]).
  static Future<Object?> answer(String method, Map<String, Object?>? args) => _ask<Object?>(method, args);

  /// Internal app storage, where sources live (no other app can read it).
  static Future<String?> sourcesRoot() => _ask<String>('sourcesRoot');

  /// The library's folder (external app storage), as MainActivity has it.
  static Future<String?> libraryRoot() => _ask<String>('libraryRoot');

  /// [bytes] as text in [charset] (any the phone knows: GBK, Big5,
  /// Shift_JIS, windows-1251…); null when it cannot (an unknown name, or no
  /// platform, as in tests).
  static Future<String?> decode(Uint8List bytes, String charset) =>
      _ask<String>('decode', {'bytes': bytes, 'charset': charset});

  /// The site at [url] in a web view, for the reader to sign in to, holding
  /// [seed] (a source's own cookies there, see Net.browserSeed) and nothing
  /// else: the cookies it has once they tap Done ({cookies, wide}, see
  /// Net.keepFromBrowser), or null if they closed it (or there is no web
  /// view). [userAgent] is the app's own.
  static Future<Map<Object?, Object?>?> browserLogin(String url, String userAgent, Map<String, Object?> seed) =>
      _ask<Map<Object?, Object?>>('browserLogin', {'url': url, 'userAgent': userAgent, ...seed});

  /// [url] in a web view nobody sees, holding [seed] alone, for a site
  /// that turns the app's own requests away ([method] POST sends [body] as
  /// a form): {html, url (where it ended), cookies, wide}, or null.
  static Future<Map<Object?, Object?>?> browserFetch(String url, String userAgent,
          {String method = 'GET', String? body, Map<String, Object?> seed = const {}}) =>
      _ask<Map<Object?, Object?>>(
          'browserFetch', {'url': url, 'userAgent': userAgent, 'method': method, 'body': body, ...seed});

  /// Forget the phone's web view cookies (browser checks, sign-ins): all of
  /// them, or those of [url]'s site. A visit leaves none there now; builds
  /// before 1.4 kept every source's there.
  static Future<void> clearWebCookies({String? url}) => _ask<void>('clearWebCookies', {'url': url});

  // ------------------------------------------------- the background check

  /// Have Android run the Dart function behind [handle] (a callback handle,
  /// see background_check.dart) every [minutes], with the network the
  /// reader allows ([unmetered]: Wi-Fi only) and the battery not low;
  /// [minutes] 0 stops it.
  static Future<void> scheduleChecks({
    required int handle,
    required int minutes,
    bool unmetered = true,
    bool charging = false,
  }) =>
      _ask<void>('scheduleChecks', {'handle': handle, 'minutes': minutes, 'unmetered': unmetered, 'charging': charging});

  /// MemoryBuildWorker runs the Dart function behind [handle] every
  /// [minutes] (0 stops it), on Wi-Fi only when [unmetered], only while
  /// charging when [charging].
  static Future<void> scheduleMemory({
    required int handle,
    required int minutes,
    bool unmetered = true,
    bool charging = false,
  }) =>
      _ask<void>('scheduleMemory', {'handle': handle, 'minutes': minutes, 'unmetered': unmetered, 'charging': charging});

  /// The background check is done: [outcome] says what to tell the reader
  /// ({found, title, text, lines}). Ends its engine.
  static Future<void> backgroundDone(Map<String, Object?> outcome) => _ask<void>('backgroundDone', outcome);

  /// How the app's runs ended since it last asked, where nothing in it
  /// could hear (PastExits.kt): error log entries, oldest first.
  static Future<List<Object?>> pastExits() async => await _ask<List<Object?>>('pastExits') ?? const [];

  /// Whether a background check is running now (the app then leaves its
  /// own check on opening to it).
  static Future<bool> backgroundBusy() async => await _ask<bool>('backgroundBusy') ?? false;

  /// Whether the app's own engine is up (asked by the background check
  /// before each write: it stops, and leaves the rest to the app).
  static Future<bool> appIsOpen() async => await _ask<bool>('appIsOpen') ?? false;

  /// Answer the background check's worker when it finds the app's own
  /// engine up (TomeVoice open, left in the background with Back, or a
  /// book read with no screen): rather than start a second engine, which
  /// must never write the library while this one may, it asks this one to
  /// check ("runCheck"), and posts what [check] says to tell the reader,
  /// as it would have from its own.
  static void answerChecks(Future<Map<String, Object?>> Function() check) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'runCheck') return check();
      throw MissingPluginException('No ${call.method} here');
    });
  }

  /// Whether the phone is on Wi-Fi now (a network not charged by the byte):
  /// what new chapters downloading by themselves wait for. Null where the
  /// platform does not say.
  static Future<bool?> unmetered() => _ask<bool>('unmetered');

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
