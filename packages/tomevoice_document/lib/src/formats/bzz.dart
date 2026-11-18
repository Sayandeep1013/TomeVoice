import 'dart:typed_data';

// BZZ, the compression DjVu keeps its text layers, outlines, annotations and
// directories in: blocks sorted by the Burrows-Wheeler transform, each byte
// then coded as its place in a move-to-front list (kept in order of how
// often bytes come up), and those places coded bit by bit by the ZP-coder,
// an adaptive binary arithmetic coder. Decoding only, ported from
// DjVuLibre's BSByteStream.cpp and ZPCodec.cpp (Leon Bottou, GPL-2.0 or
// later), whose layout the DjVu 3 specification describes.

/// The most a block may hold: DjVuLibre's limit (4096 KB).
const _maxBlock = 4096 * 1024;

/// [data] (from [start] to [end]) unpacked.
///
/// Throws a [FormatException] when the data is cut short or does not decode,
/// and when it would unpack to more than [maxLength] bytes: a damaged stream
/// can claim blocks of any size, and a page's text is never that long.
Uint8List bzzDecode(Uint8List data, {int start = 0, int? end, int maxLength = 64 << 20}) {
  final zp = _ZpDecoder(data, start, end ?? data.length);
  // The contexts carry over from one block to the next.
  final ctx = Uint8List(300);
  final out = BytesBuilder(copy: false);
  for (;;) {
    final size = _decodeRaw(zp, 24);
    if (size == 0) break;
    if (size > _maxBlock) throw const FormatException('BZZ block too large');
    if (out.length + size > maxLength) throw const FormatException('BZZ data too long');
    out.add(_decodeBlock(zp, ctx, size));
  }
  return out.takeBytes();
}

/// A number of [bits] bits, each coded at even odds.
int _decodeRaw(_ZpDecoder zp, int bits) {
  final m = 1 << bits;
  var n = 1;
  while (n < m) {
    n = (n << 1) | zp.decodeEven();
  }
  return n - m;
}

/// A number of [bits] bits, coded in the binary tree of contexts that
/// starts at [ctx][base].
int _decodeBinary(_ZpDecoder zp, Uint8List ctx, int base, int bits) {
  final m = 1 << bits;
  var n = 1;
  while (n < m) {
    n = (n << 1) | zp.decode(ctx, base + n - 1);
  }
  return n - m;
}

/// How many entries of the move-to-front list keep a count of their use.
const _freqMax = 4;

/// Contexts for the first two places of the list, by the place before.
const _ctxIds = 3;

/// One block: [size] bytes, the last of them the block's end marker, which
/// is not returned.
Uint8List _decodeBlock(_ZpDecoder zp, Uint8List ctx, int size) {
  // How fast the counts of use forget.
  var fshift = 0;
  if (zp.decodeEven() != 0) {
    fshift++;
    if (zp.decodeEven() != 0) fshift++;
  }
  final mtf = Uint8List.fromList([for (var i = 0; i < 256; i++) i]);
  final freq = List<int>.filled(_freqMax, 0);
  var fadd = 4;
  final data = Uint8List(size);
  var mtfno = 3;
  var markerpos = -1;
  for (var i = 0; i < size; i++) {
    final ctxid = mtfno < _ctxIds - 1 ? mtfno : _ctxIds - 1;
    var cx = 0;
    if (zp.decode(ctx, cx + ctxid) != 0) {
      mtfno = 0;
    } else {
      cx += _ctxIds;
      if (zp.decode(ctx, cx + ctxid) != 0) {
        mtfno = 1;
      } else {
        cx += _ctxIds;
        mtfno = 256;
        // Places 2-3, 4-7, 8-15 ... 128-255: a bit says which range, then
        // the place within it.
        for (var bits = 1; bits <= 7; bits++) {
          if (zp.decode(ctx, cx) != 0) {
            mtfno = (1 << bits) + _decodeBinary(zp, ctx, cx + 1, bits);
            break;
          }
          cx += 1 << bits;
        }
      }
    }
    if (mtfno == 256) {
      // The end marker: where the sorted block's first row was.
      data[i] = 0;
      markerpos = i;
      continue;
    }
    final c = mtf[mtfno];
    data[i] = c;
    // Move the byte up the list as far as its count of use says.
    fadd += fadd >> fshift;
    if (fadd > 0x10000000) {
      fadd >>= 24;
      for (var k = 0; k < _freqMax; k++) {
        freq[k] >>= 24;
      }
    }
    var fc = fadd;
    if (mtfno < _freqMax) fc = (fc + freq[mtfno]) & 0xFFFFFFFF;
    var k = mtfno;
    for (; k >= _freqMax; k--) {
      mtf[k] = mtf[k - 1];
    }
    for (; k > 0 && fc >= freq[k - 1]; k--) {
      mtf[k] = mtf[k - 1];
      freq[k] = freq[k - 1];
    }
    mtf[k] = c;
    freq[k] = fc;
  }

  if (markerpos < 1 || markerpos >= size) throw const FormatException('BZZ block has no end marker');
  // Undo the sort: each row's byte, and its rank among the rows ending in
  // that byte.
  final posn = Uint32List(size);
  final count = List<int>.filled(256, 0);
  for (var i = 0; i < size; i++) {
    if (i == markerpos) continue;
    final c = data[i];
    posn[i] = (c << 24) | (count[c] & 0xFFFFFF);
    count[c]++;
  }
  var last = 1;
  for (var i = 0; i < 256; i++) {
    final n = count[i];
    count[i] = last;
    last += n;
  }
  var i = 0;
  last = size - 1;
  while (last > 0) {
    final n = posn[i];
    final c = n >> 24;
    data[--last] = c;
    i = count[c] + (n & 0xFFFFFF);
  }
  if (i != markerpos) throw const FormatException('BZZ block does not unsort');
  return Uint8List.sublistView(data, 0, size - 1);
}

