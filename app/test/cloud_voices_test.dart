// Cloud voices (OpenAI, Google, Azure) on the reader's own key, against one
// stand-in for all three on this machine: no real key, no money spent.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';
import 'package:tomevoice_spike/cloud_voices.dart';
import 'package:tomevoice_spike/secrets.dart';

/// A second of tone between a fifth of a second of silence either side.
Uint8List _speech() {
  const r = CloudVoices.rate;
  final pcm = ByteData(r * 14 ~/ 10 * 2);
  for (var i = r ~/ 5; i < r * 6 ~/ 5; i++) {
    pcm.setInt16(i * 2, i % 100 < 50 ? 4000 : -4000, Endian.little);
  }
  return pcm.buffer.asUint8List();
}

Uint8List _wavOf(Uint8List pcm) {
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, CloudVoices.rate, Endian.little)
    ..setUint32(28, CloudVoices.rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
}

class _Fake {
  _Fake(this.server);

  final HttpServer server;
  int speechAsked = 0;
  Map<String, Object?>? lastJson;
  String? lastSsml;
  String? lastAuth;

  static Future<_Fake> start() async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.server.listen(f._answer);
    return f;
  }

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> _answer(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    final body = await utf8.decoder.bind(req).join();
    final key = req.headers.value('authorization')?.replaceFirst('Bearer ', '') ??
        req.headers.value('ocp-apim-subscription-key') ??
        req.uri.queryParameters['key'];
    lastAuth = key;
    if (key != 'good-key') {
      res.statusCode = path.contains('googleapis') || req.uri.queryParameters.containsKey('key') ? 400 : 401;
      res.write(jsonEncode({
        'error': {'code': 'invalid_api_key', 'message': 'API key not valid. Please pass a valid API key.'},
      }));
      await res.close();
      return;
    }
    if (path == '/v1/models/tts-1') {
      res.write(jsonEncode({'id': 'tts-1'}));
    } else if (path == '/v1/audio/speech') {
      speechAsked++;
      lastJson = (jsonDecode(body) as Map).cast<String, Object?>();
      res.add(_speech());
    } else if (path == '/v1/voices') {
      res.write(jsonEncode({
        'voices': [
          {'name': 'en-GB-Neural2-A', 'languageCodes': ['en-GB'], 'ssmlGender': 'FEMALE'},
          {'name': 'de-DE-Standard-B', 'languageCodes': ['de-DE'], 'ssmlGender': 'MALE'},
        ],
      }));
    } else if (path == '/v1beta1/text:synthesize') {
      speechAsked++;
      lastJson = (jsonDecode(body) as Map).cast<String, Object?>();
      final ssml = (lastJson!['input'] as Map)['ssml'] as String;
      final marks = RegExp(r'<mark name="(w\d+)"/>').allMatches(ssml).map((m) => m.group(1)).toList();
      res.write(jsonEncode({
        'audioContent': base64Encode(_wavOf(_speech())),
        'timepoints': [
          for (var i = 0; i < marks.length; i++) {'markName': marks[i], 'timeSeconds': 0.2 + i * 0.25},
        ],
      }));
    } else if (path == '/cognitiveservices/voices/list') {
      res.write(jsonEncode([
        {'ShortName': 'en-US-AvaMultilingualNeural', 'DisplayName': 'Ava', 'Locale': 'en-US', 'Gender': 'Female', 'VoiceType': 'Neural'},
        {'ShortName': 'fr-FR-DeniseNeural', 'DisplayName': 'Denise', 'Locale': 'fr-FR', 'Gender': 'Female', 'VoiceType': 'Neural'},
        {'ShortName': 'en-US-Old', 'DisplayName': 'Old', 'Locale': 'en-US', 'VoiceType': 'Standard'},
      ]));
    } else if (path == '/cognitiveservices/v1') {
      speechAsked++;
      lastSsml = body;
      res.add(_speech());
    } else {
      res.statusCode = 404;
      res.write('{}');
    }
    await res.close();
  }
}

