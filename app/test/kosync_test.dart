// KOReader's sync, done as KOReader does it: its partial MD5 of a book file
// (checked against values worked out from KOReader's own algorithm by a
// separate program), the password's MD5 as the key, the server's own API
// (against a KOReader sync server on this computer), and TomeVoice's place
// as a share of the book, both ways.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/kosync.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/secrets.dart';
import 'package:tomevoice_spike/speech_service.dart';
import 'package:tomevoice_spike/stats.dart';
import 'package:tomevoice_spike/sync.dart';

import 'support/kosync_server.dart';
import 'support/opds_server.dart' show sampleEpub;

/// n bytes: i * 31 + 7, modulo 256 (the same as the program that worked
/// out the digests below).
Uint8List _pattern(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + 7) & 0xFF]);

/// KOReader's partial MD5 of [_pattern] files, by length, from an
/// independent implementation of util.partialMD5 (Python, LuaJIT's 32-bit
/// shift and all).
const _known = {
  0: 'd41d8cd98f00b204e9800998ecf8427e',
  1: '89e74e640b8c46257a29de0616794d5d',
  1023: 'aa217140da10ed9796690dd1ed22a21a',
  1024: '63b2177a7af739b5cc52ab1d1c714702',
  1025: '31d56d8e673d2856b7a4eee144ee8275',
  4095: 'fbb2e3b38a23c7d820533df281b4b6ec',
  4096: 'fbb2e3b38a23c7d820533df281b4b6ec',
  5000: '5ed57c7e8b80bdccb94703bbbbe792b7',
  70000: '7c495b34b24f561520622156e96f834d',
  300000: '3840df5dc77bb7f3d6d4b67e0979ed0b',
  1100000: '9176994efdf840ffd6a4fb8d1cd31fb1',
  4200000: '4448bc4b5b98051a0a8f767b1d69ebcb',
};

