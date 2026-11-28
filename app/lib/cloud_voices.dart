import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tomevoice_audio/tomevoice_audio.dart';

import 'secrets.dart';
import 'sources/sha256.dart';

/// Cloud voices on the reader's own key: OpenAI, Google Cloud and Microsoft
/// Azure, a tenth of ElevenLabs' price or less (about $4 to $30 for a
/// million characters, a long novel), with free allowances every month at
/// Google and Azure. As with ElevenLabs (eleven_labs.dart), TomeVoice has no
/// account or server of its own: the phone talks to the service, with the
/// reader's key, and nothing else sees the text.
///
/// Each sentence is asked for once, at normal speed, and kept on the phone:
/// hearing it again, or at another speed (made here, its pitch kept), costs
/// nothing more. Where each word falls is the service's own when it says
/// (Google, from marks in the text) and otherwise measured from the speech
/// itself: its start and end, and each word's share by its letters and the
/// pauses its punctuation makes.
const cloudPrefix = 'cloud:';

/// Whether [voiceName] is a cloud voice ("cloud:openai:nova").
bool isCloud(String? voiceName) => voiceName?.startsWith(cloudPrefix) ?? false;

/// A voice service paid by the reader (ElevenLabs, the cloud voices) said
/// no: what to tell them, and whether it will likely pass by itself.
abstract interface class PaidVoiceError implements Exception {
  String get message;

  /// No answer (the network), busy, or the service's own trouble; not the
  /// key, the plan or the money.
  bool get passing;
}

class CloudError implements PaidVoiceError {
  const CloudError(this.message, {this.status, bool? passing}) : _passing = passing;

  @override
  final String message;
  final int? status;
  final bool? _passing;

  @override
  bool get passing => _passing ?? (status == null || status == 429 || status! >= 500);

  @override
  String toString() => message;
}

enum CloudService {
  openai('OpenAI', 'openai'),
  google('Google Cloud', 'google'),
  azure('Microsoft Azure', 'azure');

  const CloudService(this.label, this.code);

  final String label;

  /// In the voice name: "cloud:<code>:<voice>".
  final String code;

  static CloudService? byCode(String code) => values.where((s) => s.code == code).firstOrNull;
}

/// An OpenAI speech model.
@immutable
class OpenAiModel {
  const OpenAiModel(this.id, this.label, this.note, this.dollarsPerMillion);

  final String id;
  final String label;
  final String note;

  /// About this many US dollars for a million characters.
  final double dollarsPerMillion;

  static const mini = OpenAiModel('gpt-4o-mini-tts', 'Mini',
      'The newest, told how to read (the narration style below), about \$15 a million characters', 15);
  static const tts1 = OpenAiModel('tts-1', 'TTS-1', 'Quick and plain, \$15 a million characters', 15);
  static const hd = OpenAiModel('tts-1-hd', 'TTS-1 HD', 'Fuller sound, \$30 a million characters', 30);

  static const all = [mini, tts1, hd];

  static OpenAiModel byId(String? id) => all.where((m) => m.id == id).firstOrNull ?? mini;
}

/// A cloud voice the reader can read with.
@immutable
class CloudVoice {
  const CloudVoice({required this.service, required this.id, required this.name, this.language = '', this.note = ''});

  final CloudService service;

  /// The service's own name for it ("nova", "en-GB-Neural2-A").
  final String id;

  /// As shown ("Nova", "Neural2 A").
  final String name;

  /// Its language and region, "en-GB", when the service says.
  final String language;

  /// "Female, Neural2", for the list.
  final String note;

  String get voiceName => '$cloudPrefix${service.code}:$id';

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'language': language, 'note': note};

  static CloudVoice fromJson(CloudService s, Map<String, Object?> j) => CloudVoice(
        service: s,
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        language: j['language'] as String? ?? '',
        note: j['note'] as String? ?? '',
      );
}

/// What one voice costs, about, in US dollars for a million characters.
double cloudDollarsPerMillion(CloudService s, String voiceId, {OpenAiModel? model}) => switch (s) {
      CloudService.openai => (model ?? OpenAiModel.mini).dollarsPerMillion,
      CloudService.google => voiceId.contains('Chirp')
          ? 30
          : voiceId.contains('Studio')
              ? 160
              : voiceId.contains('Standard')
                  ? 4
                  : 16,
      CloudService.azure => voiceId.contains('HD') ? 30 : 15,
    };