void main() {
  late Directory tmp;
  late _Fake fake;
  final cloud = CloudVoices.instance;
  final real = (CloudVoices.openAiApi, CloudVoices.googleApi, CloudVoices.azureApi);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tomevoice_cloud');
    Secrets.home = tmp;
    fake = await _Fake.start();
    CloudVoices.openAiApi = fake.url;
    CloudVoices.googleApi = fake.url;
    CloudVoices.azureApi = (_) => fake.url;
    await cloud.open(tmp);
  });

  tearDown(() async {
    for (final s in CloudService.values) {
      await cloud.setKey(s, null);
    }
    await cloud.clearKept();
    CloudVoices.openAiApi = real.$1;
    CloudVoices.googleApi = real.$2;
    CloudVoices.azureApi = real.$3;
    await fake.server.close(force: true);
    Secrets.home = null;
    tmp.deleteSync(recursive: true);
  });

  test('a key is kept only once the service takes it', () async {
    await expectLater(cloud.setKey(CloudService.openai, 'wrong'), throwsA(isA<CloudError>()));
    expect(cloud.hasKey(CloudService.openai), isFalse);
    await cloud.setKey(CloudService.openai, 'good-key');
    expect(cloud.hasKey(CloudService.openai), isTrue);
    expect(cloud.keyHint(CloudService.openai), '…-key');
    expect(cloud.voicesOf(CloudService.openai).map((v) => v.id), contains('nova'));
    expect(isCloud('cloud:openai:nova'), isTrue);
    expect(cloud.byVoiceName('cloud:openai:nova')?.name, 'Nova');
  });

  test('a key it refuses says so, and does not pass by itself', () async {
    try {
      await cloud.setKey(CloudService.google, 'wrong');
      fail('taken');
    } on CloudError catch (e) {
      expect(e.message, contains('Google did not accept the key'));
      expect(e.passing, isFalse);
    }
    expect(CloudVoices.said(CloudService.openai, 429, '{"error":{"code":"insufficient_quota"}}').passing, isFalse,
        reason: 'no money left is not busy');
    expect(CloudVoices.said(CloudService.openai, 429, '{"error":{"code":"rate_limit_exceeded"}}').passing, isTrue);
  });

  test('OpenAI: a sentence made once, told how to read, its words measured from the speech', () async {
    await cloud.setKey(CloudService.openai, 'good-key');
    final out = Directory('${tmp.path}/out')..createSync();
    const text = 'The quick, brown fox.';
    final made = await cloud.synthesise(voiceName: 'cloud:openai:nova', text: text, speed: 1, outDir: out.path);
    expect(fake.lastJson!['model'], 'gpt-4o-mini-tts');
    expect(fake.lastJson!['response_format'], 'pcm');
    expect(fake.lastJson!['instructions'], CloudVoices.defaultStyle);
    final audio = WavCodec.decode(File(made['wavPath']! as String).readAsBytesSync());
    expect(audio.sampleRate, CloudVoices.rate);
    final words = (made['rangeEvents']! as List).cast<Map>();
    expect(words.map((w) => w['start']), [0, 4, 11, 17]);
    // The first word starts where the sound does, and they keep in order
    // within the second of speech.
    expect(words.first['frame'], closeTo(CloudVoices.rate / 5, 300));
    final frames = [for (final w in words) w['frame'] as int];
    expect(frames, orderedEquals([...frames]..sort()));
    expect(frames.last, lessThan(CloudVoices.rate * 6 ~/ 5));

    await cloud.synthesise(voiceName: 'cloud:openai:nova', text: text, speed: 1.5, outDir: out.path);
    expect(fake.speechAsked, 1, reason: 'never paid for twice');

    // Another narration style is another reading.
    await cloud.setOpenAiStyle('Whisper.');
    await cloud.synthesise(voiceName: 'cloud:openai:nova', text: text, speed: 1, outDir: out.path);
    expect(fake.speechAsked, 2);
    expect(fake.lastJson!['instructions'], 'Whisper.');
  });

  test("Google: its voices by language, and each word where Google's marks say", () async {
    await cloud.setKey(CloudService.google, 'good-key');
    final voices = cloud.voicesOf(CloudService.google);
    expect(voices.map((v) => v.id), ['de-DE-Standard-B', 'en-GB-Neural2-A']);
    expect(voices.last.name, 'Neural2 A');
    final out = Directory('${tmp.path}/out')..createSync();
    final made = await cloud.synthesise(voiceName: 'cloud:google:en-GB-Neural2-A', text: 'Fish & chips <now>', speed: 1, outDir: out.path);
    final ssml = (fake.lastJson!['input'] as Map)['ssml'] as String;
    expect(ssml, '<speak><mark name="w0"/>Fish <mark name="w1"/>&amp; <mark name="w2"/>chips <mark name="w3"/>&lt;now&gt;</speak>');
    expect((fake.lastJson!['voice'] as Map)['languageCode'], 'en-GB');
    final words = (made['rangeEvents']! as List).cast<Map>();
    expect([for (final w in words) w['frame']], [4800, 10800, 16800, 22800]);
    final audio = WavCodec.decode(File(made['wavPath']! as String).readAsBytesSync());
    expect(audio.frameCount, CloudVoices.rate * 14 ~/ 10, reason: "the WAV's header not read as sound");
  });

  test('Azure: the key with its region, neural voices only, the text sent as SSML', () async {
    await expectLater(cloud.setKey(CloudService.azure, 'good-key'), throwsA(isA<CloudError>()), reason: 'no region');
    await cloud.setKey(CloudService.azure, 'good-key', region: 'West Europe');
    expect(cloud.azureRegion, 'westeurope');
    expect(cloud.voicesOf(CloudService.azure).map((v) => v.name), ['Ava', 'Denise']);
    final out = Directory('${tmp.path}/out')..createSync();
    await cloud.synthesise(voiceName: 'cloud:azure:en-US-AvaMultilingualNeural', text: "Tom's <b> line", speed: 1, outDir: out.path);
    expect(fake.lastSsml, "<speak version='1.0' xml:lang='en-US'><voice name='en-US-AvaMultilingualNeural'>Tom&apos;s &lt;b&gt; line</voice></speak>");
  });

  test('prices: a tenth of ElevenLabs or less', () {
    expect(cloudDollarsPerMillion(CloudService.google, 'en-US-Standard-A'), 4);
    expect(cloudDollarsPerMillion(CloudService.google, 'en-US-Chirp3-HD-Aoede'), 30);
    expect(cloudDollarsPerMillion(CloudService.openai, 'nova', model: OpenAiModel.hd), 30);
    expect(cloudDollarsPerMillion(CloudService.azure, 'en-US-AvaNeural'), 15);
  });
}
