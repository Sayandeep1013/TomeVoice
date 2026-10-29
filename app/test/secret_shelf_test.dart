// Secret shelves: while shut, a shelf and its books are left out of what
// the library gives every page, and nothing done to the shelves without
// them (a rename, a reorder) loses them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
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
}
