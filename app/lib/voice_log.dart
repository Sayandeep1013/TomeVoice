import 'package:flutter/widgets.dart';

import 'error_log.dart' show scrubError;
import 'note_log.dart';

export 'note_log.dart' show LogEvent;

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
class VoiceLog extends NoteLog with WidgetsBindingObserver {
  VoiceLog._() : super(logFile: fileName, onFlag: onName, most: keep);

  static final instance = VoiceLog._();

  /// The most kept: one more pushes out the oldest (a day or two of reading).
  static const keep = 4000;

  /// The log, one event a line, in the app's private storage (out of every
  /// backup, as the error log is).
  static const fileName = 'voice-log.jsonl';

  /// There while the log is on.
  static const onName = 'voice-log.on';

  bool _watching = false;

  @override
  void switched() => _watch();

  /// Android's own warnings, noted only while the log is on.
  void _watch() {
    final binding = WidgetsBinding.instance;
    if (on && !_watching) {
      binding.addObserver(this);
      _watching = true;
    } else if (!on && _watching) {
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

  @override
  void reset() {
    if (_watching) WidgetsBinding.instance.removeObserver(this);
    _watching = false;
    super.reset();
  }
}

/// One thing reading aloud did.
typedef VoiceEvent = LogEvent;

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

String _times(int n) => n == 1 ? 'once' : '$n times';

/// 1.15 as "1.15×", 2.0 as "2×".
String speedLabel(num speed) {
  var s = speed.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$s${String.fromCharCode(0xD7)}';
}

/// What [events] say, in plain words, a line each: how quickly the voice
/// was heard, whether the phone kept up at each speed, the gaps, the
/// errors, and which voices read which alphabets.
List<String> voiceLogSummary(List<VoiceEvent> events) {
  final out = <String>[];
  // Starts heard.
  final sounds = events.where((e) => e.kind == 'sound' && e.n('ms') != null).toList();
  if (sounds.isEmpty) {
    out.add(events.any((e) => e.kind == 'resume')
        ? 'Reading was only resumed with the log on, so no start was timed: press Play on a book to time one.'
        : 'No start was timed yet: press Play with the log on.');
  } else {
    final byWhat = <String, List<int>>{};
    for (final e in sounds) {
      (byWhat[e.s('after')] ??= []).add(e.n('ms')!.round());
    }
    for (final w in byWhat.entries) {
      final xs = w.value;
      out.add(xs.length == 1
          ? 'After ${w.key}: the voice was heard in ${_secs(xs.single)} (once).'
          : 'After ${w.key}: the voice was heard in ${_secs(_median(xs))} as a rule '
              '(${_times(xs.length)}; slowest ${_secs(xs.reduce((a, b) => a > b ? a : b))}).');
    }
  }
  // Changes of speed heard at once, from what was made (scheduler.dart's
  // _restretch).
  final stretched = events.where((e) => e.kind == 'restretched').map((e) => (e.n('ms') ?? 0).round()).toList();
  if (stretched.isNotEmpty) {
    out.add('A change of speed was heard at once ${_times(stretched.length)}: what was made was played at the new '
        'speed (${_secs(_median(stretched))} to ready it, as a rule).');
  }
  // Keeping up, by speed.
  final made = events.where((e) => e.kind == 'made' && (e.n('ms') ?? 0) > 0 && (e.n('speechMs') ?? 0) > 0).toList();
  if (made.isNotEmpty) {
    final bySpeed = <double, List<VoiceEvent>>{};
    for (final e in made) {
      final speed = ((e.n('speed') ?? 1) * 20).round() / 20;
      (bySpeed[speed] ??= []).add(e);
    }
    for (final s in bySpeed.keys.toList()..sort()) {
      final list = bySpeed[s]!;
      final slow = list.where((e) => e.n('ms')! > e.n('speechMs')!).length;
      final pace = _median([for (final e in list) (e.n('ms')! * 100 / e.n('speechMs')!).round()]);
      out.add('At ${speedLabel(s)}: a sentence was made in $pace% of the time it takes to say, as a rule; '
          '$slow of ${list.length} took longer to make than to say'
          '${slow * 3 > list.length ? ' (this phone cannot keep up at this speed)' : ''}.');
    }
  }
  // Gaps.
  final gaps = events.where((e) => e.kind == 'gap' && e.n('ms') != null).map((e) => e.n('ms')!.round()).toList();
  if (gaps.isNotEmpty) {
    final long = gaps.where((g) => g >= 1000).length;
    out.add('The voice ran dry ${_times(gaps.length)}, waiting for the next sentence: '
        '${_secs(gaps.fold<int>(0, (a, b) => a + b))} of silence in all, the longest ${_secs(gaps.reduce((a, b) => a > b ? a : b))}'
        '${long > 0 ? '; $long over a second' : ''}.');
  } else if (made.isNotEmpty) {
    out.add('The voice never ran dry while reading.');
  }
  // Which voice read which alphabet.
  final scripts = <String, Map<String, int>>{};
  for (final e in made) {
    // A line of marks or numbers only ("* * *", "1.") says nothing here.
    if (e.s('script') == 'none') continue;
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
    out.add('Error${e.value > 1 ? ' (${e.value} times)' : ''}: ${e.key}');
  }
  // Natural voices loaded (at the start, after one was let go while
  // paused): the first sentence after waits for it.
  final loads = events.where((e) => e.kind == 'voice loaded' && e.n('ms') != null).map((e) => e.n('ms')!.round()).toList();
  if (loads.isNotEmpty) {
    out.add('A natural voice was loaded ${_times(loads.length)}, in ${_secs(_median(loads))}'
        '${loads.length > 1 ? ' as a rule (slowest ${_secs(loads.reduce((a, b) => a > b ? a : b))})' : ''}: '
        'the sentence made just after waits for it.');
  }
  int count(String kind) => events.where((e) => e.kind == kind).length;
  if (count('fallback') > 0) out.add("A natural voice gave way to the phone's ${_times(count('fallback'))}.");
  if (count('stall') > 0) out.add('The player stopped moving ${_times(count('stall'))}.');
  if (count('memory low') > 0) out.add('Android asked for memory back ${_times(count('memory low'))}.');
  return out;
}

/// The whole log as text to share: [header] (the phone and the app), the
/// summary, then every event, oldest first.
String voiceLogText(List<VoiceEvent> events, {required List<String> header}) {
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
  writeSteps(b, events);
  return b.toString();
}

/// An error's words as the voice log keeps them (as the error log does: no
/// quotes, links or paths, which could hold a book's words).
String voiceLogError(Object? message) => scrubError('${message ?? ''}', max: 160);
