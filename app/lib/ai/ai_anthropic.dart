import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'ai_client.dart';

/// Claude, spoken to in Anthropic's own Messages API (`POST /v1/messages`)
/// rather than its OpenAI-compatible endpoint, which turns down the JSON
/// mode the Builder asks for and a temperature below 1. Plain HTTP, as for
/// every provider here: there is no Anthropic SDK for Dart.
///
/// The app's messages are OpenAI's shape; here they are turned into the
/// Messages API's (the system prompt on its own, a reply's tool calls as
/// `tool_use` blocks, tool answers as `tool_result` blocks in one user
/// turn), and its replies back. A reply's own blocks (its thinking among
/// them) are kept on it ([AiReply.raw]) and sent back unchanged with the
/// tools' answers, as the API asks.

const _version = '2023-06-01';

/// Room for the answer and the model's thinking, which counts towards it:
/// a few hundred tokens (what an OpenAI-style "short answer" asks for)
/// could all go on thinking and leave no answer.
const _least = 4096;

/// What a call may write when the caller names no limit.
const _usual = 16000;

Map<String, String> _headers(AiEndpoint to) => {
      'x-api-key': to.key,
      'anthropic-version': _version,
    };

/// The app's (OpenAI-shaped) [messages] as the Messages API's: the system
/// prompt apart, and its turns.
({String system, List<Map<String, Object?>> turns}) anthropicTurns(List<Map<String, Object?>> messages) {
  final system = <String>[];
  final turns = <Map<String, Object?>>[];
  void add(String role, Object content) {
    // Answers to several tool calls go back in one user turn.
    if (turns.isNotEmpty && turns.last['role'] == role && role == 'user') {
      final last = turns.last['content'];
      final blocks = [
        ...(last is List ? last.cast<Object?>() : [_text('$last')]),
        ...(content is List ? content : [_text('$content')]),
      ];
      turns.last['content'] = blocks;
      return;
    }
    turns.add({'role': role, 'content': content});
  }

  for (final m in messages) {
    final content = m['content'];
    switch (m['role']) {
      case 'system':
        if (content is String && content.isNotEmpty) system.add(content);
      case 'assistant':
        final raw = m['raw'];
        if (raw is List && raw.isNotEmpty) {
          add('assistant', raw);
          continue;
        }
        final calls = m['tool_calls'];
        if (calls is List && calls.isNotEmpty) {
          add('assistant', [
            if (content is String && content.isNotEmpty) _text(content),
            for (final c in calls)
              if (c is Map)
                {
                  'type': 'tool_use',
                  'id': c['id'],
                  'name': (c['function'] as Map?)?['name'],
                  'input': _args((c['function'] as Map?)?['arguments']),
                },
          ]);
        } else if (content is String && content.isNotEmpty) {
          add('assistant', content);
        }
      case 'tool':
        add('user', [
          {'type': 'tool_result', 'tool_use_id': m['tool_call_id'], 'content': '${content ?? ''}'},
        ]);
      default:
        add('user', content is String ? content : jsonEncode(content));
    }
  }
  return (system: system.join('\n\n'), turns: turns);
}

Map<String, Object?> _text(String t) => {'type': 'text', 'text': t};

Map<String, Object?> _args(Object? a) {
  if (a is Map) return a.cast<String, Object?>();
  try {
    final v = jsonDecode('${a ?? '{}'}');
    return v is Map ? v.cast<String, Object?>() : const {};
  } on FormatException {
    return const {};
  }
}

