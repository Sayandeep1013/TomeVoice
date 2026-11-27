import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

import 'library_store.dart';
import 'marks.dart';

/// Highlights and notes brought from another reading app (Kindle's
/// My Clippings.txt, KOReader's notes beside each book), kept as quotes in
/// the book they were made in, at the sentence they were made at.
///
/// A highlight carries only its words and its book's title (and author), so
/// each is put in the library's book of that title, at the place in its
/// text where those words are. One whose book is not in the library, or
/// whose words its text does not have (another edition), is counted and
/// left out; nothing is guessed.

/// One highlight (or a note on its own) as another app kept it.
class ForeignHighlight {
  const ForeignHighlight({
    required this.title,
    required this.text,
    this.author = '',
    this.note,
    this.added,
    this.location = '',
  });

  final String title;
  final String author;

  /// The words highlighted; empty for a note made without one.
  final String text;
  final String? note;
  final DateTime? added;

  /// Where the app placed it ("Location 170-172", a page): to tie a note to
  /// its highlight.
  final String location;

  ForeignHighlight withNote(String? note) => ForeignHighlight(
      title: title, author: author, text: text, note: note, added: added, location: location);
}

// ---------------------------------------------------------------------------
// Kindle: My Clippings.txt

/// The entries of a Kindle's `documents/My Clippings.txt`: a title line
/// ("The Hobbit (J. R. R. Tolkien)"), a line saying what it is and where
/// ("- Your Highlight on page 12 | Location 170-172 | Added on …", in the
/// Kindle's language), a blank line, the words, and a line of ten "=".
///
/// Notes are joined to the highlight they were made on (the Kindle keeps
/// them apart, at the highlight's last location); bookmarks are left out,
/// and a highlight kept twice (made again, longer) only once, its longest.
List<ForeignHighlight> parseKindleClippings(String raw) {
  final text = raw.replaceFirst(String.fromCharCode(0xFEFF), '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final highlights = <ForeignHighlight>[];
  final notes = <({String title, String location, String text})>[];
  for (final block in text.split(RegExp(r'^==========\s*$', multiLine: true))) {
    final lines = block.split('\n').map((l) => l.trim()).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    if (lines.length < 2) continue;
    final head = lines[0];
    final info = lines[1];
    if (!info.startsWith('-')) continue;
    final body = lines.skip(2).join('\n').trim();
    final (title, author) = _titleAndAuthor(head);
    final kind = _clippingKind(info);
    final location = _location(info);
    if (kind == _Clip.bookmark || title.isEmpty) continue;
    if (kind == _Clip.note) {
      if (body.isNotEmpty) notes.add((title: title, location: location, text: body));
      continue;
    }
    if (body.isEmpty) continue;
    highlights.add(ForeignHighlight(title: title, author: author, text: body, location: location, added: _added(info)));
  }
  // A highlight made again over the same place: the longest.
  final kept = <ForeignHighlight>[];
  for (final h in highlights) {
    final i = kept.indexWhere((k) => k.title == h.title && (k.text.contains(h.text) || h.text.contains(k.text)));
    if (i < 0) {
      kept.add(h);
    } else if (h.text.length > kept[i].text.length) {
      kept[i] = h;
    }
  }
  // A note is kept at its highlight's last location ("Location 172").
  for (final n in notes) {
    final i = kept.indexWhere((k) => k.title == n.title && _endOf(k.location) == _endOf(n.location) && _endOf(n.location).isNotEmpty);
    if (i >= 0) {
      kept[i] = kept[i].withNote([if (kept[i].note != null) kept[i].note!, n.text].join('\n'));
    } else {
      kept.add(ForeignHighlight(title: n.title, text: '', note: n.text, location: n.location));
    }
  }
  return kept;
}

enum _Clip { highlight, note, bookmark }

/// What the info line says the entry is. The Kindle writes it in its own
/// language: the common words for a note and a bookmark in each, a
/// highlight otherwise.
_Clip _clippingKind(String info) {
  final first = info.split('|').first.toLowerCase();
  const note = ['note', 'notiz', 'nota', 'remarque', 'notitie', 'заметка', 'メモ', '笔记', '筆記', 'anteckning'];
  const bookmark = ['bookmark', 'lesezeichen', 'marcador', 'signet', 'segnalibro', 'bladwijzer', 'закладка', 'ブックマーク', '书签', '書籤', 'bokmärke', 'marque-page'];
  if (bookmark.any(first.contains)) return _Clip.bookmark;
  if (note.any(first.contains)) return _Clip.note;
  return _Clip.highlight;
}

/// Where the entry is: the last field before the date with numbers in it
/// ("Location 170-172" after "page 12", or "page 12" alone).
String _location(String info) {
  final parts = info.split('|');
  final before = parts.length > 1 ? parts.sublist(0, parts.length - 1) : parts;
  for (final p in before.reversed) {
    final m = RegExp(r'\d+(?:\s*-\s*\d+)?').firstMatch(p);
    if (m != null) return m.group(0)!.replaceAll(' ', '');
  }
  return '';
}

/// The last location of [location] ("170-172": "172").
String _endOf(String location) => location.split('-').last;

DateTime? _added(String info) {
  final last = info.split('|').last;
  final m = RegExp(r'(\d{1,2}) (\w+) (\d{4})|(\w+) (\d{1,2}), (\d{4})').firstMatch(last);
  if (m == null) return null;
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final day = int.tryParse(m.group(1) ?? m.group(5) ?? '');
  final month = months.indexOf((m.group(2) ?? m.group(4) ?? '').toLowerCase().padRight(3).substring(0, 3)) + 1;
  final year = int.tryParse(m.group(3) ?? m.group(6) ?? '');
  if (day == null || year == null || month == 0) return null;
  return DateTime(year, month, day);
}

/// "The Hobbit (J. R. R. Tolkien)": the title, and the author in the last
/// brackets ("Tolkien, J. R. R." turned round).
(String, String) _titleAndAuthor(String head) {
  final m = RegExp(r'^(.*)\(([^()]*)\)\s*$').firstMatch(head);
  if (m == null) return (head.trim(), '');
  var author = m.group(2)!.trim();
  final comma = RegExp(r'^([^,;]+),\s*([^,;]+)$').firstMatch(author);
  if (comma != null) author = '${comma.group(2)} ${comma.group(1)}';
  return (m.group(1)!.trim(), author);
}

// ---------------------------------------------------------------------------
// KOReader: book.sdr/metadata.<ext>.lua

/// The highlights and notes in a KOReader sidecar (`metadata.epub.lua`
/// beside the book, in its `.sdr` folder): its `annotations` (each with
/// `text`, `note`, `chapter`, `datetime`; one without `pos0` is a bookmark,
/// left out), or the older `highlight` and `bookmarks` lists, with the
/// book's title and authors from `doc_props`. [fileName] names the book
/// when the sidecar does not.
List<ForeignHighlight> parseKoreaderSidecar(String lua, {String fileName = ''}) {
  final table = LuaTable.parse(lua);
  if (table is! Map) return const [];
  final props = table['doc_props'] is Map ? table['doc_props'] as Map : const {};
  var title = '${props['title'] ?? ''}'.trim();
  final author = '${props['authors'] ?? ''}'.split('\n').first.trim();
  if (title.isEmpty) title = _titleFromSidecar(fileName);
  final out = <ForeignHighlight>[];
  void add(Map a) {
    final text = '${a['text'] ?? ''}'.trim();
    final note = '${a['note'] ?? ''}'.trim();
    if (text.isEmpty && note.isEmpty) return;
    out.add(ForeignHighlight(
      title: title,
      author: author,
      text: text,
      note: note.isEmpty ? null : note,
      added: DateTime.tryParse('${a['datetime'] ?? ''}'.replaceFirst(' ', 'T')),
      location: '${a['pageno'] ?? a['page'] ?? ''}',
    ));
  }

  final annotations = table['annotations'];
  if (annotations is Map || annotations is List) {
    for (final a in _items(annotations)) {
      // A bookmark: a place, no words.
      if (a['pos0'] == null && a['drawer'] == null) continue;
      add(a);
    }
    return out;
  }
  // Before 2024: highlights by page, and bookmarks carrying the notes.
  final notes = <String, String>{};
  for (final b in _items(table['bookmarks'])) {
    final n = '${b['text'] ?? ''}';
    final said = '${b['notes'] ?? ''}'.trim();
    if (b['highlighted'] == true && n.trim().isNotEmpty && n.trim() != said) notes[said] = n.trim();
  }
  final pages = table['highlight'];
  for (final page in _items(pages)) {
    for (final h in _items(page)) {
      final text = '${h['text'] ?? ''}'.trim();
      add({...h, 'note': notes[text]});
    }
  }
  return out;
}

Iterable<Map> _items(Object? t) sync* {
  if (t is List) {
    for (final v in t) {
      if (v is Map) yield v;
    }
  } else if (t is Map) {
    final keys = t.keys.toList()..sort((a, b) => a is num && b is num ? a.compareTo(b) : '$a'.compareTo('$b'));
    for (final k in keys) {
      if (t[k] is Map) yield t[k] as Map;
    }
  }
}

/// "metadata.epub.lua" in "Dune.sdr": "Dune".
String _titleFromSidecar(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  for (final p in parts.reversed) {
    if (p.endsWith('.sdr')) return p.substring(0, p.length - 4);
  }
  return '';
}

/// The Lua a KOReader sidecar is: `return { ... }`, a table of strings,
/// numbers, booleans and tables, keyed by `["name"]`, `[1]` or a bare name.
/// Read into Maps, Lists (a table of 1..n only), Strings, nums and bools.
class LuaTable {
  LuaTable._(this._s);

  final String _s;
  int _i = 0;

  static Object? parse(String source) {
    final p = LuaTable._(source);
    p._space();
    if (p._s.startsWith('return', p._i)) p._i += 6;
    p._space();
    try {
      return p._value();
    } on FormatException {
      return null;
    }
  }

  void _space() {
    while (_i < _s.length) {
      final c = _s[_i];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        _i++;
      } else if (_s.startsWith('--', _i)) {
        final end = _s.indexOf('\n', _i);
        _i = end < 0 ? _s.length : end;
      } else {
        break;
      }
    }
  }

  Object? _value() {
    _space();
    if (_i >= _s.length) throw const FormatException('end');
    final c = _s[_i];
    if (c == '{') return _table();
    if (c == '"' || c == "'") return _string();
    if (_s.startsWith('[[', _i) || _s.startsWith('[=', _i)) return _longString();
    if (_s.startsWith('true', _i)) {
      _i += 4;
      return true;
    }
    if (_s.startsWith('false', _i)) {
      _i += 5;
      return false;
    }
    if (_s.startsWith('nil', _i)) {
      _i += 3;
      return null;
    }
    final m = RegExp(r'-?(0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?)').matchAsPrefix(_s, _i);
    if (m == null) throw FormatException('value at $_i');
    _i = m.end;
    final n = m.group(0)!;
    if (n.contains('0x')) {
      final v = int.parse(n.replaceFirst('-', '').substring(2), radix: 16);
      return n.startsWith('-') ? -v : v;
    }
    return num.parse(n);
  }

  Object _table() {
    _i++; // {
    final map = <Object, Object?>{};
    var next = 1;
    while (true) {
      _space();
      if (_i >= _s.length) throw const FormatException('table');
      if (_s[_i] == '}') {
        _i++;
        break;
      }
      Object key;
      if (_s[_i] == '[' && !_s.startsWith('[[', _i) && !_s.startsWith('[=', _i)) {
        _i++;
        key = _value() ?? 'nil';
        _space();
        if (_i >= _s.length || _s[_i] != ']') throw FormatException('] at $_i');
        _i++;
        _space();
        if (_i >= _s.length || _s[_i] != '=') throw FormatException('= at $_i');
        _i++;
      } else {
        final name = RegExp(r'[A-Za-z_][A-Za-z0-9_]*\s*=(?!=)').matchAsPrefix(_s, _i);
        if (name != null) {
          key = name.group(0)!.split('=').first.trim();
          _i = name.end;
        } else {
          key = next++;
        }
      }
      map[key is double && key == key.roundToDouble() ? key.toInt() : key] = _value();
      _space();
      if (_i < _s.length && (_s[_i] == ',' || _s[_i] == ';')) _i++;
    }
    // 1..n and nothing else: a list.
    final n = map.length;
    if (n > 0 && List.generate(n, (i) => i + 1).every(map.containsKey)) {
      return [for (var i = 1; i <= n; i++) map[i]];
    }
    return map;
  }

  String _string() {
    final quote = _s[_i++];
    final b = StringBuffer();
    while (_i < _s.length) {
      final c = _s[_i++];
      if (c == quote) return b.toString();
      if (c != r'\') {
        b.write(c);
        continue;
      }
      if (_i >= _s.length) break;
      final e = _s[_i++];
      switch (e) {
        case 'n':
          b.write('\n');
        case 't':
          b.write('\t');
        case 'r':
          b.write('\r');
        case '\n':
          b.write('\n');
        case 'a' || 'b' || 'f' || 'v':
          break;
        default:
          final digits = RegExp(r'\d{1,3}').matchAsPrefix(_s, _i - 1);
          if (digits != null) {
            // \ddd: a byte; KOReader writes UTF-8 as itself, so these are
            // only control characters.
            b.writeCharCode(int.parse(digits.group(0)!));
            _i = digits.end;
          } else {
            b.write(e);
          }
      }
    }
    throw const FormatException('string');
  }

  String _longString() {
    final open = RegExp(r'\[(=*)\[').matchAsPrefix(_s, _i)!;
    final close = ']${open.group(1)}]';
    final end = _s.indexOf(close, open.end);
    if (end < 0) throw const FormatException('long string');
    var text = _s.substring(open.end, end);
    if (text.startsWith('\n')) text = text.substring(1);
    _i = end + close.length;
    return text;
  }
}

