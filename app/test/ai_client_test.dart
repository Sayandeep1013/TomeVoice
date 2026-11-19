// The AI client and the key ring: one OpenAI-style client for every
// provider, streamed or not, with tools; errors read as the ring needs them
// (a spent quota rests the key, a refused one is marked); keys tried in
// their order, each call counted to its key.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomevoice_spike/ai/ai_client.dart';
import 'package:tomevoice_spike/ai/ai_keys.dart';
import 'package:tomevoice_spike/ai/ai_router.dart';

/// A provider on this machine: each request answered by [answer], which
/// gets the key it was sent with and the body.
class FakeProvider {
  FakeProvider._(this._server);

  final HttpServer _server;
  final requests = <({String key, String path, Map<String, Object?> body})>[];
  late Future<void> Function(HttpRequest req, String key, Map<String, Object?> body) answer;

  String get url => 'http://${_server.address.host}:${_server.port}/v1';

  static Future<FakeProvider> start() async {
    final p = FakeProvider._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    p._server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? <String, Object?>{} : (jsonDecode(raw) as Map).cast<String, Object?>();
      final key = (req.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
      p.requests.add((key: key, path: req.uri.path, body: body));
      await p.answer(req, key, body);
    });
    return p;
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> reply(HttpRequest req, int status, Object body, {Map<String, String> headers = const {}}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  headers.forEach(req.response.headers.set);
  req.response.write(body is String ? body : jsonEncode(body));
  await req.response.close();
}

Map<String, Object?> said(String text, {int input = 12, int output = 3}) => {
      'choices': [
        {
          'message': {'role': 'assistant', 'content': text},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': input, 'completion_tokens': output},
    };

void main() {
  late FakeProvider provider;
  final client = AiClient(timeout: const Duration(seconds: 5));

  setUp(() async {
    provider = await FakeProvider.start();
    AiRing.instance.reset();
  });

  tearDown(() async {
    await provider.close();
    AiRing.instance.reset();
  });

  AiEndpoint at(String key) => AiEndpoint(baseUrl: provider.url, key: key, model: 'm');

  group('client', () {
    test('a chat call: the model, messages and key sent; the text and the tokens back', () async {
      provider.answer = (req, key, body) => reply(req, 200, said('Hello.'));
      final r = await client.chat(at('k1'), [aiMessage('user', 'Hi')], json: true, maxTokens: 50);
      expect(r.text, 'Hello.');
      expect(r.usage.input, 12);
      expect(r.usage.guessed, isFalse);
      final sent = provider.requests.single;
      expect(sent.path, '/v1/chat/completions');
      expect(sent.key, 'k1');
      expect(sent.body['model'], 'm');
      expect(sent.body['response_format'], {'type': 'json_object'});
      expect(sent.body['max_tokens'], 50);
    });

    test('streamed: each piece as it comes, the whole at the end, tool calls put together', () async {
      provider.answer = (req, key, body) async {
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final chunk in [
          {'choices': [{'delta': {'content': 'The '}}]},
          {'choices': [{'delta': {'content': 'tide.'}}]},
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {'index': 0, 'id': 'c1', 'function': {'name': 'card', 'arguments': '{"na'}},
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {'index': 0, 'function': {'arguments': 'me":"Sunny"}'}},
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
        ]) {
          req.response.write('data: ${jsonEncode(chunk)}\n\n');
          await req.response.flush();
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      };
      final pieces = <String>[];
      final r = await client.chat(at('k'), [aiMessage('user', 'Who?')], onText: pieces.add);
      expect(pieces, ['The ', 'tide.']);
      expect(r.text, 'The tide.');
      expect(r.finish, 'tool_calls');
      expect(r.toolCalls.single.name, 'card');
      expect(r.toolCalls.single.args, {'name': 'Sunny'});
      // No count from the provider: guessed.
      expect(r.usage.guessed, isTrue);
      expect(provider.requests.single.body['stream'], isTrue);
    });

    test("a key's models, by id", () async {
      provider.answer = (req, key, body) => reply(req, 200, {
            'data': [
              {'id': 'models/gemini-b'},
              {'id': 'gemini-a'},
            ],
          });
      expect(await client.models(at('k')), ['gemini-a', 'gemini-b']);
    });

    test('nothing answering is a network failure', () async {
      final gone = at('k');
      await provider.close();
      await expectLater(
        client.chat(gone, [aiMessage('user', 'Hi')]),
        throwsA(isA<AiError>().having((e) => e.kind, 'kind', AiFailure.network)),
      );
    });
  });

  group('errors', () {
    test('429 with Retry-After: the quota, resting that long', () {
      final e = errorFromResponse(429, '{"error":{"message":"Too many"}}', retryAfter: '30');
      expect(e.kind, AiFailure.quota);
      expect(e.retryAfter, const Duration(seconds: 30));
      expect(e.message, 'Too many');
    });

    test("Gemini's retryDelay, and its day's quota resting until the day turns in California", () {
      final minute = errorFromResponse(429,
          '[{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED","details":[{"retryDelay":"41s"}]}}]');
      expect(minute.retryAfter, const Duration(seconds: 41));
      final day = errorFromResponse(
        429,
        '{"error":{"message":"Quota exceeded for metric generate_content_free_tier_requests, limit: 20, '
        'quotaId: GenerateRequestsPerDayPerProjectPerModel-FreeTier","details":[{"retryDelay":"20s"}]}}',
        now: DateTime.utc(2026, 11, 19, 3),
      );
      expect(day.kind, AiFailure.quota);
      expect(day.retryAfter, const Duration(hours: 5, minutes: 2));
    });

    test('refused, the provider failing, the request wrong', () {
      expect(errorFromResponse(401, '{"error":{"message":"Bad key"}}').kind, AiFailure.refused);
      expect(errorFromResponse(403, '{"error":{"message":"No access"}}').kind, AiFailure.refused);
      expect(errorFromResponse(403, '{"error":{"message":"You exceeded your current quota"}}').kind, AiFailure.quota);
      expect(errorFromResponse(503, 'Unavailable').kind, AiFailure.server);
      expect(errorFromResponse(404, '{"error":{"message":"No such model"}}').kind, AiFailure.request);
    });
  });

  group('the ring', () {
    AiKey key(String id, {AiProvider provider = AiProvider.custom, String? base}) => AiKey(
          id: id,
          provider: provider,
          label: id,
          baseUrl: base ?? 'http://127.0.0.1:9/v1',
          secret: 'secret-$id',
          models: const {AiJob.builder: 'm', AiJob.talker: 'big'},
        );

    test('any number of keys from one provider; a job tries them in its order', () async {
      final ring = AiRing.instance;
      for (final id in ['a', 'b', 'c']) {
        await ring.put(key(id, provider: AiProvider.inception));
      }
      expect(ring.forJob(AiJob.builder).map((k) => k.id), ['a', 'b', 'c']);
      await ring.reorder(AiJob.builder, ['c', 'a', 'b']);
      expect(ring.forJob(AiJob.builder).map((k) => k.id), ['c', 'a', 'b']);
      // A key without a model for a job does not do it.
      await ring.put(key('a').copyWith(models: {AiJob.talker: 'big'}));
      expect(ring.forJob(AiJob.builder).map((k) => k.id), ['c', 'b']);
      expect(ring.forJob(AiJob.embedder), isEmpty);
      expect(key('abcdef').masked, '••••cdef');
    });

    test('a spent key rests and the next takes over; a refused one is skipped after', () async {
      final ring = AiRing.instance;
      for (final id in ['a', 'b', 'c']) {
        await ring.put(key(id, base: provider.url));
      }
      provider.answer = (req, k, body) => switch (k) {
            'secret-a' => reply(req, 429, '{"error":{"message":"slow down"}}', headers: {'retry-after': '120'}),
            'secret-b' => reply(req, 401, '{"error":{"message":"bad key"}}'),
            _ => reply(req, 200, said('From c.', input: 100, output: 20)),
          };
      final now = DateTime(2026, 11, 19, 10);
      final router = AiRouter(client: client, pause: Duration.zero, clock: () => now);
      final r = await router.chat(AiJob.builder, [aiMessage('user', 'Notes?')]);
      expect(r.text, 'From c.');
      expect(router.lastKey!.id, 'c');
      expect(ring.stateOf('a').restUntil, now.add(const Duration(minutes: 2)));
      expect(ring.stateOf('b').refused, 'bad key');
      expect(ring.today('c', now: DateTime.now()).input, 100);
      expect(ring.today('c', now: DateTime.now()).calls, 1);

      // Next time: straight to c.
      provider.requests.clear();
      await router.chat(AiJob.builder, [aiMessage('user', 'Again')]);
      expect(provider.requests.map((r) => r.key), ['secret-c']);
    });

    test('every key resting: the work waits until the first wakes', () async {
      final ring = AiRing.instance;
      await ring.put(key('a', base: provider.url));
      await ring.put(key('b', base: provider.url));
      provider.answer = (req, k, body) =>
          reply(req, 429, '{"error":{"message":"later"}}', headers: {'retry-after': k == 'secret-a' ? '600' : '60'});
      final now = DateTime(2026, 11, 19, 10);
      final router = AiRouter(client: client, pause: Duration.zero, clock: () => now);
      await expectLater(
        router.chat(AiJob.builder, [aiMessage('user', 'x')]),
        throwsA(isA<AiResting>().having((e) => e.until, 'until', now.add(const Duration(minutes: 1)))),
      );
    });

    test('the provider failing is tried once more, then the next key', () async {
      final ring = AiRing.instance;
      await ring.put(key('a', base: provider.url));
      await ring.put(key('b', base: provider.url));
      var calls = 0;
      provider.answer = (req, k, body) {
        calls++;
        return k == 'secret-a' ? reply(req, 503, 'down') : reply(req, 200, said('From b.'));
      };
      final router = AiRouter(client: client, pause: Duration.zero);
      expect((await router.chat(AiJob.talker, [aiMessage('user', 'x')])).text, 'From b.');
      expect(calls, 3);
      expect(ring.stateOf('a').refused, isNull);
    });

    test("a provider in trouble: its key rests a while, longer each time, and the work waits, not fails", () async {
      final ring = AiRing.instance;
      await ring.put(key('a', base: provider.url));
      var down = true;
      provider.answer = (req, k, body) => down ? reply(req, 500, 'The server had an error') : reply(req, 200, said('Back.'));
      var now = DateTime(2026, 11, 19, 10);
      final router = AiRouter(client: client, pause: Duration.zero, clock: () => now);
      for (final minutes in [1, 2, 5, 10, 10]) {
        await expectLater(
          router.chat(AiJob.builder, [aiMessage('user', 'x')]),
          throwsA(isA<AiResting>().having((e) => e.until, 'until', now.add(Duration(minutes: minutes)))),
        );
        now = now.add(Duration(minutes: minutes, seconds: 1));
      }
      down = false;
      expect((await router.chat(AiJob.builder, [aiMessage('user', 'x')])).text, 'Back.');
      // Well again: the next trouble rests it a minute.
      down = true;
      await expectLater(
        router.chat(AiJob.builder, [aiMessage('user', 'x')]),
        throwsA(isA<AiResting>().having((e) => e.until, 'until', now.add(const Duration(minutes: 1)))),
      );
    });
  });
}
