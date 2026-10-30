// The reading place is saved about once a sentence. Each save used to write
// library.json, every book's entry, again on the UI thread. Now the place is
// in the book's own cursor.json at once, and library.json takes the first
// one in a while at once and the rest together a few seconds on, encoding
// only the books that changed. A synthetic library of 1,000 books shows
// what that costs the UI thread, before and after; the rest checks that no
// place is lost on the way, and that two copies of the app still keep each
// other's books.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/home_shell.dart' show PlaceSettler;
import 'package:tomevoice_spike/index_file.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/safe_file.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tv_places'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// A library of [count] books as the app writes one: every field a real
  /// EPUB's entry has, on two shelves.
  Directory library(int count, {String name = 'library'}) {
    final root = Directory('${tmp.path}/$name')..createSync();
    String id(int i) => i.toRadixString(16).padLeft(16, '0');
    final opened = DateTime(2026, 10, 1);
    final books = [
      for (var i = 0; i < count; i++)
        {
          'id': id(i),
          'title': 'The Long Book of Things, Volume ${i + 1}',
          'authors': ['Author ${i % 97} Surname'],
          'source': 'epub',
          'wordCount': 80000 + i,
          'sourcePath': '${root.path}/books/${id(i)}/source.epub',
          'addedAt': opened.subtract(Duration(days: i)).toIso8601String(),
          if (i % 3 == 0) 'openedAt': opened.subtract(Duration(hours: i)).toIso8601String(),
          'cursor': {'sectionIndex': i % 30, 'blockIndex': i % 50, 'sentenceIndex': i % 7},
          'progress': (i % 100) / 100,
          'where': 'Chapter ${i % 30}: The Road Home',
          'language': 'en',
          'cover': '${root.path}/books/${id(i)}/img/OEBPS_images_cover.jpg',
          'category': i.isEven ? 'reading' : 'later',
          'series': '',
        },
    ];
    File('${root.path}/library.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'categories': [for (final c in Category.defaults) c.toJson()],
      'defaultCategory': 'reading',
      'books': books,
    }));
    return root;
  }

  /// Book [id]'s entry in library.json as it is on disk. Read while the
  /// store renames a new one over it, Windows refuses the read for a moment
  /// (a phone does not): it is read again.
  Map<String, Object?> onDisk(Directory root, String id) {
    for (var tries = 0;; tries++) {
      try {
        return Map<String, Object?>.from(
          ((jsonDecode(File('${root.path}/library.json').readAsStringSync()) as Map)['books'] as List)
              .cast<Map>()
              .firstWhere((b) => b['id'] == id),
        );
      } on FileSystemException {
        if (tries >= 50) rethrow;
        sleep(const Duration(milliseconds: 10));
      }
    }
  }

  group('a library of 1,000 books', () {
    test('a saved place costs the UI thread a fraction of what it did', () async {
      const saves = 40;
      // Before: what saveCursor did for every place, as it was written: the
      // book's cursor.json, then every entry encoded again and written.
      final oldRoot = library(1000, name: 'before');
      final index = File('${oldRoot.path}/library.json');
      final read = await LibraryStore(oldRoot).index(all: true);
      var entries = read.entries;
      final first = entries.first.id;
      Future<void> before(int n) async {
        final cursor = ReadingCursor(sectionIndex: 1, blockIndex: n);
        await writeSafely(
          File('${oldRoot.path}/books/$first/cursor.json')..parent.createSync(recursive: true),
          jsonEncode({'cursor': cursor.toJson(), 'progress': n / 1000}),
        );
        entries = [
          for (final e in entries)
            e.id == first ? e.copyWith(cursor: cursor, progress: n / 1000, openedAt: DateTime.now()) : e,
        ]..sort((a, b) => b.lastTouched.compareTo(a.lastTouched));
        await writeSafely(
          index,
          const JsonEncoder.withIndent('  ').convert({
            'categories': [for (final c in read.categories) c.toJson()],
            'defaultCategory': read.defaultCategory,
            'books': [for (final e in entries) e.toJson()],
          }),
        );
      }

      // After: the same places through saveCursor, on a library read as the
      // app reads it on opening (every book's part encoded meanwhile on a
      // background isolate). The first place is written at once, the rest
      // wait for the window's end, here brought on by settling them.
      final root = library(1000, name: 'after');
      final store = LibraryStore(root);
      await store.index(all: true);
      await store.warming;
      Future<void> after(int n) => store.saveCursor(first, ReadingCursor(sectionIndex: 2, blockIndex: n), n / 1000);

      // Each way a few times first (the test runs code compiled as it goes),
      // then one after the other, so a busy machine weighs on both alike.
      for (var n = 0; n < 5; n++) {
        await before(n);
        await after(n);
      }
      await store.settlePlaces();
      final old = <Duration>[], now = <Duration>[];
      for (var n = 0; n < saves; n++) {
        old.add(await busy(() => before(n)));
        now.add(await busy(() => after(n)));
      }
      final settle = await busy(store.settlePlaces);
      expect(onDisk(root, first)['cursor'], {'sectionIndex': 2, 'blockIndex': saves - 1, 'sentenceIndex': 0});

      // The first place after the app opens: written at once, its library
      // just read (and its parts made on a background isolate meanwhile).
      final reopened = LibraryStore(library(1000, name: 'reopened'));
      await reopened.index(all: true);
      await reopened.warming;
      final opening = await busy(() => reopened.saveCursor(first, const ReadingCursor(sectionIndex: 9), 0));
      reopened.hold();

      // Encoding alone: every entry again, against the one that changed.
      final idx = await store.index(all: true);
      final parts = Expando<Uint8List>();
      Uint8List encode(List<LibraryEntry> books) => encodeIndex(
            categories: [for (final c in idx.categories) c.toJson()],
            defaultCategory: idx.defaultCategory,
            books: books,
            toJson: (e) => e.toJson(),
            parts: parts,
          );
      encode(idx.entries);
      Duration timed(void Function() f) {
        final clock = Stopwatch()..start();
        f();
        return clock.elapsed;
      }

      final whole = [
        for (var n = 0; n < 25; n++)
          timed(() => const JsonEncoder.withIndent('  ').convert({
                'categories': [for (final c in idx.categories) c.toJson()],
                'defaultCategory': idx.defaultCategory,
                'books': [for (final e in idx.entries) e.toJson()],
              })),
      ];
      final one = [
        for (var n = 0; n < 25; n++) timed(() => encode([idx.entries.first.copyWith(progress: n / 10), ...idx.entries.skip(1)])),
      ];

      double ms(Duration d) => d.inMicroseconds / 1000;
      Duration median(List<Duration> d) => ([...d]..sort())[d.length ~/ 2];
      Duration sum(List<Duration> d) => d.fold(Duration.zero, (a, b) => a + b);
      String row(String what, List<Duration> d) => '$what median ${ms(median(d)).toStringAsFixed(2)} ms, '
          'longest ${ms(([...d]..sort()).last).toStringAsFixed(2)} ms, $saves of them ${ms(sum(d)).toStringAsFixed(1)} ms';

      // ignore: avoid_print
      print([
        'UI thread per saved place, 1,000 books (${(index.lengthSync() / 1024).round()} KB library.json):',
        '  ${row('before:', old)}',
        '  ${row('after: ', now)}, and ${ms(settle).toStringAsFixed(2)} ms to write them together',
        '  the first place after the app opens: ${ms(opening).toStringAsFixed(2)} ms',
        '  encoding library.json: every entry ${ms(median(whole)).toStringAsFixed(2)} ms, '
            'one changed ${ms(median(one)).toStringAsFixed(2)} ms',
      ].join('\n'));
      expect(median(now) * 4, lessThan(median(old)), reason: 'a place saved costs less than a quarter of what it did');
      expect((sum(now) + settle) * 4, lessThan(sum(old)), reason: 'and so do all of them, with their writing');
      expect(median(one) * 3, lessThan(median(whole)), reason: 'only the book that changed is encoded');
      store.hold();
      // A busy machine (the whole suite at once) takes far longer than 30 s.
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('a place a run stopped before writing is found again on a background isolate', () async {
      final root = library(1000);
      final store = LibraryStore(root)..placeWindow = const Duration(minutes: 1);
      final id = (await store.index(all: true)).entries.last.id;
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 9), 0.9, where: 'Chapter 9');
      // The app stops here: nothing more is written.
      store.hold();
      expect(onDisk(root, id)['progress'], 0.1);

      final again = LibraryStore(root);
      await again.index(all: true);
      expect(again.recovering, isNotNull, reason: 'a large library is looked through off the UI thread');
      await again.recovering;
      final e = (await again.list(all: true)).firstWhere((e) => e.id == id);
      expect((e.cursor.sectionIndex, e.progress, e.where), (9, 0.9, 'Chapter 9'));
      expect((await again.list(all: true)).first.id, id, reason: 'the book read last is the one read last');
      await again.settlePlaces();
      expect(onDisk(root, id)['progress'], 0.9);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('places', () {
    late Directory root;
    late LibraryStore store;
    late List<String> ids;

    setUp(() async {
      root = Directory('${tmp.path}/small')..createSync();
      store = LibraryStore(root)..placeWindow = const Duration(milliseconds: 400);
      ids = [];
      for (final name in ['one', 'two']) {
        final f = File('${root.path}/incoming/$name/$name.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('The $name story. ${'It goes on for a while, and then some more. ' * 20}');
        ids.add((await store.importFile(PickedFile(path: f.path, name: '$name.txt'))).id);
      }
    });

    tearDown(() => store.hold());

    Map<String, Object?> file(String id) =>
        Map<String, Object?>.from(jsonDecode(File('${root.path}/books/$id/cursor.json').readAsStringSync()) as Map);

    test('the first in a while is written at once; the next wait, then go together', () async {
      final id = ids.first;
      // Long enough that a busy machine still saves the next two within it.
      store.placeWindow = const Duration(seconds: 3);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      expect(onDisk(root, id)['progress'], 0.1, reason: 'at once: nothing was saved for a while');
      var said = 0;
      store.placeChanges.addListener(() => said++);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 2), 0.2);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 3), 0.3, where: 'Three');
      expect(said, 2, reason: 'every place saved is told');
      expect(onDisk(root, id)['progress'], 0.1, reason: 'library.json waits');
      expect(file(id)['progress'], 0.3, reason: 'cursor.json has every place at once');
      expect((await store.cursorFor(id)).sectionIndex, 3);
      final shown = (await store.list()).firstWhere((e) => e.id == id);
      expect((shown.progress, shown.where), (0.3, 'Three'), reason: 'every page reads the copy kept here');

      final waited = Stopwatch()..start();
      while ((onDisk(root, id)['progress'] != 0.3 || said < 3) && waited.elapsed < const Duration(seconds: 15)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(onDisk(root, id)['progress'], 0.3, reason: 'written together at the end of the window');
      expect(onDisk(root, id)['where'], 'Three');
      expect(said, 3, reason: 'and told again, for what reads the file (widgets, Android Auto)');
    });

    test('settled (a book left, reading paused, the app put away), they are written at once, and the next too',
        () async {
      final id = ids.first;
      store.placeWindow = const Duration(minutes: 1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 2), 0.2);
      expect(onDisk(root, id)['progress'], 0.1);
      await store.settlePlaces();
      expect(onDisk(root, id)['progress'], 0.2);
      // The reader saves its place as it closes, a moment after it is left.
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 4), 0.4);
      expect(onDisk(root, id)['progress'], 0.4);
    });

    testWidgets('leaving a screen settles them', (tester) async {
      final id = ids.first;
      await tester.runAsync(() async {
        store.placeWindow = const Duration(minutes: 1);
        await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
        await store.saveCursor(id, const ReadingCursor(sectionIndex: 5), 0.5);
      });
      final settler = PlaceSettler()..store = store;
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, navigatorObservers: [settler], home: const SizedBox()));
      unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('A book'))));
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      // The write is real file work: the real clock, then a pump to go on.
      for (var i = 0; i < 60 && onDisk(root, id)['progress'] != 0.5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(onDisk(root, id)['progress'], 0.5);
    });

    test('stopped before library.json took them, no place is lost', () async {
      final id = ids.last;
      store.placeWindow = const Duration(minutes: 1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1, where: 'One');
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 6, sentenceIndex: 2), 0.6, where: 'Six');
      // The process dies: what was in memory goes with it.
      store.hold();
      expect(onDisk(root, id)['progress'], 0.1);

      final again = LibraryStore(root);
      expect((await again.cursorFor(id)).sectionIndex, 6, reason: "the book opens where it was: its cursor.json");
      final e = (await again.list()).firstWhere((e) => e.id == id);
      expect((e.cursor.sectionIndex, e.cursor.sentenceIndex, e.progress, e.where), (6, 2, 0.6, 'Six'),
          reason: 'and the shelf, History and sync see it too');
      await again.settlePlaces();
      expect(onDisk(root, id)['progress'], 0.6, reason: 'written in at the next chance');
      again.hold();
    });

    test('a place older builds wrote stands; recovering never moves a place back', () async {
      final id = ids.first;
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 3), 0.3);
      // Written by an older build after library.json: no time in it.
      File('${root.path}/books/$id/cursor.json')
          .writeAsStringSync(jsonEncode({'cursor': const ReadingCursor(sectionIndex: 3).toJson(), 'progress': 0.3}));
      final again = LibraryStore(root);
      final e = (await again.list()).firstWhere((e) => e.id == id);
      expect((e.cursor.sectionIndex, e.progress), (3, 0.3));
      // A cursor.json from before the place the index has is not taken.
      File('${root.path}/books/$id/cursor.json').writeAsStringSync(jsonEncode({
        'cursor': const ReadingCursor(sectionIndex: 1).toJson(),
        'progress': 0.1,
        'at': DateTime(2020).toIso8601String(),
      }));
      final third = LibraryStore(root);
      expect((await third.list()).firstWhere((e) => e.id == id).progress, 0.3);
      again.hold();
      third.hold();
    });

    test('another copy of the app writing library.json keeps the places waiting here', () async {
      final id = ids.first;
      store.placeWindow = const Duration(minutes: 1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      // Another engine (a book read with no screen, a second copy opened by
      // a file manager), with the index in memory as it was then...
      final other = LibraryStore(root);
      await other.index(all: true);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 7), 0.7);
      // ...adds a book, writing every entry as it has them.
      final f = File('${root.path}/incoming/three/three.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('The third story. ${'It is quite another one, with words of its own. ' * 20}');
      final added = await other.importFile(PickedFile(path: f.path, name: 'three.txt'));
      // This copy reads the file again before its next change, and keeps
      // what it had not written.
      final listed = await store.list(all: true);
      expect(listed.map((e) => e.id), contains(added.id));
      expect(listed.firstWhere((e) => e.id == id).progress, 0.7);
      await store.settlePlaces();
      final fresh = LibraryStore(root);
      final all = await fresh.list(all: true);
      expect(all.map((e) => e.id), containsAll([...ids, added.id]), reason: "neither wrote over the other's books");
      expect(all.firstWhere((e) => e.id == id).progress, 0.7);
      other.hold();
      fresh.hold();
    });

    test("a later place the other copy saved is not written over by an older one waiting here", () async {
      final id = ids.first;
      store.placeWindow = const Duration(minutes: 1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 2), 0.2);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final other = LibraryStore(root);
      await other.saveCursor(id, const ReadingCursor(sectionIndex: 8), 0.8);
      expect((await store.list()).firstWhere((e) => e.id == id).progress, 0.8);
      await store.settlePlaces();
      expect(onDisk(root, id)['progress'], 0.8);
      other.hold();
    });

    test('a book removed meanwhile is not brought back by its waiting place', () async {
      final id = ids.first;
      store.placeWindow = const Duration(minutes: 1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 1), 0.1);
      await store.saveCursor(id, const ReadingCursor(sectionIndex: 2), 0.2);
      await store.remove(id);
      await store.settlePlaces();
      expect((await LibraryStore(root).list(all: true)).map((e) => e.id), isNot(contains(id)));
    });

    test('library.json is written as before, byte for byte', () async {
      await store.setTags(ids.first, ['Fantasy', 'Été à lire', '日本の本', 'A "quoted" one']);
      await store.saveCursor(ids.last, const ReadingCursor(sectionIndex: 1), 0.5, where: 'Chapter 1');
      final idx = await store.index(all: true);
      final expected = const JsonEncoder.withIndent('  ').convert({
        'categories': [for (final c in idx.categories) c.toJson()],
        'defaultCategory': idx.defaultCategory,
        'books': [for (final e in idx.entries) e.toJson()],
      });
      expect(File('${root.path}/library.json').readAsStringSync(), expected);
      // An empty shelf too.
      final parts = Expando<Uint8List>();
      expect(
        utf8.decode(encodeIndex<LibraryEntry>(
            categories: const [], defaultCategory: 'reading', books: const [], toJson: (e) => e.toJson(), parts: parts)),
        const JsonEncoder.withIndent('  ').convert({'categories': [], 'defaultCategory': 'reading', 'books': []}),
      );
    });
  });
}

/// How long [work] keeps this isolate busy: every piece of it that runs is
/// timed (its first step, and each step after an await), the time spent
/// waiting on the disk between them is not. In the app this isolate is the
/// UI thread, and this is the time a frame could not be drawn.
Future<Duration> busy(Future<void> Function() work) async {
  final clock = Stopwatch();
  var depth = 0;
  R timed<R>(R Function() f) {
    if (depth++ == 0) clock.start();
    try {
      return f();
    } finally {
      if (--depth == 0) clock.stop();
    }
  }

  await runZoned(
    () => timed(work),
    zoneSpecification: ZoneSpecification(
      run: <R>(self, parent, zone, f) => timed(() => parent.run(zone, f)),
      runUnary: <R, T>(self, parent, zone, f, arg) => timed(() => parent.runUnary(zone, f, arg)),
      runBinary: <R, T1, T2>(self, parent, zone, f, a, b) => timed(() => parent.runBinary(zone, f, a, b)),
    ),
  );
  return clock.elapsed;
}