// ---------------------------------------------------------------------------
// Kobo: .kobo/KoboReader.sqlite on the e-reader
//
// The query follows calibre's Kobo driver and export-kobo: Bookmark rows
// (a highlight has Text; a note has an Annotation too; a dog-ear has
// neither) joined to their book's row in content by VolumeID, which gives
// its Title and Attribution (author). A sideloaded book's VolumeID is its
// file ("file:///mnt/onboard/.../Dune.epub"), named after it when its
// row has no title. Columns differ between firmwares (Hidden, Type), so
// those are asked about first.

/// The highlights and notes in a Kobo's database, read only.
List<ForeignHighlight> readKoboDatabase(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final cols = {for (final r in db.select('PRAGMA table_info(Bookmark)')) '${r['name']}'};
    if (!cols.contains('VolumeID') || !cols.contains('Text')) return const [];
    final hidden = cols.contains('Hidden') ? "AND (b.Hidden IS NULL OR b.Hidden IN ('false', 0))" : '';
    final dogears = cols.contains('Type') ? "AND (b.Type IS NULL OR b.Type != 'dogear')" : '';
    final note = cols.contains('Annotation') ? 'b.Annotation' : 'NULL';
    final created = cols.contains('DateCreated') ? 'b.DateCreated' : 'NULL';
    final order = cols.contains('ChapterProgress') ? 'b.VolumeID, b.ContentID, b.ChapterProgress' : 'b.VolumeID';
    final rows = db.select(
      'SELECT b.VolumeID AS volume, b.Text AS text, $note AS note, $created AS created, '
      'book.Title AS title, book.Attribution AS author '
      'FROM Bookmark b LEFT JOIN content book ON book.ContentID = b.VolumeID '
      "WHERE ((b.Text IS NOT NULL AND b.Text != '') OR ($note IS NOT NULL AND $note != '')) $hidden $dogears "
      'ORDER BY $order',
    );
    String? text(Object? v) {
      final s = v is String ? v.trim() : '';
      return s.isEmpty ? null : s;
    }

    return [
      for (final r in rows)
        ForeignHighlight(
          title: text(r['title']) ?? _koboFileTitle('${r['volume']}'),
          author: (text(r['author']) ?? '').split(',').first.trim(),
          text: text(r['text']) ?? '',
          note: text(r['note']),
          added: DateTime.tryParse('${r['created'] ?? ''}'),
        ),
    ];
  } finally {
    db.dispose();
  }
}

