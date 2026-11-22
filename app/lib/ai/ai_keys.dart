import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../safe_file.dart';
import '../secrets.dart';
import 'ai_client.dart';

/// The providers offered by name, each with the address its OpenAI-style
/// endpoint has; any other is [custom], with the address the reader gives.
enum AiProvider {
  gemini('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai',
      note: "A free key from Google AI Studio. Its free quota is per Google project, so keys from one project "
          'share it. Google may use free-tier requests to improve its models.',
      embeds: true),
  inception('Inception (Mercury)', 'https://api.inceptionlabs.ai/v1',
      note: 'Mercury models: fast, with a context of a million tokens. Good for building memories.'),
  openrouter('OpenRouter', 'https://openrouter.ai/api/v1',
      note: 'One key for many models, some of them free.'),
  groq('Groq', 'https://api.groq.com/openai/v1', note: 'Fast open models, with a free tier.'),
  openai('OpenAI', 'https://api.openai.com/v1', note: 'Paid by use.', embeds: true),
  agentrouter('AgentRouter', 'https://agentrouter.org/v1',
      note: 'A relay to many models (Claude, GPT, DeepSeek and others), with credit when you sign up. Your text '
          'passes through it on its way to the model.'),
  milionseek('100milionseek', 'https://100milionseek.top/v1',
      note: 'DeepSeek models, free for now, through a relay run by people not named on its site: your text '
          'passes through it. Its keys start with hms-.'),
  custom('Another service', '', note: 'Any service that speaks the OpenAI chat format: give its address.');

  const AiProvider(this.label, this.baseUrl, {required this.note, this.embeds = false});

  final String label;
  final String baseUrl;
  final String note;

  /// Whether it has an embeddings endpoint, for meaning search.
  final bool embeds;

  static AiProvider byName(String? name) => values.firstWhere((p) => p.name == name, orElse: () => custom);
}

/// What a key is used for. Each job has its own order of keys, and a key
/// may name a different model for each.
enum AiJob {
  /// Making each chapter's notes: many long calls, so cheap and fast.
  builder('Building memories', 'Reads each chapter once and keeps its notes. Many calls: a cheap, fast model.'),

  /// Talk, Explain, recaps, theories: the best model there is.
  talker('Talking', 'Talk, Explain, recaps and theories: the best model you have.'),

  /// Vectors for meaning search; only some providers can.
  embedder('Meaning search', 'Finds a place by what it means, not only its words. Optional.');

  const AiJob(this.label, this.about);

  final String label;
  final String about;
}

/// One key: its provider, address, the secret itself, and the model it
/// uses for each job it does.
@immutable
class AiKey {
  const AiKey({
    required this.id,
    required this.provider,
    required this.label,
    required this.baseUrl,
    required this.secret,
    this.models = const {},
    this.dailyCap,
  });

  final String id;
  final AiProvider provider;

  /// The reader's name for it: "Gemini (work)", "Mercury 2".
  final String label;
  final String baseUrl;
  final String secret;

  /// The model for each job it does; a job it has none for, it does not do.
  final Map<AiJob, String> models;

  /// The most tokens it may use in a day (null: no limit of the reader's).
  /// Reached, it rests until midnight, and the next key takes over.
  final int? dailyCap;

  AiEndpoint endpoint(AiJob job) => AiEndpoint(baseUrl: baseUrl, key: secret, model: models[job] ?? '');

  /// The secret shown: its last four characters.
  String get masked => secret.length <= 4 ? '••••' : '••••${secret.substring(secret.length - 4)}';

  AiKey copyWith({String? label, String? baseUrl, String? secret, Map<AiJob, String>? models, AiProvider? provider}) =>
      AiKey(
        id: id,
        provider: provider ?? this.provider,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        secret: secret ?? this.secret,
        models: models ?? this.models,
        dailyCap: dailyCap,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'provider': provider.name,
        'label': label,
        'baseUrl': baseUrl,
        'secret': secret,
        'models': {for (final e in models.entries) e.key.name: e.value},
        if (dailyCap != null) 'dailyCap': dailyCap,
      };

