import 'dart:convert';
import 'dart:typed_data';

import 'package:tomevoice_document/src/formats/bzz.dart';

// DjVu files made in the tests: a BZZ encoder (the mirror of the decoder in
// lib/src/formats/bzz.dart, ported from DjVuLibre's BSEncodeByteStream.cpp
// and ZPCodec.cpp, GPL-2.0 or later), and the chunks a DjVu is built of.

/// [data] packed as DjVu packs its text layers, outlines and directories,
/// in blocks of at most [blockSize] bytes.
Uint8List bzzEncode(List<int> data, {int blockSize = 1 << 20}) {
  final zp = _ZpEncoder();
  final ctx = Uint8List(300);
  for (var at = 0; at < data.length; at += blockSize) {
    final end = at + blockSize < data.length ? at + blockSize : data.length;
    _encodeBlock(zp, ctx, data.sublist(at, end));
  }
  _encodeRaw(zp, 24, 0);
  zp.flush();
  return zp.out.takeBytes();
}

void _encodeRaw(_ZpEncoder zp, int bits, int x) {
  final m = 1 << bits;
  var n = 1;
  while (n < m) {
    x = (x & (m - 1)) << 1;
    final b = x >> bits;
    zp.encodeEven(b);
    n = (n << 1) | b;
  }
}

void _encodeBinary(_ZpEncoder zp, Uint8List ctx, int base, int bits, int x) {
  final m = 1 << bits;
  var n = 1;
  while (n < m) {
    x = (x & (m - 1)) << 1;
    final b = x >> bits;
    zp.encode(b, ctx, base + n - 1);
    n = (n << 1) | b;
  }
}

/// One block: sorted (Burrows-Wheeler, with an end marker that sorts first),
/// then coded through the move-to-front list as the decoder reads it.
void _encodeBlock(_ZpEncoder zp, Uint8List ctx, List<int> s) {
  final n = s.length;
  final size = n + 1;
  // The suffixes of s and the marker, sorted; the marker's alone is first.
  final rows = [for (var i = 0; i <= n; i++) i]..sort((a, b) {
      while (a < n && b < n) {
        final d = s[a] - s[b];
        if (d != 0) return d;
        a++;
        b++;
      }
      return (n - a) - (n - b);
    });
  final data = List<int>.filled(size, 0);
  var markerpos = -1;
  for (var r = 0; r < size; r++) {
    final k = rows[r];
    if (k == 0) {
      markerpos = r;
    } else {
      data[r] = s[k - 1];
    }
  }

  _encodeRaw(zp, 24, size);
  // Counts of use forget at the slowest pace.
  zp.encodeEven(0);
  final mtf = List<int>.generate(256, (i) => i);
  final rmtf = List<int>.generate(256, (i) => i);
  final freq = List<int>.filled(4, 0);
  var fadd = 4;
  var mtfno = 3;
  for (var i = 0; i < size; i++) {
    final c = data[i];
    final ctxid = mtfno < 2 ? mtfno : 2;
    mtfno = i == markerpos ? 256 : rmtf[c];
    var cx = 0;
    var done = false;
    var b = mtfno == 0 ? 1 : 0;
    zp.encode(b, ctx, cx + ctxid);
    if (b == 1) {
      done = true;
    } else {
      cx += 3;
      b = mtfno == 1 ? 1 : 0;
      zp.encode(b, ctx, cx + ctxid);
      if (b == 1) {
        done = true;
      } else {
        cx += 3;
        for (var bits = 1; bits <= 7; bits++) {
          b = mtfno < (2 << bits) ? 1 : 0;
          zp.encode(b, ctx, cx);
          if (b == 1) {
            _encodeBinary(zp, ctx, cx + 1, bits, mtfno - (1 << bits));
            done = true;
            break;
          }
          cx += 1 << bits;
        }
      }
    }
    if (!done) continue;
    fadd += fadd >> 0;
    if (fadd > 0x10000000) {
      fadd >>= 24;
      for (var k = 0; k < 4; k++) {
        freq[k] >>= 24;
      }
    }
    var fc = fadd;
    if (mtfno < 4) fc = (fc + freq[mtfno]) & 0xFFFFFFFF;
    var k = mtfno;
    for (; k >= 4; k--) {
      mtf[k] = mtf[k - 1];
      rmtf[mtf[k]] = k;
    }
    for (; k > 0 && fc >= freq[k - 1]; k--) {
      mtf[k] = mtf[k - 1];
      freq[k] = freq[k - 1];
      rmtf[mtf[k]] = k;
    }
    mtf[k] = c;
    freq[k] = fc;
    rmtf[c] = k;
  }
}

class _ZpEncoder {
  final out = BytesBuilder();
  int _a = 0, _scount = 0, _byte = 0, _delay = 25, _subend = 0, _buffer = 0xFFFFFF, _nrun = 0;