/// "file:///mnt/onboard/Herbert/Dune - Frank Herbert.epub": "Dune".
String _koboFileTitle(String volume) {
  final name = Uri.decodeComponent(volume.split('/').last);
  final dot = name.lastIndexOf('.');
  final bare = dot > 0 ? name.substring(0, dot) : name;
  return bare.split(' - ').first.trim();
}

// ---------------------------------------------------------------------------
// Libby: Reading Journey, Export Reading Data, Data (JSON)
//
// {"readingJourney": {"title": {"text": ...}, "author": ...},
//  "highlights": [{"quote", "note"?, "chapter", "percent", "timestamp"}]}
// as Libby writes it. Its title may be a plain string; a highlight may be a
// note alone.

List<ForeignHighlight> parseLibbyJourney(String raw) {
  final Object? j;
  try {
    j = jsonDecode(raw.replaceFirst(String.fromCharCode(0xFEFF), ''));
  } on FormatException {
    return const [];
  }
  if (j is! Map) return const [];
  final journey = j['readingJourney'] is Map ? j['readingJourney'] as Map : const {};
  final t = journey['title'];
  final title = (t is Map ? '${t['text'] ?? ''}' : '${t ?? ''}').trim();
  final author = '${journey['author'] ?? ''}'.trim();
  final list = j['highlights'];
  if (list is! List || title.isEmpty) return const [];
  return [
    for (final h in list)
      if (h is Map && ('${h['quote'] ?? ''}'.trim().isNotEmpty || '${h['note'] ?? ''}'.trim().isNotEmpty))
        ForeignHighlight(
          title: title,
          author: author,
          text: '${h['quote'] ?? ''}'.trim(),
          note: '${h['note'] ?? ''}'.trim().isEmpty ? null : '${h['note']}'.trim(),
          added: h['timestamp'] is num ? DateTime.fromMillisecondsSinceEpoch((h['timestamp'] as num).toInt()) : null,
        ),
  ];
}

