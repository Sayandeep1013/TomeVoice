import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'secrets.dart';
import 'sources/sha256.dart';

/// ElevenLabs voices on the reader's own key ("bring your own key"):
/// reading aloud in a voice from the reader's ElevenLabs account, paid from
/// that account's credits. TomeVoice has no account and no server of its
/// own; the phone talks to ElevenLabs directly.
///
/// Each sentence is asked for once with its timings ("with-timestamps": when
/// each letter is said, so the word being read is lit as with any voice),
/// at normal speed, and kept on the phone: reading it again, or at another
/// speed (made here, its pitch kept), costs no more credits.
const elevenPrefix = 'eleven:';

/// Whether [voiceName] is an ElevenLabs voice.
bool isEleven(String? voiceName) => voiceName?.startsWith(elevenPrefix) ?? false;

/// An ElevenLabs model the reader can choose, and what a character costs in
/// it on ElevenLabs' plans (credits), for the estimate shown.
@immutable
class ElevenModel {
  const ElevenModel(this.id, this.label, this.note, this.creditsPerChar);

  final String id;
  final String label;
  final String note;
  final double creditsPerChar;

  static const flash = ElevenModel(
      'eleven_flash_v2_5', 'Flash', 'Quick to start, half the credits, 32 languages', 0.5);
  static const multilingual = ElevenModel(
      'eleven_multilingual_v2', 'Multilingual', 'The richest voice, full credits, 29 languages', 1);

  static const all = [flash, multilingual];

  static ElevenModel byId(String? id) => all.where((m) => m.id == id).firstOrNull ?? flash;
}

/// A voice in the reader's ElevenLabs account (or its library's defaults).
@immutable
class ElevenVoice {
  const ElevenVoice({required this.id, required this.name, this.description = '', this.language = ''});

  final String id;
  final String name;

  /// "British, calm, narration": its labels, for the list.
  final String description;

  /// The language it was made in ("en"), when ElevenLabs says.
  final String language;

  String get voiceName => '$elevenPrefix$id';

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'description': description, 'language': language};

  static ElevenVoice fromJson(Map<String, Object?> j) => ElevenVoice(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        language: j['language'] as String? ?? '',
      );

  /// One voice as ElevenLabs lists it (GET /v1/voices).
  static ElevenVoice? fromApi(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['voice_id'];
    if (id is! String || id.isEmpty) return null;
    final labels = raw['labels'] is Map ? raw['labels'] as Map : const {};
    final words = [
      for (final k in const ['accent', 'description', 'age', 'gender', 'use_case', 'descriptive'])
        if (labels[k] is String && (labels[k] as String).trim().isNotEmpty) (labels[k] as String).trim().replaceAll('_', ' '),
    ];
    final verified = raw['verified_languages'];
    var language = labels['language'] is String ? labels['language'] as String : '';
    if (language.isEmpty && verified is List && verified.isNotEmpty && verified.first is Map) {
      language = '${(verified.first as Map)['language'] ?? ''}';
    }
    return ElevenVoice(id: id, name: '${raw['name'] ?? id}'.trim(), description: words.join(', '), language: language);
  }
}

/// What the reader's ElevenLabs account has used this month.
@immutable
class ElevenUsage {
  const ElevenUsage({required this.used, required this.limit, this.resets, this.tier = ''});

  final int used;
  final int limit;
  final DateTime? resets;
  final String tier;

  int get left => (limit - used).clamp(0, limit);
}

/// Why ElevenLabs said no, said for the reader.
class ElevenError implements Exception {
  const ElevenError(this.message, {this.status});

  final String message;
  final int? status;

  /// It will likely pass: no answer (the network), busy, or ElevenLabs'
  /// own trouble. Not so for the key, the plan or the credits.
  bool get passing => status == null || status == 429 || status! >= 500;

  @override
  String toString() => message;
}

class ElevenLabs extends ChangeNotifier {
  ElevenLabs._();

  static final instance = ElevenLabs._();

  /// ElevenLabs' address (a fake one in tests).
  @visibleForTesting
  static String api = 'https://api.elevenlabs.io';

  /// The sample rate asked for: raw 16-bit PCM, which every plan gets.
  static const rate = 24000;

  static const _keyName = 'elevenlabs.key';
  static const _modelName = 'elevenlabs.model';

  /// Sentences kept on the phone, at most this much (the least lately
  /// heard go first): about 50 hours of speech.
  static const keepBytes = 400 * 1024 * 1024;

