import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'speech_service.dart';

/// A release newer than the one installed.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.url,
    required this.title,
    this.apk64,
    this.apk32,
    this.bytes64 = 0,
    this.bytes32 = 0,
  });

  /// "0.6.0".
  final String version;

  /// The release page, where the APK is.
  final String url;
  final String title;

  /// The APKs attached to the release, for 64- and 32-bit phones, if any.
  final String? apk64;
  final String? apk32;
  final int bytes64;
  final int bytes32;

  /// The download's size in MB, rounded up, or null if unknown.
  int? sizeMb({required bool is64}) {
    final b = is64 ? bytes64 : bytes32;
    return b <= 0 ? null : (b / (1024 * 1024)).ceil();
  }
}

/// Whether there is a newer TomeVoice on GitHub.
///
/// TomeVoice is not in a store, so nothing else tells people a new version is
/// out. Once a day the app asks GitHub for the latest release: one request,
/// no account, nothing sent but the request itself. It can be turned off.
class AppUpdates {
  AppUpdates._();

  static const releasesApi = 'https://api.github.com/repos/Sayandeep1013/TomeVoice/releases/latest';
  static const _every = Duration(hours: 24);

  /// The newer release, once one has been seen.
  static final available = ValueNotifier<AppUpdate?>(null);

  static File _file(Directory root) => File('${root.path}/app_update.json');

  static Future<Map<String, Object?>> _read(Directory root) async {
    try {
      final f = _file(root);
      if (await f.exists()) return Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map);
    } on Object {
      // Start again.
    }
    return {};
  }

  static Future<void> _write(Directory root, Map<String, Object?> state) async {
    try {
      await _file(root).writeAsString(jsonEncode(state));
    } on Object {
      // Next check tries again.
    }
  }

  static Future<bool> enabled(Directory root) async => (await _read(root))['enabled'] != false;

  static Future<void> setEnabled(Directory root, bool on) async =>
      _write(root, {...await _read(root), 'enabled': on});

  /// Ask GitHub, at most once a day unless [force]. Returns the newer release,
  /// or null when this is the latest (or the check could not run and [force]
  /// is false).
  static Future<AppUpdate?> check(Directory root, {bool force = false}) async {
    final state = await _read(root);
    if (!force && state['enabled'] == false) return null;
    var last = DateTime.tryParse(state['checked'] as String? ?? '');
    // A date in the future would keep the stored answer for ever.
    if (last != null && last.isAfter(DateTime.now())) last = null;
    final installed = await const SpeechService().appVersion();
    Map<String, Object?>? latest;
    if (!force && last != null && DateTime.now().difference(last) < _every) {
      latest = (state['latest'] as Map?)?.cast<String, Object?>();
    } else {
      latest = await _fetch();
      if (latest == null && force) throw const SocketException('Could not reach GitHub');
      if (latest != null) {
        await _write(root, {...state, 'checked': DateTime.now().toIso8601String(), 'latest': latest});
      }
    }
    final update = latest == null ? null : _newer(latest, installed);
    available.value = update;
    return update;
  }

  /// Whether the reader was already told about [update].
  static Future<bool> told(Directory root, AppUpdate update) async =>
      (await _read(root))['told'] == update.version;

  static Future<void> markTold(Directory root, AppUpdate update) async =>
      _write(root, {...await _read(root), 'told': update.version});

  static Future<Map<String, Object?>?> _fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(releasesApi));
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'TomeVoice')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      // TomeVoice-1.0.0.apk for 64-bit phones, TomeVoice-1.0.0-32bit.apk
      // for older ones.
      final apks = [
        for (final a in (body['assets'] as List? ?? const []))
          if (a is Map && '${a['name']}'.endsWith('.apk')) a,
      ];
      Map? pick(bool bit32) => apks.where((a) => '${a['name']}'.endsWith('-32bit.apk') == bit32).firstOrNull;
      return {
        'tag': body['tag_name'],
        'url': body['html_url'],
        'title': body['name'],
        'apk64': pick(false)?['browser_download_url'],
        'apk32': pick(true)?['browser_download_url'],
        'bytes64': pick(false)?['size'],
        'bytes32': pick(true)?['size'],
      };
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static AppUpdate? _newer(Map<String, Object?> latest, String? installed) {
    final tag = (latest['tag'] as String? ?? '').replaceFirst(RegExp('^v'), '');
    if (tag.isEmpty || installed == null) return null;
    if (compareVersions(tag, installed) <= 0) return null;
    return AppUpdate(
      version: tag,
      url: latest['url'] as String? ?? 'https://github.com/Sayandeep1013/TomeVoice/releases/latest',
      title: latest['title'] as String? ?? 'TomeVoice $tag',
      apk64: _ours(latest['apk64']),
      apk32: _ours(latest['apk32']),
      bytes64: (latest['bytes64'] as num?)?.toInt() ?? 0,
      bytes32: (latest['bytes32'] as num?)?.toInt() ?? 0,
    );
  }
}

/// [url] if it is an APK attached to one of TomeVoice's own releases; null
/// otherwise, so nothing else is ever offered for install.
String? _ours(Object? url) =>
    url is String &&
            url.startsWith('https://github.com/Sayandeep1013/TomeVoice/releases/download/') &&
            // No "..": it would lead out of TomeVoice's releases once resolved.
            !url.contains('..') &&
            !url.contains('%')
        ? url
        : null;

/// Compare "0.10.1" with "0.9" as versions: negative, zero or positive.
/// Anything after a "+" or "-" (build numbers, "-beta") is ignored.
@visibleForTesting
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      [for (final p in v.split(RegExp(r'[+-]')).first.split('.')) int.tryParse(p.trim()) ?? 0];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}