class CloudVoices extends ChangeNotifier {
  CloudVoices._();

  static final instance = CloudVoices._();

  /// The services' addresses (fakes in tests).
  @visibleForTesting
  static String openAiApi = 'https://api.openai.com';
  @visibleForTesting
  static String googleApi = 'https://texttospeech.googleapis.com';

  /// Azure's, for [region]; a fake in tests.
  @visibleForTesting
  static String Function(String region) azureApi = (region) => 'https://$region.tts.speech.microsoft.com';

  /// Every service is asked for 16-bit PCM at this rate.
  static const rate = 24000;

  /// Sentences kept on the phone, at most this much for all three.
  static const keepBytes = 400 * 1024 * 1024;

  /// OpenAI's voices: it has no list to ask for. The last two only speak
  /// with the Mini model.
  static const openAiVoices = [
    ('alloy', 'Alloy', 'Even, neutral'),
    ('ash', 'Ash', 'Warm, low'),
    ('ballad', 'Ballad', 'Soft, British'),
    ('coral', 'Coral', 'Bright, friendly'),
    ('echo', 'Echo', 'Clear, male'),
    ('fable', 'Fable', 'Storyteller, British'),
    ('nova', 'Nova', 'Lively, female'),
    ('onyx', 'Onyx', 'Deep, male'),
    ('sage', 'Sage', 'Calm, gentle'),
    ('shimmer', 'Shimmer', 'Light, female'),
    ('verse', 'Verse', 'Expressive'),
    ('marin', 'Marin', 'Natural, the newest'),
    ('cedar', 'Cedar', 'Natural, the newest'),
  ];
  static const _miniOnly = {'ballad', 'verse', 'marin', 'cedar'};

  /// What the Mini model is told, unless the reader writes their own.
  static const defaultStyle = 'Read as an audiobook narrator: natural, warm and steady, '
      'with the pauses the punctuation asks for. Voice the dialogue lightly, never act it.';

  Secrets? _secrets;
  Directory? _home;
  final Map<CloudService, List<CloudVoice>> _listed = {};

  Future<void> open(Directory root) async {
    _secrets = await Secrets.of(root);
    _home = Secrets.home ?? root;
    for (final s in [CloudService.google, CloudService.azure]) {
      try {
        final f = _listFile(s);
        if (f != null && await f.exists()) {
          final raw = jsonDecode(await f.readAsString());
          if (raw is List) _listed[s] = [for (final v in raw) if (v is Map) CloudVoice.fromJson(s, v.cast<String, Object?>())];
        }
      } on Object {
        // Listed again when the key is saved.
      }
    }
    notifyListeners();
  }

  File? _listFile(CloudService s) => _home == null ? null : File('${_home!.path}/cloud_voices_${s.code}.json');

  Directory get _cache {
    final base = _home?.path ?? Directory.systemTemp.path;
    return Directory('$base/cloud_voices')..createSync(recursive: true);
  }

  String _keyName(CloudService s) => 'cloud.${s.code}.key';

  bool hasKey(CloudService s) => (_secrets?[_keyName(s)] ?? '').isNotEmpty;

  bool get anyKey => CloudService.values.any(hasKey);

  /// The key, shown only as its last four characters.
  String? keyHint(CloudService s) {
    final k = _secrets?[_keyName(s)];
    if (k == null || k.isEmpty) return null;
    return k.length <= 4 ? k : '…${k.substring(k.length - 4)}';
  }

  /// Azure's region ("westeurope"), which its key belongs to.
  String get azureRegion => _secrets?['cloud.azure.region'] ?? '';

  OpenAiModel get openAiModel => OpenAiModel.byId(_secrets?['cloud.openai.model']);

  Future<void> setOpenAiModel(OpenAiModel m) async {
    await _secrets?.set('cloud.openai.model', m.id);
    notifyListeners();
  }

  /// How the Mini model is told to read.
  String get openAiStyle => _secrets?['cloud.openai.style'] ?? defaultStyle;

  Future<void> setOpenAiStyle(String? style) async {
    final s = style?.trim() ?? '';
    await _secrets?.set('cloud.openai.style', s.isEmpty || s == defaultStyle ? null : s);
    notifyListeners();
  }

