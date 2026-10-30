import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tomevoice_document/tomevoice_document.dart';

/// [head] then [length] bytes of [fill].
Uint8List _file(List<int> head, {int length = 3000, int Function(int i)? fill}) =>
    Uint8List.fromList([...head, for (var i = 0; i < length; i++) fill?.call(i) ?? 0]);

/// Bytes that look like compressed audio or image data.
int _noise(int i) => (i * 131 + 7) % 251;

Matcher _refused(String why) =>
    throwsA(isA<UnsupportedDocumentException>().having((e) => e.message, 'message', contains(why)));

void main() {
  group('audio and pictures are known by their first bytes', () {
    final id3 = _file([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00]);

    test('an MP3 with an ID3 header is refused as audio, whatever it is called', () {
      expect(mediaKindOf(id3), MediaKind.audio);
      expect(detectFormat(id3, filename: 'song.mp3'), SourceKind.unknown);
      for (final name in ['song.mp3', 'song.txt', 'song']) {
        expect(() => ingestBytes(id3, filename: name), _refused('already audio'), reason: name);
      }
    });

    test('other audio', () {
      final cases = {
        'mpeg frame': _file([0xFF, 0xFB, 0x90, 0x64], fill: _noise),
        'flac': _file('fLaC'.codeUnits, fill: _noise),
        'ogg': _file('OggS'.codeUnits, fill: _noise),
        'wav': _file([...'RIFF'.codeUnits, 0x24, 0x08, 0, 0, ...'WAVE'.codeUnits], fill: _noise),
        'm4b': _file([0, 0, 0, 0x20, ...'ftypM4B '.codeUnits], fill: _noise),
        'mp4': _file([0, 0, 0, 0x20, ...'ftypisom'.codeUnits], fill: _noise),
      };
      for (final e in cases.entries) {
        expect(mediaKindOf(e.value), MediaKind.audio, reason: e.key);
        expect(() => ingestBytes(e.value, filename: 'file.bin'), _refused('already audio'), reason: e.key);
      }
    });

    test('a PNG and a JPEG are refused as pictures, whatever they are called', () {
      final png = _file([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], fill: _noise);
      final jpeg = _file([0xFF, 0xD8, 0xFF, 0xE0], fill: _noise);
      for (final bytes in [png, jpeg]) {
        expect(mediaKindOf(bytes), MediaKind.picture);
        expect(() => ingestBytes(bytes, filename: 'scan.txt'), _refused('picture-based'));
      }
    });

    test('other pictures', () {
      final cases = {
        'gif': _file('GIF89a'.codeUnits, fill: _noise),
        'webp': _file([...'RIFF'.codeUnits, 0x24, 0x08, 0, 0, ...'WEBP'.codeUnits], fill: _noise),
        'bmp': _file([0x42, 0x4D, 0x36, 0x10, 0x0E, 0, 0, 0, 0, 0, 0x36, 0, 0, 0], fill: _noise),
        'djvu': _file('AT&TFORM'.codeUnits, fill: _noise),
        'tiff': _file([0x49, 0x49, 0x2A, 0x00], fill: _noise),
        'heic': _file([0, 0, 0, 0x18, ...'ftypheic'.codeUnits], fill: _noise),
      };
      for (final e in cases.entries) {
        expect(mediaKindOf(e.value), MediaKind.picture, reason: e.key);
      }
    });

    test('a comic book zip with any name is pictures', () {
      final a = Archive();
      for (var i = 0; i < 5; i++) {
        a.addFile(ArchiveFile.bytes('page$i.jpg', [0xFF, 0xD8, 0xFF, 0xE0, i]));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(a));
      expect(() => ingestBytes(bytes, filename: 'comic.zip'), _refused('picture-based'));
    });

    test('text that starts with the same letters is still text', () {
      for (final t in ['ID3 tags explained. They hold a song title.', 'BMW makes cars. They are fast.', 'GIF8 is not a word.']) {
        final book = ingestBytes(Uint8List.fromList(utf8.encode(t)), filename: 'notes.txt');
        expect(book.sections.first.blocks.first.text, t);
      }
    });
  });

  group('binary', () {
    test('a header and a run of zeros is not text', () {
      expect(looksBinary(_file('Hello'.codeUnits)), isTrue);
      expect(() => ingestBytes(_file('Hello'.codeUnits), filename: 'x.txt'), throwsA(isA<UnsupportedDocumentException>()));
    });

    test('control characters in quantity are not text', () {
      final bytes = Uint8List.fromList([for (var i = 0; i < 2000; i++) i % 10 == 0 ? 0x07 : 0x61]);
      expect(looksBinary(bytes), isTrue);
    });

    test('UTF-16 text, tabs, form feeds and escape sequences are text', () {
      final utf16 = Uint8List.fromList([for (final c in 'Hello there, a line of text.'.codeUnits) ...[c, 0]]);
      expect(looksBinary(utf16), isFalse);
      // Tab, form feed, CR LF, and ISO-2022-JP's ESC ( B.
      final controls = <int>[
        ...'Col'.codeUnits, 0x09, ...'umn'.codeUnits, 0x0C, ...'page'.codeUnits, 0x0D, 0x0A,
        ...'next'.codeUnits, 0x1B, 0x28, 0x42, ...'line'.codeUnits,
      ];
      expect(looksBinary(Uint8List.fromList(controls)), isFalse);
    });
  });
}
