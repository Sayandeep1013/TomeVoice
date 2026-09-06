import 'dart:io';

import '../test/epub_fixture.dart';

void main(List<String> args) {
  final out = args.isEmpty ? 'fox-book.epub' : args.first;
  File(out).writeAsBytesSync(minimalEpub());
  stdout.writeln(out);
}