  static AiKey? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = v['id'], secret = v['secret'], base = v['baseUrl'];
    if (id is! String || secret is! String || base is! String) return null;
    final models = <AiJob, String>{};
    final m = v['models'];
    if (m is Map) {
      for (final job in AiJob.values) {
        final model = m[job.name];
        if (model is String && model.isNotEmpty) models[job] = model;
      }
    }
    return AiKey(
      id: id,
      provider: AiProvider.byName(v['provider'] as String?),
      label: v['label'] as String? ?? '',
      baseUrl: base,
      secret: secret,
      models: models,
      dailyCap: (v['dailyCap'] as num?)?.toInt(),
    );
  }
}

/// Why a key is not used now: resting until its quota comes back, or
/// refused (until the reader changes it, or tests it again).
@immutable
class KeyState {
  const KeyState({this.restUntil, this.refused, this.lastError});

  final DateTime? restUntil;
  final String? refused;
  final String? lastError;

  bool restingAt(DateTime now) => restUntil != null && restUntil!.isAfter(now);
}

/// A day's use of one key.
class DayUse {
  DayUse({this.calls = 0, this.input = 0, this.output = 0});

  int calls;
  int input;
  int output;

  Map<String, Object?> toJson() => {'calls': calls, 'in': input, 'out': output};

  static DayUse fromJson(Object? v) => v is Map
      ? DayUse(
          calls: (v['calls'] as num?)?.toInt() ?? 0,
          input: (v['in'] as num?)?.toInt() ?? 0,
          output: (v['out'] as num?)?.toInt() ?? 0,
        )
      : DayUse();
}

/// One call to the AI, as the log of what was sent keeps it.
class AiLogEntry {
  const AiLogEntry({
    required this.at,
    required this.job,
    required this.provider,
    required this.model,
    this.about,
    this.input = 0,
    this.output = 0,
  });

  final DateTime at;
  final AiJob job;

