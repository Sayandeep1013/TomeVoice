// Removing a book keeps its AI book memory unless the reader ticks "Also
// delete its book memory": kept aside (kept-memories/<id>/), listed in Book
// memories under the book's name, and moved back into the book's folder when
// the same book (the same id) is added again.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/memory/memory_db.dart';
import 'package:tomevoice_spike/book_actions.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tv_kept');
    store = LibraryStore(tmp);
    await MarkStore.instance.attach(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<LibraryEntry> addStarter() async {
    final copy = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/starter.epub');
    return store.importFile(PickedFile(path: copy.path, name: 'Pride and Prejudice.epub'));
  }

  /// A memory file as the builder leaves one (its content does not matter here).
  void giveMemory(String id, String marker) => File(MemoryDb.pathIn(store.bookDir(id)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(marker);

  test('kept on removing, listed by name, and back when the same book is added again', () async {
    final book = await addStarter();
    giveMemory(book.id, 'the memory');

    await store.remove(book.id, keepMemory: true, memoryChapters: 61);
    expect(Directory(store.bookDir(book.id)).existsSync(), isFalse, reason: 'the book is gone');
    final kept = await store.keptMemories();
    expect(kept.single.id, book.id);
    expect(kept.single.title, book.title);
    expect(kept.single.chapters, 61);

    final again = await addStarter();
    expect(again.id, book.id, reason: 'an id is the file\'s content: the same book has the same one');
    expect(File(MemoryDb.pathIn(store.bookDir(again.id))).readAsStringSync(), 'the memory');
    expect(await store.keptMemories(), isEmpty, reason: 'it is the book\'s again');
  });

  test('without keeping, the memory goes with the book', () async {
    final book = await addStarter();
    giveMemory(book.id, 'the memory');
    await store.remove(book.id);
    expect(await store.keptMemories(), isEmpty);
    await addStarter();
    expect(MemoryDb.existsIn(store.bookDir(book.id)), isFalse);
  });

  test('a kept memory can be deleted for good', () async {
    final book = await addStarter();
    giveMemory(book.id, 'the memory');
    await store.remove(book.id, keepMemory: true);
    await store.deleteKeptMemory(book.id);
    expect(await store.keptMemories(), isEmpty);
    await addStarter();
    expect(MemoryDb.existsIn(store.bookDir(book.id)), isFalse);
  });

  testWidgets('the Remove dialog keeps the memory unless the box is ticked', (tester) async {
    late LibraryEntry book;
    await tester.runAsync(() async {
      book = await addStarter();
      giveMemory(book.id, 'the memory');
    });
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        context = c;
        return const Scaffold();
      }),
    ));
    final removing = removeBook(context, store, book);
    await tester.pumpAndSettle();
    expect(find.text('Also delete its book memory'), findsOneWidget);
    expect(find.textContaining('Its book memory is kept'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('also-memory'))).value, isFalse,
        reason: 'kept unless asked');
    // Ticked, it says so; unticked again, kept.
    await tester.tap(find.text('Also delete its book memory'));
    await tester.pump();
    expect(find.text('Its book memory is deleted too.'), findsOneWidget);
    await tester.tap(find.text('Also delete its book memory'));
    await tester.pump();
    await tester.tap(find.text('Remove'));
    await tester.pump();
    bool? removed;
    unawaited(removing.then((v) => removed = v));
    // The removal's files are real: real time for them, and a pump for
    // what follows each.
    for (var i = 0; i < 100 && removed == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(removed, isTrue);
    await tester.runAsync(() async {
      expect((await store.keptMemories()).single.id, book.id);
    });
  });
}