/// The ZP-coder's decoder, as DjVuLibre runs it for DjVu files (its table
/// unpatched, "djvucompat").
class _ZpDecoder {
  _ZpDecoder(this._data, this._pos, this._end) {
    _code = (_next() ?? 0xFF) << 8;
    _code |= _next() ?? 0xFF;
    _preload();
    _fence = _code >= 0x8000 ? 0x7FFF : _code;
  }

  final Uint8List _data;
  int _pos;
  final int _end;
  int _a = 0;
  int _code = 0;
  int _fence = 0;
  int _buffer = 0;
  int _scount = 0;

  /// How many bytes past the end may be made up (as 0xFF) before the data
  /// counts as cut short.
  int _delay = 25;

  int? _next() => _pos < _end ? _data[_pos++] : null;

  void _preload() {
    while (_scount <= 24) {
      var byte = _next();
      if (byte == null) {
        byte = 0xFF;
        if (--_delay < 1) throw const FormatException('BZZ data ends too soon');
      }
      _buffer = ((_buffer << 8) | byte) & 0xFFFFFFFF;
      _scount += 8;
    }
  }

  void _setFence() => _fence = _code >= 0x8000 ? 0x7FFF : _code;

  /// One bit in the adaptive context [ctx][i], which learns from it.
  int decode(Uint8List ctx, int i) {
    final state = ctx[i];
    final z = _a + _zpP(state);
    if (z <= _fence) {
      _a = z;
      return state & 1;
    }
    // Avoid interval reversion.
    final d = 0x6000 + ((z + _a) >> 2);
    final zz = z > d ? d : z;
    if (zz > _code) {
      ctx[i] = zpTable[state * 4 + 3];
      _lps(zz);
      return (state & 1) ^ 1;
    }
    if (_a >= zpTable[state * 4 + 1]) ctx[i] = zpTable[state * 4 + 2];
    _mps(zz);
    return state & 1;
  }

  /// One bit at even odds, with no context.
  int decodeEven() {
    final z = 0x8000 + (_a >> 1);
    if (z > _code) {
      _lps(z);
      return 1;
    }
    _mps(z);
    return 0;
  }

  void _lps(int z) {
    z = 0x10000 - z;
    _a += z;
    _code += z;
    final shift = _ffz(_a);
    _scount -= shift;
    _a = (_a << shift) & 0xFFFF;
    _code = ((_code << shift) & 0xFFFF) | ((_buffer >> _scount) & ((1 << shift) - 1));
    if (_scount < 16) _preload();
    _setFence();
  }

  void _mps(int z) {
    _scount -= 1;
    _a = (z << 1) & 0xFFFF;
    _code = ((_code << 1) & 0xFFFF) | ((_buffer >> _scount) & 1);
    if (_scount < 16) _preload();
    _setFence();
  }

