// A book's file replaced by another edition: the new file becomes the
// book, and its place, quotes and bookmarks are found again in it by their
// sentences; the shelf it was on, and its voice, go with it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/book_replace.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/prefs.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  group('a sentence followed into another edition', () {
    final from = ['One.', 'Two.', 'Three.', 'Four.', 'Five.', 'Six.'];

    test('the same words, the copy nearest where it would be', () {
      expect(followSentence(from, ['A new preface.', ...from], 3), 4);
      // "Two." twice: the one nearest its place.
      expect(followSentence(['Two.', 'x', 'y', 'z', 'Two.'], ['Two.', 'x', 'y', 'z', 'q', 'Two.'], 4), 5);
    });

    test('a sentence changed is found by its neighbours', () {
      final to = ['One.', 'Two.', 'Three, corrected.', 'Four.', 'Five.', 'Six.'];
      expect(followSentence(from, to, 2), 2);
      // Changed and its neighbours too, as far through as it was.
      expect(followSentence(from, ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'], 3), 6);
      expect(followSentence(from, const [], 3), 0);
    });
  });

  group('replacing the file', () {
    late Directory dir;
    late LibraryStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tv_replace');
      store = LibraryStore(dir);
      MarkStore.instance.reset();
      ListeningPrefs.reset();
    });

    tearDown(() {
      MarkStore.instance.reset();
      ListeningPrefs.reset();
      dir.deleteSync(recursive: true);
    });

    PickedFile file(String name, String text) {
      final f = File('${dir.path}/incoming/${DateTime.now().microsecondsSinceEpoch}/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
      return PickedFile(path: f.path, name: name);
    }

    String book(String typo) => [
          '# Chapter 1',
          'The sea was calm that morning.',
          '',
          'Nobody on the shore had seen the $typo ship before.',
          '',
          '# Chapter 2',
          'It came closer with every hour.',
          '',
          'By noon the harbour master was worried.',
        ].join('\n');

    test('the place, the quote and the voice go to the new edition; the old one goes', () async {
      final old = await store.importFile(file('sea.md', book('stange')));
      final layout = await store.loadLayout(old.id);
      final worried = layout.units.indexWhere((u) => u.text.startsWith('By noon'));
      final at = layout.units[worried];
      final place = ReadingCursor(sectionIndex: at.sectionIndex, blockIndex: at.blockIndex, sentenceIndex: at.sentenceIndex);
      await store.saveCursor(old.id, place, 0.8);
      await MarkStore.instance.add(
          bookId: old.id, bookTitle: old.title, kind: MarkKind.quote, at: place, text: at.text);
      ListeningPrefs.memory.voiceByBook[old.id] = 'en-gb-x-rjs-local';

      final fresh = await replaceBookFile(store, old, file('sea.md', '${book('strange')}\n\nThe end.'));
      expect(fresh, isNotNull);
      expect(fresh!.id, isNot(old.id));

      final ids = (await store.list(all: true)).map((e) => e.id);
      expect(ids, [fresh.id]);
      expect(Directory(store.bookDir(old.id)).existsSync(), isFalse);

      final newLayout = await store.loadLayout(fresh.id);
      String sentenceAt(ReadingCursor c) => newLayout.units[unitAtCursor(newLayout.units, c)].text;
      expect(sentenceAt(await store.cursorFor(fresh.id)), startsWith('By noon'));
      expect(fresh.progress, 0.8);
      final quote = MarkStore.instance.forBook(fresh.id).single;
      expect(sentenceAt(quote.at), startsWith('By noon'));
      expect(MarkStore.instance.forBook(old.id), isEmpty);
      expect(ListeningPrefs.memory.voiceByBook[fresh.id], 'en-gb-x-rjs-local');
    });

    test('the same file picked again changes nothing', () async {
      final old = await store.importFile(file('sea.md', book('strange')));
      expect(await replaceBookFile(store, old, file('sea.md', book('strange'))), isNull);
      expect((await store.list(all: true)).map((e) => e.id), [old.id]);
    });
  });
}
