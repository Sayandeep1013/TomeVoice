// Backup and restore, on folders in temp: the zip itself is written and read
// by Kotlin, so these cover what Dart does with an unpacked backup: point its
// paths at this phone's folder, replace the library, or add to it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/app_update.dart';
import 'package:tomevoice_spike/backup.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late Directory staging;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_backup');
    root = Directory('${tmp.path}/files')..createSync();
    staging = stagingDir(root)..createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void put(Directory dir, String rel, Object json) {
    final f = File('${dir.path}/$rel')..createSync(recursive: true);
    f.writeAsStringSync(json is String ? json : jsonEncode(json));
  }

  Map<String, Object?> read(Directory dir, String rel) =>
      Map<String, Object?>.from(jsonDecode(File('${dir.path}/$rel').readAsStringSync()) as Map);

  Map<String, Object?> book(String id, {double progress = 0, String? category, String? root}) => {
        'id': id,
        'title': 'Book $id',
        'progress': progress,
        'cursor': {'sectionIndex': (progress * 10).round(), 'blockIndex': 0, 'sentenceIndex': 0},
        if (category != null) 'category': category,
        if (root != null) 'sourcePath': '$root/books/$id/source.epub',
      };

  StagedBackup staged({String from = '/old/files'}) => StagedBackup(
        staging,
        BackupInfo(format: backupFormat, created: DateTime(2026, 10, 24), root: from, books: 1, chapters: true),
      );

  test('paths are pointed at the folder the backup is restored into', () async {
    put(staging, 'library.json', {
      'books': [book('a', root: '/old/files')],
    });
    await checkStaged(staged(), root);
    final books = read(staging, 'library.json')['books'] as List;
    expect((books.single as Map)['sourcePath'], '${root.path}/books/a/source.epub');
  });

  test('a backup from a newer format is refused', () async {
    put(staging, 'library.json', {'books': []});
    final newer = StagedBackup(
      staging,
      BackupInfo(format: backupFormat + 1, created: DateTime(2026), root: '', books: 0, chapters: true),
    );
    expect(() => checkStaged(newer, root), throwsFormatException);
  });

  test('replace swaps the whole library and leaves nothing behind', () async {
    put(root, 'library.json', {
      'books': [book('mine')],
    });
    put(root, 'books/mine/cursor.json', {'x': 1});
    put(root, 'prefs.json', {'palette': 'forest'});
    put(staging, 'library.json', {
      'books': [book('theirs')],
    });
    put(staging, 'books/theirs/cursor.json', {'x': 2});
    put(staging, 'prefs.json', {'palette': 'ocean'});

    await replaceLibrary(root, staged());

    final books = read(root, 'library.json')['books'] as List;
    expect([for (final b in books) (b as Map)['id']], ['theirs']);
    expect(read(root, 'prefs.json')['palette'], 'ocean');
    expect(Directory('${root.path}/books/mine').existsSync(), isFalse);
    expect(staging.existsSync(), isFalse);
    expect(Directory('${root.path}/.before-restore').existsSync(), isFalse);
  });

  test('add keeps my books, adds theirs, and keeps the further place', () async {
    put(root, 'library.json', {
      'categories': [
        {'id': 'reading', 'name': 'Reading'},
      ],
      'books': [book('both', progress: 0.2), book('mine', progress: 0.5)],
    });
    put(root, 'books/both/cursor.json', {'progress': 0.2});
    put(root, 'books/both/ch/1.json', {'n': 'mine'});
    put(root, 'prefs.json', {'palette': 'forest'});

    put(staging, 'library.json', {
      'categories': [
        {'id': 'r2', 'name': 'reading'},
        {'id': 'later', 'name': 'Later'},
      ],
      'books': [
        book('both', progress: 0.7, category: 'r2'),
        book('theirs', category: 'later'),
      ],
    });
    put(staging, 'books/both/cursor.json', {'progress': 0.7});
    put(staging, 'books/both/ch/1.json', {'n': 'theirs'});
    put(staging, 'books/both/ch/2.json', {'n': 'theirs'});
    put(staging, 'books/theirs/cursor.json', {'progress': 0});
    put(staging, 'prefs.json', {'palette': 'ocean'});

    final report = await addToLibrary(root, staged());

    expect(report.added, 1);
    expect(report.updated, 1);
    final index = read(root, 'library.json');
    final byId = {for (final b in index['books'] as List) (b as Map)['id']: b};
    expect(byId.keys, unorderedEquals(['both', 'mine', 'theirs']));
    expect(byId['both']!['progress'], 0.7);
    expect(read(root, 'books/both/cursor.json')['progress'], 0.7);
    // A chapter already here stays; a missing one is added.
    expect(read(root, 'books/both/ch/1.json')['n'], 'mine');
    expect(read(root, 'books/both/ch/2.json')['n'], 'theirs');
    expect(File('${root.path}/books/theirs/cursor.json').existsSync(), isTrue);
    // "reading" is the same shelf as "Reading"; "Later" is new.
    final cats = [for (final c in index['categories'] as List) (c as Map)['name']];
    expect(cats, ['Reading', 'Later']);
    expect(byId['theirs']!['category'], 'later');
    // Settings stay this phone's.
    expect(read(root, 'prefs.json')['palette'], 'forest');
    expect(staging.existsSync(), isFalse);
  });

  test('add brings sources and source lists that are missing', () async {
    put(root, 'library.json', {'books': []});
    put(root, 'sources/installed.json', [
      {'id': 'royalroad', 'name': 'Royal Road'},
    ]);
    put(root, 'sources/repos.json', ['https://a/plugins.json']);
    put(staging, 'library.json', {'books': []});
    put(staging, 'sources/installed.json', [
      {'id': 'royalroad', 'name': 'Royal Road'},
      {'id': 'novelbin', 'name': 'Novel Bin'},
    ]);
    put(staging, 'sources/repos.json', ['https://a/plugins.json', 'https://b/plugins.json']);
    put(staging, 'sources/plugins/novelbin.js', 'code');
    put(staging, 'sources/storage-novelbin.json', {'k': 1});

    final report = await addToLibrary(root, staged());

    expect(report.sources, 1);
    final installed = jsonDecode(File('${root.path}/sources/installed.json').readAsStringSync()) as List;
    expect([for (final p in installed) (p as Map)['id']], ['royalroad', 'novelbin']);
    expect(jsonDecode(File('${root.path}/sources/repos.json').readAsStringSync()),
        ['https://a/plugins.json', 'https://b/plugins.json']);
    expect(File('${root.path}/sources/plugins/novelbin.js').readAsStringSync(), 'code');
    expect(File('${root.path}/sources/storage-novelbin.json').existsSync(), isTrue);
  });

  test('backup file names carry the date', () {
    expect(backupFileName(DateTime(2026, 3, 7)), 'TomeVoice-backup-2026-03-07.zip');
  });

  test('versions compare as numbers', () {
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('0.6', '0.6.0'), 0);
    expect(compareVersions('0.5.1', '0.6.0'), lessThan(0));
    expect(compareVersions('1.0.0+7', '1.0.0'), 0);
  });
}