  /// How many 1 bits [x] (16 bits) starts with.
  static int _ffz(int x) => x >= 0xFF00 ? _ones[x & 0xFF] + 8 : _ones[(x >> 8) & 0xFF];

  static final _ones = Uint8List.fromList([
    for (var i = 0; i < 256; i++) _leadingOnes(i),
  ]);

  static int _leadingOnes(int byte) {
    var n = 0;
    for (var b = byte; b & 0x80 != 0; b = (b << 1) & 0xFF) {
      n++;
    }
    return n;
  }
}

int _zpP(int state) => zpTable[state * 4];

/// The ZP-coder's states: for each, the probability of the less likely bit
/// (p), the threshold above which a likely bit moves the state up (m), and
/// the states a likely (up) and an unlikely (dn) bit lead to. DjVuLibre's
/// default table for the ZP-coder; its last five states are never reached
/// and are left as zeros, as there. Four numbers a state. Not exported: the
/// tests' encoder (test/djvu_fixture.dart) shares it.
final zpTable = Uint32List.fromList([
  0x8000, 0x0000, 84, 145, 0x8000, 0x0000, 3, 4, 0x8000, 0x0000, 4, 3, 0x6bbd, 0x10a5, 5, 1,
  0x6bbd, 0x10a5, 6, 2, 0x5d45, 0x1f28, 7, 3, 0x5d45, 0x1f28, 8, 4, 0x51b9, 0x2bd3, 9, 5,
  0x51b9, 0x2bd3, 10, 6, 0x4813, 0x36e3, 11, 7, 0x4813, 0x36e3, 12, 8, 0x3fd5, 0x408c, 13, 9,
  0x3fd5, 0x408c, 14, 10, 0x38b1, 0x48fd, 15, 11, 0x38b1, 0x48fd, 16, 12, 0x3275, 0x505d, 17, 13,
  0x3275, 0x505d, 18, 14, 0x2cfd, 0x56d0, 19, 15, 0x2cfd, 0x56d0, 20, 16, 0x2825, 0x5c71, 21, 17,
  0x2825, 0x5c71, 22, 18, 0x23ab, 0x615b, 23, 19, 0x23ab, 0x615b, 24, 20, 0x1f87, 0x65a5, 25, 21,
  0x1f87, 0x65a5, 26, 22, 0x1bbb, 0x6962, 27, 23, 0x1bbb, 0x6962, 28, 24, 0x1845, 0x6ca2, 29, 25,
  0x1845, 0x6ca2, 30, 26, 0x1523, 0x6f74, 31, 27, 0x1523, 0x6f74, 32, 28, 0x1253, 0x71e6, 33, 29,
  0x1253, 0x71e6, 34, 30, 0x0fcf, 0x7404, 35, 31, 0x0fcf, 0x7404, 36, 32, 0x0d95, 0x75d6, 37, 33,
  0x0d95, 0x75d6, 38, 34, 0x0b9d, 0x7768, 39, 35, 0x0b9d, 0x7768, 40, 36, 0x09e3, 0x78c2, 41, 37,
  0x09e3, 0x78c2, 42, 38, 0x0861, 0x79ea, 43, 39, 0x0861, 0x79ea, 44, 40, 0x0711, 0x7ae7, 45, 41,
  0x0711, 0x7ae7, 46, 42, 0x05f1, 0x7bbe, 47, 43, 0x05f1, 0x7bbe, 48, 44, 0x04f9, 0x7c75, 49, 45,
  0x04f9, 0x7c75, 50, 46, 0x0425, 0x7d0f, 51, 47, 0x0425, 0x7d0f, 52, 48, 0x0371, 0x7d91, 53, 49,
  0x0371, 0x7d91, 54, 50, 0x02d9, 0x7dfe, 55, 51, 0x02d9, 0x7dfe, 56, 52, 0x0259, 0x7e5a, 57, 53,
  0x0259, 0x7e5a, 58, 54, 0x01ed, 0x7ea6, 59, 55, 0x01ed, 0x7ea6, 60, 56, 0x0193, 0x7ee6, 61, 57,
  0x0193, 0x7ee6, 62, 58, 0x0149, 0x7f1a, 63, 59, 0x0149, 0x7f1a, 64, 60, 0x010b, 0x7f45, 65, 61,
  0x010b, 0x7f45, 66, 62, 0x00d5, 0x7f6b, 67, 63, 0x00d5, 0x7f6b, 68, 64, 0x00a5, 0x7f8d, 69, 65,
  0x00a5, 0x7f8d, 70, 66, 0x007b, 0x7faa, 71, 67, 0x007b, 0x7faa, 72, 68, 0x0057, 0x7fc3, 73, 69,
  0x0057, 0x7fc3, 74, 70, 0x003b, 0x7fd7, 75, 71, 0x003b, 0x7fd7, 76, 72, 0x0023, 0x7fe7, 77, 73,
  0x0023, 0x7fe7, 78, 74, 0x0013, 0x7ff2, 79, 75, 0x0013, 0x7ff2, 80, 76, 0x0007, 0x7ffa, 81, 77,
  0x0007, 0x7ffa, 82, 78, 0x0001, 0x7fff, 81, 79, 0x0001, 0x7fff, 82, 80, 0x5695, 0x0000, 9, 85,
  0x24ee, 0x0000, 86, 226, 0x8000, 0x0000, 5, 6, 0x0d30, 0x0000, 88, 176, 0x481a, 0x0000, 89, 143,
  0x0481, 0x0000, 90, 138, 0x3579, 0x0000, 91, 141, 0x017a, 0x0000, 92, 112, 0x24ef, 0x0000, 93, 135,
  0x007b, 0x0000, 94, 104, 0x1978, 0x0000, 95, 133, 0x0028, 0x0000, 96, 100, 0x10ca, 0x0000, 97, 129,
  0x000d, 0x0000, 82, 98, 0x0b5d, 0x0000, 99, 127, 0x0034, 0x0000, 76, 72, 0x078a, 0x0000, 101, 125,
  0x00a0, 0x0000, 70, 102, 0x050f, 0x0000, 103, 123, 0x0117, 0x0000, 66, 60, 0x0358, 0x0000, 105, 121,
  0x01ea, 0x0000, 106, 110, 0x0234, 0x0000, 107, 119, 0x0144, 0x0000, 66, 108, 0x0173, 0x0000, 109, 117,
  0x0234, 0x0000, 60, 54, 0x00f5, 0x0000, 111, 115, 0x0353, 0x0000, 56, 48, 0x00a1, 0x0000, 69, 113,
  0x05c5, 0x0000, 114, 134, 0x011a, 0x0000, 65, 59, 0x03cf, 0x0000, 116, 132, 0x01aa, 0x0000, 61, 55,
  0x0285, 0x0000, 118, 130, 0x0286, 0x0000, 57, 51, 0x01ab, 0x0000, 120, 128, 0x03d3, 0x0000, 53, 47,
  0x011a, 0x0000, 122, 126, 0x05c5, 0x0000, 49, 41, 0x00ba, 0x0000, 124, 62, 0x08ad, 0x0000, 43, 37,
  0x007a, 0x0000, 72, 66, 0x0ccc, 0x0000, 39, 31, 0x01eb, 0x0000, 60, 54, 0x1302, 0x0000, 33, 25,
  0x02e6, 0x0000, 56, 50, 0x1b81, 0x0000, 29, 131, 0x045e, 0x0000, 52, 46, 0x24ef, 0x0000, 23, 17,
  0x0690, 0x0000, 48, 40, 0x2865, 0x0000, 23, 15, 0x09de, 0x0000, 42, 136, 0x3987, 0x0000, 137, 7,
  0x0dc8, 0x0000, 38, 32, 0x2c99, 0x0000, 21, 139, 0x10ca, 0x0000, 140, 172, 0x3b5f, 0x0000, 15, 9,
  0x0b5d, 0x0000, 142, 170, 0x5695, 0x0000, 9, 85, 0x078a, 0x0000, 144, 168, 0x8000, 0x0000, 141, 248,
  0x050f, 0x0000, 146, 166, 0x24ee, 0x0000, 147, 247, 0x0358, 0x0000, 148, 164, 0x0d30, 0x0000, 149, 197,
  0x0234, 0x0000, 150, 162, 0x0481, 0x0000, 151, 95, 0x0173, 0x0000, 152, 160, 0x017a, 0x0000, 153, 173,
  0x00f5, 0x0000, 154, 158, 0x007b, 0x0000, 155, 165, 0x00a1, 0x0000, 70, 156, 0x0028, 0x0000, 157, 161,
  0x011a, 0x0000, 66, 60, 0x000d, 0x0000, 81, 159, 0x01aa, 0x0000, 62, 56, 0x0034, 0x0000, 75, 71,
  0x0286, 0x0000, 58, 52, 0x00a0, 0x0000, 69, 163, 0x03d3, 0x0000, 54, 48, 0x0117, 0x0000, 65, 59,
  0x05c5, 0x0000, 50, 42, 0x01ea, 0x0000, 167, 171, 0x08ad, 0x0000, 44, 38, 0x0144, 0x0000, 65, 169,
  0x0ccc, 0x0000, 40, 32, 0x0234, 0x0000, 59, 53, 0x1302, 0x0000, 34, 26, 0x0353, 0x0000, 55, 47,
  0x1b81, 0x0000, 30, 174, 0x05c5, 0x0000, 175, 193, 0x24ef, 0x0000, 24, 18, 0x03cf, 0x0000, 177, 191,
  0x2b74, 0x0000, 178, 222, 0x0285, 0x0000, 179, 189, 0x201d, 0x0000, 180, 218, 0x01ab, 0x0000, 181, 187,
  0x1715, 0x0000, 182, 216, 0x011a, 0x0000, 183, 185, 0x0fb7, 0x0000, 184, 214, 0x00ba, 0x0000, 69, 61,
  0x0a67, 0x0000, 186, 212, 0x01eb, 0x0000, 59, 53, 0x06e7, 0x0000, 188, 210, 0x02e6, 0x0000, 55, 49,
  0x0496, 0x0000, 190, 208, 0x045e, 0x0000, 51, 45, 0x030d, 0x0000, 192, 206, 0x0690, 0x0000, 47, 39,
  0x0206, 0x0000, 194, 204, 0x09de, 0x0000, 41, 195, 0x0155, 0x0000, 196, 202, 0x0dc8, 0x0000, 37, 31,
  0x00e1, 0x0000, 198, 200, 0x2b74, 0x0000, 199, 243, 0x0094, 0x0000, 72, 64, 0x201d, 0x0000, 201, 239,
  0x0188, 0x0000, 62, 56, 0x1715, 0x0000, 203, 237, 0x0252, 0x0000, 58, 52, 0x0fb7, 0x0000, 205, 235,
  0x0383, 0x0000, 54, 48, 0x0a67, 0x0000, 207, 233, 0x0547, 0x0000, 50, 44, 0x06e7, 0x0000, 209, 231,
  0x07e2, 0x0000, 46, 38, 0x0496, 0x0000, 211, 229, 0x0bc0, 0x0000, 40, 34, 0x030d, 0x0000, 213, 227,
  0x1178, 0x0000, 36, 28, 0x0206, 0x0000, 215, 225, 0x19da, 0x0000, 30, 22, 0x0155, 0x0000, 217, 223,
  0x24ef, 0x0000, 26, 16, 0x00e1, 0x0000, 219, 221, 0x320e, 0x0000, 20, 220, 0x0094, 0x0000, 71, 63,
  0x432a, 0x0000, 14, 8, 0x0188, 0x0000, 61, 55, 0x447d, 0x0000, 14, 224, 0x0252, 0x0000, 57, 51,
  0x5ece, 0x0000, 8, 2, 0x0383, 0x0000, 53, 47, 0x8000, 0x0000, 228, 87, 0x0547, 0x0000, 49, 43,
  0x481a, 0x0000, 230, 246, 0x07e2, 0x0000, 45, 37, 0x3579, 0x0000, 232, 244, 0x0bc0, 0x0000, 39, 33,
  0x24ef, 0x0000, 234, 238, 0x1178, 0x0000, 35, 27, 0x1978, 0x0000, 138, 236, 0x19da, 0x0000, 29, 21,
  0x2865, 0x0000, 24, 16, 0x24ef, 0x0000, 25, 15, 0x3987, 0x0000, 240, 8, 0x320e, 0x0000, 19, 241,
  0x2c99, 0x0000, 22, 242, 0x432a, 0x0000, 13, 7, 0x3b5f, 0x0000, 16, 10, 0x447d, 0x0000, 13, 245,
  0x5695, 0x0000, 10, 2, 0x5ece, 0x0000, 7, 1, 0x8000, 0x0000, 244, 83, 0x8000, 0x0000, 249, 250,
  0x5695, 0x0000, 10, 2, 0x481a, 0x0000, 89, 143, 0x481a, 0x0000, 230, 246,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]);