/// One chat call to Claude, as [AiClient.chat] makes it of any provider.
/// No temperature (Claude's newest models turn one down) and no JSON mode:
/// the prompts that want JSON say so.
Future<AiReply> anthropicChat(
  HttpClient http,
  Duration timeout,
  AiEndpoint to,
  List<Map<String, Object?>> messages, {
  List<AiTool> tools = const [],
  int? maxTokens,
  void Function(String piece)? onText,
  bool Function()? stopped,
}) async {
  final t = anthropicTurns(messages);
  final body = <String, Object?>{
    'model': to.model,
    'max_tokens': math.max(maxTokens ?? _usual, _least),
    if (t.system.isNotEmpty) 'system': t.system,
    'messages': t.turns,
    if (tools.isNotEmpty)
      'tools': [
        for (final x in tools) {'name': x.name, 'description': x.description, 'input_schema': x.parameters},
      ],
    if (onText != null) 'stream': true,
  };
  final res = await _send(http, timeout, to, 'messages', body);
  if (onText == null) {
    final Object? v;
    try {
      v = jsonDecode(await _read(res, timeout));
    } on FormatException {
      throw const AiError(AiFailure.server, 'Claude sent back something that is not JSON');
    }
    return anthropicReply(v, sent: messages);
  }
  return _stream(res, timeout, messages, onText, stopped);
}

/// A Messages API reply as the app's.
AiReply anthropicReply(Object? v, {required List<Map<String, Object?>> sent}) {
  if (v is! Map) throw const AiError(AiFailure.server, 'Claude sent back no reply');
  if (v['type'] == 'error') throw errorFromResponse(500, jsonEncode(v));
  final blocks = [for (final b in (v['content'] as List? ?? const [])) if (b is Map) b.cast<String, Object?>()];
  _refused(v['stop_reason']);
  final text = blocks.where((b) => b['type'] == 'text').map((b) => '${b['text'] ?? ''}').join();
  final u = v['usage'];
  return AiReply(
    text: text,
    toolCalls: [
      for (final b in blocks)
        if (b['type'] == 'tool_use')
          AiToolCall(id: '${b['id']}', name: '${b['name']}', arguments: jsonEncode(b['input'] ?? const {})),
    ],
    usage: u is Map
        ? AiUsage(input: (u['input_tokens'] as num?)?.toInt() ?? 0, output: (u['output_tokens'] as num?)?.toInt() ?? 0)
        : guessUsage(sent, text),
    finish: _finish(v['stop_reason']),
    raw: blocks,
  );
}

/// Claude's reason for stopping in OpenAI's words.
String? _finish(Object? stop) => switch (stop) {
      'end_turn' || 'stop_sequence' => 'stop',
      'max_tokens' => 'length',
      'tool_use' => 'tool_calls',
      _ => stop as String?,
    };

/// A request Claude's safeguards declined: said, not sent again.
void _refused(Object? stop) {
  if (stop == 'refusal') {
    throw const AiError(AiFailure.request, 'Claude declined to answer this. Try another model or provider for it.');
  }
}

