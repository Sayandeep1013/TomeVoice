import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// A newer TomeVoice: offer to install it. Install downloads the APK for
/// this phone (64- or 32-bit) and opens Android's installer, which asks for
/// one last tap; apps from outside a store cannot skip that. A release
/// without an APK attached opens its page instead.
///
/// With [root], the app is offering it unasked, as it opens: the reader can
/// skip this version, and Later (or tapping beside the dialog) waits a few
/// days before offering it again.
Future<void> offerUpdate(BuildContext context, AppUpdate update, {Directory? root}) async {
  final is64 = await _svc.is64Bit();
  final apk = is64 ? update.apk64 : update.apk32;
  if (!context.mounted) return;
  if (apk == null && root == null) {
    await _svc.openUrl(update.url);
    return;
  }
  final size = update.sizeMb(is64: is64);
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(root == null ? 'TomeVoice ${update.version}' : 'New version available'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${root == null ? '' : 'TomeVoice ${update.version} is ready. '}'
            '${size == null ? 'Download' : 'A $size MB download'}, then Android asks you to confirm the update. '
            'Your library and settings stay as they are.',
          ),
          const SizedBox(height: Gap.s),
          // Links rather than buttons: four buttons do not fit across a phone.
          Wrap(
            children: [
              TextButton(
                onPressed: () => unawaited(_svc.openUrl(update.url)),
                child: const Text("What's new"),
              ),
              if (root != null)
                TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: const Text('Skip this version')),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'later'), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'install'), child: const Text('Install')),
      ],
    ),
  );
  if (root != null) {
    if (choice == 'skip') await AppUpdates.skip(root, update);
    if (choice == null || choice == 'later') await AppUpdates.putOff(root, update);
  }
  if (choice != 'install' || !context.mounted) return;
  if (apk == null) {
    await _svc.openUrl(update.url);
    return;
  }

  final progress = ValueNotifier<double?>(null);
  var cancelled = false;
  // Stops the download at once, even while nothing is arriving.
  final stop = Completer<void>();
  // Captured now: the dialog is closed through it even if this screen goes.
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Downloading ${update.version}'),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              if (!stop.isCompleted) stop.complete();
            },
            child: const Text('Cancel'),
          ),
        ],
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: v, color: Skin.accentOf(context)),
              const SizedBox(height: Gap.m),
              Text(v == null ? 'Starting…' : '${(v * 100).round()}%'),
            ],
          ),
        ),
      ),
    ),
  ));
  String? file;
  String? failed;
  try {
    file = await _download(apk, 'TomeVoice-${update.version}.apk', progress, stop.future);
  } on Object {
    failed = cancelled ? null : 'The download did not finish. Check the internet connection and try again.';
  }
  nav.pop();
  progress.dispose();
  if (!context.mounted) return;
  if (file == null) {
    if (cancelled) return;
    showSnack(context, failed ?? 'The download did not finish.', long: true);
    return;
  }
  await _install(context, file);
}

/// Hand [path] to Android's installer. The first time Android asks whether
/// TomeVoice may install apps; once that is allowed, Install goes on.
Future<void> _install(BuildContext context, String path) async {
  final r = await _svc.installApk(path);
  if (!context.mounted) return;
  if (r == 'notOurs') {
    showSnack(context, 'That download was not a TomeVoice update, so it was not installed.', long: true);
    return;
  }
  if (r != 'permission') return;
  final again = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('One step for Android'),
      content: const Text(
        'Android opened a setting: turn on "Allow from this source" for TomeVoice, '
        'come back, and tap Install.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install')),
      ],
    ),
  );
  if (again == true && context.mounted) await _install(context, path);
}

/// APKs left by earlier updates (about 30 MB each), installed or put off: the
/// folder the installer reads kept every one. Shared pictures stay.
Future<void> sweepUpdateDownloads() async {
  final dir = await _svc.shareDir();
  if (dir == null) return;
  try {
    await for (final e in Directory(dir).list()) {
      if (e is File && e.path.endsWith('.apk')) await e.delete();
    }
  } on FileSystemException {
    // Tried again next start.
  }
}

/// Fetch [url] into the folder the installer can read, as [name]. Stops when
/// [stop] completes, or after 30 seconds with nothing arriving.
Future<String> _download(String url, String name, ValueNotifier<double?> progress, Future<void> stop) async {
  final dir = await _svc.shareDir();
  if (dir == null) throw const FileSystemException('No room for the download');
  final out = File('$dir/$name');
  final part = File('${out.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  // Closing the client ends whatever it is waiting for with an error.
  unawaited(stop.then((_) => client.close(force: true)));
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'TomeVoice');
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final total = res.contentLength;
    sink = part.openWrite();
    var got = 0;
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress.value = got / total;
    }
    await sink.close();
    sink = null;
    if (total > 0 && got != total) throw const HttpException('The download was cut short');
    await part.rename(out.path);
    return out.path;
  } finally {
    client.close(force: true);
    try {
      await sink?.close();
    } on Object {
      // Already failed; the part file goes below.
    }
    if (await part.exists()) await part.delete();
  }
}
