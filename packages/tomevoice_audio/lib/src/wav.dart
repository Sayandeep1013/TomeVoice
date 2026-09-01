import 'dart:typed_data';

import 'types.dart';

/// Minimal RIFF/WAVE reader and writer.
///
/// Handles the two formats we actually meet: 16-bit integer PCM (what Android's
/// `synthesizeToFile` produces) and 32-bit IEEE float. Multi-channel input is
/// downmixed to mono, because every stage in the pipeline is mono.
class WavCodec {
  const WavCodec._();

  static const int _formatPcm = 1;
  static const int _formatFloat = 3;
  static const int _formatExtensible = 0xFFFE;

  /// Parses a WAVE file into an [AudioBuffer].
  ///
  /// Chunks other than `fmt ` and `data` are skipped, which matters because
  /// real encoders emit `LIST`, `fact` and padding chunks that a naive
  /// fixed-offset parser would trip over.
  static AudioBuffer decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);

    if (bytes.length < 12) {
      throw const FormatException('Not a WAV file: too short');
    }
    if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
      throw const FormatException('Not a WAV file: missing RIFF/WAVE header');
    }

    int? format;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    int? dataOffset;
    int? dataLength;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _tag(bytes, offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;

      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);

        // WAVE_FORMAT_EXTENSIBLE hides the real format in its GUID prefix.
        if (format == _formatExtensible && size >= 26) {
          format = data.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        dataOffset = body;
        dataLength = size;
      }

      // Chunks are word-aligned: an odd size is followed by a pad byte.
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (format == null ||
        channels == null ||
        sampleRate == null ||
        bitsPerSample == null ||
        dataOffset == null ||
        dataLength == null) {
      throw const FormatException('WAV file missing fmt or data chunk');
    }

    // Guard against a declared size longer than the file actually is.
    final available = bytes.length - dataOffset;
    final byteCount = dataLength > available ? available : dataLength;

    final samples = switch (format) {
      _formatPcm when bitsPerSample == 16 =>
        _readPcm16(data, dataOffset, byteCount),
      _formatPcm when bitsPerSample == 8 =>
        _readPcm8(bytes, dataOffset, byteCount),
      _formatFloat when bitsPerSample == 32 =>
        _readFloat32(data, dataOffset, byteCount),
      _ => throw FormatException(
          'Unsupported WAV format $format at $bitsPerSample bits'),
    };

    return AudioBuffer(_downmix(samples, channels), sampleRate);
  }

  /// Encodes as 16-bit PCM, the format everything can play.
  static Uint8List encodePcm16(AudioBuffer buffer) {
    final frames = buffer.frameCount;
    final dataBytes = frames * 2;
    final out = Uint8List(44 + dataBytes);
    final view = ByteData.sublistView(out);

    _writeHeader(
      out,
      view,
      dataBytes: dataBytes,
      format: _formatPcm,
      sampleRate: buffer.sampleRate,
      bitsPerSample: 16,
    );

    for (var i = 0; i < frames; i++) {
      final clamped = buffer.samples[i].clamp(-1.0, 1.0);
      // Symmetric scaling by 32767 in both directions, matched by the divisor
      // in _readPcm16. Using 32768 on decode (the more common convention) but
      // 32767 on encode costs ~1.5 LSB on every round-trip, which is small but
      // systematic; keeping the two consistent holds it to half an LSB.
      final value = (clamped * 32767).round().clamp(-32767, 32767);
      view.setInt16(44 + i * 2, value, Endian.little);
    }
    return out;
  }

  /// Encodes as 32-bit float, lossless for our internal representation.
  static Uint8List encodeFloat32(AudioBuffer buffer) {
    final frames = buffer.frameCount;
    final dataBytes = frames * 4;
    final out = Uint8List(44 + dataBytes);
    final view = ByteData.sublistView(out);

    _writeHeader(
      out,
      view,
      dataBytes: dataBytes,
      format: _formatFloat,
      sampleRate: buffer.sampleRate,
      bitsPerSample: 32,
    );

    for (var i = 0; i < frames; i++) {
      view.setFloat32(44 + i * 4, buffer.samples[i], Endian.little);
    }
    return out;
  }

  static void _writeHeader(
    Uint8List out,
    ByteData view, {
    required int dataBytes,
    required int format,
    required int sampleRate,
    required int bitsPerSample,
  }) {
    const channels = 1;
    final blockAlign = channels * bitsPerSample ~/ 8;

    _putTag(out, 0, 'RIFF');
    view.setUint32(4, 36 + dataBytes, Endian.little);
    _putTag(out, 8, 'WAVE');
    _putTag(out, 12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, format, Endian.little);
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * blockAlign, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    _putTag(out, 36, 'data');
    view.setUint32(40, dataBytes, Endian.little);
  }

  static Float32List _readPcm16(ByteData data, int offset, int byteCount) {
    final count = byteCount ~/ 2;
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      // Divisor matches encodePcm16. -32768 is representable but out of our
      // normalised range, so clamp rather than returning -1.00003.
      out[i] =
          (data.getInt16(offset + i * 2, Endian.little) / 32767.0).clamp(-1.0, 1.0);
    }
    return out;
  }

  static Float32List _readPcm8(Uint8List bytes, int offset, int byteCount) {
    final out = Float32List(byteCount);
    for (var i = 0; i < byteCount; i++) {
      out[i] = (bytes[offset + i] - 128) / 128.0;
    }
    return out;
  }

  static Float32List _readFloat32(ByteData data, int offset, int byteCount) {
    final count = byteCount ~/ 4;
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      out[i] = data.getFloat32(offset + i * 4, Endian.little);
    }
    return out;
  }

  static Float32List _downmix(Float32List interleaved, int channels) {
    if (channels <= 1) return interleaved;
    final frames = interleaved.length ~/ channels;
    final out = Float32List(frames);
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        sum += interleaved[f * channels + c];
      }
      out[f] = sum / channels;
    }
    return out;
  }

  static String _tag(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));

  static void _putTag(Uint8List bytes, int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      bytes[offset + i] = tag.codeUnitAt(i);
    }
  }
}
