import 'model.dart';
import 'segment.dart';

int _nextId = 0;

String _blockId() => 'b${_nextId++}';

void resetBlockIds() => _nextId = 0;

Block makeBlock({
  required BlockRole role,
  required String text,
  Anchor? anchor,
  String? language,
  String? id,
}) {
  final collapsed = collapseWhitespace(text);
  return Block(
    id: id ?? _blockId(),
    role: role,
    text: collapsed,
    sentences: segmentSentences(collapsed),
    anchor: anchor ?? OffsetAnchor(0, collapsed.length),
    language: language,
  );
}

List<Speakable> flattenSpeakable(
  Book book, {
  Set<BlockRole> skip = defaultSkippedRoles,
}) {
  final out = <Speakable>[];
  for (final section in book.sections) {
    for (var bi = 0; bi < section.blocks.length; bi++) {
      final block = section.blocks[bi];
      if (skip.contains(block.role) || block.text.isEmpty) continue;
      for (var si = 0; si < block.sentences.length; si++) {
        final sentence = block.sentences[si];
        final text = sentence.of(block.text).trim();
        if (text.isEmpty) continue;
        out.add(Speakable(
          sectionIndex: section.index,
          blockIndex: bi,
          sentenceIndex: si,
          text: text,
          role: block.role,
          blockId: block.id,
        ));
      }
    }
  }
  return out;
}

int indexOfCursor(List<Speakable> units, ReadingCursor cursor) {
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u.sectionIndex == cursor.sectionIndex &&
        u.blockIndex == cursor.blockIndex &&
        u.sentenceIndex == cursor.sentenceIndex) {
      return i;
    }
    if (u.sectionIndex > cursor.sectionIndex) return i;
    if (u.sectionIndex == cursor.sectionIndex &&
        u.blockIndex > cursor.blockIndex) {
      return i;
    }
  }
  return units.isEmpty ? 0 : units.length - 1;
}

ReadingCursor cursorOf(Speakable u) => ReadingCursor(
      sectionIndex: u.sectionIndex,
      blockIndex: u.blockIndex,
      sentenceIndex: u.sentenceIndex,
    );

double progressFraction(List<Speakable> units, int index) {
  if (units.isEmpty) return 0;
  if (index < 0) return 0;
  return ((index + 1) / units.length).clamp(0.0, 1.0);
}

int wordCountOf(Book book) {
  var n = 0;
  for (final s in book.sections) {
    for (final b in s.blocks) {
      n += countWords(b.text);
    }
  }
  return n;
}
