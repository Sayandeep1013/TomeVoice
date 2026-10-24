// The library's files on the phone: changes made at the same moment both
// stay, and a damaged file is kept aside or rebuilt instead of costing the
// reader their shelf or a book.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;
  late String id;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tv_safety');
    store = LibraryStore(tmp);
    final copy = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/starter.epub');
    id = (await store.importFile(PickedFile(path: copy.path, name: 'Pride and Prejudice.epub'))).id;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a place saved while the book is moved keeps both', () async {
    final later = Category.defaults.last.id;
    await Future.wait([
      store.saveCursor(id, ReadingCursor.zero, 0.5),
      store.moveBooks({id}, later),
      store.forgetOpened('nobody'),
    ]);
    final e = (await store.list()).single;
    expect(e.progress, 0.5);
    expect(e.category, later);
  });

  test('an unreadable library list is kept aside, not written over', () async {
    File('${tmp.path}/library.json').writeAsStringSync('{"books": [ {"id": "cut sho');
    expect(await store.list(), isEmpty);
    expect(File('${tmp.path}/library.json.broken').readAsStringSync(), contains('cut sho'));
  });

  test('a book whose parsed copy was cut short opens from its own file', () async {
    File('${tmp.path}/books/$id/parsed.json').writeAsStringSync('{"v": 5, "book": {"id"');
    final layout = await store.loadLayout(id);
    expect(layout.units, isNotEmpty);
  });
}
