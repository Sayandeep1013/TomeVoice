import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// One file in a zip (a book's EPUB), as the zip's directory at its end
/// lists it: enough to read it from where it lies, without unpacking the
/// rest. Plain values, so it crosses to another isolate.
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.headerOffset,
  });

  /// Its path in the zip, folders apart by "/".
  final String name;

  /// 0: stored as it is; 8: deflated.
  final int method;
  final int compressedSize;
  final int size;

  /// Where its local header starts; its bytes come after that header.
  final int headerOffset;

  bool get stored => method == 0;
}

/// The files of the zip at [path] by name, from its central directory alone
/// (zip64's too): an EPUB of hundreds of megabytes of audio is not read for
/// it. Throws a [FormatException] for a file that is not a zip.
Map<String, ZipEntry> zipEntries(String path) {
  final f = File(path).openSync();
  try {
    return _entries(f);
  } finally {
    f.closeSync();
  }
}

Map<String, ZipEntry> _entries(RandomAccessFile f) {
  final length = f.lengthSync();
  // The end record is the last 22 bytes, unless a comment of up to 64 KB follows it.
  final tail = math.min(length, 22 + 0xFFFF);
  final end = _read(f, length - tail, tail);
  var at = -1;
  for (var i = end.length - 22; i >= 0; i--) {
    if (_u32(end, i) == 0x06054b50) {
      at = i;
      break;
    }
  }
  if (at < 0) throw const FormatException('Not a zip: it has no directory');
  var count = _u16(end, at + 10);
  var dirSize = _u32(end, at + 12);
  var dirOffset = _u32(end, at + 16);
  if (count == 0xFFFF || dirSize == 0xFFFFFFFF || dirOffset == 0xFFFFFFFF) {
    // Zip64: a locator just before the end record says where its own end record is.
    final locator = at - 20;
    if (locator >= 0 && _u32(end, locator) == 0x07064b50) {
      final record = _read(f, _u64(end, locator + 8), 56);
      if (_u32(record, 0) == 0x06064b50) {
        count = _u64(record, 32);
        dirSize = _u64(record, 40);
        dirOffset = _u64(record, 48);
      }
    }
  }
  if (dirOffset < 0 || dirOffset + dirSize > length) throw const FormatException('Not a zip: its directory is cut short');
  final dir = _read(f, dirOffset, dirSize);
  final out = <String, ZipEntry>{};
  var p = 0;
  for (var k = 0; k < count && p + 46 <= dir.length; k++) {
    if (_u32(dir, p) != 0x02014b50) break;
    final method = _u16(dir, p + 10);
    var compressed = _u32(dir, p + 20);
    var size = _u32(dir, p + 24);
    final nameLength = _u16(dir, p + 28);
    final extraLength = _u16(dir, p + 30);
    final commentLength = _u16(dir, p + 32);
    var offset = _u32(dir, p + 42);
    if (p + 46 + nameLength + extraLength > dir.length) break;
    final name = utf8.decode(Uint8List.sublistView(dir, p + 46, p + 46 + nameLength), allowMalformed: true);
    // Zip64's sizes and offset, for those marked as too large for the directory.
    var e = p + 46 + nameLength;
    final extraEnd = e + extraLength;
    while (e + 4 <= extraEnd) {
      final id = _u16(dir, e);
      final n = _u16(dir, e + 2);
      if (id == 0x0001) {
        var q = e + 4;
        if (size == 0xFFFFFFFF && q + 8 <= e + 4 + n) {
          size = _u64(dir, q);
          q += 8;
        }
        if (compressed == 0xFFFFFFFF && q + 8 <= e + 4 + n) {
          compressed = _u64(dir, q);
          q += 8;
        }
        if (offset == 0xFFFFFFFF && q + 8 <= e + 4 + n) offset = _u64(dir, q);
      }
      e += 4 + n;
    }
    final normalised = name.replaceAll('\\', '/');
    out[normalised] = ZipEntry(
      name: normalised,
      method: method,
      compressedSize: compressed,
      size: size,
      headerOffset: offset,
    );
    p += 46 + nameLength + extraLength + commentLength;
  }
  return out;
}

/// Where [entry]'s own bytes begin in the open zip [f]: after its local
/// header, whose name and extra field can differ in length from the
/// directory's.
int zipDataOffset(RandomAccessFile f, ZipEntry entry) {
  final header = _read(f, entry.headerOffset, 30);
  if (header.length < 30 || _u32(header, 0) != 0x04034b50) {
    throw FormatException('${entry.name} is damaged in the book');
  }
  return entry.headerOffset + 30 + _u16(header, 26) + _u16(header, 28);
}

/// [entry]'s bytes, unpacked (a small file: a book's package document).
Uint8List zipRead(String path, ZipEntry entry) {
  final f = File(path).openSync();
  try {
    final raw = _read(f, zipDataOffset(f, entry), entry.compressedSize);
    if (entry.stored) return raw;
    if (entry.method != 8) throw FormatException('${entry.name} is packed in a way TomeVoice cannot unpack');
    return Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
  } finally {
    f.closeSync();
  }
}

/// [entry] of the zip at [path] unpacked into the file [to], a piece at a
/// time (a chapter's audio can be tens of megabytes).
void zipUnpack(String path, ZipEntry entry, String to) {
  final input = File(path).openSync();
  final out = File(to).openSync(mode: FileMode.write);
  try {
    input.setPositionSync(zipDataOffset(input, entry));
    final sink = _FileSink(out);
    final inflate = entry.stored ? null : ZLibDecoder(raw: true).startChunkedConversion(sink);
    if (!entry.stored && entry.method != 8) {
      throw FormatException('${entry.name} is packed in a way TomeVoice cannot unpack');
    }
    var left = entry.compressedSize;
    while (left > 0) {
      final piece = input.readSync(math.min(left, 1 << 20));
      if (piece.isEmpty) throw FormatException('${entry.name} is cut short in the book');
      left -= piece.length;
      if (inflate == null) {
        out.writeFromSync(piece);
      } else {
        inflate.add(piece);
      }
    }
    inflate?.close();
  } finally {
    input.closeSync();
    out.closeSync();
  }
}

class _FileSink implements Sink<List<int>> {
  _FileSink(this.file);

  final RandomAccessFile file;

  @override
  void add(List<int> data) => file.writeFromSync(data);

  @override
  void close() {}
}

Uint8List _read(RandomAccessFile f, int at, int length) {
  f.setPositionSync(at);
  return f.readSync(length);
}

int _u16(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

int _u32(Uint8List b, int at) => _u16(b, at) | (_u16(b, at + 2) << 16);

int _u64(Uint8List b, int at) => _u32(b, at) + _u32(b, at + 4) * 0x100000000;