// ---------------------------------------------------------------------------
// Google Play Books: the book's Doc in Drive's "Play Books Notes" folder,
// downloaded (File, Download) as Word (.docx) or Markdown (.md).
//
// The Doc: a table at its head, the cover and then the title in italics
// with the author and publisher; then every highlight twice (by colour,
// then by chapter), each in a table cell of its own: the words highlighted
// in italics, the note, the date ("April 27, 2021") and the page as a link.
// Its headings are in the reader's language, so nothing goes by them: the
// cells are read, the first with italics and no date is the title, and a
// highlight met twice is kept once.

/// A table cell of the Doc: its runs of text, each italic or not.
typedef _Cell = List<({String text, bool italic})>;

List<ForeignHighlight> parsePlayBooksNotes(List<int> bytes, {String fileName = ''}) {
  final zipped = bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
  final cells = zipped ? _docxCells(bytes) : _markdownCells(utf8.decode(bytes, allowMalformed: true));
  return _playBooksFrom(cells, fileName: fileName);
}

/// A date as the Doc writes one, in English or another language's order.
final _docDate = RegExp(r'(\p{L}+\.? \d{1,2}, \d{4}|\d{1,2}\.? \p{L}+\.? \d{4}|\d{4}[-/.]\d{1,2}[-/.]\d{1,2})', unicode: true);

