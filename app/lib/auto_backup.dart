import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'backup.dart';
import 'folders.dart';
import 'library_store.dart';
import 'prefs.dart';
import 'speech_service.dart';

/// How often the library backs itself up into the folder the reader picked.
enum BackupEvery {
  off('Off', Duration.zero),
  daily('Daily', Duration(hours: 20)),
  weekly('Weekly', Duration(days: 6, hours: 20));

  const BackupEvery(this.label, this.gap);
  final String label;

  /// The least time between two backups: a little under the day or week,
  /// so a phone opened at about the same time each day backs up each day.
  final Duration gap;

  static BackupEvery byName(String? name) => values.where((e) => e.name == name).firstOrNull ?? off;
}

/// Automatic backups are named apart from the ones saved by hand, which
/// are never deleted to make room.
const autoBackupPrefix = 'TomeVoice-auto-backup-';

/// How many automatic backups are kept in the folder.
const autoBackupsKept = 5;

/// "TomeVoice-auto-backup-2026-10-30-0915.zip": in date order by name.
String autoBackupName(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '$autoBackupPrefix${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}.zip';
}

/// Whether a backup is due at [now], the last having been made at [last].
bool backupDue(BackupEvery every, DateTime? last, DateTime now) {
  if (every == BackupEvery.off) return false;
  if (last == null || last.isAfter(now)) return true;
  return now.difference(last) >= every.gap;
}

/// The automatic backups in [files] beyond the newest [keep]; anything
/// else in the folder is left alone.
List<FolderFile> backupsToPrune(List<FolderFile> files, {int keep = autoBackupsKept}) {
  final ours = [
    for (final f in files)
      if (f.name.startsWith(autoBackupPrefix) && f.name.toLowerCase().endsWith('.zip')) f,
  ]..sort((a, b) {
      final byName = b.name.compareTo(a.name);
      return byName != 0 ? byName : b.modified.compareTo(a.modified);
    });
  return ours.length <= keep ? const [] : ours.sublist(keep);
}

/// Backs the library up when one is due: on opening the app, and on coming
/// back to it. Uses the backup writer Settings > Back up library uses,
/// without downloaded chapters unless the reader asked for them.
class AutoBackup {
  AutoBackup._();

  /// What went wrong last time, for Settings; null when it went well.
  static final problem = ValueNotifier<String?>(null);

  /// Set while a backup is being written.
  static final running = ValueNotifier<bool>(false);

  static AppLifecycleListener? _lifecycle;

  static ListeningPrefs get _prefs => ListeningPrefs.loaded ?? ListeningPrefs.memory;

  /// Check a moment after the app opens (once the shelf is up and quiet),
  /// and whenever it comes back. Not in widget tests, which have no folder.
  static void start(LibraryStore store, {Duration after = const Duration(seconds: 10)}) {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    Future<void>.delayed(after, () => runIfDue(store));
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(runIfDue(store)));
  }

  /// A backup, if one is due and a folder has been picked.
  static Future<bool> runIfDue(LibraryStore store, {DateTime? now, Folders folders = const Folders()}) async {
    final p = _prefs;
    final at = now ?? DateTime.now();
    if (!backupDue(BackupEvery.byName(p.backupEvery), p.lastBackup, at)) return false;
    return backUpNow(store, now: at, folders: folders);
  }

  /// Back up into the picked folder now, keeping the newest few. False,
  /// with [problem] saying why, when it could not.
  static Future<bool> backUpNow(LibraryStore store, {DateTime? now, Folders folders = const Folders()}) async {
    if (running.value) return false;
    final p = _prefs;
    final folder = p.backupFolder;
    if (folder == null) {
      problem.value = 'Choose a folder for the backups.';
      return false;
    }
    final at = now ?? DateTime.now();
    running.value = true;
    try {
      // The places kept in memory go into library.json first (see saveCursor).
      await store.settlePlaces();
      final info = BackupInfo(
        format: backupFormat,
        created: at,
        root: store.root.path,
        // Counted as a backup saved by hand counts them.
        books: (await store.list()).length,
        chapters: p.backupChapters,
        appVersion: await const SpeechService().appVersion(),
      );
      await folders.backUp(
        folder,
        name: autoBackupName(at),
        manifest: jsonEncode(info.toJson()),
        includeChapters: p.backupChapters,
      );
      // Room for the next: the oldest automatic ones go.
      try {
        for (final old in backupsToPrune(await folders.list(folder))) {
          await folders.delete(folder, old.id);
        }
      } on PlatformException {
        // Kept until the next backup tries again.
      }
      p.lastBackup = at;
      p.save();
      problem.value = null;
      return true;
    } on PlatformException catch (e) {
      problem.value = e.code == 'FOLDER'
          ? 'TomeVoice can no longer write to ${folder.name}. Choose the folder again.'
          : 'The last backup failed: ${e.message ?? e.code}';
      return false;
    } on Object catch (e) {
      problem.value = 'The last backup failed: $e';
      return false;
    } finally {
      running.value = false;
    }
  }
}
