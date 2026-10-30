// Secret shelves: while shut, a shelf and its books are left out of what
// the library gives every page, and nothing done to the shelves without
// them (a rename, a reorder) loses them. A secret book removed leaves
// nothing saved from it behind.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart' show ReadingCursor;
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/marks.dart';
import 'package:tomevoice_spike/quote_export.dart';
import 'package:tomevoice_spike/saved_screen.dart';
import 'package:tomevoice_spike/secret_shelf.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;
  late String id;
  late Category secret;

  setUp(() async {
    LibraryStore.secretOpen.value = false;
    tmp = Directory.systemTemp.createTempSync('tv_secret');
    store = LibraryStore(tmp);
    final copy = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/starter.epub');
    id = (await store.importFile(PickedFile(path: copy.path, name: 'Pride and Prejudice.epub'))).id;
    secret = await store.addCategory('Secret', secret: true);
    await store.moveBooks({id}, secret.id);
  });

  tearDown(() {
    LibraryStore.secretOpen.value = false;
    tmp.deleteSync(recursive: true);
  });

  test('a shut secret shelf and its books are left out', () async {
    final shown = await store.index();
    expect(shown.categories.any((c) => c.id == secret.id), isFalse);
    expect(shown.entries, isEmpty);
    expect(await store.hiddenIds(), {id});
    expect(store.isSecret(id), isTrue);
    // Imports and the starter book see everything.
    expect((await store.list(all: true)).single.id, id);
  });

  test('opened, it shows with its books', () async {
    LibraryStore.secretOpen.value = true;
    final shown = await store.index();
    expect(shown.categories.any((c) => c.id == secret.id && c.secret), isTrue);
    expect(shown.inCategory(secret.id).single.id, id);
    expect(await store.hiddenIds(), isEmpty);
  });

  test('shelves saved while it is shut keep it, and its books stay on it', () async {
    final shown = await store.index();
    await store.saveCategories([for (final c in shown.categories.reversed) c.renamed('${c.name}!')]);
    final all = await store.index(all: true);
    expect(all.categories.where((c) => c.secret).single.id, secret.id);
    expect(all.entries.single.category, secret.id);
  });

  test('a secret shelf is never where new books go, nor the only shelf', () async {
    final all = await store.index(all: true);
    await store.saveCategories(all.categories, defaultCategory: secret.id);
    expect((await store.index(all: true)).defaultCategory, isNot(secret.id));
    await store.saveCategories([for (final c in all.categories) c.withSecret(true)]);
    expect((await store.index(all: true)).categories.where((c) => !c.secret), isNotEmpty);
  });

  test('the flag survives being written and read back', () async {
    final fresh = LibraryStore(tmp);
    final all = await fresh.index(all: true);
    expect(all.categories.firstWhere((c) => c.id == secret.id).secret, isTrue);
  });

  test('its file opened again keeps it on the secret shelf, still hidden', () async {
    final again = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/again.epub');
    final entry = await store.importFile(PickedFile(path: again.path, name: 'Pride and Prejudice.epub'));
    expect(entry.id, id);
    expect(store.isSecret(id), isTrue);
    expect((await store.index()).entries, isEmpty);
  });

  group('removed', () {
    setUp(() async {
      MarkStore.instance.reset();
      await MarkStore.instance.attach(tmp);
    });
    tearDown(MarkStore.instance.reset);

    Future<void> save(String bookId, String title, MarkKind kind, String text) =>
        MarkStore.instance.add(bookId: bookId, bookTitle: title, kind: kind, at: ReadingCursor.zero, text: text);

    /// A book on an ordinary shelf.
    Future<String> openBook() async {
      final f = File('${tmp.path}/incoming/open.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('Chapter 1\n\n${'An open story goes on. ' * 30}');
      return (await store.importFile(PickedFile(path: f.path, name: 'open.txt'))).id;
    }

    test('a secret book takes what was saved from it: gone from the marks, their file and exports', () async {
      await save(id, 'Pride and Prejudice', MarkKind.quote, 'It is a truth universally acknowledged.');
      await save(id, 'Pride and Prejudice', MarkKind.bookmark, 'A single man in possession of a good fortune.');
      final open = await openBook();
      await save(open, 'Open', MarkKind.quote, 'An open story goes on.');

      await store.remove(id);
      expect(MarkStore.instance.forBook(id), isEmpty);
      expect(MarkStore.instance.forBook(open), hasLength(1));
      final file = File('${tmp.path}/marks.json').readAsStringSync();
      expect(file, isNot(contains('universally')));
      expect(file, isNot(contains('Pride and Prejudice')));
      // Shut or open, an export has nothing of it: there is nothing left.
      for (final shelfOpen in [false, true]) {
        LibraryStore.secretOpen.value = shelfOpen;
        expect([for (final b in await quotesToExport(store)) for (final q in b.quotes) q.bookId], [open]);
      }
    });

    test('a book on an open shelf leaves its quotes, as ever', () async {
      final open = await openBook();
      await save(open, 'Open', MarkKind.quote, 'An open story goes on.');
      await store.remove(open);
      expect(MarkStore.instance.forBook(open), hasLength(1));
    });

    testWidgets("Saved shows nothing of a secret book once it is removed", (tester) async {
      await tester.runAsync(() async {
        await save(id, 'Pride and Prejudice', MarkKind.quote, 'It is a truth universally acknowledged.');
        await store.remove(id);
        await store.index(all: true);
      });
      await tester.pumpWidget(MaterialApp(home: SavedScreen(store: store)));
      await tester.pumpAndSettle();
      expect(find.textContaining('universally'), findsNothing);
      expect(find.text('Pride and Prejudice'), findsNothing);
      expect(find.text('No quotes yet'), findsOneWidget);
    });
  });

  testWidgets('shown while shut, a secret book asks for the lock first', (tester) async {
    const channel = MethodChannel('tomevoice/tts');
    final asked = <String>[];
    var answer = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call.method);
      return call.method == 'confirmUser' ? answer : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final context = tester.element(find.byType(SizedBox));

    // Cancelled: not shown, and the shelf stays shut.
    expect(await SecretShelf.mayShow(context, store, id), isFalse);
    expect(asked, ['confirmUser']);
    expect(SecretShelf.open.value, isFalse);
    await tester.pump(const Duration(seconds: 1));

    // The phone's lock given: shown, and the shelf is open.
    answer = true;
    expect(await SecretShelf.mayShow(context, store, id), isTrue);
    expect(SecretShelf.open.value, isTrue);
    // Open, nothing more is asked; a book on no secret shelf never asks.
    asked.clear();
    expect(await SecretShelf.mayShow(context, store, id), isTrue);
    LibraryStore.secretOpen.value = false;
    expect(await SecretShelf.mayShow(context, store, 'not-a-secret-book'), isTrue);
    expect(asked.where((m) => m == 'confirmUser'), isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });
}
