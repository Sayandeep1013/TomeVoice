// Sync through WebDAV, against a WebDAV server on this computer: each
// book's place, quotes and reading time as a small file keyed by its id,
// merged as a restore merges (quotes by id, removals kept, time per day the
// larger, places the newest); nothing sent while sync is off, and nothing
// of a book on a shut secret shelf.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/secrets.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/stats.dart';
import 'package:tomevoice_spike/sync.dart';

import 'support/webdav_server.dart';

Mark _mark(String id, {DateTime? created, DateTime? edited, String book = 'b', String? note}) => Mark(
      id: id,
      bookId: book,
      bookTitle: 'Book',
      kind: MarkKind.quote,
      at: const ReadingCursor(sectionIndex: 0, blockIndex: 1, sentenceIndex: 0),
      text: 'Words $id.',
      created: created ?? DateTime(2026, 10, 1),
      edited: edited,
      note: note,
    );

SyncedPlace _place(int block, DateTime at) =>
    SyncedPlace(cursor: ReadingCursor(blockIndex: block), progress: block / 100, at: at.toUtc());

void main() {
  group('merging', () {
    test('places by the newest; quotes by id, the copy changed last; time per day the larger', () {
      final t = DateTime.utc(2026, 10, 30, 9);
      final a = BookRecord(
        id: 'b',
        title: 'Mine',
        place: _place(5, t),
        marks: [_mark('x', note: 'old'), _mark('y')],
        days: {'2026-10-29': 1000, '2026-10-30': 5000},
      );
      final b = BookRecord(
        id: 'b',
        title: 'Theirs',
        place: _place(9, t.add(const Duration(minutes: 1))),
        marks: [_mark('x', edited: DateTime(2026, 10, 2), note: 'new'), _mark('z')],
        days: {'2026-10-30': 3000, '2026-10-31': 700},
      );
      final m = mergeBooks(a, b);
      expect(m.place!.cursor.blockIndex, 9);
      expect([for (final x in m.marks) x.id]..sort(), ['x', 'y', 'z']);
      expect(m.marks.firstWhere((x) => x.id == 'x').note, 'new');
      expect(m.days, {'2026-10-29': 1000, '2026-10-30': 5000, '2026-10-31': 700});
      expect(m.title, 'Theirs', reason: "the server's name, so two phones do not write it back and forth");
      // The same both ways round, but for whose name it takes.
      expect(jsonEncode(mergeBooks(b, a).toJson()..remove('title')), jsonEncode(m.toJson()..remove('title')));
    });

    test('a removal outlasts copies saved before it, not a change after it', () {
      final removedAt = DateTime.utc(2026, 10, 10);
      final mine = BookRecord(id: 'b', marks: [_mark('x'), _mark('y', edited: DateTime(2026, 10, 20))]);
      final theirs = BookRecord(id: 'b', removed: {'x': removedAt, 'y': removedAt});
      final m = mergeBooks(mine, theirs);
      expect([for (final x in m.marks) x.id], ['y']);
      expect(m.removed.keys, containsAll(['x', 'y']));
    });

    test('day totals: the larger of each figure', () {
      final m = mergeDays(
        {'2026-10-30': {'listen': 100, 'read': 50}},
        {'2026-10-30': {'listen': 80, 'read': 70, 'words': 9}, '2026-10-31': {'chapters': 1}},
      );
      expect(m, {
        '2026-10-30': {'listen': 100, 'read': 70, 'words': 9},
        '2026-10-31': {'chapters': 1},
      });
    });

    test('a record is written the same whatever order it was built in', () {
      final one = BookRecord(id: 'b', marks: [_mark('a'), _mark('b')], days: {'2': 2, '1': 1});
      final two = BookRecord(id: 'b', marks: [_mark('b'), _mark('a')], days: {'1': 1, '2': 2});
      expect(one.encode(), two.encode());
      expect(BookRecord.fromJson('b', jsonDecode(one.encode())).encode(), one.encode());
    });
  });

  group('with a WebDAV server', () {
    late Directory tmp;
    late WebDavTestServer server;
    late LibraryStore store;
    late LibraryEntry book;
    late ReadingLayout layout;

    String bookFile() => '/dav/TomeVoice/books/${book.id}.json';
    BookRecord onServer() => BookRecord.fromJson(book.id, jsonDecode(server.files[bookFile()]!));
    Future<LibraryEntry> entry() async => (await store.list(all: true)).firstWhere((e) => e.id == book.id);

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tomevoice_sync');
      server = await WebDavTestServer.start();
      ListeningPrefs.reset();
      MarkStore.instance.reset();
      StatsStore.instance.days.clear();
      store = LibraryStore(tmp);
      final f = File('${tmp.path}/incoming/novel.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('Chapter 1\n\n${List.generate(40, (i) => 'Sentence $i of the story goes on.').join(' ')}');
      book = await store.importFile(PickedFile(path: f.path, name: 'novel.txt'));
      layout = await store.loadLayout(book.id);
    });

    tearDown(() async {
      await server.close();
      LibraryStore.secretOpen.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    Future<void> turnOn() async {
      ListeningPrefs.memory
        ..webdavOn = true
        ..webdavUrl = server.root.toString()
        ..webdavUser = 'reader';
      await (await Secrets.of(tmp)).set('webdav', 'secret');
    }

    Future<Mark> quote(int unit) => MarkStore.instance.add(
          bookId: book.id,
          bookTitle: book.title,
          kind: MarkKind.quote,
          at: cursorOf(layout.units[unit]),
          text: layout.units[unit].text,
        );

    test('off unless set up: nothing is sent', () async {
      await quote(3);
      await store.saveCursor(book.id, cursorOf(layout.units[5]), 0.2);
      final r = await BookSync.instance.syncNow(store: store);
      expect(r.sent, 0);
      expect(server.requests, isEmpty);
      // Set up, but turned off again: still nothing.
      await turnOn();
      ListeningPrefs.memory.webdavOn = false;
      await BookSync.instance.syncNow(store: store);
      expect(server.requests, isEmpty);
    });

    test("a book's place, quotes and time go up, and come back merged with another phone's", () async {
      await turnOn();
      final q1 = await quote(3);
      await store.saveCursor(book.id, cursorOf(layout.units[5]), 0.2, where: 'Chapter 1');
      StatsStore.instance.addTime(book.id, const Duration(minutes: 7), listening: true, now: DateTime(2026, 10, 30, 12));

      final first = await BookSync.instance.syncNow(store: store);
      expect(first.problem, isNull);
      final up = onServer();
      expect(up.marks.single.id, q1.id);
      expect(up.place!.cursor.sentenceIndex, layout.units[5].sentenceIndex);
      expect(up.days['2026-10-30'], const Duration(minutes: 7).inMilliseconds);
      expect(server.files.keys, contains('/dav/TomeVoice/stats.json'));
      expect(server.files[bookFile()], isNot(contains('Chapter 1\n')), reason: 'never the book itself');

      // Nothing changed: nothing written again.
      final puts = server.requests.where((r) => r.startsWith('PUT')).length;
      await BookSync.instance.syncNow(store: store);
      expect(server.requests.where((r) => r.startsWith('PUT')).length, puts);

      // Another phone: removed q1, saved q2, read on further, read longer.
      final q2 = Mark(
        id: 'other-phone-quote',
        bookId: book.id,
        bookTitle: book.title,
        kind: MarkKind.quote,
        at: cursorOf(layout.units[20]),
        text: layout.units[20].text,
        created: DateTime.now(),
        colour: MarkColour.green,
      );
      final theirs = BookRecord(
        id: book.id,
        title: book.title,
        place: SyncedPlace(
          cursor: cursorOf(layout.units[30]),
          progress: 0.7,
          where: 'Chapter 1',
          at: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
        marks: [q2],
        removed: {q1.id: DateTime.now().toUtc()},
        days: {'2026-10-30': const Duration(minutes: 20).inMilliseconds},
      );
      server.files[bookFile()] = theirs.encode();

      await BookSync.instance.syncNow(store: store);
      final here = MarkStore.instance.forBook(book.id);
      expect([for (final m in here) m.id], [q2.id]);
      expect(here.single.colour, MarkColour.green);
      final e = await entry();
      expect(layout.unitForCursor(e.cursor, saved: true), 30);
      expect(StatsStore.instance.days['2026-10-30']!.books[book.id], const Duration(minutes: 20).inMilliseconds);

      // Removed here: the server keeps the removal, so it does not come back.
      await MarkStore.instance.remove(q2.id);
      final q3 = await quote(10);
      await BookSync.instance.syncNow(store: store);
      final after = onServer();
      expect([for (final m in after.marks) m.id], [q3.id]);
      expect(after.removed.keys, containsAll([q1.id, q2.id]));
      expect(MarkStore.instance.forBook(book.id).map((m) => m.id), [q3.id]);
    });

    test('a file another phone wrote between the read and the write is read again and merged', () async {
      await turnOn();
      await quote(2);
      await BookSync.instance.syncNow(store: store);
      // Written elsewhere since (so it is read), and again just after it is
      // read (so the write finds it changed), and something new here too.
      void add(String id) => server.files[bookFile()] =
          mergeBooks(onServer(), BookRecord(id: book.id, marks: [_mark(id, book: book.id, created: DateTime.now())])).encode();
      add('elsewhere-1');
      server.afterGet = (path) {
        if (path != bookFile()) return;
        server.afterGet = null;
        add('elsewhere-2');
      };
      await quote(4);
      await BookSync.instance.syncNow(store: store);
      expect(server.requests.where((r) => r == 'GET ${bookFile()}'), hasLength(2), reason: 'read again after the refusal');
      expect(onServer().marks.map((m) => m.id), containsAll(['elsewhere-1', 'elsewhere-2']));
      expect(onServer().marks, hasLength(4));
      expect(MarkStore.instance.forBook(book.id), hasLength(4));
    });

    test('a book on a shut secret shelf is never sent; open, it is', () async {
      await turnOn();
      final secret = await store.addCategory('Hidden', secret: true);
      await store.moveBooks({book.id}, secret.id);
      await quote(3);
      LibraryStore.secretOpen.value = false;
      await BookSync.instance.syncNow(store: store);
      expect(server.files.keys, isNot(contains(bookFile())));
      expect(server.requests.where((r) => r.contains(book.id)), isEmpty);
      expect(server.files['/dav/TomeVoice/stats.json'], isNot(contains(book.id)), reason: 'the day totals name no book');

      LibraryStore.secretOpen.value = true;
      await BookSync.instance.syncNow(store: store);
      expect(server.files.keys, contains(bookFile()));
    });

    test('a wrong password is said, and nothing changes', () async {
      await turnOn();
      await (await Secrets.of(tmp)).set('webdav', 'wrong');
      await quote(3);
      final r = await BookSync.instance.syncNow(store: store);
      expect(r.problem, contains('did not take'));
      expect(BookSync.instance.status.value.problem, isNotNull);
      expect(server.files.keys.where((k) => k.endsWith('.json')), isEmpty);
      expect(MarkStore.instance.forBook(book.id), hasLength(1));
    });

    test('the sync settings are kept with the others; the password never is', () async {
      await turnOn();
      final json = ListeningPrefs.memory.toJson();
      expect(json['webdavUrl'], server.root.toString());
      expect(jsonEncode(json), isNot(contains('secret')));
      final back = ListeningPrefs.fromJson(json);
      expect(back.webdavOn, isTrue);
      expect(back.webdavUser, 'reader');
      expect(ListeningPrefs.fromJson(const {}).webdavOn, isFalse);
      expect(ListeningPrefs.fromJson(const {}).kosyncOn, isFalse);
      expect(File('${tmp.path}/.secrets.json').readAsStringSync(), contains('secret'));
    });
  });
}
