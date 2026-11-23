import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'error_log.dart' show scrubError;
import 'safe_file.dart';

/// The voice log: what reading aloud did on this phone, step by step, for a
/// reader whose voice lags, stops or goes wrong to share (About > Voice
/// log). Off unless they turn it on; nothing is ever sent from the app.
///
/// It notes how long each start took to be heard (Play, a skip, a change of
/// speed or voice), how long each sentence took to make against how long it
/// plays (a phone that makes speech slower than it is spoken runs dry), each
/// time the voice ran dry and for how long, the engine's errors, a natural
/// voice giving way to the phone's, the player stalling, Android asking for
/// memory back and the app going to the background. Never a book's words or
/// title: a sentence is its length and the alphabet it is written in.
///
/// Off, [note] returns at once. On, a line is added to a list in memory and
/// written a few seconds later with the others, so reading never waits on
/// the disk.
class VoiceLog with WidgetsBindingObserver {
  VoiceLog._();

  static final instance = VoiceLog._();

  /// The most kept: one more pushes out the oldest (a day or two of reading).
  static const keep = 4000;

  /// The log, one event a line, in the app's private storage (out of every
  /// backup, as the error log is).
  static const fileName = 'voice-log.jsonl';

  /// There while the log is on.
  static const onName = 'voice-log.on';

  Directory? _dir;
  bool _on = false;
  final _events = <VoiceEvent>[];
  final _unsaved = <VoiceEvent>[];
  int _fileLines = 0;
  Timer? _saveTimer;
  bool _watching = false;

  /// Told when it is turned on or off, or cleared.
  final changes = ValueNotifier<int>(0);

  bool get on => _on;

  /// Oldest first.
  List<VoiceEvent> get events => List.unmodifiable(_events);

  /// Read what is kept in [dir] (the app's private storage), and whether it
  /// is on.
  Future<void> attach(Directory dir) async {
    if (_dir?.path == dir.path) return;
    _dir = dir;
    try {
      _on = await File('${dir.path}/$onName').exists();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        final read = <VoiceEvent>[];
        for (final line in await file.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            final e = VoiceEvent.fromJson(jsonDecode(line));
            if (e != null) read.add(e);
          } on FormatException {
            // A line cut short as the app was ended.
          }
        }
        _fileLines = read.length;
        _events.insertAll(0, read);
        _trim();
      }
    } on Object {
      // Unreadable: started afresh.
    }
    _watch();
    changes.value++;
  }

  /// Turn the log on or off. Off keeps what was noted, to be shared.
  Future<void> setOn(bool on) async {
    if (on == _on) return;
    if (on) {
      _on = true;
      note('log on');
    } else {
      note('log off');
      await flush();
      _on = false;
    }
    final dir = _dir;
    if (dir != null) {
      final flag = File('${dir.path}/$onName');
      try {
        if (on) {
          await flag.writeAsString('1');
        } else if (await flag.exists()) {
          await flag.delete();
        }
      } on Object {
        // Asked again next time.
      }
    }
    _watch();
    changes.value++;
  }

  /// Note [kind] with [fields] (numbers, short words: never a book's text).
  void note(String kind, [Map<String, Object?> fields = const {}]) {
    if (!_on) return;
    final e = VoiceEvent(DateTime.now(), kind, fields);
    _events.add(e);
    _unsaved.add(e);
    _trim();
    _saveTimer ??= Timer(const Duration(seconds: 4), () => unawaited(flush()));
  }

  void _trim() {
    if (_events.length > keep) _events.removeRange(0, _events.length - keep);
  }

  /// Write what is not written yet: added to the end of the file, which is
  /// written afresh only when it has grown to twice what is kept.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final dir = _dir;
    if (dir == null || _unsaved.isEmpty) return;
    final file = File('${dir.path}/$fileName');
    final count = _unsaved.length;
    final lines = _unsaved.map((e) => jsonEncode(e.toJson())).join('\n');
    _unsaved.clear();
    try {
      if (_fileLines + count > keep * 2) {
        await writeSafely(file, '${_events.map((e) => jsonEncode(e.toJson())).join('\n')}\n');
        _fileLines = _events.length;
      } else {
        await file.writeAsString('$lines\n', mode: FileMode.append, flush: true);
        _fileLines += count;
      }
    } on Object {
      // Written with the next.
    }
  }

  /// Forget everything noted.
  Future<void> clear() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _events.clear();
    _unsaved.clear();
    _fileLines = 0;
    final dir = _dir;
    if (dir != null) {
      final file = File('${dir.path}/$fileName');
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // Gone with the next write.
      }
    }
    changes.value++;
  }

  /// Android's own warnings, noted only while the log is on.
  void _watch() {
    final binding = WidgetsBinding.instance;
    if (_on && !_watching) {
      binding.addObserver(this);
      _watching = true;
    } else if (!_on && _watching) {
      binding.removeObserver(this);
      _watching = false;
    }
  }

  @override
  void didHaveMemoryPressure() => note('memory low');

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) note('app hidden');
    if (state == AppLifecycleState.resumed) note('app shown');
  }

  /// Back to nothing, nowhere (between tests).
  @visibleForTesting
  void reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_watching) WidgetsBinding.instance.removeObserver(this);
    _watching = false;
    _dir = null;
    _on = false;
    _events.clear();
    _unsaved.clear();
    _fileLines = 0;
  }

  /// Turned on in memory only (tests).
  @visibleForTesting
  set onForTests(bool on) => _on = on;
}

