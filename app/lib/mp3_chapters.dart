import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mp4_chapters.dart' show AudioTags, ChapterMark, maxChapterMarks;

/// Chapter marks and tags written into an MP3 file once it is made: an
/// ID3v2.3 tag at its start. The encoder (AudioExport.kt) writes neither.
///
/// Tags are text frames: the title (TIT2), author (TPE1), album (TALB) and
/// genre (TCON), and the cover (APIC). A book's chapters are the ID3v2
/// Chapter Frame Addendum's: a CHAP frame for each, its start and end in
/// milliseconds and its title (a TIT2 inside it), and one CTOC frame
/// listing them in order, which ffmpeg, VLC, foobar2000, podcast players and
/// most audiobook players read. Version 2.3 rather than 2.4: Windows and
/// many older players read only 2.3. Its text is Latin-1 where that holds
/// it, else UTF-16 with a byte order mark.
///
/// The tag goes before the audio, in the room AudioExport.kt leaves for it
/// (an empty tag as large as this one can be, see [id3Room]): written there
/// in place, the rest of the room its padding, so the audio never moves and
/// nothing is copied. A tag that does not fit goes before the audio in a
/// copy of the file.

/// Padding a tag is given beyond what it holds, so that a tag editor can
/// change it in place.
const id3Padding = 1024;

/// The largest tag the format can say the size of (28 bits).
const _maxTagBytes = (1 << 28) - 1;

/// The ID3v2.3 tag holding [tags] and [marks] (at most [maxChapterMarks];
/// more are left out), the last chapter ending at [length]: [padding] zeros
/// after its frames, or more, to make it [size] bytes in all.
Uint8List id3Tag({
  AudioTags? tags,
  List<ChapterMark> marks = const [],
  Duration length = Duration.zero,
  int padding = 0,
  int size = 0,
}) {
  final frames = BytesBuilder(copy: false);
  void add(Uint8List? frame) {
    if (frame != null) frames.add(frame);
  }

  add(_text('TIT2', tags?.title));
  add(_text('TPE1', tags?.artist));
  add(_text('TALB', tags?.album));
  add(_text('TCON', tags?.genre));
  final cover = tags?.cover;
  final mime = cover == null ? null : _pictureMime(cover);
  if (cover != null && mime != null) add(_picture(cover, mime));
  final kept = marks.take(maxChapterMarks).toList();
  if (kept.isNotEmpty) {
    final ids = [for (var i = 0; i < kept.length; i++) 'ch$i'];
    add(_contents(ids));
    for (var i = 0; i < kept.length; i++) {
      add(_chapter(ids[i], kept[i], i + 1 < kept.length ? kept[i + 1].start : length));
    }
  }
  final body = frames.takeBytes();
  final total = math.max(10 + body.length + padding, size);
  if (total - 10 > _maxTagBytes) throw const FormatException('The tags are too large for an MP3 file');
  // What is not written is padding: zeros.
  final out = Uint8List(total);
  out.setRange(0, 3, ascii.encode('ID3'));
  // Version 2.3.0, no flags.
  out[3] = 3;
  _syncSafe(out, 6, total - 10);
  out.setRange(10, 10 + body.length, body);
  return out;
}

/// The room to leave at the start of an MP3 file for the tag of [tags] and
/// chapters titled [titles], made before their times are known: that tag,
/// times being the same size whatever they are, and [id3Padding]. A save's
/// chapters are some of those it planned, so its tag fits.
int id3Room(AudioTags? tags, List<String> titles) =>
    id3Tag(tags: tags, marks: [for (final t in titles) ChapterMark(Duration.zero, t)], padding: id3Padding).length;