/// A streamed reply: the text given as it comes, the blocks put together
/// for sending back.
Future<AiReply> _stream(HttpClientResponse res, Duration timeout, List<Map<String, Object?>> sent,
    void Function(String) onText, bool Function()? stopped) async {
  final blocks = <int, Map<String, Object?>>{};
  final json = <int, StringBuffer>{};
  final text = StringBuffer();
  String? stop;
  var input = 0, output = 0;
  try {
    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter()).timeout(timeout)) {
      if (stopped != null && stopped()) break;
      if (!line.startsWith('data:')) continue;
      final Object? v;
      try {
        v = jsonDecode(line.substring(5).trim());
      } on FormatException {
        continue;
      }
      if (v is! Map) continue;
      switch (v['type']) {
        case 'error':
          throw errorFromResponse(500, jsonEncode(v));
        case 'message_start':
          final u = (v['message'] as Map?)?['usage'];
          if (u is Map) input = (u['input_tokens'] as num?)?.toInt() ?? input;
        case 'content_block_start':
          final i = (v['index'] as num?)?.toInt() ?? blocks.length;
          final b = ((v['content_block'] as Map?) ?? const {}).cast<String, Object?>();
          blocks[i] = Map.of(b);
          if (b['type'] == 'tool_use') json[i] = StringBuffer();
        case 'content_block_delta':
          final i = (v['index'] as num?)?.toInt() ?? 0;
          final d = (v['delta'] as Map?) ?? const {};
          final b = blocks[i] ??= {'type': 'text', 'text': ''};
          switch (d['type']) {
            case 'text_delta':
              final piece = '${d['text'] ?? ''}';
              b['text'] = '${b['text'] ?? ''}$piece';
              text.write(piece);
              if (piece.isNotEmpty) onText(piece);
            case 'input_json_delta':
              (json[i] ??= StringBuffer()).write(d['partial_json'] ?? '');
            case 'thinking_delta':
              b['thinking'] = '${b['thinking'] ?? ''}${d['thinking'] ?? ''}';
            case 'signature_delta':
              b['signature'] = '${b['signature'] ?? ''}${d['signature'] ?? ''}';
          }
        case 'message_delta':
          stop = ((v['delta'] as Map?)?['stop_reason'] as String?) ?? stop;
          final u = v['usage'];
          if (u is Map) output = (u['output_tokens'] as num?)?.toInt() ?? output;
      }
    }
  } on TimeoutException {
    throw const AiError(AiFailure.server, 'The answer stopped coming', slow: true);
  } on SocketException catch (e) {
    throw AiError(AiFailure.network, e.message);
  } on HttpException catch (e) {
    throw AiError(AiFailure.network, e.message);
  }
  _refused(stop);
  for (final e in json.entries) {
    blocks[e.key]?['input'] = _args(e.value.toString());
  }
  final ordered = [for (final k in blocks.keys.toList()..sort()) blocks[k]!];
  final whole = text.toString();
  return AiReply(
    text: whole,
    toolCalls: [
      for (final b in ordered)
        if (b['type'] == 'tool_use')
          AiToolCall(id: '${b['id']}', name: '${b['name']}', arguments: jsonEncode(b['input'] ?? const {})),
    ],
    usage: input + output > 0 ? AiUsage(input: input, output: output) : guessUsage(sent, whole),
    finish: _finish(stop),
    raw: ordered,
  );
}

/// The models a Claude key may use.
Future<List<String>> anthropicModels(HttpClient http, Duration timeout, AiEndpoint to) async {
  final res = await _send(http, timeout, to, 'models?limit=1000', null);
  final v = jsonDecode(await _read(res, timeout));
  final data = v is Map ? v['data'] : null;
  if (data is! List) return const [];
  return [
    for (final m in data)
      if (m is Map && m['id'] is String) m['id'] as String,
  ]..sort();
}

Future<HttpClientResponse> _send(
    HttpClient http, Duration timeout, AiEndpoint to, String path, Map<String, Object?>? body) async {
  HttpClientRequest? req;
  try {
    final url = to.path(path);
    req = body == null ? await http.getUrl(url) : await http.postUrl(url);
    _headers(to).forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(timeout);
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    final text = await _read(res, timeout).catchError((_) => '');
    throw errorFromResponse(res.statusCode, text, retryAfter: res.headers.value(HttpHeaders.retryAfterHeader));
  } on AiError {
    rethrow;
  } on TimeoutException {
    req?.abort();
    throw const AiError(AiFailure.server, 'Claude took too long to answer', slow: true);
  } on SocketException catch (e) {
    throw AiError(AiFailure.network, e.message);
  } on HandshakeException catch (e) {
    throw AiError(AiFailure.network, e.message);
  } on HttpException catch (e) {
    throw AiError(AiFailure.network, e.message);
  }
}

Future<String> _read(HttpClientResponse res, Duration timeout) async {
  try {
    return await res.transform(utf8.decoder).join().timeout(timeout);
  } on TimeoutException {
    throw const AiError(AiFailure.server, 'The answer stopped coming', slow: true);
  } on SocketException catch (e) {
    throw AiError(AiFailure.network, e.message);
  } on HttpException catch (e) {
    throw AiError(AiFailure.network, e.message);
  }
}
