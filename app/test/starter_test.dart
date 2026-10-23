// The book a new install starts with: it must import as itself, with its
// cover, from the copy inside the app.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/library_store.dart';
import 'package:tomevoice_spike/speech_service.dart';

void main() {
  test('the bundled Pride and Prejudice imports with its title, author and cover', () async {
    final tmp = Directory.systemTemp.createTempSync('tv_starter');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final copy = File('assets/starter/pride-and-prejudice.epub').copySync('${tmp.path}/starter.epub');
    final e = await LibraryStore(tmp).importFile(PickedFile(path: copy.path, name: 'Pride and Prejudice.epub'));
    expect(e.title, contains('Pride and Prejudice'));
    expect(e.authors.join(), contains('Austen'));
    expect(e.cover, isNotNull, reason: 'the peacock cover');
    expect(e.wordCount, greaterThan(100000));
  });
}