List<ForeignHighlight> _playBooksFrom(List<_Cell> cells, {required String fileName}) {
  String join(Iterable<String> parts) => parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  var title = '', author = '';
  final found = <({String text, String? note})>[];
  final seen = <String>{};
  for (final cell in cells) {
    final italic = join(cell.where((r) => r.italic).map((r) => r.text));
    final plain = join(cell.where((r) => !r.italic).map((r) => r.text));
    final date = _docDate.allMatches(plain).lastOrNull;
    if (date == null) {
      // The head: the title in italics, then its author.
      if (title.isEmpty && italic.isNotEmpty) {
        title = italic;
        author = plain.split(' ').take(2).join(' ');
      }
      continue;
    }
    // A bookmark: a place, no words.
    if (italic.isEmpty) continue;
    // The note is what is left before the date; the page comes after it.
    final note = plain.substring(0, date.start).trim();
    if (!seen.add(normaliseForMatch(italic))) continue;
    found.add((text: italic, note: note.isEmpty ? null : note));
  }
  // Without a title cell, the file's name ("Notes from Dune").
  if (title.isEmpty) {
    title = fileName
        .replaceAll(RegExp(r'\.(docx|md)$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^Notes from ', caseSensitive: false), '')
        .trim();
  }
  return [for (final h in found) ForeignHighlight(title: title, author: author, text: h.text, note: h.note)];
}

