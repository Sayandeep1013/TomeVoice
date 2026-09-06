import 'dart:io';

import 'package:tomevoice_document/tomevoice_document.dart';

void main(List<String> args) {
  final path = args.first;
  final book = ingestBytes(
    File(path).readAsBytesSync(),
    filename: path,
  );
  final units = flattenSpeakable(book);
  stdout.writeln('title=${book.metadata.title}');
  stdout.writeln('source=${book.source.name}');
  stdout.writeln('sections=${book.sections.length}');
  stdout.writeln('sentences=${units.length}');
  if (units.isNotEmpty) {
    stdout.writeln('first=${units.first.text}');
  }
}
