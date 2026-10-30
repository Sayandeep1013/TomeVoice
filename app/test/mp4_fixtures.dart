// Minimal MP4 files, laid out as MediaMuxer can leave them, and ways to
// read back what was written into them: for the chapter-mark tests and the
// save's.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/mp4_chapters.dart';

/// The audio in the fake files' mdat.
final fakeAudio = [for (var i = 0; i < 4000; i++) (i * 7) & 0xFF];

/// A minimal MP4, as MediaMuxer can leave one: ftyp, then a moov whose stco
/// points at the audio in mdat, either first (with [room] bytes of free
/// space after it) or last. [userData] is a udta to put in moov.
({Uint8List bytes, int mdatAt}) fakeMp4({required bool moovFirst, int room = 0, Uint8List? userData}) {
  final ftyp = mp4Box('ftyp', [...ascii.encode('M4A '), 0, 0, 0, 0, ...ascii.encode('M4A isom')]);
  Uint8List moov(int chunkAt) => mp4Box('moov', [
        ...mp4Box('mvhd', List.filled(100, 0)),
        ...mp4Box(
            'trak',
            mp4Box(
                'mdia',
                mp4Box(
                    'minf',
                    mp4Box(
                        'stbl',
                        mp4Box('stco', [0, 0, 0, 0, 0, 0, 0, 1, ...(ByteData(4)..setUint32(0, chunkAt)).buffer.asUint8List()]))))),
        ...?userData,
      ]);
  final mdat = mp4Box('mdat', fakeAudio);
  if (!moovFirst) {
    final at = ftyp.length;
    return (bytes: Uint8List.fromList([...ftyp, ...mdat, ...moov(at + 8)]), mdatAt: at);
  }
  final at = ftyp.length + moov(0).length + room;
  final free = room == 0 ? const <int>[] : mp4Box('free', List.filled(room - 8, 0));
  return (bytes: Uint8List.fromList([...ftyp, ...moov(at + 8), ...free, ...mdat]), mdatAt: at);
}

/// The box down [types] from [box].
Mp4Box boxAt(Uint8List b, Mp4Box box, List<String> types) {
  var at = box;
  for (final t in types) {
    at = mp4Children(b, at.offset + at.header, at.end).firstWhere((c) => c.type == t);
  }
  return at;
}

/// A chpl box's chapters: (start in 100 ns, title).
List<(int, String)> chaptersIn(Uint8List b, Mp4Box chpl) {
  final d = ByteData.sublistView(b);
  expect(b[chpl.offset + 8], 1, reason: 'not version 1');
  var at = chpl.offset + 16;
  final n = b[at++];
  final out = <(int, String)>[];
  for (var i = 0; i < n; i++) {
    final start = d.getUint64(at);
    final length = b[at + 8];
    out.add((start, utf8.decode(b.sublist(at + 9, at + 9 + length))));
    at += 9 + length;
  }
  expect(at, chpl.end, reason: 'the box holds more than its chapters');
  return out;
}
