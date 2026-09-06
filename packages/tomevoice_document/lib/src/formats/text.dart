import 'dart:convert';
import 'dart:typed_data';

import '../build.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

Book parseText(
  Uint8List bytes, {
  required String id,
  String? filename,
  SourceKind kind = SourceKind.text,
}) {
  final raw = _decode(bytes);
  resetBlockIds();
  final title = _titleFromName(filename) ?? _firstLineTitle(raw) ?? 'Untitled';

  if (kind == SourceKind.markdown) {
    return _markdown(id, title, raw, filename);
  }
  if (kind == SourceKind.html) {
    final blocks = blocksFromHtml(raw);
    final sections = [
      Section(id: 's0', index: 0, title: title, blocks: blocks),
    ];
    final book = Book(
      id: id,
      metadata: BookMetadata(title: title, language: 'en'),
      sections: sections,
      toc: [TocEntry(title: title, sectionIndex: 0)],
      source: SourceKind.html,
      sourceName: filename,
      wordCount: 0,
    );
    return Book(
      id: book.id,
      metadata: book.metadata,
      sections: book.sections,
      toc: book.toc,
      source: book.source,
      sourceName: book.sourceName,
      wordCount: wordCountOf(book),
    );
  }

  final paragraphs = raw
      .split(RegExp(r'\n\s*\n'))
      .map(collapseWhitespace)
      .where((p) => p.isNotEmpty)
      .toList();

  final blocks = [
    for (final p in paragraphs)
      makeBlock(
        role: _looksLikeHeading(p) ? BlockRole.heading : BlockRole.paragraph,
        text: p,
        anchor: OffsetAnchor(0, p.length),
      ),
  ];

  final book = Book(
    id: id,
    metadata: BookMetadata(title: title, language: 'en'),
    sections: [
      Section(id: 's0', index: 0, title: title, blocks: blocks),
    ],
    toc: [TocEntry(title: title, sectionIndex: 0)],
    source: kind,
    sourceName: filename,
    wordCount: 0,
  );
  return Book(
    id: book.id,
    metadata: book.metadata,
    sections: book.sections,
    toc: book.toc,
    source: book.source,
    sourceName: book.sourceName,
    wordCount: wordCountOf(book),
  );
}

Book _markdown(String id, String title, String raw, String? filename) {
  final sections = <Section>[];
  var currentTitle = title;
  var current = <Block>[];
  var index = 0;

  void flush() {
    if (current.isEmpty && sections.isNotEmpty) return;
    sections.add(Section(
      id: 's$index',
      index: index,
      title: currentTitle,
      blocks: List<Block>.from(current),
    ));
    index++;
    current = [];
  }

  for (final line in raw.split('\n')) {
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      if (current.isNotEmpty) flush();
      currentTitle = collapseWhitespace(heading.group(2)!);
      current.add(makeBlock(
        role: BlockRole.heading,
        text: currentTitle,
      ));
      continue;
    }
    if (line.trim().isEmpty) continue;
    current.add(makeBlock(
      role: BlockRole.paragraph,
      text: line.trim(),
    ));
  }
  flush();

  if (sections.isEmpty) {
    sections.add(Section(id: 's0', index: 0, title: title, blocks: const []));
  }

  final toc = [
    for (final s in sections) TocEntry(title: s.displayTitle, sectionIndex: s.index),
  ];
  final book = Book(
    id: id,
    metadata: BookMetadata(title: title, language: 'en'),
    sections: sections,
    toc: toc,
    source: SourceKind.markdown,
    sourceName: filename,
    wordCount: 0,
  );
  return Book(
    id: book.id,
    metadata: book.metadata,
    sections: book.sections,
    toc: book.toc,
    source: book.source,
    sourceName: book.sourceName,
    wordCount: wordCountOf(book),
  );
}

String _decode(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3));
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

String? _titleFromName(String? filename) {
  if (filename == null || filename.isEmpty) return null;
  final slash = filename.replaceAll('\\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  final stem = dot > 0 ? slash.substring(0, dot) : slash;
  final cleaned = stem.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  return cleaned.isEmpty ? null : cleaned;
}

String? _firstLineTitle(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.length <= 80) return t;
    return null;
  }
  return null;
}

bool _looksLikeHeading(String p) =>
    p.length <= 80 &&
    !p.endsWith('.') &&
    !p.endsWith('?') &&
    !p.endsWith('!') &&
    p == p.toUpperCase() &&
    RegExp(r'[A-Z]').hasMatch(p);
