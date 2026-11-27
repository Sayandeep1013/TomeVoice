// ElevenLabs voices on the reader's own key, against a stand-in for
// ElevenLabs on this machine: no real key, no credits spent.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/eleven_labs.dart';
import 'package:tomevoice_spike/secrets.dart';

/// ElevenLabs as far as TomeVoice asks it: voices, credits, and a sentence
/// with when each letter is said.
class _FakeEleven {
  _FakeEleven(this.server);

  final HttpServer server;
  int speechAsked = 0;
  String? lastKey;
  Map<String, Object?>? lastBody;

  /// What the next answer is when not 200.
  int? failWith;
  String failBody = '';

  static Future<_FakeEleven> start() async {
    final f = _FakeEleven(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.server.listen(f._answer);
    return f;
  }

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> _answer(HttpRequest req) async {
    lastKey = req.headers.value('xi-api-key');
    final res = req.response;
    res.headers.contentType = ContentType.json;
    if (failWith != null) {
      res.statusCode = failWith!;
      res.write(failBody);
      await res.close();
      return;
    }
    if (lastKey != 'good-key') {
      res.statusCode = 401;
      res.write(jsonEncode({
        'detail': {'status': 'invalid_api_key', 'message': 'Invalid API key'},
      }));
      await res.close();
      return;
    }
    final path = req.uri.path;
    if (path == '/v1/voices') {
      res.write(jsonEncode({
        'voices': [
          {
            'voice_id': 'v2',
            'name': 'Rachel',
            'labels': {'accent': 'american', 'description': 'calm', 'use_case': 'narration'},
          },
          {'voice_id': 'v1', 'name': 'Adam', 'labels': {}},
          {'name': 'no id'},
        ],
      }));
    } else if (path == '/v1/user/subscription') {
      res.write(jsonEncode({
        'tier': 'starter',
        'character_count': 1200,
        'character_limit': 30000,
        'next_character_count_reset_unix': 1798761600,
      }));
    } else if (path.startsWith('/v1/text-to-speech/') && path.endsWith('/with-timestamps')) {
      speechAsked++;
      lastBody = (jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, Object?>();
      final text = lastBody!['text'] as String;
      // A second of a quiet tone; each letter a fortieth of a second on.
      final pcm = ByteData(ElevenLabs.rate * 2);
      for (var i = 0; i < ElevenLabs.rate; i++) {
        pcm.setInt16(i * 2, (i % 100 < 50 ? 2000 : -2000), Endian.little);
      }
      res.write(jsonEncode({
        'audio_base64': base64Encode(pcm.buffer.asUint8List()),
        'alignment': {
          'characters': [for (final c in text.split('')) c],
          'character_start_times_seconds': [for (var i = 0; i < text.length; i++) i / 40],
          'character_end_times_seconds': [for (var i = 0; i < text.length; i++) (i + 1) / 40],
        },
      }));
    } else {
      res.statusCode = 404;
      res.write('{}');
    }
    await res.close();
  }
}

void main() {
  late Directory tmp;
  late _FakeEleven fake;
  final eleven = ElevenLabs.instance;
  final realApi = ElevenLabs.api;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tomevoice_eleven');
    Secrets.home = tmp;
    fake = await _FakeEleven.start();
    ElevenLabs.api = fake.url;
    await eleven.open(tmp);
  });

  tearDown(() async {
    await eleven.setKey(null);
    await eleven.clearKept();
    ElevenLabs.api = realApi;
    await fake.server.close(force: true);
    Secrets.home = null;
    tmp.deleteSync(recursive: true);
  });

  test('a key is kept only once ElevenLabs takes it, with its voices, A to Z', () async {
    await expectLater(eleven.setKey('wrong'), throwsA(isA<ElevenError>()));
    expect(eleven.hasKey, isFalse);

    await eleven.setKey('good-key');
    expect(eleven.hasKey, isTrue);
    expect(eleven.keyHint, '…-key');
    expect([for (final v in eleven.voices) v.name], ['Adam', 'Rachel']);
    expect(eleven.voices.last.description, 'american, calm, narration');
    expect(eleven.byVoiceName('eleven:v2')?.name, 'Rachel');
    expect(isEleven('eleven:v2'), isTrue);
    expect(isEleven('neural:af_heart'), isFalse);
  });

  test("this month's credits: used, left and when they renew", () async {
    await eleven.setKey('good-key');
    final u = await eleven.usage();
    expect(u!.used, 1200);
    expect(u.limit, 30000);
    expect(u.left, 28800);
    expect(u.resets!.year, 2027);
  });

