// Chapter marks and tags written into an MP4 after it is made: a Nero chpl
// box (and iTunes tags) in moov/udta, moov placed so the audio never moves
// and the offsets into it stay right, whichever way MediaMuxer laid it out.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/mp4_chapters.dart';

import 'mp4_fixtures.dart';

late Directory _dir;

void main() {
  setUp(() => _dir = Directory.systemTemp.createTempSync('tomevoice_mp4'));
  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('chapter marks and tags in the file', () {
    final marks = [
      const ChapterMark(Duration.zero, 'Chapter 1: Arrival'),
      const ChapterMark(Duration(seconds: 31, milliseconds: 250), 'Chapter 2: Night'),
      const ChapterMark(Duration(hours: 9, minutes: 59), 'Chapter 3: Morning'),
    ];

    /// Patch [made] as a file, then check it: its boxes fill it exactly, the
    /// audio has not moved, the chunk offset still points at it, and moov
    /// holds [marks]. Returns the top boxes' types.
    Future<List<String>> patched(({Uint8List bytes, int mdatAt}) made) async {
      final f = File('${_dir.path}/book.m4b')..writeAsBytesSync(made.bytes);
      await writeChaptersAndTags(f.path, marks: marks, tags: const AudioTags(title: 'The Book', audiobook: true));
      final b = f.readAsBytesSync();
      final top = mp4Children(b, 0, b.length);
      final mdat = top.singleWhere((x) => x.type == 'mdat');
      expect(mdat.offset, made.mdatAt, reason: 'the audio moved');
      expect(b.sublist(mdat.offset + 8, mdat.end), fakeAudio);
      final moov = top.singleWhere((x) => x.type == 'moov');
      final stco = boxAt(b, moov, ['trak', 'mdia', 'minf', 'stbl', 'stco']);
      expect(ByteData.sublistView(b).getUint32(stco.offset + 16), made.mdatAt + 8,
          reason: 'the chunk offset no longer points at the audio');
      final udta = boxAt(b, moov, ['udta']);
      expect(chaptersIn(b, boxAt(b, udta, ['chpl'])), [for (final m in marks) (m.start.inMicroseconds * 10, m.title)]);
      expect(mp4Children(b, udta.offset + 8, udta.end).map((c) => c.type), contains('meta'));
      return [for (final x in top) x.type];
    }

    test('moov last: written where it was, the audio untouched', () async {
      expect(await patched(fakeMp4(moovFirst: false)), ['ftyp', 'mdat', 'moov']);
    });

    test("moov first with room after it, as MediaMuxer leaves it: into the room, the rest still free", () async {
      final made = fakeMp4(moovFirst: true, room: 4096);
      expect(await patched(made), ['ftyp', 'moov', 'free', 'mdat']);
      expect(File('${_dir.path}/book.m4b').lengthSync(), made.bytes.length, reason: 'the file grew');
    });

    test('moov first with no room: the old one becomes free space, the new one goes last', () async {
      expect(await patched(fakeMp4(moovFirst: true)), ['ftyp', 'free', 'mdat', 'moov']);
      expect(await patched(fakeMp4(moovFirst: true, room: 16)), ['ftyp', 'free', 'free', 'mdat', 'moov']);
    });

    test("user data already there is kept; old chapters are replaced, not added to", () async {
      final old = mp4Box('udta', [
        ...mp4Box('XYZ ', const [1, 2, 3]),
        ...chplBox(const [ChapterMark(Duration.zero, 'Old')]),
      ]);
      await patched(fakeMp4(moovFirst: false, userData: old));
      final b = File('${_dir.path}/book.m4b').readAsBytesSync();
      final moov = mp4Children(b, 0, b.length).singleWhere((x) => x.type == 'moov');
      expect(mp4Children(b, moov.offset + 8, moov.end).where((c) => c.type == 'udta'), hasLength(1));
      final udta = boxAt(b, moov, ['udta']);
      expect(mp4Children(b, udta.offset + 8, udta.end).map((c) => c.type), ['XYZ ', 'chpl', 'meta']);
    });

    test('a chpl box: version 1, a one-byte count, starts in 100 ns, titles cut at 255 bytes between characters',
        () {
      final e = String.fromCharCode(0xE9);
      final b = chplBox([const ChapterMark(Duration(milliseconds: 1500), 'One'), ChapterMark(const Duration(hours: 10), e * 200)]);
      final d = ByteData.sublistView(b);
      expect(latin1.decode(b.sublist(4, 8)), 'chpl');
      expect(b.sublist(8, 17), [1, 0, 0, 0, 0, 0, 0, 0, 2]);
      expect(d.getUint64(17), 15000000);
      expect(b[25], 3);
      expect(utf8.decode(b.sublist(26, 29)), 'One');
      expect(d.getUint64(29), 10 * 3600 * 10000000);
      // 200 of a two-byte letter: 127 fit, the 128th would be cut in half.
      expect(b[37], 254);
      expect(utf8.decode(b.sublist(38, 38 + 254)), e * 127);
      expect(b.length, 38 + 254);
      expect(chplBox([for (var i = 0; i < 300; i++) ChapterMark(Duration(seconds: i), '$i')])[16], 255);
    });

    test('tags: title, author, album, genre, an audiobook, and the cover', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final meta = metaBox(AudioTags(
        title: 'Emma',
        artist: 'Jane Austen',
        album: 'Emma',
        genre: 'Audiobook',
        cover: jpeg,
        audiobook: true,
      ));
      final box = mp4Children(meta, 0, meta.length).single;
      // A full box: version and flags before its children.
      final kids = mp4Children(meta, box.offset + 12, box.end);
      expect(kids.map((k) => k.type), ['hdlr', 'ilst']);
      expect(latin1.decode(meta.sublist(kids[0].offset + 16, kids[0].offset + 20)), 'mdir');
      final items = mp4Children(meta, kids[1].offset + 8, kids[1].end);
      final c = String.fromCharCode(0xA9);
      expect(items.map((i) => i.type), ['${c}nam', '${c}ART', '${c}alb', '${c}gen', 'stik', 'covr']);
      Uint8List data(int k) {
        final d = mp4Children(meta, items[k].offset + 8, items[k].end).single;
        expect(d.type, 'data');
        return meta.sublist(d.offset + 8, d.end);
      }

      expect(data(1), [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode('Jane Austen')]);
      expect(data(4), [0, 0, 0, 21, 0, 0, 0, 0, 2]);
      expect(data(5), [0, 0, 0, 13, 0, 0, 0, 0, ...jpeg]);
    });
  });
}