  /// [s]'s voices: OpenAI's fixed few (those its model speaks), the others
  /// as the service listed them when the key was saved.
  List<CloudVoice> voicesOf(CloudService s) {
    if (s == CloudService.openai) {
      if (!hasKey(s)) return const [];
      final mini = openAiModel == OpenAiModel.mini;
      return [
        for (final (id, name, note) in openAiVoices)
          if (mini || !_miniOnly.contains(id)) CloudVoice(service: s, id: id, name: name, note: note),
      ];
    }
    return hasKey(s) ? (_listed[s] ?? const []) : const [];
  }

  CloudVoice? byVoiceName(String? voiceName) {
    if (!isCloud(voiceName)) return null;
    final rest = voiceName!.substring(cloudPrefix.length);
    final i = rest.indexOf(':');
    if (i < 0) return null;
    final s = CloudService.byCode(rest.substring(0, i));
    if (s == null) return null;
    final id = rest.substring(i + 1);
    return voicesOf(s).where((v) => v.id == id).firstOrNull ??
        // A voice from a list not loaded yet: still the reader's.
        (hasKey(s) ? CloudVoice(service: s, id: id, name: id) : null);
  }

  /// About what [voiceName] costs for a million characters, in US dollars.
  double? dollarsPerMillion(String? voiceName) {
    final v = byVoiceName(voiceName);
    return v == null ? null : cloudDollarsPerMillion(v.service, v.id, model: openAiModel);
  }

  /// Keep [key] (and Azure's [region]) once the service has answered to it:
  /// a key that does not work is not kept. Null forgets it.
  Future<void> setKey(CloudService s, String? key, {String? region}) async {
    final k = key?.trim() ?? '';
    if (k.isEmpty) {
      await _secrets?.set(_keyName(s), null);
      if (s == CloudService.azure) await _secrets?.set('cloud.azure.region', null);
      _listed.remove(s);
      try {
        await _listFile(s)?.delete();
      } on Object {
        // Not there.
      }
      notifyListeners();
      return;
    }
    final r = (region ?? '').trim().toLowerCase().replaceAll(' ', '');
    if (s == CloudService.azure && r.isEmpty) throw const CloudError('Azure needs the region the key is for, as "westeurope".', passing: false);
    final list = await _list(s, k, r);
    await _secrets?.set(_keyName(s), k);
    if (s == CloudService.azure) await _secrets?.set('cloud.azure.region', r);
    await _keep(s, list);
  }

  Future<void> refreshVoices(CloudService s) async {
    final k = _secrets?[_keyName(s)];
    if (k == null || k.isEmpty) return;
    await _keep(s, await _list(s, k, azureRegion));
  }

  Future<void> _keep(CloudService s, List<CloudVoice>? list) async {
    if (list != null) {
      _listed[s] = list;
      try {
        await _listFile(s)?.writeAsString(jsonEncode([for (final v in list) v.toJson()]));
      } on Object {
        // Listed again next time.
      }
    }
    notifyListeners();
  }

  /// The service's voices, which also proves the key. OpenAI has no list:
  /// its models are asked for instead.
  Future<List<CloudVoice>?> _list(CloudService s, String key, String region) async {
    switch (s) {
      case CloudService.openai:
        await _send(s, 'GET', Uri.parse('$openAiApi/v1/models/tts-1'), headers: {'Authorization': 'Bearer $key'});
        return null;
      case CloudService.google:
        final body = jsonDecode(utf8.decode(await _send(s, 'GET', Uri.parse('$googleApi/v1/voices?key=${Uri.encodeQueryComponent(key)}'))));
        final list = body is Map ? body['voices'] : null;
        if (list is! List) throw const CloudError('Google sent no voices.');
        return [
          for (final v in list)
            if (v is Map && v['name'] is String) _googleVoice(v),
        ]..sort(_byLanguageThenName);
      case CloudService.azure:
        final body = jsonDecode(utf8.decode(await _send(s, 'GET', Uri.parse('${azureApi(region)}/cognitiveservices/voices/list'),
            headers: {'Ocp-Apim-Subscription-Key': key})));
        if (body is! List) throw const CloudError('Azure sent no voices.');
        return [
          for (final v in body)
            if (v is Map && v['ShortName'] is String && '${v['VoiceType'] ?? 'Neural'}' == 'Neural')
              CloudVoice(
                service: s,
                id: v['ShortName'] as String,
                name: '${v['DisplayName'] ?? v['LocalName'] ?? v['ShortName']}',
                language: '${v['Locale'] ?? ''}',
                note: [
                  if (v['Gender'] is String) v['Gender'],
                  if ('${v['ShortName']}'.contains('Multilingual')) 'speaks many languages',
                  if ('${v['ShortName']}'.contains('HD')) 'HD',
                ].join(', '),
              ),
        ]..sort(_byLanguageThenName);
    }
  }

