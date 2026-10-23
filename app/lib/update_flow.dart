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
Future<void> offerUpdate(BuildContext context, AppUpdate update) async {
  final is64 = await _svc.is64Bit();
  final apk = is64 ? update.apk64 : update.apk32;
  if (!context.mounted) return;
  if (apk == null) {
    await _svc.openUrl(update.url);
    return;
  }
  final size = update.sizeMb(is64: is64);
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('TomeVoice ${update.version}'),
      content: Text(
        '${size == null ? 'Download' : 'A $size MB download'}, then Android asks you to confirm the update. '
        'Your library and settings stay as they are.',
      ),
      actions: [
        TextButton(
          onPressed: () {
            unawaited(_svc.openUrl(update.url));
          },
          child: const Text("What's new"),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final progress = ValueNotifier<double?>(null);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Downloading ${update.version}'),
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
    file = await _download(apk, 'TomeVoice-${update.version}.apk', progress);
  } on Object {
    failed = 'The download did not finish. Check the internet connection and try again.';
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  if (file == null) {
    showSnack(context, failed ?? 'The download did not finish.', long: true);
    return;
  }
  await _install(context, file);
}

/// Hand [path] to Android's installer. The first time Android asks whether
/// TomeVoice may install apps; once that is allowed, Install goes on.
Future<void> _install(BuildContext context, String path) async {
  final r = await _svc.installApk(path);
  if (r != 'permission' || !context.mounted) return;
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

/// Fetch [url] into the folder the installer can read, as [name].
Future<String> _download(String url, String name, ValueNotifier<double?> progress) async {
  final dir = await _svc.shareDir();
  if (dir == null) throw const FileSystemException('No room for the download');
  final out = File('$dir/$name');
  final part = File('${out.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'TomeVoice');
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final total = res.contentLength;
    final sink = part.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress.value = got / total;
    }
    await sink.close();
    if (total > 0 && got != total) throw const HttpException('The download was cut short');
    await part.rename(out.path);
    return out.path;
  } finally {
    client.close(force: true);
    if (await part.exists()) await part.delete();
  }
}
