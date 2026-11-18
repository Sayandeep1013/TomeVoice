import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The one way TomeVoice talks to a model: the OpenAI chat format, which
/// every provider it offers speaks (Gemini through its OpenAI-compatible
/// endpoint, Inception, OpenRouter, Groq, OpenAI, and any other the reader
/// names). Straight from the phone to the provider, with the reader's own
/// key: there is no TomeVoice server between.
///
/// dart:io only (no platform channel), so it works the same in a
/// background isolate and in the background worker's engine.

/// Where a call goes: a provider's base URL, a key and a model.
class AiEndpoint {
  const AiEndpoint({required this.baseUrl, required this.key, required this.model});

  /// The base the OpenAI paths hang from, without a trailing slash:
  /// `https://api.inceptionlabs.ai/v1`.
  final String baseUrl;
  final String key;
  final String model;

  Uri path(String p) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base/$p');
  }
}

/// Why a call failed, as the key ring needs to know it.
enum AiFailure {
  /// The key's quota is spent (HTTP 429, or the provider's quota error):
  /// it rests until [AiError.retryAfter], and the next key takes over.
  quota,

  /// The key was refused (401, 403): wrong, revoked or without access.
  refused,

  /// The provider failed (5xx, a timeout): tried again a little later.
  server,

  /// The request itself was wrong (400, 404, an unknown model): trying again
  /// will not mend it.
  request,

  /// No network, or the address does not answer.
  network,
}

class AiError implements Exception {
  const AiError(this.kind, this.message, {this.retryAfter, this.status});

  final AiFailure kind;
  final String message;

  /// How long the key should rest, when the provider said or it can be told
  /// (a quota reset at the day's end).
  final Duration? retryAfter;
  final int? status;

  @override
  String toString() => 'AiError(${kind.name}${status == null ? '' : ' $status'}): $message';
}

/// A tool the model may call, in the OpenAI shape.
class AiTool {
  const AiTool({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;

  /// A JSON schema for the arguments.
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': parameters},
      };
}

/// A call the model asked for: [arguments] as the JSON it sent.
class AiToolCall {
  const AiToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;
  final String arguments;