  void _outbit(int bit) {
    if (_delay > 0) {
      if (_delay < 0xFF) _delay--;
      return;
    }
    _byte = (_byte << 1) | bit;
    if (++_scount == 8) {
      out.addByte(_byte & 0xFF);
      _scount = 0;
      _byte = 0;
    }
  }

  void _emit(int b) {
    _buffer = ((_buffer << 1) + b) & 0xFFFFFFFF;
    final top = _buffer >> 24;
    _buffer &= 0xFFFFFF;
    switch (top) {
      case 1:
        _outbit(1);
        for (; _nrun > 0; _nrun--) {
          _outbit(0);
        }
      case 0xFF:
        _outbit(0);
        for (; _nrun > 0; _nrun--) {
          _outbit(1);
        }
      case 0:
        _nrun++;
      default:
        throw StateError('ZP encoder lost its place');
    }
  }

  void _shiftOut() {
    _emit(1 - (_subend >> 15));
    _subend = (_subend << 1) & 0xFFFF;
    _a = (_a << 1) & 0xFFFF;
  }

  void flush() {
    if (_subend > 0x8000) {
      _subend = 0x10000;
    } else if (_subend > 0) {
      _subend = 0x8000;
    }
    while (_buffer != 0xFFFFFF || _subend != 0) {
      _emit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
    }
    _outbit(1);
    for (; _nrun > 0; _nrun--) {
      _outbit(0);
    }
    while (_scount > 0) {
      _outbit(1);
    }
    _delay = 0xFF;
  }

  void encode(int bit, Uint8List ctx, int i) {
    final state = ctx[i];
    var z = _a + zpTable[state * 4];
    if (bit != (state & 1)) {
      final d = 0x6000 + ((z + _a) >> 2);
      if (z > d) z = d;
      ctx[i] = zpTable[state * 4 + 3];
      z = 0x10000 - z;
      _subend += z;
      _a += z;
      while (_a >= 0x8000) {
        _shiftOut();
      }
    } else if (z >= 0x8000) {
      final d = 0x6000 + ((z + _a) >> 2);
      if (z > d) z = d;
      if (_a >= zpTable[state * 4 + 1]) ctx[i] = zpTable[state * 4 + 2];
      _a = z;
      if (_a >= 0x8000) _shiftOut();
    } else {
      _a = z;
    }
  }

  void encodeEven(int bit) {
    var z = 0x8000 + (_a >> 1);
    if (bit != 0) {
      z = 0x10000 - z;
      _subend += z;
      _a += z;
      while (_a >= 0x8000) {
        _shiftOut();
      }
    } else {
      _a = z;
      if (_a >= 0x8000) _shiftOut();
    }
  }
}