  Secrets? _secrets;
  Directory? _home;
  List<ElevenVoice> _voices = const [];

  /// Where the key is kept (Secrets, never in a backup) and the voices and
  /// sentences are: set as the library opens.
  Future<void> open(Directory root) async {
    _secrets = await Secrets.of(root);
    _home = Secrets.home ?? root;
    try {
      final f = _voicesFile;
      if (f != null && await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is List) {
          _voices = [for (final v in raw) if (v is Map) ElevenVoice.fromJson(v.cast<String, Object?>())];
        }
      }
    } on Object {
      // Listed again from ElevenLabs.
    }
    notifyListeners();
  }

  File? get _voicesFile => _home == null ? null : File('${_home!.path}/elevenlabs_voices.json');

  Directory get _cache {
    final base = _home?.path ?? Directory.systemTemp.path;
    return Directory('$base/elevenlabs')..createSync(recursive: true);
  }

  /// A key is set.
  bool get hasKey => (_secrets?[_keyName] ?? '').isNotEmpty;

  /// The key, shown only as its last four characters.
  String? get keyHint {
    final k = _secrets?[_keyName];
    if (k == null || k.isEmpty) return null;
    return k.length <= 4 ? k : '…${k.substring(k.length - 4)}';
  }

  ElevenModel get model => ElevenModel.byId(_secrets?[_modelName]);

  Future<void> setModel(ElevenModel m) async {
    await _secrets?.set(_modelName, m.id);
    notifyListeners();
  }

  List<ElevenVoice> get voices => _voices;

  ElevenVoice? byVoiceName(String? voiceName) {
    if (!isEleven(voiceName)) return null;
    final id = voiceName!.substring(elevenPrefix.length);
    return _voices.where((v) => v.id == id).firstOrNull;
  }

  /// Keep [key] after asking ElevenLabs for its voices with it: a key that
  /// does not work is not kept. Null forgets the key (and its voices).
  Future<void> setKey(String? key) async {
    final k = key?.trim() ?? '';
    if (k.isEmpty) {
      await _secrets?.set(_keyName, null);
      _voices = const [];
      try {
        await _voicesFile?.delete();
      } on Object {
        // Not there.
      }
      notifyListeners();
      return;
    }
    final list = await _listVoices(k);
    await _secrets?.set(_keyName, k);
    await _keepVoices(list);
  }

  /// The account's voices, asked again.
  Future<void> refreshVoices() async {
    final k = _secrets?[_keyName];
    if (k == null || k.isEmpty) return;
    await _keepVoices(await _listVoices(k));
  }

  Future<void> _keepVoices(List<ElevenVoice> list) async {
    _voices = list;
    try {
      await _voicesFile?.writeAsString(jsonEncode([for (final v in list) v.toJson()]));
    } on Object {
      // Listed again next time.
    }
    notifyListeners();
  }

  Future<List<ElevenVoice>> _listVoices(String key) async {
    final body = await _get('/v1/voices', key);
    final list = body is Map ? body['voices'] : null;
    if (list is! List) throw const ElevenError('ElevenLabs sent no voices.');
    return [for (final v in list) ElevenVoice.fromApi(v)].whereType<ElevenVoice>().toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// This month's credits. Null when the key may not read them (a key made
  /// with text to speech only).
  Future<ElevenUsage?> usage() async {
    final k = _secrets?[_keyName];
    if (k == null || k.isEmpty) return null;
    try {
      final body = await _get('/v1/user/subscription', k);
      if (body is! Map) return null;
      final reset = (body['next_character_count_reset_unix'] as num?)?.toInt();
      return ElevenUsage(
        used: (body['character_count'] as num?)?.toInt() ?? 0,
        limit: (body['character_limit'] as num?)?.toInt() ?? 0,
        resets: reset == null ? null : DateTime.fromMillisecondsSinceEpoch(reset * 1000),
        tier: '${body['tier'] ?? ''}',
      );
    } on ElevenError {
      return null;
    }
  }

  /// [text] said by [voice] at [speed], as reading aloud takes a sentence
  /// (SpeechService.synthesise): a WAV file, and where each word starts.
  /// Made at normal speed once and kept; another speed is made from it here.
  Future<Map<String, Object?>> synthesise({
    required String voiceId,
    required String text,
    required double speed,
    required String outDir,
    String? previousText,
    String? nextText,
  }) async {
    final key = _secrets?[_keyName];
    if (key == null || key.isEmpty) {
      throw const ElevenError('No ElevenLabs key. Add yours under Voices, ElevenLabs.');
    }
    final m = model;
    final made = await _kept(voiceId, m.id, text) ??
        await _ask(key, voiceId, m.id, text, previousText: previousText, nextText: nextText);
    final out = File('$outDir/eleven_${DateTime.now().microsecondsSinceEpoch}.wav');
    final s = speed.clamp(0.5, 3.0);
    final job = (pcm: made.pcm, speed: s);
    final wav = (s - 1).abs() < 0.01 ? _wav(made.pcm) : await compute(_stretched, job);
    await out.writeAsBytes(wav, flush: true);
    return {
      'wavPath': out.path,
      'engineId': 'tomevoice.elevenlabs',
      // Laid out as Android documents onRangeStart: start, end, then the
      // frame (SpeechService.decodeTimings tells the order by the frame
      // running past the text's length).
      'rangeEvents': [
        for (final w in made.words) {'start': w.start, 'end': w.end, 'frame': (w.frame / s).round()},
      ],
    };
  }

  /// The file name a sentence is kept under: what makes the speech (the
  /// same sentence, voice and model), hashed.
  String _cacheName(String voiceId, String modelId, String text) =>
      sha256Hex(utf8.encode(jsonEncode([voiceId, modelId, text]))).substring(0, 32);

  Future<_Made?> _kept(String voiceId, String modelId, String text) async {
    final name = _cacheName(voiceId, modelId, text);
    final pcm = File('${_cache.path}/$name.pcm');
    final words = File('${_cache.path}/$name.json');
    try {
      if (!await pcm.exists() || !await words.exists()) return null;
      final made = _Made(await pcm.readAsBytes(), _Made.wordsFrom(jsonDecode(await words.readAsString())));
      // Heard again: last to go when room is made.
      unawaited(pcm.setLastModified(DateTime.now()).catchError((Object _) {}));
      return made;
    } on Object {
      return null;
    }
  }

  Future<_Made> _ask(String key, String voiceId, String modelId, String text, {String? previousText, String? nextText}) async {
    // What comes before and after, so the voice goes on in one tone across
    // sentences (ElevenLabs reads them for context and does not charge for
    // them): the end of the one before, the start of the one after.
    final before = previousText?.trim() ?? '';
    final after = nextText?.trim() ?? '';
    final body = await _post(
      '/v1/text-to-speech/${Uri.encodeComponent(voiceId)}/with-timestamps?output_format=pcm_$rate',
      key,
      {
        'text': text,
        'model_id': modelId,
        if (before.isNotEmpty) 'previous_text': before.length > 600 ? before.substring(before.length - 600) : before,
        if (after.isNotEmpty) 'next_text': after.length > 600 ? after.substring(0, 600) : after,
      },
    );
    if (body is! Map || body['audio_base64'] is! String) throw const ElevenError('ElevenLabs sent no speech.');
    final pcm = base64Decode(body['audio_base64'] as String);
    final align = (body['alignment'] ?? body['normalized_alignment']) as Map?;
    final words = wordsOf(text, align);
    final made = _Made(pcm, words);
    final name = _cacheName(voiceId, modelId, text);
    try {
      await File('${_cache.path}/$name.pcm').writeAsBytes(pcm, flush: true);
      await File('${_cache.path}/$name.json').writeAsString(jsonEncode(_Made.wordsTo(words)));
      unawaited(_trim());
    } on Object {
      // Asked for again next time.
    }
    return made;
  }

  /// Where each word of [text] starts in the speech, from when each letter
  /// is said. ElevenLabs aligns the text as sent, letter for letter; if it
  /// sent fewer letters, words past them take the last time known.
  @visibleForTesting
  static List<({int start, int end, int frame})> wordsOf(String text, Map? align) {
    final starts = align?['character_start_times_seconds'];
    if (starts is! List || starts.isEmpty) return const [];
    return [
      for (final m in RegExp(r'\S+').allMatches(text))
        (
          start: m.start,
          end: m.end,
          frame: ((starts[m.start.clamp(0, starts.length - 1)] as num).toDouble() * rate).round(),
        ),
    ];
  }

  /// Least lately heard sentences go once there are more than [keepBytes].
  Future<void> _trim() async {
    try {
      final files = <File, FileStat>{};
      var total = 0;
      await for (final e in _cache.list()) {
        if (e is File && e.path.endsWith('.pcm')) {
          final s = await e.stat();
          files[e] = s;
          total += s.size;
        }
      }
      if (total <= keepBytes) return;
      final old = files.entries.toList()..sort((a, b) => a.value.modified.compareTo(b.value.modified));
      for (final e in old) {
        if (total <= keepBytes * 0.9) break;
        total -= e.value.size;
        await e.key.delete();
        final words = File(e.key.path.replaceFirst(RegExp(r'\.pcm$'), '.json'));
        if (await words.exists()) await words.delete();
      }
    } on Object {
      // Tried again after the next sentence.
    }
  }

  /// How many sentences are kept, and their size in bytes.
  Future<({int sentences, int bytes})> kept() async {
    var n = 0, bytes = 0;
    try {
      await for (final e in _cache.list()) {
        if (e is File && e.path.endsWith('.pcm')) {
          n++;
          bytes += await e.length();
        }
      }
    } on Object {
      // None.
    }
    return (sentences: n, bytes: bytes);
  }

  /// Forget every kept sentence (they are asked for, and paid for, again).
  Future<void> clearKept() async {
    try {
      await _cache.delete(recursive: true);
    } on Object {
      // Not there.
    }
  }

  Future<Object?> _get(String path, String key) => _send('GET', path, key, null);

  Future<Object?> _post(String path, String key, Map<String, Object?> body) => _send('POST', path, key, body);

  Future<Object?> _send(String method, String path, String key, Map<String, Object?>? body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, Uri.parse('$api$path'));
      req.headers
        ..set('xi-api-key', key)
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, 'TomeVoice');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 45));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200) return jsonDecode(text);
      throw ElevenError(_said(res.statusCode, text), status: res.statusCode);
    } on ElevenError {
      rethrow;
    } on TimeoutException {
      throw const ElevenError('ElevenLabs did not answer in time. Check the internet connection.');
    } on SocketException {
      throw const ElevenError('Could not reach ElevenLabs. Check the internet connection.');
    } on HandshakeException {
      throw const ElevenError('Could not reach ElevenLabs securely. Check the internet connection.');
    } finally {
      client.close(force: true);
    }
  }

  /// What ElevenLabs' answer [status] with [body] means for the reader.
  @visibleForTesting
  static String said(int status, String body) => _said(status, body);

  static String _said(int status, String body) {
    var detail = '';
    try {
      final j = jsonDecode(body);
      final d = j is Map ? j['detail'] : null;
      detail = d is Map ? '${d['status'] ?? ''} ${d['message'] ?? ''}' : '${d ?? ''}';
    } on Object {
      // Not JSON.
    }
    final low = detail.toLowerCase();
    if (status == 401 && low.contains('quota')) return 'Your ElevenLabs credits are used up for this month.';
    if (low.contains('quota_exceeded') || low.contains('quota')) return 'Your ElevenLabs credits are used up for this month.';
    if (status == 401 && low.contains('permission')) {
      return 'This ElevenLabs key may not do that. Give it Text to Speech and Voices (read) on elevenlabs.io.';
    }
    if (status == 401) return 'ElevenLabs did not accept the key. Check it on elevenlabs.io.';
    if (status == 402) return 'Your ElevenLabs plan does not allow this voice or model.';
    if (status == 404) return 'That ElevenLabs voice is not in your account any more.';
    if (status == 429) return 'ElevenLabs is busy, or too many requests at once. It tries again in a moment.';
    return 'ElevenLabs said no ($status).';
  }

  static Uint8List _wav(Uint8List pcm) {
    final samples = Float32List(pcm.length ~/ 2);
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    return WavCodec.encodePcm16(AudioBuffer(samples, rate));
  }

  static Uint8List _stretched(({Uint8List pcm, double speed}) job) {
    final samples = Float32List(job.pcm.length ~/ 2);
    final data = ByteData.sublistView(job.pcm);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    return WavCodec.encodePcm16(AudioBuffer(TimeStretchStage.stretch(samples, rate, job.speed), rate));
  }
}

/// A sentence as ElevenLabs made it: 16-bit PCM at [ElevenLabs.rate], and
/// where each word starts.
class _Made {
  _Made(this.pcm, this.words);

  final Uint8List pcm;
  final List<({int start, int end, int frame})> words;

  static List<({int start, int end, int frame})> wordsFrom(Object? raw) => [
        if (raw is List)
          for (final w in raw)
            if (w is List && w.length == 3) (start: w[0] as int, end: w[1] as int, frame: w[2] as int),
      ];

  static List<List<int>> wordsTo(List<({int start, int end, int frame})> words) => [
        for (final w in words) [w.start, w.end, w.frame],
      ];
}