  Map<String, Object?> get args {
    try {
      final v = jsonDecode(arguments);
      return v is Map ? v.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

/// Tokens a call used: as the provider counted them, or, when it did not
/// say, guessed at four characters a token.
class AiUsage {
  const AiUsage({this.input = 0, this.output = 0, this.guessed = false});

  final int input;
  final int output;
  final bool guessed;

  int get total => input + output;
}

class AiReply {
  const AiReply({required this.text, this.toolCalls = const [], this.usage = const AiUsage(), this.finish});

  final String text;
  final List<AiToolCall> toolCalls;
  final AiUsage usage;

  /// Why it stopped: `stop`, `length`, `tool_calls`.
  final String? finish;

  /// The reply as a message to send back with the tools' answers.
  Map<String, Object?> get asMessage => {
        'role': 'assistant',
        'content': text.isEmpty ? null : text,
        if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
      };
}

/// A message, as the OpenAI format has them.
Map<String, Object?> aiMessage(String role, String content) => {'role': role, 'content': content};

/// The answer to a tool call, sent back to the model.
Map<String, Object?> aiToolAnswer(String id, String content) =>
    {'role': 'tool', 'tool_call_id': id, 'content': content};

class AiClient {
  AiClient({HttpClient? http, this.timeout = const Duration(minutes: 3)}) : _http = http ?? HttpClient();

  final HttpClient _http;

  /// How long a reply may take to begin, and between parts of a streamed one.
  final Duration timeout;

  void close() => _http.close(force: true);

  /// One chat call. [json] asks for a JSON object back (the notes); [tools]
  /// lets the model ask for more (search the book, a card). With [onText]
  /// the reply streams, each piece given as it comes, and the whole is
  /// still returned at the end.
  Future<AiReply> chat(
    AiEndpoint to,
    List<Map<String, Object?>> messages, {
    List<AiTool> tools = const [],
    bool json = false,
    int? maxTokens,
    double? temperature,
    void Function(String piece)? onText,
  }) async {
    final body = <String, Object?>{
      'model': to.model,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toJson()],
      if (json) 'response_format': {'type': 'json_object'},
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (temperature != null) 'temperature': temperature,
      if (onText != null) 'stream': true,
    };
    final res = await _send(to, 'chat/completions', body);
    if (onText == null) {
      final raw = await _read(res);
      final Object? v;
      try {
        v = jsonDecode(raw);
      } on FormatException {
        throw AiError(AiFailure.server, 'The provider sent back something that is not JSON', status: res.statusCode);
      }
      return parseChatReply(v, sent: messages);
    }
    return _stream(res, messages, onText);
  }

  /// The models a key may use, by id, as the provider lists them.
  Future<List<String>> models(AiEndpoint to) async {
    final res = await _send(to, 'models', null);
    final v = jsonDecode(await _read(res));
    final data = v is Map ? v['data'] : null;
    if (data is! List) return const [];
    final ids = [
      for (final m in data)
        if (m is Map && m['id'] is String) (m['id'] as String).replaceFirst(RegExp('^models/'), ''),
    ]..sort();
    return ids;
  }

  /// Vectors for [texts], for meaning search; only some providers have it.
  Future<List<List<double>>> embed(AiEndpoint to, List<String> texts) async {
    final res = await _send(to, 'embeddings', {'model': to.model, 'input': texts});
    final v = jsonDecode(await _read(res));
    final data = v is Map ? v['data'] : null;
    if (data is! List) throw const AiError(AiFailure.server, 'No vectors came back');
    return [
      for (final d in data)
        [for (final x in (d as Map)['embedding'] as List) (x as num).toDouble()],
    ];
  }

  Future<HttpClientResponse> _send(AiEndpoint to, String path, Map<String, Object?>? body) async {
    try {
      final req = body == null ? await _http.getUrl(to.path(path)) : await _http.postUrl(to.path(path));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${to.key}');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
      // OpenRouter shows the app's name on its own usage page; nothing of the
      // reader's goes with it.
      req.headers.set('X-Title', 'TomeVoice');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(timeout);
      if (res.statusCode >= 200 && res.statusCode < 300) return res;
      final text = await _read(res).catchError((_) => '');
      throw errorFromResponse(res.statusCode, text, retryAfter: res.headers.value(HttpHeaders.retryAfterHeader));
    } on AiError {
      rethrow;
    } on TimeoutException {
      throw const AiError(AiFailure.server, 'The provider took too long to answer');
    } on SocketException catch (e) {
      throw AiError(AiFailure.network, e.message);
    } on HandshakeException catch (e) {
      throw AiError(AiFailure.network, e.message);
    } on HttpException catch (e) {
      throw AiError(AiFailure.network, e.message);
    }
  }

  Future<String> _read(HttpClientResponse res) => res.transform(utf8.decoder).join().timeout(timeout);

  Future<AiReply> _stream(HttpClientResponse res, List<Map<String, Object?>> sent, void Function(String) onText) async {
    final text = StringBuffer();
    final calls = <int, ({String id, String name, StringBuffer args})>{};
    String? finish;
    AiUsage? usage;
    try {
      await for (final line in res.transform(utf8.decoder).transform(const LineSplitter()).timeout(timeout)) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        final Object? v;
        try {
          v = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (v is! Map) continue;
        if (v['error'] != null) throw errorFromResponse(500, data);
        final u = v['usage'];
        if (u is Map) usage = _usage(u);
        final choices = v['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final c = choices.first as Map;
        finish = c['finish_reason'] as String? ?? finish;
        final delta = c['delta'];
        if (delta is! Map) continue;
        final piece = delta['content'];
        if (piece is String && piece.isNotEmpty) {
          text.write(piece);
          onText(piece);
        }
        final tc = delta['tool_calls'];
        if (tc is List) {
          for (final t in tc) {
            if (t is! Map) continue;
            final i = t['index'] as int? ?? 0;
            final f = t['function'] as Map?;
            final was = calls[i];
            final call = was ??
                (id: t['id'] as String? ?? 'call_$i', name: f?['name'] as String? ?? '', args: StringBuffer());
            if (was == null) calls[i] = call;
            final a = f?['arguments'];
            if (a is String) call.args.write(a);
          }
        }
      }
    } on TimeoutException {
      throw const AiError(AiFailure.server, 'The answer stopped coming');
    }
    final whole = text.toString();
    return AiReply(
      text: whole,
      toolCalls: [
        for (final c in calls.values) AiToolCall(id: c.id, name: c.name, arguments: c.args.toString()),
      ],
      usage: usage ?? guessUsage(sent, whole),
      finish: finish,
    );
  }
}

/// A non-streamed chat reply, read.
AiReply parseChatReply(Object? v, {required List<Map<String, Object?>> sent}) {
  if (v is! Map) throw const AiError(AiFailure.server, 'The provider sent back no reply');
  if (v['error'] != null) throw errorFromResponse(500, jsonEncode(v));
  final choices = v['choices'];
  if (choices is! List || choices.isEmpty) throw const AiError(AiFailure.server, 'The reply was empty');
  final c = choices.first as Map;
  final m = c['message'] as Map? ?? const {};
  final content = m['content'];
  final text = content is String
      ? content
      : content is List
          ? [
              for (final p in content)
                if (p is Map && p['text'] is String) p['text'] as String,
            ].join()
          : '';
  final calls = [
    for (final t in (m['tool_calls'] as List? ?? const []))
      if (t is Map)
        AiToolCall(
          id: t['id'] as String? ?? '',
          name: (t['function'] as Map?)?['name'] as String? ?? '',
          arguments: (t['function'] as Map?)?['arguments'] as String? ?? '{}',
        ),
  ];
  final u = v['usage'];
  return AiReply(
    text: text,
    toolCalls: calls,
    usage: u is Map ? _usage(u) : guessUsage(sent, text),
    finish: c['finish_reason'] as String?,
  );
}

AiUsage _usage(Map u) => AiUsage(
      input: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
      output: (u['completion_tokens'] as num?)?.toInt() ?? 0,
    );

/// Tokens guessed at four characters each, for a provider that did not count.
AiUsage guessUsage(List<Map<String, Object?>> sent, String reply) {
  var chars = 0;
  for (final m in sent) {
    final c = m['content'];
    if (c is String) chars += c.length;
  }
  return AiUsage(input: (chars / 4).ceil(), output: (reply.length / 4).ceil(), guessed: true);
}

/// What an error response means for the key: spent, refused, a fault of
/// the provider's or of the request. A spent quota says how long to rest
/// when it can be told: the provider's Retry-After, Gemini's retryDelay,
/// or, for a day's quota, until it resets (midnight in California, where
/// Google resets them).
AiError errorFromResponse(int status, String body, {String? retryAfter, DateTime? now}) {
  String message = body.trim();
  Object? v;
  try {
    v = jsonDecode(body);
  } on FormatException {
    v = null;
  }
  Object? err = v is Map ? v['error'] : null;
  if (v is List && v.isNotEmpty && v.first is Map) err = (v.first as Map)['error'];
  if (err is Map && err['message'] is String) message = err['message'] as String;
  if (err is String) message = err;
  if (message.length > 300) message = '${message.substring(0, 300)}…';
  final lower = body.toLowerCase();

  Duration? rest;
  final header = int.tryParse(retryAfter ?? '');
  if (header != null) rest = Duration(seconds: header);
  final delay = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
  if (rest == null && delay != null) rest = Duration(milliseconds: (double.parse(delay.group(1)!) * 1000).round());

  final spent = status == 429 ||
      lower.contains('resource_exhausted') ||
      lower.contains('quota') && (status == 403 || status == 400) ||
      lower.contains('insufficient_quota');
  if (spent) {
    final daily = lower.contains('perday') || lower.contains('per day') || lower.contains('daily');
    if (daily && (rest == null || rest < const Duration(minutes: 10))) rest = untilQuotaDay(now ?? DateTime.now());
    return AiError(AiFailure.quota, message.isEmpty ? 'The key has used up its quota for now' : message,
        retryAfter: rest ?? const Duration(minutes: 1), status: status);
  }
  if (status == 401 || status == 403) {
    return AiError(AiFailure.refused, message.isEmpty ? 'The key was refused' : message, status: status);
  }
  if (status == 408 || status >= 500) {
    return AiError(AiFailure.server, message.isEmpty ? 'The provider failed ($status)' : message,
        retryAfter: rest, status: status);
  }
  return AiError(AiFailure.request, message.isEmpty ? 'The provider turned the request down ($status)' : message,
      status: status);
}

/// Until the next midnight Pacific time, when Google's daily quotas reset:
/// eight hours after midnight UTC (seven in summer time, an hour early then,
/// which only means one early try).
Duration untilQuotaDay(DateTime now) {
  final utc = now.toUtc();
  var reset = DateTime.utc(utc.year, utc.month, utc.day, 8);
  if (!reset.isAfter(utc)) reset = reset.add(const Duration(days: 1));
  return reset.difference(utc) + const Duration(minutes: 2);
}