void main() {
  group("KOReader's document id", () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('tomevoice_md5'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('matches values worked out from its algorithm, from a file and from bytes', () async {
      for (final MapEntry(key: n, value: want) in _known.entries) {
        final bytes = _pattern(n);
        final f = File('${tmp.path}/b$n')..writeAsBytesSync(bytes);
        expect(await koreaderPartialMd5(f), want, reason: '$n bytes');
        expect(koreaderPartialMd5Of(bytes), want, reason: '$n bytes in memory');
      }
    });

    test('samples at 0, 1 KB, 4 KB, 16 KB ...: the same as hashing those by hand', () {
      final bytes = _pattern(70000);
      final by = BytesBuilder()
        ..add(bytes.sublist(0, 1024))
        ..add(bytes.sublist(1024, 2048))
        ..add(bytes.sublist(4096, 5120))
        ..add(bytes.sublist(16384, 17408))
        ..add(bytes.sublist(65536, 66560));
      expect(koreaderPartialMd5Of(bytes), md5.convert(by.takeBytes()).toString());
      // A change past the last sample is not seen (as in KOReader).
      final changed = Uint8List.fromList(bytes)..[69000] ^= 0xFF;
      expect(koreaderPartialMd5Of(changed), koreaderPartialMd5Of(bytes));
      final early = Uint8List.fromList(bytes)..[10] ^= 0xFF;
      expect(koreaderPartialMd5Of(early), isNot(koreaderPartialMd5Of(bytes)));
    });

    test("the key is the password's MD5", () {
      expect(koreaderKey('secret'), '5ebe2294ecd0e0f08eab7690d2a6ee69');
    });
  });

  group('places as shares of the book', () {
    test('every sentence of a book goes to a share and back to itself', () {
      final book = specimenBook();
      final units = flattenSpeakable(book);
      var last = -1.0;
      for (final u in units) {
        final c = cursorOf(u);
        final p = percentOf(book, c);
        expect(p, greaterThanOrEqualTo(last), reason: 'further on, further through');
        last = p;
        final back = placeAt(book, p);
        expect((back.sectionIndex, back.blockIndex, back.sentenceIndex), (c.sectionIndex, c.blockIndex, c.sentenceIndex));
      }
      expect(percentOf(book, cursorOf(units.first)), 0);
      final end = placeAt(book, 1);
      final lastUnit = cursorOf(units.last);
      expect((end.sectionIndex, end.blockIndex, end.sentenceIndex),
          (lastUnit.sectionIndex, lastUnit.blockIndex, lastUnit.sentenceIndex));
    });

    test("a PDF's share is its page of the pages, and its place a page number", () {
      final book = Book(
        id: 'p',
        metadata: const BookMetadata(title: 'P'),
        source: SourceKind.pdf,
        toc: const [],
        sections: [
          Section(id: 's', index: 0, blocks: [
            for (var page = 0; page < 10; page++)
              makeBlock(role: BlockRole.paragraph, text: 'Page ${page + 1} has words on it.', anchor: PageAnchor(page)),
          ]),
        ],
      );
      const third = ReadingCursor(blockIndex: 2);
      expect(percentOf(book, third), 0.3);
      expect(progressOf(book, third), '3');
      expect(placeAt(book, 0.3).blockIndex, 2);
      expect(placeAt(book, 0.0, page: 7).blockIndex, 6, reason: "KOReader's page, 1-based");
    });

    test("an EPUB's place is a pointer to its chapter file, as KOReader numbers them", () {
      final bytes = sampleEpub();
      final spine = epubSpine(bytes);
      expect(spine, ['OEBPS/c1.xhtml']);
      final book = ingestBytes(bytes, filename: 'b.epub');
      final c = cursorOf(flattenSpeakable(book)[3]);
      expect(progressOf(book, c, spine: spine), '/body/DocFragment[1]');
      // Without the spine, or for a book KOReader would read another way,
      // nothing is said rather than something wrong.
      expect(progressOf(book, c), isNull);
      expect(progressOf(specimenBook(), cursorOf(flattenSpeakable(specimenBook()).first)), isNull);
    });
  });

  group('with a KOReader sync server', () {
    late KosyncTestServer server;
    setUp(() async => server = await KosyncTestServer.start());
    tearDown(() => server.close());

    test('register, sign in, send and read a place, as the KOReader plugin does', () async {
      final key = koreaderKey('secret');
      final me = KosyncClient(server.root, user: 'reader', key: key);
      expect(await me.register(), isTrue);
      expect(server.users['reader'], key, reason: 'the password itself never goes');
      expect(await me.register(), isFalse, reason: 'taken');
      await me.authorize();
      await expectLater(KosyncClient(server.root, user: 'reader', key: koreaderKey('nope')).authorize(),
          throwsA(isA<KosyncAuthException>()));

      expect(await me.pull('abc'), isNull);
      server.clock = () => 1730000000;
      final at = await me.push('abc', percentage: 0.4231, progress: '/body/DocFragment[3]', device: 'TomeVoice', deviceId: 'D1');
      expect(at, 1730000000);
      final back = (await me.pull('abc'))!;
      expect(back.percentage, 0.4231);
      expect(back.progress, '/body/DocFragment[3]');
      expect(back.device, 'TomeVoice');
      expect(back.deviceId, 'D1');
      expect(back.timestamp, 1730000000);
      me.close();
    });
  });

  group('syncing a book', () {
    late Directory tmp;
    late KosyncTestServer server;
    late LibraryStore store;
    late LibraryEntry book;
    late String doc;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tomevoice_kosync');
      server = await KosyncTestServer.start();
      ListeningPrefs.reset();
      MarkStore.instance.reset();
      StatsStore.instance.days.clear();
      store = LibraryStore(tmp);
      final bytes = sampleEpub(title: 'Kosync Book');
      final f = File('${tmp.path}/incoming/k.epub')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      book = await store.importFile(PickedFile(path: f.path, name: 'k.epub'));
      doc = koreaderPartialMd5Of(bytes);
      server.users['reader'] = koreaderKey('secret');
      ListeningPrefs.memory
        ..kosyncOn = true
        ..kosyncUrl = server.root.toString()
        ..kosyncUser = 'reader';
      await (await Secrets.of(tmp)).set('kosync', koreaderKey('secret'));
    });

    tearDown(() async {
      await server.close();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test("this phone's place goes as a share and a chapter pointer; a newer one from KOReader comes back", () async {
      final layout = await store.loadLayout(book.id);
      final at = layout.units.length ~/ 2;
      await store.saveCursor(book.id, cursorOf(layout.units[at]), 0.5);
      final r = await BookSync.instance.syncNow(store: store);
      expect(r.problem, isNull);
      final sent = server.progress['reader']![doc]!;
      expect(sent['device'], 'TomeVoice');
      expect(sent['progress'], '/body/DocFragment[1]');
      final pct = sent['percentage'] as double;
      expect(pct, closeTo(at / layout.units.length, 0.08));
      final mine = sent['device_id'] as String;
      expect(mine, hasLength(32));

      // Unmoved: not sent again; its own place is not taken back.
      final puts = server.requests.where((q) => q.startsWith('PUT')).length;
      await BookSync.instance.syncNow(store: store);
      expect(server.requests.where((q) => q.startsWith('PUT')).length, puts);

      // KOReader on another device read on to 90%, later.
      server.progress['reader']![doc] = {
        'percentage': 0.9,
        'progress': '/body/DocFragment[1]/body/p[100]/text().0',
        'device': 'Kobo',
        'device_id': 'KOBO1',
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      };
      final taken = await BookSync.instance.syncNow(store: store);
      expect(taken.taken, greaterThanOrEqualTo(1));
      final e = (await store.list(all: true)).firstWhere((x) => x.id == book.id);
      final unit = layout.unitForCursor(e.cursor, saved: true);
      expect(percentOf(layout.book, cursorOf(layout.units[unit])), closeTo(0.9, 0.02));
      expect(server.progress['reader']![doc]!['device'], 'Kobo', reason: 'what was taken is not sent back');
    });
  });
}