/// The whole size of the ID3v2 tag [head] (a file's first ten bytes, or
/// more) starts, header and footer included; 0 when it starts none.
int id3Size(List<int> head) {
  if (head.length < 10 || head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0;
  if (head[3] < 2 || head[3] > 4 || head[4] == 0xFF) return 0;
  if (head.sublist(6, 10).any((b) => b >= 0x80)) return 0;
  final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
  // A 2.4 tag may have a footer, ten bytes more.
  final footer = head[3] == 4 && (head[5] & 0x10) != 0 ? 10 : 0;
  return 10 + size + footer;
}

/// Write [tags] and [marks] (the last chapter ending at [length]) as the
/// ID3v2.3 tag at the start of the MP3 file at [path]: over the tag already
/// there, in place, when they fit in it (AudioExport.kt leaves one, see
/// [id3Room]); otherwise before the audio, in a copy that takes the file's
/// place. The tag it had is replaced; the audio is never changed.
Future<void> writeId3(
  String path, {
  AudioTags? tags,
  List<ChapterMark> marks = const [],
  required Duration length,
}) async {
  final file = File(path);
  var old = 0;
  // Read and write, at no end: append mode keeps what is there.
  final f = await file.open(mode: FileMode.append);
  try {
    await f.setPosition(0);
    old = id3Size(await f.read(10));
    if (old > await f.length()) old = 0;
    final tag = id3Tag(tags: tags, marks: marks, length: length, size: old);
    if (old > 0 && tag.length == old) {
      await f.setPosition(0);
      await f.writeFrom(tag);
      await f.flush();
      return;
    }
  } finally {
    await f.close();
  }
  // No room: the tag, then the audio, into a new file that takes its place.
  final copy = File('$path.tagged');
  final out = copy.openWrite();
  try {
    out.add(id3Tag(tags: tags, marks: marks, length: length, padding: id3Padding));
    await out.addStream(file.openRead(old));
    await out.flush();
  } finally {
    await out.close();
  }
  await copy.rename(path);
}

/// A frame: [id], the size of [data] (in 2.3 a plain 32-bit number, unlike
/// the tag's), no flags, and [data].
Uint8List _frame(String id, List<int> data) {
  final out = Uint8List(10 + data.length);
  out.setRange(0, 4, ascii.encode(id));
  ByteData.sublistView(out).setUint32(4, data.length);
  out.setRange(10, out.length, data);
  return out;
}

/// The text frame [id] holding [value]; null for no text.
Uint8List? _text(String id, String? value) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return null;
  return _frame(id, _encoded(v));
}

/// [text] as a text frame holds it: its encoding (0 Latin-1, 1 UTF-16),
/// then the text, unterminated.
List<int> _encoded(String text) {
  final units = text.codeUnits;
  if (units.every((u) => u < 0x100)) return [0, ...units];
  final out = BytesBuilder(copy: false)..add(const [1, 0xFF, 0xFE]);
  for (final u in units) {
    out
      ..addByte(u & 0xFF)
      ..addByte(u >> 8);
  }
  return out.takeBytes();
}

/// The cover: no description, of type 3 (the front cover).
Uint8List _picture(Uint8List cover, String mime) => _frame('APIC', [
      0, // the description's encoding, Latin-1
      ...ascii.encode(mime), 0,
      3,
      0, // an empty description
      ...cover,
    ]);

/// 'image/jpeg' or 'image/png' for [b], null for anything else.
String? _pictureMime(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
  return null;
}

/// The table of contents: one, at the top, its chapters [ids] in order.
Uint8List _contents(List<String> ids) => _frame('CTOC', [
      ...ascii.encode('toc'), 0,
      0x03, // top level, ordered
      ids.length,
      for (final id in ids) ...[...ascii.encode(id), 0],
    ]);

/// Chapter [id]: [mark]'s start, its [end], no byte offsets (all ones: the
/// times are what count), and its title.
Uint8List _chapter(String id, ChapterMark mark, Duration end) {
  final start = _ms(mark.start);
  final times = ByteData(16)
    ..setUint32(0, start)
    ..setUint32(4, math.max(start, _ms(end)))
    ..setUint32(8, 0xFFFFFFFF)
    ..setUint32(12, 0xFFFFFFFF);
  return _frame('CHAP', [
    ...ascii.encode(id), 0,
    ...times.buffer.asUint8List(),
    ...?_text('TIT2', mark.title),
  ]);
}

int _ms(Duration d) => d.inMilliseconds.clamp(0, 0xFFFFFFFE);

/// [value] as four bytes of seven bits each, from [at].
void _syncSafe(Uint8List out, int at, int value) {
  for (var i = 0; i < 4; i++) {
    out[at + i] = (value >> (21 - 7 * i)) & 0x7F;
  }
}
