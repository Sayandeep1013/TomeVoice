import 'dart:io';
import 'dart:math';

import 'package:tomevoice_document/tomevoice_document.dart';

void main(List<String> args) {
  final path = args.first;
  final book = ingestBytes(
    File(path).readAsBytesSync(),
    filename: path,
  );
  final units = flattenSpeakable(book);
  stdout.writeln('title=${book.metadata.title}');
  stdout.writeln('language=${book.metadata.language}');
  stdout.writeln('authors=${book.metadata.authors.join('; ')}');
  stdout.writeln('sections=${book.sections.length}');
  stdout.writeln('sentences=${units.length}');
  stdout.writeln('wordCount=${book.wordCount}');
  stdout.writeln('--- sections ---');
  for (final s in book.sections) {
    final n = units.where((u) => u.sectionIndex == s.index).length;
    final chars = s.blocks.fold<int>(0, (a, b) => a + b.text.length);
    stdout.writeln(
      '${s.index.toString().padLeft(3)} sentences=${n.toString().padLeft(5)} '
      'chars=${chars.toString().padLeft(6)} title=${s.displayTitle}',
    );
  }
  stdout.writeln('--- first 8 speakable ---');
  for (final u in units.take(8)) {
    stdout.writeln('[s${u.sectionIndex}] ${u.text}');
  }
  // First section with real chapter-sized text.
  final meat = book.sections.where((s) {
    final chars = s.blocks.fold<int>(0, (a, b) => a + b.text.length);
    return chars > 800;
  });
  if (meat.isNotEmpty) {
    final s = meat.first;
    stdout.writeln('--- first meaty section s${s.index} ${s.displayTitle} ---');
    for (final b in s.blocks.take(6)) {
      final sample = b.text.substring(0, min(220, b.text.length));
      stdout.writeln('  [${b.role.name}] $sample');
    }
  }
  // Flag replacement chars / empty-looking glyphs.
  var replacement = 0;
  var nonAscii = 0;
  for (final u in units.take(200)) {
    replacement += '\uFFFD'.allMatches(u.text).length;
    nonAscii += u.text.runes.where((r) => r > 127).length;
  }
  stdout.writeln('replacementCharsInFirst200=$replacement');
  stdout.writeln('nonAsciiInFirst200=$nonAscii');
  final chapters = readingSectionIndexes(book, units);
  stdout.writeln('readingChapters=${chapters.length}');
  if (units.isNotEmpty) {
    stdout.writeln(
      'opensOn=${units[firstReadingUnitIndex(units, book)].text}',
    );
  }

  final chapter = book.sections.where(
    (s) => s.displayTitle.toLowerCase().contains('chapter'),
  );
  if (chapter.isNotEmpty) {
    final s = chapter.first;
    stdout.writeln('--- ${s.displayTitle} first sentences ---');
    for (final u in units.where((u) => u.sectionIndex == s.index).take(8)) {
      stdout.writeln(u.text);
    }
  }
}
