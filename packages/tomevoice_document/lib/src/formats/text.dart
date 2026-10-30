import 'dart:typed_data';

import '../build.dart';
import '../encoding.dart';
import '../model.dart';
import '../segment.dart';
import 'html_blocks.dart';

Book parseText(
  Uint8List bytes, {
  required String id,
  String? filename,
  SourceKind kind = SourceKind.text,
  LegacyDecoder? legacy,
}) =>
    parseTextString(
      decodeText(bytes, legacy: legacy, markup: kind == SourceKind.html),
      id: id,
      filename: filename,
      kind: kind,
    );

/// Noncharacters TomeVoice uses inside its own pipeline; never book text.
final _ownMarks = RegExp('[${String.fromCharCode(0xFDD0)}-${String.fromCharCode(0xFDD2)}]');

Book parseTextString(
  String raw, {
  required String id,
  String? filename,
  SourceKind kind = SourceKind.text,
}) {
  raw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(_ownMarks, '');
  resetBlockIds();
  final title = titleFromFilename(filename) ?? _firstLineTitle(raw) ?? 'Untitled';
  final metadata = BookMetadata(title: title);

  if (kind == SourceKind.markdown) {
    return _markdown(id, metadata, raw, filename);
  }
  if (kind == SourceKind.html) {
    return assembleBook(
      id: id,
      metadata: metadata,
      sections: [(title: title, blocks: blocksFromHtml(raw))],
      source: SourceKind.html,
      filename: filename,
    );
  }
  return assembleBook(
    id: id,
    metadata: metadata,
    sections: sectionsFromPlainText(raw, fallbackTitle: title),
    source: kind,
    filename: filename,
  );
}

/// Paragraphs and chapters out of plain text.
///
/// Two shapes are common. Gutenberg-style files separate paragraphs with a
/// blank line and hard-wrap the lines inside them; many other files (web
/// dumps, phone notes, translated novels) put one paragraph per line with no
/// blank lines at all. Treating the second shape like the first turned a
/// whole novel into a single paragraph.
List<DraftSection> sectionsFromPlainText(
  String raw, {
  required String fallbackTitle,
}) {
  final lines = raw.split('\n');
  final nonEmpty = lines.where((l) => l.trim().isNotEmpty).length;
  var blank = 0;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim().isEmpty && lines[i - 1].trim().isNotEmpty) blank++;
  }
  final blankSeparated = nonEmpty > 0 && blank >= nonEmpty / 6;

  final paragraphs = <String>[];
  if (blankSeparated) {
    final buf = <String>[];
    void flush() {
      if (buf.isEmpty) return;
      paragraphs.add(joinWrappedLines(buf));
      buf.clear();
    }

    for (final l in lines) {
      if (l.trim().isEmpty) {
        flush();
      } else if (buf.isNotEmpty && looksLikeChapterLine(l)) {
        flush();
        buf.add(l);
        flush();
      } else {
        buf.add(l);
      }
    }
    flush();
  } else {
    for (final l in lines) {
      final t = collapseWhitespace(l);
      if (t.isNotEmpty) paragraphs.add(t);
    }
  }

  final sections = <DraftSection>[];
  String? title = fallbackTitle;
  var blocks = <Block>[];
  var chapters = 0;
  for (final p in paragraphs) {
    if (looksLikeChapterLine(p)) {
      if (blocks.isNotEmpty) sections.add((title: title, blocks: blocks));
      chapters++;
      title = p;
      blocks = [makeBlock(role: BlockRole.heading, text: p)];
      continue;
    }
    blocks.add(makeBlock(
      role: _looksLikeHeading(p) ? BlockRole.heading : BlockRole.paragraph,
      text: p,
    ));
  }
  if (blocks.isNotEmpty) sections.add((title: title, blocks: blocks));

  // One "chapter" line in a whole file is probably prose, not structure.
  if (chapters < 2) {
    return _parts([for (final s in sections) ...s.blocks], fallbackTitle);
  }
  return sections;
}

/// About a chapter's worth of words: a long text with no chapters of its
/// own is cut into parts of this size, at paragraph ends, so the reader
/// has places to jump to and a chapter to finish.
const _partWords = 4000;