  static int _byLanguageThenName(CloudVoice a, CloudVoice b) {
    final l = a.language.compareTo(b.language);
    return l != 0 ? l : a.name.compareTo(b.name);
  }

  /// "en-GB-Neural2-A" as "Neural2 A", noted with its gender and kind.
  static CloudVoice _googleVoice(Map v) {
    final id = v['name'] as String;
    final langs = v['languageCodes'];
    final lang = langs is List && langs.isNotEmpty ? '${langs.first}' : '';
    final parts = id.split('-');
    final name = parts.length > 2 ? parts.sublist(2).join(' ') : id;
    final gender = '${v['ssmlGender'] ?? ''}';
    return CloudVoice(
      service: CloudService.google,
      id: id,
      name: name,
      language: lang,
      note: [
        if (gender.isNotEmpty && gender != 'SSML_VOICE_GENDER_UNSPECIFIED') '${gender[0]}${gender.substring(1).toLowerCase()}',
        '\$${cloudDollarsPerMillion(CloudService.google, id).round()} a million characters',
      ].join(', '),
    );
  }

  /// [text] said by [voiceName] at [speed], as reading aloud takes a
  /// sentence (SpeechService.synthesise): a WAV file, and where each word
  /// starts. Made at normal speed once and kept.
  Future<Map<String, Object?>> synthesise({
    required String voiceName,
    required String text,
    required double speed,
    required String outDir,
  }) async {
    final v = byVoiceName(voiceName);
    if (v == null) throw const CloudError('That cloud voice has no key now. Add it under Voices, Cloud voices.', passing: false);
    final key = _secrets?[_keyName(v.service)] ?? '';
    final variant = v.service == CloudService.openai
        ? '${openAiModel.id}|${openAiModel == OpenAiModel.mini ? openAiStyle : ''}'
        : '';
    final name = sha256Hex(utf8.encode(jsonEncode([v.service.code, v.id, variant, text]))).substring(0, 32);
    final made = await _kept(name) ?? await _make(v, key, text, name);
    final out = File('$outDir/cloud_${DateTime.now().microsecondsSinceEpoch}.wav');
    final s = speed.clamp(0.5, 3.0);
    final wav = (s - 1).abs() < 0.01 ? _wav(made.pcm) : await compute(_stretched, (pcm: made.pcm, speed: s));
    await out.writeAsBytes(wav, flush: true);
    return {
      'wavPath': out.path,
      'engineId': 'tomevoice.cloud.${v.service.code}',
      'rangeEvents': [
        for (final w in made.words) {'start': w.start, 'end': w.end, 'frame': (w.frame / s).round()},
      ],
    };
  }

  Future<_Made?> _kept(String name) async {
    final pcm = File('${_cache.path}/$name.pcm');
    final words = File('${_cache.path}/$name.json');
    try {
      if (!await pcm.exists() || !await words.exists()) return null;
      final made = _Made(await pcm.readAsBytes(), _Made.wordsFrom(jsonDecode(await words.readAsString())));
      unawaited(pcm.setLastModified(DateTime.now()).catchError((Object _) {}));
      return made;
    } on Object {
      return null;
    }
  }

