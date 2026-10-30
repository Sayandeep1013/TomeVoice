// OCR language data downloads, from a local server: going on from where a
// cut-off one stopped, a stall, being called off, and files that are not
// what they should be kept off the phone. No Flutter test binding here: it
// answers every HTTP request with a 400.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ocr.dart';

/// A traineddata file as tessdata_fast has them: a count of entries, where
/// each starts (-1 for none), then the entries.
Uint8List traineddata(int size) {
  final b = ByteData(size);
  const n = 24;
  b.setInt32(0, n, Endian.little);
  for (var i = 0; i < n; i++) {
    b.setInt64(4 + 8 * i, i < 17 ? -1 : 4 + 8 * n + (i - 17) * 1000, Endian.little);
  }
  final r = math.Random(7);
  for (var i = 4 + 8 * n; i < size; i++) {
    b.setUint8(i, r.nextInt(256));
  }
  return b.buffer.asUint8List();
}

void main() {
  const lang = OcrLanguage('tst', 'Test', 200 * 1024);
  late Directory root;
  late HttpServer server;
  late Uint8List body;

  /// How the server answers: cut off after this many bytes (null: all of
  /// it), or hang after the first few.
  int? cutAfter;
  var hang = false;
  final ranges = <String?>[];
  final encodings = <String?>[];
  final held = <Socket>[];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tomevoice_ocr_data');
    OcrData.instance.attach(root);
    body = traineddata(lang.bytes);
    cutAfter = null;
    hang = false;
    ranges.clear();
    encodings.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      encodings.add(req.headers.value(HttpHeaders.acceptEncodingHeader));
      final from = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final res = req.response;
      if (from > 0) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${body.length - 1}/${body.length}');
      }
      res.contentLength = body.length - from;
      final end = hang ? from + 10 : (cutAfter == null ? body.length : (from + cutAfter!).clamp(0, body.length));
      if (end == body.length) {
        res.add(body.sublist(from));
        await res.close();
        return;
      }
      // The headers promise the whole file; the socket, taken over, sends
      // part of it and then drops (or just stops).
      final socket = await res.detachSocket();
      socket.add(body.sublist(from, end));
      await socket.flush();
      if (hang) {
        held.add(socket);
      } else {
        socket.destroy();
      }
    });
  });

  tearDown(() async {
    for (final s in held) {
      s.destroy();
    }
    held.clear();
    await server.close(force: true);
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  Uri at() => Uri.parse('http://${server.address.address}:${server.port}/tst.traineddata');

  List<FileSystemEntity> parts() => root.listSync(recursive: true).where((e) => e.path.endsWith('.part')).toList();

  test('a download cut off goes on from where it stopped, and the file is whole', () async {
    cutAfter = body.length ~/ 2;
    await expectLater(OcrData.instance.download(lang, source: at()), throwsA(anything));
    expect(OcrData.instance.installed(lang), isFalse);
    expect(parts(), hasLength(1), reason: 'what came is kept');

    cutAfter = null;
    await OcrData.instance.download(lang, source: at());
    expect(ranges.last, 'bytes=${body.length ~/ 2}-', reason: 'it started again from nothing');
    expect(OcrData.instance.installed(lang), isTrue);
    expect(OcrData.instance.fileOf(lang).readAsBytesSync(), body);
    expect(OcrData.instance.fileOf(lang).path, endsWith('/ocr/tessdata/tst.traineddata'));
    expect(parts(), isEmpty);
    expect(encodings.toSet(), {'identity'}, reason: 'sizes and ranges count the bytes of the file itself');
    expect(OcrData.instance.downloading, isEmpty);
  });

  test('a stalled download stops, rather than waiting for ever', () async {
    hang = true;
    await expectLater(
      OcrData.instance.download(lang, source: at(), stall: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(OcrData.instance.downloading, isEmpty);
  });

  test('a download can be called off at once, and leaves nothing behind', () async {
    hang = true;
    final going = OcrData.instance.download(lang, source: at(), stall: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(OcrData.instance.downloading, contains('tst'));
    final watch = Stopwatch()..start();
    OcrData.instance.cancel(lang);
    await expectLater(going, throwsA(isA<OcrDownloadCancelled>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'it waited for data that never came');
    expect(OcrData.instance.downloading, isEmpty);
    expect(parts(), isEmpty);
  });

  test('a file of another size, or not a traineddata file, is not kept', () async {
    final short = OcrLanguage('tst', 'Test', lang.bytes - 1);
    await expectLater(OcrData.instance.download(short, source: at()), throwsA(isA<FormatException>()));
    expect(parts(), isEmpty);

    // The right size, but a web page (a captive portal, say).
    body = Uint8List.fromList(utf8.encode('<html>${' ' * (lang.bytes - 13)}</html>'));
    expect(body.length, lang.bytes);
    await expectLater(OcrData.instance.download(lang, source: at()), throwsA(isA<FormatException>()));
    expect(OcrData.instance.installed(lang), isFalse);
    expect(parts(), isEmpty, reason: 'a damaged file is not worth going on from');
  });

  test('two asking for the same language share one download; one on the phone is not fetched', () async {
    final a = OcrData.instance.download(lang, source: at());
    final b = OcrData.instance.download(lang, source: at());
    await Future.wait([a, b]);
    expect(ranges, hasLength(1));
    expect(OcrData.instance.installed(lang), isTrue);
    await OcrData.instance.download(lang, source: at());
    expect(ranges, hasLength(1));
  });

  test('several languages are fetched one after another, with one progress to the end', () async {
    const other = OcrLanguage('ts2', 'Test two', 200 * 1024);
    final seen = <double>[];
    await OcrData.instance.ensure([lang, other], onProgress: seen.add, source: (_) => at());
    expect(OcrData.instance.installed(lang) && OcrData.instance.installed(other), isTrue);
    expect(seen.last, 1.0);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'it never goes back');
    }
    expect(seen, contains(0.5), reason: 'half way when the first is in');

    seen.clear();
    await OcrData.instance.ensure([lang, other], onProgress: seen.add, source: (_) => at());
    expect(seen, [1.0], reason: 'nothing more to fetch');
    expect(ranges, hasLength(2));

    // Data that would not load is taken off, to be fetched again.
    await OcrData.instance.remove([lang]);
    expect(OcrData.instance.installed(lang), isFalse);
    expect(OcrData.instance.installed(other), isTrue);
  });
}