/// One thing reading aloud did.
@immutable
class VoiceEvent {
  const VoiceEvent(this.time, this.kind, this.fields);

  final DateTime time;
  final String kind;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {'t': time.millisecondsSinceEpoch, 'k': kind, ...fields};

  static VoiceEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t'];
    final k = json['k'];
    if (t is! int || k is! String) return null;
    return VoiceEvent(
      DateTime.fromMillisecondsSinceEpoch(t),
      k,
      {
        for (final e in json.entries)
          if (e.key != 't' && e.key != 'k') '${e.key}': e.value,
      },
    );
  }

  num? n(String key) => fields[key] is num ? fields[key] as num : null;
  String s(String key) => '${fields[key] ?? ''}';
}

/// The alphabet [text] is mostly written in ("Latin", "Bengali", "CJK"…),
/// from its first letters: which voice should read it, without its words.
String scriptOf(String text) {
  final counts = <String, int>{};
  var seen = 0;
  for (final r in text.runes) {
    final s = _scriptOfRune(r);
    if (s == null) continue;
    counts[s] = (counts[s] ?? 0) + 1;
    if (++seen >= 80) break;
  }
  if (counts.isEmpty) return 'none';
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

String? _scriptOfRune(int r) {
  bool within(int a, int b) => r >= a && r <= b;
  if (within(0x41, 0x5A) || within(0x61, 0x7A) || within(0xC0, 0x24F) || within(0x1E00, 0x1EFF)) return 'Latin';
  if (within(0x0980, 0x09FF)) return 'Bengali';
  if (within(0x0900, 0x097F)) return 'Devanagari';
  if (within(0x0A00, 0x0A7F)) return 'Gurmukhi';
  if (within(0x0A80, 0x0AFF)) return 'Gujarati';
  if (within(0x0B80, 0x0BFF)) return 'Tamil';
  if (within(0x0C00, 0x0C7F)) return 'Telugu';
  if (within(0x0C80, 0x0CFF)) return 'Kannada';
  if (within(0x0D00, 0x0D7F)) return 'Malayalam';
  if (within(0x0B00, 0x0B7F)) return 'Odia';
  if (within(0x0600, 0x06FF) || within(0x0750, 0x077F)) return 'Arabic';
  if (within(0x0400, 0x04FF)) return 'Cyrillic';
  if (within(0x0370, 0x03FF)) return 'Greek';
  if (within(0x0590, 0x05FF)) return 'Hebrew';
  if (within(0x0E00, 0x0E7F)) return 'Thai';
  if (within(0xAC00, 0xD7AF) || within(0x1100, 0x11FF)) return 'Hangul';
  if (within(0x3040, 0x30FF)) return 'Kana';
  if (within(0x4E00, 0x9FFF) || within(0x3400, 0x4DBF)) return 'CJK';
  if (within(0x0E80, 0x0EFF)) return 'Lao';
  if (within(0x1000, 0x109F)) return 'Myanmar';
  if (within(0x0D80, 0x0DFF)) return 'Sinhala';
  if (r > 0x7F && String.fromCharCode(r).toUpperCase() != String.fromCharCode(r).toLowerCase()) return 'Other';
  return null;
}

int _median(List<int> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

String _secs(num ms) => '${(ms / 1000).toStringAsFixed(1)} s';

/// What [events] say, in plain words, a line each: how quickly the voice
/// was heard, whether the phone kept up at each speed, the gaps, the
/// errors, and which voices read which alphabets.
List<String> voiceLogSummary(List<VoiceEvent> events) {
  final out = <String>[];
  // Starts heard.
  final sounds = events.where((e) => e.kind == 'sound' && e.n('ms') != null).toList();
  if (sounds.isEmpty) {
    out.add('No start was timed yet: press Play with the log on.');
  } else {
    final byWhat = <String, List<int>>{};
    for (final e in sounds) {
      (byWhat[e.s('after')] ??= []).add(e.n('ms')!.round());
    }
    for (final w in byWhat.entries) {
      final xs = w.value;
      out.add('After ${w.key}: the voice was heard in ${_secs(_median(xs))} as a rule '
          '(${xs.length} times; slowest ${_secs(xs.reduce((a, b) => a > b ? a : b))}).');
    }
  }
  // Keeping up, by speed.
  final made = events.where((e) => e.kind == 'made' && (e.n('ms') ?? 0) > 0 && (e.n('speechMs') ?? 0) > 0).toList();
  if (made.isNotEmpty) {
    final bySpeed = <String, List<VoiceEvent>>{};
    for (final e in made) {
      final speed = ((e.n('speed') ?? 1) * 4).round() / 4;
      (bySpeed['${speed}x'] ??= []).add(e);
    }
    final speeds = bySpeed.keys.toList()..sort((a, b) => double.parse(a.replaceAll('x', '')).compareTo(double.parse(b.replaceAll('x', ''))));
    for (final s in speeds) {
      final list = bySpeed[s]!;
      final slow = list.where((e) => e.n('ms')! > e.n('speechMs')!).length;
      final pace = _median([for (final e in list) (e.n('ms')! * 100 / e.n('speechMs')!).round()]);
      out.add('At $s: a sentence took $pace% of its own length to make, as a rule; '
          '$slow of ${list.length} took longer to make than to say'
          '${slow * 3 > list.length ? ' (this phone cannot keep up at this speed)' : ''}.');
    }
  }
  // Gaps.
  final gaps = events.where((e) => e.kind == 'gap' && e.n('ms') != null).map((e) => e.n('ms')!.round()).toList();
  if (gaps.isNotEmpty) {
    final long = gaps.where((g) => g >= 1000).length;
    out.add('The voice ran dry ${gaps.length} times, waiting for the next sentence: '
        '${_secs(gaps.fold<int>(0, (a, b) => a + b))} of silence in all, the longest ${_secs(gaps.reduce((a, b) => a > b ? a : b))}'
        '${long > 0 ? '; $long over a second' : ''}.');
  } else if (made.isNotEmpty) {
    out.add('The voice never ran dry while reading.');
  }
  // Which voice read which alphabet.
  final scripts = <String, Map<String, int>>{};
  for (final e in made) {
    final m = scripts[e.s('script')] ??= {};
    m[e.s('voice')] = (m[e.s('voice')] ?? 0) + 1;
  }
  for (final s in scripts.entries) {
    final voices = s.value.entries.map((v) => '${v.key} (${v.value})').join(', ');
    out.add('${s.key} sentences were read by: $voices.');
  }
  // What went wrong.
  final errors = <String, int>{};
  for (final e in events.where((e) => e.kind == 'error')) {
    final key = [e.s('code'), e.s('message')].where((x) => x.isNotEmpty).join(': ');
    errors[key] = (errors[key] ?? 0) + 1;
  }
  for (final e in errors.entries) {
    out.add('Error${e.value > 1 ? ' ${e.value} times' : ''}: ${e.key}');
  }
  int count(String kind) => events.where((e) => e.kind == kind).length;
  if (count('fallback') > 0) out.add("A natural voice gave way to the phone's ${count('fallback')} times.");
  if (count('stall') > 0) out.add('The player stopped moving ${count('stall')} times.');
  if (count('memory low') > 0) out.add('Android asked for memory back ${count('memory low')} times.');
  return out;
}

/// The whole log as text to share: [header] (the phone and the app), the
/// summary, then every event, oldest first.
String voiceLogText(List<VoiceEvent> events, {required List<String> header}) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  final b = StringBuffer()
    ..writeln('TomeVoice voice log')
    ..writeln("It never holds a book's words or title: a sentence is its length and alphabet.")
    ..writeln();
  for (final h in header) {
    b.writeln(h);
  }
  b
    ..writeln()
    ..writeln('In short')
    ..writeln('--------');
  for (final s in voiceLogSummary(events)) {
    b.writeln('- $s');
  }
  b
    ..writeln()
    ..writeln('Step by step')
    ..writeln('------------');
  String? day;
  for (final e in events) {
    final t = e.time;
    final d = '${t.year}-${two(t.month)}-${two(t.day)}';
    if (d != day) {
      day = d;
      b.writeln(d);
    }
    final fields = e.fields.entries.map((f) => '${f.key}=${f.value}').join(' ');
    b.writeln('${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}  ${e.kind}${fields.isEmpty ? '' : '  $fields'}');
  }
  return b.toString();
}

/// An error's words as the voice log keeps them (as the error log does: no
/// quotes, links or paths, which could hold a book's words).
String voiceLogError(Object? message) => scrubError('${message ?? ''}', max: 160);
