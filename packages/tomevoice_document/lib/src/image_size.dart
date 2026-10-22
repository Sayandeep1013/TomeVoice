import 'dart:typed_data';

/// Pixel size of a PNG, JPEG, GIF or WebP from its header, or null.
///
/// The reader needs the size before the picture is decoded so a lazily built
/// list can reserve the right height; otherwise every image that loads pushes
/// the text the voice is following down the screen.
({int width, int height})? imageSize(Uint8List b) {
  if (b.length < 24) return null;
  final d = ByteData.sublistView(b);

  // PNG: IHDR is the first chunk.
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return _ok(d.getUint32(16), d.getUint32(20));
  }
  // GIF87a / GIF89a.
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return _ok(d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
  }
  // WebP: RIFF....WEBP then VP8 / VP8L / VP8X.
  if (b.length >= 30 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    final kind = String.fromCharCodes(b.sublist(12, 16));
    if (kind == 'VP8 ') {
      return _ok(d.getUint16(26, Endian.little) & 0x3FFF,
          d.getUint16(28, Endian.little) & 0x3FFF);
    }
    if (kind == 'VP8L') {
      final bits = d.getUint32(21, Endian.little);
      return _ok((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (kind == 'VP8X') {
      final w = b[24] | (b[25] << 8) | (b[26] << 16);
      final h = b[27] | (b[28] << 8) | (b[29] << 16);
      return _ok(w + 1, h + 1);
    }
    return null;
  }
  // JPEG: walk segments to the first start-of-frame.
  if (b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = d.getUint16(i + 2);
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) return _ok(d.getUint16(i + 7), d.getUint16(i + 5));
      if (len < 2) return null;
      i += 2 + len;
    }
  }
  return null;
}

({int width, int height})? _ok(int w, int h) =>
    w > 0 && h > 0 && w < 100000 && h < 100000 ? (width: w, height: h) : null;