// ---------------------------------------------------------------- chunks

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u24(int v) => [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// An IFF chunk: its id, its size, its data, and a byte to make it even.
List<int> chunk(String id, List<int> data) => [
      ...ascii.encode(id),
      ..._u32(data.length),
      ...data,
      if (data.length.isOdd) 0,
    ];

/// A FORM chunk of [type] ("DJVU", "DJVI", "DJVM") holding [chunks].
List<int> form(String type, List<List<int>> chunks) => chunk('FORM', [
      ...ascii.encode(type),
      for (final c in chunks) ...c,
    ]);

/// A whole file: the "AT&T" every DjVu starts with, then its form.
Uint8List djvuFile(List<int> form) => Uint8List.fromList([...ascii.encode('AT&T'), ...form]);

/// A page's INFO chunk: its size in pixels and its resolution.
List<int> info({int width = 2550, int height = 3300, int dpi = 300}) =>
    chunk('INFO', [..._u16(width), ..._u16(height), 24, 0, dpi & 0xFF, dpi >> 8, 22, 1]);

/// A zone of a text layer: its kind (1 page ... 7 character), where it sits
/// (pixels from the bottom left), the stretch of the text's bytes it holds,
/// and the zones in it.
class Zone {
  Zone(this.type, this.xmin, this.ymin, this.xmax, this.ymax, this.start, this.length, [this.children = const []]);
  final int type, xmin, ymin, xmax, ymax, start, length;
  final List<Zone> children;
}

/// A text layer's data (TXTa's, or TXTz's before packing): the text and,
/// when given, its zones.
List<int> textLayer(String text, {Zone? zones}) {
  final bytes = utf8.encode(text);
  final out = <int>[..._u24(bytes.length), ...bytes];
  if (zones != null) {
    out.add(1);
    _writeZone(out, zones, null, null);
  }
  return out;
}

void _writeZone(List<int> out, Zone z, Zone? parent, Zone? prev) {
  var x = z.xmin, y = z.ymin, start = z.start;
  final w = z.xmax - z.xmin, h = z.ymax - z.ymin;
  if (prev != null) {
    if (z.type == 1 || z.type == 4 || z.type == 5) {
      x -= prev.xmin;
      y = prev.ymin - (z.ymin + h);
    } else {
      x -= prev.xmax;
      y -= prev.ymin;
    }
    start -= prev.start + prev.length;
  } else if (parent != null) {
    x -= parent.xmin;
    y = parent.ymax - (z.ymin + h);
    start -= parent.start;
  }
  out
    ..add(z.type)
    ..addAll(_u16(x + 0x8000))
    ..addAll(_u16(y + 0x8000))
    ..addAll(_u16(w + 0x8000))
    ..addAll(_u16(h + 0x8000))
    ..addAll(_u16(start + 0x8000))
    ..addAll(_u24(z.length))
    ..addAll(_u24(z.children.length));
  Zone? last;
  for (final c in z.children) {
    _writeZone(out, c, z, last);
    last = c;
  }
}

/// A page's text layer from its paragraphs, each a list of lines, set as OCR
/// sets a page: lines 50 pixels apart, a line's gap more between paragraphs,
/// each line as wide as its text (30 pixels a character) and in paragraph
/// zones when [paragraphZones], straight in the page zone when not.
List<int> pageText(List<List<String>> paragraphs, {bool paragraphZones = true, int height = 3300}) {
  final text = StringBuffer();
  final paraZones = <Zone>[];
  final looseLines = <Zone>[];
  var y = height - 200;
  for (final p in paragraphs) {
    final lines = <Zone>[];
    final paraStart = utf8.encode(text.toString()).length;
    for (final l in p) {
      final start = utf8.encode(text.toString()).length;
      text.write('$l\n');
      final length = utf8.encode('$l\n').length;
      lines.add(Zone(5, 200, y - 40, 200 + 30 * l.length, y, start, length));
      y -= 50;
    }
    text.write('\x1F');
    final paraLength = utf8.encode(text.toString()).length - paraStart;
    paraZones.add(Zone(4, 200, lines.last.ymin, lines.map((l) => l.xmax).reduce((a, b) => a > b ? a : b), lines.first.ymax,
        paraStart, paraLength, lines));
    looseLines.addAll(lines);
    y -= 50;
  }
  final all = utf8.encode(text.toString()).length;
  return textLayer(
    text.toString(),
    zones: Zone(1, 0, 0, 2550, height, 0, all, paragraphZones ? paraZones : looseLines),
  );
}

/// A bookmark of an outline: its title, where it points ("#3" for the third
/// page, "#p0003.djvu" for a page's file) and the bookmarks under it.
class Bookmark {
  const Bookmark(this.title, this.url, [this.children = const []]);
  final String title, url;
  final List<Bookmark> children;
}

/// A NAVM chunk's data, packed: how many bookmarks, then each in order.
List<int> navm(List<Bookmark> bookmarks) {
  final out = <int>[];
  var total = 0;
  void write(Bookmark b) {
    total++;
    final title = utf8.encode(b.title), url = utf8.encode(b.url);
    out
      ..add(b.children.length & 0xFF)
      ..add(b.children.length >> 8)
      ..addAll(_u16(title.length))
      ..addAll(title)
      ..addAll(_u24(url.length))
      ..addAll(url);
    b.children.forEach(write);
  }

  bookmarks.forEach(write);
  return bzzEncode([..._u16(total), ...out]);
}

/// A file of a bundled DjVu: its id, its kind (0 included, 1 page, 3 shared
/// annotations), its title when it has one, and its form.
typedef Part = ({String id, int type, String? title, List<int> form});

/// A bundled DjVu: a DIRM directory, then [extra] chunks (NAVM), then the
/// files. [bundled] false writes an indirect DjVu's directory, which points
/// at files beside it.
Uint8List bundle(List<Part> parts, {List<List<int>> extra = const [], bool bundled = true}) {
  final names = <int>[
    for (final p in parts) ..._u24(p.form.length),
    for (final p in parts) p.type | (p.title != null ? 0x40 : 0),
    for (final p in parts) ...[
      ...utf8.encode(p.id),
      0,
      if (p.title != null) ...[...utf8.encode(p.title!), 0],
    ],
  ];
  final packed = bzzEncode(names);
  final head = 3 + (bundled ? 4 * parts.length : 0);
  final dirmLength = 8 + head + packed.length + ((head + packed.length).isOdd ? 1 : 0);
  var at = 4 + 12 + dirmLength + extra.fold<int>(0, (n, c) => n + c.length);
  final offsets = <int>[];
  for (final p in parts) {
    offsets.add(at);
    at += p.form.length;
  }
  final dirm = chunk('DIRM', [
    bundled ? 0x81 : 0x01,
    ..._u16(parts.length),
    if (bundled)
      for (final o in offsets) ..._u32(o),
    ...packed,
  ]);
  return djvuFile(form('DJVM', [
    dirm,
    ...extra,
    if (bundled)
      for (final p in parts) p.form,
  ]));
}
