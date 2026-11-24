import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'safe_file.dart';

/// A log the reader turns on to share with whoever helps them (the voice
/// log, the tap log): notes kept in a file in the app's private storage
/// (out of every backup, as the error log is), off unless a flag file is
/// there. Off, [note] returns at once. On, a note is added to a list in
/// memory and written a few seconds later with the others, so nothing ever
/// waits on the disk.
class NoteLog {
  NoteLog({required this.fileName, required this.onName, required this.keep});

  /// The notes, one a line.
  final String fileName;

  /// There while the log is on.
  final String onName;

  /// The most kept: one more pushes out the oldest.
  final int keep;

  Directory? _dir;
  bool _on = false;
  final _events = <LogEvent>[];
  final _unsaved = <LogEvent>[];
  int _fileLines = 0;
  Timer? _saveTimer;

  /// Told when it is turned on or off, or cleared.
  final changes = ValueNotifier<int>(0);

  bool get on => _on;

  /// Oldest first.
  List<LogEvent> get events => List.unmodifiable(_events);

  /// Called once it has been read, and each time it is turned on or off.
  @protected
  void switched() {}

  /// Read what is kept in [dir] (the app's private storage), and whether it
  /// is on.
  Future<void> attach(Directory dir) async {
    if (_dir?.path == dir.path) return;
    _dir = dir;
    try {
      _on = await File('${dir.path}/$onName').exists();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        final read = <LogEvent>[];
        for (final line in await file.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            final e = LogEvent.fromJson(jsonDecode(line));
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
    switched();
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
    switched();
    changes.value++;
  }

  /// Note [kind] with [fields] (numbers, short words: never a book's text).
  void note(String kind, [Map<String, Object?> fields = const {}]) {
    if (!_on) return;
    final e = LogEvent(DateTime.now(), kind, fields);
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

  /// Back to nothing, nowhere (between tests).
  @mustCallSuper
  void reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
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

/// One thing a log noted.
@immutable
class LogEvent {
  const LogEvent(this.time, this.kind, this.fields);

  final DateTime time;
  final String kind;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {'t': time.millisecondsSinceEpoch, 'k': kind, ...fields};

  static LogEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t'];
    final k = json['k'];
    if (t is! int || k is! String) return null;
    return LogEvent(
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

/// The step-by-step part of a shared log: a line a note, oldest first, the
/// day written above its first.
void writeSteps(StringBuffer b, List<LogEvent> events) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
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
}