  test('a sentence comes as a WAV with each word placed, made once, and any speed after costs nothing', () async {
    await eleven.setKey('good-key');
    const text = 'The quick fox.';
    final out = Directory('${tmp.path}/out')..createSync();

    final first = await eleven.synthesise(voiceId: 'v2', text: text, speed: 1, outDir: out.path);
    expect(fake.speechAsked, 1);
    expect(fake.lastBody!['model_id'], ElevenModel.flash.id, reason: 'Flash unless chosen otherwise');
    final audio = WavCodec.decode(File(first['wavPath']! as String).readAsBytesSync());
    expect(audio.sampleRate, ElevenLabs.rate);
    expect(audio.frameCount, ElevenLabs.rate);
    final words = first['rangeEvents']! as List;
    expect(words, [
      {'start': 0, 'end': 3, 'frame': 0},
      {'start': 4, 'end': 9, 'frame': 2400},
      {'start': 10, 'end': 14, 'frame': 6000},
    ]);

    // Heard again, and at twice the speed: from what is kept.
    await eleven.synthesise(voiceId: 'v2', text: text, speed: 1, outDir: out.path);
    final fast = await eleven.synthesise(voiceId: 'v2', text: text, speed: 2, outDir: out.path);
    expect(fake.speechAsked, 1, reason: 'never paid for twice');
    final fastAudio = WavCodec.decode(File(fast['wavPath']! as String).readAsBytesSync());
    expect(fastAudio.frameCount, closeTo(ElevenLabs.rate / 2, ElevenLabs.rate * 0.05));
    expect((fast['rangeEvents']! as List)[2], {'start': 10, 'end': 14, 'frame': 3000});
    expect((await eleven.kept()).sentences, 1);

    // Another model is another voice: asked for.
    await eleven.setModel(ElevenModel.multilingual);
    await eleven.synthesise(voiceId: 'v2', text: text, speed: 1, outDir: out.path);
    expect(fake.speechAsked, 2);
    expect(fake.lastBody!['model_id'], ElevenModel.multilingual.id);
    await eleven.setModel(ElevenModel.flash);
  });

  test('says why ElevenLabs said no, in words the reader can act on', () async {
    await eleven.setKey('good-key');
    fake
      ..failWith = 401
      ..failBody = jsonEncode({
        'detail': {'status': 'quota_exceeded', 'message': 'This request exceeds your quota.'},
      });
    await expectLater(
      eleven.synthesise(voiceId: 'v2', text: 'Hello.', speed: 1, outDir: tmp.path),
      throwsA(isA<ElevenError>().having((e) => e.message, 'message', contains('credits are used up'))),
    );
    expect(ElevenLabs.said(429, '{}'), contains('busy'));
    expect(ElevenLabs.said(401, '{"detail":{"status":"invalid_api_key"}}'), contains('did not accept the key'));
    expect(ElevenLabs.said(404, '{}'), contains('not in your account'));
  });

  test('each sentence is sent with the ones either side, for one voice and tone across them', () async {
    await eleven.setKey('good-key');
    await eleven.synthesise(
        voiceId: 'v1', text: 'The middle one.', speed: 1, outDir: tmp.path, previousText: 'The first one.', nextText: 'The last one.');
    expect(fake.lastBody!['previous_text'], 'The first one.');
    expect(fake.lastBody!['next_text'], 'The last one.');
    await eleven.synthesise(voiceId: 'v1', text: 'Alone.', speed: 1, outDir: tmp.path);
    expect(fake.lastBody!.containsKey('previous_text'), isFalse);
    expect(fake.lastBody!.containsKey('next_text'), isFalse);
  });

  test('a failure that will likely pass (the network, busy, its own trouble) is told from one that will not', () {
    expect(const ElevenError('x').passing, isTrue);
    expect(const ElevenError('x', status: 429).passing, isTrue);
    expect(const ElevenError('x', status: 503).passing, isTrue);
    expect(const ElevenError('x', status: 401).passing, isFalse);
    expect(const ElevenError('x', status: 402).passing, isFalse);
  });

  test('no key: says where to add one, and asks nothing', () async {
    await expectLater(
      eleven.synthesise(voiceId: 'v2', text: 'Hello.', speed: 1, outDir: tmp.path),
      throwsA(isA<ElevenError>().having((e) => e.message, 'message', contains('No ElevenLabs key'))),
    );
    expect(fake.speechAsked, 0);
  });

  test('words are placed from when their first letter is said, even if fewer letters came back', () {
    final w = ElevenLabs.wordsOf('One two', {
      'character_start_times_seconds': [0.0, 0.1, 0.2, 0.3],
    });
    expect(w.map((e) => (e.start, e.end, e.frame)), [(0, 3, 0), (4, 7, 7200)]);
    expect(ElevenLabs.wordsOf('One', null), isEmpty);
  });
}
