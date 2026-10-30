// Chapter marks and tags written into an MP3 after it is made: an ID3v2.3
// tag before the audio, its chapters as CHAP frames listed by a CTOC, put
// into the room the encoder left so the audio never moves, or before the
// audio in a copy when there is none.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/mp3_chapters.dart';
import 'package:tomevoice_spike/mp4_chapters.dart';

import 'mp3_fixtures.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('tomevoice_mp3'));
  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  final marks = [
    const ChapterMark(Duration.zero, 'Chapter 1: Arrival'),
    const ChapterMark(Duration(seconds: 31, milliseconds: 250), 'Chapter 2: Night'),
    const ChapterMark(Duration(hours: 9, minutes: 59), 'Chapter 3: Morning'),
  ];
  const length = Duration(hours: 10, seconds: 5);
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(300, 7)]);
  final tags = AudioTags(title: 'Emma', artist: 'Jane Austen', album: 'Emma', genre: 'Audiobook', cover: jpeg);

  group('the tag', () {
    test('ID3v2.3: a header with its size in seven-bit bytes, the frames in order, then padding', () {
      final b = id3Tag(tags: tags, marks: marks, length: length, padding: 100);
      expect(b.sublist(0, 6), [0x49, 0x44, 0x33, 3, 0, 0]);
      // 7 bits a byte, the high bit always clear, the ten-byte header not counted.
      expect(b.sublist(6, 10).every((x) => x < 0x80), isTrue);
      expect((b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9], b.length - 10);
      expect(b[8], greaterThan(0), reason: 'a tag of more than 127 bytes needs the second byte');
      expect(id3Size(b), b.length);
      final frames = id3FramesIn(b);
      expect(frames.map((f) => f.id), ['TIT2', 'TPE1', 'TALB', 'TCON', 'APIC', 'CTOC', 'CHAP', 'CHAP', 'CHAP']);
      // A 2.3 frame's size is a plain 32-bit number: the cover's is over 127.
      final at = _offsetOf(b, 'APIC');
      expect(ByteData.sublistView(b).getUint32(at + 4), frames[4].data.length);
      expect(frames[4].data.length, greaterThan(300));
      expect(b.sublist(b.length - 100).every((x) => x == 0), isTrue, reason: 'the padding is not zeros');
      expect(id3Tag(tags: tags, marks: marks, length: length, size: 9000).length, 9000);
      expect(id3Tag(tags: tags, marks: marks, length: length, size: 20).length, b.length - 100,
          reason: 'a size too small for the frames was taken');
    });

    test('tags: title, author, album and genre as text, Latin-1 where it holds them, else UTF-16', () {
      final e = String.fromCharCode(0xC9);
      final bengali = String.fromCharCodes([0x0986, 0x09AE, 0x09BF]);
      final face = String.fromCharCodes([0xD83D, 0xDE00]);
      final b = id3Tag(tags: AudioTags(title: '${e}mile', artist: bengali, album: 'Smile $face', genre: '  '));
      final frames = id3FramesIn(b);
      expect(frames.map((f) => f.id), ['TIT2', 'TPE1', 'TALB'], reason: 'a blank genre was written');
      expect(frames[0].data, [0, 0xC9, ...ascii.encode('mile')], reason: 'not Latin-1, unterminated');
      expect(frames[1].data, [1, 0xFF, 0xFE, 0x86, 0x09, 0xAE, 0x09, 0xBF, 0x09], reason: 'not UTF-16LE after its mark');
      expect(textOf(frames[1].data), bengali);
      expect(textOf(frames[2].data), 'Smile $face', reason: 'a letter beyond 16 bits lost its pair');
      expect(id3FramesIn(id3Tag(padding: 10)), isEmpty);
    });

    test('the cover: its type, the front cover, no description, the picture as it is', () {
      final apic = id3FramesIn(id3Tag(tags: tags)).singleWhere((f) => f.id == 'APIC').data;
      expect(apic, [0, ...ascii.encode('image/jpeg'), 0, 3, 0, ...jpeg]);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2]);
      final p = id3FramesIn(id3Tag(tags: AudioTags(cover: png))).single;
      expect(p.data.sublist(0, 11), [0, ...ascii.encode('image/png'), 0]);
      expect(id3FramesIn(id3Tag(tags: AudioTags(title: 'x', cover: Uint8List.fromList([1, 2, 3, 4])))).map((f) => f.id),
          ['TIT2'], reason: 'something that is not a picture went in as the cover');
    });

    test('chapters: a CHAP each, to the start of the next, the last to the end; a CTOC lists them in order', () {
      final b = id3Tag(marks: marks, length: length);
      final frames = id3FramesIn(b);
      final chap = frames.firstWhere((f) => f.id == 'CHAP').data;
      // Its element id, start and end in ms, no byte offsets, then its title.
      expect(chap.sublist(0, 4), [...ascii.encode('ch0'), 0]);
      expect(chap.sublist(4, 20), [0, 0, 0, 0, 0, 0, 0x7A, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      expect(chap.sublist(20, 30), [...ascii.encode('TIT2'), 0, 0, 0, 19, 0, 0]);
      expect(chap.sublist(30), [0, ...ascii.encode('Chapter 1: Arrival')]);
      final second = chapterIn(frames.where((f) => f.id == 'CHAP').elementAt(1).data);
      expect((second.startByte, second.endByte), (0xFFFFFFFF, 0xFFFFFFFF));
      expect(id3ChaptersIn(b), [
        (0, 31250, 'Chapter 1: Arrival'),
        (31250, 35940000, 'Chapter 2: Night'),
        (35940000, 36005000, 'Chapter 3: Morning'),
      ]);
      final toc = frames.singleWhere((f) => f.id == 'CTOC').data;
      expect(toc, [...ascii.encode('toc'), 0, 3, 3, ...ascii.encode('ch0'), 0, ...ascii.encode('ch1'), 0, ...ascii.encode('ch2'), 0],
          reason: 'not one top-level, ordered table of the three');
      expect(id3FramesIn(id3Tag(tags: tags)).map((f) => f.id), isNot(contains('CTOC')), reason: 'contents with no chapters');
    });

    test('a chapter ending before it starts is made to end where it starts; more than 255 chapters keep the first 255', () {
      final short = id3ChaptersIn(id3Tag(marks: marks, length: const Duration(hours: 1)));
      expect(short.last, (35940000, 35940000, 'Chapter 3: Morning'));
      final many = id3Tag(marks: [for (var i = 0; i < 300; i++) ChapterMark(Duration(seconds: i), '$i')], length: length);
      final listed = id3ChaptersIn(many);
      expect(listed, hasLength(255));
      expect(listed.last, (254000, 36005000, '254'));
    });
  });

  group('into the file', () {
    test('the room left before the times are known holds the tag once they are', () {
      final room = id3Room(tags, [for (final m in marks) m.title]);
      final made = id3Tag(tags: tags, marks: marks, length: length);
      expect(room, made.length + id3Padding, reason: 'the times changed the size');
      // A chapter with nothing said gives its mark to the next: fewer fit too.
      expect(id3Tag(tags: tags, marks: marks.sublist(1), length: length).length, lessThan(room));
    });

    test('written into the room: the audio unmoved, the rest padding, the file no larger', () async {
      final room = id3Room(tags, [for (final m in marks) m.title]);
      final made = fakeMp3(room: room);
      final f = File('${_dir.path}/book.mp3')..writeAsBytesSync(made.bytes);
      await writeId3(f.path, tags: tags, marks: marks, length: length);
      final b = f.readAsBytesSync();
      expect(b.length, made.bytes.length, reason: 'the file grew');
      expect(id3Size(b), room, reason: 'the tag is not the size of the room');
      expect(b.sublist(room), fakeFrames, reason: 'the audio moved or changed');
      expect(id3FramesIn(b).map((x) => x.id), ['TIT2', 'TPE1', 'TALB', 'TCON', 'APIC', 'CTOC', 'CHAP', 'CHAP', 'CHAP']);
      expect(id3ChaptersIn(b).map((c) => c.$3), [for (final m in marks) m.title]);
      // Written again (fewer chapters): the same room, the old frames gone.
      await writeId3(f.path, tags: const AudioTags(title: 'Emma'), marks: marks.sublist(0, 1), length: length);
      final again = f.readAsBytesSync();
      expect(again.length, made.bytes.length);
      expect(id3FramesIn(again).map((x) => x.id), ['TIT2', 'CTOC', 'CHAP']);
      expect(again.sublist(room), fakeFrames);
    });

    test('no room, or too little: the tag goes before the audio, which follows unchanged', () async {
      for (final room in [0, 64]) {
        final made = fakeMp3(room: room);
        final f = File('${_dir.path}/r$room.mp3')..writeAsBytesSync(made.bytes);
        await writeId3(f.path, tags: tags, marks: marks, length: length);
        final b = f.readAsBytesSync();
        final size = id3Size(b);
        expect(size, id3Tag(tags: tags, marks: marks, length: length).length + id3Padding, reason: 'room $room');
        expect(b.sublist(size), fakeFrames, reason: 'the audio after the tag is not the audio (room $room)');
        expect(id3ChaptersIn(b), hasLength(3));
        expect(File('${f.path}.tagged').existsSync(), isFalse, reason: 'the copy was left behind');
      }
    });

    test("a tag's size is read from its header; anything else is no tag", () {
      expect(id3Size(id3Tag(padding: 5)), 15);
      expect(id3Size(fakeFrames), 0);
      expect(id3Size(ascii.encode('ID3')), 0, reason: 'too short');
      expect(id3Size([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0x80, 0]), 0, reason: 'a size byte with its high bit set');
      expect(id3Size([0x49, 0x44, 0x33, 9, 0, 0, 0, 0, 1, 0]), 0, reason: 'a version there is none of');
      expect(id3Size([0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 1, 0]), 10 + 128 + 10, reason: "a 2.4 tag's footer");
    });
  });
}

/// Where the frame [id] starts in the tag [b].
int _offsetOf(Uint8List b, String id) {
  final code = ascii.encode(id);
  for (var at = 10; at + 4 <= b.length; at++) {
    if (b[at] == code[0] && b[at + 1] == code[1] && b[at + 2] == code[2] && b[at + 3] == code[3]) return at;
  }
  return -1;
}
