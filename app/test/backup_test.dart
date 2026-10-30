// Backup and restore, on folders in temp: the zip itself is written and read
// by Kotlin, so these cover what Dart does with an unpacked backup: point its
// paths at this phone's folder, replace the library, or add to it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/app_update.dart';
import 'package:tomevoice_spike/backup.dart';
import 'package:tomevoice_spike/library_store.dart';

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

  group('a replace stopped part way', () {
    void journal(Map<String, Object?> j) => put(root, '.restore-journal.json', j);

    test('is undone at the next start', () async {
      // Stopped after "books" went aside and the backup's list came in.
      put(root, '.before-restore/library.json', {
        'books': [book('mine')],
      });
      put(root, '.before-restore/books/mine/cursor.json', {'x': 1});
      put(root, 'prefs.json', {'palette': 'forest'});
      put(root, 'library.json', {
        'books': [book('theirs')],
      });
      journal({
        'aside': ['library.json', 'books', 'prefs.json'],
        'in': ['library.json'],
        'done': false,
      });

      await clearStaleRestore(root);

      expect([for (final b in read(root, 'library.json')['books'] as List) (b as Map)['id']], ['mine']);
      expect(read(root, 'books/mine/cursor.json')['x'], 1);
      expect(read(root, 'prefs.json')['palette'], 'forest', reason: 'never moved, so left alone');
      expect(Directory('${root.path}/.before-restore').existsSync(), isFalse);
      expect(File('${root.path}/.restore-journal.json').existsSync(), isFalse);
    });

    test('that got all the way through is finished', () async {
      put(root, '.before-restore/library.json', {
        'books': [book('mine')],
      });
      put(root, 'library.json', {
        'books': [book('theirs')],
      });
      journal({
        'aside': ['library.json'],
        'in': ['library.json'],
        'done': true,
      });

      await clearStaleRestore(root);

      expect([for (final b in read(root, 'library.json')['books'] as List) (b as Map)['id']], ['theirs']);
      expect(Directory('${root.path}/.before-restore').existsSync(), isFalse);
      expect(File('${root.path}/.restore-journal.json').existsSync(), isFalse);
    });

    test('by an older app is put back where nothing took its place, and never deleted', () async {
      // No journal: the hidden folder is the library as it was.
      put(root, '.before-restore/books/mine/cursor.json', {'x': 1});
      put(root, '.before-restore/library.json', {
        'books': [book('mine')],
      });
      put(root, 'library.json', {
        'books': [book('theirs')],
      });
      await clearStaleRestore(root);
      expect(read(root, 'books/mine/cursor.json')['x'], 1);
      // A replace now keeps what could not be put back, under another name.
      put(staging, 'library.json', {
        'books': [book('new')],
      });
      await replaceLibrary(root, staged());
      final kept = root.listSync().map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
      expect(kept.where((n) => n.startsWith('.before-restore-')), hasLength(1));
    });
  });

  test('a backup whose books do not read as the library reads them is refused', () async {
    put(staging, 'library.json', {
      'books': [
        {'id': 'b${'0' * 15}', 'title': 'Odd', 'progress': 'half'},
      ],
    });
    await expectLater(checkStaged(staged(), root), throwsA(isA<FormatException>()));
  });

  test("replace keeps this phone's natural voices and its update choice", () async {
    put(root, 'library.json', {
      'books': [book('mine')],
    });
    put(root, 'voices/piper-en_US-kristin-medium/tokens.txt', 'a 1');
    put(root, 'app_update.json', {'check': false});
    put(staging, 'library.json', {
      'books': [book('theirs')],
    });
    // A backup made before voices were left out still has some.
    put(staging, 'voices/piper-en_US-ryan-high/tokens.txt', 'b 2');

    await replaceLibrary(root, staged());

    expect(File('${root.path}/voices/piper-en_US-kristin-medium/tokens.txt').readAsStringSync(), 'a 1');
    expect(Directory('${root.path}/voices/piper-en_US-ryan-high').existsSync(), isFalse);
    expect(read(root, 'app_update.json')['check'], false);
    expect(staging.existsSync(), isFalse);
  });

  test("replace keeps this phone's OCR language data and the scan it is reading", () async {
    put(root, 'library.json', {
      'books': [book('mine')],
    });
    put(root, 'ocr/tessdata/ben.traineddata', 'model');
    put(root, 'ocr/jobs/scan/pages/0.txt', 'page one');
    put(staging, 'library.json', {
      'books': [book('theirs')],
    });
    // A backup never carries any (LibraryBackup.kt leaves ocr/ out); one
    // that did is not taken.
    put(staging, 'ocr/tessdata/hin.traineddata', 'other');

    await replaceLibrary(root, staged());

    expect(File('${root.path}/ocr/tessdata/ben.traineddata').readAsStringSync(), 'model');
    expect(File('${root.path}/ocr/jobs/scan/pages/0.txt').readAsStringSync(), 'page one');
    expect(File('${root.path}/ocr/tessdata/hin.traineddata').existsSync(), isFalse);
    expect([for (final b in read(root, 'library.json')['books'] as List) (b as Map)['id']], ['theirs']);
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

  group('add brings what the books came with', () {
    Map<String, Object?> mark(String id, String created) => {
          'id': id,
          'book': 'b1',
          'bookTitle': 'Book',
          'kind': 'quote',
          'at': {'sectionIndex': 0, 'blockIndex': 0, 'sentenceIndex': 0},
          'text': 'A line.',
          'created': created,
        };

    void stage() {
      staging.createSync(recursive: true);
      put(staging, 'library.json', {'books': []});
      put(staging, 'marks.json', [mark('q-old', '2026-09-01T10:00:00.000'), mark('q-new', '2026-10-20T10:00:00.000')]);
      put(staging, 'stats.json', {
        'goalMinutes': 20,
        'days': {
          '2026-10-01': {'listen': 600000, 'books': {'b1': 600000}},
          '2026-10-02': {'listen': 60000},
        },
      });
      put(staging, 'rules.json', {
        'say': [
          {'from': 'Sunny', 'to': 'Sonny'},
          {'from': 'Klein', 'to': 'Kline', 'book': 'b1'},
        ],
        'skip': [
          {'text': 'Read at site X'},
        ],
      });
      put(staging, 'prefs.json', {'palette': 'ocean'});
    }

    setUp(() {
      put(root, 'library.json', {'books': []});
      put(root, 'marks.json', [mark('q-mine', '2026-10-10T10:00:00.000')]);
      put(root, 'stats.json', {
        'days': {
          '2026-10-02': {'listen': 120000, 'read': 5000},
        },
      });
      put(root, 'rules.json', {
        'say': [
          {'from': 'sunny', 'to': 'Sun-ee'},
        ],
      });
      put(root, 'prefs.json', {'palette': 'forest'});
      stage();
    });

    test('quotes, days of stats and reading rules, each once', () async {
      final report = await addToLibrary(root, staged());
      expect(report.marks, 2);
      expect(report.days, 1, reason: 'one new day; the day on both had less listening there');
      expect(report.rules, 2, reason: "this phone's own fix for Sunny wins");
      final marks = [for (final m in jsonDecode(File('${root.path}/marks.json').readAsStringSync()) as List) (m as Map)['id']];
      expect(marks, ['q-new', 'q-mine', 'q-old'], reason: 'newest first');
      final days = read(root, 'stats.json')['days'] as Map;
      expect((days['2026-10-01'] as Map)['listen'], 600000);
      expect((days['2026-10-02'] as Map)['listen'], 120000);
      expect((days['2026-10-02'] as Map)['read'], 5000);
      expect(read(root, 'stats.json')['goalMinutes'], 20);
      final rules = read(root, 'rules.json');
      expect([for (final r in rules['say'] as List) (r as Map)['to']], ['Sun-ee', 'Kline']);
      expect((rules['skip'] as List).single, {'text': 'Read at site X'});
      expect(read(root, 'prefs.json')['palette'], 'forest');
      expect(addSummary(report),
          'Added 2 quotes and bookmarks, 2 reading rules and 1 day of stats from the backup.');

      // The same backup added again counts nothing twice.
      stage();
      final again = await addToLibrary(root, staged());
      expect((again.marks, again.days, again.rules), (0, 0, 0));
      expect((read(root, 'stats.json')['days'] as Map)['2026-10-01'], {'listen': 600000, 'books': {'b1': 600000}});
      expect(addSummary(again), 'Nothing new to add from the backup.');
    });

    test("the backup's settings only when asked", () async {
      final report = await addToLibrary(root, staged(), settings: true);
      expect(report.settings, isTrue);
      expect(read(root, 'prefs.json')['palette'], 'ocean');
      expect(addSummary(report), endsWith("The backup's settings are in use."));
    });

    test('the summary is there once, after the app starts again', () async {
      await saveRestoreReport(root, 'Added 2 books from the backup.');
      expect(await takeRestoreReport(root), 'Added 2 books from the backup.');
      expect(await takeRestoreReport(root), isNull);
    });
  });

  test("add puts both phones' tags on a book in both; a series given here stays, one missing comes", () async {
    put(root, 'library.json', {
      'books': [
        {...book('both'), 'tags': ['Fantasy', 'Mine'], 'series': 'Saga', 'seriesIndex': 2},
        // Taken out of its series here: it stays out.
        {...book('cleared'), 'series': ''},
        book('bare'),
      ],
    });
    put(staging, 'library.json', {
      'books': [
        {...book('both'), 'tags': ['fantasy', 'Theirs'], 'series': 'Other Saga', 'seriesIndex': 5, 'print': 'AAAA'},
        {...book('cleared'), 'series': 'Back Again', 'seriesIndex': 1},
        {...book('bare'), 'series': 'Found There', 'seriesIndex': 3, 'tags': ['Lent']},
        {...book('new'), 'tags': ['Brought'], 'series': 'New Saga', 'seriesIndex': 1},
      ],
    });

    final report = await addToLibrary(root, staged());

    final byId = {for (final b in read(root, 'library.json')['books'] as List) (b as Map)['id']: b};
    expect(byId['both']!['tags'], ['Fantasy', 'Mine', 'Theirs'], reason: 'each tag once, as spelled here');
    expect((byId['both']!['series'], byId['both']!['seriesIndex']), ('Saga', 2));
    expect(byId['both']!['print'], 'AAAA', reason: 'a print of the same text, made there');
    expect((byId['cleared']!['series'], byId['cleared']!.containsKey('seriesIndex')), ('', false));
    expect((byId['bare']!['series'], byId['bare']!['seriesIndex']), ('Found There', 3));
    expect(byId['bare']!['tags'], ['Lent']);
    expect(byId['new']!['tags'], ['Brought']);
    expect(byId['new']!['series'], 'New Saga');
    expect(report.updated, 2, reason: 'the two books given something; the one left alone is not');

    // As the library reads it.
    final entries = {for (final e in await LibraryStore(root).list(all: true)) e.id: e};
    expect(entries['both']!.tags, ['Fantasy', 'Mine', 'Theirs']);
    expect(entries['cleared']!.seriesName, isNull);
    expect((entries['bare']!.seriesName, entries['bare']!.seriesIndex), ('Found There', 3.0));
  });

  test("the same backup added twice changes nothing the second time", () async {
    put(root, 'library.json', {
      'books': [
        {...book('both'), 'tags': ['Mine']},
      ],
    });
    Map<String, Object?> theirs() => {
          'books': [
            {...book('both'), 'tags': ['Theirs'], 'series': 'Saga', 'seriesIndex': 1},
          ],
        };
    put(staging, 'library.json', theirs());
    expect((await addToLibrary(root, staged())).updated, 1);
    staging.createSync(recursive: true);
    put(staging, 'library.json', theirs());
    expect((await addToLibrary(root, staged())).updated, 0);
    final both = (read(root, 'library.json')['books'] as List).single as Map;
    expect(both['tags'], ['Mine', 'Theirs']);
    expect(both['series'], 'Saga');
  });

  test('a secret shelf in a backup never merges into an open one here', () async {
    put(root, 'library.json', {
      'categories': [
        {'id': 'later', 'name': 'Later'},
      ],
      'books': [],
    });
    put(staging, 'library.json', {
      'categories': [
        {'id': 'later', 'name': 'Later', 'secret': true},
      ],
      'books': [book('hidden', category: 'later')],
    });
    await addToLibrary(root, staged());
    final index = read(root, 'library.json');
    final cats = [for (final c in index['categories'] as List) Map<String, Object?>.from(c as Map)];
    final secret = cats.singleWhere((c) => c['secret'] == true);
    expect(secret['id'], isNot('later'));
    expect(cats.where((c) => c['id'] == 'later').single['secret'], isNull);
    final hidden = (index['books'] as List).cast<Map>().singleWhere((b) => b['id'] == 'hidden');
    expect(hidden['category'], secret['id']);
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

  test('a new version is offered until skipped, and Later waits three days', () async {
    const v5 = AppUpdate(version: '1.0.5', url: 'u', title: 't');
    const v6 = AppUpdate(version: '1.0.6', url: 'u', title: 't');
    final now = DateTime(2026, 10, 24, 18);
    expect(await AppUpdates.shouldOffer(root, v5, now: now), isTrue);

    await AppUpdates.putOff(root, v5, now: now);
    expect(await AppUpdates.shouldOffer(root, v5, now: now.add(const Duration(days: 2))), isFalse);
    expect(await AppUpdates.shouldOffer(root, v5, now: now.add(const Duration(days: 3))), isTrue);
    expect(await AppUpdates.shouldOffer(root, v6, now: now), isTrue, reason: 'a newer one is offered at once');
    expect(await AppUpdates.shouldOffer(root, v5, now: now.subtract(const Duration(days: 30))), isTrue,
        reason: 'a clock wound back does not put it off for ever');

    await AppUpdates.skip(root, v5);
    expect(await AppUpdates.shouldOffer(root, v5, now: now.add(const Duration(days: 30))), isFalse);
    expect(await AppUpdates.shouldOffer(root, v6, now: now), isTrue, reason: 'the next release asks again');
  });
}
