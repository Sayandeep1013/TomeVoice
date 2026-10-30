import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Chapter marks and tags written into an MP4 file (an .m4b audiobook, an
/// .m4a chapter) once it is made: Android's MediaMuxer writes neither.
///
/// Chapters are a Nero `chpl` box in moov/udta, each chapter's start (in
/// units of 100 ns) and its title, which ffmpeg, VLC, foobar2000 and most
/// audiobook players read. Tags are iTunes items in moov/udta/meta/ilst:
/// title, author, album, genre, "audiobook" and a cover.
///
/// Only moov changes. The audio (mdat) is never moved, so the offsets in
/// moov that point into it stay right: a moov that has grown is written
/// where it was when it is the last box or has free space after it, and
/// otherwise at the end of the file, the old one marked free. Nothing is
/// read whole but moov (a few MB for a twelve-hour book).

/// Where a chapter starts in the audio, and its title.
class ChapterMark {
  const ChapterMark(this.start, this.title);

  final Duration start;
  final String title;

  @override
  String toString() => 'ChapterMark($start, $title)';
}

/// What the file says about itself.
class AudioTags {
  const AudioTags({this.title, this.artist, this.album, this.genre, this.cover, this.audiobook = false});

  final String? title;
  final String? artist;
  final String? album;
  final String? genre;

  /// A JPEG or PNG picture.
  final Uint8List? cover;

  /// Marked as an audiobook for Apple's players (media kind 2).
  final bool audiobook;
}

/// The most chapters a `chpl` box holds: its count is one byte (a 32-bit
/// count, which mp4v2 reads, is read by ffmpeg as its low byte).
const maxChapterMarks = 255;

/// The most bytes of a chapter's title: its length is one byte.
const _maxTitleBytes = 255;

/// The `chpl` box for [marks] (at most [maxChapterMarks]; more are left out).
Uint8List chplBox(List<ChapterMark> marks) {
  final b = BytesBuilder(copy: false)
    // Version 1, no flags; four reserved bytes; the count.
    ..add(const [1, 0, 0, 0, 0, 0, 0, 0]);
  final kept = marks.take(maxChapterMarks).toList();
  b.addByte(kept.length);
  for (final m in kept) {
    final start = ByteData(8)..setUint64(0, m.start.inMicroseconds * 10);
    b.add(start.buffer.asUint8List());
    final title = utf8Within(m.title, _maxTitleBytes);
    b
      ..addByte(title.length)
      ..add(title);
  }
  return mp4Box('chpl', b.takeBytes());
}

/// [text] as UTF-8 in at most [max] bytes, cut between characters.
Uint8List utf8Within(String text, int max) {
  final bytes = utf8.encode(text);
  if (bytes.length <= max) return bytes;
  var end = max;
  // A continuation byte at the cut belongs to a character it would split.
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return Uint8List.sublistView(bytes, 0, end);
}

/// The `meta` box holding [tags] as iTunes items.
Uint8List metaBox(AudioTags tags) {
  final items = BytesBuilder(copy: false);
  void text(String code, String? value) {
    if (value == null || value.trim().isEmpty) return;
    items.add(_item(code, 1, utf8.encode(value.trim())));
  }

  text('nam', tags.title);
  text('ART', tags.artist);
  text('alb', tags.album);
  text('gen', tags.genre);
  if (tags.audiobook) items.add(_item('stik', 21, const [2]));
  final cover = tags.cover;
  if (cover != null && _pictureKind(cover) != null) items.add(_item('covr', _pictureKind(cover)!, cover));
  final hdlr = mp4Box('hdlr', [
    0, 0, 0, 0, // version and flags
    0, 0, 0, 0, // pre-defined
    ...ascii.encode('mdir'),
    ...ascii.encode('appl'),
    0, 0, 0, 0, 0, 0, 0, 0, // reserved
    0, // an empty name
  ]);
  return mp4Box('meta', [0, 0, 0, 0, ...hdlr, ...mp4Box('ilst', items.takeBytes())]);
}

/// An iTunes item: [code] is the box type, the text ones written with the
/// copyright sign before it ("©nam"); [kind] is the data's well-known type
/// (1 text, 13 JPEG, 14 PNG, 21 a whole number).
Uint8List _item(String code, int kind, List<int> value) {
  final type = code.length == 3 ? [0xA9, ...ascii.encode(code)] : ascii.encode(code);
  final data = mp4Box('data', [0, 0, 0, kind, 0, 0, 0, 0, ...value]);
  return _box(type, data);
}

/// 13 for a JPEG, 14 for a PNG, null for anything else.
int? _pictureKind(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 13;
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 14;
  return null;
}

/// A box of [type] (four ASCII letters) around [payload].
Uint8List mp4Box(String type, List<int> payload) => _box(ascii.encode(type), payload);

Uint8List _box(List<int> type, List<int> payload) {
  final out = Uint8List(8 + payload.length);
  ByteData.sublistView(out).setUint32(0, out.length);
  out.setRange(4, 8, type);
  out.setRange(8, out.length, payload);
  return out;
}

/// One box: its type, where it starts, its whole size and its header's.
class Mp4Box {
  const Mp4Box(this.type, this.offset, this.size, this.header);

  final String type;
  final int offset;
  final int size;
  final int header;

  int get end => offset + size;

  @override
  String toString() => '$type@$offset+$size';
}

/// The boxes in [bytes] from [from] to [to]: a box's children, given the
/// box and its header's size.
List<Mp4Box> mp4Children(Uint8List bytes, int from, int to) {
  final d = ByteData.sublistView(bytes);
  final out = <Mp4Box>[];
  var at = from;
  while (at + 8 <= to) {
    var size = d.getUint32(at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > to) throw const FormatException('A box is cut short');
      size = d.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header || at + size > to) throw const FormatException('A box runs past the one it is in');
    out.add(Mp4Box(latin1.decode(bytes.sublist(at + 4, at + 8)), at, size, header));
    at += size;
  }
  return out;
}

