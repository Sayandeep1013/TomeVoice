// Natural voice downloads: going on from where a cut-off one stopped,
// calling one off, a stall, and a damaged archive kept off the phone.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/neural_voices.dart';

/// A voice's archive, as the release has it: one top folder with the model,
/// its tokens and its pronunciation data (espeak-ng's, or a [lexicon]), and
/// a shared model's speakers ([speakers] false leaves them out).
Uint8List archiveOf(NeuralVoice v, {bool lexicon = false, bool speakers = true}) {
  final top = v.pack?.id ?? 'vits-piper-${v.id}';
  final a = Archive()
    ..addFile(ArchiveFile.bytes('$top/${v.modelFile}', Uint8List(1500 * 1024)))
    ..addFile(ArchiveFile.string('$top/tokens.txt', 'a 1\nb 2\n'));
  if (lexicon) {
    a.addFile(ArchiveFile.string('$top/lexicon.txt', 'x x\n'));
  } else {
    a.addFile(ArchiveFile.string('$top/espeak-ng-data/phontab', 'x'));
  }
  if (v.pack != null && speakers) a.addFile(ArchiveFile.bytes('$top/voices.bin', Uint8List(4096)));
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

  group('from the catalog', () {
    final catalog = NeuralCatalog.parse(File('assets/voices/catalog.json').readAsStringSync());
    setUp(() => NeuralVoices.instance.useCatalog(catalog));

    test('a model with many voices is downloaded once, for every speaker', () async {
      final alpha = catalog.byId('kokoro-multi-lang-v1_0:hf_alpha')!;
      final psi = catalog.byId('kokoro-multi-lang-v1_0:hm_psi')!;
      body = archiveOf(alpha);
      cutAfter = body.length ~/ 3;
      await expectLater(NeuralVoices.instance.download(alpha, source: at()), throwsA(anything));
      // The part is the model's, whichever of its speakers asked.
      cutAfter = null;
      await NeuralVoices.instance.download(psi, source: at());
      expect(ranges.last, 'bytes=${body.length ~/ 3}-');
      expect(NeuralVoices.instance.installed(alpha), isTrue);
      expect(NeuralVoices.instance.installed(psi), isTrue);
      expect(Directory('${root.path}/voices/kokoro-multi-lang-v1_0').existsSync(), isTrue);
      expect(File('${NeuralVoices.instance.folder(alpha).path}/voices.bin').existsSync(), isTrue);

      // Removing one speaker removes the model all of them share.
      await NeuralVoices.instance.remove(psi);
      expect(NeuralVoices.instance.installed(alpha), isFalse);
    });

    test("a model whose speakers did not come is not kept", () async {
      final alpha = catalog.byId('kokoro-multi-lang-v1_0:hf_alpha')!;
      body = archiveOf(alpha, speakers: false);
      await expectLater(NeuralVoices.instance.download(alpha, source: at()), throwsA(isA<FormatException>()));
      expect(NeuralVoices.instance.installed(alpha), isFalse);
    });

    test('a Chinese voice read through a lexicon unpacks without espeak-ng data', () async {
      final xiaoYa = catalog.byId('zh_CN-xiao_ya-medium')!;
      body = archiveOf(xiaoYa, lexicon: true);
      await NeuralVoices.instance.download(xiaoYa, source: at());
      expect(NeuralVoices.instance.installed(xiaoYa), isTrue);
      expect(File('${NeuralVoices.instance.folder(xiaoYa).path}/lexicon.txt').existsSync(), isTrue);
    });
  });
}
