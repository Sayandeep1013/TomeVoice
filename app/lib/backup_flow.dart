import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'backup.dart';
import 'library_store.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// "92 MB", "640 KB".
String sizeLabel(int bytes) {
  if (bytes < 0) return '';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

/// Settings → Back up library: choose what goes in, where it goes, then
/// write it with a progress bar.
Future<void> runBackup(BuildContext context, LibraryStore store) async {
  final sizes = await Future.wait([
    _svc.backupSize(includeChapters: true),
    _svc.backupSize(includeChapters: false),
  ]);
  if (!context.mounted) return;
  final all = sizes[0];
  final lean = sizes[1];
  final includeChapters = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Back up library', subtitle: 'One file with your books and places'),
          SheetAction(
            icon: Icons.inventory_2_outlined,
            label: 'Everything',
            detail: [
              if (all >= 0) 'About ${sizeLabel(all)}',
              'Books, places, categories, sources, settings and downloaded chapters',
            ].join(' · '),
            onTap: () => Navigator.pop(ctx, true),
          ),
          if (lean >= 0 && all - lean > 1024 * 1024)
            SheetAction(
              icon: Icons.compress_rounded,
              label: 'Without downloaded chapters',
              detail: 'About ${sizeLabel(lean)} · Web novel chapters download again after a restore',
              onTap: () => Navigator.pop(ctx, false),
            ),
          const SizedBox(height: Gap.s),
        ],
      ),
    ),
  );
  if (includeChapters == null || !context.mounted) return;

  final progress = ValueNotifier<double?>(null);
  var dialogOpen = false;
  // The save dialog comes first; the progress dialog only once writing starts.
  final sub = SpeechService.events.listen((e) {
    if (e['type'] != 'backupProgress') return;
    final total = (e['total'] as num?)?.toDouble() ?? 0;
    if (total > 0) progress.value = ((e['done'] as num?)?.toDouble() ?? 0) / total;
    if (!dialogOpen && context.mounted) {
      dialogOpen = true;
      unawaited(_progressDialog(context, 'Backing up', progress));
    }
  });
  String message;
  try {
    final r = await backUpLibrary(store, includeChapters: includeChapters);
    message = r == null ? '' : 'Backed up ${sizeLabel(r.bytes)}. Keep the file somewhere safe, such as Drive.';
  } on Object catch (e) {
    message = 'The backup failed: ${_reason(e)}';
  } finally {
    await sub.cancel();
  }
  if (!context.mounted) return;
  if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  if (message.isNotEmpty) showSnack(context, message, long: true);
}

/// Settings → Restore a backup: pick the file, unpack it, then add it to
/// the library or replace the library with it, and start again.
Future<void> runRestore(BuildContext context, LibraryStore store) async {
  final progress = ValueNotifier<double?>(null);
  var dialogOpen = false;
  final sub = SpeechService.events.listen((e) {
    if (e['type'] != 'restoreProgress' || dialogOpen || !context.mounted) return;
    dialogOpen = true;
    unawaited(_progressDialog(context, 'Reading the backup', progress));
  });
  StagedBackup? staged;
  try {
    staged = await pickBackup(store);
  } on Object catch (e) {
    await sub.cancel();
    if (!context.mounted) return;
    if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    showSnack(context, 'That backup could not be used: ${_reason(e)}', long: true);
    return;
  }
  await sub.cancel();
  if (!context.mounted) return;
  if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
  if (staged == null) return;

  final info = staged.info;
  final made = MaterialLocalizations.of(context).formatMediumDate(info.created);
  final how = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            'Restore a backup',
            subtitle: 'Made $made · ${info.books} ${info.books == 1 ? 'book' : 'books'}',
          ),
          SheetAction(
            icon: Icons.library_add_outlined,
            label: 'Add to my library',
            detail: 'Adds the books you don\'t have. For books in both, keeps whichever place is further',
            onTap: () => Navigator.pop(ctx, 'add'),
          ),
          SheetAction(
            icon: Icons.swap_horiz_rounded,
            label: 'Replace my library',
            detail: 'Your library and settings now are removed, and the backup takes their place',
            danger: true,
            onTap: () => Navigator.pop(ctx, 'replace'),
          ),
          const SizedBox(height: Gap.s),
        ],
      ),
    ),
  );
  if (how == null || !context.mounted) {
    await staged.discard();
    return;
  }
  if (how == 'replace' &&
      !await confirm(
        context,
        title: 'Replace your library?',
        body: 'The books, places and settings on this phone are removed and the backup\'s take their place. '
            'This cannot be undone.',
        action: 'Replace',
      )) {
    await staged.discard();
    return;
  }
  if (!context.mounted) return;
  unawaited(_progressDialog(context, how == 'add' ? 'Adding to your library' : 'Restoring', progress));
  try {
    if (how == 'add') {
      await addToLibrary(store.root, staged);
    } else {
      await replaceLibrary(store.root, staged);
    }
  } on Object catch (e) {
    await staged.discard();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    showSnack(context, 'The restore failed and your library was left as it was: ${_reason(e)}', long: true);
    return;
  }
  // Every store reads its files once; start the app again so all of them
  // read the restored ones.
  await _svc.restartApp();
}

Future<void> _progressDialog(BuildContext context, String title, ValueNotifier<double?> progress) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: v, color: Skin.amber),
                const SizedBox(height: Gap.m),
                Text(v == null ? 'Working…' : '${(v * 100).round()}%'),
              ],
            ),
          ),
        ),
      ),
    );

String _reason(Object e) => switch (e) {
      PlatformException(:final message, :final code) => message ?? code,
      FormatException(:final message) => message,
      _ => '$e',
    };
