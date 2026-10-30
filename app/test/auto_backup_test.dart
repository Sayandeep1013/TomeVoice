// Automatic backups: when one is due, what is written where (the backup
// writer, without downloaded chapters unless asked), the newest five kept
// and nothing else in the folder touched, a folder taken away said plainly,
// and the settings kept and restored.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/auto_backup.dart';
import 'package:tomevoice_spike/backup.dart';
import 'package:tomevoice_spike/folders.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/prefs.dart';

const _channel = MethodChannel('tomevoice/tts');

FolderFile _file(String name, {int minute = 0}) =>
    (id: 'doc:$name', name: name, size: 100, modified: DateTime(2026, 1, 1, 0, minute));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late List<MethodCall> calls;
  late List<Map<String, Object?>> inFolder;
  PlatformException? refuse;
  const folder = PickedFolder('content://com.android.externalstorage.documents/tree/primary%3ABackups', 'Backups');

  setUp(() {
    ListeningPrefs.reset();
    AutoBackup.problem.value = null;
    tmp = Directory.systemTemp.createTempSync('tomevoice_auto');
    calls = [];
    inFolder = [];
    refuse = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final args = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
      switch (call.method) {
        case 'backupToFolder':
          if (refuse != null) throw refuse!;
          inFolder.add({'id': 'doc:${args['name']}', 'name': args['name'], 'size': 1234, 'modified': 0});
          return {'files': 3, 'bytes': 1234, 'name': args['name']};
        case 'listFolder':
          return inFolder;
        case 'deleteFromFolder':
          inFolder.removeWhere((f) => f['id'] == args['id']);
          return null;
        case 'appVersion':
          return '1.2.2';
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  List<String> backupsWritten() => [for (final c in calls) if (c.method == 'backupToFolder') (c.arguments as Map)['name'] as String];

  test('due daily, weekly or never', () {
    final now = DateTime(2026, 10, 30, 9);
    expect(backupDue(BackupEvery.off, null, now), isFalse);
    expect(backupDue(BackupEvery.daily, null, now), isTrue);
    // Opened at about the same time each day: each day.
    expect(backupDue(BackupEvery.daily, DateTime(2026, 10, 29, 9, 10), now), isTrue);
    expect(backupDue(BackupEvery.daily, DateTime(2026, 10, 30, 7), now), isFalse);
    expect(backupDue(BackupEvery.weekly, DateTime(2026, 10, 25), now), isFalse);
    expect(backupDue(BackupEvery.weekly, DateTime(2026, 10, 23, 10), now), isTrue);
    // A clock put back: due, rather than never again.
    expect(backupDue(BackupEvery.daily, DateTime(2027), now), isTrue);
    expect(BackupEvery.byName('fortnightly'), BackupEvery.off);
  });

  test('names sort by time; only automatic ones beyond the newest five go', () {
    expect(autoBackupName(DateTime(2026, 3, 4, 5, 6)), 'TomeVoice-auto-backup-2026-03-04-0506.zip');
    final files = [
      for (var d = 1; d <= 8; d++) _file(autoBackupName(DateTime(2026, 1, d, 9))),
      _file(backupFileName(DateTime(2026, 1, 1))), // Saved by hand.
      _file('notes.md'),
    ]..shuffle();
    final gone = backupsToPrune(files);
    expect([for (final f in gone) f.name]..sort(), [
      autoBackupName(DateTime(2026, 1, 1, 9)),
      autoBackupName(DateTime(2026, 1, 2, 9)),
      autoBackupName(DateTime(2026, 1, 3, 9)),
    ]);
    expect(backupsToPrune(files.take(3).toList()), isEmpty);
  });

  test('nothing happens while off, or without a folder', () async {
    final store = LibraryStore(tmp);
    final prefs = ListeningPrefs.memory;
    expect(await AutoBackup.runIfDue(store), isFalse);
    expect(calls.where((c) => c.method == 'backupToFolder'), isEmpty);

    prefs.backupEvery = 'daily';
    expect(await AutoBackup.runIfDue(store), isFalse);
    expect(AutoBackup.problem.value, contains('Choose a folder'));
    expect(calls.where((c) => c.method == 'backupToFolder'), isEmpty);
  });

  test('a backup when due, without downloaded chapters, then not again until the next', () async {
    final store = LibraryStore(tmp);
    final prefs = ListeningPrefs.memory
      ..backupEvery = 'daily'
      ..backupFolder = folder;
    final now = DateTime(2026, 10, 30, 9, 15);
    expect(await AutoBackup.runIfDue(store, now: now), isTrue);
    final call = calls.singleWhere((c) => c.method == 'backupToFolder');
    final args = Map<String, Object?>.from(call.arguments as Map);
    expect(args['tree'], folder.uri);
    expect(args['name'], 'TomeVoice-auto-backup-2026-10-30-0915.zip');
    expect(args['includeChapters'], isFalse);
    final manifest = BackupInfo.fromJson(Map<String, Object?>.from(jsonDecode(args['manifest'] as String) as Map));
    expect(manifest.format, backupFormat);
    expect(manifest.chapters, isFalse);
    expect(manifest.root, tmp.path);
    expect(manifest.created, now);
    expect(prefs.lastBackup, now);
    expect(AutoBackup.problem.value, isNull);

    expect(await AutoBackup.runIfDue(store, now: now.add(const Duration(hours: 3))), isFalse);
    expect(await AutoBackup.runIfDue(store, now: now.add(const Duration(days: 1))), isTrue);
    expect(backupsWritten(), hasLength(2));

    prefs.backupChapters = true;
    await AutoBackup.backUpNow(store, now: now.add(const Duration(days: 2)));
    expect((calls.lastWhere((c) => c.method == 'backupToFolder').arguments as Map)['includeChapters'], isTrue);
  });

  test('the newest five automatic backups are kept; nothing else is touched', () async {
    final store = LibraryStore(tmp);
    ListeningPrefs.memory
      ..backupEvery = 'weekly'
      ..backupFolder = folder;
    for (var w = 1; w <= 6; w++) {
      final f = _file(autoBackupName(DateTime(2026, 8, w * 7)));
      inFolder.add({'id': f.id, 'name': f.name, 'size': f.size, 'modified': 0});
    }
    inFolder.add({'id': 'doc:mine', 'name': backupFileName(DateTime(2026, 1, 1)), 'size': 9, 'modified': 0});
    inFolder.add({'id': 'doc:notes', 'name': 'Quotes - quotes.md', 'size': 9, 'modified': 0});
    expect(await AutoBackup.runIfDue(store, now: DateTime(2026, 10, 30, 8)), isTrue);
    final names = [for (final f in inFolder) f['name'] as String];
    expect(names.where((n) => n.startsWith(autoBackupPrefix)), hasLength(autoBackupsKept));
    expect(names, contains('TomeVoice-auto-backup-2026-10-30-0800.zip'));
    expect(names, isNot(contains(autoBackupName(DateTime(2026, 8, 7)))));
    expect(names, isNot(contains(autoBackupName(DateTime(2026, 8, 14)))));
    expect(names, containsAll([backupFileName(DateTime(2026, 1, 1)), 'Quotes - quotes.md']));
  });

  test('a folder taken away is said plainly, and the last backup stays as it was', () async {
    final store = LibraryStore(tmp);
    final prefs = ListeningPrefs.memory
      ..backupEvery = 'daily'
      ..backupFolder = folder
      ..lastBackup = DateTime(2026, 10, 1);
    refuse = PlatformException(code: 'FOLDER', message: 'gone');
    expect(await AutoBackup.runIfDue(store, now: DateTime(2026, 10, 30)), isFalse);
    expect(AutoBackup.problem.value, contains('Choose the folder again'));
    expect(prefs.lastBackup, DateTime(2026, 10, 1));
    expect(AutoBackup.running.value, isFalse);
  });

  test('the settings are kept, and a backup restored brings them back', () async {
    final before = ListeningPrefs.fromJson(const {});
    expect(before.backupEvery, 'off');
    expect(before.backupFolder, isNull);
    expect(before.backupChapters, isFalse);
    expect(before.lastBackup, isNull);

    final mine = ListeningPrefs()
      ..backupEvery = 'weekly'
      ..backupFolder = folder
      ..backupChapters = true
      ..lastBackup = DateTime(2026, 10, 29, 21, 5)
      ..notesAloud = true
      ..exportFolder = const PickedFolder('content://x/tree/notes', 'Notes');
    final back = ListeningPrefs.fromJson(mine.toJson());
    expect(back.backupEvery, 'weekly');
    expect(back.backupFolder?.uri, folder.uri);
    expect(back.backupFolder?.name, 'Backups');
    expect(back.backupChapters, isTrue);
    expect(back.lastBackup, DateTime(2026, 10, 29, 21, 5));
    expect(back.notesAloud, isTrue);
    expect(back.exportFolder?.name, 'Notes');

    // Add, taking the backup's settings: they are this phone's now.
    final staging = Directory('${tmp.path}/.restore')..createSync();
    File('${staging.path}/library.json').writeAsStringSync(jsonEncode({'categories': [], 'books': []}));
    File('${staging.path}/prefs.json').writeAsStringSync(jsonEncode(mine.toJson()));
    final staged = StagedBackup(
      staging,
      BackupInfo(format: backupFormat, created: DateTime(2026), root: tmp.path, books: 0, chapters: false),
    );
    final report = await addToLibrary(tmp, staged, settings: true);
    expect(report.settings, isTrue);
    ListeningPrefs.reset();
    final restored = await ListeningPrefs.load(tmp.path);
    expect(restored.backupEvery, 'weekly');
    expect(restored.backupFolder?.uri, folder.uri);
    expect(restored.notesAloud, isTrue);
  });
}