List<DraftSection> _parts(List<Block> blocks, String title) {
  final total = blocks.fold<int>(0, (n, b) => n + countWords(b.text));
  if (total < _partWords * 2) return [(title: title, blocks: blocks)];
  final out = <DraftSection>[];
  var part = <Block>[];
  var words = 0;
  for (final b in blocks) {
    part.add(b);
    words += countWords(b.text);
    if (words >= _partWords) {
      out.add((title: 'Part ${out.length + 1}', blocks: part));
      part = [];
      words = 0;
    }
  }
  if (part.isNotEmpty) {
    // A short tail joins the part before it rather than standing alone.
    if (words < _partWords ~/ 3 && out.isNotEmpty) {
      final last = out.removeLast();
      out.add((title: last.title, blocks: [...last.blocks, ...part]));
    } else {
      out.add((title: 'Part ${out.length + 1}', blocks: part));
    }
  }
  return out;
}

/// Join hard-wrapped lines into one paragraph, mending words that were
/// hyphenated across a line break ("exam-\nple" -> "example").
String joinWrappedLines(List<String> lines) {
  final parts = <String>[];
  for (final raw in lines) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (parts.isNotEmpty) {
      final prev = parts.last;
      if (prev.length >= 2 &&
          prev.endsWith('-') &&
          _isLetterUnit(prev.codeUnitAt(prev.length - 2)) &&
          _isLowerUnit(l.codeUnitAt(0))) {
        parts[parts.length - 1] = prev.substring(0, prev.length - 1) + l;
        continue;
      }
    }
    parts.add(l);
  }
  return collapseWhitespace(parts.join(' '));
}

bool _isLetterUnit(int c) =>
    (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0xC0;
bool _isLowerUnit(int c) => (c >= 97 && c <= 122) || (c >= 0xDF && c <= 0xFF);

Book _markdown(String id, BookMetadata metadata, String raw, String? filename) {
  final sections = <DraftSection>[];
  String? currentTitle = metadata.title;
  var current = <Block>[];
  final para = <String>[];

  void flushPara() {
    if (para.isEmpty) return;
    final text = _stripInlineMarkdown(joinWrappedLines(para));
    para.clear();
    if (text.isEmpty) return;
    final list = RegExp(r'^([-*+]|\d+[.)])\s+').hasMatch(text);
    current.add(makeBlock(
      role: list ? BlockRole.listItem : BlockRole.paragraph,
      text: text.replaceFirst(RegExp(r'^([-*+]|\d+[.)])\s+'), ''),
    ));
  }

  var inCode = false;
  for (final line in raw.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      flushPara();
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    final heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$').firstMatch(line);
    if (heading != null) {
      flushPara();
      final level = heading.group(1)!.length;
      final text = _stripInlineMarkdown(collapseWhitespace(heading.group(2)!));
      if (level <= 2 && current.isNotEmpty) {
        sections.add((title: currentTitle, blocks: current));
        current = [];
      }
      if (level <= 2) currentTitle = text;
      current.add(makeBlock(role: BlockRole.heading, text: text));
      continue;
    }
    if (line.trim().isEmpty ||
        RegExp(r'^\s*([-*_]\s*){3,}$').hasMatch(line)) {
      flushPara();
      continue;
    }
    if (RegExp(r'^\s*([-*+]|\d+[.)])\s+').hasMatch(line)) flushPara();
    para.add(line.replaceFirst(RegExp(r'^\s*>\s?'), ''));
  }
  flushPara();
  if (current.isNotEmpty) sections.add((title: currentTitle, blocks: current));

  return assembleBook(
    id: id,
    metadata: metadata,
    sections: sections,
    source: SourceKind.markdown,
    filename: filename,
  );
}

String _stripInlineMarkdown(String s) => s
    .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAllMapped(RegExp(r'(\*\*|__)(.+?)\1'), (m) => m.group(2)!)
    .replaceAllMapped(RegExp(r'(?<![\w*])[*_](\S.*?)[*_](?![\w*])'),
        (m) => m.group(1)!)
    .replaceAll('`', '');

/// Bytes to text: a byte order mark, then (for HTML) the charset it
/// declares, then UTF-8 when the bytes are mostly UTF-8, then UTF-16
/// without a mark, an East Asian encoding through [legacy], a Cyrillic code
/// page, and Windows-1252. See [decodeBytes].
String decodeText(Uint8List bytes, {LegacyDecoder? legacy, bool markup = false}) =>
    decodeBytes(bytes, markup: markup, legacy: legacy);

/// Windows-1252: Latin-1 plus curly quotes and dashes in 0x80-0x9F, which is
/// what nearly every "ANSI" text file actually is.
String decodeCp1252(List<int> bytes) => decodeSingleByte(bytes, 'windows-1252');

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