  /// The book it was about, when known.
  final String? about;
  final String provider;
  final String model;
  final int input;
  final int output;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'job': job.name,
        if (about != null) 'about': about,
        'provider': provider,
        'model': model,
        'in': input,
        'out': output,
      };

  static AiLogEntry? fromJson(Object? v) {
    if (v is! Map) return null;
    final at = DateTime.tryParse(v['at'] as String? ?? '');
    final job = AiJob.values.where((j) => j.name == v['job']).firstOrNull;
    if (at == null || job == null) return null;
    return AiLogEntry(
      at: at,
      job: job,
      about: v['about'] as String?,
      provider: v['provider'] as String? ?? '',
      model: v['model'] as String? ?? '',
      input: (v['in'] as num?)?.toInt() ?? 0,
      output: (v['out'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The reader's keys, kept with the catalogue passwords (in the app's own
/// storage, never in a backup), each job's order of them, and how each has
/// been used. One for the app; [attach] reads it.
class AiRing extends ChangeNotifier {
  AiRing._();

  static final instance = AiRing._();

  static const _secretName = 'ai.ring';

  Secrets? _secrets;
  File? _useFile;

  final _keys = <AiKey>[];
  final _order = <AiJob, List<String>>{};
  final _state = <String, KeyState>{};

  /// What was sent, oldest first: the last [logKept] calls, kept on this
  /// phone alone.
  List<AiLogEntry> get log => List.unmodifiable(_log);
  final _log = <AiLogEntry>[];
  static const logKept = 300;
  File? _logFile;
  Timer? _logTimer;

  /// A call made for [job] with [key], about [about].
  void logCall(AiJob job, AiKey key, {String? about, AiUsage? usage, DateTime? now}) {
    _log.add(AiLogEntry(
      at: now ?? DateTime.now(),
      job: job,
      about: about,
      provider: key.provider.label,
      model: key.models[job] ?? '',
      input: usage?.input ?? 0,
      output: usage?.output ?? 0,
    ));
    if (_log.length > logKept) _log.removeRange(0, _log.length - logKept);
    notifyListeners();
    _logTimer ??= Timer(const Duration(seconds: 2), () {
      _logTimer = null;
      unawaited(_saveLog());
    });
  }

  Future<void> clearLog() async {
    _log.clear();
    notifyListeners();
    await _saveLog();
  }

  Future<void> _saveLog() async {
    final f = _logFile;
    if (f == null) return;
    await writeSafely(f, jsonEncode([for (final e in _log) e.toJson()]));
  }

  /// key id → day (yyyy-mm-dd) → use. Thirty days are kept.
  final _use = <String, Map<String, DayUse>>{};

  List<AiKey> get keys => List.unmodifiable(_keys);
  bool get hasKeys => _keys.isNotEmpty;

  /// The reader agreed to what is sent ([ensureAiConsent]): until then,
  /// nothing is. Adding a key is done only after agreeing, so it counts.
  bool get consented => _consented;
  var _consented = false;

  Future<void> consent() async {
    if (_consented) return;
    _consented = true;
    await _save();
  }

  KeyState stateOf(String id) => _state[id] ?? const KeyState();

  /// Read the ring of the library at [root]: the keys from its secrets, the
  /// use from a file beside them.
  Future<void> attach(Directory root) async {
    final secrets = await Secrets.of(root);
    _secrets = secrets;
    _useFile = File('${(Secrets.home ?? root).path}/.ai_usage.json');
    _logFile = File('${(Secrets.home ?? root).path}/.ai_log.json');
    _log.clear();
    try {
      final f = _logFile!;
      if (await f.exists()) {
        final v = jsonDecode(await f.readAsString());
        if (v is List) _log.addAll(v.map(AiLogEntry.fromJson).whereType<AiLogEntry>());
      }
    } on Object {
      // Only a record: lost, it starts again.
    }
    _keys.clear();
    _order.clear();
    _consented = false;
    try {
      final v = jsonDecode(secrets[_secretName] ?? '{}');
      if (v is Map) {
        _consented = v['consent'] == true;
        for (final k in (v['keys'] as List? ?? const [])) {
          final key = AiKey.fromJson(k);
          if (key != null) _keys.add(key);
        }
        final o = v['order'];
        if (o is Map) {
          for (final job in AiJob.values) {
            final ids = o[job.name];
            if (ids is List) _order[job] = [for (final i in ids) if (i is String) i];
          }
        }
        final st = v['state'];
        if (st is Map) {
          for (final e in st.entries) {
            final s = e.value;
            if (e.key is! String || s is! Map) continue;
            _state[e.key as String] = KeyState(
              restUntil: DateTime.tryParse(s['restUntil'] as String? ?? ''),
              refused: s['refused'] as String?,
            );
          }
        }
      }
    } on FormatException {
      // Unreadable: the reader adds the keys again.
    }
    try {
      final file = _useFile!;
      if (await file.exists()) {
        final v = jsonDecode(await file.readAsString());
        if (v is Map) {
          for (final e in v.entries) {
            final days = e.value;
            if (e.key is! String || days is! Map) continue;
            _use[e.key as String] = {for (final d in days.entries) d.key as String: DayUse.fromJson(d.value)};
          }
        }
      }
    } on Object {
      // Use is only a guide: lost, it starts again.
    }
    notifyListeners();
  }

  /// For tests: an empty ring kept nowhere.
  @visibleForTesting
  void reset() {
    _secrets = null;
    _useFile = null;
    _keys.clear();
    _order.clear();
    _state.clear();
    _use.clear();
    _consented = false;
    _log.clear();
    _logFile = null;
    _logTimer?.cancel();
    _logTimer = null;
  }

  Future<void> _save() async {
    notifyListeners();
    final s = _secrets;
    if (s == null) return;
    await s.set(
      _secretName,
      jsonEncode({
        if (_consented) 'consent': true,
        'keys': [for (final k in _keys) k.toJson()],
        'order': {for (final e in _order.entries) e.key.name: e.value},
        'state': {
          for (final e in _state.entries)
            if (e.value.restUntil != null || e.value.refused != null)
              e.key: {
                if (e.value.restUntil != null) 'restUntil': e.value.restUntil!.toIso8601String(),
                if (e.value.refused != null) 'refused': e.value.refused,
              },
        },
      }),
    );
  }

  /// A new key, or one changed: changed, it is given another chance.
  Future<void> put(AiKey key) async {
    _consented = true;
    final i = _keys.indexWhere((k) => k.id == key.id);
    if (i < 0) {
      _keys.add(key);
    } else {
      _keys[i] = key;
    }
    _state.remove(key.id);
    for (final job in AiJob.values) {
      final order = _order[job] ??= [];
      if (key.models[job] != null && !order.contains(key.id)) order.add(key.id);
      if (key.models[job] == null) order.remove(key.id);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    _keys.removeWhere((k) => k.id == id);
    for (final o in _order.values) {
      o.remove(id);
    }
    _state.remove(id);
    _use.remove(id);
    await _save();
    await _saveUse();
  }

  /// The keys a [job] tries, in their order: those with a model for it.
  List<AiKey> forJob(AiJob job) {
    final byId = {for (final k in _keys) k.id: k};
    final ordered = [
      for (final id in _order[job] ?? const <String>[])
        if (byId[id]?.models[job] != null) byId[id]!,
    ];
    // Any with a model for it the order does not name yet, last.
    for (final k in _keys) {
      if (k.models[job] != null && !ordered.contains(k)) ordered.add(k);
    }
    return ordered;
  }

  Future<void> reorder(AiJob job, List<String> ids) async {
    _order[job] = [...ids];
    await _save();
  }

  /// The key's quota is spent: it rests until [until].
  Future<void> rest(String id, DateTime until, String why) async {
    _state[id] = KeyState(restUntil: until, lastError: why);
    await _save();
  }

  /// The provider refused the key.
  Future<void> refuse(String id, String why) async {
    _state[id] = KeyState(refused: why, lastError: why);
    await _save();
  }

  /// It worked: whatever was held against it goes; but not a rest for its
  /// daily limit, which the very call that worked may have just reached (it
  /// was cleared at once, so the limit never held).
  void cleared(String id, {DateTime? now}) {
    final s = _state[id];
    if (s == null) return;
    if ((s.lastError?.startsWith(dailyLimitReached) ?? false) && s.restingAt(now ?? DateTime.now())) return;
    _state.remove(id);
    unawaited(_save());
  }

  /// How a rest for the daily limit is said, and known.
  static const dailyLimitReached = 'its daily limit of';

  /// The soonest a resting key of [job] wakes, if all of them rest.
  DateTime? wakesAt(AiJob job, {DateTime? now}) {
    final at = now ?? DateTime.now();
    DateTime? soonest;
    for (final k in forJob(job)) {
      final s = stateOf(k.id);
      if (s.refused != null) continue;
      if (!s.restingAt(at)) return null;
      if (soonest == null || s.restUntil!.isBefore(soonest)) soonest = s.restUntil;
    }
    return soonest;
  }

  static String _day(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// [usage] counted to key [id], today.
  void count(String id, AiUsage usage, {DateTime? now}) {
    final days = _use[id] ??= {};
    final day = days[_day(now ?? DateTime.now())] ??= DayUse();
    day
      ..calls += 1
      ..input += usage.input
      ..output += usage.output;
    // Its daily limit reached: it rests until midnight.
    final cap = _keys.where((k) => k.id == id).firstOrNull?.dailyCap;
    final at = now ?? DateTime.now();
    if (cap != null && day.input + day.output >= cap && !stateOf(id).restingAt(at)) {
      unawaited(rest(id, DateTime(at.year, at.month, at.day + 1), '$dailyLimitReached $cap tokens is used'));
    }
    if (days.length > 30) {
      final sorted = days.keys.toList()..sort();
      for (final old in sorted.take(days.length - 30)) {
        days.remove(old);
      }
    }
    notifyListeners();
    _useDirty = true;
    _useTimer ??= Timer(const Duration(seconds: 2), () {
      _useTimer = null;
      unawaited(_saveUse());
    });
  }

  bool _useDirty = false;
  Timer? _useTimer;

  Future<void> _saveUse() async {
    final f = _useFile;
    if (f == null || !_useDirty) return;
    _useDirty = false;
    await writeSafely(
      f,
      jsonEncode({
        for (final e in _use.entries) e.key: {for (final d in e.value.entries) d.key: d.value.toJson()},
      }),
    );
  }

  /// Key [id]'s use today.
  DayUse today(String id, {DateTime? now}) => _use[id]?[_day(now ?? DateTime.now())] ?? DayUse();

  /// Key [id]'s use over the days kept.
  DayUse allTime(String id) {
    final all = DayUse();
    for (final d in (_use[id] ?? const <String, DayUse>{}).values) {
      all
        ..calls += d.calls
        ..input += d.input
        ..output += d.output;
    }
    return all;
  }
}