/// The cells of a .docx's tables, each run marked italic or not (w:i in its
/// run's properties), a hyperlink's runs included.
List<_Cell> _docxCells(List<int> bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } on Object {
    return const [];
  }
  final doc = zip.findFile('word/document.xml');
  if (doc == null) return const [];
  final xml = utf8.decode(doc.content, allowMalformed: true);
  final cells = <_Cell>[];
  for (final tc in RegExp(r'<w:tc>([\s\S]*?)</w:tc>').allMatches(xml)) {
    final runs = <({String text, bool italic})>[];
    for (final p in RegExp(r'<w:p[ >][\s\S]*?</w:p>').allMatches(tc.group(1)!)) {
      for (final r in RegExp(r'<w:r[ >]([\s\S]*?)</w:r>').allMatches(p.group(0)!)) {
        final body = r.group(1)!;
        final italic = RegExp(r'<w:i(?: w:val="(?:true|1|on)")?\s*/>').hasMatch(body);
        final text = [for (final t in RegExp(r'<w:t(?: [^>]*)?>([\s\S]*?)</w:t>').allMatches(body)) _unxml(t.group(1)!)].join();
        if (text.isNotEmpty) runs.add((text: text, italic: italic));
      }
      runs.add((text: ' ', italic: false));
    }
    cells.add(runs);
  }
  return cells;
}

String _unxml(String s) =>
    s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');

/// The cells of a Markdown download's tables ("| ... |" rows), the
/// *italic* parts marked; pictures, links' addresses and escapes left out.
List<_Cell> _markdownCells(String md) {
  final cells = <_Cell>[];
  for (final line in md.split('\n')) {
    final l = line.trim();
    if (!l.startsWith('|') || RegExp(r'^\|[\s:|-]+\|?$').hasMatch(l)) continue;
    final inner = l.substring(1, l.endsWith('|') && l.length > 1 ? l.length - 1 : l.length);
    for (var cell in inner.split(RegExp(r'(?<!\\)\|'))) {
      cell = cell
          .replaceAll(RegExp(r'!\[[^\]]*\]\[[^\]]*\]|!\[[^\]]*\]\([^)]*\)'), '')
          .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
          .replaceAllMapped(RegExp(r'\\([\\`*_{}\[\]()#+\-.!$|~])'), (m) => m.group(1)!);
      if (cell.trim().isEmpty) continue;
      final runs = <({String text, bool italic})>[];
      var at = 0;
      for (final m in RegExp(r'\*([^*]+)\*').allMatches(cell)) {
        if (m.start > at) runs.add((text: cell.substring(at, m.start), italic: false));
        runs.add((text: m.group(1)!, italic: true));
        at = m.end;
      }
      if (at < cell.length) runs.add((text: cell.substring(at), italic: false));
      cells.add(runs);
    }
  }
  return cells;
}

// ---------------------------------------------------------------------------
// Putting them in the library

/// What an import of highlights did.
class HighlightReport {
  const HighlightReport({
    required this.added,
    required this.already,
    required this.notFound,
    required this.missingBooks,
    required this.books,
  });

  /// Quotes added.
  final int added;

  /// Already kept here (imported before, or saved by hand).
  final int already;

  /// In a book here, but its words are not in this edition's text.
  final int notFound;

  /// Titles of the books not in the library.
  final List<String> missingBooks;

  /// Books that got quotes.
  final int books;

  String get summary {
    final parts = <String>[
      if (added > 0) 'Added ${_n(added, 'quote')} to ${_n(books, 'book')}.' else 'No new quotes.',
      if (already > 0) '$already already here.',
      if (notFound > 0) "${_n(notFound, 'quote')} not found in the book's text (another edition?).",
      if (missingBooks.isNotEmpty)
        '${_n(missingBooks.length, 'book')} not in your library: ${missingBooks.take(3).join(', ')}'
            '${missingBooks.length > 3 ? '…' : ''}. Add ${missingBooks.length == 1 ? 'it' : 'them'} and import again.',
    ];
    return parts.join(' ');
  }

