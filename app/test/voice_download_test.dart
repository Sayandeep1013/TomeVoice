// Natural voice downloads: going on from where a cut-off one stopped,
// calling one off, a stall, and a damaged archive kept off the phone.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/neural_voices.dart';

/// A voice's archive, as the release has it: one top folder with the model,
/// its tokens and its pronunciation data.
Uint8List archiveOf(NeuralVoice v) {
  final a = Archive()
    ..addFile(ArchiveFile.bytes('vits-piper-${v.id}/${v.id}.onnx', Uint8List(1500 * 1024)))
    ..addFile(ArchiveFile.string('vits-piper-${v.id}/tokens.txt', 'a 1\nb 2\n'))
    ..addFile(ArchiveFile.string('vits-piper-${v.id}/espeak-ng-data/phontab', 'x'));
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(a));
}

void main() {
  final voice = neuralVoices.first;
  late Directory root;
  late HttpServer server;
  late Uint8List body;

  /// How the server answers: cut off after this many bytes (null: all of
  /// it), or hang after the first few.
  int? cutAfter;
  var hang = false;
  final ranges = <String?>[];
  final held = <Socket>[];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('tomevoice_voices');
    NeuralVoices.instance.attach(root);
    body = archiveOf(voice);
    cutAfter = null;
    hang = false;
    ranges.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
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

  Uri at() => Uri.parse('http://${server.address.address}:${server.port}/voice.tar.bz2');

  test('a download cut off goes on from where it stopped, and the voice is whole', () async {
    cutAfter = body.length ~/ 2;
    await expectLater(NeuralVoices.instance.download(voice, source: at()), throwsA(anything));
    expect(NeuralVoices.instance.installed(voice), isFalse);

    cutAfter = null;
    await NeuralVoices.instance.download(voice, source: at());
    expect(ranges.last, 'bytes=${body.length ~/ 2}-', reason: 'it started again from nothing');
    expect(NeuralVoices.instance.installed(voice), isTrue);
    expect(File('${NeuralVoices.instance.folder(voice).path}/tokens.txt').existsSync(), isTrue);
    expect(root.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty);
  });

  test('a stalled download stops, rather than sitting at its percentage for good', () async {
    hang = true;
    await expectLater(
      NeuralVoices.instance.download(voice, source: at(), stall: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(NeuralVoices.instance.downloading, isEmpty);
  });

  test('a download can be called off at once, and leaves nothing behind', () async {
    hang = true;
    final going = NeuralVoices.instance.download(voice, source: at(), stall: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(NeuralVoices.instance.downloading, contains(voice.id));
    final watch = Stopwatch()..start();
    NeuralVoices.instance.cancel(voice);
    await expectLater(going, throwsA(isA<DownloadCancelled>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'it waited for data that never came');
    expect(NeuralVoices.instance.downloading, isEmpty);
    expect(root.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty);
  });

  test('a damaged archive is not unpacked into a voice', () async {
    body = Uint8List.fromList(body)..[body.length ~/ 2] ^= 0xFF;
    await expectLater(NeuralVoices.instance.download(voice, source: at()), throwsA(isA<FormatException>()));
    expect(NeuralVoices.instance.installed(voice), isFalse);
    expect(root.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty,
        reason: 'a broken file is not worth going on from');
  });
}
