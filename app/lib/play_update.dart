import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What Google Play says of the copy installed from it.
@immutable
class PlayUpdateInfo {
  const PlayUpdateInfo({
    required this.available,
    required this.versionCode,
    this.staleDays,
    this.downloaded = false,
    this.bytes = 0,
  });

  /// A newer version is on Play and can be installed in the background.
  final bool available;

  /// Play's number for the newer version (it gives no name, "2.9.0").
  final int versionCode;

  /// Days since Play first had it for this phone, when Play knows.
  final int? staleDays;

  /// It has been downloaded, and a restart installs it.
  final bool downloaded;

  final int bytes;

  /// The download's size in MB, rounded up, or null if unknown.
  int? get sizeMb => bytes <= 0 ? null : (bytes / (1024 * 1024)).ceil();

  static PlayUpdateInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return PlayUpdateInfo(
      available: raw['available'] == true,
      versionCode: (raw['versionCode'] as num?)?.toInt() ?? 0,
      staleDays: (raw['staleDays'] as num?)?.toInt(),
      downloaded: raw['downloaded'] == true,
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Google Play's in-app updates, in the Play build (PlayUpdates.kt).
///
/// The Play build cannot update itself from GitHub, and Play alone only
/// updates apps when it gets round to it, so the app asks Play whether a
/// newer version is out and offers it: Update downloads it in the
/// background while reading goes on, and Restart installs it. In the GitHub
/// build every call answers "nothing" (it updates from GitHub instead).
class PlayUpdates {
  PlayUpdates._();

  static const _channel = MethodChannel('tomevoice/play_update');

  /// While Play downloads: the share done (null while unknown).
  static final progress = ValueNotifier<double?>(null);

  /// Downloading now.
  static final downloading = ValueNotifier<bool>(false);

  /// Downloaded: a restart installs it.
  static final ready = ValueNotifier<bool>(false);

  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'progress':
          downloading.value = true;
          progress.value = (call.arguments as num?)?.toDouble();
        case 'downloaded':
          downloading.value = false;
          ready.value = true;
        case 'failed':
          downloading.value = false;
          progress.value = null;
      }
      return null;
    });
  }

  /// Ask Play. Null when Play cannot say (not installed from Play, no
  /// Play Store, offline) or in the GitHub build.
  static Future<PlayUpdateInfo?> check() async {
    _listen();
    try {
      final info = PlayUpdateInfo.fromMap(await _channel.invokeMethod<Object?>('check'));
      if (info?.downloaded == true) ready.value = true;
      return info;
    } on Object {
      return null;
    }
  }

  /// Show Play's own Update prompt; once the reader agrees, Play downloads
  /// it in the background. False when it could not be started.
  static Future<bool> start() async {
    _listen();
    try {
      final started = await _channel.invokeMethod<bool>('start') ?? false;
      if (started) {
        downloading.value = true;
        progress.value = null;
      }
      return started;
    } on Object {
      return false;
    }
  }

  /// Install what was downloaded: Play closes the app, installs it and
  /// opens it again.
  static Future<void> complete() async {
    try {
      await _channel.invokeMethod<bool>('complete');
    } on Object {
      // Play installs it the next time the app is closed.
    }
  }
}