  static String _n(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';
}

/// Words as compared: lower case, letters and digits only, one space
/// between (curly and straight quotes, dashes and line breaks alike).
String normaliseForMatch(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

/// The library book [title] by [author] is, or null: the same title once
/// both are made plain (a subtitle after a colon aside), the author's
/// surname in its authors when both say one.
LibraryEntry? matchBook(List<LibraryEntry> entries, String title, String author) {
  String plain(String t) => normaliseForMatch(t.split(RegExp(r'[:(\[]')).first);
  final want = plain(title);
  if (want.isEmpty) return null;
  final surname = normaliseForMatch(author).split(' ').where((w) => w.length > 1).lastOrNull;
  bool byAuthor(LibraryEntry e) =>
      surname == null || e.authors.isEmpty || normaliseForMatch(e.authors.join(' ')).contains(surname);
  final same = entries.where((e) => plain(e.title) == want).toList();
  final firm = same.where(byAuthor).firstOrNull ?? (same.length == 1 ? same.first : null);
  if (firm != null) return firm;
  // "The Hobbit, or There and Back Again" and "The Hobbit".
  if (want.length < 6) return null;
  return entries.where((e) {
    final t = plain(e.title);
    return t.length >= 6 && (t.startsWith(want) || want.startsWith(t)) && byAuthor(e);
  }).firstOrNull;
}

/// Where [text] is in [units]: the first sentence it starts in, and how many
/// it runs over; null when its words are not there. Its first words are
/// looked for (a highlight may run past what this edition has), the first
/// 80 letters, then the first 30.
({int unit, int span})? placeIn(List<Speakable> units, String text) {
  final want = normaliseForMatch(text);
  if (want.isEmpty) return null;
  final starts = <int>[];
  final all = StringBuffer();
  for (final u in units) {
    starts.add(all.length);
    all
      ..write(normaliseForMatch(u.text))
      ..write(' ');
  }
  final hay = all.toString();
  int unitAt(int offset) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  for (final take in [want.length, 80, 30]) {
    if (take > want.length || take < 12 && take != want.length) continue;
    final at = hay.indexOf(want.substring(0, take));
    if (at < 0) continue;
    final first = unitAt(at);
    final last = unitAt((at + want.length - 1).clamp(0, hay.length - 1));
    return (unit: first, span: (last - first + 1).clamp(1, 50));
  }
  return null;
}

/// Put [highlights] into the library's books as quotes. [onProgress] is
/// told each book as it is opened.
Future<HighlightReport> importHighlights(
  LibraryStore store,
  List<ForeignHighlight> highlights, {
  void Function(String title, int done, int total)? onProgress,
}) async {
  final entries = (await store.index(all: true)).entries;
  final byBook = <String, List<ForeignHighlight>>{};
  final missing = <String>{};
  final entryOf = <String, LibraryEntry>{};
  for (final h in highlights) {
    final e = matchBook(entries, h.title, h.author);
    if (e == null) {
      missing.add(h.title);
      continue;
    }
    entryOf[e.id] = e;
    byBook.putIfAbsent(e.id, () => []).add(h);
  }
  var added = 0, already = 0, notFound = 0, books = 0, done = 0;
  for (final MapEntry(key: id, value: list) in byBook.entries) {
    final entry = entryOf[id]!;
    onProgress?.call(entry.title, done++, byBook.length);
    final ReadingLayout layout;
    try {
      layout = await store.loadLayout(id);
    } on Object {
      notFound += list.length;
      continue;
    }
    final kept = {
      for (final m in MarkStore.instance.forBook(id))
        if (m.kind == MarkKind.quote) normaliseForMatch(m.text),
    };
    var got = 0;
    for (final h in list) {
      final words = h.text.isEmpty ? '' : h.text;
      if (words.isEmpty) {
        // A note made without a highlight: nothing to place it by.
        notFound++;
        continue;
      }
      final place = placeIn(layout.units, words);
      if (place == null) {
        notFound++;
        continue;
      }
      final said = [for (var u = place.unit; u < place.unit + place.span && u < layout.units.length; u++) layout.units[u].text]
          .join(' ');
      final key = normaliseForMatch(said);
      if (kept.contains(key) || kept.contains(normaliseForMatch(words))) {
        already++;
        continue;
      }
      await MarkStore.instance.add(
        bookId: id,
        bookTitle: entry.title,
        kind: MarkKind.quote,
        at: cursorOf(layout.units[place.unit]),
        span: place.span,
        text: said,
        chapter: layout.chapterTitle(layout.chapterOfUnit(place.unit)),
        note: h.note,
      );
      kept.add(key);
      got++;
    }
    added += got;
    if (got > 0) books++;
  }
  return HighlightReport(
    added: added,
    already: already,
    notFound: notFound,
    missingBooks: missing.toList()..sort(),
    books: books,
  );
}