  Future<_Made> _make(CloudVoice v, String key, String text, String name) async {
    final Uint8List pcm;
    List<({int start, int end, int frame})>? words;
    switch (v.service) {
      case CloudService.openai:
        final m = openAiModel;
        pcm = await _send(v.service, 'POST', Uri.parse('$openAiApi/v1/audio/speech'),
            headers: {'Authorization': 'Bearer $key'},
            json: {
              'model': m.id,
              'voice': v.id,
              'input': text,
              'response_format': 'pcm',
              if (m == OpenAiModel.mini) 'instructions': openAiStyle,
            });
      case CloudService.google:
        // Marks before each word, so Google says when each is said
        // (charged for the words only). Chirp and Studio voices take no
        // marks: their words are measured instead.
        final marks = !v.id.contains('Chirp') && !v.id.contains('Studio') && !v.id.contains('Journey');
        final spans = RegExp(r'\S+').allMatches(text).toList();
        final ssml = StringBuffer('<speak>');
        var at = 0;
        for (var i = 0; i < spans.length; i++) {
          ssml
            ..write(_xml(text.substring(at, spans[i].start)))
            ..write('<mark name="w$i"/>')
            ..write(_xml(spans[i].group(0)!));
          at = spans[i].end;
        }
        ssml
          ..write(_xml(text.substring(at)))
          ..write('</speak>');
        final lang = v.language.isNotEmpty ? v.language : v.id.split('-').take(2).join('-');
        final body = jsonDecode(utf8.decode(await _send(
          v.service,
          'POST',
          Uri.parse('$googleApi/v1beta1/text:synthesize?key=${Uri.encodeQueryComponent(key)}'),
          json: {
            'input': marks ? {'ssml': ssml.toString()} : {'text': text},
            'voice': {'languageCode': lang, 'name': v.id},
            'audioConfig': {'audioEncoding': 'LINEAR16', 'sampleRateHertz': rate},
            if (marks) 'enableTimePointing': ['SSML_MARK'],
          },
        )));
        if (body is! Map || body['audioContent'] is! String) throw const CloudError('Google sent no speech.');
        pcm = pcmOfWav(base64Decode(body['audioContent'] as String));
        final points = body['timepoints'];
        if (marks && points is List && points.isNotEmpty) {
          final times = <int, int>{
            for (final p in points)
              if (p is Map && '${p['markName']}'.startsWith('w'))
                (int.tryParse('${p['markName']}'.substring(1)) ?? -1): (((p['timeSeconds'] as num?) ?? 0) * rate).round(),
          };
          var last = 0;
          words = [
            for (var i = 0; i < spans.length; i++) (start: spans[i].start, end: spans[i].end, frame: last = times[i] ?? last),
          ];
        }
      case CloudService.azure:
        final lang = v.language.isNotEmpty ? v.language : 'en-US';
        pcm = await _send(v.service, 'POST', Uri.parse('${azureApi(azureRegion)}/cognitiveservices/v1'),
            headers: {
              'Ocp-Apim-Subscription-Key': key,
              'X-Microsoft-OutputFormat': 'raw-24khz-16bit-mono-pcm',
            },
            ssml: "<speak version='1.0' xml:lang='$lang'><voice name='${_xml(v.id)}'>${_xml(text)}</voice></speak>");
    }
    if (pcm.length < 2) throw CloudError('${v.service.label} sent no speech.');
    final made = _Made(pcm, words ?? estimateWords(text, pcm));
    try {
      await File('${_cache.path}/$name.pcm').writeAsBytes(pcm, flush: true);
      await File('${_cache.path}/$name.json').writeAsString(jsonEncode(_Made.wordsTo(made.words)));
      unawaited(_trim());
    } on Object {
      // Asked for again next time.
    }
    return made;
  }

  static String _xml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

  /// The samples of a WAV file (Google's LINEAR16): what its "data" chunk
  /// holds, or the whole if it has none.
  @visibleForTesting
  static Uint8List pcmOfWav(Uint8List wav) {
    if (wav.length < 12 || String.fromCharCodes(wav.sublist(0, 4)) != 'RIFF') return wav;
    final d = ByteData.sublistView(wav);
    var i = 12;
    while (i + 8 <= wav.length) {
      final id = String.fromCharCodes(wav.sublist(i, i + 4));
      final size = d.getUint32(i + 4, Endian.little);
      if (id == 'data') return Uint8List.sublistView(wav, i + 8, math.min(wav.length, i + 8 + size));
      i += 8 + size + (size & 1);
    }
    return wav;
  }

