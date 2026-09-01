import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'fixtures.dart';

void main() {
  group('WAV codec', () {
    test('float32 round-trip is lossless', () {
      final fixture = syntheticSpeech(words: 3, wordMs: 100);
      final decoded =
          WavCodec.decode(WavCodec.encodeFloat32(fixture.audio));

      expect(decoded.sampleRate, fixture.audio.sampleRate);
      expect(decoded.frameCount, fixture.audio.frameCount);
      for (var i = 0; i < decoded.frameCount; i++) {
        expect(decoded.samples[i], closeTo(fixture.audio.samples[i], 1e-7));
      }
    });

    test('pcm16 round-trip is lossless within quantisation', () {
      final fixture = syntheticSpeech(words: 3, wordMs: 100);
      final decoded = WavCodec.decode(WavCodec.encodePcm16(fixture.audio));

      expect(decoded.frameCount, fixture.audio.frameCount);
      for (var i = 0; i < decoded.frameCount; i++) {
        // One LSB of int16.
        expect(decoded.samples[i], closeTo(fixture.audio.samples[i], 1 / 32767));
      }
    });

    test('pcm16 clamps rather than wrapping on overshoot', () {
      final hot = AudioBuffer(
        Float32List.fromList([2.0, -2.0, 1.0, -1.0, 0.0]),
        kRate,
      );
      final decoded = WavCodec.decode(WavCodec.encodePcm16(hot));

      expect(decoded.samples[0], closeTo(1.0, 1e-4));
      expect(decoded.samples[1], closeTo(-1.0, 1e-4));
      expect(decoded.samples[2], closeTo(1.0, 1e-4));
      expect(decoded.samples[3], closeTo(-1.0, 1e-4));
      expect(decoded.samples[4], 0.0);
    });

    test('skips unknown chunks instead of misreading them', () {
      final fixture = syntheticSpeech(words: 2, wordMs: 50);
      final normal = WavCodec.encodePcm16(fixture.audio);

      // Splice a LIST chunk between `fmt ` and `data`, as real encoders do.
      final listChunk = Uint8List.fromList([
        ...'LIST'.codeUnits,
        4, 0, 0, 0,
        ...'INFO'.codeUnits,
      ]);
      final spliced = Uint8List.fromList([
        ...normal.sublist(0, 36),
        ...listChunk,
        ...normal.sublist(36),
      ]);
      // Fix the RIFF size field.
      ByteData.sublistView(spliced)
          .setUint32(4, spliced.length - 8, Endian.little);

      final decoded = WavCodec.decode(spliced);
      expect(decoded.frameCount, fixture.audio.frameCount);
    });

    test('downmixes stereo to mono', () {
      // Hand-build a 2-channel float file: L = +1, R = -1 => mono 0.
      final frames = 10;
      final data = Uint8List(44 + frames * 2 * 4);
      final view = ByteData.sublistView(data);
      void tag(int o, String s) {
        for (var i = 0; i < 4; i++) {
          data[o + i] = s.codeUnitAt(i);
        }
      }

      tag(0, 'RIFF');
      view.setUint32(4, data.length - 8, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      view.setUint32(16, 16, Endian.little);
      view.setUint16(20, 3, Endian.little); // IEEE float
      view.setUint16(22, 2, Endian.little); // stereo
      view.setUint32(24, kRate, Endian.little);
      view.setUint32(28, kRate * 8, Endian.little);
      view.setUint16(32, 8, Endian.little);
      view.setUint16(34, 32, Endian.little);
      tag(36, 'data');
      view.setUint32(40, frames * 2 * 4, Endian.little);

      for (var f = 0; f < frames; f++) {
        view.setFloat32(44 + f * 8, 1.0, Endian.little);
        view.setFloat32(44 + f * 8 + 4, -1.0, Endian.little);
      }

      final decoded = WavCodec.decode(data);
      expect(decoded.frameCount, frames);
      for (final s in decoded.samples) {
        expect(s, closeTo(0.0, 1e-6));
      }
    });

    test('rejects a non-WAV file clearly', () {
      expect(
        () => WavCodec.decode(Uint8List.fromList('not a wav at all'.codeUnits)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
