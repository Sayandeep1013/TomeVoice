import 'dart:convert';
import 'dart:typed_data';

/// library.json's bytes, as LibraryStore writes them: pretty-printed with
/// two spaces, exactly as JsonEncoder.withIndent writes the whole map (it is
/// read over USB, by the widgets and by Android Auto, and back-ups carry
/// it). Each book's part is encoded once and kept with its entry in
/// [parts]: an entry is never changed, only replaced, so a write encodes the
/// books that changed since the last one and copies the rest. Encoding the
/// whole shelf again for every saved place was what cost the UI thread.
Uint8List encodeIndex<T extends Object>({
  required List<Map<String, Object?>> categories,
  required String defaultCategory,
  required List<T> books,
  required Map<String, Object?> Function(T book) toJson,
  required Expando<Uint8List> parts,
}) {
  final out = BytesBuilder(copy: false);
  out.add(_head);
  out.add(_nested(categories, 1));
  out.add(utf8.encode(',\n  "defaultCategory": ${jsonEncode(defaultCategory)},\n  "books": '));
  if (books.isEmpty) {
    out.add(_empty);
  } else {
    for (var i = 0; i < books.length; i++) {
      out.add(i == 0 ? _first : _next);
      final b = books[i];
      out.add(parts[b] ??= encodePart(toJson(b)));
    }
    out.add(_close);
  }
  out.add(_end);
  return out.takeBytes();
}

/// One book's part of library.json: its entry as it stands in the books'
/// list, two levels in.
Uint8List encodePart(Map<String, Object?> json) => _nested(json, 2);

/// [value] encoded as it stands [depth] levels into the whole: wrapped in
/// that many lists and encoded, its own lines are indented as they are
/// there, and the wrapping is cut away again (no copy is made).
Uint8List _nested(Object? value, int depth) {
  Object? wrapped = value;
  for (var i = 0; i < depth; i++) {
    wrapped = [wrapped];
  }
  final bytes = _pretty.convert(wrapped) as Uint8List;
  // "[\n  [\n    " before it and "\n  ]\n]" after, for two levels.
  var before = 0;
  for (var i = 0; i < depth; i++) {
    before += 2 + 2 * i;
  }
  before += 2 * depth;
  var after = 0;
  for (var i = 0; i < depth; i++) {
    after += 2 + 2 * i;
  }
  return Uint8List.sublistView(bytes, before, bytes.length - after);
}

final _pretty = JsonUtf8Encoder('  ', null, 4096);
final _head = utf8.encode('{\n  "categories": ');
final _empty = utf8.encode('[]');
final _first = utf8.encode('[\n    ');
final _next = utf8.encode(',\n    ');
final _close = utf8.encode('\n  ]');
final _end = utf8.encode('\n}');