  /// Where each word of [text] is said in [pcm], for a service that does
  /// not say: the speech runs from its first sound to its last, and each
  /// word takes its share by its letters, with the pause after a comma or
  /// a full stop counted in.
  @visibleForTesting
  static List<({int start, int end, int frame})> estimateWords(String text, Uint8List pcm) {
    final spans = RegExp(r'\S+').allMatches(text).toList();
    if (spans.isEmpty) return const [];
    final data = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    const window = rate ~/ 100; // 10 ms
    bool loud(int w) {
      var peak = 0;
      final end = math.min(n, (w + 1) * window);
      for (var i = w * window; i < end; i++) {
        final s = data.getInt16(i * 2, Endian.little).abs();
        if (s > peak) peak = s;
      }
      return peak > 800;
    }

    final windows = (n + window - 1) ~/ window;
    var first = 0;
    while (first < windows && !loud(first)) {
      first++;
    }
    var last = windows - 1;
    while (last > first && !loud(last)) {
      last--;
    }
    final from = first >= windows ? 0 : first * window;
    final to = first >= windows ? n : math.min(n, (last + 1) * window);
    double pause(String w) => RegExp(r'[.!?…]["”’)\]]*$').hasMatch(w)
        ? 5.0
        : RegExp(r'[,;:—–]["”’)\]]*$').hasMatch(w)
            ? 2.5
            : 0.0;
    double weight(String w) =>
        math.max(1, w.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').length) + 1.0 + pause(w);

    final weights = [for (final m in spans) weight(m.group(0)!)];
    // The last word's own pause comes after the speech has ended.
    final total = weights.fold<double>(0, (a, b) => a + b) - pause(spans.last.group(0)!);
    var sum = 0.0;
    return [
      for (var i = 0; i < spans.length; i++)
        () {
          final frame = from + ((to - from) * (sum / total)).round();
          sum += weights[i];
          return (start: spans[i].start, end: spans[i].end, frame: frame);
        }(),
    ];
  }

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

  Future<void> clearKept() async {
    try {
      await _cache.delete(recursive: true);
    } on Object {
      // Not there.
    }
  }

  Future<Uint8List> _send(
    CloudService s,
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, Object?>? json,
    String? ssml,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'TomeVoice');
      headers.forEach(req.headers.set);
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(json)));
      } else if (ssml != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/ssml+xml');
        req.add(utf8.encode(ssml));
      }
      final res = await req.close().timeout(const Duration(seconds: 45));
      final chunks = <int>[];
      await for (final c in res) {
        chunks.addAll(c);
      }
      final body = Uint8List.fromList(chunks);
      if (res.statusCode == 200) return body;
      throw said(s, res.statusCode, utf8.decode(body, allowMalformed: true));
    } on CloudError {
      rethrow;
    } on TimeoutException {
      throw CloudError('${s.label} did not answer in time. Check the internet connection.');
    } on SocketException {
      throw CloudError('Could not reach ${s.label}. Check the internet connection.');
    } on HandshakeException {
      throw CloudError('Could not reach ${s.label} securely. Check the internet connection.');
    } finally {
      client.close(force: true);
    }
  }

  /// What [s]'s answer [status] with [body] means for the reader.
  @visibleForTesting
  static CloudError said(CloudService s, int status, String body) {
    var detail = '';
    try {
      final j = jsonDecode(body);
      final e = j is Map ? j['error'] : null;
      detail = e is Map ? '${e['code'] ?? ''} ${e['status'] ?? ''} ${e['message'] ?? ''}' : '${e ?? ''}';
    } on Object {
      detail = body;
    }
    final low = detail.toLowerCase();
    final name = s.label;
    if (low.contains('insufficient_quota') || low.contains('billing')) {
      return CloudError('Your $name account has no credit left, or no billing set up.', status: status, passing: false);
    }
    if (s == CloudService.google && (low.contains('has not been used') || low.contains('disabled') || low.contains('service_disabled'))) {
      return CloudError('Turn on the Cloud Text-to-Speech API for this key\'s project in the Google Cloud console.',
          status: status, passing: false);
    }
    if (status == 400 && s == CloudService.google && low.contains('api key not valid')) {
      return CloudError('Google did not accept the key. Check it in the Google Cloud console.', status: status, passing: false);
    }
    if (status == 401 || status == 403) {
      return CloudError(
          s == CloudService.azure
              ? 'Azure did not accept the key for that region. Check both on portal.azure.com.'
              : '$name did not accept the key. Check it on the $name site.',
          status: status,
          passing: false);
    }
    if (status == 404) return CloudError('$name does not have that voice.', status: status, passing: false);
    if (status == 429) return CloudError('$name is busy, or too many requests at once. It tries again in a moment.', status: status);
    if (status >= 500) return CloudError('$name had trouble ($status). It tries again in a moment.', status: status);
    return CloudError('$name said no ($status).', status: status, passing: false);
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
