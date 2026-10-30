// Minimal MP3 files, laid out as AudioExport.kt leaves them, and ways to
// read back the ID3v2.3 tag written into them: for the tag tests and the
// save's.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/mp3_chapters.dart';

/// The fake files' audio: a frame header's sync bits, then a pattern.
final fakeFrames = [0xFF, 0xF3, 0x84, 0xC4, for (var i = 0; i < 3000; i++) (i * 11) & 0xFF];

/// A minimal MP3, as AudioExport.kt leaves one: an empty ID3v2.3 tag of
/// [room] bytes (none for 0), padding only, then the audio.
({Uint8List bytes, int audioAt}) fakeMp3({int room = 0}) {
  final head = Uint8List(room);
  if (room >= 10) {
    head.setRange(0, 4, [0x49, 0x44, 0x33, 3]);
    final n = room - 10;
    head.setRange(6, 10, [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]);
  }
  return (bytes: Uint8List.fromList([...head, ...fakeFrames]), audioAt: room);
}

/// The frames of the ID3v2.3 tag [b] starts with, checked as they are
/// read: the header, each frame inside the tag, only zeros after them.
List<({String id, Uint8List data})> id3FramesIn(Uint8List b) {
  expect(latin1.decode(b.sublist(0, 3)), 'ID3');
  expect(b.sublist(3, 6), [3, 0, 0], reason: 'not version 2.3 with no flags');
  final end = id3Size(b);
  expect(end, greaterThan(10));
  return framesIn(b, 10, end);
}

/// The frames from [from] to [to] (a tag's, or a chapter's own), the rest
/// padding.
List<({String id, Uint8List data})> framesIn(Uint8List b, int from, int to) {
  final d = ByteData.sublistView(b);
  final out = <({String id, Uint8List data})>[];
  var at = from;
  while (at + 10 <= to && b[at] != 0) {
    final size = d.getUint32(at + 4);
    expect(b.sublist(at + 8, at + 10), [0, 0], reason: 'a frame with flags');
    expect(at + 10 + size, lessThanOrEqualTo(to), reason: 'a frame runs past the tag');
    out.add((id: ascii.decode(b.sublist(at, at + 4)), data: b.sublist(at + 10, at + 10 + size)));
    at += 10 + size;
  }
  expect(b.sublist(at, to).every((x) => x == 0), isTrue, reason: 'something other than padding after the frames');
  return out;
}

/// A text frame's text: Latin-1, or UTF-16 after its byte order mark.
String textOf(Uint8List data) {
  if (data.isEmpty) return '';
  if (data[0] == 0) return latin1.decode(data.sublist(1));
  expect(data[0], 1, reason: 'an encoding 2.3 does not have');
  final b = data.sublist(1);
  final little = b[0] == 0xFF && b[1] == 0xFE;
  expect(little || (b[0] == 0xFE && b[1] == 0xFF), isTrue, reason: 'UTF-16 with no byte order mark');
  return String.fromCharCodes([
    for (var i = 2; i + 1 < b.length; i += 2) little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
  ]);
}

/// A null-terminated Latin-1 string in [b] from [at], and where it ends.
(String, int) _cString(Uint8List b, int at) {
  final end = b.indexOf(0, at);
  expect(end, greaterThanOrEqualTo(0), reason: 'a string with no end');
  return (latin1.decode(b.sublist(at, end)), end + 1);
}

/// A CHAP frame's element id, start and end (ms), byte offsets and title.
({String id, int start, int end, int startByte, int endByte, String? title}) chapterIn(Uint8List data) {
  final (id, at) = _cString(data, 0);
  final d = ByteData.sublistView(data);
  final sub = framesIn(data, at + 16, data.length);
  final title = sub.where((f) => f.id == 'TIT2').map((f) => textOf(f.data)).firstOrNull;
  return (
    id: id,
    start: d.getUint32(at),
    end: d.getUint32(at + 4),
    startByte: d.getUint32(at + 8),
    endByte: d.getUint32(at + 12),
    title: title,
  );
}

/// A CTOC frame's element id, flags and the chapters it lists.
({String id, int flags, List<String> children}) contentsIn(Uint8List data) {
  var (id, at) = _cString(data, 0);
  final flags = data[at];
  final n = data[at + 1];
  at += 2;
  final children = <String>[];
  for (var i = 0; i < n; i++) {
    final (child, next) = _cString(data, at);
    children.add(child);
    at = next;
  }
  expect(at, data.length, reason: 'the table of contents holds more than its chapters');
  return (id: id, flags: flags, children: children);
}

/// The chapters of the tag [b] starts with: (start, end, title), in the
/// order its table of contents lists them.
List<(int, int, String?)> id3ChaptersIn(Uint8List b) {
  final frames = id3FramesIn(b);
  final toc = contentsIn(frames.singleWhere((f) => f.id == 'CTOC').data);
  final chapters = {
    for (final f in frames.where((f) => f.id == 'CHAP'))
      chapterIn(f.data).id: chapterIn(f.data),
  };
  expect(chapters.keys.toSet(), toc.children.toSet(), reason: 'the contents and the chapters disagree');
  return [for (final id in toc.children) (chapters[id]!.start, chapters[id]!.end, chapters[id]!.title)];
}
