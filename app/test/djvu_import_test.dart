// A DjVu brought in as any other book: read by its hidden text, on the
// import isolate, and listed by its own format.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  late Directory tmp;
  late LibraryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tv_djvu');
    store = LibraryStore(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  PickedFile copyIn(String name, List<int> bytes) {
    final f = File('${tmp.path}/incoming/s/$name')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return PickedFile(path: f.path, name: name, mime: 'image/vnd.djvu');
  }

  test('a scanned play in DjVu is imported, its text read and its pages kept', () async {
    final bytes = File('../packages/tomevoice_document/test/fixtures/game-of-comedy.djvu').readAsBytesSync();
    final entry = await store.importFile(copyIn('A Game of Comedy.djvu', bytes));
    expect(entry.source, SourceKind.djvu);
    expect(entry.formatLabel, 'DJVU');
    expect(entry.title, 'A Game of Comedy');
    final book = (await store.loadLayout(entry.id)).book;
    final texts = [
      for (final s in book.sections)
        for (final b in s.blocks) b.text,
    ];
    expect(texts, contains('Pierre. Goodness ! A woman !'));
    expect(book.sections.last.blocks.last.anchor, isA<PageAnchor>());
  });

  test('a DjVu of pictures only is refused with its own message', () async {
    // One page, its INFO chunk and nothing else.
    final page = [
      ...'AT&TFORM'.codeUnits, 0, 0, 0, 22, ...'DJVU'.codeUnits, //
      ...'INFO'.codeUnits, 0, 0, 0, 10, 9, 0xF6, 12, 0xE4, 24, 0, 0x2C, 1, 22, 1,
    ];
    await expectLater(
      store.importFile(copyIn('scan.djvu', page)),
      throwsA(isA<UnsupportedDocumentException>().having((e) => e.message, 'message', contains('pictures only'))),
    );
  });
}
