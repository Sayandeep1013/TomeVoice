import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'kf8_fixture.dart';

void main() {
  final parts = [
    ['<div class="cover"><p>A Tale of the Coast</p></div>'],
    [
      '<h1>Chapter One</h1><p>The lamp was lit at dusk.</p>',
      '<p>It burned until the boats came home.</p>',
    ],
    ['<h1>Chapter Two</h1><p>The tide turned at <a href="kindle:pos:fid:0001:off:0000">noon</a>.</p>'],
  ];
  const toc = [(title: 'The Lamp', fragment: 1), (title: 'The Tide', fragment: 3)];

  group('damaged Kindle files', () {
    test('a file cut short gives a plain message, wherever it is cut', () {
      final whole = kf8Book(parts: parts, toc: toc);
      for (var n = 0; n < whole.length; n += 7) {
        try {
          ingestBytes(Uint8List.sublistView(whole, 0, n), filename: 'cut.azw3');
        } on ParseException {
          // The plain message.
        } on UnsupportedDocumentException {
          // Too little left to be anything.
        }
      }
      expect(
        () => ingestBytes(Uint8List.sublistView(whole, 0, 120), filename: 'cut.azw3'),
        throwsA(isA<ParseException>().having((e) => e.message, 'message', isNot(contains('Range')))),
      );
    });
  });
}