/// The boxes at the top of the file [f], read one header at a time.
Future<List<Mp4Box>> mp4TopBoxes(RandomAccessFile f) async {
  final length = await f.length();
  final out = <Mp4Box>[];
  var at = 0;
  while (at + 8 <= length) {
    await f.setPosition(at);
    final h = await f.read(16);
    final d = ByteData.sublistView(h);
    var size = d.getUint32(0);
    var header = 8;
    if (size == 1) {
      if (h.length < 16) throw const FormatException('The file ends inside a box');
      size = d.getUint64(8);
      header = 16;
    } else if (size == 0) {
      size = length - at;
    }
    if (size < header || at + size > length) throw const FormatException('The file ends inside a box');
    out.add(Mp4Box(latin1.decode(h.sublist(4, 8)), at, size, header));
    at += size;
  }
  return out;
}

/// [moov] (a whole moov box) with [boxes] in its udta, replacing any of
/// the same types there; the rest of moov and of udta is kept as it was.
/// udta is added at the end of moov when it has none.
Uint8List moovWithUserData(Uint8List moov, List<Uint8List> boxes) {
  final head = mp4Children(moov, 0, moov.length).single;
  if (head.type != 'moov') throw const FormatException('Not a moov box');
  final types = {for (final b in boxes) latin1.decode(b.sublist(4, 8))};
  Uint8List udtaFrom(Mp4Box? old) {
    final kept = BytesBuilder(copy: false);
    if (old != null) {
      for (final c in mp4Children(moov, old.offset + old.header, old.end)) {
        if (!types.contains(c.type)) kept.add(Uint8List.sublistView(moov, c.offset, c.end));
      }
    }
    for (final b in boxes) {
      kept.add(b);
    }
    return mp4Box('udta', kept.takeBytes());
  }

  final out = BytesBuilder(copy: false);
  var placed = false;
  for (final c in mp4Children(moov, head.header, moov.length)) {
    if (c.type == 'udta' && !placed) {
      out.add(udtaFrom(c));
      placed = true;
    } else {
      out.add(Uint8List.sublistView(moov, c.offset, c.end));
    }
  }
  if (!placed) out.add(udtaFrom(null));
  return mp4Box('moov', out.takeBytes());
}

/// Write [marks] (as `chpl`) and [tags] (as `meta`) into the MP4 file at
/// [path], in place. With no marks and no tags it changes nothing.
Future<void> writeChaptersAndTags(String path, {List<ChapterMark> marks = const [], AudioTags? tags}) async {
  final boxes = [
    if (marks.isNotEmpty) chplBox(marks),
    if (tags != null) metaBox(tags),
  ];
  if (boxes.isEmpty) return;
  // Read and write, at no end: append mode keeps what is there.
  final f = await File(path).open(mode: FileMode.append);
  try {
    final top = await mp4TopBoxes(f);
    final at = top.indexWhere((b) => b.type == 'moov');
    if (at < 0) throw const FormatException('The file has no moov box');
    final moov = top[at];
    await f.setPosition(moov.offset);
    final fresh = moovWithUserData(await f.read(moov.size), boxes);
    final after = top.sublist(at + 1);
    final room = after.isEmpty ? 0 : moov.size + (after.first.type == 'free' ? after.first.size : 0) - fresh.length;
    if (after.every((b) => b.type == 'free' || b.type == 'skip')) {
      // The last box (free space aside): written where it is.
      await f.setPosition(moov.offset);
      await f.writeFrom(fresh);
      await f.truncate(moov.offset + fresh.length);
    } else if (after.first.type == 'free' && (room == 0 || room >= 8)) {
      // Into the free space after it, what is left of that still free.
      await f.setPosition(moov.offset);
      await f.writeFrom(fresh);
      // (Its header only: what it holds is never read.)
      if (room > 0) await f.writeFrom([..._u32(room), ...ascii.encode('free')]);
    } else {
      // No room where it is: the old one becomes free space, the new one
      // goes at the end.
      final end = await f.length();
      await f.setPosition(moov.offset + 4);
      await f.writeFrom(ascii.encode('free'));
      await f.setPosition(end);
      await f.writeFrom(fresh);
    }
    await f.flush();
  } finally {
    await f.close();
  }
}

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
